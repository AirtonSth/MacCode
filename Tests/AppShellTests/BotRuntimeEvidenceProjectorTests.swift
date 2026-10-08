import XCTest
import CoreModel
import SocketServer
@testable import AppShell

final class BotRuntimeEvidenceProjectorTests: XCTestCase {
    /// WHY: an idempotent replay of a completed Bot receipt must reconcile the
    /// retained exact events its run already published, once and only once.
    func test_reconcilesRetainedEventsPublishedBeforeBindingWithoutDuplicateReplay() throws {
        let bus = EventBus(recentLimit: 8)
        var terminals: [BotRuntimeEvidenceProjector.TerminalEvidence] = []
        let projector = BotRuntimeEvidenceProjector(eventBus: bus) { terminals.append($0) }

        var projected: [EventBus.Event] = []
        let token = bus.subscribe(since: bus.currentSeq) { event in
            if event.kind.hasPrefix("bot.run.") { projected.append(event) }
        }
        defer { bus.unsubscribe(token) }

        bus.publish(kind: .agentItemDelta, payload: agentPayload())
        bus.publish(kind: .agentRunCompleted, payload: agentPayload())

        let receipt = sendReceipt()
        XCTAssertTrue(projector.registerCompletedSend(receipt))
        XCTAssertTrue(projector.registerCompletedSend(receipt))
        // A replay after the terminal was projected must not settle the run twice.
        XCTAssertTrue(projector.registerCompletedSend(receipt))

        XCTAssertEqual(projected.map(\.kind), ["bot.run.stream", "bot.run.completed"])
        XCTAssertEqual(terminals, [.init(botID: "bot-a", runID: "run-a", failed: false)])
    }

    /// WHY: generic Agent events must never advance iOS Bot state unless an
    /// exact completed send receipt first bound their full runtime identity.
    func test_projectsStrictlyOrderedExactStreamAndTerminalEvidence() throws {
        let bus = EventBus(recentLimit: 32)
        var terminals: [BotRuntimeEvidenceProjector.TerminalEvidence] = []
        let projector = BotRuntimeEvidenceProjector(eventBus: bus) { terminals.append($0) }
        let receipt = sendReceipt()
        XCTAssertTrue(projector.registerCompletedSend(receipt))

        var projected: [EventBus.Event] = []
        let token = bus.subscribe(since: bus.currentSeq) { event in
            if event.kind.hasPrefix("bot.run.") { projected.append(event) }
        }
        defer { bus.unsubscribe(token) }

        bus.publish(kind: .agentItemDelta, payload: agentPayload(runID: "wrong-run"))
        bus.publish(kind: .agentItemDelta, payload: agentPayload(threadID: "wrong-thread"))
        bus.publish(kind: .agentItemDelta, payload: agentPayload())
        bus.publish(kind: .agentRunCompleted, payload: agentPayload())
        bus.publish(kind: .agentItemDelta, payload: agentPayload())

        XCTAssertEqual(projected.map(\.kind), ["bot.run.stream", "bot.run.completed"])
        XCTAssertEqual(terminals, [.init(botID: "bot-a", runID: "run-a", failed: false)])
        XCTAssertTrue(zip(projected, projected.dropFirst()).allSatisfy { $0.seq < $1.seq })
        for event in projected {
            let payload = try XCTUnwrap(event.payload.objectValue)
            XCTAssertEqual(payload["host_id"]?.stringValue, "host-a")
            XCTAssertEqual(payload["bot_id"]?.stringValue, "bot-a")
            XCTAssertEqual(payload["conversation_id"]?.stringValue, "conversation-a")
            XCTAssertEqual(payload["request_id"]?.stringValue, "request-a")
            XCTAssertEqual(payload["client_request_id"]?.stringValue, "request-a")
            XCTAssertEqual(payload["run_id"]?.stringValue, "run-a")
        }

        var crossConversation = sendReceipt().objectValue!
        var crossReadback = crossConversation["readback"]!.objectValue!
        var crossRun = crossReadback["run"]!.objectValue!
        crossRun["conversation_id"] = .string("conversation-b")
        crossReadback["run"] = .object(crossRun)
        crossConversation["readback"] = .object(crossReadback)
        XCTAssertFalse(projector.registerCompletedSend(.object(crossConversation)))

        var crossBot = sendReceipt().objectValue!
        var crossBotReadback = crossBot["readback"]!.objectValue!
        var crossBotRun = crossBotReadback["run"]!.objectValue!
        crossBotRun["bot_id"] = .string("bot-b")
        crossBotReadback["run"] = .object(crossBotRun)
        crossBot["readback"] = .object(crossBotReadback)
        XCTAssertFalse(projector.registerCompletedSend(.object(crossBot)))

        var failed = sendReceipt().objectValue!
        failed["status"] = .string("failed")
        XCTAssertFalse(projector.registerCompletedSend(.object(failed)))
    }

