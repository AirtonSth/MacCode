import XCTest
import Foundation
import AgentRuntime
@testable import AppShell

// WHY these tests exist (Rule 8):
// - SidebarViewModel.downloadErrorMessage(_:) is the contract between a raw Error
//   and the copy the user sees in the download-failed modal.
// - If it returns String(describing:) verbatim, the user sees an unintelligible
//   dump (e.g. "URLError(code: NSURLErrorNotConnectedToInternet, ...)") instead of
//   actionable guidance.  A regression in this function is a silent UX failure.
// - Each mapping case must fail when the corresponding error kind is passed but the
//   function returns the wrong copy -- that would mean the user sees the wrong
//   recovery instruction.

final class TokenSaverDownloadErrorMessageTests: XCTestCase {

    // MARK: - URLError: no network

    func test_urlError_notConnectedToInternet_returnsFriendlyNetworkCopy() {
        let error = URLError(.notConnectedToInternet)
        let message = SidebarViewModel.downloadErrorMessage(error)
        XCTAssertTrue(
            message.localizedLowercase.contains("internet") ||
            message.localizedLowercase.contains("network"),
            "No-network error must mention 'internet' or 'network'; got: \(message)"
        )
        XCTAssertFalse(
            message.contains("URLError") || message.contains("NSURLError"),
            "No-network error must not expose raw URLError type; got: \(message)"
        )
    }

    func test_urlError_networkConnectionLost_returnsFriendlyNetworkCopy() {
        let error = URLError(.networkConnectionLost)
        let message = SidebarViewModel.downloadErrorMessage(error)
        XCTAssertTrue(
            message.localizedLowercase.contains("internet") ||
            message.localizedLowercase.contains("network"),
            "Connection-lost error must mention network; got: \(message)"
        )
    }

    func test_urlError_timedOut_returnsFriendlyNetworkCopy() {
        let error = URLError(.timedOut)
        let message = SidebarViewModel.downloadErrorMessage(error)
        XCTAssertFalse(message.isEmpty, "timed-out error must return non-empty message")
        XCTAssertFalse(
            message.contains("URLError"),
            "timed-out error must not expose raw URLError type; got: \(message)"
        )
    }

    // MARK: - NSCocoaErrorDomain: disk space

    func test_diskSpaceError_returnsDiskSpaceCopy() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteOutOfSpaceError,
            userInfo: nil
        )
        let message = SidebarViewModel.downloadErrorMessage(error)
        XCTAssertTrue(
            message.localizedLowercase.contains("disk") ||
            message.localizedLowercase.contains("space"),
            "Disk-space error must mention 'disk' or 'space'; got: \(message)"
        )
        XCTAssertFalse(
            message.contains("NSCocoaErrorDomain"),
            "Disk-space error must not expose raw NSCocoaErrorDomain; got: \(message)"
        )
    }

    // MARK: - TokenSaverModelDownloadError: HTTP 401

    func test_httpStatus401_returnsAccessDeniedCopy() {
        let error = TokenSaverModelDownloadError.httpStatus(401, "api/models")
        let message = SidebarViewModel.downloadErrorMessage(error)
        XCTAssertTrue(
            message.localizedLowercase.contains("access") ||
            message.localizedLowercase.contains("sign in") ||
            message.localizedLowercase.contains("subscription"),
            "HTTP 401 must return access/sign-in copy; got: \(message)"
        )
    }

    func test_httpStatus500_returnsServerErrorCopy() {
        let error = TokenSaverModelDownloadError.httpStatus(503, "files/model.gguf")
        let message = SidebarViewModel.downloadErrorMessage(error)
        XCTAssertTrue(
            message.localizedLowercase.contains("server") ||
            message.localizedLowercase.contains("503"),
            "HTTP 5xx must mention server error or status code; got: \(message)"
        )
    }

    // MARK: - TokenSaverModelDownloadError: validation failed

    func test_validationFailed_returnsVerificationCopy() {
        let error = TokenSaverModelDownloadError.validationFailed("checksum mismatch")
        let message = SidebarViewModel.downloadErrorMessage(error)
        XCTAssertTrue(
            message.localizedLowercase.contains("verif") ||
            message.localizedLowercase.contains("corrupt") ||
            message.localizedLowercase.contains("retry"),
            "Validation failure must suggest retrying or mention corruption; got: \(message)"
        )
    }

    // MARK: - Unknown error: non-empty generic fallback

    func test_unknownError_returnsNonEmptyGenericMessage() {
        struct WeirdError: Error {}
        let message = SidebarViewModel.downloadErrorMessage(WeirdError())
        XCTAssertFalse(message.isEmpty, "Unknown error must return non-empty message")
        // Must not dump the raw type name as the primary message
        XCTAssertFalse(
            message.contains("WeirdError"),
            "Unknown error must not expose the raw Swift type name; got: \(message)"
        )
    }

    // MARK: - Generic fallback contains 'failed' to confirm it's not a stale old string

    func test_unknownError_genericMessageContainsFailedOrDownload() {
        struct AnotherError: Error {}
        let message = SidebarViewModel.downloadErrorMessage(AnotherError())
        let lower = message.localizedLowercase
        XCTAssertTrue(
            lower.contains("download") || lower.contains("failed") || lower.contains("try"),
            "Generic fallback must be user-facing (mention download/failed/try); got: \(message)"
        )
    }
}

