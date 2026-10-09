import XCTest
@testable import AppShell
@testable import CoreModel
@testable import SocketServer
@testable import Persistence
import AgentRuntime

/// C5 perf receipts (host connection: `agent.thread.read` v1 and paired `bot.*`).
///
/// Opt-in measurement, not a pass/fail gate: run with
/// `RC_HOST_CONN_RECEIPTS=1 scripts/isolated-sandbox.sh test --filter HostConnectionThreadReadBotReceiptTests`.
/// Every scenario uses a file-backed AppContext (writer + WAL reader), the
/// production AppCommandRouter + BotsViewModel + JSONRPCDispatcher and a real
/// DirectHTTPServer over loopback TCP with a paired bearer. It only uses API
/// that exists before and after C5, so the same file produces both receipts.
///
/// "Main stall" is the longest a MainActor hop issued from a background task
/// waited while one request was in flight: how long the app's main thread (UI,
/// every other RPC, every event publish) was unavailable because of it.
final class HostConnectionThreadReadBotReceiptTests: XCTestCase {
    private static let warmups = 2
    private static let heldSamples = 7
    private static let idleSamples = 30
    private static let lockHoldSeconds: TimeInterval = 0.25
    private static let requestDelayIntoHoldSeconds: TimeInterval = 0.02
    private static let eventsPerThread = 128
    private static let botCount = 20
    private static let queuedPerBot = 10
    private static let seededBotReceipts = 5_000

