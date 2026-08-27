import XCTest
import Combine
import AgentRuntime
import CoreModel
import Persistence
@testable import AppShell

@MainActor
final class TokenSaverLocalUsageSignalTests: XCTestCase {
    private final class FakeInsomniaPowerManager: InsomniaPowerManaging {
        func activate(reason: String, options: InsomniaPowerOptions) -> Bool { true }
        func deactivate() {}
        func releaseProcessAssertions() {}
    }

    private final class FakeExternalPowerMonitor: ExternalPowerMonitoring {
        var currentPowerState: ExternalPowerState = .externalPower
        var onPowerStateChanged: (@MainActor (ExternalPowerState) -> Void)?
        func start() {}
        func stop() {}
    }

    func test_localUsageLabelNamesProvidersAndMeasuredTokenDeltas() {
        let now = Date()
        let update = SidebarViewModel.TokenSaverLocalUsageUpdate(
            providerTokenDeltas: [.grok: 1_200, .codex: 800],
            updatedAt: now
        )

        XCTAssertEqual(
            SidebarRootView.localUsageUpdateLabel(update, now: now),
            "Local usage · Codex +800, Grok +1.2K tokens · just now",
            "WHY: cross-provider work must remain visible even when rounded account percentages do not move"
        )
    }

    func test_accountRefreshLabelCannotBeMistakenForLocalRunActivity() {
        let now = Date()

        XCTAssertEqual(
            SidebarRootView.accountUsageLastUpdatedLabel(nil, now: now),
            "Account usage not refreshed"
        )
        XCTAssertEqual(
            SidebarRootView.accountUsageLastUpdatedLabel(now, now: now),
            "Account usage updated just now",
            "WHY: the existing timestamp belongs to the provider-account probe, not a subagent token event"
        )
    }

