import XCTest
@testable import SocketServer
import CoreModel

/// QA-mac:45 -- real-socket integration coverage for `/v1/ws`. Previously only
/// `WebSocketOutboundQueue` and `pongFrame` were unit-tested; nothing exercised
/// the actual upgrade handshake or event delivery over a live socket. These tests
/// stand up a real loopback `DirectHTTPServer` and drive it with a real
/// `URLSessionWebSocketTask`, so the handshake, EventBus subscription, framed
/// delivery, and the `x-rc2-since-seq` delta slice are all proven end-to-end.
@MainActor
final class WebSocketIntegrationTests: XCTestCase {

    private func startServer(
        heartbeatInterval: TimeInterval = DirectHTTPServer.wsHeartbeatInterval,
        webSocketOutboundMaxQueuedBytes: Int = DirectHTTPServer.maxWebSocketOutboundQueuedBytes
    ) throws -> (DirectHTTPServer, UInt16) {
        let port = UInt16.random(in: 33000...44000)
        let server = DirectHTTPServer(port: port, loopbackOnly: true,
                                      dispatcher: JSONRPCDispatcher(router: FakeRouter()),
                                      heartbeatInterval: heartbeatInterval,
                                      webSocketOutboundMaxQueuedBytes: webSocketOutboundMaxQueuedBytes)
        try server.start()
        return (server, port)
    }

    private func wsTask(port: UInt16, sinceSeq: Int64?) -> URLSessionWebSocketTask {
        var req = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
        if let s = sinceSeq { req.setValue("\(s)", forHTTPHeaderField: "x-rc2-since-seq") }
        let task = URLSession.shared.webSocketTask(with: req)
        task.resume()
        return task
    }

