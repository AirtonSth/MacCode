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

    private func sourceURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }
}
