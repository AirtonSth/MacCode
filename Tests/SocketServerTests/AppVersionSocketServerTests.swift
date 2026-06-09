import XCTest
@testable import SocketServer

/// Verifies that SocketServer's AppVersion.short helper resolves
/// CFBundleShortVersionString from Bundle.main, or returns a sane non-crashing
/// fallback when the key is absent (SPM test host).
///
/// Why this matters: DirectHTTPServer's /v1/discovery endpoint advertises
/// "version" to iOS clients. A hardcoded literal means bumping the app version
/// requires a code change; a missing or empty value breaks iOS version
/// negotiation during LAN pairing.
final class AppVersionSocketServerTests: XCTestCase {

    func test_short_returnsNonEmptyString() {
        let v = AppVersion.short
        XCTAssertFalse(
            v.isEmpty,
            "AppVersion.short must never return an empty string; /v1/discovery version field must always carry a parseable value for iOS client version negotiation"
        )
    }

    func test_short_matchesBundleOrFallback() {
        let v = AppVersion.short
        let expected = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        XCTAssertEqual(
            v, expected,
            "AppVersion.short must return CFBundleShortVersionString when present (real app bundle) or 'unknown' fallback (SPM test host) — the /v1/discovery version field must be driven by the bundle, not a hardcoded literal"
        )
    }
}
