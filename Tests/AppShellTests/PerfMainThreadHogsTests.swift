import XCTest
import AgentRuntime
import CoreModel
import Persistence
@testable import AppShell

/// Regression pins for the 2026-09-14 live audit (TODO.md F1 / F4): work that
/// interrupted the main thread per stream event with N concurrent runs.
@MainActor
final class PerfMainThreadHogsTests: XCTestCase {
    // MARK: PL-01 / EV-22

    func test_tokenSaverDailyEconomyRecompute_coalescesTriggersAndPostsUsageChangedAfterUpsert() async throws {
        // WHY: every usage flush (0.75 s per run) and every Graphify item settle
        // ran the 7-read + upsert recompute synchronously on the main thread,
        // each waiting on the SQLite lock behind the writers (~16% of the main
        // thread in the live sample). Triggers must coalesce into one off-main
        // recompute, and the usage-changed notification must follow the upsert.
        let directory = NSTemporaryDirectory() + "RC2PL01-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        context.tokenSaverDailyEconomyRecomputeDebounceForTesting = 0.05
        context.tokenSaverDailyEconomySharedSnapshotLoadsForTesting = 0

        let posted = expectation(forNotification: .rc2TokenSaverUsageChanged, object: nil)
        for _ in 0..<10 {
            context.scheduleTokenSaverDailyEconomyRecompute(notifyUsageChanged: true)
        }
        await fulfillment(of: [posted], timeout: 3)

        XCTAssertEqual(
            context.tokenSaverDailyEconomyOffMainRecomputeCountForTesting,
            1,
            "10 triggers inside the debounce window must produce ONE recompute"
        )
        XCTAssertEqual(context.tokenSaverDailyEconomySharedSnapshotLoadsForTesting, 1)
        let todayMs = context.tokenSaverDailyEconomyRepo.dayStartMs(for: Date())
        XCTAssertNotNil(
            try context.tokenSaverDailyEconomyRepo.record(dayStartMs: todayMs),
            "the day row must already be upserted when usage-changed is posted"
        )
    }

    // MARK: PL-03 / EV-29

