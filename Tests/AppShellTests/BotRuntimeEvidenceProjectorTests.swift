import XCTest
import CoreModel
import SocketServer
@testable import AppShell
@testable import Persistence

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
        projector.flushTerminalsForTesting()
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
        projector.flushTerminalsForTesting()
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

        projector.flushTerminalsForTesting()
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
        projector.flushTerminalsForTesting()
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
        projector.flushTerminalsForTesting()
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
        projector.flushTerminalsForTesting()
        XCTAssertEqual(terminals, [.init(botID: "bot-a", runID: "run-a", failed: false)])
    }

    /// WHY: the settle behind `onTerminal` reads fleet attention and writes
    /// the sidecar in SQLite. Run on the EventBus delivery lane, a slow settle
    /// held back the phone's `bot.run.completed` and every other publisher,
    /// other Bots' terminal events included. It must run off the lane, and
    /// still once per run and in the order the runs ended.
    func test_heldSettleDoesNotHoldBackTerminalEvidenceAndSettlesOncePerRunInOrder() throws {
        let bus = EventBus(recentLimit: 32)
        let settleStarted = DispatchSemaphore(value: 0)
        let releaseSettle = DispatchSemaphore(value: 0)
        var terminals: [BotRuntimeEvidenceProjector.TerminalEvidence] = []
        var settlesHeldUntilReleased = 0
        let projector = BotRuntimeEvidenceProjector(eventBus: bus) { terminal in
            settleStarted.signal()
            // Stands in for a settle waiting on SQLite. Bounded, so a settle
            // on the delivery lane fails this test instead of hanging it.
            if releaseSettle.wait(timeout: .now() + 10) == .success { settlesHeldUntilReleased += 1 }
            terminals.append(terminal)
        }
        XCTAssertTrue(projector.registerCompletedSend(sendReceipt()))
        XCTAssertTrue(projector.registerCompletedSend(sendReceipt(runID: "run-b", threadID: "thread-b")))

        var projected: [String] = []
        let token = bus.subscribe(since: bus.currentSeq) { event in
            guard event.kind.hasPrefix("bot.run.") else { return }
            projected.append("\(event.kind) \(event.payload.objectValue?["run_id"]?.stringValue ?? "")")
        }
        defer { bus.unsubscribe(token) }

        bus.publish(kind: .agentRunCompleted, payload: agentPayload())
        XCTAssertEqual(settleStarted.wait(timeout: .now() + 10), .success)
        // run-a's settle is held. run-b fails meanwhile: its evidence must
        // not wait for run-a's settle.
        bus.publish(kind: .agentRunFailed, payload: agentPayload(runID: "run-b", threadID: "thread-b"))
        bus.flushPersistenceSubmissions()
        XCTAssertEqual(projected, ["bot.run.completed run-a", "bot.run.failed run-b"])

        // A receipt replay while the settle is pending must not queue a second one.
        XCTAssertTrue(projector.registerCompletedSend(sendReceipt()))
        bus.flushPersistenceSubmissions()
        XCTAssertEqual(projected.count, 2)

        releaseSettle.signal()
        releaseSettle.signal()
        projector.flushTerminalsForTesting()
        XCTAssertEqual(
            settlesHeldUntilReleased,
            2,
            "both settles were still held when the terminal evidence above was delivered"
        )
        XCTAssertEqual(terminals, [
            .init(botID: "bot-a", runID: "run-a", failed: false),
            .init(botID: "bot-a", runID: "run-b", failed: true),
        ])
    }

    /// WHY: `settleRuntime` reads attention and writes the sidecar. While
    /// another thread holds the SQLite connection (a long stream flush or
    /// prune), the phone must still get `bot.run.completed` at once, and the
    /// run must still settle exactly once when the connection frees.
    func test_heldSQLiteConnectionDoesNotDelayBotRunCompletedAndTheRunSettlesExactlyOnce() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-bot-projector-settle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }
        let authority = BotRemoteControlAuthority(
            db: db,
            store: BotStore(db: db),
            settings: SettingsStore(db: db),
            appSupportDirectory: supportDir
        )
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "held-create",
            "name": "Held Bot",
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let conversation = try authority.dispatch(method: "bot.conversation.create", params: [
            "client_request_id": "held-conversation",
            "bot_id": botID,
            "title": "Held",
        ])
        let conversationID = try XCTUnwrap(
            (conversation["readback"] as? [String: Any])?["conversation_id"] as? String
        )
        let runID = UUID().uuidString.lowercased()
        let threadID = UUID().uuidString.lowercased()
        authority.onSend = { _, _, _, _, _ in
            [
                "bot_id": botID,
                "conversation_id": conversationID,
                "thread_id": threadID,
                "run_id": runID,
                "queued_follow_up": false,
            ]
        }
        let sent = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "held-send",
            "host_id": "held-host",
            "bot_id": botID,
            "conversation_id": conversationID,
            "text": "Finish while SQLite is busy",
        ])

        let bus = EventBus(recentLimit: 8)
        let settleFinished = DispatchSemaphore(value: 0)
        var settleResults: [Bool] = []
        let projector = BotRuntimeEvidenceProjector(eventBus: bus) { terminal in
            settleResults.append(authority.settleRuntime(
                botID: terminal.botID,
                runID: terminal.runID,
                failed: terminal.failed
            ))
            settleFinished.signal()
        }
        XCTAssertTrue(
            projector.registerCompletedSend(JSONValue.from(sent)),
            "the authority's own bot.send receipt binds the run"
        )

        var projected: [String] = []
        let token = bus.subscribe(since: bus.currentSeq) { event in
            if event.kind.hasPrefix("bot.run.") { projected.append(event.kind) }
        }
        defer { bus.unsubscribe(token) }

        let connectionHeld = DispatchSemaphore(value: 0)
        let releaseConnection = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            db.performSync { _ in
                connectionHeld.signal()
                // Bounded, so a settle on the delivery lane fails this test
                // instead of hanging it.
                _ = releaseConnection.wait(timeout: .now() + 10)
            }
        }
        XCTAssertEqual(connectionHeld.wait(timeout: .now() + 10), .success)

        bus.publish(kind: .agentRunCompleted, payload: agentPayload(runID: runID, threadID: threadID))
        bus.flushPersistenceSubmissions()
        XCTAssertEqual(projected, ["bot.run.completed"])
        XCTAssertEqual(
            settleFinished.wait(timeout: .now()),
            .timedOut,
            "bot.run.completed reached the subscriber while the settle still waits for SQLite"
        )

        releaseConnection.signal()
        XCTAssertEqual(settleFinished.wait(timeout: .now() + 10), .success)
        projector.flushTerminalsForTesting()
        XCTAssertEqual(settleResults, [true], "the exact run settles once")
        let listed = try authority.dispatch(method: "bot.attention.list", params: [:])
        let item = try XCTUnwrap((listed["items"] as? [[String: Any]])?.first {
            $0["bot_id"] as? String == botID
        })
        XCTAssertEqual(item["run_id"] as? String, runID)
        XCTAssertEqual(item["state"] as? String, "finished")
        XCTAssertFalse(
            authority.settleRuntime(botID: botID, runID: runID, failed: false),
            "nothing is left to settle a second time"
        )
    }

    /// WHY: `bot.run.completed` is published before the run is settled, so a
    /// phone read made on that event could be told the run is still working:
    /// "run status unconfirmed" with the answer already on screen. A read
    /// waits on this barrier first. It must cover the settle of the event the
    /// reader has already seen and nothing queued afterwards. (A later settle
    /// that is already running can still delay the read through the
    /// authority's lock; that is unchanged here.)
    func test_barrierTakenWhenTerminalEvidenceArrivesWaitsForThatSettleAndNoLaterOne() throws {
        let bus = EventBus(recentLimit: 32)
        let settleStarted = DispatchSemaphore(value: 0)
        let releaseSettle = DispatchSemaphore(value: 0)
        let barrierPassed = DispatchSemaphore(value: 0)
        let order = TerminalOrderLog()
        let projector = BotRuntimeEvidenceProjector(eventBus: bus) { terminal in
            settleStarted.signal()
            // Stands in for a settle waiting on SQLite. Bounded, so a
            // regression fails this test instead of hanging it.
            _ = releaseSettle.wait(timeout: .now() + 10)
            order.record("settled \(terminal.runID)")
        }
        XCTAssertTrue(projector.registerCompletedSend(sendReceipt()))
        XCTAssertTrue(projector.registerCompletedSend(sendReceipt(runID: "run-b", threadID: "thread-b")))

        let token = bus.subscribe(since: bus.currentSeq) { event in
            guard event.kind == "bot.run.completed" else { return }
            // The reader's reaction, taken the moment the evidence arrives.
            projector.afterQueuedTerminals {
                order.record("barrier")
                barrierPassed.signal()
            }
        }
        defer { bus.unsubscribe(token) }

        bus.publish(kind: .agentRunCompleted, payload: agentPayload())
        bus.flushPersistenceSubmissions()
        XCTAssertEqual(settleStarted.wait(timeout: .now() + 10), .success)
        // run-b ends after the reader took its barrier.
        bus.publish(kind: .agentRunFailed, payload: agentPayload(runID: "run-b", threadID: "thread-b"))
        bus.flushPersistenceSubmissions()
        XCTAssertEqual(
            barrierPassed.wait(timeout: .now()),
            .timedOut,
            "the barrier does not pass while run-a's settle is still running"
        )

        // Releases run-a's settle only; run-b's stays held.
        releaseSettle.signal()
        XCTAssertEqual(barrierPassed.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(
            order.entries,
            ["settled run-a", "barrier"],
            "the barrier passes after the settle queued before it and before the one queued after it"
        )

        releaseSettle.signal()
        projector.flushTerminalsForTesting()
        XCTAssertEqual(order.entries, ["settled run-a", "barrier", "settled run-b"])
    }

    /// WHY: paired reads are served on the MainActor, and a settle can itself
    /// lead to a read. Taking the barrier must never block its caller, or a
    /// read on the main thread or on the settle queue would freeze the host.
    func test_barrierNeverBlocksACallerOnTheMainThreadOrOnTheSettleQueue() throws {
        let bus = EventBus(recentLimit: 8)
        let settleStarted = DispatchSemaphore(value: 0)
        let releaseSettle = DispatchSemaphore(value: 0)
        let passedFromSettleQueue = DispatchSemaphore(value: 0)
        let passedFromMainThread = DispatchSemaphore(value: 0)
        var settleQueueProjector: BotRuntimeEvidenceProjector?
        let projector = BotRuntimeEvidenceProjector(eventBus: bus) { _ in
            // Taken on the settle queue, inside the settle it would wait for.
            settleQueueProjector?.afterQueuedTerminals { passedFromSettleQueue.signal() }
            settleStarted.signal()
            _ = releaseSettle.wait(timeout: .now() + 10)
        }
        settleQueueProjector = projector
        defer { settleQueueProjector = nil }
        XCTAssertTrue(projector.registerCompletedSend(sendReceipt()))

        bus.publish(kind: .agentRunCompleted, payload: agentPayload())
        XCTAssertEqual(settleStarted.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(Thread.isMainThread)
        // Returns at once although the settle it waits for is still held.
        projector.afterQueuedTerminals { passedFromMainThread.signal() }
        XCTAssertEqual(passedFromMainThread.wait(timeout: .now()), .timedOut)

        releaseSettle.signal()
        XCTAssertEqual(passedFromSettleQueue.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(passedFromMainThread.wait(timeout: .now() + 10), .success)
        projector.flushTerminalsForTesting()
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

/// What ran on the projector's settle queue, in order.
private final class TerminalOrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var entries: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func record(_ entry: String) {
        lock.lock()
        recorded.append(entry)
        lock.unlock()
    }
}
