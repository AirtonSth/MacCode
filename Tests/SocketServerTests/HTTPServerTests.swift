import XCTest
import Darwin
import CoreModel
import Persistence
@testable import SocketServer

@MainActor
private final class HTTPAttachmentReceiptRouter: FakeRouter, CommandReceiptStateRouting {
    func claimCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws -> CommandReceiptClaimResult {
        .claimed
    }

    func commitCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        result: JSONValue
    ) throws {}

    func finalizeCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        result: JSONValue,
        events: [EventBus.MutationEventIntent],
        minimumEventSequence: Int64
    ) throws -> [EventBus.Event] {
        events.enumerated().map { ordinal, event in
            EventBus.Event(
                seq: minimumEventSequence + Int64(ordinal) + 1,
                kind: event.kind,
                payload: event.payload,
                ts: event.createdAt.timeIntervalSince1970
            )
        }
    }

    func markCommandReceiptUnknown(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws {}

    func commandReceiptStatus(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String
    ) throws -> CommandReceiptStatusResult {
        .absent
    }
}

final class HTTPServerTests: XCTestCase {
    override func tearDown() {
        DirectStaticFileRegistry.shared.resetForTests()
        super.tearDown()
    }

    // MARK: - urlHostLiteral / endpointURLString (IPv6 zone-id URL hosts)

    func test_urlHostLiteral_encodes_bracketed_ipv6_zone_id() {
        // WHY: Link-local peers arrive already-bracketed from some callers;
        // bare `%en0` is illegal in a URL host and must become `%25en0`.
        XCTAssertEqual(urlHostLiteral("[fe80::1%en0]"), "[fe80::1%25en0]")
        XCTAssertEqual(
            endpointURLString(scheme: "http", host: "[fe80::1%en0]", port: 18217),
            "http://[fe80::1%25en0]:18217/"
        )
    }

    func test_urlHostLiteral_does_not_double_encode_percent25_zone() {
        // WHY: Re-encoding `%25` → `%2525` breaks already-correct URL hosts and
        // would make dual-stack / AWDL discovery strings unroutable.
        XCTAssertEqual(urlHostLiteral("[fe80::1%25en0]"), "[fe80::1%25en0]")
        XCTAssertEqual(urlHostLiteral("fe80::1%25en0"), "[fe80::1%25en0]")
    }