    /// WHY: Bot receipts intentionally use lowercase UUIDs while canonical
    /// Agent lifecycle events use Foundation's uppercase UUID spelling. UUID
    /// casing must not strand an otherwise exact Bot run in Working.
    func test_projectsExactTerminalAcrossUUIDCasing() throws {
        let bus = EventBus(recentLimit: 8)
        var terminals: [BotRuntimeEvidenceProjector.TerminalEvidence] = []
        let projector = BotRuntimeEvidenceProjector(eventBus: bus) { terminals.append($0) }
        let runID = "54943aa2-59c1-40e4-b56d-edb6b382edb8"
        let threadID = "2969b74d-0bab-4486-bbf1-8b9a9761f936"
        XCTAssertTrue(projector.registerCompletedSend(sendReceipt(runID: runID, threadID: threadID)))

        bus.publish(kind: .agentRunCompleted, payload: agentPayload(
            runID: runID.uppercased(),
            threadID: threadID.uppercased()
        ))

        XCTAssertEqual(terminals, [.init(botID: "bot-a", runID: runID, failed: false)])
    }

    /// WHY: the host's failure reason must survive Bot runtime projection so
    /// iOS can show the provider's actual error instead of a generic failure.
    func test_projectsFailureMessageIntoBotEvidence() throws {
        let bus = EventBus(recentLimit: 8)
        let projector = BotRuntimeEvidenceProjector(eventBus: bus)
        XCTAssertTrue(projector.registerCompletedSend(sendReceipt()))

        var projected: [EventBus.Event] = []
        let token = bus.subscribe(since: bus.currentSeq) { event in
            if event.kind == "bot.run.failed" { projected.append(event) }
        }
        defer { bus.unsubscribe(token) }

        bus.publish(kind: .agentRunFailed, payload: .object([
            "run_id": .string("run-a"),
            "thread_id": .string("thread-a"),
            "message": .string("Grok ACP failure: balance exhausted"),
        ]))
        bus.flushPersistenceSubmissions()

        XCTAssertEqual(projected.count, 1)
        XCTAssertEqual(
            projected.first?.payload.objectValue?["message"]?.stringValue,
            "Grok ACP failure: balance exhausted"
        )
    }