    func test_petResolvesLinkedBotOnceOffMainAndReusesItAcrossActiveRunRefreshes() async throws {
        // WHY: `applyActiveThreadIDs` ran `botStore.conversationsLinked` +
        // `bots(ids:)` on the main thread for every agent.item.started/completed
        // of every run (372 samples in 8 s). The bot link of a thread cannot
        // change mid-run: resolve once, off-main, then reuse.
        let directory = NSTemporaryDirectory() + "RC2PL03-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Pet", cwd: NSTemporaryDirectory())
        let thread = AgentThread(
            workspaceId: workspace.id,
            title: "bot run",
            provider: .codex,
            model: "test",
            status: .running,
            hasUnread: false
        )
        try context.threadRepo.upsert(thread)
        let bot = try context.botStore.create(name: "Ceo", title: "Lead", description: "", provider: .claude)
        // Separate BotStore instance: the controller's in-memory linked-thread
        // cache stays cold so the durable (SQLite) resolution path is exercised.
        try BotStore(db: context.db).upsertConversation(
            BotConversation(botID: bot.id, title: "Standup", linkedAgentThreadID: thread.id)
        )
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true, petReadyCounterEnabled: false))

        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        controller.start()
        defer { controller.stop() }

        let projection = ActiveRunProjection(runs: [.init(threadId: thread.id, runId: AgentRunID())])
        context.coordinator.onActiveRunProjectionChanged?(projection, .started)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if controller.modelForTests.activeThreads.first?.route == .botsDesk(botID: bot.id) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let row = try XCTUnwrap(controller.modelForTests.activeThreads.first)
        XCTAssertEqual(row.route, .botsDesk(botID: bot.id), "a bot-linked run must still route to the Bots desk")
        XCTAssertEqual(row.workspaceName, "Bots")
        XCTAssertEqual(controller.linkedBotDurableLookupCountForTesting, 1)

        for _ in 0..<20 {
            context.coordinator.onActiveRunProjectionChanged?(projection, .started)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(
            controller.linkedBotDurableLookupCountForTesting,
            1,
            "re-applying the same active set must not query bot_conversations again"
        )
        XCTAssertEqual(controller.modelForTests.activeThreads.first?.route, .botsDesk(botID: bot.id))
    }

    // MARK: EV-21

    func test_peerHandoffAuthorityStampsStreamProgressWithoutMainActorHop() throws {
        // WHY: the authority is an always-installed coordinator observer; it
        // scheduled one `Task { @MainActor }` per AssistantEvent of every run
        // (~90/s with 3 runs) just to store a Date. The stamp must land
        // synchronously on the calling thread and be pruned when the run ends.
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2EV21-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root.path).run()
        let threadRepo = AgentThreadRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            checkpointRepo: AgentTurnCheckpointRepository(db: db),
            providers: [:]
        )
        let authority = BotPeerHandoffAuthority(
            botStore: BotStore(db: db),
            threadRepo: threadRepo,
            runRepo: runRepo,
            messageRepo: messageRepo,
            queuedMessageRepo: AgentQueuedMessageRepository(db: db),
            checkpointRepo: AgentTurnCheckpointRepository(db: db),
            settingsRepo: SettingsRepository(db: db),
            coordinator: coordinator,
            appSupportDirectory: root
        )
        let run = AgentRunID()
        let thread = AgentThreadID()
        authority.runCoordinator(coordinator, didReceive: .turnStarted(turnId: "t1"), run: run, threadId: thread)
        XCTAssertEqual(
            authority.peerProgressStampCountForTesting,
            1,
            "the progress stamp must be visible synchronously — a MainActor hop per stream event is what this test forbids"
        )
        authority.runCoordinator(
            coordinator,
            didFinish: run,
            threadId: thread,
            status: .completed,
            finalMessage: nil,
            providerThreadId: nil
        )
        XCTAssertEqual(authority.peerProgressStampCountForTesting, 0, "finished runs must not accumulate stamps")
    }

    // MARK: PL-02 / PL-04 source pins

    func test_tokenSaverFooterReloadsAreDetachedFromTheMainActor() throws {
        // WHY: `Task { }` inside a @MainActor view model inherits the actor. Both
        // footer reloads claimed to read settings/ledger "off-main" but ran on
        // main on every `.rc2TokenSaverUsageChanged` (107 samples in 8 s).
        for (file, anchor) in [
            ("Sources/AppShell/BotsWindow.swift", "func reloadTokenSaverThreadSavings() {"),
            ("Sources/Surfaces/AgentAppSurface.swift", "public func reloadTokenSaverThreadSavings() {")
        ] {
            let source = try String(contentsOf: sourceURL(file), encoding: .utf8)
            let start = try XCTUnwrap(source.range(of: anchor), file)
            let slice = String(source[start.upperBound...].prefix(4_000))
            XCTAssertTrue(slice.contains("tokenSaverFooterReloadTask = Task.detached("), "\(file): reload must run detached")
            XCTAssertFalse(slice.contains("tokenSaverFooterReloadTask = Task {"), "\(file): actor-inheriting Task is the bug")
        }
    }

    func test_petDockPlacementCacheHasNoPeriodicRevalidationLoop() throws {
        // WHY: a 30 s loop hit-tested the Dock against the WindowServer for every
        // screen on the main thread (~130 ms per tick). The screen/Dock
        // notifications already invalidate the cache; recompute stays lazy.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/Pet/PetWindowController.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("30_000_000_000"), "no periodic Dock revalidation")
        XCTAssertFalse(source.contains("func revalidateDockPlacementCache"))
        XCTAssertTrue(source.contains("didChangeScreenParametersNotification"), "invalidation stays notification-driven")
        XCTAssertTrue(source.contains("com.apple.dock.prefchanged"))
    }

    // MARK: BT-21 / BT-25 source pins

    func test_botsDeskLiveTurnRowsAreEquatableAndRailTakesOneLiveSnapshot() throws {
        // WHY (BT-21): without `.equatable()` every finished turn re-ran
        // compose + workBlocks on every Bots body pass (Agent App already gates
        // it). WHY (BT-25): the rail took the coordinator's global lock and
        // allocated a Set per row per pass; one snapshot per pass instead.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        var searchStart = source.startIndex
        var liveTurnSites = 0
        while let range = source.range(of: "AgentChatLiveTurnView(", range: searchStart..<source.endIndex) {
            liveTurnSites += 1
            let tail = String(source[range.upperBound...].prefix(900))
            XCTAssertTrue(tail.contains(".equatable()"), "every Bots AgentChatLiveTurnView must be gated by .equatable()")
            searchStart = range.upperBound
        }
        XCTAssertEqual(liveTurnSites, 2)
        let rail = try XCTUnwrap(source.range(of: "private var deskThreadRail: some View {"))
        let railSlice = String(source[rail.upperBound...].prefix(2_500))
        XCTAssertTrue(railSlice.contains("let liveThreadIDs = vm.liveDeskThreadIDsSnapshot()"))
        XCTAssertTrue(railSlice.contains("deskThreadRow(conversation, liveThreadIDs: liveThreadIDs)"))
        XCTAssertFalse(railSlice.contains("vm.isDeskConversationRunning(conversation)"), "rows must not re-snapshot the coordinator")
    }

    // MARK: BT-20 / BT-22 / BT-24 (Bots desk)

    private func makeDeskHarness() throws -> (context: AppContext, vm: BotsViewModel, bot: BotDefinition, thread: AgentThread, conversation: BotConversation) {
        let directory = NSTemporaryDirectory() + "RC2BotsPerf-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        let conversation = BotConversation(botID: bot.id, title: "Standup", linkedAgentThreadID: thread.id)
        try context.botStore.upsertConversation(conversation)
        return (context, vm, bot, thread, conversation)
    }

    func test_deskStreamEventsCoalesceIntoOneMainHopAndOnePublishPerBatch() async throws {
        // WHY (BT-20): each token scheduled its own MainActor Task and its own
        // @Published write on the monolithic BotsViewModel, invalidating the
        // whole Bots tree per token. A burst delivered before the main actor
        // runs must land as ONE hop and still apply every event in order.
        let h = try makeDeskHarness()
        h.vm.openDesk(h.bot)
        h.vm.selectDeskThread(h.conversation.id)
        XCTAssertEqual(h.vm.selectedConversation?.linkedAgentThreadID, h.thread.id)
        h.vm.resetDeskStreamMainHopCountForTesting()
        let runID = AgentRunID()
        h.vm.runCoordinator(h.context.coordinator, didReceive: .turnStarted(turnId: "t1"), run: runID, threadId: h.thread.id)
        for i in 0..<200 {
            h.vm.runCoordinator(
                h.context.coordinator,
                didReceive: .itemStarted(item: AssistantItem(id: "item-\(i)", turnId: "t1", type: .tool, startedAtMs: Int64(i))),
                run: runID,
                threadId: h.thread.id
            )
        }
        XCTAssertEqual(h.vm.deskStreamMainHopCountForTesting, 1, "a burst delivered before the main actor drains must open exactly one hop")
        for _ in 0..<200 {
            if h.vm.applyIncomingDeskEventCountForTesting == 201 { break }
            await Task.yield()
        }
        XCTAssertEqual(h.vm.applyIncomingDeskEventCountForTesting, 201, "every event of the batch must still be applied")
        XCTAssertEqual(h.vm.deskLiveTimeline.turns.first?.turnId, "t1")
        XCTAssertEqual(h.vm.deskLiveTimeline.turns.first?.items.count, 200, "order and completeness must survive coalescing")
        XCTAssertEqual(h.vm.deskLiveTimeline.turns.first?.items.last?.id, "item-199")
    }

    func test_deskTimelineIsMemoizedAcrossBodyPassesAndRematerializesLiveBodies() async throws {
        // WHY (BT-22): the transcript model was rebuilt on every body pass with
        // an O(messages × turns × items × bytes) duplicate scan. Reads without a
        // structural change must reuse the model; streamed text must still be
        // the live snapshot; a new item must rebuild.
        let h = try makeDeskHarness()
        h.vm.openDesk(h.bot)
        h.vm.selectDeskThread(h.conversation.id)
        let runID = AgentRunID()
        func deliver(_ event: AssistantEvent) async {
            h.vm.runCoordinator(h.context.coordinator, didReceive: event, run: runID, threadId: h.thread.id)
            for _ in 0..<50 { await Task.yield() }
        }
        await deliver(.turnStarted(turnId: "t1"))
        await deliver(.itemStarted(item: AssistantItem(id: "a", turnId: "t1", type: .assistantMessage, startedAtMs: 1)))
        await deliver(.itemDelta(itemId: "a", bodyAppend: "Hello", outputAppend: nil, summary: nil))
        let baseline = h.vm.deskTimelineComputeCountForTesting
        _ = h.vm.deskTimeline
        _ = h.vm.deskTimeline
        _ = h.vm.deskTimeline
        XCTAssertEqual(h.vm.deskTimelineComputeCountForTesting, baseline + 1, "repeated body reads must reuse the model")

        await deliver(.itemDelta(itemId: "a", bodyAppend: " world", outputAppend: nil, summary: nil))
        let afterDelta = h.vm.deskTimeline
        XCTAssertEqual(h.vm.deskTimelineComputeCountForTesting, baseline + 1, "a body delta is not a structural change")
        let liveTurn = afterDelta.compactMap { item -> AssistantTurnSnapshot? in
            if case .liveTurn(let turn, _) = item { return turn }
            return nil
        }.first
        XCTAssertEqual(liveTurn?.items.first?.body, "Hello world", "the memoized model must carry the LIVE turn snapshot, not the one captured at compute time")

        await deliver(.itemStarted(item: AssistantItem(id: "b", turnId: "t1", type: .tool, startedAtMs: 2)))
        _ = h.vm.deskTimeline
        XCTAssertEqual(h.vm.deskTimelineComputeCountForTesting, baseline + 2, "a new item must rebuild the model")
    }

    func test_duplicateTerminalNotificationsApplyFollowThroughOnce() async throws {
        // WHY (BT-24): didChangeStatus(terminal) and didFinish both delivered the
        // same run end; each pass re-ran message decode + work log + replay +
        // SQLite writes. The same (thread, run) terminal must settle once.
        let h = try makeDeskHarness()
        let runID = AgentRunID()
        h.vm.runCoordinator(h.context.coordinator, didChangeStatus: .completed, runId: runID, threadId: h.thread.id)
        h.vm.runCoordinator(h.context.coordinator, didFinish: runID, threadId: h.thread.id, status: .completed, finalMessage: "done", providerThreadId: nil)
        for _ in 0..<200 {
            if h.vm.followThroughApplyCountForTesting >= 1 { break }
            await Task.yield()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(h.vm.followThroughApplyCountForTesting, 1, "the same terminal run must settle once")
        let settled = try h.context.botStore.conversationLinked(to: h.thread.id)
        XCTAssertNotNil(settled, "the conversation row must still be updated by the single follow-through")
    }

    private func sourceURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }
}
