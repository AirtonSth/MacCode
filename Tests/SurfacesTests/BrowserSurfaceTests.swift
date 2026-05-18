import XCTest
@testable import Surfaces

// BrowserSurface is @MainActor; its static helpers inherit that isolation.
// Under the Swift 6 compiler these calls must come from a MainActor context,
// so the test case itself is MainActor-isolated. (Pre-existing build blocker
// for the whole SwiftPM test bundle — unrelated to git-tab work.)
@MainActor
final class BrowserSurfaceTests: XCTestCase {
    func test_safariUserAgent_identifiesEmbeddedBrowserAsDesktopSafari() {
        let ua = BrowserSurface.safariLikeUserAgent(
            safariVersion: "26.3.1"
        )

        XCTAssertTrue(ua.contains("Macintosh; Intel Mac OS X 10_15_7"))
        XCTAssertTrue(ua.contains("Version/26.3.1 Safari/605.1.15"))
        XCTAssertFalse(ua.contains("RemoteCode"))
        XCTAssertFalse(ua.contains("WKWebView"))
    }

    func test_googleHostDetection_onlyMatchesGoogleDomains() {
        XCTAssertTrue(BrowserSurface.isGoogleHost("google.com"))
        XCTAssertTrue(BrowserSurface.isGoogleHost("www.google.com"))
        XCTAssertFalse(BrowserSurface.isGoogleHost("evilgoogle.com"))
        XCTAssertFalse(BrowserSurface.isGoogleHost("google.com.example"))
    }
}
