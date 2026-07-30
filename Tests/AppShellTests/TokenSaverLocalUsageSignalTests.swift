import XCTest
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