// WHY these tests exist (Rule 8):
// downloadConfirmDecision is the pure arithmetic gate that prevents an
// accidental single-click from silently starting a multi-GB download and that
// warns the user when their disk is too full to complete the download.
// If the threshold arithmetic is wrong the guard never fires, so an accidental
// click wastes bandwidth and a nearly-full disk silently runs out of space.
// Each test case must fail when the relevant boundary condition is violated.
@MainActor
final class TokenSaverDownloadConfirmDecisionTests: XCTestCase {

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

    // MARK: - Insufficient disk

    func test_downloadConfirmDecision_insufficientDisk_whenFreeLessThanModelPlusMargin() {
        // WHY: free space exactly one byte below the required threshold must
        // return .insufficientDisk so the confirm dialog warns before any
        // network traffic begins.
        let modelBytes = SidebarViewModel.approvedModelEstimatedBytes
        let margin = SidebarViewModel.downloadDiskMarginBytes
        let free = modelBytes + margin - 1
        XCTAssertEqual(
            SidebarViewModel.downloadConfirmDecision(modelBytes: modelBytes, freeDiskBytes: free),
            .insufficientDisk,
            "free < model + margin must return .insufficientDisk; an accidental click on a nearly-full disk must be blocked"
        )
    }

    func test_downloadConfirmDecision_insufficientDisk_whenFreeIsZero() {
        // WHY: a completely full disk must never silently start the download.
        XCTAssertEqual(
            SidebarViewModel.downloadConfirmDecision(
                modelBytes: SidebarViewModel.approvedModelEstimatedBytes,
                freeDiskBytes: 0
            ),
            .insufficientDisk,
            "zero free bytes must return .insufficientDisk regardless of model size"
        )
    }

    // MARK: - Confirm (enough space)

    func test_downloadConfirmDecision_confirm_whenFreeEqualsModelPlusMargin() {
        // WHY: the boundary case -- exactly enough space -- must allow the
        // download to proceed so the user is not incorrectly blocked.
        let modelBytes = SidebarViewModel.approvedModelEstimatedBytes
        let margin = SidebarViewModel.downloadDiskMarginBytes
        let free = modelBytes + margin
        XCTAssertEqual(
            SidebarViewModel.downloadConfirmDecision(modelBytes: modelBytes, freeDiskBytes: free),
            .confirm,
            "free == model + margin must return .confirm; the user has exactly enough space"
        )
    }

    func test_downloadConfirmDecision_confirm_whenFreeIsAmple() {
        // WHY: a mac with plenty of free space must reach the confirm dialog,
        // not an error dialog, so the user can proceed normally.
        let modelBytes = SidebarViewModel.approvedModelEstimatedBytes
        let margin = SidebarViewModel.downloadDiskMarginBytes
        let free = modelBytes + margin + 10_000_000_000  // 10 GB extra
        XCTAssertEqual(
            SidebarViewModel.downloadConfirmDecision(modelBytes: modelBytes, freeDiskBytes: free),
            .confirm,
            "ample free space must return .confirm"
        )
    }

    // MARK: - Confirm gate blocks download when user cancels

