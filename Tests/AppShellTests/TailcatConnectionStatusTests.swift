import XCTest
@testable import AppShell

/// Contract for the "Connect from anywhere" default and the sidebar header
/// DERP badge:
///   1. A missing `tailcat_access_enabled` key (fresh install / never touched)
///      must enable the feature; only an explicit "0" keeps it off.
///   2. The sidebar header badge is green only while the Tailcat runtime is
///      .active (connected through DERP) and yellow in every other state.
@MainActor
final class TailcatConnectionStatusTests: XCTestCase {

    // MARK: - Connect from anywhere defaults to enabled

    func test_missingTailcatSettingDefaultsToEnabled() {
        XCTAssertTrue(
            TailcatAccessDefaults.isEnabled(nil),
            "fresh installs must get Connect from anywhere enabled by default"
        )
        XCTAssertTrue(TailcatAccessDefaults.isEnabled("1"))
        XCTAssertFalse(
            TailcatAccessDefaults.isEnabled("0"),
            "an explicit off must survive: default-on applies only when the key is missing"
        )
    }

    func test_settingsToggleHydratesEnabledWhenSettingKeyMissing() async throws {
        let (controller, _) = try makeSettingsController()
        defer { close(controller) }

        XCTAssertTrue(
            controller.viewModel.tailcatAccessEnabled,
            "init hydration must apply the default-on contract for a missing key"
        )
        controller.viewModel.reload()
        XCTAssertTrue(
            controller.viewModel.tailcatAccessEnabled,
            "a full freshness reload must keep the default-on state"
        )
    }

    func test_settingsToggleStaysOffAfterExplicitOptOut() async throws {
        let (controller, context) = try makeSettingsController()
        defer { close(controller) }
        try context.settingsRepo.set("tailcat_access_enabled", "0")

        controller.viewModel.reload()
        XCTAssertFalse(
            controller.viewModel.tailcatAccessEnabled,
            "an explicit user opt-out must win over the default-on"
        )
    }

    // MARK: - Sidebar header badge state

    func test_runtimeStatusNotificationDrivesSidebarBadgeState() async throws {
        let (ctx, router, vm) = try makeSidebarViewModel()

        XCTAssertEqual(vm.tailcatRuntimeStatus, .off, "badge starts yellow (not connected)")

        NotificationCenter.default.post(
            name: .rc2TailcatRuntimeStatusChanged,
            object: nil,
            userInfo: [
                "status": TailcatRuntimeStatus.active.displayText,
                "rawStatus": TailcatRuntimeStatus.active.rawValue,
            ]
        )
        let connected = await drainUntil(vm.tailcatRuntimeStatus == .active)
        XCTAssertTrue(connected, "DERP connected (.active) must reach the sidebar badge state")
        XCTAssertTrue(vm.tailcatRuntimeStatus.isDERPConnected, ".active renders the green badge")

        NotificationCenter.default.post(
            name: .rc2TailcatRuntimeStatusChanged,
            object: nil,
            userInfo: [
                "status": TailcatRuntimeStatus.off.displayText,
                "rawStatus": TailcatRuntimeStatus.off.rawValue,
            ]
        )
        let disconnected = await drainUntil(vm.tailcatRuntimeStatus == .off)
        XCTAssertTrue(disconnected, "losing the DERP runtime must flip the badge back to yellow")
        XCTAssertFalse(vm.tailcatRuntimeStatus.isDERPConnected)
        _ = (ctx, router)
    }

    func test_badgeIsGreenOnlyForActiveRuntime() {
        XCTAssertTrue(TailcatRuntimeStatus.active.isDERPConnected)
        for status: TailcatRuntimeStatus in [.off, .checking, .unavailable, .requiresSubscription] {
            XCTAssertFalse(
                status.isDERPConnected,
                "\(status) must render the yellow (not connected) badge"
            )
        }
    }

    func test_legacyStatusNotificationWithoutRawStatusIsIgnored() async throws {
        let (_, _, vm) = try makeSidebarViewModel()

        NotificationCenter.default.post(
            name: .rc2TailcatRuntimeStatusChanged,
            object: nil,
            userInfo: ["status": TailcatRuntimeStatus.active.displayText]
        )

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(
            vm.tailcatRuntimeStatus,
            .off,
            "notifications without a parseable rawStatus must not change the badge state"
        )
    }

    // MARK: - Helpers

    private func makeSettingsController() throws -> (SettingsWindowController, AppContext) {
        let directory = NSTemporaryDirectory() + "RC2TailcatDefaults-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let controller = SettingsWindowController(
            context: context,
            tailcatAccessSettingAuthority: TailcatAccessSettingAuthority()
        )
        controller.window.animationBehavior = .none
        return (controller, context)
    }

    private func makeSidebarViewModel() throws -> (AppContext, AppCommandRouter, SidebarViewModel) {
        let directory = NSTemporaryDirectory() + "RC2TailcatBadge-\(UUID().uuidString)"
        let ctx = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let vm = SidebarViewModel(context: ctx, router: router)
        return (ctx, router, vm)
    }

    private func close(_ controller: SettingsWindowController) {
        controller.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    @discardableResult
    private func drainUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        return condition()
    }
}

private extension SidebarViewModel {
    /// Observers are torn down in deinit; keep a named seam so tests can drop
    /// the VM without fighting lifetime warnings.
    func tearDownForTestingIfAvailable() {}
}
