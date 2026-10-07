import XCTest
@testable import SocketServer
import CoreModel

/// C8 end to end over a real loopback `/v1/ws` and `events.recent`.
/// Why it matters: an iPhone back from minutes in the background used to get
/// `baselineRequired` and download a full snapshot. A client that opts in
/// must instead get the state events it missed, a `streamGap` for exactly the
/// threads whose live deltas were lost, and then the live stream — while a
/// client that did not opt in sees the old welcome shape and the old baseline.
@MainActor
final class DurableReplayWebSocketTests: XCTestCase {
    private let log = FakeDurableEventLog()
    private static let legacyWelcomeKeys: Set<String> = [
        "protocolVersion", "type", "connectionId", "hostId", "bootEpoch",
        "serverTimeEpochMs", "heartbeatIntervalMs", "heartbeatTimeoutMs",
        "snapshotTimeoutMs", "currentSequence", "oldestReplaySequence", "capabilities",
    ]

    override func setUp() {
        super.setUp()
        log.wire(EventBus.shared)
    }

    override func tearDown() {
        FakeDurableEventLog.unwire(EventBus.shared)
        EventBus.shared.clearPreviousBootReplayForTesting()
        super.tearDown()
    }

    // MARK: - Scenario

    private func state(_ marker: String) {
        EventBus.shared.publish(kind: .workspaceUpdated, payload: .object([
            "workspace_id": .string("w-durable"), "name": .string(marker),
        ]))
    }

    private func delta(_ thread: String, bytes: Int = 8) {
        EventBus.shared.publish(kind: .agentItemDelta, payload: .object([
            "thread_id": .string(thread), "item_id": .string("i-\(thread)"),
            "delta": .string(String(repeating: "x", count: bytes)),
        ]))
    }

    /// The client saw through `cursor`; then a gap long enough that the
    /// 2 MiB ring dropped everything up to the flood's tail.
    private func evictedRingScenario() -> (cursor: Int64, gapThread: String, floodThread: String, okThread: String) {
        let suffix = UUID().uuidString.prefix(8)
        let gapThread = "t-gap-\(suffix)", floodThread = "t-flood-\(suffix)", okThread = "t-ok-\(suffix)"
        state("anchor")
        let cursor = EventBus.shared.currentSeq
        delta(gapThread)
        state("m1")
        state("m2")
        for _ in 0..<40 { delta(floodThread, bytes: 64 * 1_024) }
        state("m3")
        delta(okThread)
        return (cursor, gapThread, floodThread, okThread)
    }

    // MARK: - Helpers

    private func startServer(bootEpoch: UInt64 = 42) throws -> (DirectHTTPServer, UInt16) {
        var lastError: Error?
        for _ in 0..<10 {
            let port = UInt16.random(in: 33000...44000)
            let server = DirectHTTPServer(
                port: port, loopbackOnly: true,
                dispatcher: JSONRPCDispatcher(router: FakeRouter()),
                serverId: "durable-host", bootEpoch: bootEpoch
            )
            do { try server.start(); return (server, port) } catch { lastError = error }
        }
        throw lastError!
    }

    private func socket(
        port: UInt16, since: Int64, durable: Bool,
        resumeEpoch: Int64? = nil
    ) -> URLSessionWebSocketTask {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
        request.setValue("\(since)", forHTTPHeaderField: "X-RC2-Since-Seq")
        if durable { request.setValue("v1", forHTTPHeaderField: "X-RC2-Durable-Replay") }
        if let resumeEpoch {
            request.setValue("durable-host", forHTTPHeaderField: "X-RC2-Resume-Host-Id")
            request.setValue("\(resumeEpoch)", forHTTPHeaderField: "X-RC2-Resume-Boot-Epoch")
        }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 4 * 1_024 * 1_024
        task.resume()
        return task
    }

