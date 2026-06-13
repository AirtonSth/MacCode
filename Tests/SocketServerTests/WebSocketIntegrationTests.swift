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

    private func startServer() throws -> (DirectHTTPServer, UInt16) {
        let port = UInt16.random(in: 33000...44000)
        let server = DirectHTTPServer(port: port, loopbackOnly: true,
                                      dispatcher: JSONRPCDispatcher(router: FakeRouter()))
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
