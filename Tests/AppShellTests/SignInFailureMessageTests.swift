import XCTest
@testable import AppShell

/// WHY: SettingsViewModel.signInFailureMessage(for:) maps transport/API errors
/// to distinct user-visible status strings. Without tests, a code change that
/// collapses 401 and 429 into the same message (or makes every URLError say
/// "Service unavailable") ships silently. The set also drives the inline error
/// hint visibility via signInFailureStatuses - a missing mapping leaves users
/// with no actionable feedback.
///
/// All cases are nonisolated static - no AppContext, no MainActor needed.
@MainActor
final class SignInFailureMessageTests: XCTestCase {

    // MARK: - PrivateAccountAPIError.http

    /// 401 Unauthorized: the user's credentials were rejected.
    /// Message must be "Sign in failed" (distinct from 429 / 5xx) so the UI
    /// tells the user to check their password, not to wait.
    func test_http401_returnsSignInFailed() {
        let msg = SettingsViewModel.signInFailureMessage(for: PrivateAccountAPIError.http(401))
        XCTAssertEqual(msg, "Sign in failed",
                       "401 means bad credentials; the user needs to re-enter their password, not wait")
    }

    /// 403 Forbidden: treated identically to 401 at the UX layer.
    func test_http403_returnsSignInFailed() {
        let msg = SettingsViewModel.signInFailureMessage(for: PrivateAccountAPIError.http(403))
        XCTAssertEqual(msg, "Sign in failed",
                       "403 must map to 'Sign in failed' like 401 so the user gets the same actionable prompt")
    }

    /// 429 Too Many Requests: the user hammered the endpoint.
    /// Must be distinct from 401 so they know to wait, not retry immediately.
    func test_http429_returnsTooManyAttempts() {
        let msg = SettingsViewModel.signInFailureMessage(for: PrivateAccountAPIError.http(429))
        XCTAssertEqual(msg, "Too many attempts, wait a minute",
                       "429 must tell users to back off - mapping it to 'Sign in failed' would prompt immediate retries that worsen the rate-limit")
    }

    /// 500 Internal Server Error: lower bound of 5xx range.
    func test_http500_returnsServiceUnavailable() {
        let msg = SettingsViewModel.signInFailureMessage(for: PrivateAccountAPIError.http(500))
        XCTAssertEqual(msg, "Service unavailable",
                       "500 must map to 'Service unavailable', not 'Sign in failed', so the user knows the problem is server-side")
    }

    /// 503 Service Unavailable: mid-range 5xx.
    func test_http503_returnsServiceUnavailable() {
        let msg = SettingsViewModel.signInFailureMessage(for: PrivateAccountAPIError.http(503))
        XCTAssertEqual(msg, "Service unavailable",
                       "503 must map to 'Service unavailable' - same as 500")
    }

    /// 599 is the upper bound of the 5xx range handled explicitly.
    func test_http599_returnsServiceUnavailable() {
        let msg = SettingsViewModel.signInFailureMessage(for: PrivateAccountAPIError.http(599))
        XCTAssertEqual(msg, "Service unavailable",
                       "599 is still in the 5xx range and must map to 'Service unavailable'")
    }

    /// 400 Bad Request: outside the explicitly handled ranges. Falls through to
    /// "Service error" so user knows to contact support rather than retry or wait.
    func test_http400_returnsServiceError() {
        let msg = SettingsViewModel.signInFailureMessage(for: PrivateAccountAPIError.http(400))
        XCTAssertEqual(msg, "Service error",
                       "400 is not in the handled 401/403/429/5xx sets; the fallthrough must be 'Service error' not 'Service unavailable'")
    }

    /// invalidResponse: the server returned something not parseable as HTTP.
    /// Must surface as "Service error" (not crash or return "Sign in failed").
    func test_invalidResponse_returnsServiceError() {
        let msg = SettingsViewModel.signInFailureMessage(for: PrivateAccountAPIError.invalidResponse)
        XCTAssertEqual(msg, "Service error",
                       "an unparseable response must map to 'Service error' - silent nil or crash would hide the failure from the user")
    }

    // MARK: - URLError

    /// No internet connection: the device is offline.
    /// Must say "No internet connection" so the user checks their network,
    /// not their credentials.
    func test_urlError_notConnectedToInternet_returnsNoInternet() {
        let err = URLError(.notConnectedToInternet)
        let msg = SettingsViewModel.signInFailureMessage(for: err)
        XCTAssertEqual(msg, "No internet connection",
                       "notConnectedToInternet must not map to 'Service unavailable' - the fix is on the device, not the server")
    }