    private func next(_ task: URLSessionWebSocketTask, seconds: Double = 5) async throws -> [String: Any] {
        let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: data = Data()
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Reads frames (skipping heartbeats) until `stop` returns true.
    private func frames(
        _ task: URLSessionWebSocketTask,
        budget: Int = 400,
        until stop: ([String: Any]) -> Bool
    ) async throws -> [[String: Any]] {
        var collected: [[String: Any]] = []
        for _ in 0..<budget {
            let frame = try await next(task)
            if frame["type"] as? String == "heartbeat" { continue }
            collected.append(frame)
            if stop(frame) { return collected }
        }
        XCTFail("frame budget exhausted")
        return collected
    }

    private func marker(_ frame: [String: Any]) -> String? {
        (frame["payload"] as? [String: Any])?["name"] as? String
    }

    // MARK: - Tests

    func test_durableSocket_afterEvictedRing_replaysMissedState_gapsLostThreads_thenGoesLive() async throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let scenario = evictedRingScenario()
        let task = socket(port: port, since: scenario.cursor, durable: true)
        defer { task.cancel(with: .goingAway, reason: nil) }

        let welcome = try await next(task)
        XCTAssertEqual(welcome["type"] as? String, "welcome")
        XCTAssertEqual((welcome["replayFromSequence"] as? NSNumber)?.int64Value, scenario.cursor,
                       "the socket promises a replay from the client's own cursor")
        XCTAssertEqual((welcome["oldestReplaySequence"] as? NSNumber)?.int64Value, scenario.cursor + 1)
        XCTAssertTrue((welcome["capabilities"] as? [String])?.contains("events.durable_replay_v1") == true)
        XCTAssertNoThrow(try ConnectionTransportFrame.decodeStrict(
            JSONSerialization.data(withJSONObject: welcome)
        ))

        var gapThreads = Set<String>()
        let backlog = try await frames(task) { frame in
            if frame["type"] as? String == "streamGap", let thread = frame["threadId"] as? String {
                gapThreads.insert(thread)
            }
            return frame["type"] as? String == "replayComplete"
        }
        XCTAssertEqual((backlog.last?["throughSequence"] as? NSNumber)?.int64Value,
                       (welcome["currentSequence"] as? NSNumber)?.int64Value,
                       "catch-up ends exactly at the welcome head")
        let lastEvent = try XCTUnwrap(backlog.lastIndex { $0["type"] as? String == "event" })
        let firstGap = try XCTUnwrap(backlog.firstIndex { $0["type"] as? String == "streamGap" })
        XCTAssertLessThan(lastEvent, firstGap, "gaps follow the replayed events, so a tail refetch lands on top")
        XCTAssertFalse(backlog.contains { $0["type"] as? String == "baselineRequired" })
        XCTAssertFalse(backlog.contains {
            ($0["payload"] as? [String: Any])?["thread_id"] as? String == scenario.floodThread
        }, "a gapped thread is refetched whole; its ring deltas would be wasted bytes")
        XCTAssertEqual(backlog.compactMap(marker), ["m1", "m2", "m3"],
                       "state events from the event log, then the ring, in order")
        XCTAssertEqual(gapThreads, [scenario.gapThread, scenario.floodThread],
                       "only the threads that lost deltas after the cursor")
        XCTAssertTrue(backlog.contains {
            ($0["payload"] as? [String: Any])?["thread_id"] as? String == scenario.okThread
        }, "a delta still in the ring is replayed, not gapped")
        let sequences = backlog.compactMap { ($0["sequence"] as? NSNumber)?.int64Value }
        XCTAssertEqual(sequences, sequences.sorted())

        state("m4-live")
        let live = try await frames(task) { self.marker($0) == "m4-live" }
        XCTAssertEqual(live.compactMap(marker), ["m4-live"])
    }

    func test_legacySocket_sameScenario_keepsOldWelcome_andGetsBaselineRequired() async throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let scenario = evictedRingScenario()
        let task = socket(port: port, since: scenario.cursor, durable: false)
        defer { task.cancel(with: .goingAway, reason: nil) }

