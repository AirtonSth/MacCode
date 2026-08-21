import XCTest
import Darwin
import CoreModel
@testable import Persistence

final class BotPeerRPCClientTests: XCTestCase {
    func test_existingPeerCallRoundTripsNewlineJSON() throws {
        // WHY: host catalog reuses the same client. Peer consultations must
        // still receive the JSON object result they already depend on.
        let server = try UnixEchoServer { request in
            XCTAssertEqual(request["method"] as? String, "bot.peer.list")
            let params = try XCTUnwrap(request["params"] as? [String: Any])
            XCTAssertEqual(params["thread_id"] as? String, Self.threadID)
            XCTAssertEqual(params["run_id"] as? String, Self.runID)
            XCTAssertEqual(params[BotPeerDelegation.capabilityRPCParameterKey] as? String, Self.capability)
            return #"{"jsonrpc":"2.0","id":1,"result":{"bots":[]}}"#
        }
        defer { server.stop() }
        let result = try BotPeerRPCClient(environment: Self.environment(socket: server.path)).call(
            method: "bot.peer.list",
            arguments: [:]
        )
        let object = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual((object["bots"] as? [Any])?.count, 0)
    }

    func test_connectFailureOnMissingSocket() {
        var closed: [Int32] = []
        var syscalls = Self.fakeConnectedSyscalls(closed: &closed)
        syscalls.connect = { _, _, _ in
            errno = ECONNREFUSED
            return -1
        }
        XCTAssertThrowsError(
            try BotPeerRPCClient(
                environment: Self.environment(socket: "/tmp/unused.sock"),
                syscalls: syscalls,
                timeoutOverride: 0.05
            ).call(method: "bot.list", arguments: [:], budget: .hostOperation)
        ) { error in
            guard case .socket = error as? BotPeerRPCError else {
                return XCTFail("expected socket failure, got \(error)")
            }
        }
        XCTAssertEqual(closed, [7])
    }

    func test_connectTimeoutWhenHandshakeNeverCompletes() {
        var closed: [Int32] = []
        var syscalls = Self.fakeConnectedSyscalls(closed: &closed)
        syscalls.connect = { _, _, _ in
            errno = EINPROGRESS
            return -1
        }
        syscalls.poll = { _, _, _ in 0 }
        XCTAssertThrowsError(
            try BotPeerRPCClient(
                environment: Self.environment(socket: "/tmp/unused.sock"),
                syscalls: syscalls,
                timeoutOverride: 0.05
            ).call(method: "bot.list", arguments: [:], budget: .hostOperation)
        ) { error in
            XCTAssertEqual(error as? BotPeerRPCError, .timeout("connect"))
        }
        XCTAssertEqual(closed, [7])
    }

    func test_acceptedWithoutNewlineTimesOutAndClosesFD() throws {
        var closed: [Int32] = []
        var syscalls = UnixDeadlineSyscalls.darwin
        let closeImpl = syscalls.close
        syscalls.close = { fd in
            closed.append(fd)
            return closeImpl(fd)
        }
        let server = try UnixEchoServer { _ in
            nil
        }
        defer { server.stop() }
        XCTAssertThrowsError(
            try BotPeerRPCClient(
                environment: Self.environment(socket: server.path),
                syscalls: syscalls,
                timeoutOverride: 0.05
            ).call(method: "bot.list", arguments: [:], budget: .hostOperation)
        ) { error in
            XCTAssertEqual(error as? BotPeerRPCError, .timeout("read"))
        }
        XCTAssertFalse(closed.isEmpty, "the client FD must close after a hung newline read")
    }

    func test_oversizeReplyWithoutNewlineIsRejected() throws {
        let oversized = String(repeating: "x", count: BotPeerRPCClient.maximumResponseBytes + 8)
        let server = try UnixEchoServer { _ in oversized }
        defer { server.stop() }
        XCTAssertThrowsError(
            try BotPeerRPCClient(environment: Self.environment(socket: server.path)).call(
                method: "bot.list",
                arguments: [:],
                budget: .hostOperation
            )
        ) { error in
            XCTAssertEqual(error as? BotPeerRPCError, .invalidResponse)
        }
    }

    func test_stalledWriteTimesOutAndCleansUp() throws {
        var closed: [Int32] = []
        var syscalls = Self.fakeConnectedSyscalls(closed: &closed)
        syscalls.write = { _, _, _ in
            errno = EAGAIN
            return -1
        }
        syscalls.poll = { fds, _, _ in
            fds.pointee.revents = fds.pointee.events
            return 1
        }
        XCTAssertThrowsError(
            try BotPeerRPCClient(
                environment: Self.environment(socket: "/tmp/unused.sock"),
                syscalls: syscalls,
                timeoutOverride: 0.05
            ).call(method: "bot.list", arguments: [:], budget: .hostOperation)
        ) { error in
            XCTAssertEqual(error as? BotPeerRPCError, .timeout("write"))
        }
        XCTAssertEqual(closed, [7])
    }

    func test_pollEINTRRetriesThenSucceeds() throws {
        var pollCalls = 0
        var syscalls = UnixDeadlineSyscalls.darwin
        let pollImpl = syscalls.poll
        syscalls.poll = { fds, n, timeout in
            pollCalls += 1
            if pollCalls == 1 {
                errno = EINTR
                return -1
            }
            return pollImpl(fds, n, timeout)
        }
        let server = try UnixEchoServer { _ in
            #"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#
        }
        defer { server.stop() }
        let result = try BotPeerRPCClient(
            environment: Self.environment(socket: server.path),
            syscalls: syscalls
        ).call(method: "bot.list", arguments: [:], budget: .hostOperation)
        let object = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertGreaterThanOrEqual(pollCalls, 2)
    }

