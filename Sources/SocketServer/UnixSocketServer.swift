import Foundation
import Darwin

/// Pure helper: builds the `server.listener` EventBus event payload for the
/// Unix-domain socket server. Mirrors `serverListenerEventPayload` in
/// HTTPServer.swift so subscribers can treat both servers uniformly.
/// - Parameters:
///   - bound: `true` on success, `false` on failure.
///   - path: The filesystem path the socket was (attempted to be) bound to.
public func unixSocketListenerEventPayload(bound: Bool, path: String) -> [String: Any] {
    return [
        "bound": bound,
        "address": path,
        "port": 0
    ]
}

/// Same-user local IPC server. The filesystem socket is owner-only (`0600`),
/// and requests intentionally use shared domain handlers without remote
/// transport identity or durable transport receipts.
public final class UnixSocketServer: @unchecked Sendable {
    private static let maxClientLineBytes = 1024 * 1024
    static let maxStreamQueuedBytes = 1024 * 1024
    static let maxConnectedClients = 64
    static let maxActiveRequests = 64
    private static let defaultLocalRequestTimeout: DispatchTimeInterval = .seconds(5)
    private static let agentMessageSendLocalRequestTimeout: DispatchTimeInterval = .seconds(120)

    public let socketPath: String
    private let dispatcher: JSONRPCDispatcher
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    private let lifecycleLock = NSLock()
    private var running = false
    private var starting = false
    private var stopping = false
    private var startCancellationRequested = false
    private var lifecycleGeneration: UInt64 = 0
    private var clientFDs: Set<Int32> = []
    private var activeRequestCount = 0
    private let localRequestTimeout: DispatchTimeInterval
    private let agentMessageSendRequestTimeout: DispatchTimeInterval
    private let activeRequestLimit: Int
    private let localRequestHandlerForTesting: (@MainActor @Sendable (JSONRPCRequest) async -> JSONRPCResponse)?
    var listenerFDObserverForTesting: (@Sendable (Int32) -> Void)?
    var acceptedFDObserverForTesting: (@Sendable (Int32) -> Void)?
    var outboundWriteWillBeginForTesting: (@Sendable (Data) -> Void)?
    var listenFDForTesting: Int32 {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return listenFD
    }
    var acceptedClientCountForTesting: Int {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return clientFDs.count
    }
    var activeRequestCountForTesting: Int {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return activeRequestCount
    }

    public init(socketPath: String, dispatcher: JSONRPCDispatcher) {
        self.socketPath = socketPath
        self.dispatcher = dispatcher
        self.localRequestTimeout = Self.defaultLocalRequestTimeout
        self.agentMessageSendRequestTimeout = Self.agentMessageSendLocalRequestTimeout
        self.activeRequestLimit = Self.maxActiveRequests
        self.localRequestHandlerForTesting = nil
    }

    init(
        socketPath: String,
        dispatcher: JSONRPCDispatcher,
        localRequestTimeoutForTesting: DispatchTimeInterval,
        agentMessageSendRequestTimeoutForTesting: DispatchTimeInterval? = nil,
        activeRequestLimitForTesting: Int,
        localRequestHandlerForTesting: @escaping @MainActor @Sendable (JSONRPCRequest) async -> JSONRPCResponse
    ) {
        self.socketPath = socketPath
        self.dispatcher = dispatcher
        self.localRequestTimeout = localRequestTimeoutForTesting
        self.agentMessageSendRequestTimeout =
            agentMessageSendRequestTimeoutForTesting ?? localRequestTimeoutForTesting
        self.activeRequestLimit = max(1, activeRequestLimitForTesting)
        self.localRequestHandlerForTesting = localRequestHandlerForTesting
    }

