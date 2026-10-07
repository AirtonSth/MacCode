import XCTest
import RemoteCodeTreaty
@testable import SocketServer

/// WHY (C4 / M5): a 27-reconnect storm left no host-side trace, because only
/// slow-client, outbound-pressure, cloexec and connection-limit closes emitted
/// anything. Every `/v1/ws` close must now be counted per reason in
/// `/v1/health`, and described by a secret-free `diagnostic.ws_connection_closed`
/// event that a storm cannot turn into its own flood.
final class WebSocketCloseDiagnosticsTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 1_000
        var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [[String: JSONValue]] = []
        var payloads: [[String: JSONValue]] { lock.lock(); defer { lock.unlock() }; return stored }
        func append(_ payload: JSONValue) {
            lock.lock(); stored.append(payload.objectValue ?? [:]); lock.unlock()
        }
    }

    private func summary(_ reason: String, code: Int? = 1012) -> WebSocketCloseSummary {
        WebSocketCloseSummary(
            reason: reason, code: code, durationMilliseconds: 1_500,
            sinceSequence: 42, replayExpired: false, framesShed: 0
        )
    }

    func test_stormOfOneReasonEmitsOncePerWindowButCountsEveryClose() {
        let clock = Clock()
        let sink = Sink()
        let diagnostics = WebSocketCloseDiagnostics(
            minimumInterval: 10, now: { clock.now }, publish: { sink.append($0) }
        )

        for _ in 0..<27 {
            diagnostics.record(summary("eventGap"))
            clock.advance(0.5)
        }

        let health = diagnostics.healthJSON()
        XCTAssertEqual((health["by_reason"] as? [String: Int])?["eventGap"], 27, "counters never drop a close")
        XCTAssertEqual(sink.payloads.count, 2, "13.5 s of closes at 10 s per reason -> 2 events")
        XCTAssertEqual(health["events_emitted_total"] as? Int, 2)
        XCTAssertEqual(health["events_suppressed_total"] as? Int, 25)
        XCTAssertEqual(sink.payloads.first?["suppressed_since_last"], .number(0))
        XCTAssertEqual(
            sink.payloads.last?["suppressed_since_last"], .number(19),
            "the next event says how many closes the window hid"
        )
    }

    func test_reasonsAreRateLimitedIndependently() {
        let clock = Clock()
        let sink = Sink()
        let diagnostics = WebSocketCloseDiagnostics(
            minimumInterval: 10, now: { clock.now }, publish: { sink.append($0) }
        )
        XCTAssertTrue(diagnostics.record(summary("eventGap")))
        XCTAssertTrue(diagnostics.record(summary("heartbeatTimeout")))
        XCTAssertFalse(diagnostics.record(summary("eventGap")))
        clock.advance(10)
        XCTAssertTrue(diagnostics.record(summary("eventGap")))
        XCTAssertEqual(sink.payloads.compactMap { $0["reason"]?.stringValue },
                       ["eventGap", "heartbeatTimeout", "eventGap"])
    }

    func test_payloadIsCompactAndSecretFree() throws {
        let sink = Sink()
        let diagnostics = WebSocketCloseDiagnostics(publish: { sink.append($0) })
        diagnostics.record(WebSocketCloseSummary(
            reason: "peerClose", code: nil, durationMilliseconds: 61_000,
            sinceSequence: 9_001, replayExpired: true, framesShed: 3
        ))
        let payload = try XCTUnwrap(sink.payloads.first)
        XCTAssertEqual(Set(payload.keys), [
            "reason", "code", "duration_ms", "since_seq", "replay_expired", "frames_shed", "suppressed_since_last",
        ])
        XCTAssertEqual(payload["code"], .null)
        XCTAssertEqual(payload["duration_ms"], .number(61_000))
        XCTAssertEqual(payload["since_seq"], .number(9_001))
        XCTAssertEqual(payload["replay_expired"], .bool(true))
        XCTAssertEqual(payload["frames_shed"], .number(3))
    }

    func test_closeRecordKeepsTheFirstReason() {
        let record = WebSocketCloseRecord(sinceSequence: 7, openedAt: 100)
        record.recordTerminal("heartbeatTimeout")
        // The read loop then sees EOF after the host shut the socket down.
        record.recordClose(reason: "peerEOF", code: 1006)
        record.markReplayExpired()
        record.recordFramesShed(2)
        record.recordFramesShed(0)
        let summary = record.summary(now: 102.5)
        XCTAssertEqual(summary.reason, "heartbeatTimeout")
        XCTAssertEqual(summary.code, 1012)
        XCTAssertEqual(summary.durationMilliseconds, 2_500)
        XCTAssertEqual(summary.sinceSequence, 7)
        XCTAssertTrue(summary.replayExpired)
        XCTAssertEqual(summary.framesShed, 2)
    }

    func test_terminalReasonsMapToTheCloseCodeTheHostSends() {
        let expected: [(String, String, Int?)] = [
            ("event_gap", "eventGap", 1012),
            ("heartbeatTimeout", "heartbeatTimeout", 1012),
            ("invalidEvent", "invalidEvent", 1011),
            ("write_failed", "writeFailed", 1011),
            ("protocolError", "protocolError", 1002),
            ("peerClose", "peerClose", nil),
        ]
        for (terminal, reason, code) in expected {
            let record = WebSocketCloseRecord(sinceSequence: 0)
            record.recordTerminal(terminal)
            XCTAssertEqual(record.summary().reason, reason, terminal)
            XCTAssertEqual(record.summary().code, code, terminal)
        }
        let silent = WebSocketCloseRecord(sinceSequence: 0)
        XCTAssertEqual(silent.summary().code, 1006, "no close frame at all is RFC 6455 1006")
    }

    /// WHY: eventGap closes used retryAfterMs 0, so every client that lost the
    /// same burst reconnected in the same instant.
    func test_eventGapRetryHintIsJitteredBetween250And1000ms() {
        XCTAssertEqual(WebSocketCloseDiagnostics.eventGapRetryAfterMilliseconds(randomUnit: 0), 250)
        XCTAssertEqual(WebSocketCloseDiagnostics.eventGapRetryAfterMilliseconds(randomUnit: 0.5), 625)
        XCTAssertEqual(WebSocketCloseDiagnostics.eventGapRetryAfterMilliseconds(randomUnit: 1), 1_000)
        XCTAssertEqual(WebSocketCloseDiagnostics.eventGapRetryAfterMilliseconds(randomUnit: .nan), 250)
        let draws = (0..<500).map { _ in WebSocketCloseDiagnostics.eventGapRetryAfterMilliseconds() }
        XCTAssertTrue(draws.allSatisfy { (250...1_000).contains($0) })
        XCTAssertGreaterThan(Set(draws).count, 50, "the hint must actually spread clients out")
    }
}