    /// Receive frames until one with `kind == wantedKind` arrives (skipping
    /// heartbeats and any unrelated event), or fail once the frame budget is spent.
    private func receiveEvent(_ task: URLSessionWebSocketTask, kind wantedKind: String,
                              budget: Int = 50) async throws -> [String: Any] {
        for _ in 0..<budget {
            let message = try await task.receive()
            let data: Data
            switch message {
            case .data(let d): data = d
            case .string(let s): data = Data(s.utf8)
            @unknown default: continue
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if obj["type"] as? String == "heartbeat" { continue }
            if obj["kind"] as? String == wantedKind { return obj }
        }
        XCTFail("did not receive an event of kind \(wantedKind) within the frame budget")
        return [:]
    }

    private enum TimeoutError: Error { case timedOut }

    private func receiveWithTimeout(_ task: URLSessionWebSocketTask, seconds: Double = 2) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask {
                try await task.receive()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func waitUntil(timeoutSeconds: Double = 2, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func testHeartbeatFrameFiresOverLiveWebSocket() async throws {
        let (server, port) = try startServer(heartbeatInterval: 0.05)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)

        let baseline = EventBus.shared.currentSeq
        let task = wsTask(port: port, sinceSeq: baseline)
        defer { task.cancel(with: .normalClosure, reason: nil) }

        for _ in 0..<5 {
            let message = try await receiveWithTimeout(task)
            let data: Data
            switch message {
            case .data(let d): data = d
            case .string(let s): data = Data(s.utf8)
            @unknown default: continue
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if obj["type"] as? String == "heartbeat" {
                XCTAssertNotNil(obj["ts"], "heartbeat frames must carry a timestamp for client freshness UI")
                return
            }
        }
        XCTFail("did not receive a heartbeat frame over the live WebSocket")
    }

    func testWebSocketCloseUnsubscribesEventBus() async throws {
        let baselineSubscribers = EventBus.shared.subscriberCountForTests
        let (server, port) = try startServer()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)

        let task = wsTask(port: port, sinceSeq: EventBus.shared.currentSeq)
        let subscribed = await waitUntil {
            EventBus.shared.subscriberCountForTests > baselineSubscribers
        }
        XCTAssertTrue(subscribed, "WS handshake must create an EventBus subscription before this test can prove cleanup")

        task.cancel(with: .normalClosure, reason: nil)
        let cleanedUp = await waitUntil {
            EventBus.shared.subscriberCountForTests == baselineSubscribers
        }
        XCTAssertTrue(cleanedUp,
                      "closing a live WS task must unsubscribe from EventBus so repeated mobile reconnects do not leak subscribers")
    }

    func testSlowClientQueueFullClosesLiveWebSocketWithServerClosePayload() async throws {
        let (server, port) = try startServer(webSocketOutboundMaxQueuedBytes: 128)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)

        let task = wsTask(port: port, sinceSeq: EventBus.shared.currentSeq)
        defer { task.cancel(with: .normalClosure, reason: nil) }
        try await Task.sleep(nanoseconds: 150_000_000)

        let kind = "test.ws.queuefull.\(UUID().uuidString)"
        EventBus.shared.publish(kind: kind, payload: .object([
            "blob": .string(String(repeating: "x", count: 4_096))
        ]))

        for _ in 0..<10 {
            let message = try await receiveWithTimeout(task, seconds: 2)
            let data: Data
            switch message {
            case .data(let d): data = d
            case .string(let s): data = Data(s.utf8)
            @unknown default: continue
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if obj["type"] as? String == "server_close" {
                XCTAssertEqual(obj["reason"] as? String, "queue_full",
                               "live WS slow-client close must carry the stable queue_full reason")
                XCTAssertEqual(obj["action"] as? String, "reconnect_with_baseline",
                               "client recovery must be explicit after a queue_full close")
                let dropped = await waitUntil { server.wsTracker.slowClientDrops >= 1 }
                XCTAssertTrue(dropped, "live queue_full close must increment slow-client diagnostics")
                return
            }
        }

        XCTFail("live queue_full path must send a server_close frame before shutting down the socket")
    }

    func testCompressionNegotiationDeliversDecodableEnvelope() async throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)

        // Negotiate lzfse compression via the upgrade header.
        var req = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
        let baseline = EventBus.shared.currentSeq
        req.setValue("\(baseline)", forHTTPHeaderField: "x-rc2-since-seq")
        req.setValue(PayloadCodec.lzfse.wireName, forHTTPHeaderField: "x-rc2-ws-encoding")
        let task = URLSession.shared.webSocketTask(with: req)
        task.resume()
        try await Task.sleep(nanoseconds: 150_000_000)

        // A large, highly-compressible payload so the envelope is strictly smaller
        // than the raw frame (the server only sends a binary envelope when it wins).
        let kind = "test.ws.compress.\(UUID().uuidString)"
        let big = String(repeating: "same visible state ", count: 400)
        EventBus.shared.publish(kind: kind, payload: .object(["blob": .string(big)]))

        for _ in 0..<50 {
            let message = try await task.receive()
            switch message {
            case .data(let envelope):
                // Binary frame => the negotiated lzfse WebSocket envelope. It must
                // decode back to the exact JSON event we published.
                let decoded = try PayloadCodec.decodeWebSocketEnvelope(envelope)
                guard let obj = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
                      obj["kind"] as? String == kind else { continue }
                let payload = obj["payload"] as? [String: Any]
                XCTAssertEqual(payload?["blob"] as? String, big,
                    "a compression-negotiated client must receive a decodable lzfse envelope carrying the exact event")
                task.cancel(with: .normalClosure, reason: nil)
                return
            case .string(let s):
                // Text frame: only acceptable if it is NOT our large event (e.g. a
                // heartbeat); our big payload must arrive compressed as a binary frame.
                if let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                   obj["kind"] as? String == kind {
                    XCTFail("the large negotiated-compression event must be delivered as a binary lzfse envelope, not an uncompressed text frame")
                    return
                }
            @unknown default: continue
            }
        }
        XCTFail("did not receive the compressed event within the frame budget")
    }

