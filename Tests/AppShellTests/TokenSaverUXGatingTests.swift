import XCTest
import AppKit
@testable import AppShell
import AgentRuntime
import Persistence

// WHY these tests exist (Rule 8):
// :185 -- A paused download shows only Cancel; Resume must exist and re-start
//         the download. Without this test a paused download is stuck -- the
//         user can only Cancel and lose progress context.
// :190 -- A blocked sidecar leaves the headline unchanged; the degraded copy
//         must appear so the user knows compression stopped, not just "Saved X
//         tokens" which implies everything is fine.
// :191 -- setTokenSaverEnabled(false) previously stopped + uninstalled with no
//         warning. The confirm gate must fire; bypassing it (gate returns false)
//         must leave Token Saver enabled.

@MainActor
final class TokenSaverUXGatingTests: XCTestCase {

    // MARK: - Shared helpers

    private final class FakeInsomniaPower: InsomniaPowerManaging {
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

    private func makeVM(
        dir: String = NSTemporaryDirectory() + "RC2UXGate-" + UUID().uuidString,
        subscribed: Bool = true,
        downloadHandler: SidebarViewModel.TokenSaverModelDownloadHandler? = nil,
        validationProvider: SidebarViewModel.TokenSaverModelValidationProvider? = nil,
        downloadConfirmProvider: SidebarViewModel.TokenSaverDownloadConfirmProvider? = nil,
        disableConfirmProvider: SidebarViewModel.TokenSaverDisableConfirmProvider? = nil
    ) throws -> (AppContext, AppCommandRouter, SidebarViewModel) {
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        if subscribed {
            PrivateAccountSessionStore(repo: ctx.settingsRepo).save(PrivateAccountSession(
                accessToken: "tok",
                refreshToken: "ref",
                user: PrivateAccountUser(
                    daysRemaing: nil,
                    daysRemaining: 30,
                    email: "test@example.com",
                    id: "uid",
                    subscribed: true
                )
            ))
        }
        let vm = SidebarViewModel(
            context: ctx,
            router: router,
            insomniaPower: FakeInsomniaPower(),
            powerMonitor: FakeExternalPowerMonitor(),
            tokenSaverModelValidationProvider: validationProvider,
            tokenSaverModelDownloadHandler: downloadHandler,
            tokenSaverDownloadConfirmProvider: downloadConfirmProvider,
            tokenSaverDisableConfirmProvider: disableConfirmProvider
        )
        vm.reload()
        return (ctx, router, vm)
    }

    // MARK: - :185 Resume button / resumeTokenSaverModelDownload

    func test_resumeTokenSaverModelDownload_setsShowsModalTrue() throws {
        // WHY: cancelTokenSaverModelDownload dismisses the sheet (showsTokenSaverModelDownload=false).
        // resumeTokenSaverModelDownload must re-open it so the modal reappears.
        var beginCalled = 0
        let handler: SidebarViewModel.TokenSaverModelDownloadHandler = { _ in
            beginCalled += 1
            // Suspend until cancelled so we can assert state while it runs.
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw CancellationError()
        }
        let (_, _, vm) = try makeVM(downloadHandler: handler)
        vm.cancelTokenSaverModelDownload()
        XCTAssertFalse(vm.showsTokenSaverModelDownload,
                       "cancel must dismiss the modal before resume is called")
        vm.resumeTokenSaverModelDownload()
        XCTAssertTrue(vm.showsTokenSaverModelDownload,
                      "resumeTokenSaverModelDownload must re-open the download modal")
    }

    func test_resumeTokenSaverModelDownload_invokesBeginDownload() throws {
        // WHY: resume must actually restart the download, not just show the modal.
        // Verifying the handler is invoked proves beginTokenSaverModelDownload was called.
        var beginCalled = 0
        let handler: SidebarViewModel.TokenSaverModelDownloadHandler = { _ in
            beginCalled += 1
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw CancellationError()
        }
        let (_, _, vm) = try makeVM(downloadHandler: handler)
        // Pause the download first.
        vm.cancelTokenSaverModelDownload()
        // Resume must trigger a new download task.
        vm.resumeTokenSaverModelDownload()
        // Give the task a tick to start.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertGreaterThan(beginCalled, 0,
                             "resumeTokenSaverModelDownload must invoke the download handler")
    }

    func test_downloadModal_isPaused_afterCancel() throws {
        // WHY: the paused state is what controls Resume button visibility.
        // Confirm cancel sets phase to .paused (not .idle or .failed).
        let stallHandler: SidebarViewModel.TokenSaverModelDownloadHandler = { _ in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw CancellationError()
        }
        let (_, _, vm) = try makeVM(
            downloadHandler: stallHandler,
            downloadConfirmProvider: { _, _ in true }   // skip NSAlert in tests
        )
        vm.setTokenSaverEnabled(true)   // triggers beginTokenSaverModelDownload
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        vm.cancelTokenSaverModelDownload()
        XCTAssertEqual(vm.tokenSaverModelDownloadState.phase, .paused,
                       "cancel must leave phase == .paused so the Resume button appears")
    }