    func test_hostCatalogClientDeadlineStrictlyOutlivesUnixServerDeadline() {
        // WHY: packaged Claude Bot E2E lost rc_bot_skill_create/view when both
        // Unix ends used 5s. The MCP child must keep waiting after the host's
        // bounded catalog deadline so a still-running MainActor hop is not
        // reported as a client timeout. Ordinary local RPC stays untouched.
        XCTAssertGreaterThan(
            RemoteCodeHostCatalog.unixClientDeadline,
            RemoteCodeHostCatalog.unixServerDeadline,
            "client catalog deadline must strictly outlive the Unix server deadline"
        )
        XCTAssertEqual(
            BotPeerDelegation.hostOperationTimeout,
            RemoteCodeHostCatalog.unixClientDeadline,
            "host-catalog RPC client budget is the catalog client deadline"
        )
        XCTAssertEqual(
            BotPeerRPCClient.Budget.hostOperation.timeout,
            RemoteCodeHostCatalog.unixClientDeadline
        )
        XCTAssertGreaterThan(
            RemoteCodeHostCatalog.unixServerDeadline,
            5,
            "catalog Unix hops need a bounded extension past the ordinary 5s local RPC"
        )
        XCTAssertEqual(
            Set(RemoteCodeHostCatalog.rpcMethods.map { RemoteCodeHostCatalog.usesUnixCatalogDeadline($0) }),
            [true],
            "every finite host-catalog RPC must use the catalog Unix deadline"
        )
        XCTAssertFalse(RemoteCodeHostCatalog.usesUnixCatalogDeadline("workspace.list"))
        XCTAssertFalse(RemoteCodeHostCatalog.usesUnixCatalogDeadline("agent.message.send"))
        XCTAssertFalse(RemoteCodeHostCatalog.usesUnixCatalogDeadline("bot.peer.ask"))
    }

    func test_missingCapabilityIsStillInjectedAsAbsentHiddenParam() throws {
        let server = try UnixEchoServer { request in
            let params = try XCTUnwrap(request["params"] as? [String: Any])
            XCTAssertNil(params[BotPeerDelegation.capabilityRPCParameterKey])
            return #"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#
        }
        defer { server.stop() }
        var environment = Self.environment(socket: server.path)
        environment.removeValue(forKey: BotPeerDelegation.capabilityEnvironmentKey)
        _ = try BotPeerRPCClient(environment: environment).call(
            method: "bot.list",
            arguments: [:],
            budget: .hostOperation
        )
    }

    private static let threadID = "11111111-2222-3333-4444-555555555555"
    private static let runID = "66666666-7777-8888-9999-aaaaaaaaaaaa"
    private static let capability = String(repeating: "ab", count: 32)

    private static func environment(socket: String) -> [String: String] {
        [
            BotPeerDelegation.socketEnvironmentKey: socket,
            BotPeerDelegation.threadEnvironmentKey: threadID,
            BotPeerDelegation.runEnvironmentKey: runID,
            BotPeerDelegation.capabilityEnvironmentKey: capability,
        ]
    }

    private static func fakeConnectedSyscalls(closed: UnsafeMutablePointer<[Int32]>) -> UnixDeadlineSyscalls {
        var syscalls = UnixDeadlineSyscalls.darwin
        syscalls.socket = { _, _, _ in 7 }
        syscalls.fcntlGet = { _ in 0 }
        syscalls.fcntlSetNonblocking = { _, _ in 0 }
        syscalls.disableSIGPIPE = { _ in 0 }
        syscalls.connect = { _, _, _ in 0 }
        syscalls.getSocketError = { _ in 0 }
        syscalls.close = { fd in
            closed.pointee.append(fd)
            return 0
        }
        return syscalls
    }
}

private final class UnixEchoServer {
    let path: String
    private let listenFD: Int32
    private var thread: Thread?

    init(_ handler: @escaping ([String: Any]) throws -> String?) throws {
        path = NSTemporaryDirectory() + "rc-peer-rpc-\(UUID().uuidString).sock"
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw BotPeerRPCError.socket("listen socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                path.withCString { src in strncpy(dest, src, 103) }
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(listenFD, 1) == 0 else {
            Darwin.close(listenFD)
            throw BotPeerRPCError.socket("bind/listen")
        }
        let fd = listenFD
        thread = Thread {
            var client = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let accepted = withUnsafeMutablePointer(to: &client) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(fd, $0, &length)
                }
            }
            guard accepted >= 0 else { return }
            defer { Darwin.close(accepted) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while data.last != 0x0A {
                let count = Darwin.read(accepted, &buffer, buffer.count)
                if count <= 0 { return }
                data.append(buffer, count: count)
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            guard let reply = try? handler(object) else {
                Thread.sleep(forTimeInterval: 0.2)
                return
            }
            var payload = Data(reply.utf8)
            if payload.last != 0x0A { payload.append(0x0A) }
            _ = payload.withUnsafeBytes { raw in
                Darwin.write(accepted, raw.baseAddress!, payload.count)
            }
        }
        thread?.start()
    }

    func stop() {
        Darwin.close(listenFD)
        unlink(path)
        thread?.cancel()
    }
}