    public func start() throws {
        lifecycleLock.lock()
        guard !running, !starting, !stopping else {
            lifecycleLock.unlock()
            throw POSIXError(.EALREADY)
        }
        starting = true
        startCancellationRequested = false
        lifecycleLock.unlock()
        var committedStart = false
        defer {
            if !committedStart {
                lifecycleLock.lock()
                starting = false
                lifecycleLock.unlock()
            }
        }

        unlink(socketPath)
        let listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
        if listenerFD < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        listenerFDObserverForTesting?(listenerFD)
        guard Self.enableCloseOnExec(listenerFD) else {
            let savedErrno = errno
            close(listenerFD)
            unlink(socketPath)
            throw POSIXError(POSIXErrorCode(rawValue: savedErrno) ?? .EIO)
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        if pathBytes.count > maxPath {
            close(listenerFD)
            unlink(socketPath)
            throw NSError(domain: "RemoteCode.Socket", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket path too long: \(socketPath)"])
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tp in
            tp.withMemoryRebound(to: CChar.self, capacity: maxPath) { tbase in
                pathBytes.withUnsafeBufferPointer { src in
                    for i in 0..<src.count { tbase[i] = src[i] }
                }
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(listenerFD, sa, addrLen)
            }
        }
        if bindResult < 0 {
            let savedErrno = errno
            let msg = String(cString: strerror(savedErrno))
            close(listenerFD)
            unlink(socketPath)
            let failPayload = unixSocketListenerEventPayload(bound: false, path: socketPath)
            EventBus.shared.publish(kind: "server.listener", payload: .object(failPayload.mapValues { v -> JSONValue in
                if let b = v as? Bool { return .bool(b) }
                if let i = v as? Int { return .number(Double(i)) }
                if let s = v as? String { return .string(s) }
                return .string("\(v)")
            }))
            throw NSError(domain: "RemoteCode.Socket", code: Int(savedErrno), userInfo: [NSLocalizedDescriptionKey: "bind: \(msg)"])
        }
        // Establish same-user scope before the socket begins listening. A
        // permission failure is fatal; never expose the local IPC endpoint
        // with permissions inherited from the process umask.
        if chmod(socketPath, 0o600) < 0 {
            let savedErrno = errno
            let msg = String(cString: strerror(savedErrno))
            close(listenerFD)
            unlink(socketPath)
            throw NSError(
                domain: "RemoteCode.Socket",
                code: Int(savedErrno),
                userInfo: [NSLocalizedDescriptionKey: "chmod: \(msg)"]
            )
        }
        if Darwin.listen(listenerFD, 16) < 0 {
            let savedErrno = errno
            let msg = String(cString: strerror(savedErrno))
            close(listenerFD)
            unlink(socketPath)
            let failPayload = unixSocketListenerEventPayload(bound: false, path: socketPath)
            EventBus.shared.publish(kind: "server.listener", payload: .object(failPayload.mapValues { v -> JSONValue in
                if let b = v as? Bool { return .bool(b) }
                if let i = v as? Int { return .number(Double(i)) }
                if let s = v as? String { return .string(s) }
                return .string("\(v)")
            }))
            throw NSError(domain: "RemoteCode.Socket", code: Int(savedErrno), userInfo: [NSLocalizedDescriptionKey: "listen: \(msg)"])
        }
        lifecycleLock.lock()
        guard !startCancellationRequested else {
            lifecycleLock.unlock()
            close(listenerFD)
            unlink(socketPath)
            throw POSIXError(.ECANCELED)
        }
        listenFD = listenerFD
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        running = true
        starting = false
        lifecycleLock.unlock()
        committedStart = true

        let t = Thread { [weak self] in
            self?.acceptLoop(listenerFD: listenerFD, generation: generation)
        }
        t.name = "RC2.SocketAccept"
        t.start()
        lifecycleLock.lock()
        if running, lifecycleGeneration == generation {
            acceptThread = t
        }
        lifecycleLock.unlock()

        guard isRunning(generation: generation) else { return }

        // Publish success event so AppDelegate (or any observer) can surface
        // the server status without polling. Mirrors HTTPServer's pattern.
        let successPayload = unixSocketListenerEventPayload(bound: true, path: socketPath)
        EventBus.shared.publish(kind: "server.listener", payload: .object(successPayload.mapValues { v -> JSONValue in
            if let b = v as? Bool { return .bool(b) }
            if let i = v as? Int { return .number(Double(i)) }
            if let s = v as? String { return .string(s) }
            return .string("\(v)")
        }))
    }

    public func stop() {
        lifecycleLock.lock()
        guard !stopping else {
            lifecycleLock.unlock()
            return
        }
        stopping = true
        running = false
        if starting { startCancellationRequested = true }
        for fd in clientFDs { shutdown(fd, SHUT_RDWR) }
        let listenerFD = listenFD
        listenFD = -1
        lifecycleLock.unlock()
        if listenerFD >= 0 {
            shutdown(listenerFD, SHUT_RDWR)
            close(listenerFD)
        }
        unlink(socketPath)
        lifecycleLock.lock()
        stopping = false
        lifecycleLock.unlock()
    }

    private func acceptLoop(listenerFD: Int32, generation: UInt64) {
        while isRunning(generation: generation) {
            var clientAddr = sockaddr()
            var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listenerFD, &clientAddr, &clientLen)
            if client < 0 {
                if !isRunning(generation: generation) { return }
                continue
            }
            guard Self.enableCloseOnExec(client) else {
                close(client)
                continue
            }
            guard registerClient(client, generation: generation) else {
                shutdown(client, SHUT_RDWR)
                close(client)
                if isRunning(generation: generation) {
                    EventBus.shared.publish(kind: "diagnostic.unix_client_limit", payload: .object([
                        "max_clients": .number(Double(Self.maxConnectedClients))
                    ]))
                }
                continue
            }
            acceptedFDObserverForTesting?(client)
            disableSIGPIPE(fd: client)
            DispatchQueue.global().async { [weak self] in
                guard let self else {
                    shutdown(client, SHUT_RDWR)
                    close(client)
                    return
                }
                self.handleClient(fd: client, generation: generation)
            }
        }
    }

    private func isRunning(generation: UInt64) -> Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return running && lifecycleGeneration == generation
    }