    // MARK: - :190 Degraded headline when sidecar is blocked

    func test_tokenSaverCardHeadline_blocked_returnsDegradedCopy() {
        // WHY: when sidecar is blocked the user gets no signal from the savings
        // headline that compression has stopped. The degraded variant must appear.
        let headline = SidebarRootView.tokenSaverCardHeadline(
            subscribed: true,
            enabled: true,
            sidecarStatus: .blocked("GPU unavailable"),
            savedTokens: 50_000,
            usedTokens: 200_000
        )
        XCTAssertTrue(
            headline.lowercased().contains("degraded"),
            "Blocked sidecar must produce a degraded headline; got: '\(headline)'"
        )
        XCTAssertFalse(
            headline.lowercased().contains("saved"),
            "Blocked sidecar must not report saved tokens as if healthy; got: '\(headline)'"
        )
    }

    func test_tokenSaverCardHeadline_notStarted_returnsSavingsCopy() {
        // WHY: healthy (not-yet-started) state must still show saved tokens.
        // If this regresses, the degraded-branch logic has overreached into
        // non-blocked states.
        let headline = SidebarRootView.tokenSaverCardHeadline(
            subscribed: true,
            enabled: true,
            sidecarStatus: .notStarted,
            savedTokens: 50_000,
            usedTokens: 200_000
        )
        XCTAssertTrue(
            headline.lowercased().contains("saved") || headline.lowercased().contains("tracking"),
            "Non-blocked sidecar must show savings headline; got: '\(headline)'"
        )
    }

    func test_tokenSaverCardHeadline_blockedButDisabled_returnsEnableCopy() {
        // WHY: blocked only matters when enabled. If disabled the card shows
        // "Enable savings" regardless of sidecar state.
        let headline = SidebarRootView.tokenSaverCardHeadline(
            subscribed: true,
            enabled: false,
            sidecarStatus: .blocked("GPU unavailable"),
            savedTokens: 0,
            usedTokens: 0
        )
        XCTAssertEqual(headline, "Enable savings",
                       "Disabled Token Saver must show 'Enable savings' even when sidecar is blocked")
    }

    func test_shouldConfirmTokenSaverDisable_alwaysTrue() {
        // WHY: every disable must go through the confirm path. If this seam ever
        // returns false, the confirm gate in setTokenSaverEnabled is silently bypassed.
        XCTAssertTrue(SidebarViewModel.shouldConfirmTokenSaverDisable(),
                      "shouldConfirmTokenSaverDisable must always return true")
    }

    // MARK: - :191 Disable-confirm gate

    func test_setTokenSaverEnabled_false_doesNotDisableWhenConfirmDenied() throws {
        // WHY: if the user taps Cancel in the confirm alert, Token Saver must
        // remain enabled. Bypassing the guard means the user loses their setting
        // without consent.
        let (_, _, vm) = try makeVM(
            validationProvider: { .installed },
            disableConfirmProvider: { false }   // user taps Cancel
        )
        vm.setTokenSaverEnabled(true)           // enable first (model is installed)
        XCTAssertTrue(vm.tokenSaverEnabled, "pre-condition: Token Saver must be on")

        vm.setTokenSaverEnabled(false)
        XCTAssertTrue(vm.tokenSaverEnabled,
                      "setTokenSaverEnabled(false) must not disable when confirm returns false")
    }

    func test_setTokenSaverEnabled_false_disablesWhenConfirmAccepted() throws {
        // WHY: if the user confirms, Token Saver must actually stop.
        // This is the "happy path" of the confirm gate.
        let (_, _, vm) = try makeVM(
            validationProvider: { .installed },
            disableConfirmProvider: { true }    // user taps Disable
        )
        vm.setTokenSaverEnabled(true)
        XCTAssertTrue(vm.tokenSaverEnabled, "pre-condition: Token Saver must be on")

        vm.setTokenSaverEnabled(false)
        XCTAssertFalse(vm.tokenSaverEnabled,
                       "setTokenSaverEnabled(false) must disable when confirm returns true")
    }

    func test_setTokenSaverEnabled_true_doesNotRequireDisableConfirm() throws {
        // WHY: the confirm gate must only fire on disable, not enable.
        // If it fired on enable, enabling would be broken.
        var confirmCallCount = 0
        let (_, _, vm) = try makeVM(
            validationProvider: { .installed },
            disableConfirmProvider: {
                confirmCallCount += 1
                return true
            }
        )
        vm.setTokenSaverEnabled(true)
        XCTAssertEqual(confirmCallCount, 0,
                       "disableConfirmProvider must not be called when enabling Token Saver")
    }
}