    func test_urlHostLiteral_preserves_global_and_plain_bracketed_ipv6() {
        // WHY: Global unicast and already-correct bracketed hosts must pass
        // through without invented zone IDs or extra percent sequences.
        XCTAssertEqual(urlHostLiteral("[2001:db8::1]"), "[2001:db8::1]")
        XCTAssertEqual(urlHostLiteral("2001:db8::1"), "[2001:db8::1]")
        XCTAssertEqual(urlHostLiteral("fe80::1%en0"), "[fe80::1%25en0]")
        XCTAssertEqual(urlHostLiteral("127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(urlHostLiteral("localhost"), "localhost")
        XCTAssertEqual(
            endpointURLString(scheme: "ws", host: "2001:db8::1", port: 443, path: "/v1/ws"),
            "ws://[2001:db8::1]:443/v1/ws"
        )
    }

    @MainActor
    func test_health_and_discovery_loopback() throws {
        let port = UInt16.random(in: 33000...44000)
        let dispatcher = JSONRPCDispatcher(router: FakeRouter())
        let s = DirectHTTPServer(port: port, loopbackOnly: true, dispatcher: dispatcher, bootEpoch: 1)
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
            // boot_epoch is the process generation iOS compares before bearer catch-up RPC.
            XCTAssertEqual(obj?["boot_epoch"] as? Int, 1,
                           "GET /v1/discovery must advertise server bootEpoch")
            disco.fulfill()
        }.resume()
        wait(for: [healthEx, disco], timeout: 4)
    }

    @MainActor
    func test_v1HealthReportsOnlyAggregateCommandReceiptMetrics() throws {
        let port = UInt16.random(in: 33000...44000)
        let metrics = CommandReceiptMetrics()
        metrics.recordClaim(.claimed, latencyMilliseconds: 2)
        metrics.recordUnknownOutcome()
        metrics.recordFinalization(success: false, latencyMilliseconds: 3)
        let dispatcher = JSONRPCDispatcher(router: FakeRouter(), commandReceiptMetrics: metrics)
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: true,
            dispatcher: dispatcher,
            bootEpoch: 1
        )
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let response = expectation(description: "receipt health metrics")
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port)/v1/health")!) { data, httpResponse, error in
            XCTAssertNil(error)
            XCTAssertEqual((httpResponse as? HTTPURLResponse)?.statusCode, 200)
            let body = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
            let receipts = body?["command_receipts"] as? [String: Any]
            XCTAssertEqual(receipts?["claims_total"] as? Int, 1)
            XCTAssertEqual(receipts?["new_claims_total"] as? Int, 1)
            XCTAssertEqual(receipts?["unknown_outcomes_total"] as? Int, 1)
            let finalization = receipts?["finalization"] as? [String: Any]
            XCTAssertEqual(finalization?["failure_total"] as? Int, 1)
            let encoded = String(data: data ?? Data(), encoding: .utf8) ?? ""
            for forbidden in ["client_request_id", "owner_fingerprint", "params_hash", "result_json"] {
                XCTAssertFalse(encoded.contains(forbidden), "health metrics must not expose \(forbidden)")
            }
            response.fulfill()
        }.resume()
        wait(for: [response], timeout: 4)
    }

    @MainActor
    func test_rpc_route_dispatches_to_desktop_router() throws {
        let port = UInt16.random(in: 33000...44000)
        let router = FakeRouter()
        router.workspaces = [Workspace.empty(name: "mobile", cwd: "/tmp")]
        let dispatcher = JSONRPCDispatcher(router: router)
        let s = DirectHTTPServer(port: port, loopbackOnly: true, dispatcher: dispatcher, bootEpoch: 1)
        try s.start()
        defer { s.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = """
        {"jsonrpc":"2.0","id":"rpc-route","method":"workspace.list","params":{}}
        """.data(using: .utf8)!

        let routed = expectation(description: "rpc routed")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            XCTAssertNil(err)
            if let r = resp as? HTTPURLResponse { XCTAssertEqual(r.statusCode, 200) }
            let obj = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
            XCTAssertEqual(obj?["id"] as? String, "rpc-route")
            let result = obj?["result"] as? [[String: Any]]
            XCTAssertEqual(result?.first?["name"] as? String, "mobile")
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
        let s = DirectHTTPServer(port: port, loopbackOnly: true, dispatcher: dispatcher, bootEpoch: 1)
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
        let s = DirectHTTPServer(port: port, loopbackOnly: true, dispatcher: dispatcher, bootEpoch: 1)
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
    func test_attachmentUploadEnvelopeCarriesExact25MBAndRejectsNextDecodedByte() async throws {
        // WHY: normal RPCs stay capped at 2 MiB, but the authenticated upload
        // envelope must carry the advertised 25 MiB after base64 expansion.
        let port = UInt16.random(in: 33000...44000)
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: HTTPAttachmentReceiptRouter()),
            serverId: "attachment-boundary-host",
            bootEpoch: 1
        )
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 50_000_000)

        var socketRequest = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
        socketRequest.setValue("\(EventBus.shared.currentSeq)", forHTTPHeaderField: "x-rc2-since-seq")
        let socket = URLSession.shared.webSocketTask(with: socketRequest)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let welcomeMessage = try await socket.receive()
        let welcomeData: Data
        switch welcomeMessage {
        case .data(let data): welcomeData = data
        case .string(let string): welcomeData = Data(string.utf8)
        @unknown default: throw URLError(.cannotDecodeContentData)
        }
        let welcome = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: welcomeData) as? [String: Any]
        )
        let connectionId = try XCTUnwrap(welcome["connectionId"] as? String)

        func response(decodedByteCount: Int, requestId: String) async throws -> (Data, HTTPURLResponse) {
            let payload = Data(repeating: 0x41, count: decodedByteCount).base64EncodedString()
            let json: [String: Any] = [
                "jsonrpc": "2.0",
                "id": requestId,
                "method": "agent.attachment.upload",
                "params": [
                    "client_request_id": requestId,
                    "connection_id": connectionId,
                    "expected_host_id": "attachment-boundary-host",
                    "expected_boot_epoch": 1,
                    "workspace_id": UUID().uuidString,
                    "filename": "boundary.bin",
                    "data_base64": payload
                ]
            ]
            let body = try JSONSerialization.data(withJSONObject: json)
            let compressed = try PayloadCodec.lzfse.encode(body)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(PayloadCodec.lzfse.wireName, forHTTPHeaderField: "Content-Encoding")
            request.setValue("1", forHTTPHeaderField: "X-RemoteCode-Attachment-Upload")
            request.httpBody = compressed
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, try XCTUnwrap(response as? HTTPURLResponse))
        }

        let exact = try await response(decodedByteCount: 25 * 1024 * 1024, requestId: "exact")
        XCTAssertEqual(exact.1.statusCode, 200)
        let exactJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: exact.0) as? [String: Any])
        XCTAssertNotNil(
            exactJSON["result"],
            "exactly 25 MiB must reach the attachment router; response=\(exactJSON)"
        )

        let oversized = try await response(decodedByteCount: 25 * 1024 * 1024 + 1, requestId: "oversized")
        XCTAssertEqual(oversized.1.statusCode, 200,
                       "decoded attachment validation is a typed JSON-RPC error, not a transport disconnect")
        let oversizedJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: oversized.0) as? [String: Any])
        XCTAssertNotNil(oversizedJSON["error"], "25 MiB + 1 byte must be rejected by the decoded-byte authority")
    }

    @MainActor
    func test_partialHeaderSlowLorisConnectionTimesOutAndCloses() throws {
        let port = UInt16.random(in: 33000...44000)
        let dispatcher = JSONRPCDispatcher(router: FakeRouter())
        let s = DirectHTTPServer(
            port: port,
            loopbackOnly: true,
            dispatcher: dispatcher,
            bootEpoch: 1,
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

    /// C-07: one TCP connection must serve multiple HTTP requests (keep-alive).
    /// WHY: cold-start used to open 11+ TCP connections because every response
    /// sent `Connection: close`. Reusing one socket is the highest-ROI latency
    /// cut on 3G (skips SYN/FIN per RPC after the first).
    @MainActor
    func test_httpKeepAlive_reusesOneTCPConnectionAndIdlesOut() throws {
        let port = UInt16.random(in: 33000...44000)
        let dispatcher = JSONRPCDispatcher(router: FakeRouter())
        let s = DirectHTTPServer(
            port: port,
            loopbackOnly: true,
            dispatcher: dispatcher,
            bootEpoch: 1,
            clientReceiveTimeoutSeconds: 1
        )
        try s.start()
        defer { s.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let fd = try connectLocalhost(port: port)
        defer { Darwin.close(fd) }

        try writeAll(fd: fd, data: Data(
            "GET /healthz HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8
        ))
        let first = try readFullHTTPResponse(fd: fd, timeout: 2)
        XCTAssertTrue(first.contains("HTTP/1.1 200"), "first keep-alive response must be 200, got: \(first.prefix(120))")
        XCTAssertTrue(first.lowercased().contains("connection: keep-alive"),
                      "responses must advertise keep-alive so clients reuse the socket")
        XCTAssertTrue(first.contains("ok\n"), "healthz body must be present on first response")

        // Second request on the SAME fd — proves the server did not FIN after response 1.
        try writeAll(fd: fd, data: Data(
            "GET /v1/discovery HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8
        ))
        let second = try readFullHTTPResponse(fd: fd, timeout: 2)
        XCTAssertTrue(second.contains("HTTP/1.1 200"), "second keep-alive response must be 200, got: \(second.prefix(120))")
        XCTAssertTrue(second.contains("remotecode"),
                      "second request on the same TCP connection must reach discovery")

        // Idle SO_RCVTIMEO (1s) must reclaim the connection (no cleanup regression).
        let idleDeadline = Date().addingTimeInterval(2.5)
        var closed = false
        var bytes = [UInt8](repeating: 0, count: 64)
        while Date() < idleDeadline {
            let n = Darwin.recv(fd, &bytes, bytes.count, MSG_DONTWAIT)
            if n == 0 { closed = true; break }
            if n < 0, errno == ECONNRESET || errno == ENOTCONN { closed = true; break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(closed, "server must close an idle keep-alive connection via SO_RCVTIMEO")
    }

    func test_httpClientRequestsClose_parsesConnectionHeader() {
        XCTAssertFalse(DirectHTTPServer.httpClientRequestsClose([:]),
                       "HTTP/1.1 default is keep-alive when Connection is absent")
        XCTAssertFalse(DirectHTTPServer.httpClientRequestsClose(["connection": "keep-alive"]))
        XCTAssertTrue(DirectHTTPServer.httpClientRequestsClose(["connection": "close"]))
        XCTAssertTrue(DirectHTTPServer.httpClientRequestsClose(["connection": "Keep-Alive, close"]),
                      "comma-separated tokens must honor an explicit close")
    }

    func test_webSocketPongFrameClampsOversizedPingPayload() {
        let frame = DirectHTTPServer.pongFrame(payload: Data(repeating: 0x41, count: 300))

        XCTAssertEqual(frame.first, 0x8A, "server pong frames must stay valid websocket control frames")
        XCTAssertEqual(frame.dropFirst().first, 125, "oversized ping payloads must not trap while converting the pong length to UInt8")
        XCTAssertEqual(frame.count, 127)
    }

    func test_webSocketConnectionWriterSerializesApplicationAndControlFrames() {
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let writer = WebSocketConnectionWriter { _, data in
            if data == Data([1]) {
                firstEntered.signal()
                _ = releaseFirst.wait(timeout: .now() + 2)
            } else {
                secondEntered.signal()
            }
            return true
        }
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            _ = writer.send(opcode: 0x1, data: Data([1]))
            group.leave()
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 1), .success)

        group.enter()
        DispatchQueue.global().async {
            _ = writer.send(opcode: 0xA, data: Data([2]))
            group.leave()
        }
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 0.1), .timedOut,
                       "pong bytes must not interleave with an application frame already being written")
        releaseFirst.signal()
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(group.wait(timeout: .now() + 1), .success)
    }

    func test_webSocketLivenessPolicyUsesWiFiAndCellularProfiles() {
        XCTAssertEqual(DirectHTTPServer.wsHeartbeatInterval, 10,
                       "default / Wi-Fi welcome advertises a 10s ping interval")
        XCTAssertEqual(DirectHTTPServer.wsHeartbeatTimeout, 30,
                       "default / Wi-Fi black-hole budget is 30s")
        XCTAssertEqual(DirectHTTPServer.wsHeartbeatProfileCellular.interval, 25)
        XCTAssertEqual(DirectHTTPServer.wsHeartbeatProfileCellular.timeout, 90)
        XCTAssertGreaterThan(DirectHTTPServer.wsHeartbeatTimeout,
                             DirectHTTPServer.wsHeartbeatInterval)
        XCTAssertGreaterThan(DirectHTTPServer.wsSocketReadTimeout,
                             DirectHTTPServer.wsHeartbeatProfileCellular.timeout,
                             "socket read timeout is a fallback; RFC pong / traffic owns liveness")
    }

    func test_heartbeatProfileSelectionTracksWSFilter() {
        XCTAssertEqual(
            DirectHTTPServer.heartbeatProfile(forWSFilter: .full),
            DirectHTTPServer.wsHeartbeatProfileWiFi
        )
        XCTAssertEqual(
            DirectHTTPServer.heartbeatProfile(forWSFilter: .cellularSafe()),
            DirectHTTPServer.wsHeartbeatProfileCellular
        )
    }

    func test_httpKeepAliveIdleResolvesFromExperimentFlag() {
        XCTAssertEqual(
            DirectHTTPServer.resolvedHttpKeepAliveIdleTimeoutSeconds(experimentEnabled: false),
            DirectHTTPServer.httpKeepAliveIdleTimeoutSeconds
        )
        XCTAssertEqual(
            DirectHTTPServer.resolvedHttpKeepAliveIdleTimeoutSeconds(experimentEnabled: true),
            DirectHTTPServer.httpKeepAliveIdleTimeoutExperimentSeconds
        )
        XCTAssertEqual(DirectHTTPServer.httpKeepAliveIdleTimeoutExperimentSeconds, 25,
                       "U-002 budget covers typical cellular RRC idle without indefinite hold")
        XCTAssertGreaterThan(
            DirectHTTPServer.httpKeepAliveIdleTimeoutExperimentSeconds,
            DirectHTTPServer.httpKeepAliveIdleTimeoutSeconds
        )
    }

    func test_coalescingWindowNegotiationPreservesDefaultsAndClampsProposal() {
        // WHY: legacy clients must retain current latency, while measured 3G
        // clients may request a bounded aggregation window without unbounded UI delay.
        XCTAssertEqual(
            DirectHTTPServer.negotiateCoalescingWindowMs(filter: .full, proposedMs: nil),
            DirectHTTPServer.wsCoalescingWindowWiFiMs
        )
        XCTAssertEqual(
            DirectHTTPServer.negotiateCoalescingWindowMs(filter: .cellularSafe(), proposedMs: nil),
            DirectHTTPServer.wsCoalescingWindowCellularMs
        )
        XCTAssertEqual(
            DirectHTTPServer.negotiateCoalescingWindowMs(filter: .full, proposedMs: 1),
            DirectHTTPServer.wsCoalescingWindowMinMs
        )
        XCTAssertEqual(
            DirectHTTPServer.negotiateCoalescingWindowMs(filter: .cellularSafe(), proposedMs: 999_999),
            DirectHTTPServer.wsCoalescingWindowMaxMs
        )
    }

    func test_heartbeatNegotiationAcceptsClientProposalWithinProfile() {
        let accepted = DirectHTTPServer.negotiateHeartbeatProfile(
            filter: .cellularSafe(),
            proposedIntervalMs: 25_000,
            proposedTimeoutMs: 90_000
        )
        XCTAssertEqual(accepted.interval, 25)
        XCTAssertEqual(accepted.timeout, 90)

        let countered = DirectHTTPServer.negotiateHeartbeatProfile(
            filter: .cellularSafe(),
            proposedIntervalMs: 60_000,
            proposedTimeoutMs: 120_000
        )
        XCTAssertEqual(countered.interval, 25,
                       "host counters interval proposals above the cellular ceiling")
        XCTAssertEqual(countered.timeout, 90,
                       "host counters timeout proposals above the cellular ceiling")

        let wifi = DirectHTTPServer.negotiateHeartbeatProfile(
            filter: .full,
            proposedIntervalMs: nil,
            proposedTimeoutMs: nil
        )
        XCTAssertEqual(wifi, DirectHTTPServer.wsHeartbeatProfileWiFi)

        // Full content fidelity + cellular-scale client proposal (street 4G):
        // must not clamp to Wi‑Fi 10s/30s liveness.
        let fullWithCellularProposal = DirectHTTPServer.negotiateHeartbeatProfile(
            filter: .full,
            proposedIntervalMs: 25_000,
            proposedTimeoutMs: 90_000
        )
        XCTAssertEqual(fullWithCellularProposal.interval, 25,
                       "full filter must still accept cellular interval proposals")
        XCTAssertEqual(fullWithCellularProposal.timeout, 90,
                       "full filter must still accept cellular timeout proposals on 4G")
    }

    func test_webSocketLiveness_requiresExactPongPayloadByDeadline() {
        let nonce = Data("server-nonce".utf8)
        let state = WebSocketLivenessState(
            now: 0,
            interval: 10,
            timeout: 30,
            nonce: { nonce }
        )

        XCTAssertEqual(state.nextAction(now: 9.99), .none)
        XCTAssertEqual(state.nextAction(now: 10), .ping(nonce))
        XCTAssertFalse(state.acceptPong(Data("wrong".utf8), now: 11),
                       "an unrelated pong must not prove this connection is live")
        XCTAssertEqual(state.nextAction(now: 29.99), .none)
        XCTAssertEqual(state.nextAction(now: 30), .timedOut)

        let late = WebSocketLivenessState(
            now: 0,
            interval: 10,
            timeout: 30,
            nonce: { nonce }
        )
        XCTAssertEqual(late.nextAction(now: 10), .ping(nonce))
        XCTAssertFalse(late.acceptPong(nonce, now: 30),
                       "a matching pong at or after the deadline must not revive the connection")
        XCTAssertEqual(late.nextAction(now: 30), .timedOut)

        let matched = WebSocketLivenessState(
            now: 0,
            interval: 10,
            timeout: 30,
            nonce: { nonce }
        )
        XCTAssertEqual(matched.nextAction(now: 10), .ping(nonce))
        XCTAssertTrue(matched.acceptPong(nonce, now: 16))
        XCTAssertEqual(matched.nextAction(now: 25.99), .none)
        XCTAssertEqual(matched.nextAction(now: 26), .ping(nonce),
                       "a matching pong resets proof and schedules the next server ping")
    }

    func test_webSocketLiveness_inboundTrafficCountsAsProofAndSuppressesPing() {
        let nonce = Data("server-nonce".utf8)
        let state = WebSocketLivenessState(
            now: 0,
            interval: 10,
            timeout: 30,
            nonce: { nonce }
        )
        XCTAssertEqual(state.nextAction(now: 10), .ping(nonce))
        state.noteInboundTraffic(now: 12)
        XCTAssertEqual(state.nextAction(now: 21.99), .none,
                       "real traffic must suppress the next ping until a full interval elapses")
        XCTAssertEqual(state.nextAction(now: 22), .ping(nonce))
        state.noteInboundTraffic(now: 25)
        // Traffic at t=25 clears outstanding and restarts the interval clock.
        XCTAssertEqual(state.nextAction(now: 35), .ping(nonce))
        XCTAssertEqual(state.nextAction(now: 54.99), .none,
                       "while a ping is outstanding the scheduler waits for proof or timeout")
        XCTAssertEqual(state.nextAction(now: 55), .timedOut,
                       "traffic only delays the hard timeout; silence still closes at the deadline")
    }

    func test_webSocketLiveness_nextWakeDelay_schedulesInterestNotPoll() {
        // WHY (C-19): host must wake once per interval (~12/min on Wi-Fi), not 4×/s.
        let nonce = Data("server-nonce".utf8)
        let state = WebSocketLivenessState(
            now: 0,
            interval: 10,
            timeout: 30,
            nonce: { nonce }
        )
        XCTAssertEqual(state.nextWakeDelay(now: 0), 10, accuracy: 0.001,
                       "fresh connection next interest is the first ping")
        XCTAssertEqual(state.nextWakeDelay(now: 3), 7, accuracy: 0.001)
        _ = state.nextAction(now: 10)
        // Outstanding ping: next interest is the hard timeout from last proof (t=0).
        XCTAssertEqual(state.nextWakeDelay(now: 10), 20, accuracy: 0.001,
                       "while awaiting pong, wake only at timeout")
        XCTAssertTrue(state.acceptPong(nonce, now: 12))
        XCTAssertEqual(state.nextWakeDelay(now: 12), 10, accuracy: 0.001,
                       "after pong, next wake is interval from proof")
    }

    func test_connectionOutboundOwner_ordersAcceptedWorkThenTerminalAndRejectsLaterFrames() throws {
        let recorded = RecordedFrames()
        let owner = WebSocketOutboundQueue(
            maxQueuedBytes: 1_024,
            applicationWriter: { data in
                recorded.append("app:\(String(decoding: data, as: UTF8.self))")
                return true
            },
            controlWriter: { opcode, data in
                recorded.append("control:\(opcode):\(String(decoding: data, as: UTF8.self))")
                return true
            },
            writeFailureClosingData: Data("write-failure".utf8),
            onTerminal: { reason in recorded.append("terminal:\(reason)") },
            didSendTerminal: { recorded.append("shutdown") }
        )

        XCTAssertEqual(owner.enqueueApplication(Data("event-1".utf8)), .accepted)
        XCTAssertTrue(owner.terminate(
            errorData: Data("error".utf8),
            closingData: Data("closing".utf8),
            reason: "protocolError"
        ))
        XCTAssertEqual(owner.enqueueApplication(Data("event-too-late".utf8)), .closed)
        owner.finish()

        let frames = recorded.snapshot
        let appIndex = try XCTUnwrap(frames.firstIndex(of: "app:event-1"))
        let errorIndex = try XCTUnwrap(frames.firstIndex(of: "control:1:error"))
        let closingIndex = try XCTUnwrap(frames.firstIndex(of: "control:1:closing"))
        let closeIndex = try XCTUnwrap(frames.firstIndex(of: "control:8:"))
        let shutdownIndex = try XCTUnwrap(frames.firstIndex(of: "shutdown"))
        XCTAssertLessThan(appIndex, errorIndex,
                          "accepted application work must complete before terminal frames")
        XCTAssertLessThan(errorIndex, closingIndex)
        XCTAssertLessThan(closingIndex, closeIndex)
        XCTAssertLessThan(closeIndex, shutdownIndex)
        XCTAssertEqual(frames.filter { $0 == "terminal:protocolError" }.count, 1)
        XCTAssertFalse(frames.contains("app:event-too-late"),
                       "no application event may be accepted after terminal state")
    }

    func test_connectionOutboundOwner_concurrentTerminateCannotOvertakeAcceptedSubmission() {
        assertConcurrentTerminateCannotOvertake(
            expectedFirstFrame: "app:event",
            submit: { $0.enqueueApplication(Data("event".utf8)) }
        )
        assertConcurrentTerminateCannotOvertake(
            expectedFirstFrame: "control:9:ping",
            submit: { $0.enqueueControl(opcode: 0x9, data: Data("ping".utf8)) }
        )
    }

    /// WHY: iOS pings every 5s and kills the connection when the pong misses its
    /// 2s deadline. On a slow uplink the outbound queue can hold up to 1 MiB of
    /// event data ahead of the pong; strict FIFO would starve the pong behind
    /// healthy-but-slow event writes and the client would drop a live connection.
    /// Control frames must overtake application frames that have not started
    /// writing (an in-progress frame is never preempted per RFC 6455).
    func test_connectionOutboundOwner_pongOvertakesQueuedApplicationFramesOnStalledWriter() {
        let recorded = RecordedFrames()
        let firstWriteEntered = DispatchSemaphore(value: 0)
        let releaseFirstWrite = DispatchSemaphore(value: 0)
        let owner = WebSocketOutboundQueue(
            maxQueuedBytes: 1_024,
            applicationWriter: { data in
                recorded.append("app:\(String(decoding: data, as: UTF8.self))")
                if data == Data("event-1".utf8) {
                    firstWriteEntered.signal()
                    _ = releaseFirstWrite.wait(timeout: .now() + 2)
                }
                return true
            },
            controlWriter: { opcode, data in
                recorded.append("control:\(opcode):\(String(decoding: data, as: UTF8.self))")
                return true
            },
            writeFailureClosingData: Data(),
            onTerminal: { _ in },
            didSendTerminal: {}
        )

        XCTAssertEqual(owner.enqueueApplication(Data("event-1".utf8)), .accepted)
        XCTAssertEqual(firstWriteEntered.wait(timeout: .now() + 2), .success,
                       "the first application frame must be mid-write before the queue backs up")
        XCTAssertEqual(owner.enqueueApplication(Data("event-2".utf8)), .accepted)
        XCTAssertEqual(owner.enqueueApplication(Data("event-3".utf8)), .accepted)
        XCTAssertEqual(owner.enqueueControl(opcode: 0xA, data: Data("pong".utf8)), .accepted)
        releaseFirstWrite.signal()
        owner.finish()

        XCTAssertEqual(recorded.snapshot, [
            "app:event-1",
            "control:10:pong",
            "app:event-2",
            "app:event-3",
        ], "a pong must be written before queued application frames that have not started, or the client's 2s pong deadline starves behind event data")
    }

    /// WHY: both WebSocket frame classes can hold 4,096 frames. Array.removeFirst
    /// shifts every remaining element per drain and turns that bounded backlog
    /// into quadratic CPU work. A head-indexed FIFO must preserve order while
    /// compacting storage only a bounded number of times, then remain reusable.
    func test_webSocketFrameFIFO_drains100kInOrderWithAmortizedCompactionAndReusableStorage() {
        var fifo = WebSocketFrameFIFO<Int>()
        let frameCount = 100_000

        for frame in 0..<frameCount {
            fifo.append(frame)
        }
        XCTAssertEqual(fifo.diagnostics.queuedCount, frameCount)
        XCTAssertEqual(fifo.diagnostics.storageCount, frameCount)

        var expected = 0
        while expected < frameCount / 2, let frame = fifo.popFirst() {
            guard frame == expected else {
                XCTFail("FIFO reordered frame \(frame); expected \(expected)")
                break
            }
            expected += 1
        }
        XCTAssertEqual(expected, frameCount / 2)
        XCTAssertEqual(fifo.diagnostics.queuedCount, frameCount / 2)
        XCTAssertEqual(fifo.diagnostics.storageCount, frameCount / 2,
                       "consumed slots must compact instead of retaining peak storage")
        XCTAssertEqual(fifo.diagnostics.headIndex, 0)
        XCTAssertEqual(fifo.diagnostics.compactionCount, 1)

        while let frame = fifo.popFirst() {
            guard frame == expected else {
                XCTFail("FIFO reordered frame \(frame); expected \(expected)")
                break
            }
            expected += 1
        }

        XCTAssertEqual(expected, frameCount)
        XCTAssertEqual(fifo.diagnostics.queuedCount, 0)
        XCTAssertEqual(fifo.diagnostics.storageCount, 0,
                       "drained storage must not stack stale frame references")
        XCTAssertEqual(fifo.diagnostics.headIndex, 0)
        XCTAssertGreaterThan(fifo.diagnostics.compactionCount, 0)
        XCTAssertLessThan(fifo.diagnostics.compactionCount, 64,
                          "compaction must be amortized, never one Array shift per frame")

        for frame in 0..<4_096 {
            fifo.append(frame)
        }
        for expected in 0..<4_096 {
            XCTAssertEqual(fifo.popFirst(), expected)
        }
        XCTAssertEqual(fifo.diagnostics.queuedCount, 0)
        XCTAssertEqual(fifo.diagnostics.storageCount, 0,
                       "a reused queue must release every drained storage slot")
    }

    /// C-04: degrade ladder coalesces by key then sheds bulk without closing.
    func test_connectionOutboundOwner_degradeCoalescesAndDiscardsBulkWithoutTerminate() throws {
        let stall = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let owner = WebSocketOutboundQueue(
            maxQueuedBytes: 64 * 1024,
            applicationWriter: { data in
                if String(decoding: data, as: UTF8.self).contains("\"sequence\":1") {
                    stall.signal()
                    _ = release.wait(timeout: .now() + 2)
                }
                return true
            },
            controlWriter: { _, _ in true },
            writeFailureClosingData: Data(),
            onTerminal: { _ in XCTFail("degrade must never terminate") },
            didSendTerminal: { XCTFail("degrade must never shut down") }
        )

        func eventFrame(seq: Int64, kind: String, payload: [String: Any]) throws -> Data {
            let object: [String: Any] = [
                "protocolVersion": 3,
                "type": "event",
                "connectionId": "c",
                "hostId": "h",
                "bootEpoch": 1,
                "sequence": seq,
                "eventId": "1:\(seq)",
                "occurredAtEpochMs": 0,
                "kind": kind,
                "payload": payload,
            ]
            return try JSONSerialization.data(withJSONObject: object)
        }

        let first = try eventFrame(seq: 1, kind: "agent.item.delta", payload: [
            "item_id": "i1", "text": "a",
        ])
        XCTAssertEqual(owner.enqueueApplication(first), .accepted)
        XCTAssertEqual(stall.wait(timeout: .now() + 2), .success)

        for seq in 2...6 {
            let frame = try eventFrame(seq: Int64(seq), kind: "agent.item.delta", payload: [
                "item_id": "i1", "text": "t\(seq)",
            ])
            XCTAssertEqual(owner.enqueueApplication(frame), .accepted)
        }
        let critical = try eventFrame(seq: 7, kind: "agent.run.completed", payload: [
            "thread_id": "t1",
        ])
        XCTAssertEqual(owner.enqueueApplication(critical), .accepted)

        let before = owner.queuedFrameCountForTests
        XCTAssertGreaterThan(before, 1)
        let outcome = owner.degrade()
        XCTAssertTrue(outcome.needsBaselineRequired || outcome.discardedBulkFrames > 0
                      || outcome.coalescedAwayFrames > 0,
                      "degrade must free or mark pressure")
        XCTAssertLessThan(owner.queuedFrameCountForTests, before,
                          "coalesce/discard must reduce queued frames")
        XCTAssertEqual(owner.enqueueApplication(Data("tiny".utf8)), .accepted,
                       "queue must stay open after degrade")

        release.signal()
        owner.finish()
    }

    func test_outboundPressureBaselineGate_rateLimitsToOnePerSecond() {
        let gate = OutboundPressureBaselineGate(minInterval: 1.0)
        XCTAssertTrue(gate.tryAcquire(now: 100))
        XCTAssertFalse(gate.tryAcquire(now: 100.5),
                       "second acquire inside 1s must be rejected")
        XCTAssertTrue(gate.tryAcquire(now: 101.0),
                      "acquire at the interval boundary must succeed")
    }

    func test_connectionOutboundOwner_writeFailureClosesOnceAndClearsQueueAccounting() {
        let recorded = RecordedFrames()
        let owner = WebSocketOutboundQueue(
            maxQueuedBytes: 1_024,
            applicationWriter: { data in
                recorded.append("app:\(String(decoding: data, as: UTF8.self))")
                return false
            },
            controlWriter: { opcode, data in
                recorded.append("control:\(opcode):\(String(decoding: data, as: UTF8.self))")
                return true
            },
            writeFailureClosingData: Data("write-failure".utf8),
            onTerminal: { reason in recorded.append("terminal:\(reason)") },
            didSendTerminal: { recorded.append("shutdown") }
        )

        XCTAssertEqual(owner.enqueueApplication(Data("event".utf8)), .accepted)
        owner.finish()

        XCTAssertEqual(recorded.snapshot, [
            "app:event",
            "terminal:write_failed",
            "control:1:write-failure",
            "control:8:",
            "shutdown",
        ])
        XCTAssertEqual(owner.queuedByteCount, 0)
        XCTAssertEqual(owner.queuedFrameCountForTests, 0)
        XCTAssertEqual(owner.enqueueApplication(Data("too-late".utf8)), .closed)
    }

    func test_connectionOutboundOwner_controlFloodSharesByteAndFrameBudget() {
        // WHY: a slow client can keep the control writer blocked while sending
        // pings. Control frames must share both queue budgets with application
        // frames or Data plus one dispatch closure per ping grows indefinitely.
        let recorded = RecordedFrames()
        let firstWriteEntered = DispatchSemaphore(value: 0)
        let releaseFirstWrite = DispatchSemaphore(value: 0)
        let owner = WebSocketOutboundQueue(
            maxQueuedBytes: 16,
            maxQueuedFrames: 4,
            applicationWriter: { _ in true },
            controlWriter: { opcode, data in
                recorded.append("control:\(opcode):\(String(decoding: data, as: UTF8.self))")
                if opcode == 0x9, data == Data("ping".utf8) {
                    firstWriteEntered.signal()
                    _ = releaseFirstWrite.wait(timeout: .now() + 2)
                }
                return true
            },
            writeFailureClosingData: Data(),
            onTerminal: { reason in recorded.append("terminal:\(reason)") },
            didSendTerminal: { recorded.append("shutdown") }
        )

        XCTAssertEqual(owner.enqueueControl(opcode: 0x9, data: Data("ping".utf8)), .accepted)
        XCTAssertEqual(firstWriteEntered.wait(timeout: .now() + 2), .success)
        for _ in 0..<3 {
            XCTAssertEqual(owner.enqueueControl(opcode: 0xA, data: Data("pong".utf8)), .accepted)
        }
        XCTAssertEqual(owner.queuedByteCount, 16)
        XCTAssertEqual(owner.queuedFrameCountForTests, 4)

        XCTAssertEqual(owner.enqueueControl(opcode: 0xA, data: Data("full".utf8)), .queueFull)
        // C-04: control overflow reports queueFull but stays open (no terminate).
        XCTAssertEqual(owner.enqueueControl(opcode: 0xA, data: Data("x".utf8)), .queueFull)
        XCTAssertEqual(recorded.snapshot.filter { $0.hasPrefix("terminal:") }.count, 0,
                       "queue_full must not terminate; degrade owns recovery")
        XCTAssertLessThanOrEqual(owner.queuedByteCount, 16)
        XCTAssertLessThanOrEqual(owner.queuedFrameCountForTests, 4)

        releaseFirstWrite.signal()
        owner.finish()

        XCTAssertEqual(owner.queuedByteCount, 0)
        XCTAssertEqual(owner.queuedFrameCountForTests, 0)
        XCTAssertEqual(recorded.snapshot.filter { $0.hasPrefix("terminal:") }.count, 0)
        XCTAssertEqual(recorded.snapshot.filter { $0 == "shutdown" }.count, 0)
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

    /// Read one full HTTP/1.1 response (headers + Content-Length body) so a
    /// keep-alive test can issue a second request on the same socket without
    /// leaving unread body bytes that would desync framing.
    private func readFullHTTPResponse(fd: Int32, timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            if Date() >= deadline {
                throw POSIXError(.ETIMEDOUT)
            }
            let n = Darwin.recv(fd, &buf, buf.count, MSG_DONTWAIT)
            if n > 0 {
                out.append(buf, count: n)
                headerEnd = out.range(of: Data("\r\n\r\n".utf8))
            } else if n == 0 {
                throw POSIXError(.ECONNRESET)
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            } else {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        let headerData = out.subdata(in: out.startIndex..<headerEnd!.lowerBound)
        let headerStr = String(decoding: headerData, as: UTF8.self)
        var contentLength = 0
        for line in headerStr.split(separator: "\r\n", omittingEmptySubsequences: false).dropFirst() {
            if line.lowercased().hasPrefix("content-length:") {
                let raw = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(raw) ?? 0
            }
        }
        let bodyStart = headerEnd!.upperBound
        while out.count - bodyStart < contentLength {
            if Date() >= deadline {
                throw POSIXError(.ETIMEDOUT)
            }
            let n = Darwin.recv(fd, &buf, buf.count, MSG_DONTWAIT)
            if n > 0 {
                out.append(buf, count: n)
            } else if n == 0 {
                throw POSIXError(.ECONNRESET)
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            } else {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        // Truncate to one message so pipelined extra bytes stay for next call.
        let end = bodyStart + contentLength
        if end < out.count {
            // Should not happen on a non-pipelined client; keep full buffer.
        }
        return String(decoding: out.prefix(end), as: UTF8.self)
    }

    private func assertConcurrentTerminateCannotOvertake(
        expectedFirstFrame: String,
        submit: @escaping @Sendable (WebSocketOutboundQueue) -> WebSocketOutboundQueue.EnqueueResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let acceptanceReached = DispatchSemaphore(value: 0)
        let terminationAttempted = DispatchSemaphore(value: 0)
        let completed = DispatchGroup()
        let recorded = RecordedFrames()
        let owner = WebSocketOutboundQueue(
            maxQueuedBytes: 1_024,
            applicationWriter: { data in
                recorded.append("app:\(String(decoding: data, as: UTF8.self))")
                return true
            },
            controlWriter: { opcode, data in
                recorded.append("control:\(opcode):\(String(decoding: data, as: UTF8.self))")
                return true
            },
            writeFailureClosingData: Data(),
            onTerminal: { _ in },
            didSendTerminal: {},
            acceptedSubmissionHook: {
                acceptanceReached.signal()
                if terminationAttempted.wait(timeout: .now() + 2) == .timedOut {
                    recorded.append("termination-timeout")
                }
            },
            terminationAttemptHook: { terminationAttempted.signal() }
        )

        completed.enter()
        DispatchQueue.global().async {
            if submit(owner) != .accepted { recorded.append("submission-rejected") }
            completed.leave()
        }
        XCTAssertEqual(acceptanceReached.wait(timeout: .now() + 2), .success, file: file, line: line)

        completed.enter()
        DispatchQueue.global().async {
            _ = owner.terminate(
                errorData: nil,
                closingData: Data("closing".utf8),
                reason: "protocolError"
            )
            completed.leave()
        }

        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success, file: file, line: line)
        owner.finish()
        XCTAssertEqual(recorded.snapshot, [
            expectedFirstFrame,
            "control:1:closing",
            "control:8:",
        ], "an accepted submission must enter the serial queue before a concurrent terminal sequence",
           file: file, line: line)
    }

    private final class RecordedFrames: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ value: String) {
            lock.lock(); values.append(value); lock.unlock()
        }

        var snapshot: [String] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }
}
