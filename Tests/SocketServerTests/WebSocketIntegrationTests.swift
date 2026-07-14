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
        clientReceiveTimeoutSeconds: Int = 20,
        webSocketOutboundMaxQueuedBytes: Int = DirectHTTPServer.maxWebSocketOutboundQueuedBytes,
        serverId: String = "test-host",
        bootEpoch: UInt64 = 42
    ) throws -> (DirectHTTPServer, UInt16) {
        let port = UInt16.random(in: 33000...44000)
        let server = DirectHTTPServer(port: port, loopbackOnly: true,
                                      dispatcher: JSONRPCDispatcher(router: FakeRouter()),
                                      serverId: serverId,
                                      bootEpoch: bootEpoch,
                                      clientReceiveTimeoutSeconds: clientReceiveTimeoutSeconds,
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

    private func object(from message: URLSessionWebSocketTask.Message) throws -> [String: Any] {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw TimeoutError.timedOut
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func uniqueEventKind(_ prefix: String) -> String {
        let suffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        return "\(prefix).\(suffix)"
    }

    func test_CONN001_firstFrameIsCanonicalWelcomeBeforeReplay() async throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)

        let baseline = EventBus.shared.currentSeq
        let task = wsTask(port: port, sinceSeq: baseline)
        defer { task.cancel(with: .normalClosure, reason: nil) }

        let obj = try object(from: await receiveWithTimeout(task))
        XCTAssertEqual(obj["type"] as? String, "welcome",
                       "the authenticated socket must establish v3 identity before replay or live events")
        XCTAssertEqual(obj["protocolVersion"] as? Int, 3)
        XCTAssertEqual(obj["hostId"] as? String, "test-host")
        XCTAssertGreaterThan((obj["bootEpoch"] as? NSNumber)?.uint64Value ?? 0, 0)
        XCTAssertNotNil(obj["connectionId"] as? String)
        XCTAssertEqual((obj["currentSequence"] as? NSNumber)?.int64Value, baseline)
        XCTAssertNotNil(obj["oldestReplaySequence"])
        XCTAssertEqual((obj["heartbeatIntervalMs"] as? NSNumber)?.int64Value, 5_000)
        XCTAssertEqual((obj["heartbeatTimeoutMs"] as? NSNumber)?.int64Value, 10_000)
        XCTAssertEqual(obj["capabilities"] as? [String], [
            "events.replay", "jsonrpc.batch", "snapshot.v3",
        ])
    }

    func testWebSocketSendsImmediateFrameBeforeReceiveTimeout() async throws {
        let (server, port) = try startServer(clientReceiveTimeoutSeconds: 1)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)

        let task = wsTask(port: port, sinceSeq: EventBus.shared.currentSeq)
        defer { task.cancel(with: .normalClosure, reason: nil) }

        let message = try await receiveWithTimeout(task, seconds: 0.5)
        let data: Data
        switch message {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default:
            XCTFail("unexpected websocket message type")
            return
        }
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "welcome",
                       "the host must send v3 identity immediately and before the receive timeout")
    }

    func testWebSocketAnswersTheInitialIOSPingWhileReceivingTheImmediateWelcome() async throws {
        let (server, port) = try startServer(clientReceiveTimeoutSeconds: 5)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)

        let task = wsTask(port: port, sinceSeq: EventBus.shared.currentSeq)
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let welcome = expectation(description: "the receive pump drains the immediate welcome")
        let receiver = Task {
            var sawFirstMessage = false
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard !sawFirstMessage else { continue }
                    sawFirstMessage = true
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default:
                        XCTFail("unexpected websocket message type")
                        return
                    }
                    let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    XCTAssertEqual(obj["type"] as? String, "welcome",
                                   "the receive pump must preserve the first application frame")
                    welcome.fulfill()
                } catch {
                    return
                }
            }
        }
        defer { receiver.cancel() }
        let pong = expectation(description: "the host answers URLSession's initial ping")
        task.sendPing { error in
            XCTAssertNil(error,
                         "iOS uses this pong as its transport barrier before replaying missed events")
            pong.fulfill()
        }

        await fulfillment(of: [pong, welcome], timeout: 2)
    }

    func test_CONN002_malformedOrUnknownClientEnvelope_failsClosedWithTypedErrorAndClosing() async throws {
        for invalid in [
            "{not-json",
            #"{"protocolVersion":3,"type":"unknown","unexpected":true}"#,
        ] {
            let (server, port) = try startServer()
            let task = wsTask(port: port, sinceSeq: EventBus.shared.currentSeq)
            let welcome = try object(from: await receiveWithTimeout(task))
            XCTAssertEqual(welcome["type"] as? String, "welcome")

            try await task.send(.string(invalid))
            let error = try object(from: await receiveWithTimeout(task))
            XCTAssertEqual(error["type"] as? String, "error")
            XCTAssertEqual(error["protocolVersion"] as? Int, 3)
            XCTAssertEqual(error["code"] as? String, "protocolError")
            XCTAssertEqual(error["retryable"] as? Bool, false)
            XCTAssertNil(error["unexpected"], "safe protocol diagnostics must never echo unknown input fields")

            let closing = try object(from: await receiveWithTimeout(task))
            XCTAssertEqual(closing["type"] as? String, "closing")
            XCTAssertEqual(closing["reason"] as? String, "protocolError")
            XCTAssertEqual(closing["retryable"] as? Bool, false)
            task.cancel(with: .normalClosure, reason: nil)
            server.stop()
        }
    }

    func test_CONN003_eventFrameUsesWelcomeOwnershipAndContiguousSequence() async throws {
        let (server, port) = try startServer(serverId: "event-host")
        defer { server.stop() }
        let baseline = EventBus.shared.currentSeq
        let task = wsTask(port: port, sinceSeq: baseline)
        defer { task.cancel(with: .normalClosure, reason: nil) }

        let welcome = try object(from: await receiveWithTimeout(task))
        XCTAssertEqual(welcome["type"] as? String, "welcome")
        let connectionId = try XCTUnwrap(welcome["connectionId"] as? String)
        let bootEpoch = try XCTUnwrap((welcome["bootEpoch"] as? NSNumber)?.uint64Value)
        let kind = uniqueEventKind("test.ws.typed_event")
        EventBus.shared.publish(kind: kind, payload: .object(["value": .number(7)]))

        let event = try await receiveEvent(task, kind: kind)
        XCTAssertEqual(event["type"] as? String, "event")
        XCTAssertEqual(event["protocolVersion"] as? Int, 3)
        XCTAssertEqual(event["connectionId"] as? String, connectionId)
        XCTAssertEqual(event["hostId"] as? String, "event-host")
        XCTAssertEqual((event["bootEpoch"] as? NSNumber)?.uint64Value, bootEpoch)
        XCTAssertEqual((event["sequence"] as? NSNumber)?.int64Value, baseline + 1)
        XCTAssertNil(event["seq"], "v3 events must use the canonical sequence field")
    }

    func test_CONN005_welcomeExposesReplayWindowForGapDetection() async throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        EventBus.shared.publish(kind: "test.ws.replay_window", payload: .object([:]))
        let expected = EventBus.shared.snapshot()
        let task = wsTask(port: port, sinceSeq: expected.lastSeq)
        defer { task.cancel(with: .normalClosure, reason: nil) }

        let welcome = try object(from: await receiveWithTimeout(task))
        XCTAssertEqual((welcome["currentSequence"] as? NSNumber)?.int64Value, expected.lastSeq)
        XCTAssertEqual(
            (welcome["oldestReplaySequence"] as? NSNumber)?.int64Value,
            expected.recent.first?.seq ?? expected.lastSeq
        )
    }

    func test_CONN006_simultaneousSocketsUseDistinctConnectionIDsWithOneHostEpoch() async throws {
        let baselineSubscribers = EventBus.shared.subscriberCountForTests
        let (server, port) = try startServer(serverId: "stable-host")
        defer { server.stop() }

        let first = wsTask(port: port, sinceSeq: EventBus.shared.currentSeq)
        let second = wsTask(port: port, sinceSeq: EventBus.shared.currentSeq)
        defer {
            first.cancel(with: .normalClosure, reason: nil)
            second.cancel(with: .normalClosure, reason: nil)
        }
        async let firstMessage = receiveWithTimeout(first)
        async let secondMessage = receiveWithTimeout(second)
        let firstWelcome = try object(from: await firstMessage)
        let secondWelcome = try object(from: await secondMessage)
        let firstConnection = try XCTUnwrap(firstWelcome["connectionId"] as? String)
        let secondConnection = try XCTUnwrap(secondWelcome["connectionId"] as? String)
        XCTAssertNotEqual(secondConnection, firstConnection,
                          "connectionId must identify one physical socket, not the host process")
        XCTAssertEqual(firstWelcome["hostId"] as? String, "stable-host")
        XCTAssertEqual(secondWelcome["hostId"] as? String, "stable-host")
        XCTAssertEqual(
            (secondWelcome["bootEpoch"] as? NSNumber)?.uint64Value,
            (firstWelcome["bootEpoch"] as? NSNumber)?.uint64Value
        )

        first.cancel(with: .normalClosure, reason: nil)
        second.cancel(with: .normalClosure, reason: nil)
        let cleanedUp = await waitUntil {
            EventBus.shared.subscriberCountForTests == baselineSubscribers
        }
        XCTAssertTrue(cleanedUp)
    }

    func test_CONN006_controlledHostRestartKeepsHostIDAndChangesBootEpoch() async throws {
        let (firstServer, firstPort) = try startServer(serverId: "restart-host", bootEpoch: 41)
        let first = wsTask(port: firstPort, sinceSeq: EventBus.shared.currentSeq)
        let firstWelcome = try object(from: await receiveWithTimeout(first))
        first.cancel(with: .normalClosure, reason: nil)
        firstServer.stop()

        let (secondServer, secondPort) = try startServer(serverId: "restart-host", bootEpoch: 42)
        defer { secondServer.stop() }
        let second = wsTask(port: secondPort, sinceSeq: EventBus.shared.currentSeq)
        defer { second.cancel(with: .normalClosure, reason: nil) }
        let secondWelcome = try object(from: await receiveWithTimeout(second))

        XCTAssertEqual(firstWelcome["hostId"] as? String, secondWelcome["hostId"] as? String)
        XCTAssertEqual((firstWelcome["bootEpoch"] as? NSNumber)?.uint64Value, 41)
        XCTAssertEqual((secondWelcome["bootEpoch"] as? NSNumber)?.uint64Value, 42,
                       "a controlled process restart must publish the newly persisted boot epoch")
    }

    func test_CONN009_pingPongIsLivenessAuthorityAndWelcomeAdvertisesDeadline() async throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let task = wsTask(port: port, sinceSeq: EventBus.shared.currentSeq)
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let welcome = try object(from: await receiveWithTimeout(task))
        XCTAssertGreaterThan((welcome["heartbeatTimeoutMs"] as? NSNumber)?.int64Value ?? 0, 0)
        let receiver = Task {
            while !Task.isCancelled {
                do { _ = try await task.receive() } catch { return }
            }
        }
        defer { receiver.cancel() }

        let pong = expectation(description: "RFC ping receives pong")
        task.sendPing { error in
            XCTAssertNil(error)
            pong.fulfill()
        }
        await fulfillment(of: [pong], timeout: 3)
    }

    func test_CONN009_typedHeartbeatFollowsWelcomeAndKeepsConnectionIdentity() async throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let task = wsTask(port: port, sinceSeq: EventBus.shared.currentSeq)
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let welcome = try object(from: await receiveWithTimeout(task))
        XCTAssertEqual((welcome["heartbeatTimeoutMs"] as? NSNumber)?.int64Value, 10_000)
        let connectionId = try XCTUnwrap(welcome["connectionId"] as? String)

        let heartbeat = try object(from: await receiveWithTimeout(task, seconds: 6))
        XCTAssertEqual(heartbeat["type"] as? String, "heartbeat")
        XCTAssertEqual(heartbeat["connectionId"] as? String, connectionId)
        XCTAssertEqual(heartbeat["hostId"] as? String, welcome["hostId"] as? String)
        XCTAssertEqual(
            (heartbeat["bootEpoch"] as? NSNumber)?.uint64Value,
            (welcome["bootEpoch"] as? NSNumber)?.uint64Value
        )
        XCTAssertNotNil(heartbeat["lastReceivedSequence"])
        XCTAssertNil(heartbeat["sequence"], "typed heartbeat is sequence-neutral")
        XCTAssertFalse((heartbeat["nonce"] as? String)?.isEmpty ?? true)

        let kind = uniqueEventKind("test.ws.after_heartbeat")
        EventBus.shared.publish(kind: kind, payload: .object(["live": .bool(true)]))
        let event = try await receiveEvent(task, kind: kind)
        XCTAssertEqual(event["connectionId"] as? String, connectionId)
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

    func testSlowClientQueueFullClosesLiveWebSocketWithTypedClosingFrame() async throws {
        let (server, port) = try startServer(webSocketOutboundMaxQueuedBytes: 128)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 80_000_000)

        let task = wsTask(port: port, sinceSeq: EventBus.shared.currentSeq)
        defer { task.cancel(with: .normalClosure, reason: nil) }
        try await Task.sleep(nanoseconds: 150_000_000)

        let kind = uniqueEventKind("test.ws.queuefull")
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
            if obj["type"] as? String == "closing" {
                XCTAssertEqual(obj["reason"] as? String, "queue_full",
                               "live WS slow-client close must carry the stable queue_full reason")
                XCTAssertEqual(obj["retryable"] as? Bool, true,
                               "client recovery must be explicit after a queue_full close")
                let dropped = await waitUntil { server.wsTracker.slowClientDrops >= 1 }
                XCTAssertTrue(dropped, "live queue_full close must increment slow-client diagnostics")
                return
            }
        }

        XCTFail("live queue_full path must send a typed closing frame before shutting down the socket")
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
        let kind = uniqueEventKind("test.ws.compress")
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
        let droppedKind = uniqueEventKind("diagnostic.test")   // priority .diagnostic -> filtered out
        let keptKind = uniqueEventKind("test.ws.critical")     // default -> .critical -> kept
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

        let kind = uniqueEventKind("test.ws.roundtrip")
        EventBus.shared.publish(kind: kind, payload: .object(["hello": .string("ws"), "n": .number(7)]))

        let obj = try await receiveEvent(task, kind: kind)
        let payload = obj["payload"] as? [String: Any]
        XCTAssertEqual(payload?["hello"] as? String, "ws",
                       "the live WS client must receive the exact payload published on EventBus after the handshake")
        XCTAssertNotNil(obj["sequence"], "delivered events must carry an ordering sequence")
        if let seq = (obj["sequence"] as? NSNumber)?.int64Value {
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
        let staleKind = uniqueEventKind("test.ws.stale")
        EventBus.shared.publish(kind: staleKind, payload: .object(["pre": .bool(true)]))
        let baseline = EventBus.shared.currentSeq

        let task = wsTask(port: port, sinceSeq: baseline)
        try await Task.sleep(nanoseconds: 150_000_000)

        let freshKind = uniqueEventKind("test.ws.fresh")
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