    func testFilterNegotiationDropsDiagnosticKeepsCritical() async throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)

        // Negotiate the cellular-safe filter. It drops diagnostic/metrics events
        // (reducerRequired == false, non-critical) and keeps critical ones.
        var req = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
        let baseline = EventBus.shared.currentSeq
        req.setValue("\(baseline)", forHTTPHeaderField: "x-rc2-since-seq")
        req.setValue("cellular-safe", forHTTPHeaderField: "x-rc2-ws-filter")
        let task = URLSession.shared.webSocketTask(with: req)
        task.resume()
        try await Task.sleep(nanoseconds: 150_000_000)

        // Publish a DROPPED diagnostic event first, then a KEPT critical event.
        let droppedKind = "diagnostic.test.\(UUID().uuidString)"   // priority .diagnostic -> filtered out
        let keptKind = "test.ws.critical.\(UUID().uuidString)"     // default -> .critical -> kept
        EventBus.shared.publish(kind: droppedKind, payload: .object(["d": .bool(true)]))
        EventBus.shared.publish(kind: keptKind, payload: .object(["k": .bool(true)]))

        // The first non-heartbeat event must be the critical one; the diagnostic
        // event must never appear (the negotiated filter dropped it server-side).
        for _ in 0..<50 {
            let message = try await task.receive()
            let data: Data
            switch message {
            case .data(let d): data = d
            case .string(let s): data = Data(s.utf8)
            @unknown default: continue
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if obj["type"] as? String == "heartbeat" { continue }
            let k = obj["kind"] as? String
            XCTAssertNotEqual(k, droppedKind,
                "the cellular-safe filter must drop diagnostic.* events server-side; one was delivered")
            if k == keptKind {
                task.cancel(with: .normalClosure, reason: nil)
                return
            }
        }
        XCTFail("did not receive the critical event the cellular-safe filter should keep")
    }

    func testHandshakeThenDeliversPublishedEvent() async throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)

        // Subscribe from the current head so the retained backlog is skipped and
        // the only event we can receive is the one we publish next.
        let baseline = EventBus.shared.currentSeq
        let task = wsTask(port: port, sinceSeq: baseline)
        try await Task.sleep(nanoseconds: 150_000_000)   // let the upgrade + subscribe complete

        let kind = "test.ws.roundtrip.\(UUID().uuidString)"
        EventBus.shared.publish(kind: kind, payload: .object(["hello": .string("ws"), "n": .number(7)]))

        let obj = try await receiveEvent(task, kind: kind)
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["hello"] as? String, "ws",
                       "the live WS client must receive the exact payload published on EventBus after the handshake")
        XCTAssertNotNil(obj["seq"], "delivered events must carry an ordering seq")
        if let seq = (obj["seq"] as? NSNumber)?.int64Value {
            XCTAssertGreaterThan(seq, baseline, "delivered seq must be strictly after the subscribed-from baseline")
        }

        task.cancel(with: .normalClosure, reason: nil)
    }

    func testSinceSeqSkipsEventsPublishedBeforeConnect() async throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)

        // Event A is published BEFORE the client subscribes-from-head; it must NOT
        // be delivered. Event B is published after and MUST be. The baseline is
        // captured AFTER the stale publish, so the since-seq head sits past it.
        let staleKind = "test.ws.stale.\(UUID().uuidString)"
        EventBus.shared.publish(kind: staleKind, payload: .object(["pre": .bool(true)]))
        let baseline = EventBus.shared.currentSeq

        let task = wsTask(port: port, sinceSeq: baseline)
        try await Task.sleep(nanoseconds: 150_000_000)

        let freshKind = "test.ws.fresh.\(UUID().uuidString)"
        EventBus.shared.publish(kind: freshKind, payload: .object(["post": .bool(true)]))

        // The first non-heartbeat event we see must be the fresh one -- if the stale
        // pre-connect event were delivered we would see it first (lower seq).
        for _ in 0..<50 {
            let message = try await task.receive()
            let data: Data
            switch message {
            case .data(let d): data = d
            case .string(let s): data = Data(s.utf8)
            @unknown default: continue
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if obj["type"] as? String == "heartbeat" { continue }
            let k = obj["kind"] as? String
            XCTAssertNotEqual(k, staleKind,
                              "an event published before the x-rc2-since-seq head must never be delivered (delta-slice contract)")
            if k == freshKind {
                task.cancel(with: .normalClosure, reason: nil)
                return
            }
        }
        XCTFail("did not receive the post-connect event within the frame budget")
    }
}
