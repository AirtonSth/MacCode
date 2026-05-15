import XCTest
@testable import Surfaces

final class BrowserSurfaceTests: XCTestCase {
    func test_safariUserAgent_identifiesEmbeddedBrowserAsDesktopSafari() {
        let ua = BrowserSurface.safariLikeUserAgent(
            safariVersion: "26.3.1"
        )

        XCTAssertTrue(ua.contains("Macintosh; Intel Mac OS X 10_15_7"))
        XCTAssertTrue(ua.contains("Version/26.3.1 Safari/605.1.15"))
        XCTAssertFalse(ua.contains("RemoteCode2"))
        XCTAssertFalse(ua.contains("WKWebView"))
    }

    func test_googleHostDetection_onlyMatchesGoogleDomains() {
        XCTAssertTrue(BrowserSurface.isGoogleHost("google.com"))
        XCTAssertTrue(BrowserSurface.isGoogleHost("www.google.com"))
        XCTAssertFalse(BrowserSurface.isGoogleHost("evilgoogle.com"))
        XCTAssertFalse(BrowserSurface.isGoogleHost("google.com.example"))
    }
}
