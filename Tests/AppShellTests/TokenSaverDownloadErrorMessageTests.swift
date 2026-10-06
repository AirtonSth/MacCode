import XCTest
import Foundation
import AgentRuntime
import Persistence
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

    func test_downloadConfirmDecision_confirm_whenFreeDiskIsUnknown() {
        // WHY: `volumeFreeDiskBytes()` cannot measure the volume when the
        // resource-value query fails, and reports its unknown sentinel (-1).
        // Reading that sentinel as "full" showed the blocking "Not enough disk
        // space" alert -- whose only button is OK -- to a user whose disk was
        // fine. Unknown must fall through to the normal confirm dialog; if the
        // disk really is full the download fails loudly on the write.
        XCTAssertGreaterThanOrEqual(
            SidebarViewModel.volumeFreeDiskBytes(),
            0,
            "a readable home volume must report real free bytes, never the sentinel"
        )
        XCTAssertEqual(
            SidebarViewModel.downloadConfirmDecision(
                modelBytes: SidebarViewModel.approvedModelEstimatedBytes,
                freeDiskBytes: -1
            ),
            .confirm,
            "an unmeasurable volume must not be reported as insufficient disk"
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
}