/// End to end over a real loopback socket: a closed `/v1/ws` connection lands
/// in `/v1/health` and on the event bus with its resume cursor.
@MainActor
final class WebSocketCloseDiagnosticsIntegrationTests: XCTestCase {
    func test_protocolErrorCloseIsCountedInHealthAndPublished() async throws {
        let port = UInt16.random(in: 33000...44000)
        let server = DirectHTTPServer(
            port: port, loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: FakeRouter()),
            serverId: "close-diag-host", bootEpoch: 5
        )
        try server.start()
        defer { server.stop() }

        let since = EventBus.shared.currentSeq
        let observed = LockedPayloads()
        let subscription = EventBus.shared.subscribe(since: since) { event in
            if event.kind == "diagnostic.ws_connection_closed" { observed.append(event.payload) }
        }
        defer { EventBus.shared.unsubscribe(subscription) }

        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
        request.setValue("\(since)", forHTTPHeaderField: "x-rc2-since-seq")
        request.setValue("close-diag-host", forHTTPHeaderField: "x-rc2-resume-host-id")
        request.setValue("5", forHTTPHeaderField: "x-rc2-resume-boot-epoch")
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        _ = try await task.receive() // welcome
        try await task.send(.string("{not-json"))

        let deadline = Date().addingTimeInterval(5)
        while observed.values.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        task.cancel(with: .normalClosure, reason: nil)

        let payload = try XCTUnwrap(observed.values.first?.objectValue)
        XCTAssertEqual(payload["reason"], .string("protocolError"))
        XCTAssertEqual(payload["code"], .number(1002))
        XCTAssertEqual(payload["since_seq"], .number(Double(since)))
        XCTAssertEqual(payload["replay_expired"], .bool(false))

        var healthRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/health")!)
        healthRequest.httpMethod = "GET"
        let (data, _) = try await URLSession.shared.data(for: healthRequest)
        let health = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let closes = try XCTUnwrap(health["connection_closes"] as? [String: Any])
        XCTAssertEqual((closes["by_reason"] as? [String: Int])?["protocolError"], 1)
        let receipts = try XCTUnwrap(health["command_receipts"] as? [String: Any])
        XCTAssertEqual(receipts["push_token_unchanged_skips_total"] as? Int, 0)
    }
}

private final class LockedPayloads: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [JSONValue] = []
    var values: [JSONValue] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ value: JSONValue) { lock.lock(); stored.append(value); lock.unlock() }
}
