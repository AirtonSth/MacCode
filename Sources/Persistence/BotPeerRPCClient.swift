import Foundation
import Darwin
import CoreModel

enum BotPeerRPCError: Error, CustomStringConvertible, Equatable {
    case missingContext(String)
    case invalidContext(String)
    case socket(String)
    case timeout(String)
    case invalidResponse
    case remote(String)

    var description: String {
        switch self {
        case .missingContext(let key): return "Bot delegation requires \(key) on the active provider run."
        case .invalidContext(let key): return "Bot delegation received an invalid \(key)."
        case .socket(let message): return message
        case .timeout(let budget): return "MacCode \(budget) request timed out."
        case .invalidResponse: return "MacCode returned an invalid Bot delegation response."
        case .remote(let message): return message
        }
    }

    var requiresReceiptReconciliation: Bool {
        switch self {
        case .socket, .timeout, .invalidResponse: return true
        case .missingContext, .invalidContext, .remote: return false
        }
    }
}

/// Blocking Unix-socket client used by the stdio MCP subprocess. The provider
/// is already blocked on its tool call while the app asynchronously runs the
/// peer Bot, so no polling or prompt inference belongs in this process.
///
/// Connect, write, and newline-read are nonblocking with explicit monotonic
/// deadlines. Peer consultations keep the long Bot-ask budget; host catalog
/// operations use the short host budget.
struct BotPeerRPCClient {
    static let maximumResponseBytes = 2 * 1_024 * 1_024
    private static let durablePeerMethods: Set<String> = [
        "bot.peer.ask", "bot.peer.self_config", "bot.peer.cancel",
    ]

    enum Budget: String, Equatable, Sendable {
        case peerConsultation
        case hostOperation

        var timeout: TimeInterval {
            switch self {
            case .peerConsultation: return BotPeerDelegation.peerConsultationTimeout
            case .hostOperation: return BotPeerDelegation.hostOperationTimeout
            }
        }
    }

    let environment: [String: String]
    var syscalls: UnixDeadlineSyscalls
    var timeoutOverride: TimeInterval?

    init(
        environment: [String: String],
        syscalls: UnixDeadlineSyscalls = .darwin,
        timeoutOverride: TimeInterval? = nil
    ) {
        self.environment = environment
        self.syscalls = syscalls
        self.timeoutOverride = timeoutOverride
    }

    func call(
        method: String,
        arguments: [String: Any],
        budget: Budget = .peerConsultation
    ) throws -> Any {
        let context = try requestContext()
        var params = arguments
        params["thread_id"] = context.threadID
        params["run_id"] = context.runID
        if let capability = context.capability {
            params[BotPeerDelegation.capabilityRPCParameterKey] = capability
        }

        guard Self.durablePeerMethods.contains(method) else {
            return try callOnce(method: method, params: params, context: context, budget: budget)
        }
        let clientRequestID = (params["client_request_id"] as? String) ?? UUID().uuidString.lowercased()
        params["client_request_id"] = clientRequestID
        do {
            return try callOnce(method: method, params: params, context: context, budget: budget)
        } catch let initialError as BotPeerRPCError {
            guard initialError.requiresReceiptReconciliation else { throw initialError }
            var statusParams: [String: Any] = [
                "method": method,
                "client_request_id": clientRequestID,
                "thread_id": context.threadID,
                "run_id": context.runID,
            ]
            if let capability = context.capability {
                statusParams[BotPeerDelegation.capabilityRPCParameterKey] = capability
            }
            let statusMethod = method == "bot.peer.ask"
                ? "bot.peer.receipt.status"
                : "bot.receipt.status"
            guard let statusResult = try? callOnce(
                method: statusMethod,
                params: statusParams,
                context: context,
                budget: .hostOperation
            ),
                  let status = statusResult as? [String: Any],
                  status["status"] as? String == "committed",
                  status["method"] as? String == method,
                  status["clientRequestId"] as? String == clientRequestID,
                  status["caller_thread_id"] as? String == context.threadID.lowercased(),
                  status["caller_run_id"] as? String == context.runID.lowercased(),
                  let result = status["result"] else {
                throw initialError
            }
            return result
        }
    }

