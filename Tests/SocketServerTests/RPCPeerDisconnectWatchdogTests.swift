import Darwin
import XCTest
@testable import SocketServer

/// C9: the in-flight `/v1/rpc` watchdog is a read source instead of a 5 ms
/// MSG_PEEK poll. These pin what the poll guaranteed: a peer that goes away
/// cancels the work and releases the socket (once), a live peer is never
/// cancelled, and a pipelined request is left for the keep-alive reader.
final class RPCPeerDisconnectWatchdogTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func socketPair() throws -> (host: Int32, peer: Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw NSError(domain: "socketpair", code: Int(errno))
        }
        return (fds[0], fds[1])
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(1_000)
        }
        return condition()
    }

    /// Immediate path: the peer closes mid-RPC, the host learns at once
    /// (no poll interval) and runs the release exactly once.
    func test_peerClose_firesDisconnectOnce() async throws {
        let (host, peer) = try socketPair()
        defer { close(host) }
        let fired = Counter()
        let watchdog = RPCPeerDisconnectWatchdog(fd: host, isOwned: { true }) { fired.increment() }
        let started = DispatchTime.now()
        close(peer)
        XCTAssertTrue(waitUntil(1) { fired.count == 1 }, "a closed peer must cancel the in-flight RPC")
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        XCTAssertLessThan(elapsedMs, 500)
        await watchdog.stop()
        XCTAssertEqual(fired.count, 1, "release must run exactly once even when stop follows")
    }

    /// Eventual completion with a live peer: the RPC finishes, stop() returns,
    /// and the connection is never treated as gone.
    func test_livePeer_stopNeverFiresDisconnect() async throws {
        let (host, peer) = try socketPair()
        defer { close(host); close(peer) }
        let fired = Counter()
        let watchdog = RPCPeerDisconnectWatchdog(fd: host, isOwned: { true }) { fired.increment() }
        try await Task.sleep(nanoseconds: 50_000_000)
        await watchdog.stop()
        XCTAssertEqual(fired.count, 0)
        // After stop the fd is the caller's again: closing the peer now must
        // not reach the stopped watchdog.
        close(peer)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fired.count, 0)
    }

    /// A pipelined request arrives while the RPC runs. The watchdog must not
    /// read it (the keep-alive reader owns those bytes) or call it a
    /// disconnect, and it must stop watching rather than spin on a readable fd.
    func test_pipelinedBytes_areLeftForTheReaderAndNotADisconnect() async throws {
        let (host, peer) = try socketPair()
        defer { close(host); close(peer) }
        let fired = Counter()
        let watchdog = RPCPeerDisconnectWatchdog(fd: host, isOwned: { true }) { fired.increment() }
        let request = Array("POST /v1/rpc HTTP/1.1\r\n".utf8)
        XCTAssertEqual(write(peer, request, request.count), request.count)
        try await Task.sleep(nanoseconds: 50_000_000)
        await watchdog.stop()
        XCTAssertEqual(fired.count, 0)
        var buffer = [UInt8](repeating: 0, count: 64)
        let read = recv(host, &buffer, buffer.count, MSG_DONTWAIT)
        XCTAssertEqual(read, request.count, "the pipelined bytes must still be in the socket")
    }

    /// Revoke and server stop `shutdown(SHUT_RDWR)` the descriptor from
    /// another thread. That must cancel the RPC the same way a peer close does.
    func test_hostSideShutdown_firesDisconnect() async throws {
        let (host, peer) = try socketPair()
        defer { close(host); close(peer) }
        let fired = Counter()
        let watchdog = RPCPeerDisconnectWatchdog(fd: host, isOwned: { true }) { fired.increment() }
        shutdown(host, SHUT_RDWR)
        XCTAssertTrue(waitUntil(1) { fired.count == 1 })
        await watchdog.stop()
        XCTAssertEqual(fired.count, 1)
    }

    /// Failure path: the registry no longer owns the descriptor (it was
    /// released elsewhere). Any wake must treat the RPC as abandoned.
    func test_unownedDescriptor_firesDisconnectOnWake() async throws {
        let (host, peer) = try socketPair()
        defer { close(host); close(peer) }
        let fired = Counter()
        let watchdog = RPCPeerDisconnectWatchdog(fd: host, isOwned: { false }) { fired.increment() }
        let byte: [UInt8] = [0x50]
        XCTAssertEqual(write(peer, byte, 1), 1)
        XCTAssertTrue(waitUntil(1) { fired.count == 1 })
        await watchdog.stop()
        XCTAssertEqual(fired.count, 1)
    }

    /// End to end on the real server: an RPC is stuck behind a blocked main
    /// actor, the client drops, and the host releases the socket while main is
    /// still blocked. Afterwards the server keeps serving.
    @MainActor
    func test_httpRPC_peerDropWhileMainBlocked_releasesSocket() async throws {
        let router = FakeRouter()
        var server: DirectHTTPServer?
        var port: UInt16 = 0
        for _ in 0..<20 {
            port = UInt16.random(in: 33_000...44_000)
            let candidate = DirectHTTPServer(
                port: port,
                loopbackOnly: true,
                dispatcher: JSONRPCDispatcher(router: router),
                bootEpoch: 1
            )
            if (try? candidate.start()) != nil { server = candidate; break }
        }
        let live = try XCTUnwrap(server)
        defer { live.stop() }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let body = #"{"jsonrpc":"2.0","id":1,"method":"system.ping"}"#
        let request = "POST /v1/rpc HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let bytes = Array(request.utf8)
        XCTAssertEqual(write(fd, bytes, bytes.count), bytes.count)
        // Main stays blocked from here until the socket is released, so the
        // RPC cannot finish on its own.
        XCTAssertTrue(waitUntil(1) { live.acceptedSocketCountForTests == 1 })
        usleep(50_000)
        close(fd)
        XCTAssertTrue(
            waitUntil(1) { live.acceptedSocketCountForTests == 0 },
            "a dropped peer must release the socket while the RPC is still waiting on main"
        )

        var ping = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
        ping.httpMethod = "POST"
        ping.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ping.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: ping)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("pong"))
    }
}