    /// Network connection was dropped mid-request.
    func test_urlError_networkConnectionLost_returnsNoInternet() {
        let err = URLError(.networkConnectionLost)
        let msg = SettingsViewModel.signInFailureMessage(for: err)
        XCTAssertEqual(msg, "No internet connection",
                       "networkConnectionLost must map to 'No internet connection' - a dropped connection is an offline symptom")
    }

    /// Data plan disallowed (e.g. parental controls, MDM).
    func test_urlError_dataNotAllowed_returnsNoInternet() {
        let err = URLError(.dataNotAllowed)
        let msg = SettingsViewModel.signInFailureMessage(for: err)
        XCTAssertEqual(msg, "No internet connection",
                       "dataNotAllowed must map to 'No internet connection' - the user needs to change network permissions, not retry credentials")
    }

    /// Request timed out: the server was too slow.
    /// Must say "Service unavailable" (server-side) not "No internet connection".
    func test_urlError_timedOut_returnsServiceUnavailable() {
        let err = URLError(.timedOut)
        let msg = SettingsViewModel.signInFailureMessage(for: err)
        XCTAssertEqual(msg, "Service unavailable",
                       "timedOut means the server was unreachable, not that the device has no internet - must not confuse the user about where the fault lies")
    }

    /// Cannot connect to host: server down or DNS works but port closed.
    func test_urlError_cannotConnectToHost_returnsServiceUnavailable() {
        let err = URLError(.cannotConnectToHost)
        let msg = SettingsViewModel.signInFailureMessage(for: err)
        XCTAssertEqual(msg, "Service unavailable",
                       "cannotConnectToHost means the server is unreachable; mapping to 'No internet' would mislead a user who has Wi-Fi but the server is down")
    }

    /// Cannot find host (DNS failure for the server's domain).
    func test_urlError_cannotFindHost_returnsServiceUnavailable() {
        let err = URLError(.cannotFindHost)
        let msg = SettingsViewModel.signInFailureMessage(for: err)
        XCTAssertEqual(msg, "Service unavailable",
                       "cannotFindHost means DNS failed for the server; must not map to 'No internet connection'")
    }

    /// Unknown URLError code: the default branch returns "No internet connection".
    /// This tests that unknown codes do not crash or return an empty string.
    func test_urlError_unknownCode_returnsNoInternet() {
        let err = URLError(.unknown)
        let msg = SettingsViewModel.signInFailureMessage(for: err)
        XCTAssertEqual(msg, "No internet connection",
                       "an unknown URLError must fall through to 'No internet connection' as the default - never an empty string or crash")
    }

    // MARK: - Generic (non-API, non-URL) error

    /// A plain NSError or custom error not matching any handled type must fall
    /// through to "Sign in failed" - the safest default that still tells the
    /// user something went wrong.
    func test_genericError_returnsSignInFailed() {
        struct SomeOtherError: Error {}
        let msg = SettingsViewModel.signInFailureMessage(for: SomeOtherError())
        XCTAssertEqual(msg, "Sign in failed",
                       "an unrecognised error type must fall through to 'Sign in failed', not crash or return empty")
    }

    // MARK: - signInFailureStatuses coverage

    /// Every message returned by signInFailureMessage must appear in
    /// signInFailureStatuses so the inline error-hint logic fires for all of them.
    /// If a message is returned but not in the set, the hint is silently suppressed.
    func test_allReturnedMessages_areInSignInFailureStatuses() {
        let allMessages: [String] = [
            SettingsViewModel.signInFailureMessage(for: PrivateAccountAPIError.http(401)),
            SettingsViewModel.signInFailureMessage(for: PrivateAccountAPIError.http(429)),
            SettingsViewModel.signInFailureMessage(for: PrivateAccountAPIError.http(500)),
            SettingsViewModel.signInFailureMessage(for: PrivateAccountAPIError.http(400)),
            SettingsViewModel.signInFailureMessage(for: PrivateAccountAPIError.invalidResponse),
            SettingsViewModel.signInFailureMessage(for: URLError(.notConnectedToInternet)),
            SettingsViewModel.signInFailureMessage(for: URLError(.timedOut)),
        ]
        let statuses = SettingsViewModel.signInFailureStatuses
        for msg in allMessages {
            XCTAssertTrue(statuses.contains(msg),
                          "message '\(msg)' returned by signInFailureMessage must appear in " +
                          "signInFailureStatuses or the inline error hint will never show for that failure")
        }
    }
}