    private func callOnce(
        method: String,
        params: [String: Any],
        context: (socketPath: String, threadID: String, runID: String, capability: String?),
        budget: Budget
    ) throws -> Any {

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        ]
        var payload = try JSONSerialization.data(withJSONObject: request)
        payload.append(0x0A)
        let timeout = timeoutOverride ?? budget.timeout
        let started = DispatchTime.now()
        let deadline = DispatchTime.now() + timeout
        let response: Data
        do {
            response = try UnixDeadlineSession.roundTrip(
                syscalls: syscalls,
                socketPath: context.socketPath,
                payload: payload,
                deadline: deadline,
                idleTimeout: budget == .peerConsultation ? timeout : nil,
                maximumResponseBytes: Self.maximumResponseBytes
            )
        } catch let error as BotPeerRPCError {
            if case .timeout(let phase) = error {
                let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
                RemoteCodeHostCatalogDiagnostics.timeout(
                    method: method,
                    budget: "\(budget.rawValue).\(phase)",
                    elapsedMilliseconds: elapsed
                )
            }
            throw error
        }
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw BotPeerRPCError.invalidResponse
        }
        if let error = object["error"] as? [String: Any] {
            if error["data"] != nil, let data = try? JSONSerialization.data(withJSONObject: error, options: [.sortedKeys]),
               let structured = String(data: data, encoding: .utf8) {
                throw BotPeerRPCError.remote(structured)
            }
            throw BotPeerRPCError.remote(error["message"] as? String ?? "Bot delegation failed.")
        }
        guard let result = object["result"] else {
            throw BotPeerRPCError.invalidResponse
        }
        return result
    }

    private func requestContext() throws -> (
        socketPath: String,
        threadID: String,
        runID: String,
        capability: String?
    ) {
        func required(_ key: String) throws -> String {
            guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { throw BotPeerRPCError.missingContext(key) }
            return value
        }
        func optional(_ key: String) -> String? {
            let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        let socketPath = try required(BotPeerDelegation.socketEnvironmentKey)
        let threadID = try required(BotPeerDelegation.threadEnvironmentKey)
        let runID = try required(BotPeerDelegation.runEnvironmentKey)
        guard UUID(uuidString: threadID) != nil else {
            throw BotPeerRPCError.invalidContext(BotPeerDelegation.threadEnvironmentKey)
        }
        guard UUID(uuidString: runID) != nil else {
            throw BotPeerRPCError.invalidContext(BotPeerDelegation.runEnvironmentKey)
        }
        return (
            socketPath,
            threadID,
            runID,
            optional(BotPeerDelegation.capabilityEnvironmentKey)
        )
    }
}

struct UnixDeadlineSyscalls: Sendable {
    var socket: @Sendable (Int32, Int32, Int32) -> Int32
    var fcntlGet: @Sendable (Int32) -> Int32
    var fcntlSetNonblocking: @Sendable (Int32, Int32) -> Int32
    var disableSIGPIPE: @Sendable (Int32) -> Int32
    var connect: @Sendable (Int32, UnsafePointer<sockaddr>, socklen_t) -> Int32
    var poll: @Sendable (UnsafeMutablePointer<pollfd>, nfds_t, Int32) -> Int32
    var write: @Sendable (Int32, UnsafeRawPointer, Int) -> Int
    var read: @Sendable (Int32, UnsafeMutableRawPointer, Int) -> Int
    var close: @Sendable (Int32) -> Int32
    var getSocketError: @Sendable (Int32) -> Int32
    var errnoValue: @Sendable () -> Int32

    static let darwin = UnixDeadlineSyscalls(
        socket: { Darwin.socket($0, $1, $2) },
        fcntlGet: { fcntl($0, F_GETFL) },
        fcntlSetNonblocking: { fd, flags in fcntl(fd, F_SETFL, flags) },
        disableSIGPIPE: { fd in
            var enabled: Int32 = 1
            return setsockopt(
                fd,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &enabled,
                socklen_t(MemoryLayout<Int32>.size)
            )
        },
        connect: { Darwin.connect($0, $1, $2) },
        poll: { Darwin.poll($0, $1, $2) },
        write: { Darwin.write($0, $1, $2) },
        read: { Darwin.read($0, $1, $2) },
        close: { Darwin.close($0) },
        getSocketError: { fd in
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            let result = getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
            return result == 0 ? error : errno
        },
        errnoValue: { errno }
    )
}

enum UnixDeadlineSession {
    static func roundTrip(
        syscalls: UnixDeadlineSyscalls,
        socketPath: String,
        payload: Data,
        deadline: DispatchTime,
        idleTimeout: TimeInterval? = nil,
        maximumResponseBytes: Int
    ) throws -> Data {
        let fd = syscalls.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw BotPeerRPCError.socket("Bot delegation socket(): \(String(cString: strerror(Int32(syscalls.errnoValue()))))")
        }
        defer { _ = syscalls.close(fd) }

        guard syscalls.disableSIGPIPE(fd) == 0 else {
            throw BotPeerRPCError.socket("Bot delegation could not disable SIGPIPE.")
        }