    private struct Fixture {
        let context: AppContext
        let router: AppCommandRouter
        let botsViewModel: BotsViewModel
        let server: DirectHTTPServer
        let token: String
        let port: UInt16
        let threadA: AgentThreadID
        let threadB: AgentThreadID
        let bots: [BotID]
    }

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["RC_HOST_CONN_RECEIPTS"] == "1" else {
            throw XCTSkip("set RC_HOST_CONN_RECEIPTS=1 to record host-connection receipts")
        }
    }

    @MainActor
    private func makeFixture() throws -> Fixture {
        let dir = NSTemporaryDirectory() + "RC2HostConnC5Receipt-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: context)
        context.router = router
        let botsViewModel = BotsViewModel(context: context, router: router)
        router.botsViewModel = botsViewModel
        let repo = DeviceTrustRepository(db: context.db)
        let code = try repo.createPairingCode()
        let paired = try XCTUnwrap(repo.redeemPairingCode(code.code, deviceName: "Receipt iPhone"))
        let auth = LocalAuthAdapter(repo: DeviceTrustRepository(db: context.db))

        // Two threads with a full v1 window each (128 events, ~700 B payloads).
        var threadIDs: [AgentThreadID] = []
        for name in ["A", "B"] {
            let thread = AgentThread(title: "receipt thread \(name)", provider: .codex, model: "gpt-5")
            try context.threadRepo.upsert(thread)
            let run = AgentRun(
                threadId: thread.id,
                provider: .codex,
                model: "gpt-5",
                status: .completed,
                startedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
            try context.runRepo.upsert(run)
            for seq in 1...Self.eventsPerThread {
                let turn = "\(name)-turn-\(seq)-" + String(repeating: "x", count: 640)
                try context.runRepo.appendStreamEvent(
                    runId: run.id,
                    seq: seq,
                    kind: "turnStarted",
                    payloadJSON: #"{"turnStarted":{"turnId":"\#(turn)"}}"#
                )
            }
            threadIDs.append(thread.id)
        }

        // 20 bots, 10 queued follow-ups each: the fleet-wide queue a paired
        // device's bot polls used to rescan and re-publish.
        var bots: [BotID] = []
        for index in 0..<Self.botCount {
            let bot = try botsViewModel.create(name: "Receipt Bot \(index)", title: "Receipt")
            bots.append(bot.id)
            for item in 0..<Self.queuedPerBot {
                _ = try context.botStore.enqueueQueuedFollowUp(BotQueuedFollowUpRecord(
                    botID: bot.id,
                    text: "queued follow-up \(item) " + String(repeating: "q", count: 160),
                    payloadJSON: "{}",
                    createdAt: Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(item))
                ))
            }
        }
        botsViewModel.reloadQueuedFollowUpsFromStore()

        var lastError: Error?
        for _ in 0..<20 {
            let port = UInt16.random(in: 33000...44000)
            let server = DirectHTTPServer(
                port: port,
                loopbackOnly: true,
                dispatcher: JSONRPCDispatcher(router: router),
                auth: auth,
                serverId: "receipt-host",
                bootEpoch: 1
            )
            do {
                try server.start()
                return Fixture(
                    context: context,
                    router: router,
                    botsViewModel: botsViewModel,
                    server: server,
                    token: paired.token,
                    port: port,
                    threadA: threadIDs[0],
                    threadB: threadIDs[1],
                    bots: bots
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: "receipt", code: 1)
    }

    private static func threadReadV1Params(_ thread: AgentThreadID) -> [String: Any] {
        [
            "thread_id": thread.value.uuidString,
            "response_version": 1,
            "include_event_watermark": true,
        ]
    }

    // MARK: - agent.thread.read v1

    @MainActor
    func test_receipt_threadReadV1_idle() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        let params = Self.threadReadV1Params(fixture.threadB)
        for _ in 0..<5 { _ = try await Self.rpc(fixture, method: "agent.thread.read", params: params) }
        var latency: [Double] = []
        var stall: [Double] = []
        for _ in 0..<Self.idleSamples {
            let sample = try await Self.rpcWithMainStall(fixture, method: "agent.thread.read", params: params)
            latency.append(sample.latency)
            stall.append(sample.mainStall)
        }
        Self.report("rpc_thread_read_v1_128_events_idle", latency)
        Self.report("main_stall_thread_read_v1_128_events_idle", stall)
    }

    /// Thread A's mirror lock is held for 250 ms (a long stream flush or a
    /// concurrent A snapshot). The device reads thread B.
    @MainActor
    func test_receipt_threadReadV1_otherThreadMirrorLockHeld() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        try await lockHeldReceipt(
            fixture,
            holding: fixture.threadA,
            reading: fixture.threadB,
            name: "thread_read_v1_other_thread_mirror_lock_held_250ms"
        )
    }

    /// Thread A's mirror lock is held for 250 ms and the device reads thread A.
    /// The read must wait (correctness); the main thread must not.
    @MainActor
    func test_receipt_threadReadV1_sameThreadMirrorLockHeld() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        try await lockHeldReceipt(
            fixture,
            holding: fixture.threadA,
            reading: fixture.threadA,
            name: "thread_read_v1_same_thread_mirror_lock_held_250ms"
        )
    }

    @MainActor
    private func lockHeldReceipt(
        _ fixture: Fixture,
        holding: AgentThreadID,
        reading: AgentThreadID,
        name: String
    ) async throws {
        let params = Self.threadReadV1Params(reading)
        _ = try await Self.rpc(fixture, method: "agent.thread.read", params: params)
        var latency: [Double] = []
        var stall: [Double] = []
        for index in 0..<(Self.warmups + Self.heldSamples) {
            let released = Self.holdMirrorLock(fixture.context.coordinator, thread: holding)
            try await Task.sleep(nanoseconds: UInt64(Self.requestDelayIntoHoldSeconds * 1_000_000_000))
            let sample = try await Self.rpcWithMainStall(fixture, method: "agent.thread.read", params: params)
            await Self.waitForRelease(released)
            if index >= Self.warmups {
                latency.append(sample.latency)
                stall.append(sample.mainStall)
            }
        }
        Self.report("rpc_" + name, latency)
        Self.report("main_stall_" + name, stall)
    }

    // MARK: - bot.*

    @MainActor
    func test_receipt_botReceiptStatus_idle() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        let params: [String: Any] = ["client_request_id": "receipt-unknown-request"]
        try await idleBotReceipt(fixture, name: "bot_receipt_status_20_bots_200_queued_idle", method: "bot.receipt.status") { _ in params }
    }

    @MainActor
    func test_receipt_botList_idle() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        try await idleBotReceipt(fixture, name: "bot_list_20_bots_200_queued_idle", method: "bot.list") { _ in [:] }
    }

    @MainActor
    func test_receipt_botSetPinned_idle() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        let bot = fixture.bots[0].value.uuidString.lowercased()
        try await idleBotReceipt(fixture, name: "bot_set_pinned_20_bots_200_queued_idle", method: "bot.set_pinned") { index in
            [
                "client_request_id": "receipt-pin-\(index)-\(UUID().uuidString)",
                "bot_id": bot,
                "pinned": index.isMultiple(of: 2),
            ]
        }
    }

    @MainActor
    private func idleBotReceipt(
        _ fixture: Fixture,
        name: String,
        method: String,
        params: (Int) -> [String: Any]
    ) async throws {
        for index in 0..<5 { _ = try await Self.rpc(fixture, method: method, params: params(-1 - index)) }
        var latency: [Double] = []
        var stall: [Double] = []
        for index in 0..<Self.idleSamples {
            let sample = try await Self.rpcWithMainStall(fixture, method: method, params: params(index))
            latency.append(sample.latency)
            stall.append(sample.mainStall)
        }
        Self.report("rpc_" + name, latency)
        Self.report("main_stall_" + name, stall)
    }

    // MARK: - bot.send

    // A paired `bot.send` to a Bot that is idle and not open on the Mac, on a
    // conversation that already exists, answered by `FakeProviderRunner`: a
    // real coordinator run with one delta, no process and no network. Each
    // scenario records, per send:
    //
    // - `rpc_bot_send_ack_*`, `main_stall_bot_send_ack_*`: request sent to
    //   response read, and the main stall while it was in flight.
    // - `bot_send_start_*`: request sent to `agent.run.started`.
    // - `bot_first_event_*`: request sent to the run's first `bot.run.stream`.
    // - `bot_settle_*`: `agent.run.completed` published to `bot.run.completed`
    //   published.
    // - `bot_settle_read_*`: `agent.run.completed` published to the answer of
    //   one `bot.attention.list` sent when this loop sees `bot.run.completed`
    //   (it looks every 0.25 ms): the moment the phone can show the run as
    //   ended. This is the line that holds the settle of the run.
    // - `main_sqlite_syncs_bot_send_*`: main-thread SQLite waits from the
    //   request to the desk follow-through of the run, this loop's one
    //   `bot.attention.list` included. Recorded as 35 to 37 per send, and the
    //   max as 37 in every scenario of every run: compare the max.
    // - `event_ring_retained_bot_send_*`: events the retained ring held when
    //   the scenario began. The ring belongs to the process.
    //
    // `bot_send_start` and `bot_first_event` end where an EventBus subscriber
    // receives the event, which is where a paired socket is fed. The two
    // settle lines start at the time the bus stamped on `agent.run.completed`
    // when it was published: subscribers are fed in no fixed order, and on a
    // tree whose projector settles the run inside its own delivery, this
    // file's subscriber may see that event only after the settle. The two
    // `*_syncs_*` and `*_retained_*` lines are counts: compare those when the
    // machine is loaded. Signposts named `bot_send_ack`, `bot_send_start`,
    // `bot_first_event` and `bot_settle` exist on `io.remotecode.perf` and
    // time other spans (the MainActor turn that acknowledges; brain read to
    // provider start; receipt bound to first projected event; the settle
    // call), so a signpost is not compared with the RECEIPT line of its name.
    // The stages of `bot_guest_prepare` are signposts only: they need a
    // Docker desktop and are not driven here.
    //
    // The first receipts of these scenarios are not a "before": the speed
    // checkpoints C01m, C07m, C09, C09b and C10 were committed first. Every
    // API this file uses was found at 3b2cdfff7, the tree before them, by
    // symbol lookup; the file has not been compiled or run there. On a quiet
    // machine the true "before" is this file checked out over that tree, one
    // scenario per process, and an "after" compared with it is recorded with
    // the same loop on its own tree:
    //
    //     git worktree add --detach ../macos-bots-before 3b2cdfff7
    //     cd ../macos-bots-before
    //     git checkout feat/design-bots-speed-20261008 -- Tests/AppShellTests/HostConnectionThreadReadBotReceiptTests.swift
    //     for t in botSend_idle botSend_largeReceiptMap botSend_sqliteWriterHeld withFullEventRing_botSend; do
    //       RC_HOST_CONN_RECEIPTS=1 scripts/isolated-sandbox.sh test \
    //         --filter "HostConnectionThreadReadBotReceiptTests/test_receipt_$t" | grep '^RECEIPT'
    //     done
    //
    // The stream's "before" is a count, not a time: the cadence of one tick
    // per token fed to today's batcher, in
    // `BotStreamFrameBaselineTests/test_tickBehindEveryDelta_costsTwoFramesPerTokenOnBothStreams`.

    @MainActor
    func test_receipt_botSend_idle() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        try armBotSend(fixture)
        try await botSendReceipt(fixture, name: "idle", samples: Self.idleSamples)
    }

    /// 5,000 earlier sends left their receipts and claims in the paired Bot
    /// authority. Each Bot mutation serialises both maps whole.
    @MainActor
    func test_receipt_botSend_largeReceiptMap() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        try armBotSend(fixture)
        let seededRequestID = try Self.seedBotReceipts(fixture, count: Self.seededBotReceipts)
        let seeded = try await fixture.router.dispatchPairedBotRemote(
            method: "bot.receipt.status",
            params: ["client_request_id": .string(seededRequestID)]
        )
        XCTAssertEqual(
            seeded.objectValue?["status"]?.stringValue,
            "completed",
            "the authority must have loaded the seeded receipts, or this scenario measures an empty map"
        )
        try await botSendReceipt(fixture, name: "5000_receipts", samples: Self.idleSamples)
    }

    /// Another thread holds the SQLite writer for 250 ms (a long stream flush
    /// or prune) and the send starts 20 ms into the hold. The acknowledgement
    /// writes the user's message and the receipt on the MainActor.
    @MainActor
    func test_receipt_botSend_sqliteWriterHeld() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        try armBotSend(fixture)
        let db = fixture.context.db
        try await botSendReceipt(fixture, name: "sqlite_writer_held_250ms", samples: Self.heldSamples) {
            let started = DispatchSemaphore(value: 0)
            let released = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                db.performSync { _ in
                    started.signal()
                    Thread.sleep(forTimeInterval: Self.lockHoldSeconds)
                }
                released.signal()
            }
            started.wait()
            return released
        }
    }

    /// The retained ring is at its 4,096-event limit, as after a long reply.
    /// Named to sort after every other scenario of this class: the ring
    /// belongs to the process and cannot be emptied again in it.
    @MainActor
    func test_receipt_withFullEventRing_botSend() async throws {
        let fixture = try makeFixture()
        defer { fixture.server.stop() }
        try armBotSend(fixture)
        let thread = UUID().uuidString.lowercased()
        let run = UUID().uuidString.lowercased()
        for index in 0..<EventBus.defaultRecentLimit {
            EventBus.shared.publish(kind: .agentItemDelta, payload: .object([
                "thread_id": .string(thread),
                "run_id": .string(run),
                "item_id": .string("receipt-ring-item"),
                "body_append": .string("token \(index) "),
            ]))
        }
        XCTAssertEqual(
            EventBus.shared.healthCounters().retainedCount,
            EventBus.defaultRecentLimit,
            "the ring must be full, or this scenario measures a shorter one"
        )
        try await botSendReceipt(fixture, name: "ring_4096_events", samples: Self.idleSamples)
    }

    @MainActor
    private func botSendReceipt(
        _ fixture: Fixture,
        name: String,
        samples: Int,
        hold: (() -> DispatchSemaphore)? = nil
    ) async throws {
        // The Bot is created after its provider is in place, and has no
        // queued follow-up of its own: nothing drains into its conversation.
        let bot = try fixture.botsViewModel.create(name: "Receipt Send Bot", title: "Receipt")
        let botID = bot.id.value.uuidString.lowercased()
        Self.reportCounts("event_ring_retained_bot_send_" + name, [EventBus.shared.healthCounters().retainedCount])
        let marks = BotSendMarks()
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { marks.record($0) }
        defer { EventBus.shared.unsubscribe(token) }

        var conversationID: String?
        var ack: [Double] = []
        var stall: [Double] = []
        var start: [Double] = []
        var firstEvent: [Double] = []
        var settle: [Double] = []
        var settleRead: [Double] = []
        var mainSyncs: [Int] = []
        // Send 0 opens the conversation and its Agent thread; it and the next
        // `warmups` sends are not kept.
        for index in 0..<(1 + Self.warmups + samples) {
            let requestID = "receipt-send-\(index)-\(UUID().uuidString)"
            var params: [String: Any] = [
                "client_request_id": requestID,
                "bot_id": botID,
                "text": "receipt send \(index)",
            ]
            if let conversationID { params["conversation_id"] = conversationID }
            let followThroughs = fixture.botsViewModel.followThroughApplyCountForTesting
            let released = hold?()
            if released != nil {
                try await Task.sleep(nanoseconds: UInt64(Self.requestDelayIntoHoldSeconds * 1_000_000_000))
            }
            let syncsBefore = PerfSwitchMetrics.mainThreadSyncCountForTesting()
            let sent = DispatchTime.now()
            let sample = try await Self.rpcWithMainStall(fixture, method: "bot.send", params: params)
            if let released { await Self.waitForRelease(released) }
            let phoneTold = try await Self.awaited(
                "bot.run.completed of \(requestID): the send was queued or refused, or its run never ended"
            ) {
                marks.time("bot.run.completed", requestID: requestID)
            }
            _ = try await Self.rpc(fixture, method: "bot.attention.list")
            let readAnswered = Date().timeIntervalSince1970
            // The next send must find the Bot idle, or the host queues it.
            _ = try await Self.awaited("the desk follow-through of \(requestID)") {
                fixture.botsViewModel.followThroughApplyCountForTesting > followThroughs ? true : nil
            }
            let syncs = PerfSwitchMetrics.mainThreadSyncCountForTesting() - syncsBefore
            let runStarted = try XCTUnwrap(marks.time("agent.run.started", requestID: requestID))
            let firstStream = try XCTUnwrap(
                marks.time("bot.run.stream", requestID: requestID),
                "the run's delta was not projected to bot.run.stream"
            )
            let runEnded = try XCTUnwrap(marks.time("agent.run.completed", requestID: requestID))
            // One delivery lane takes every mark, in the order the events
            // were published. A send out of this order has a wrong mark and
            // must not be recorded as a measurement.
            XCTAssertTrue(
                sent <= runStarted && runStarted <= firstStream && firstStream <= phoneTold && runEnded <= phoneTold,
                "the marks of \(requestID) are out of order"
            )
            let runEndedPublished = try XCTUnwrap(marks.published("agent.run.completed", requestID: requestID))
            let phoneToldPublished = try XCTUnwrap(marks.published("bot.run.completed", requestID: requestID))
            conversationID = try XCTUnwrap(marks.conversationID(requestID: requestID))
            guard index > Self.warmups else { continue }
            ack.append(sample.latency)
            stall.append(sample.mainStall)
            start.append(Self.ms(from: sent, to: runStarted))
            firstEvent.append(Self.ms(from: sent, to: firstStream))
            settle.append((phoneToldPublished - runEndedPublished) * 1000)
            settleRead.append((readAnswered - runEndedPublished) * 1000)
            mainSyncs.append(syncs)
        }
        Self.report("rpc_bot_send_ack_" + name, ack)
        Self.report("main_stall_bot_send_ack_" + name, stall)
        Self.report("bot_send_start_" + name, start)
        Self.report("bot_first_event_" + name, firstEvent)
        Self.report("bot_settle_" + name, settle)
        Self.report("bot_settle_read_" + name, settleRead)
        Self.reportCounts("main_sqlite_syncs_bot_send_" + name, mainSyncs)
    }

    /// Gives the fixture a provider that answers by itself, so a paired
    /// `bot.send` without a route (the Distill default) starts, streams and
    /// ends a real coordinator run. Call it in the MainActor turn that made
    /// the fixture: each Bot `makeFixture` creates queues a catalog refresh,
    /// and one that runs before this catalog is in place lists this
    /// machine's providers instead and the send is refused as unauthenticated.
    @MainActor
    private func armBotSend(_ fixture: Fixture) throws {
        fixture.context.coordinator.replaceProvider(
            .distill,
            runner: FakeProviderRunner(provider: .distill, scenario: .simpleAssistant(reply: "ok"))
        )
        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .distill,
            models: [
                AgentModelDescriptor(id: "main-a", label: "Main A", provider: .distill),
                AgentModelDescriptor(id: "main-b", label: "Main B", provider: .distill),
            ],
            binaryPath: "/usr/bin/true",
            authenticated: true,
            id: "distill-acp",
            capabilitiesOverride: AgentProviderCapabilities(supportsDistillMainEffortAuto: true)
        )
        fixture.router.rememberProviderSnapshotsForSend([snapshot])
        fixture.router.preflightListedProviderSnapshotsForTesting = false
        let suiteName = "rc2-host-conn-bot-send-receipt-" + UUID().uuidString
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { suite.removePersistentDomain(forName: suiteName) }
        let lastModels = AgentLastModelStore(defaults: suite)
        lastModels.remember(model: "main-b", for: .distill)
        fixture.botsViewModel.lastModelStore = lastModels
        fixture.botsViewModel.replaceProvidersForTests([snapshot])
    }

    /// Writes `count` earlier `bot.send` receipts and their claims where the
    /// paired Bot authority loads them, before the first paired request
    /// creates it. Returns one seeded request id.
    @MainActor
    private static func seedBotReceipts(_ fixture: Fixture, count: Int) throws -> String {
        let botID = fixture.bots[0].value.uuidString.lowercased()
        let text = String(repeating: "m", count: 200)
        var receipts: [String: Any] = [:]
        var claims: [String: Any] = [:]
        for index in 0..<count {
            let requestID = "receipt-seeded-send-\(index)"
            let conversationID = UUID().uuidString.lowercased()
            var readback: [String: Any] = [
                "host_id": "receipt-host",
                "bot_id": botID,
                "request_id": requestID,
                "client_request_id": requestID,
                "conversation_id": conversationID,
                "run_id": UUID().uuidString.lowercased(),
            ]
            var run = readback
            run["thread_id"] = UUID().uuidString.lowercased()
            run["status"] = "working"
            run["text"] = text
            readback["enqueued"] = false
            readback["run"] = run
            receipts[requestID] = [
                "request_id": requestID,
                "client_request_id": requestID,
                "receipt_id": UUID().uuidString.lowercased(),
                "status": "completed",
                "host_id": "receipt-host",
                "bot_id": botID,
                "readback": readback,
            ] as [String: Any]
            claims[requestID] = [
                "method": "send",
                "params": #"{"bot_id":"\#(botID)","conversation_id":"\#(conversationID)","host_id":"receipt-host","text":"\#(text)"}"#,
            ]
        }
        let updatedAt = ISO8601DateFormatter().string(from: Date())
        try fixture.context.db.performSync { database in
            for (key, value) in [("bot.remote.receipts", receipts), ("bot.remote.receipt_claims", claims)] {
                let json = try String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self)
                let statement = try database.prepare(
                    "INSERT INTO settings(key, value, updated_at) VALUES(?, ?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at;"
                )
                defer { statement.reset() }
                try statement.bind(1, key)
                try statement.bind(2, json)
                try statement.bind(3, updatedAt)
                _ = try statement.step()
            }
        }
        return "receipt-seeded-send-0"
    }

    // MARK: - Helpers

    private static func ms(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }

    private static func ms(from start: DispatchTime, to end: DispatchTime) -> Double {
        Double(end.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }

    /// Returns what `value` answers, looking every 0.25 ms. A mark that never
    /// arrives fails the scenario; it is never recorded as a missing sample.
    @MainActor
    private static func awaited<T>(_ what: String, _ value: () -> T?) async throws -> T {
        let deadline = DispatchTime.now() + 20.0
        while DispatchTime.now() < deadline {
            if let found = value() { return found }
            try await Task.sleep(nanoseconds: 250_000)
        }
        return try XCTUnwrap(value(), "timed out waiting for \(what)")
    }

    /// When each event of a run first reached an EventBus subscriber, and the
    /// wall-clock time the bus stamped on it when it was published, before
    /// any subscriber was fed. `bot.*` events name the request, so a send
    /// finds its run and its conversation without reading the response.
    private final class BotSendMarks: @unchecked Sendable {
        private let lock = NSLock()
        private var runIDByRequestID: [String: String] = [:]
        private var conversationIDByRequestID: [String: String] = [:]
        private var firstSeen: [String: DispatchTime] = [:]
        private var firstPublished: [String: TimeInterval] = [:]

        func record(_ event: EventBus.Event) {
            let now = DispatchTime.now()
            guard let payload = event.payload.objectValue,
                  let runID = payload["run_id"]?.stringValue?.lowercased() else { return }
            lock.lock(); defer { lock.unlock() }
            if let requestID = payload["client_request_id"]?.stringValue {
                runIDByRequestID[requestID] = runID
                if let conversationID = payload["conversation_id"]?.stringValue {
                    conversationIDByRequestID[requestID] = conversationID
                }
            }
            let key = event.kind + "|" + runID
            if firstSeen[key] == nil {
                firstSeen[key] = now
                firstPublished[key] = event.ts
            }
        }

        func time(_ kind: String, requestID: String) -> DispatchTime? {
            lock.lock(); defer { lock.unlock() }
            guard let runID = runIDByRequestID[requestID] else { return nil }
            return firstSeen[kind + "|" + runID]
        }

        func published(_ kind: String, requestID: String) -> TimeInterval? {
            lock.lock(); defer { lock.unlock() }
            guard let runID = runIDByRequestID[requestID] else { return nil }
            return firstPublished[kind + "|" + runID]
        }

        func conversationID(requestID: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return conversationIDByRequestID[requestID]
        }
    }

    /// Holds `thread`'s mirror lock for `lockHoldSeconds` on another thread,
    /// through the public v1 snapshot entry point (its body runs under the lock).
    private static func holdMirrorLock(_ coordinator: AgentRunCoordinator, thread: AgentThreadID) -> DispatchSemaphore {
        let started = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? coordinator.withMirrorEventSnapshotForThreadReadV1(
                threadId: thread,
                eventLimit: 1,
                maxPayloadBytes: 1_024
            ) { _ in
                started.signal()
                Thread.sleep(forTimeInterval: lockHoldSeconds)
            }
            released.signal()
        }
        started.wait()
        return released
    }

    private static func waitForRelease(_ released: DispatchSemaphore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                released.wait()
                continuation.resume()
            }
        }
    }

    /// Polls MainActor availability from a background task while `body` runs.
    private final class MainStallProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private var worst: Double = 0

        var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

        func record(_ value: Double) {
            lock.lock(); worst = max(worst, value); lock.unlock()
        }

        func stop() -> Double {
            lock.lock(); defer { lock.unlock() }
            running = false
            return worst
        }
    }

    @MainActor
    private static func rpcWithMainStall(
        _ fixture: Fixture,
        method: String,
        params: [String: Any]
    ) async throws -> (latency: Double, mainStall: Double) {
        let probe = MainStallProbe()
        let poller = Task.detached(priority: .userInitiated) {
            while probe.isRunning {
                let t0 = DispatchTime.now()
                await MainActor.run {}
                probe.record(ms(since: t0))
                try? await Task.sleep(nanoseconds: 250_000)
            }
        }
        let latency = try await rpc(fixture, method: method, params: params)
        let stall = probe.stop()
        await poller.value
        return (latency, stall)
    }

    @MainActor
    private static func rpc(
        _ fixture: Fixture,
        method: String,
        params: [String: Any] = [:]
    ) async throws -> Double {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(fixture.port)/v1/rpc")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(fixture.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
        ])
        let t0 = DispatchTime.now()
        let (data, response) = try await URLSession.shared.data(for: request)
        let latency = ms(since: t0)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(object?["error"], "\(method) failed: \(String(decoding: data, as: UTF8.self).prefix(300))")
        return latency
    }

    private static func report(_ name: String, _ samples: [Double]) {
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let index = min(sorted.count - 1, Int((p * Double(sorted.count - 1)).rounded()))
            return sorted[index]
        }
        let rounded = samples.map { ($0 * 1000).rounded() / 1000 }
        let payload: [String: Any] = [
            "scenario": name,
            "n": samples.count,
            "p50_ms": (percentile(0.5) * 1000).rounded() / 1000,
            "p95_ms": (percentile(0.95) * 1000).rounded() / 1000,
            "max_ms": ((sorted.last ?? 0) * 1000).rounded() / 1000,
            "samples_ms": rounded,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        printReceipt(data)
    }

    /// One write per line: redirected to a file, a line left in the stdout
    /// buffer is cut where the buffer fills and XCTest's own output lands
    /// inside it.
    private static func printReceipt(_ data: Data) {
        fflush(stdout)
        print("RECEIPT \(String(decoding: data, as: UTF8.self))")
        fflush(stdout)
    }

    private static func reportCounts(_ name: String, _ counts: [Int]) {
        let payload: [String: Any] = [
            "scenario": name,
            "n": counts.count,
            "min": counts.min() ?? 0,
            "max": counts.max() ?? 0,
            "counts": counts,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        printReceipt(data)
    }
}