    func test_usageChangedNotificationPublishesProviderLocalDeltaWithoutClaimingSavings() async throws {
        let (context, viewModel, appSupport) = try makeViewModel()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        await viewModel.reloadTokenSaverAndWait()
        XCTAssertNil(viewModel.tokenSaverLocalUsageUpdate)

        _ = try TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).record(
            provider: .grok,
            actualProviderTokens: 321,
            estimatedRawTokens: 321,
            eligibleRuns: 1
        )
        NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)

        let refreshed = await waitUntil {
            viewModel.tokenSaverLocalUsageUpdate?.totalTokenDelta == 321
        }
        XCTAssertTrue(refreshed)
        XCTAssertEqual(viewModel.tokenSaverLocalUsageUpdate?.providerTokenDeltas[.grok], 321)
        XCTAssertEqual(viewModel.tokenSaverUsageSnapshot.measuredSavedTokens, 0)
        XCTAssertNil(
            viewModel.tokenSaverAccountUsageLastUpdated,
            "WHY: a local provider token event must not masquerade as a completed account-usage refresh"
        )
    }

    func test_accountOnlyNotificationDoesNotInventLocalProviderActivity() async throws {
        let (context, viewModel, appSupport) = try makeViewModel()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        await viewModel.reloadTokenSaverAndWait()

        _ = try TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).recordAccountUsage(
            provider: .claude,
            weeklyUsedPercent: 27
        )
        NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)

        let refreshed = await waitUntil {
            viewModel.tokenSaverUsageSnapshot.providers
                .first(where: { $0.provider == .claude })?
                .weeklyUsedPercent == 27
        }
        XCTAssertTrue(refreshed)
        XCTAssertNil(
            viewModel.tokenSaverLocalUsageUpdate,
            "WHY: an account percentage refresh changes no locally observed provider-token total"
        )
    }

    /// WHY: usage-changed fires during agent runs. Rewriting equal
    /// tokenSaverEnabled / snapshot @Published values rebuilt the always-on
    /// sidebar and pushed a widget digest with a new timestamp.
    func test_unchangedUsageReload_doesNotPublishSidebar() async throws {
        let (_, viewModel, appSupport) = try makeViewModel()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        await viewModel.reloadTokenSaverAndWait()

        var publishes = 0
        let sub = viewModel.objectWillChange.sink { publishes += 1 }
        NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)
        let settled = await waitUntil(timeout: 1.0) { publishes > 0 }
        _ = sub

        XCTAssertFalse(settled)
        XCTAssertEqual(
            publishes,
            0,
            "equal flags/snapshot must not invalidate the sidebar on a usage notification"
        )
    }

    /// WHY: Today "Estimated save 2.6M" was day-measured × 200. A long thread
    /// with lifetime savings active today must use permanent saved × (runs − 1).
    func test_todayEstimatedSave_usesPermanentThreadAmortNotDayMeasuredCap() throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2TokenSaverTodayAmort-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
        SettingsStore(db: context.db).save(AppSettings(tokenSaverEnabled: true))
        let repo = context.tokenSaverSavingsRepo
        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400)
        let thread = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

        XCTAssertEqual(
            try repo.record(
                provider: "claude",
                mode: "command-output",
                inputTokens: 3_000_000,
                outputTokens: 0,
                savedTokens: 3_000_000,
                delivered: true,
                threadID: thread,
                idempotencyKey: "lifetime-base",
                at: yesterday
            ),
            3_000_000
        )
        for index in 0..<50 {
            _ = try repo.record(
                provider: "claude",
                mode: "command-output",
                inputTokens: 20,
                outputTokens: 10,
                savedTokens: 10,
                delivered: true,
                threadID: thread,
                idempotencyKey: "lifetime-run-\(index)",
                at: yesterday
            )
        }
        XCTAssertEqual(
            try repo.record(
                provider: "claude",
                mode: "command-output",
                inputTokens: 13_000,
                outputTokens: 0,
                savedTokens: 13_000,
                delivered: true,
                threadID: thread,
                idempotencyKey: "today-active",
                at: now
            ),
            13_000
        )

        context.recomputeTokenSaverDailyEconomyToday(now: now)
        let todayMs = context.tokenSaverDailyEconomyRepo.dayStartMs(for: now)
        let todayEnd = context.tokenSaverDailyEconomyRepo.dayEndMsExclusive(for: now)
        let todayMeasured = try context.tokenSaverDailyEconomyRepo.measuredPipes(
            dayStartMs: todayMs,
            dayEndMsExclusive: todayEnd
        )
        XCTAssertEqual(todayMeasured, 13_000)
        let row = try XCTUnwrap(context.tokenSaverDailyEconomyRepo.record(dayStartMs: todayMs))
        let dayMeasuredCap = todayMeasured * TokenSaverBareUserEstimator.cacheAmortizationMaxMultipleOfMeasured
        XCTAssertEqual(dayMeasuredCap, 2_600_000)
        XCTAssertGreaterThan(
            row.totalCredible,
            dayMeasuredCap,
            "Today Estimated save must not stay at the 2.6M day-measured × 200 cap"
        )
        XCTAssertGreaterThan(
            row.totalCredible,
            3_000_000 * TokenSaverBareUserEstimator.cacheAmortizationMaxExtraTurns,
            "52 runs must beat the old 50 extra-turn cap"
        )
        XCTAssertEqual(row.formulaVersion, TokenSaverDailyEconomyRepository.formulaVersion)
    }

    /// WHY: a 7-day heal used to construct a fresh SettingsStore + UsageStore
    /// per day (empty cache → 7 SQLite reads + 7 usage.json decodes) on the
    /// MainActor. Shared snapshot must load once per window call.
    func test_economyWindow_loadsSharedSettingsAndUsageOnce() throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2TokenSaverEconomyWindow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
        context.tokenSaverDailyEconomySharedSnapshotLoadsForTesting = 0

        context.recomputeTokenSaverDailyEconomyWindow(dayCount: 7)

        XCTAssertEqual(
            context.tokenSaverDailyEconomySharedSnapshotLoadsForTesting,
            1,
            "7-day heal must share one settings+usage.json snapshot, not load per day"
        )
    }

    /// WHY: AppContext already recomputes today before posting usage-changed.
    /// Reloading the sidebar snapshot must not stall MainActor on another
    /// 7-day settings+usage walk — historical days are unchanged by this event.
    func test_usageChangedNotification_doesNotRehealSevenDayWindow() async throws {
        let (context, viewModel, appSupport) = try makeViewModel()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let healsAfterInit = viewModel.tokenSaverEconomyWindowHealCountForTesting
        XCTAssertGreaterThanOrEqual(healsAfterInit, 1, "boot must heal the week once")

        _ = try TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).record(
            provider: .claude,
            actualProviderTokens: 10,
            estimatedRawTokens: 10,
            eligibleRuns: 1
        )
        NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)

        let refreshed = await waitUntil {
            viewModel.tokenSaverUsageSnapshot.providers
                .contains(where: { $0.provider == .claude && $0.actualProviderTokens >= 10 })
        }
        XCTAssertTrue(refreshed)
        XCTAssertEqual(
            viewModel.tokenSaverEconomyWindowHealCountForTesting,
            healsAfterInit,
            "usage notification must not re-run the 7-day economy heal"
        )
    }

    /// WHY: itemDelta fires at stream rate. A new SettingsStore per chunk
    /// was a MainActor SQLite load even when Token Saver / Graphify is off.
    func test_graphifyUsageGate_loadsSettingsOnceUntilRevisionChanges() throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2GraphifyUsageGate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
        context.graphifyUsageSettingsLoadCountForTesting = 0
        let threadId = AgentThreadID()
        let runId = AgentRunID()

        context.recordGraphifyUsageFromItemDelta(
            itemId: "i1",
            bodyAppend: "echo",
            outputAppend: nil,
            summary: nil,
            threadId: threadId,
            runId: runId
        )
        context.recordGraphifyUsageFromItemDelta(
            itemId: "i1",
            bodyAppend: " hi",
            outputAppend: nil,
            summary: nil,
            threadId: threadId,
            runId: runId
        )
        XCTAssertEqual(
            context.graphifyUsageSettingsLoadCountForTesting,
            1,
            "unchanged settings revision must not SQLite-load on every itemDelta"
        )

        SettingsStore(db: context.db).save(AppSettings(tokenSaverEnabled: true, graphifyEnabled: true))
        context.recordGraphifyUsageFromItemDelta(
            itemId: "i1",
            bodyAppend: "!",
            outputAppend: nil,
            summary: nil,
            threadId: threadId,
            runId: runId
        )
        XCTAssertEqual(
            context.graphifyUsageSettingsLoadCountForTesting,
            2,
            "a settings save must bump revision so the next delta re-reads admission"
        )
    }

    /// WHY: when Graphify is admitted, itemDelta used to threadRepo.get on
    /// every chunk (~30 Hz). Provider is stable per thread; first chunk
    /// fills the cache, later chunks must not hit SQLite.
    func test_graphifyProviderLabel_cachedAcrossItemDeltas() throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2GraphifyProviderCache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
        SettingsStore(db: context.db).save(AppSettings(tokenSaverEnabled: true, graphifyEnabled: true))
        context.graphifyProviderLookupCountForTesting = 0
        let threadId = AgentThreadID()
        let runId = AgentRunID()

        context.recordGraphifyUsageFromItemDelta(
            itemId: "tool-1",
            bodyAppend: "graphify",
            outputAppend: nil,
            summary: nil,
            threadId: threadId,
            runId: runId
        )
        context.recordGraphifyUsageFromItemDelta(
            itemId: "tool-1",
            bodyAppend: " query",
            outputAppend: nil,
            summary: nil,
            threadId: threadId,
            runId: runId
        )
        context.recordGraphifyUsageFromItemDelta(
            itemId: "tool-2",
            bodyAppend: "graphify path",
            outputAppend: nil,
            summary: nil,
            threadId: threadId,
            runId: runId
        )

        XCTAssertEqual(
            context.graphifyProviderLookupCountForTesting,
            1,
            "thread provider must be SQLite-loaded once per thread, not per itemDelta"
        )
        XCTAssertEqual(context.graphifyProviderLabel(for: threadId), "unknown")
    }

    /// WHY: the first Graphify itemDelta used to full-get 26 columns + routing
    /// JSON just to read provider. listChrome already returns that field.
    func test_graphifyProviderLabel_usesListChromeWithoutDurableGet() throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2GraphifyProviderChrome-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
        let thread = AgentThread(title: "graphify", provider: .grok, model: "grok-4")
        try context.threadRepo.upsert(thread)
        let getsBefore = context.threadRepo.durableGetCountForTesting
        let chromeBefore = context.threadRepo.listChromeCallCountForTesting
        context.graphifyProviderLookupCountForTesting = 0

        XCTAssertEqual(context.graphifyProviderLabel(for: thread.id), "grok")
        XCTAssertEqual(context.graphifyProviderLookupCountForTesting, 1)
        XCTAssertEqual(
            context.threadRepo.durableGetCountForTesting,
            getsBefore,
            "first Graphify provider lookup must not compile a full 26-column get"
        )
        XCTAssertEqual(
            context.threadRepo.listChromeCallCountForTesting,
            chromeBefore + 1
        )
        XCTAssertEqual(context.graphifyProviderLabel(for: thread.id), "grok")
        XCTAssertEqual(context.graphifyProviderLookupCountForTesting, 1)
        XCTAssertEqual(context.threadRepo.listChromeCallCountForTesting, chromeBefore + 1)

        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AppShell/AppContext.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "func graphifyProviderLabel(for threadId: AgentThreadID)"))
        let body = String(source[range.lowerBound...].prefix(900))
        XCTAssertTrue(body.contains("threadRepo.listChrome(ids: [threadId])"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadId)"))
    }

    /// WHY: after a Graphify invocation is recorded, later itemDelta chunks
    /// used to JSON-parse the growing tool body and re-detect on MainActor.
    func test_graphifyDetect_skipsAfterInvocationRecorded() throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2GraphifyDetectSkip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
        SettingsStore(db: context.db).save(AppSettings(tokenSaverEnabled: true, graphifyEnabled: true))
        context.graphifyDetectCountForTesting = 0
        let threadId = AgentThreadID()
        let runId = AgentRunID()

        context.recordGraphifyUsageFromItemDelta(
            itemId: "bash-1",
            bodyAppend: #"{"command":"graphify query where is X"}"#,
            outputAppend: nil,
            summary: "Bash",
            threadId: threadId,
            runId: runId
        )
        XCTAssertEqual(context.graphifyDetectCountForTesting, 1)
        context.recordGraphifyUsageFromItemDelta(
            itemId: "bash-1",
            bodyAppend: " && echo more",
            outputAppend: nil,
            summary: "Bash",
            threadId: threadId,
            runId: runId
        )
        context.recordGraphifyUsageFromItemDelta(
            itemId: "bash-1",
            bodyAppend: " && echo again",
            outputAppend: nil,
            summary: "Bash",
            threadId: threadId,
            runId: runId
        )
        XCTAssertEqual(
            context.graphifyDetectCountForTesting,
            1,
            "after the pending Graphify row is recorded, later deltas must not re-parse/detect"
        )
    }

    /// WHY: after detect records the pending row, later itemDelta chunks
    /// still copied the growing command body (~30 Hz) and then copied it
    /// again in processGraphifyBuffer only to return. Answer tokens come
    /// from result-phase output, so command-body growth is wasted.
    func test_graphifyBuffer_stopsGrowingBodyAfterInvocationRecorded() throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2GraphifyBodyCap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
        SettingsStore(db: context.db).save(AppSettings(tokenSaverEnabled: true, graphifyEnabled: true))
        let threadId = AgentThreadID()
        let runId = AgentRunID()
        let itemId = "bash-body"

        context.recordGraphifyUsageFromItemDelta(
            itemId: itemId,
            bodyAppend: #"{"command":"graphify query where is X"}"#,
            outputAppend: nil,
            summary: "Bash",
            threadId: threadId,
            runId: runId
        )
        let afterMatch = context.graphifyBufferBodyUTF8CountForTesting(runId: runId, itemId: itemId)
        XCTAssertGreaterThan(afterMatch, 0, "first matching chunk must populate the command body")

        context.recordGraphifyUsageFromItemDelta(
            itemId: itemId,
            bodyAppend: String(repeating: "x", count: 2048),
            outputAppend: nil,
            summary: "Bash",
            threadId: threadId,
            runId: runId
        )
        context.recordGraphifyUsageFromItemDelta(
            itemId: itemId,
            bodyAppend: String(repeating: "y", count: 2048),
            outputAppend: nil,
            summary: "Bash",
            threadId: threadId,
            runId: runId
        )
        XCTAssertEqual(
            context.graphifyBufferBodyUTF8CountForTesting(runId: runId, itemId: itemId),
            afterMatch,
            "later command-text deltas must not grow the body after the pending row exists"
        )
    }

    private func makeViewModel() throws -> (AppContext, SidebarViewModel, URL) {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2TokenSaverLocalSignal-\(UUID().uuidString)", isDirectory: true)
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(tokenSaverEnabled: true))
        let viewModel = SidebarViewModel(
            context: context,
            router: router,
            insomniaPower: FakeInsomniaPowerManager(),
            powerMonitor: FakeExternalPowerMonitor()
        )
        return (context, viewModel, appSupport)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}