        let flags = syscalls.fcntlGet(fd)
        guard flags >= 0 else {
            throw BotPeerRPCError.socket("Bot delegation fcntl(F_GETFL) failed.")
        }
        guard syscalls.fcntlSetNonblocking(fd, flags | O_NONBLOCK) == 0 else {
            throw BotPeerRPCError.socket("Bot delegation fcntl(F_SETFL) failed.")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            throw BotPeerRPCError.socket("Bot delegation socket path is too long.")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
            tuplePointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                pathBytes.withUnsafeBufferPointer { source in
                    for index in source.indices { destination[index] = source[index] }
                }
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                syscalls.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            let connectErrno = syscalls.errnoValue()
            if connectErrno != EINPROGRESS {
                throw BotPeerRPCError.socket(
                    "Bot delegation could not connect to MacCode: \(String(cString: strerror(connectErrno)))"
                )
            }
            try wait(syscalls: syscalls, fd: fd, events: Int16(POLLOUT), deadline: deadline, budget: "connect")
            let socketError = syscalls.getSocketError(fd)
            guard socketError == 0 else {
                throw BotPeerRPCError.socket(
                    "Bot delegation could not connect to MacCode: \(String(cString: strerror(socketError)))"
                )
            }
        }

        try writeAll(syscalls: syscalls, fd: fd, data: payload, deadline: deadline)
        return try readLine(
            syscalls: syscalls,
            fd: fd,
            deadline: deadline,
            idleTimeout: idleTimeout,
            maximumResponseBytes: maximumResponseBytes
        )
    }

    private static func wait(
        syscalls: UnixDeadlineSyscalls,
        fd: Int32,
        events: Int16,
        deadline: DispatchTime,
        budget: String
    ) throws {
        while true {
            try throwIfTimedOut(deadline, budget: budget)
            let remainingMs = millisecondsUntil(deadline)
            var pollFD = pollfd(fd: fd, events: events, revents: 0)
            let count = withUnsafeMutablePointer(to: &pollFD) {
                syscalls.poll($0, 1, remainingMs)
            }
            if count < 0 {
                if syscalls.errnoValue() == EINTR { continue }
                throw BotPeerRPCError.socket("Bot delegation poll(): \(String(cString: strerror(syscalls.errnoValue())))")
            }
            if count == 0 {
                throw BotPeerRPCError.timeout(budget)
            }
            if pollFD.revents & Int16(POLLNVAL) != 0 {
                throw BotPeerRPCError.socket("Bot delegation poll() saw a closed descriptor.")
            }
            if pollFD.revents & events != 0 { return }
            if pollFD.revents & Int16(POLLERR | POLLHUP) != 0 { return }
        }
    }

    private static func writeAll(
        syscalls: UnixDeadlineSyscalls,
        fd: Int32,
        data: Data,
        deadline: DispatchTime
    ) throws {
        guard !data.isEmpty else { return }
        var written = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while written < data.count {
                try wait(syscalls: syscalls, fd: fd, events: Int16(POLLOUT), deadline: deadline, budget: "write")
                let count = syscalls.write(fd, base.advanced(by: written), data.count - written)
                if count < 0 {
                    let writeErrno = syscalls.errnoValue()
                    if writeErrno == EINTR { continue }
                    if writeErrno == EAGAIN || writeErrno == EWOULDBLOCK { continue }
                    throw BotPeerRPCError.socket("Bot delegation request could not be written.")
                }
                if count == 0 {
                    throw BotPeerRPCError.socket("Bot delegation request could not be written.")
                }
                written += count
            }
        }
    }

    private static func readLine(
        syscalls: UnixDeadlineSyscalls,
        fd: Int32,
        deadline: DispatchTime,
        idleTimeout: TimeInterval?,
        maximumResponseBytes: Int
    ) throws -> Data {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        var readDeadline = deadline
        while response.last != 0x0A {
            try wait(syscalls: syscalls, fd: fd, events: Int16(POLLIN), deadline: readDeadline, budget: "read")
            let count = buffer.withUnsafeMutableBytes { raw in
                syscalls.read(fd, raw.baseAddress!, raw.count)
            }
            if count < 0 {
                let readErrno = syscalls.errnoValue()
                if readErrno == EINTR { continue }
                if readErrno == EAGAIN || readErrno == EWOULDBLOCK { continue }
                throw BotPeerRPCError.socket("MacCode closed the Bot delegation request before replying.")
            }
            guard count > 0 else {
                throw BotPeerRPCError.socket("MacCode closed the Bot delegation request before replying.")
            }
            response.append(buffer, count: count)
            if let idleTimeout {
                readDeadline = DispatchTime.now() + idleTimeout
            }
            guard response.count <= maximumResponseBytes else {
                throw BotPeerRPCError.invalidResponse
            }
        }
        return response
    }

    private static func throwIfTimedOut(_ deadline: DispatchTime, budget: String) throws {
        if DispatchTime.now().uptimeNanoseconds >= deadline.uptimeNanoseconds {
            throw BotPeerRPCError.timeout(budget)
        }
    }

    private static func millisecondsUntil(_ deadline: DispatchTime) -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= deadline.uptimeNanoseconds { return 0 }
        let remainingNs = deadline.uptimeNanoseconds - now
        let remainingMs = remainingNs / 1_000_000
        if remainingMs == 0 { return 1 }
        if remainingMs > UInt64(Int32.max) { return Int32.max }
        return Int32(remainingMs)
    }
}