    /// WHY: `bot.run.stream` carries ids only, so it is liveness evidence, yet
    /// each one costs a frame to every device and flushes the delta coalescing
    /// window. One per token adds one event per token; one per second still
    /// proves the run is alive.
    func test_thousandDeltasOverTwentySecondsPublishAtMostOneStreamTickPerSecond() throws {
        let bus = EventBus(recentLimit: 8)
        var now = Date(timeIntervalSinceReferenceDate: 0)
        let projector = BotRuntimeEvidenceProjector(eventBus: bus, now: { now })
        XCTAssertTrue(projector.registerCompletedSend(sendReceipt()))

        var ticks = 0
        let token = bus.subscribe(since: bus.currentSeq) { event in
            if event.kind == "bot.run.stream" { ticks += 1 }
        }
        defer { bus.unsubscribe(token) }

        // 1,000 tokens 20 ms apart: 20 s of provider output for one bound run.
        for index in 0..<1_000 {
            now = Date(timeIntervalSinceReferenceDate: Double(index * 20) / 1_000)
            bus.publish(kind: .agentItemDelta, payload: agentPayload())
        }
        bus.flushPersistenceSubmissions()

        XCTAssertLessThanOrEqual(ticks, 21, "one tick per token costs one frame per token")
        XCTAssertGreaterThanOrEqual(ticks, 20, "every second of a live run still proves liveness")
    }

    /// WHY: "working" must show on the first token and "finished" on the exact
    /// terminal event. The one-per-second limit may only drop redundant ticks
    /// of the same run, and a dropped tick must not be projected later by a
    /// receipt replay.
    func test_firstStreamTickIsImmediateAndTerminalEvidenceIsNeverThrottled() throws {
        let bus = EventBus(recentLimit: 32)
        var now = Date(timeIntervalSinceReferenceDate: 100)
        var terminals: [BotRuntimeEvidenceProjector.TerminalEvidence] = []
        let projector = BotRuntimeEvidenceProjector(
            eventBus: bus,
            onTerminal: { terminals.append($0) },
            now: { now }
        )
        XCTAssertTrue(projector.registerCompletedSend(sendReceipt()))
        XCTAssertTrue(projector.registerCompletedSend(sendReceipt(runID: "run-b", threadID: "thread-b")))

        var projected: [EventBus.Event] = []
        let token = bus.subscribe(since: bus.currentSeq) { event in
            if event.kind.hasPrefix("bot.run.") { projected.append(event) }
        }
        defer { bus.unsubscribe(token) }
        func projectedRuns() -> [String] {
            projected.map { "\($0.kind) \($0.payload.objectValue?["run_id"]?.stringValue ?? "")" }
        }

        bus.publish(kind: .agentItemDelta, payload: agentPayload())
        bus.flushPersistenceSubmissions()
        XCTAssertEqual(projectedRuns(), ["bot.run.stream run-a"])

        // Same instant: run-a's further ticks are redundant, run-b's first is not.
        bus.publish(kind: .agentItemDelta, payload: agentPayload())
        bus.publish(kind: .agentItemProgress, payload: agentPayload())
        bus.publish(kind: .agentItemDelta, payload: agentPayload(runID: "run-b", threadID: "thread-b"))
        bus.flushPersistenceSubmissions()
        XCTAssertEqual(projectedRuns(), ["bot.run.stream run-a", "bot.run.stream run-b"])

        // Still inside run-b's one-second window.
        bus.publish(kind: .agentRunCompleted, payload: agentPayload(runID: "run-b", threadID: "thread-b"))
        bus.flushPersistenceSubmissions()
        XCTAssertEqual(
            projectedRuns(),
            ["bot.run.stream run-a", "bot.run.stream run-b", "bot.run.completed run-b"]
        )
        XCTAssertEqual(terminals, [.init(botID: "bot-a", runID: "run-b", failed: false)])

        // The dropped run-a ticks stay consumed: a replayed receipt, even
        // after the window has passed, does not publish them.
        now = now.addingTimeInterval(5)
        XCTAssertTrue(projector.registerCompletedSend(sendReceipt()))
        bus.flushPersistenceSubmissions()
        XCTAssertEqual(projected.count, 3)

        bus.publish(kind: .agentItemDelta, payload: agentPayload())
        bus.flushPersistenceSubmissions()
        XCTAssertEqual(projectedRuns().last, "bot.run.stream run-a")
        XCTAssertEqual(projected.count, 4)

        // A wall clock stepped backwards must not hold liveness back.
        now = now.addingTimeInterval(-10)
        bus.publish(kind: .agentItemDelta, payload: agentPayload())
        bus.flushPersistenceSubmissions()
        XCTAssertEqual(projected.count, 5)

        // A failure inside run-a's window is as exact as a completion.
        bus.publish(kind: .agentRunFailed, payload: agentPayload())
        bus.flushPersistenceSubmissions()
        XCTAssertEqual(projectedRuns().last, "bot.run.failed run-a")
        XCTAssertEqual(terminals.last, .init(botID: "bot-a", runID: "run-a", failed: true))
    }