    func test_setTokenSaverEnabled_doesNotBeginDownload_whenConfirmDenied() async throws {
        // WHY: if the confirm provider returns false the download must not
        // start -- tokenSaverEnabled stays false and the download modal stays
        // closed, so an accidental click has zero side effects.
        let missing: SidebarViewModel.TokenSaverModelValidationProvider = {
            TokenSaverModelValidation(state: .missing, reason: "manifest missing")
        }
        var downloadStarted = false
        let neverDownload: SidebarViewModel.TokenSaverModelDownloadHandler = { _ in
            downloadStarted = true
            throw CancellationError()
        }
        let deny: SidebarViewModel.TokenSaverDownloadConfirmProvider = { _, _ in false }

        let dir = NSTemporaryDirectory() + "RC2DownloadConfirmDeny-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        PrivateAccountSessionStore(repo: ctx.settingsRepo).save(PrivateAccountSession(
            accessToken: "tok",
            refreshToken: "ref",
            user: PrivateAccountUser(daysRemaing: nil, daysRemaining: 30, email: "paid@example.com", id: "paid", subscribed: true)
        ))

        let vm = SidebarViewModel(
            context: ctx,
            router: router,
            tokenSaverModelValidationProvider: missing,
            tokenSaverModelDownloadHandler: neverDownload,
            tokenSaverDownloadConfirmProvider: deny
        )
        vm.reload()

        vm.setTokenSaverEnabled(true)

        XCTAssertFalse(downloadStarted,
                       "a denied confirm must not call the download handler; the user clicked Cancel")
        XCTAssertFalse(vm.tokenSaverEnabled,
                       "Token Saver must stay disabled when the user cancels the download confirm")
        XCTAssertFalse(vm.showsTokenSaverModelDownload,
                       "the download modal must not open when the confirm was denied")
    }

    func test_setTokenSaverEnabled_beginsDownload_whenConfirmAccepted() async throws {
        // WHY: if the confirm provider returns true the download must start,
        // proving the gate lets the normal path through when the user agrees.
        let missing: SidebarViewModel.TokenSaverModelValidationProvider = {
            TokenSaverModelValidation(state: .missing, reason: nil)
        }
        var downloadStarted = false
        let hangDownload: SidebarViewModel.TokenSaverModelDownloadHandler = { progress in
            downloadStarted = true
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw CancellationError()
        }
        let accept: SidebarViewModel.TokenSaverDownloadConfirmProvider = { _, _ in true }

        let dir = NSTemporaryDirectory() + "RC2DownloadConfirmAccept-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        PrivateAccountSessionStore(repo: ctx.settingsRepo).save(PrivateAccountSession(
            accessToken: "tok",
            refreshToken: "ref",
            user: PrivateAccountUser(daysRemaing: nil, daysRemaining: 30, email: "paid@example.com", id: "paid", subscribed: true)
        ))

        let vm = SidebarViewModel(
            context: ctx,
            router: router,
            tokenSaverModelValidationProvider: missing,
            tokenSaverModelDownloadHandler: hangDownload,
            tokenSaverDownloadConfirmProvider: accept
        )
        vm.reload()

        vm.setTokenSaverEnabled(true)

        // beginTokenSaverModelDownload launches a Task; wait briefly for it to start.
        let started = await waitUntil { downloadStarted }
        XCTAssertTrue(started,
                      "an accepted confirm must reach the download handler; the gate must not block a willing user")
        XCTAssertTrue(vm.showsTokenSaverModelDownload,
                      "the download modal must open after confirm accepted")
    }

    // MARK: - No confirm when model already installed

    func test_setTokenSaverEnabled_skipsConfirm_whenModelAlreadyInstalled() async throws {
        // WHY: the confirm is only for the multi-GB network fetch; when the
        // model is already present on disk no download happens and the prompt
        // must not appear. (The confirm provider should never be called.)
        var confirmCalled = false
        let unexpectedConfirm: SidebarViewModel.TokenSaverDownloadConfirmProvider = { _, _ in
            confirmCalled = true
            return false
        }
        let installed: SidebarViewModel.TokenSaverModelValidationProvider = { .installed }

        let dir = NSTemporaryDirectory() + "RC2DownloadConfirmInstalled-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        PrivateAccountSessionStore(repo: ctx.settingsRepo).save(PrivateAccountSession(
            accessToken: "tok",
            refreshToken: "ref",
            user: PrivateAccountUser(daysRemaing: nil, daysRemaining: 30, email: "paid@example.com", id: "paid", subscribed: true)
        ))

        let vm = SidebarViewModel(
            context: ctx,
            router: router,
            tokenSaverModelValidationProvider: installed,
            tokenSaverDownloadConfirmProvider: unexpectedConfirm
        )
        vm.reload()

        vm.setTokenSaverEnabled(true)

        XCTAssertFalse(confirmCalled,
                       "when the model is already installed no download is needed; the confirm dialog must not appear")
        XCTAssertTrue(vm.tokenSaverEnabled,
                      "model already installed => Token Saver must enable immediately without a confirm prompt")
    }
}
