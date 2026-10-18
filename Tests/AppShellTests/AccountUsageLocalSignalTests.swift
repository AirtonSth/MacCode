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

        _ = try ProviderUsageStore(appSupportDirectory: context.appSupportDirectory).record(
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
            .appendingPathComponent("RC2AccountUsageDetailsProbe-\(UUID().uuidString)", isDirectory: true)
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

        _ = try ProviderUsageStore(appSupportDirectory: context.appSupportDirectory).recordAccountUsage(
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

    /// WHY: "Account usage updated just now" promises Claude was asked. A
    /// timer tick inside the Claude CLI interval does not ask Claude. When the
    /// popover opened during such a tick, the popover's own request was
    /// dropped as busy and the tick's settle stamped a Claude percent up to an
    /// hour old as fresh. The popover must wait for a refresh that probes Claude.
    func test_detailsProbe_doesNotSettleOnAPeriodicTickThatSkippedClaude() async throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2AccountUsageDetailsSkip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let refresher = SteppedAccountUsageRefresher()
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
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        context.accountUsageNow = { now }
        var settles = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .rc2AccountUsageRefreshSettled, object: nil, queue: nil
        ) { _ in settles += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        // A tick probes Claude, so the next tick falls inside the interval.
        context.refreshPeriodicAccountUsage()
        let firstStarted = await waitUntilAsync { await refresher.requests.count == 1 }
        XCTAssertTrue(firstStarted)
        await refresher.releaseNext()
        let firstSettled = await waitUntil { settles == 1 }
        XCTAssertTrue(firstSettled)

        // Inside the Claude CLI interval: a tick that skips the Claude CLI is in flight when the popover opens.
        now = now.addingTimeInterval(AppContext.claudeUsageCLIProbeInterval / 2)
        context.refreshPeriodicAccountUsage()
        let tickStarted = await waitUntilAsync { await refresher.requests.count == 2 }
        XCTAssertTrue(tickStarted)
        let tickProbesClaude = await refresher.requests.last?.allowClaudeCLIProbe
        XCTAssertEqual(tickProbesClaude, false, "precondition: this tick does not ask Claude")
        viewModel.refreshAccountUsageForDetails()
        XCTAssertTrue(viewModel.accountUsageIsRefreshing)
        // The popover registers its observer and asks from a MainActor Task.
        try? await Task.sleep(nanoseconds: 300_000_000)

        await refresher.releaseNext()
        let tickSettled = await waitUntil { settles == 2 }
        XCTAssertTrue(tickSettled)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(
            viewModel.accountUsageLastUpdated,
            "a tick that never asked Claude must not stamp the popover's \"updated just now\""
        )
        XCTAssertTrue(viewModel.accountUsageIsRefreshing, "the popover is still waiting for Claude")

        let detailsStarted = await waitUntilAsync { await refresher.requests.count == 3 }
        XCTAssertTrue(detailsStarted, "the popover's own refresh must still run once the tick clears")
        let details = await refresher.requests.last
        XCTAssertEqual(details?.allowClaudeCLIProbe, true)
        XCTAssertEqual(details?.allowClaudeUsageScreen, true)
        await refresher.releaseNext()
        let stamped = await waitUntil { viewModel.accountUsageLastUpdated != nil }
        XCTAssertTrue(stamped, "the refresh that asked Claude settles the popover")
        XCTAssertFalse(viewModel.accountUsageIsRefreshing)
        XCTAssertEqual(
            ProviderUsageStore(appSupportDirectory: context.appSupportDirectory)
                .load().providers.first { $0.provider == .claude }?.weeklyUsedPercent,
            55
        )
    }

    /// WHY: usage-changed fires during agent runs. Rewriting an equal
    /// snapshot @Published value rebuilt the always-on sidebar.
    func test_unchangedUsageReload_doesNotPublishSidebar() async throws {
        let (_, viewModel, appSupport) = try makeViewModel()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        await viewModel.reloadAccountUsageAndWait()
        // Mount also loads Activity counts off-main; let that unrelated first publish land
        // so the window below only sees what the usage notification causes.
        let countsSettled = await waitUntil { viewModel.activityCounts.isAvailable }
        XCTAssertTrue(countsSettled, "precondition: the mount-time Activity counts load finished")

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

    private actor GatedAccountUsageRefresher: ProviderAccountUsageRefreshing {
        private var started = false
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func hasStarted() -> Bool { started }

        func refreshAccountUsage(_ request: ProviderAccountUsageRefreshRequest) async -> [AssistantAccountUsage] {
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

    /// Holds each full refresh until `releaseNext()`. Claude answers only a
    /// request allowed to launch its CLI, as with a stale Claude Code cache.
    private actor SteppedAccountUsageRefresher: ProviderAccountUsageRefreshing {
        private(set) var requests: [ProviderAccountUsageRefreshRequest] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var releases = 0

        func refreshAccountUsage(_ request: ProviderAccountUsageRefreshRequest) async -> [AssistantAccountUsage] {
            requests.append(request)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if releases > 0 {
                    releases -= 1
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                }
            }
            var usages = [AssistantAccountUsage(
                provider: .codex, weeklyUsedPercent: 10, weeklyWindowDurationMinutes: 10_080
            )]
            if request.allowClaudeCLIProbe {
                usages.append(AssistantAccountUsage(
                    provider: .claude, weeklyUsedPercent: 55, weeklyWindowDurationMinutes: 10_080
                ))
            }
            return usages
        }

        func grokAccountUsage(_ request: ProviderAccountUsageRefreshRequest) async -> AssistantAccountUsage? {
            nil
        }

        func releaseNext() {
            if waiters.isEmpty {
                releases += 1
            } else {
                waiters.removeFirst().resume()
            }
        }
    }

    private func makeViewModel() throws -> (AppContext, SidebarViewModel, URL) {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2AccountUsageLocalSignal-\(UUID().uuidString)", isDirectory: true)
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
        let router = AppCommandRouter(context: context)
        context.router = router
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
