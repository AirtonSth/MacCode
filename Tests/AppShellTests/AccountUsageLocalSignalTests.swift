import XCTest
import Combine
import AgentRuntime
import CoreModel
import Persistence
@testable import AppShell

@MainActor
final class AccountUsageLocalSignalTests: XCTestCase {
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

    func test_usageChangedNotificationRefreshesLocalUsageWithoutStampingAccountRefresh() async throws {
        let (context, viewModel, appSupport) = try makeViewModel()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        await viewModel.reloadAccountUsageAndWait()

        _ = try TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).record(
            provider: .grok,
            actualProviderTokens: 321,
            estimatedRawTokens: 321,
            eligibleRuns: 1
        )
        NotificationCenter.default.post(name: .rc2AccountUsageChanged, object: nil)

        let refreshed = await waitUntil {
            viewModel.accountUsageSnapshot.providers
                .first(where: { $0.provider == .grok })?
                .actualProviderTokens == 321
        }
        XCTAssertTrue(refreshed, "WHY: the sidebar's \"Used …\" figure must follow local provider usage")
        XCTAssertEqual(viewModel.accountUsageSnapshot.usedTokens, 321)
        XCTAssertNil(
            viewModel.accountUsageLastUpdated,
            "WHY: a local provider token event must not masquerade as a completed account-usage refresh"
        )
    }

    /// WHY: opening the account-usage details popover stamps "Account usage
    /// updated just now" when the provider probe finishes. The probe used to
    /// treat ANY `rc2AccountUsageChanged` as that completion, but local
    /// paths post the same notification (`savings_recorded` during a run, the
    /// enable/disable toggle of older builds) without querying a provider — so the popover
    /// asserted a fresh account query that was still in flight.
    func test_detailsProbe_ignoresLocalUsageNotificationWhileProbeIsInFlight() async throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2TokenSaverDetailsProbe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let refresher = GatedAccountUsageRefresher()
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport.path,
            accountUsageRefresher: refresher
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
        XCTAssertNil(viewModel.accountUsageLastUpdated, "probe precondition: nothing stamped yet")

        viewModel.refreshAccountUsageForDetails()
        XCTAssertTrue(viewModel.accountUsageIsRefreshing)
        // The probe registers its one-shot observer from a MainActor Task, so
        // wait for the gated provider call before posting: a notification sent
        // before registration would be missed and prove nothing.
        let probeInFlight = await waitUntilAsync { await refresher.hasStarted() }
        XCTAssertTrue(probeInFlight, "the provider probe must be running before the local event is posted")

        // A local usage event posts the same
        // notification the probe used to accept as completion.
        NotificationCenter.default.post(name: .rc2AccountUsageChanged, object: nil)
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertNil(
            viewModel.accountUsageLastUpdated,
            "WHY: a local usage event must not stamp the account-usage timestamp while the provider probe is still running"
        )

        await refresher.release()
        let settled = await waitUntil { viewModel.accountUsageLastUpdated != nil }
        XCTAssertTrue(settled, "the probe must stamp freshness once the real provider refresh finishes")
        XCTAssertFalse(
            viewModel.accountUsageIsRefreshing,
            "the spinner must stop on the real settle, not on a local usage event"
        )
    }

    func test_accountUsageNotificationRefreshesProviderPercentages() async throws {
        let (context, viewModel, appSupport) = try makeViewModel()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        await viewModel.reloadAccountUsageAndWait()

        _ = try TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).recordAccountUsage(
            provider: .claude,
            weeklyUsedPercent: 27
        )
        NotificationCenter.default.post(name: .rc2AccountUsageChanged, object: nil)

        let refreshed = await waitUntil {
            viewModel.accountUsageSnapshot.providers
                .first(where: { $0.provider == .claude })?
                .weeklyUsedPercent == 27
        }
        XCTAssertTrue(refreshed, "WHY: a provider account refresh must reach the sidebar without reopening it")
        XCTAssertEqual(
            viewModel.accountUsageSnapshot.usedTokens,
            0,
            "WHY: an account percentage refresh changes no locally observed provider-token total"
        )
    }

    /// WHY: usage-changed fires during agent runs. Rewriting an equal
    /// snapshot @Published value rebuilt the always-on sidebar.
    func test_unchangedUsageReload_doesNotPublishSidebar() async throws {
        let (_, viewModel, appSupport) = try makeViewModel()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        await viewModel.reloadAccountUsageAndWait()

        var publishes = 0
        let sub = viewModel.objectWillChange.sink { publishes += 1 }
        NotificationCenter.default.post(name: .rc2AccountUsageChanged, object: nil)
        let settled = await waitUntil(timeout: 1.0) { publishes > 0 }
        _ = sub

        XCTAssertFalse(settled)
        XCTAssertEqual(
            publishes,
            0,
            "an equal snapshot must not invalidate the sidebar on a usage notification"
        )
    }

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
