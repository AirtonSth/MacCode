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

    /// WHY: opening the Token Saver details popover stamps "Account usage
    /// updated just now" when the provider probe finishes. The probe used to
    /// treat ANY `rc2TokenSaverUsageChanged` as that completion, but local
    /// paths post the same notification (`savings_recorded` during a run, the
    /// enable/disable toggle) without querying a provider — so the popover
    /// asserted a fresh account query that was still in flight.
    func test_detailsProbe_ignoresLocalUsageNotificationWhileProbeIsInFlight() async throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2TokenSaverDetailsProbe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let refresher = GatedAccountUsageRefresher()
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport.path,
            tokenSaverAccountUsageRefresher: refresher
        )
        let router = AppCommandRouter(context: context)
        context.router = router
        PrivateAccountSessionStore(repo: context.settingsRepo).save(PrivateAccountSession(
            accessToken: "tok",
            refreshToken: "ref",
            user: PrivateAccountUser(
                daysRemaing: nil,
                daysRemaining: 30,
                email: "paid@example.com",
                id: "paid",
                subscribed: true
            )
        ))
        let viewModel = SidebarViewModel(
            context: context,
            router: router,
            insomniaPower: FakeInsomniaPowerManager(),
            powerMonitor: FakeExternalPowerMonitor()
        )
        viewModel.reload()
        XCTAssertNotNil(viewModel.privateAccountUser, "probe precondition: a signed-in account")
        XCTAssertNil(viewModel.tokenSaverAccountUsageLastUpdated, "probe precondition: nothing stamped yet")

        viewModel.refreshTokenSaverAccountUsageForDetails()
        XCTAssertTrue(viewModel.tokenSaverAccountUsageIsRefreshing)
        // The probe registers its one-shot observer from a MainActor Task, so
        // wait for the gated provider call before posting: a notification sent
        // before registration would be missed and prove nothing.
        let probeInFlight = await waitUntilAsync { await refresher.hasStarted() }
        XCTAssertTrue(probeInFlight, "the provider probe must be running before the local event is posted")

        // A local savings_recorded event (or the enable toggle) posts the same
        // notification the probe used to accept as completion.
        NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertNil(
            viewModel.tokenSaverAccountUsageLastUpdated,
            "WHY: a local usage event must not stamp the account-usage timestamp while the provider probe is still running"
        )

        await refresher.release()
        let settled = await waitUntil { viewModel.tokenSaverAccountUsageLastUpdated != nil }
        XCTAssertTrue(settled, "the probe must stamp freshness once the real provider refresh finishes")
        XCTAssertFalse(
            viewModel.tokenSaverAccountUsageIsRefreshing,
            "the spinner must stop on the real settle, not on a local usage event"
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

    /// WHY: result-phase `output +=` copied every stdout chunk unbounded. An
    /// 8 MiB graphify/tool result used to retain 8 MiB in GraphifyItemBuffer
    /// while the detect window is 8 KiB. Prefix-cap the stored string to that
    /// window; keep a running UTF-8 count so answerTokens (Token Saver) does
    /// not shrink.
    func test_graphifyBuffer_eightMiBResultStreamRetainsAtMostDetectWindow() throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2GraphifyOutputCap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
        SettingsStore(db: context.db).save(AppSettings(tokenSaverEnabled: true, graphifyEnabled: true))
        let threadId = AgentThreadID()
        let runId = AgentRunID()
        let itemId = "bash-output-8mib"

        context.recordGraphifyUsageFromItemDelta(
            itemId: itemId,
            bodyAppend: #"{"command":"graphify query where is X"}"#,
            outputAppend: nil,
            summary: "Bash",
            threadId: threadId,
            runId: runId
        )

        let totalBytes = 8 * 1_024 * 1_024
        let chunk = String(repeating: "a", count: 64 * 1_024)
        let chunkBytes = chunk.utf8.count
        let fullChunks = totalBytes / chunkBytes
        let remainder = totalBytes % chunkBytes
        for _ in 0..<fullChunks {
            context.recordGraphifyUsageFromItemDelta(
                itemId: itemId,
                bodyAppend: nil,
                outputAppend: chunk,
                summary: "result",
                threadId: threadId,
                runId: runId
            )
        }
        if remainder > 0 {
            context.recordGraphifyUsageFromItemDelta(
                itemId: itemId,
                bodyAppend: nil,
                outputAppend: String(repeating: "b", count: remainder),
                summary: "result",
                threadId: threadId,
                runId: runId
            )
        }

        let stored = context.graphifyBufferStoredOutputUTF8CountForTesting(runId: runId, itemId: itemId)
        let counted = context.graphifyBufferOutputUTF8CountForTesting(runId: runId, itemId: itemId)
        let cap = AppContext.graphifyOutputMaxUTF8Bytes
        XCTAssertEqual(cap, GraphifyUsageDetector.maxHaystackUTF8Bytes)
        XCTAssertLessThanOrEqual(
            stored,
            cap,
            "8 MiB result stream must retain ≤ the detect-window cap in the stored string"
        )
        XCTAssertGreaterThan(stored, 0, "prefix of the result stream must still be retained")
        XCTAssertEqual(
            counted,
            totalBytes,
            "running UTF-8 count must keep the full 8 MiB so answerTokens do not drop"
        )
        XCTAssertEqual(
            GraphifyUsageDetector.tokensFromUTF8Count(counted),
            GraphifyUsageDetector.tokensFromUTF8Count(totalBytes),
            "Token Saver Graphify credit must match the uncapped stream"
        )
        NSLog(
            "[perf-proof] graphifyOutput cap_bytes=%d stored_bytes=%d counted_bytes=%d unbounded_would_be=%d reduction_mib=%.2f",
            cap, stored, counted, totalBytes,
            Double(totalBytes - stored) / (1024.0 * 1024.0)
        )
    }

    /// WHY: live sample spent the ACP parse queue in detect() on a growing
    /// unmatched body. Negative scans must not repeat at stream rate, and a
    /// later graphify command on a new item must still record.
    func test_graphifyDetect_skipsGrowingUnmatchedBodyThenStillRecordsMatch() throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2GraphifyNegativeSkip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
        SettingsStore(db: context.db).save(AppSettings(tokenSaverEnabled: true, graphifyEnabled: true))
        context.graphifyDetectCountForTesting = 0
        let threadId = AgentThreadID()
        let runId = AgentRunID()

        context.recordGraphifyUsageFromItemDelta(
            itemId: "prose-1",
            bodyAppend: String(repeating: "assistant token ", count: 200),
            outputAppend: nil,
            summary: "assistant",
            threadId: threadId,
            runId: runId
        )
        let afterProse = context.graphifyDetectCountForTesting
        context.recordGraphifyUsageFromItemDelta(
            itemId: "prose-1",
            bodyAppend: String(repeating: "more ", count: 400),
            outputAppend: nil,
            summary: "assistant",
            threadId: threadId,
            runId: runId
        )
        context.recordGraphifyUsageFromItemDelta(
            itemId: "prose-1",
            bodyAppend: String(repeating: "x", count: GraphifyUsageDetector.maxHaystackUTF8Bytes),
            outputAppend: nil,
            summary: "assistant",
            threadId: threadId,
            runId: runId
        )
        let afterFill = context.graphifyDetectCountForTesting
        context.recordGraphifyUsageFromItemDelta(
            itemId: "prose-1",
            bodyAppend: String(repeating: "y", count: 2048),
            outputAppend: nil,
            summary: "assistant",
            threadId: threadId,
            runId: runId
        )
        XCTAssertEqual(
            context.graphifyDetectCountForTesting,
            afterFill,
            "after the detect window fills without graphify, later deltas must not re-detect"
        )
        XCTAssertLessThanOrEqual(afterProse, 1)
        XCTAssertLessThanOrEqual(afterFill, 2)

        context.recordGraphifyUsageFromItemDelta(
            itemId: "bash-2",
            bodyAppend: "cd repo && graphi",
            outputAppend: nil,
            summary: "Bash",
            threadId: threadId,
            runId: runId
        )
        context.recordGraphifyUsageFromItemDelta(
            itemId: "bash-2",
            bodyAppend: "fy query where is X",
            outputAppend: nil,
            summary: "Bash",
            threadId: threadId,
            runId: runId
        )
        XCTAssertGreaterThan(
            context.graphifyDetectCountForTesting,
            afterFill,
            "a later item whose command completes as graphify query must still detect"
        )
    }

    /// WHY: prefix-capping stored output at 8 KiB used to miss a shell failure
    /// after that window and still call markSucceeded with the full token count.
    func test_graphifyBuffer_failureAfter8KiBPrefix_isNotMarkedSucceeded() throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2GraphifyLateFailure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
        SettingsStore(db: context.db).save(AppSettings(tokenSaverEnabled: true, graphifyEnabled: true))
        let threadId = AgentThreadID()
        let runId = AgentRunID()
        let itemId = "bash-late-failure"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        context.recordGraphifyUsageFromItemDelta(
            itemId: itemId,
            bodyAppend: #"{"command":"graphify query where is X"}"#,
            outputAppend: nil,
            summary: "Bash",
            threadId: threadId,
            runId: runId
        )
        let prefix = String(repeating: "a", count: GraphifyUsageDetector.maxHaystackUTF8Bytes)
        context.recordGraphifyUsageFromItemDelta(
            itemId: itemId,
            bodyAppend: nil,
            outputAppend: prefix,
            summary: "result",
            threadId: threadId,
            runId: runId
        )
        XCTAssertEqual(
            context.graphifyBufferStoredOutputUTF8CountForTesting(runId: runId, itemId: itemId),
            GraphifyUsageDetector.maxHaystackUTF8Bytes
        )
        XCTAssertFalse(
            GraphifyUsageDetector.looksLikeFailure(
                output: GraphifyUsageDetector.cappedHaystack(prefix)
            )
        )
        context.recordGraphifyUsageFromItemDelta(
            itemId: itemId,
            bodyAppend: nil,
            outputAppend: "graphify: command not found\n",
            summary: "result",
            threadId: threadId,
            runId: runId
        )
        XCTAssertTrue(
            context.graphifyBufferSawFailureForTesting(runId: runId, itemId: itemId),
            "streaming scan must see the failure after the 8 KiB stored prefix"
        )
        context.finalizeGraphifyUsageItem(itemId: itemId, runId: runId)

        let okId = "bash-late-success"
        context.recordGraphifyUsageFromItemDelta(
            itemId: okId,
            bodyAppend: #"{"command":"graphify query SidebarView"}"#,
            outputAppend: nil,
            summary: "Bash",
            threadId: threadId,
            runId: runId
        )
        context.recordGraphifyUsageFromItemDelta(
            itemId: okId,
            bodyAppend: nil,
            outputAppend: prefix + "NODE SidebarView\n",
            summary: "result",
            threadId: threadId,
            runId: runId
        )
        XCTAssertFalse(context.graphifyBufferSawFailureForTesting(runId: runId, itemId: okId))
        context.finalizeGraphifyUsageItem(itemId: okId, runId: runId)
        context.backgroundWriterQueue.sync {}
        let succeeded = try context.graphifyUsageRepo.signalCount(
            fromMs: nowMs - 60_000,
            toMsExclusive: nowMs + 60_000
        )
        XCTAssertEqual(
            succeeded,
            1,
            "failure after 8 KiB must not succeed; a later non-failure Graphify result still credits"
        )
    }

    /// WHY: Graphify credits the estimated save from counted rows only
    /// (`ok = 1` on query/path/explain). The pending row exists to hold the credit
    /// back until the tool result is known good, but if that pending write fails
    /// the success path used to update zero rows and say nothing: a Graphify
    /// answer the user really got silently vanished from `signalCount`, which
    /// lowers the Graphify leg of the estimated save -- the figure that must never
    /// go down. The delivered answer must still be credited.
    func test_graphifyUsageCreditsAnswerWhosePendingInsertFailed() throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2GraphifyPendingInsertLost-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
        SettingsStore(db: context.db).save(AppSettings(tokenSaverEnabled: true, graphifyEnabled: true))
        // Only the pending (ok=0) insert is refused, so the recovered success row
        // can still land: this is a lost pending write, not a dead database.
        try context.db.execute("""
            CREATE TRIGGER fail_graphify_usage_pending_insert
            BEFORE INSERT ON graphify_usage_events
            WHEN NEW.ok = 0
            BEGIN
                SELECT RAISE(ABORT, 'graphify usage pending insert blocked');
            END;
            """)
        // Anti-vacuity: the trigger has to really refuse the pending write.
        XCTAssertThrowsError(
            try context.graphifyUsageRepo.insert(
                GraphifyUsageEvent(
                    createdAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                    provider: "claude",
                    runId: "probe-run",
                    itemId: "probe-item",
                    subcommand: "query",
                    answerTokens: 0,
                    source: "event_stream",
                    ok: false
                )
            ),
            "the fixture must block the ok=0 insert, otherwise this spec proves nothing"
        )
        let threadId = AgentThreadID()
        let runId = AgentRunID()
        let itemId = "bash-lost-pending-row"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        context.recordGraphifyUsageFromItemDelta(
            itemId: itemId,
            bodyAppend: #"{"command":"graphify query where is X"}"#,
            outputAppend: nil,
            summary: "Bash",
            threadId: threadId,
            runId: runId
        )
        context.recordGraphifyUsageFromItemDelta(
            itemId: itemId,
            bodyAppend: nil,
            outputAppend: "NODE X\n",
            summary: "result",
            threadId: threadId,
            runId: runId
        )
        XCTAssertGreaterThan(
            context.graphifyDetectCountForTesting,
            0,
            "the Graphify query must be detected, otherwise no credit was ever at stake"
        )
        context.finalizeGraphifyUsageItem(itemId: itemId, runId: runId)
        context.backgroundWriterQueue.sync {}

        let signals = try context.graphifyUsageRepo.signalCount(
            fromMs: nowMs - 60_000,
            toMsExclusive: nowMs + 60_000
        )
        XCTAssertEqual(
            signals,
            1,
            "a delivered Graphify query must stay counted even when its pending row could not be written -- losing it lowers the estimated save"
        )
        XCTAssertGreaterThan(
            try context.graphifyUsageRepo.answerTokensSum(
                fromMs: nowMs - 60_000,
                toMsExclusive: nowMs + 60_000
            ),
            0,
            "the recovered row must carry the measured answer size, not a zero-token placeholder"
        )
    }

    /// LEG-2: the normal path (pending row lands, then flips to ok=1) is unchanged
    /// by the recovery above -- exactly one counted row, no duplicate insert and no
    /// recovery bookkeeping. Green before and after the change.
    func test_graphifyUsageCreditsOnceWhenThePendingInsertLanded() throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2GraphifyPendingInsertLanded-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
        SettingsStore(db: context.db).save(AppSettings(tokenSaverEnabled: true, graphifyEnabled: true))
        let threadId = AgentThreadID()
        let runId = AgentRunID()
        let itemId = "bash-pending-row-landed"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        context.recordGraphifyUsageFromItemDelta(
            itemId: itemId,
            bodyAppend: #"{"command":"graphify query where is X"}"#,
            outputAppend: nil,
            summary: "Bash",
            threadId: threadId,
            runId: runId
        )
        context.recordGraphifyUsageFromItemDelta(
            itemId: itemId,
            bodyAppend: nil,
            outputAppend: "NODE X\n",
            summary: "result",
            threadId: threadId,
            runId: runId
        )
        context.finalizeGraphifyUsageItem(itemId: itemId, runId: runId)
        context.backgroundWriterQueue.sync {}

        XCTAssertEqual(
            try context.graphifyUsageRepo.signalCount(fromMs: nowMs - 60_000, toMsExclusive: nowMs + 60_000),
            1,
            "one delivered Graphify query is one signal"
        )
        let rows = try context.db.prepare("SELECT COUNT(*) FROM graphify_usage_events WHERE run_id = ? AND item_id = ?;")
        try rows.bind(1, runId.value.uuidString)
        try rows.bind(2, itemId)
        _ = try rows.step()
        XCTAssertEqual(
            rows.columnInt64(0),
            1,
            "the landed path must not add a second row through recovery"
        )
    }

    /// WHY: a buffer is only dropped by its own item's terminal event, and a run
    /// stopped mid-item never emits one. Every interrupted run therefore left a
    /// ~16 KiB entry behind for the life of the app (nothing ever revisited it).
    /// The run-finish hook is terminal, so that is where they are reclaimed.
    func test_graphifyBuffer_runStoppedMidItemIsReclaimedAtRunFinish() async throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2GraphifyRunStopReclaim-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
        SettingsStore(db: context.db).save(AppSettings(tokenSaverEnabled: true, graphifyEnabled: true))
        let thread = AgentThread(title: "stopped mid item", provider: .codex, model: "m")
        try context.threadRepo.upsert(thread)
        var run = AgentRun(threadId: thread.id, provider: .codex, model: "m",
                           status: .running, startedAt: Date())
        try context.runRepo.upsert(run)
        let itemId = "bash-interrupted"

        context.recordGraphifyUsageFromItemDelta(
            itemId: itemId,
            bodyAppend: String(repeating: "npm run build ", count: 64),
            outputAppend: nil,
            summary: "Bash",
            threadId: thread.id,
            runId: run.id
        )
        XCTAssertEqual(
            context.graphifyBufferCountForTesting(),
            1,
            "fixture check: the streaming item is resident while the run is alive"
        )
        context.graphifyBufferBackdateForTesting(
            runId: run.id,
            itemId: itemId,
            byMs: AppContext.graphifyBufferStaleAfterMs + 1
        )

        run.status = .cancelled
        run.finishedAt = Date()
        try context.runRepo.upsert(run)
        context.coordinator.onRunFinished?(thread.id, run.id, .cancelled)

        await waitForGraphifyBufferCount(0, in: context)
        XCTAssertEqual(
            context.graphifyBuffersDroppedStaleForTesting,
            1,
            "the interrupted item's entry must be the one reclaimed"
        )
    }

    /// WHY: capacity is the backstop for entries no run-finish hook ever sees
    /// (a provider crash leaves the run unclosed). Keep the newest stream: the
    /// oldest entry is the one whose item stopped sending events.
    func test_graphifyBuffer_capacityReclaimsTheOldestAndKeepsTheLiveStream() throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2GraphifyCapacity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
        SettingsStore(db: context.db).save(AppSettings(tokenSaverEnabled: true, graphifyEnabled: true))
        context.graphifyBufferCapacity = 1
        let threadId = AgentThreadID()
        let runId = AgentRunID()

        context.recordGraphifyUsageFromItemDelta(
            itemId: "abandoned", bodyAppend: String(repeating: "old ", count: 64),
            outputAppend: nil, summary: "Bash", threadId: threadId, runId: runId
        )
        context.graphifyBufferBackdateForTesting(
            runId: runId, itemId: "abandoned", byMs: AppContext.graphifyBufferStaleAfterMs + 1
        )
        context.recordGraphifyUsageFromItemDelta(
            itemId: "live", bodyAppend: String(repeating: "new ", count: 64),
            outputAppend: nil, summary: "Bash", threadId: threadId, runId: runId
        )

        XCTAssertEqual(
            context.graphifyBufferBodyUTF8CountForTesting(runId: runId, itemId: "abandoned"),
            0,
            "the entry whose item stopped sending events must be the one reclaimed"
        )
        XCTAssertGreaterThan(
            context.graphifyBufferBodyUTF8CountForTesting(runId: runId, itemId: "live"),
            0,
            "the item still streaming must keep its buffer"
        )
        XCTAssertEqual(context.graphifyBufferCountForTesting(), 1, "capacity must bound the map")
        XCTAssertEqual(context.graphifyBuffersDroppedStaleForTesting, 1)
        XCTAssertEqual(context.graphifyBuffersDroppedOverCapacityForTesting, 0)
    }

    /// WHY: a pending ok=0 row is only credited when its item finalizes, so a
    /// sweep that dropped the buffer of a recorded Graphify invocation would
    /// strand the row and shrink the Graphify credit. Backstop pressure must
    /// drop abandoned entries around it instead.
    func test_graphifyBuffer_pendingGraphifyRowIsNeverSwept() throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2GraphifyPendingRow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
        SettingsStore(db: context.db).save(AppSettings(tokenSaverEnabled: true, graphifyEnabled: true))
        // Every insert is over capacity, so both the stale pass and the
        // capacity backstop run on each one.
        context.graphifyBufferCapacity = 0
        let threadId = AgentThreadID()
        let runId = AgentRunID()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        context.recordGraphifyUsageFromItemDelta(
            itemId: "graphify-call",
            bodyAppend: #"{"command":"graphify query where is X"}"#,
            outputAppend: nil,
            summary: "Bash",
            threadId: threadId,
            runId: runId
        )
        // Result phase: the flip to ok=1 only happens with real tool output.
        context.recordGraphifyUsageFromItemDelta(
            itemId: "graphify-call",
            bodyAppend: nil,
            outputAppend: "NODE SidebarView\n",
            summary: "result",
            threadId: threadId,
            runId: runId
        )
        context.graphifyBufferBackdateForTesting(
            runId: runId, itemId: "graphify-call", byMs: AppContext.graphifyBufferStaleAfterMs + 1
        )
        context.recordGraphifyUsageFromItemDelta(
            itemId: "abandoned", bodyAppend: String(repeating: "noise ", count: 64),
            outputAppend: nil, summary: "Bash", threadId: threadId, runId: runId
        )

        XCTAssertGreaterThan(
            context.graphifyBufferBodyUTF8CountForTesting(runId: runId, itemId: "graphify-call"),
            0,
            "a stale entry holding a pending Graphify row must survive the sweep"
        )
        XCTAssertEqual(
            context.graphifyBufferBodyUTF8CountForTesting(runId: runId, itemId: "abandoned"),
            0,
            "the abandoned entry without a pending row is the one dropped"
        )
        XCTAssertEqual(context.graphifyBuffersDroppedStaleForTesting, 0)
        XCTAssertEqual(context.graphifyBuffersDroppedOverCapacityForTesting, 1)

        // The stranded row would never be credited: prove the flip still lands.
        context.finalizeGraphifyUsageItem(itemId: "graphify-call", runId: runId)
        context.backgroundWriterQueue.sync {}
        XCTAssertEqual(
            try context.graphifyUsageRepo.signalCount(
                fromMs: nowMs - 60_000,
                toMsExclusive: nowMs + 60_000
            ),
            1,
            "the Graphify credit must survive the sweep"
        )
    }

    private func waitForGraphifyBufferCount(
        _ expected: Int,
        in context: AppContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if context.graphifyBufferCountForTesting() == expected { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(
            context.graphifyBufferCountForTesting(),
            expected,
            "resident Graphify buffers never reached \(expected)",
            file: file,
            line: line
        )
    }

    /// Holds the provider probe open until the test releases it, so the
    /// completion signal can be observed while a refresh is genuinely running.
    private actor GatedAccountUsageRefresher: TokenSaverAccountUsageRefreshing {
        private var started = false
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func hasStarted() -> Bool { started }

        func refreshAccountUsage(_ request: TokenSaverAccountUsageRefreshRequest) async -> [AssistantAccountUsage] {
            started = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if released {
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                }
            }
            return [AssistantAccountUsage(
                provider: .claude,
                weeklyUsedPercent: 55,
                weeklyWindowDurationMinutes: 10_080,
                currentSessionUsedPercent: 4
            )]
        }

        func release() {
            released = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
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

    private func waitUntilAsync(
        timeout: TimeInterval = 2,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }
}