    /// WHY: every phone send pushed the whole retained ring (up to 4,096
    /// events) through the projector on the MainActor, although a new run
    /// cannot have published before its receipt is registered. Only an
    /// idempotent replay of a receipt may need the retained events, and it
    /// must still get them: a replay must not lose the terminal event.
    func test_newReceiptDoesNotReplayRetainedRingButReplayedReceiptStillReconciles() throws {
        let bus = EventBus()
        var terminals: [BotRuntimeEvidenceProjector.TerminalEvidence] = []
        let projector = BotRuntimeEvidenceProjector(eventBus: bus) { terminals.append($0) }

        var projected: [EventBus.Event] = []
        let token = bus.subscribe(since: bus.currentSeq) { event in
            if event.kind.hasPrefix("bot.run.") { projected.append(event) }
        }
        defer { bus.unsubscribe(token) }

        for _ in 0..<(EventBus.defaultRecentLimit - 2) {
            bus.publish(
                kind: .agentItemDelta,
                payload: agentPayload(runID: "other-run", threadID: "other-thread")
            )
        }
        bus.publish(kind: .agentItemDelta, payload: agentPayload())
        bus.publish(kind: .agentRunCompleted, payload: agentPayload())
        XCTAssertEqual(bus.recentCountForTests, EventBus.defaultRecentLimit)

        let receipt = sendReceipt()
        XCTAssertTrue(projector.registerCompletedSend(receipt))
        XCTAssertEqual(projector.replayedEventCountForTesting, 0)

        XCTAssertTrue(projector.registerCompletedSend(receipt))
        bus.flushPersistenceSubmissions()
        // The whole retained ring, plus the two events this replay projected:
        // they are published while the replay subscription is still installed.
        XCTAssertEqual(projector.replayedEventCountForTesting, EventBus.defaultRecentLimit + 2)
        XCTAssertEqual(projected.map(\.kind), ["bot.run.stream", "bot.run.completed"])
        XCTAssertEqual(terminals, [.init(botID: "bot-a", runID: "run-a", failed: false)])
    }

    private func sendReceipt(
        runID: String = "run-a",
        threadID: String = "thread-a"
    ) -> JSONValue {
        .object([
            "status": .string("completed"),
            "host_id": .string("host-a"),
            "bot_id": .string("bot-a"),
            "request_id": .string("request-a"),
            "client_request_id": .string("request-a"),
            "receipt_id": .string("receipt-a"),
            "readback": .object([
                "host_id": .string("host-a"),
                "bot_id": .string("bot-a"),
                "conversation_id": .string("conversation-a"),
                "request_id": .string("request-a"),
                "client_request_id": .string("request-a"),
                "run_id": .string(runID),
                "enqueued": .bool(false),
                "run": .object([
                    "host_id": .string("host-a"),
                    "bot_id": .string("bot-a"),
                    "conversation_id": .string("conversation-a"),
                    "request_id": .string("request-a"),
                    "client_request_id": .string("request-a"),
                    "run_id": .string(runID),
                    "thread_id": .string(threadID),
                ]),
            ]),
        ])
    }

    private func agentPayload(
        runID: String = "run-a",
        threadID: String = "thread-a"
    ) -> JSONValue {
        .object([
            "run_id": .string(runID),
            "thread_id": .string(threadID),
        ])
    }
}