    private func registerClient(_ fd: Int32, generation: UInt64) -> Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        guard running,
              lifecycleGeneration == generation,
              clientFDs.count < Self.maxConnectedClients else { return false }
        clientFDs.insert(fd)
        return true
    }

    private func releaseClient(_ fd: Int32) {
        lifecycleLock.lock()
        let wasOwned = clientFDs.remove(fd) != nil
        lifecycleLock.unlock()
        guard wasOwned else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    private func beginRequest(generation: UInt64) -> Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        guard running,
              lifecycleGeneration == generation,
              activeRequestCount < activeRequestLimit else { return false }
        activeRequestCount += 1
        return true
    }

    private func endRequest() {
        lifecycleLock.lock()
        activeRequestCount = max(0, activeRequestCount - 1)
        lifecycleLock.unlock()
    }

    private func disableSIGPIPE(fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    @discardableResult
    static func enableCloseOnExec(
        _ fd: Int32,
        getFlags: (Int32) -> Int32 = { fcntl($0, F_GETFD) },
        setFlags: (Int32, Int32) -> Int32 = { fcntl($0, F_SETFD, $1) }
    ) -> Bool {
        guard fd >= 0 else { return false }
        let flags = getFlags(fd)
        guard flags >= 0 else { return false }
        guard flags & FD_CLOEXEC == 0 else { return true }
        return setFlags(fd, flags | FD_CLOEXEC) == 0
    }

    private func handleClient(fd: Int32, generation: UInt64) {
        let streamSubscription = UnixStreamSubscriptionState()
        let outboundReference = UnixOutboundQueueReference()
        let outbound = WebSocketOutboundQueue(
            label: "rc2.unix.outbound",
            maxQueuedBytes: Self.maxStreamQueuedBytes,
            writer: { [weak self] data in
                self?.write(fd: fd, data: data) ?? false
            },
            onClose: { reason in
                if let subscription = streamSubscription.requestCleanup() {
                    EventBus.shared.unsubscribe(subscription)
                }
                let queuedBytes = outboundReference.value?.queuedByteCount ?? 0
                shutdown(fd, SHUT_RDWR)
                EventBus.shared.publish(kind: "diagnostic.unix_slow_client", payload: .object([
                    "reason": .string(reason),
                    "queued_bytes": .number(Double(queuedBytes)),
                    "max_queued_bytes": .number(Double(Self.maxStreamQueuedBytes))
                ]))
            }
        )
        outboundReference.value = outbound
        defer {
            if let subscription = streamSubscription.requestCleanup() {
                EventBus.shared.unsubscribe(subscription)
            }
            outbound.close()
            shutdown(fd, SHUT_RDWR)
            outbound.finish()
            releaseClient(fd)
        }
        var buffer = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while isRunning(generation: generation) {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            buffer.append(tmp, count: n)
            if buffer.count > Self.maxClientLineBytes {
                return
            }
            // process line-delimited JSON
            while let nlIdx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nlIdx)
                buffer.removeSubrange(buffer.startIndex...nlIdx)
                if lineData.isEmpty { continue }
                // Special-case events.stream so this connection becomes a
                // long-lived event feed instead of a single request/response.
                if let req = try? JSONDecoder().decode(JSONRPCRequest.self, from: lineData),
                   req.method == "events.stream" {
                    let since: Int64 = req.params?["after_seq"]?.intValue.map(Int64.init) ?? 0
                    if let existing = streamSubscription.removeCurrent() {
                        EventBus.shared.unsubscribe(existing)
                    }
                    // Queue the acknowledgement before subscribing. Any replay or
                    // live event delivered by subscribe is then serialized behind
                    // the ack instead of racing ahead of it.
                    let ack = JSONRPCResponse(id: req.id, result: .object([
                        "subscribed": .bool(true)
                    ]))
                    guard let ackData = encode(response: ack),
                          outbound.enqueue(ackData) == .accepted else {
                        _ = outbound.terminate(errorData: nil, closingData: nil, reason: "queue_full")
                        return
                    }
                    let id = EventBus.shared.subscribe(since: since) { [weak self] ev in
                        guard let self else { return }
                        guard !streamSubscription.isCleanupRequested else { return }
                        let payload: [String: JSONValue] = [
                            "seq": .number(Double(ev.seq)),
                            "kind": .string(ev.kind),
                            "ts": .number(ev.ts),
                            "payload": ev.payload
                        ]
                        let resp = JSONRPCResponse(id: req.id, result: .object(payload))
                        guard let data = self.encode(response: resp) else { return }
                        switch outbound.enqueue(data) {
                        case .accepted, .closed:
                            break
                        case .queueFull:
                            _ = outbound.terminate(errorData: nil, closingData: nil, reason: "queue_full")
                        }
                    }
                    guard streamSubscription.install(id) else {
                        EventBus.shared.unsubscribe(id)
                        return
                    }
                    continue
                }
                guard respond(
                    lineData: lineData,
                    outbound: outbound,
                    generation: generation
                ) else { return }
            }
        }
    }

    private func respond(
        lineData: Data,
        outbound: WebSocketOutboundQueue,
        generation: UInt64
    ) -> Bool {
        let decoder = JSONDecoder()
        do {
            let req = try decoder.decode(JSONRPCRequest.self, from: lineData)
            guard beginRequest(generation: generation) else {
                EventBus.shared.publish(kind: "diagnostic.unix_request_limit", payload: .object([
                    "max_active_requests": .number(Double(activeRequestLimit))
                ]))
                return false
            }
            let semaphore = DispatchSemaphore(value: 0)
            let slot = LockedUnixResponse()
            // The CommandRouting conformance is @preconcurrency, so the
            // compiler will not insert an actor hop when the dispatcher
            // calls a main-actor method. An explicit @MainActor Task keeps
            // every synchronous AppKit/SwiftUI call on the main actor.
            let task = Task { @MainActor in
                defer { self.endRequest() }
                let response: JSONRPCResponse
                if let localRequestHandlerForTesting {
                    response = await localRequestHandlerForTesting(req)
                } else {
                    response = await dispatcher.dispatchUnixSocket(req)
                }
                slot.value = response
                semaphore.signal()
            }
            let requestTimeout = req.method == "agent.message.send"
                ? agentMessageSendRequestTimeout
                : localRequestTimeout
            guard semaphore.wait(timeout: .now() + requestTimeout) == .success else {
                task.cancel()
                EventBus.shared.publish(kind: "diagnostic.unix_request_timeout", payload: .object([
                    "method": .string(req.method),
                    "timeout_seconds": .number(Self.timeoutSeconds(requestTimeout))
                ]))
                return false
            }
            if let resp = slot.value, let data = encode(response: resp) {
                _ = outbound.enqueue(data)
            }
            return true
        } catch {
            let resp = JSONRPCResponse(id: nil, error: .parseError)
            if let data = encode(response: resp) {
                _ = outbound.enqueue(data)
            }
            return true
        }
    }

    private static func timeoutSeconds(_ timeout: DispatchTimeInterval) -> Double {
        switch timeout {
        case .seconds(let value):
            return Double(value)
        case .milliseconds(let value):
            return Double(value) / 1_000
        case .microseconds(let value):
            return Double(value) / 1_000_000
        case .nanoseconds(let value):
            return Double(value) / 1_000_000_000
        case .never:
            return -1
        @unknown default:
            return 0
        }
    }

    private func encode(response: JSONRPCResponse) -> Data? {
        guard var data = try? JSONEncoder().encode(response) else { return nil }
        data.append(0x0A)
        return data
    }

    private func write(fd: Int32, data: Data) -> Bool {
        outboundWriteWillBeginForTesting?(data)
        var succeeded = true
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < data.count {
                let n = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if n < 0, errno == EINTR { continue }
                if n <= 0 {
                    succeeded = false
                    return
                }
                written += n
            }
        }
        return succeeded
    }
}