        let welcome = try await next(task)
        XCTAssertEqual(Set(welcome.keys), Self.legacyWelcomeKeys, "an old iOS build decodes welcome with exact keys")
        let first = try await frames(task) { _ in true }
        XCTAssertEqual(first.first?["type"] as? String, "baselineRequired")
    }

    func test_durableSocket_logPrunedPastCursor_getsBaselineRequired() async throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        let scenario = evictedRingScenario()
        log.prune(through: scenario.cursor)
        let task = socket(port: port, since: scenario.cursor, durable: true)
        defer { task.cancel(with: .goingAway, reason: nil) }

        let welcome = try await next(task)
        let current = (welcome["currentSequence"] as? NSNumber)?.int64Value
        XCTAssertEqual((welcome["replayFromSequence"] as? NSNumber)?.int64Value, current,
                       "replayFromSequence == currentSequence announces the baseline")
        let first = try await frames(task) { _ in true }
        XCTAssertEqual(first.first?["type"] as? String, "baselineRequired")
    }

    func test_durableSocket_logReplayOverBudget_getsBaselineRequired() async throws {
        let (server, port) = try startServer()
        defer { server.stop() }
        state("anchor")
        let cursor = EventBus.shared.currentSeq
        let text = String(repeating: "state ", count: 70)
        for index in 0..<700 { state("big-\(index) \(text)") }
        for _ in 0..<40 { delta("t-flood-budget", bytes: 64 * 1_024) }
        let task = socket(port: port, since: cursor, durable: true)
        defer { task.cancel(with: .goingAway, reason: nil) }

        let welcome = try await next(task)
        XCTAssertEqual((welcome["replayFromSequence"] as? NSNumber)?.int64Value,
                       (welcome["currentSequence"] as? NSNumber)?.int64Value,
                       "about 400 KB of log replay costs more than a baseline")
        let first = try await frames(task) { _ in true }
        XCTAssertEqual(first.first?["type"] as? String, "baselineRequired")
    }

    func test_durableSocket_previousBootCursor_replays_withRecordedLostThreads() async throws {
        let (server, port) = try startServer(bootEpoch: 42)
        defer { server.stop() }
        state("anchor")
        let cursor = EventBus.shared.currentSeq
        state("old-boot-tail")
        EventBus.shared.installPreviousBootReplay(EventBus.PreviousBootReplay(
            bootEpoch: 41,
            highWater: EventBus.shared.currentSeq,
            lostStreams: [.thread("t-old"): EventBus.shared.currentSeq, .thread("t-seen"): cursor],
            minimumCursor: 0
        ))
        state("new-boot")

        let task = socket(port: port, since: cursor, durable: true, resumeEpoch: 41)
        defer { task.cancel(with: .goingAway, reason: nil) }
        let welcome = try await next(task)
        XCTAssertEqual((welcome["replayFromSequence"] as? NSNumber)?.int64Value, cursor)
        var gaps: [String] = []
        let backlog = try await frames(task) { frame in
            if frame["type"] as? String == "streamGap" { gaps.append(frame["threadId"] as? String ?? "") }
            return frame["type"] as? String == "replayComplete"
        }
        XCTAssertEqual(backlog.compactMap(marker), ["old-boot-tail", "new-boot"])
        XCTAssertEqual(gaps, ["t-old"], "a stream lost at or before the cursor is not reported")

        let legacy = socket(port: port, since: cursor, durable: false, resumeEpoch: 41)
        defer { legacy.cancel(with: .goingAway, reason: nil) }
        let legacyWelcome = try await next(legacy)
        XCTAssertNil(legacyWelcome["replayFromSequence"], "without opt-in a restart still means baseline")
    }

    func test_eventsRecentDurable_pagesLogAndRing_andReportsGaps_legacyStillBaselines() async throws {
        let scenario = evictedRingScenario()
        let dispatcher = JSONRPCDispatcher(router: FakeRouter())
        func call(_ params: [String: JSONValue]) async -> JSONRPCResponse {
            await dispatcher.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "events.recent", params: params))
        }

        let legacy = await call(["since_seq": .number(Double(scenario.cursor))])
        XCTAssertEqual(legacy.result?.objectValue?["requires_baseline"]?.boolValue, true)
        XCTAssertNil(legacy.result?.objectValue?["stream_gaps"], "old response shape unchanged")

        var since = scenario.cursor
        var markers: [String] = []
        var gapThreads = Set<String>()
        for _ in 0..<40 {
            let response = await call([
                "since_seq": .number(Double(since)), "max_bytes": .number(300_000), "durable": .bool(true),
            ])
            let result = try XCTUnwrap(response.result?.objectValue)
            XCTAssertEqual(result["requires_baseline"]?.boolValue, false)
            for gap in result["stream_gaps"]?.arrayValue ?? [] {
                if let thread = gap.objectValue?["thread_id"]?.stringValue { gapThreads.insert(thread) }
            }
            let events = result["events"]?.arrayValue ?? []
            markers += events.compactMap { $0.objectValue?["payload"]?.objectValue?["name"]?.stringValue }
            if result["truncated"]?.boolValue != true { break }
            since = Int64(try XCTUnwrap(events.last?.objectValue?["seq"]?.intValue))
        }
        XCTAssertEqual(markers, ["m1", "m2", "m3"])
        XCTAssertEqual(gapThreads, [scenario.gapThread, scenario.floodThread])

        let bad = await call(["since_seq": .number(0), "durable": .string("yes")])
        XCTAssertEqual(bad.error?.code, -32602)
    }
}
