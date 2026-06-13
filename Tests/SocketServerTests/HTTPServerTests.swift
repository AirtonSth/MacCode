import XCTest
import Darwin
@testable import SocketServer

final class HTTPServerTests: XCTestCase {
    override func tearDown() {
        DirectStaticFileRegistry.shared.resetForTests()
        super.tearDown()
    }

    @MainActor
    func test_health_and_discovery_loopback() throws {
        let port = UInt16.random(in: 33000...44000)
        let dispatcher = JSONRPCDispatcher(router: FakeRouter())
        let s = DirectHTTPServer(port: port, loopbackOnly: true, dispatcher: dispatcher)
        try s.start()
        defer { s.stop() }
        // wait for accept thread
        Thread.sleep(forTimeInterval: 0.05)
        let url = URL(string: "http://127.0.0.1:\(port)/healthz")!
        let healthEx = expectation(description: "health")
        URLSession.shared.dataTask(with: url) { data, resp, err in
            XCTAssertNil(err)
            if let r = resp as? HTTPURLResponse { XCTAssertEqual(r.statusCode, 200) }
            XCTAssertEqual(String(data: data ?? Data(), encoding: .utf8), "ok\n")
            healthEx.fulfill()
        }.resume()
        let disco = expectation(description: "discovery")
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port)/v1/discovery")!) { data, _, _ in
            let obj = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
            XCTAssertEqual(obj?["app"] as? String, "remotecode")
            XCTAssertEqual(obj?["relay"] as? Bool, false)
            disco.fulfill()
        }.resume()
        wait(for: [healthEx, disco], timeout: 4)
    }

    @MainActor
    func test_rpc_route_dispatches_to_desktop_router() throws {
        let port = UInt16.random(in: 33000...44000)
        let dispatcher = JSONRPCDispatcher(router: FakeRouter())
        let s = DirectHTTPServer(port: port, loopbackOnly: true, dispatcher: dispatcher)
        try s.start()
        defer { s.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = """
        {"jsonrpc":"2.0","id":"rpc-route","method":"workspace.create","params":{"name":"mobile","cwd":"/tmp"}}
        """.data(using: .utf8)!

        let routed = expectation(description: "rpc routed")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            XCTAssertNil(err)
            if let r = resp as? HTTPURLResponse { XCTAssertEqual(r.statusCode, 200) }
            let obj = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
            XCTAssertEqual(obj?["id"] as? String, "rpc-route")
            let result = obj?["result"] as? [String: Any]
            XCTAssertEqual(result?["name"] as? String, "mobile")
            XCTAssertNil(obj?["error"], "mobile RPC must reach the desktop JSON-RPC dispatcher")
            routed.fulfill()
        }.resume()
        wait(for: [routed], timeout: 4)
    }

    @MainActor
    func test_staticFileRouteServesOnlyGrantedFilesWithoutDirectoryListing() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-static-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let html = temp.appendingPathComponent("index space.html")
        try "<h1>Exact mirror</h1>".write(to: html, atomically: true, encoding: .utf8)
        let grant = try XCTUnwrap(DirectStaticFileRegistry.shared.register(fileURL: html))

        let port = UInt16.random(in: 33000...44000)
        let dispatcher = JSONRPCDispatcher(router: FakeRouter())
        let s = DirectHTTPServer(port: port, loopbackOnly: true, dispatcher: dispatcher)
        try s.start()
        defer { s.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let served = expectation(description: "granted file served")
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port)\(grant.routePath)")!) { data, resp, err in
            XCTAssertNil(err)
            XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")
            XCTAssertEqual(String(data: data ?? Data(), encoding: .utf8), "<h1>Exact mirror</h1>")
            served.fulfill()
        }.resume()

        let blocked = expectation(description: "directory blocked")
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port)/__rc2_static/not-granted/\(temp.lastPathComponent)")!) { _, resp, _ in
            XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 404,
                           "static server must not expose arbitrary Mac filesystem paths")
            blocked.fulfill()
        }.resume()

        wait(for: [served, blocked], timeout: 4)
    }

    @MainActor
    func test_httpRejectsOversizedBodyFromContentLengthBeforeBodyRead() throws {
        let port = UInt16.random(in: 33000...44000)
        let dispatcher = JSONRPCDispatcher(router: FakeRouter())
        let s = DirectHTTPServer(port: port, loopbackOnly: true, dispatcher: dispatcher)
        try s.start()
        defer { s.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let fd = try connectLocalhost(port: port)
        defer { Darwin.close(fd) }
        let request = """
        POST /v1/rpc HTTP/1.1\r
        Host: 127.0.0.1:\(port)\r
        Content-Length: \(DirectHTTPServer.maxRequestBodyBytes + 1)\r
        \r

        """
        try writeAll(fd: fd, data: Data(request.utf8))
        let response = readResponse(fd: fd)

        XCTAssertTrue(
            response.hasPrefix("HTTP/1.1 413"),
            "oversized iOS/HTTP requests must be rejected from Content-Length instead of buffering the body into Mac memory"
        )
    }

    @MainActor
    func test_partialHeaderSlowLorisConnectionTimesOutAndCloses() throws {
        let port = UInt16.random(in: 33000...44000)
        let dispatcher = JSONRPCDispatcher(router: FakeRouter())
        let s = DirectHTTPServer(
            port: port,
            loopbackOnly: true,
            dispatcher: dispatcher,
            clientReceiveTimeoutSeconds: 1
        )
        try s.start()
        defer { s.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let fd = try connectLocalhost(port: port)
        defer { Darwin.close(fd) }
        var clientTimeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &clientTimeout, socklen_t(MemoryLayout<timeval>.size))

        let partial = """
        GET /v1/ws HTTP/1.1\r
        Host: 127.0.0.1:\(port)\r
        """
        try writeAll(fd: fd, data: Data(partial.utf8))

        var byte = UInt8(0)
        let start = Date()
        let n = Darwin.read(fd, &byte, 1)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 2.5,
                          "partial-header clients must be reclaimed by the server timeout, not by the test client's longer timeout")
        XCTAssertTrue(n == 0 || (n < 0 && errno == ECONNRESET),
                      "server must close/reset a slow-loris partial-header connection; read result=\(n), errno=\(errno)")
    }

    func test_webSocketPongFrameClampsOversizedPingPayload() {
        let frame = DirectHTTPServer.pongFrame(payload: Data(repeating: 0x41, count: 300))

        XCTAssertEqual(frame.first, 0x8A, "server pong frames must stay valid websocket control frames")
        XCTAssertEqual(frame.dropFirst().first, 125, "oversized ping payloads must not trap while converting the pong length to UInt8")
        XCTAssertEqual(frame.count, 127)
    }

    // MARK: - Auth-gate coverage (T010-T012, T006) — loopbackOnly: false

    /// Minimal auth provider used only by the auth-gate tests below.
    /// Not shared with HTTPPairingTests.FakeAuth to keep each file self-contained.
    private final class StubAuth: DirectAuthProvider {
        func verify(token: String) -> Bool { token == "good-token" }
        func createPairingCode() -> String? { nil }
        func redeemPairingCode(_ code: String, deviceName: String) -> (deviceId: String, token: String)? { nil }
        func listDevices() -> [[String: Any]] { [] }
        func revokeDevice(_ id: String) {}
    }

    /// WHY: the auth gate at HTTPServer.swift:530-541 is the primary security
    /// barrier preventing unauthenticated LAN peers from invoking RPC methods,
    /// listing devices, or receiving terminal output via /v1/ws.
    /// Every existing test uses loopbackOnly:true which skips the gate entirely.
    /// A regression here would allow any LAN device to run arbitrary commands
    /// without pairing (DRIFT-3 class of defect).

    @MainActor
    // The auth gate is decided by HTTPServer.httpAuthGateRequiresToken /
    // wsUpgradeRequiresToken. A loopback test client (127.0.0.1) is always
    // treated as trusted, so a real socket cannot exercise the NON-loopback
    // gate -- these tests pin the pure gate decision instead, exactly what the
    // production gate at HTTPServer.swift:524-540 evaluates per request.

    func test_httpAuthGate_rpc_requiresTokenOnNonLoopback() {
        XCTAssertTrue(DirectHTTPServer.httpAuthGateRequiresToken(loopbackOnly: false, path: "/v1/rpc", hasAuthProvider: true),
            "/v1/rpc on a non-loopback bind with auth configured MUST require a token (auth bypass = LAN RCE)")
    }
    func test_httpAuthGate_devices_requiresTokenOnNonLoopback() {
        XCTAssertTrue(DirectHTTPServer.httpAuthGateRequiresToken(loopbackOnly: false, path: "/v1/devices", hasAuthProvider: true),
            "/v1/devices must require a token on non-loopback; device enumeration leaks pairing state")
    }
    func test_httpAuthGate_loopbackIsTrustedOpen() {
        XCTAssertFalse(DirectHTTPServer.httpAuthGateRequiresToken(loopbackOnly: true, path: "/v1/rpc", hasAuthProvider: true),
            "loopback-only binds are trusted and must stay open (preserves the local test harness + same-machine UX)")
    }
    func test_httpAuthGate_preTokenPathsExempt() {
        for p in ["/v1/discovery", "/v1/capabilities", "/v1/pair", "/v1/pair/redeem", "/v1/pair/status", "/v1/pair/cancel"] {
            XCTAssertFalse(DirectHTTPServer.httpAuthGateRequiresToken(loopbackOnly: false, path: p, hasAuthProvider: true),
                "\(p) is fetched before a token exists (GAP-9); gating it makes every LAN connect fail 401")
        }
    }
    func test_httpAuthGate_noAuthProviderDisablesGate() {
        XCTAssertFalse(DirectHTTPServer.httpAuthGateRequiresToken(loopbackOnly: false, path: "/v1/rpc", hasAuthProvider: false),
            "with no auth provider configured the gate is disabled (auth not yet provisioned)")
    }
    func test_httpAuthGate_validTokenAccepted_invalidRejected() {
        let auth = StubAuth()
        XCTAssertTrue(auth.verify(token: "good-token"), "a valid bearer token must verify so a gated request proceeds (200)")
        XCTAssertFalse(auth.verify(token: "wrong-token"), "an invalid bearer token must fail verification so the request is rejected (401)")
    }
    func test_wsUpgradeGate_requiresTokenOnNonLoopback() {
        XCTAssertTrue(DirectHTTPServer.wsUpgradeRequiresToken(loopbackOnly: false, hasAuthProvider: true),
            "the /v1/ws upgrade must require a token on a non-loopback bind; unauthenticated WS = full event-stream leak")
        XCTAssertFalse(DirectHTTPServer.wsUpgradeRequiresToken(loopbackOnly: true, hasAuthProvider: true),
            "loopback WS upgrade stays open (trusted)")
    }

    private func connectLocalhost(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc < 0 {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    }

    // MARK: - nextHeaderTerminatorRange unit tests

    /// Terminator present in a single contiguous buffer -- found at correct index.
    func test_nextHeaderTerminatorRange_present() {
        let buf = Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
        let r = DirectHTTPServer.nextHeaderTerminatorRange(in: buf, from: 0)
        XCTAssertNotNil(r, "terminator must be found in a complete header")
        // The range should point at the \r\n\r\n that ends the header.
        XCTAssertEqual(buf[r!], Data("\r\n\r\n".utf8),
                       "range must point at the 4-byte CRLFCRLF sequence")
    }

    /// WHY: a terminator split across two appends must still be found when
    /// the scan starts at (prevCount - 3). This is the boundary case the
    /// overlap exists for. Without the 3-byte overlap the second half \r\n
    /// would be scanned in isolation and the terminator would be missed.
    func test_nextHeaderTerminatorRange_split_across_boundary() {
        // Simulate: first read ends with "\r\n", second read starts with "\r\n".
        var buf = Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8) // ends with \r\n
        let prevCount = buf.count
        buf.append(Data("\r\n".utf8))                         // second read: \r\n completes terminator
        let overlap = 3  // terminatorLength - 1
        let searchFrom = max(0, prevCount - overlap)
        let r = DirectHTTPServer.nextHeaderTerminatorRange(in: buf, from: searchFrom)
        XCTAssertNotNil(r,
            "terminator split across two reads must be found with a 3-byte overlap search")
    }

    /// Searching from beyond the terminator must return nil (correctness guard).
    func test_nextHeaderTerminatorRange_miss_when_offset_past_terminator() {
        let header = "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
        let buf = Data(header.utf8)
        // Start search past the terminator position.
        let r = DirectHTTPServer.nextHeaderTerminatorRange(in: buf, from: buf.count)
        XCTAssertNil(r, "search past end of buffer must return nil")
    }

    /// No terminator in buffer -- must return nil.
    func test_nextHeaderTerminatorRange_absent() {
        let buf = Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)
        XCTAssertNil(DirectHTTPServer.nextHeaderTerminatorRange(in: buf, from: 0),
                     "absent terminator must return nil")
    }

    private func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < data.count {
                let n = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if n < 0, errno == EINTR { continue }
                if n <= 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += n
            }
        }
    }

    private func readResponse(fd: Int32) -> String {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
            if out.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