/// C00: the stage intervals of the Bot ruler (`bot_send_ack`, `bot_send_start`,
/// `bot_guest_prepare`, `bot_first_event`, `bot_settle`). `OSSignposter` cannot
/// be read back, so their placement is pinned in the source, as
/// `PerfSwitchInstrumentationTests` does for the switch intervals.
final class BotSendStageIntervalPlacementTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(relative),
            encoding: .utf8
        )
    }

    private func assertInOrder(
        _ markers: [String],
        in source: String,
        after anchor: String,
        _ message: String,
        line: UInt = #line
    ) {
        guard var cursor = source.range(of: anchor)?.upperBound else {
            return XCTFail("\(message): missing \(anchor)", line: line)
        }
        for marker in markers {
            guard let found = source[cursor...].range(of: marker) else {
                return XCTFail("\(message): missing or out of order: \(marker)", line: line)
            }
            cursor = found.upperBound
        }
    }

    /// WHY: a Bot speed change is compared stage by stage in Instruments. An
    /// interval that opens after its stage's work, or closes before it, files
    /// that work under no stage or under another one, and the comparison
    /// then credits or blames the wrong change.
    func test_eachStageIntervalOpensBeforeAndClosesAfterTheWorkItIsNamedFor() throws {
        let router = try source("Sources/AppShell/AppCommandRouter.swift")
        assertInOrder(
            [
                #"signposter.beginInterval("bot_send_ack""#,
                "defer {",
                #"signposter.endInterval("bot_send_ack", sendAckInterval)"#,
                "var result = try authority.dispatch(method: method, params: foundation)",
                "botRuntimeEvidenceProjector.registerCompletedSend(",
            ],
            in: router,
            after: "public func dispatchPairedBotRemote(",
            "bot_send_ack opens before the run is admitted and closes when the acknowledging turn leaves"
        )
        assertInOrder(
            [
                #"signposter.beginInterval("bot_settle""#,
                #"defer { signposter.endInterval("bot_settle", interval) }"#,
                "settleRuntime(",
            ],
            in: router,
            after: "private lazy var botRuntimeEvidenceProjector",
            "bot_settle encloses the settle of the ended run"
        )
        assertInOrder(
            [
                #"signposter.beginInterval("bot_send_start""#,
                "self.destBrainInputs(",
                "await self.startSupervisedRun(",
                #"signposter.endInterval("bot_send_start", startInterval)"#,
                "if let started {",
            ],
            in: try source("Sources/AppShell/BotsWindow.swift"),
            after: "private func enqueueSupervisedBotRun(",
            "bot_send_start encloses the brain read and the provider start"
        )
        assertInOrder(
            [
                "bindingsByRunID[binding.runID] = binding",
                "firstEventIntervalByBotID.updateValue(",
                #"signposter.beginInterval("#,
                #""bot_first_event","#,
                #"signposter.endInterval("bot_first_event", abandoned)"#,
                "lastProjectedSequenceByRunID[runID] = event.seq",
                "firstEventIntervalByBotID.removeValue(forKey: binding.botID)",
                #"signposter.endInterval("bot_first_event", firstEventInterval)"#,
                "eventBus.publish(kind: projectedKind",
            ],
            in: try source("Sources/AppShell/BotRuntimeEvidenceProjector.swift"),
            after: "func registerCompletedSend(",
            "bot_first_event opens when the receipt binds the run, closes before its first event is projected, and the Bot's next send closes one whose run never projected an event"
        )
        assertInOrder(
            [
                "stamps.begin(.starting)",
                "defer { stamps.end() }",
                "self.prepareGuestRun(request, placement: placement) { stage in",
                "stamps.begin(stage)",
                "progress(stage)",
                #""bot_guest_prepare","#,
                "stage.rawValue",
                #"endInterval("bot_guest_prepare", interval)"#,
            ],
            in: try source("Sources/AppShell/BotGuestRunResolver.swift"),
            after: "// MARK: - DistillGuestLaunchResolving",
            "bot_guest_prepare opens one interval per reported stage and closes the last when preparation ends"
        )
    }
}
