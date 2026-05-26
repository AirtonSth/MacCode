import XCTest
import CoreModel
@testable import SocketServer

final class CellularDataOptimizationTests: XCTestCase {
    func testPayloadCodecRoundTripsAndRejectsInvalidData() throws {
        let payload = Data(String(repeating: #"{"event":"same visible state"}"#, count: 40).utf8)
        let encoded = try PayloadCodec.lzfse.encode(payload)

        XCTAssertLessThan(encoded.count, payload.count)
        XCTAssertEqual(try PayloadCodec.lzfse.decode(encoded, expectedSize: payload.count), payload)
        XCTAssertThrowsError(try PayloadCodec.lzfse.decode(Data([0, 1, 2, 3]), expectedSize: payload.count))
    }

    func testWebSocketEnvelopeRoundTripsAndRejectsInvalidData() throws {
        let event = Data(String(repeating: #"{"seq":1,"kind":"surface.browser","payload":{"url":"https://example.test"}}"#, count: 20).utf8)
        let envelope = try PayloadCodec.encodeWebSocketEnvelope(event)

        XCTAssertLessThan(envelope.count, event.count,
                          "Mac WS compression must save bytes before it is sent on a cellular-optimized stream")
        XCTAssertEqual(try PayloadCodec.decodeWebSocketEnvelope(envelope), event)
        XCTAssertThrowsError(try PayloadCodec.decodeWebSocketEnvelope(Data("not-an-envelope".utf8)))
    }

    @MainActor
    func testEventsRecentHonorsSinceSeqAndMaxBytesWithTruncationMetadata() async throws {
        let bus = EventBus()
        bus.publish(kind: "a", payload: .string(String(repeating: "a", count: 500)))
        bus.publish(kind: "b", payload: .string(String(repeating: "b", count: 500)))
        bus.publish(kind: "c", payload: .string("small"))

        let result = bus.recentEvents(since: 1, maxBytes: 600)

        XCTAssertEqual(result.events.map(\.kind), ["b"])
        XCTAssertTrue(result.truncated,
                      "bounded cellular replay must say when history was truncated so iOS does not mark partial state live")
        XCTAssertTrue(result.requiresBaseline)
        XCTAssertEqual(result.lastSeq, 3)
    }

    @MainActor
    func testHTTPServerCompressesLargeAcceptedJSONResponses() throws {
        let port = UInt16.random(in: 33000...44000)
        let router = FakeRouter()
        router.workspaces = (0..<40).map { Workspace.empty(name: "workspace-\($0)-\(String(repeating: "x", count: 40))", cwd: "/tmp/project-\($0)") }
        let dispatcher = JSONRPCDispatcher(router: router)
        let server = DirectHTTPServer(port: port, loopbackOnly: true, dispatcher: dispatcher)
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let body = """
        {"jsonrpc":"2.0","id":"rpc-route","method":"workspace.list","params":{}}
        """
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
        request.httpMethod = "POST"
        request.setValue(PayloadCodec.acceptEncodingHeader, forHTTPHeaderField: "Accept-Encoding")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        let done = expectation(description: "compressed response")
        URLSession.shared.dataTask(with: request) { data, response, error in
            XCTAssertNil(error)
            let http = response as? HTTPURLResponse
            XCTAssertEqual(http?.value(forHTTPHeaderField: "Content-Encoding"), PayloadCodec.lzfse.wireName,
                           "Mac must only compress after explicit iOS negotiation")
            do {
                let decoded = try PayloadCodec.lzfse.decode(data ?? Data(), expectedSize: nil)
                let obj = try JSONSerialization.jsonObject(with: decoded) as? [String: Any]
                XCTAssertEqual(obj?["id"] as? String, "rpc-route")
            } catch {
                XCTFail("compressed JSON response should decode: \(error)")
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 4)
    }

    @MainActor
    func testHTTPServerDecodesCompressedRequestsAndRejectsBadEncodedBodies() async throws {
        let port = UInt16.random(in: 33000...44000)
        let router = FakeRouter()
        router.workspaces = [Workspace.empty(name: "compressed-request", cwd: "/tmp")]
        let server = DirectHTTPServer(port: port, loopbackOnly: true, dispatcher: JSONRPCDispatcher(router: router))
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 50_000_000)

        let json = #"{"jsonrpc":"2.0","id":"rpc-route","method":"workspace.list","params":{"note":""# +
            String(repeating: "same visible state ", count: 200) +
            #""}}"#
        let body = Data(json.utf8)
        let compressed = try PayloadCodec.lzfse.encode(body)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(PayloadCodec.lzfse.wireName, forHTTPHeaderField: "Content-Encoding")
        request.httpBody = compressed

        let (data, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let result = obj?["result"] as? [[String: Any]]
        XCTAssertEqual(result?.first?["name"] as? String, "compressed-request",
                       "compressed read-only RPC requests must route to the exact same dispatcher result as plain JSON")

        request.httpBody = Data("corrupt".utf8)
        let (_, badResponse) = try await URLSession.shared.data(for: request)

        XCTAssertEqual((badResponse as? HTTPURLResponse)?.statusCode, 400,
                       "corrupt compressed bodies must fail loudly instead of reaching RPC dispatch")
    }

    @MainActor
    func testDispatcherReadOnlyBatchRejectsMutatingMethods() async {
        let dispatcher = JSONRPCDispatcher(router: FakeRouter())

        let response = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .string("batch"),
            method: "rpc.batch",
            params: ["calls": .array([
                .object(["method": .string("workspace.list"), "params": .object([:])]),
                .object(["method": .string("agent.run.stop"), "params": .object([:])])
            ])]
        ))

        XCTAssertEqual(response.error?.code, -32602)
        XCTAssertEqual(response.error?.data, .string("agent.run.stop"),
                       "cellular batching must fail loudly instead of changing mutating RPC semantics")
    }

    func testCellularSafeEventFilterDropsOnlyDiagnosticNonReducerEvents() {
        let bus = EventBus()
        var full: [String] = []
        var filtered: [String] = []
        _ = bus.subscribe(since: nil) { full.append($0.kind) }
        _ = bus.subscribe(since: nil, filter: .cellularSafe) { filtered.append($0.kind) }

        bus.publish(kind: "diagnostic.tick", payload: .object(["sample": .string(String(repeating: "x", count: 200))]))
        bus.publish(kind: "surface.output", payload: .object([
            "surface_id": .string("s1"),
            "seq": .number(7),
            "rows": .number(33),
            "cols": .number(101),
            "base64": .string(Data(String(repeating: "log ", count: 200).utf8).base64EncodedString())
        ]))
        bus.publish(kind: "surface.browser", payload: .object(["surface_id": .string("s1"), "url": .string("https://example.test")]))
        bus.publish(kind: "agent.run.completed", payload: .object(["thread_id": .string("t1")]))

        XCTAssertEqual(full, ["diagnostic.tick", "surface.output", "surface.browser", "agent.run.completed"],
                       "old/unfiltered clients must keep receiving the full stream")
        XCTAssertEqual(filtered, ["surface.output.summary", "surface.browser", "agent.run.completed"],
                       "cellular-safe WS filtering may summarize passive terminal output and drop diagnostics while visible state and critical events pass")
    }

    func testCellularSafeOutputSummaryKeepsSeqAndGeometry() {
        let source = EventBus.Event(seq: 1, kind: "surface.output", payload: .object([
            "surface_id": .string("s1"),
            "seq": .number(42),
            "rows": .number(34),
            "cols": .number(120),
            "base64": .string(Data("abc".utf8).base64EncodedString())
        ]), ts: 0)

        let mapped = EventStreamFilter.cellularSafe.map(source)
        let payload = mapped?.payload.objectValue

        XCTAssertEqual(mapped?.kind, "surface.output.summary")
        XCTAssertEqual(payload?["seq"], .number(42),
                       "summarized terminal output must keep per-surface seq so iOS knows whether read_history caught up")
        XCTAssertEqual(payload?["rows"], .number(34))
        XCTAssertEqual(payload?["cols"], .number(120))
    }
}
