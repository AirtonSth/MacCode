import XCTest
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
