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

    /// WHY: usage-changed fires during agent runs. Rewriting an equal
    /// snapshot @Published value rebuilt the always-on sidebar.
    func test_unchangedUsageReload_doesNotPublishSidebar() async throws {
        let (context, viewModel, appSupport) = try makeViewModel()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        await viewModel.reloadAccountUsageAndWait()
        // Mount also loads Activity counts off-main; let that unrelated first publish land
        // so the window below only sees what the usage notification causes.
        let countsSettled = await waitUntil { viewModel.activityCounts.isAvailable }
        XCTAssertTrue(countsSettled, "precondition: the mount-time Activity counts load finished")
        // Mount also reads the Distill account list for the rings; let it land too.
        let accountsSettled = await waitUntil { !context.distillAccountsController.isRefreshing }
        XCTAssertTrue(accountsSettled, "precondition: the mount-time account list load finished")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

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