/// Coordinates the EventBus UUID with cleanup that can happen while
/// `subscribe` is still replaying synchronously. Without this handshake a
/// queue overflow can close the socket before `subscribe` returns, leaving
/// the UUID orphaned in EventBus.
private final class UnixStreamSubscriptionState: @unchecked Sendable {
    private let lock = NSLock()
    private var subscriptionID: UUID?
    private var cleanupRequested = false

    var isCleanupRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return cleanupRequested
    }

    func install(_ id: UUID) -> Bool {
        lock.lock()
        guard !cleanupRequested else {
            lock.unlock()
            return false
        }
        subscriptionID = id
        lock.unlock()
        return true
    }

    func requestCleanup() -> UUID? {
        lock.lock()
        cleanupRequested = true
        let id = subscriptionID
        subscriptionID = nil
        lock.unlock()
        return id
    }

    func removeCurrent() -> UUID? {
        lock.lock()
        let id = subscriptionID
        subscriptionID = nil
        lock.unlock()
        return id
    }
}

private final class UnixOutboundQueueReference: @unchecked Sendable {
    private let lock = NSLock()
    private weak var storage: WebSocketOutboundQueue?

    var value: WebSocketOutboundQueue? {
        get {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock(); storage = newValue; lock.unlock()
        }
    }
}

private final class LockedUnixResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: JSONRPCResponse?

    var value: JSONRPCResponse? {
        get {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock(); storage = newValue; lock.unlock()
        }
    }
}
