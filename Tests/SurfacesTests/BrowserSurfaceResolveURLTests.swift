import XCTest
import CoreModel
@testable import Surfaces

/// Tests for BrowserSurface pure helpers: resolveURL (T037),
/// hidden-navigation deferral via isVisibleForTesting (T038), and
/// legacy-Google reload cap googleLegacyLayoutReloadCap (T043).
///
/// All tests are @MainActor because BrowserSurface is @MainActor.
@MainActor
final class BrowserSurfaceResolveURLTests: XCTestCase {

    // MARK: - resolveURL (T037)

    // WHY: a fully-qualified https URL must pass through unchanged.
    // If resolveURL strips or alters the scheme the surface navigates to
    // the wrong resource.
    func test_resolveURL_httpsURL_returnsUnchanged() throws {
        let result = try XCTUnwrap(BrowserSurface.resolveURL(from: "https://github.com/foo/bar"))
        XCTAssertEqual(result.absoluteString, "https://github.com/foo/bar")
    }

    // WHY: a URL with a custom scheme (e.g. http://) must be preserved as-is
    // so development servers on http are reachable.
    func test_resolveURL_httpURL_returnsUnchanged() throws {
        let result = try XCTUnwrap(BrowserSurface.resolveURL(from: "http://localhost:3000/"))
        XCTAssertEqual(result.absoluteString, "http://localhost:3000/")
    }

    // WHY: scheme-less input that looks like a hostname (contains a dot, no
    // spaces) must be prefixed with https:// so the user can type "apple.com"
    // without typing the scheme -- matching Safari/Chrome omnibox behavior.
    func test_resolveURL_schemelessHost_prefixesHttps() throws {
        let result = try XCTUnwrap(BrowserSurface.resolveURL(from: "apple.com"))
        XCTAssertEqual(result.absoluteString, "https://apple.com")
    }

    func test_resolveURL_schemelessHostWithPath_prefixesHttps() throws {
        let result = try XCTUnwrap(BrowserSurface.resolveURL(from: "example.com/docs"))
        XCTAssertEqual(result.absoluteString, "https://example.com/docs")
    }

    // WHY: a query string with spaces must be routed to the default search
    // engine, NOT treated as a URL. Sending a bare query to URL(string:)
    // returns nil; the fallback search path ensures the user gets results.
    func test_resolveURL_queryWithSpaces_returnsSearchURL() throws {
        let result = try XCTUnwrap(BrowserSurface.resolveURL(from: "weather tomorrow"))
        XCTAssertTrue(result.absoluteString.hasPrefix("https://www.google.com/search?q="),
                      "query with spaces must become a Google search URL")
        XCTAssertTrue(result.absoluteString.contains("weather"),
                      "search URL must contain the query terms")
    }

    // WHY: a single-word term with no dots must also be treated as a search
    // query so "swift" goes to a search rather than trying "https://swift"
    // (which doesn't resolve).
    func test_resolveURL_singleWordNoDots_returnsSearchURL() throws {
        let result = try XCTUnwrap(BrowserSurface.resolveURL(from: "swift"))
        XCTAssertTrue(result.absoluteString.hasPrefix("https://www.google.com/search?q="),
                      "bare word with no dots must become a search URL")
    }

    // WHY: empty input must return nil, not a URL, so navigate(string:)
    // correctly returns false and avoids a blank navigation.
    func test_resolveURL_emptyString_returnsNil() {
        let result = BrowserSurface.resolveURL(from: "")
        XCTAssertNil(result, "empty input must produce nil, not a navigation")
    }

    func test_resolveURL_whitespaceOnly_returnsNil() {
        let result = BrowserSurface.resolveURL(from: "   ")
        XCTAssertNil(result, "whitespace-only input must produce nil")
    }

    // WHY: about:blank is treated as a missing URL by normalizedInitialURL
    // and should fall through to the default page; resolveURL should still
    // return a URL for it (it contains "://").
    func test_resolveURL_aboutBlank_returnsURL() throws {
        let result = try XCTUnwrap(BrowserSurface.resolveURL(from: "about:blank"))
        XCTAssertEqual(result.absoluteString, "about:blank")
    }

    // MARK: - hidden-navigation deferral (T038)

    // WHY: navigate(to:) while the surface is hidden must NOT trigger a
    // webView.load; the load is deferred until didBecomeVisible. If the
    // browser loads while hidden, WebKit spins up an offscreen process for
    // content the user cannot see, wasting CPU and memory.
    func test_isVisibleForTesting_startsTrue() {
        let surface = BrowserSurface(workspaceID: WorkspaceID(), initialURL: nil, title: "t")
        XCTAssertTrue(surface.isVisibleForTesting,
                      "a freshly-created surface must start visible")
    }

    func test_didBecomeHidden_setsIsVisibleFalse() {
        let surface = BrowserSurface(workspaceID: WorkspaceID(), initialURL: nil, title: "t")
        surface.didBecomeHidden()
        XCTAssertFalse(surface.isVisibleForTesting,
                       "didBecomeHidden must flip isVisible to false so deferred-load logic triggers")
    }

    func test_didBecomeVisible_setsIsVisibleTrue() {
        let surface = BrowserSurface(workspaceID: WorkspaceID(), initialURL: nil, title: "t")
        surface.didBecomeHidden()
        surface.didBecomeVisible()
        XCTAssertTrue(surface.isVisibleForTesting,
                      "didBecomeVisible must restore isVisible so subsequent navigations load immediately")
    }

    func test_didBecomeVisible_idempotent() {
        let surface = BrowserSurface(workspaceID: WorkspaceID(), initialURL: nil, title: "t")
        // Already visible
        surface.didBecomeVisible()
        XCTAssertTrue(surface.isVisibleForTesting,
                      "calling didBecomeVisible on an already-visible surface must be a no-op")
    }

    func test_didBecomeHidden_idempotent() {
        let surface = BrowserSurface(workspaceID: WorkspaceID(), initialURL: nil, title: "t")
        surface.didBecomeHidden()
        surface.didBecomeHidden()
        XCTAssertFalse(surface.isVisibleForTesting,
                       "calling didBecomeHidden twice must not crash or toggle back to visible")
    }

    // MARK: - legacy-Google reload cap (T043)

    // WHY: googleLegacyLayoutReloadCap = 32. Without the cap, the reload-dedup
    // set grows without limit for every distinct Google URL visited, leaking
    // memory proportional to the number of pages browsed. The cap means only
    // the 32 most-recently-seen keys are retained (PERF-005).
    func test_googleLegacyLayoutReloadCap_is32() {
        XCTAssertEqual(BrowserSurface.googleLegacyLayoutReloadCap, 32,
                       "reload cap must be 32 to bound the dedup-set memory footprint (PERF-005)")
    }

    // MARK: - isGoogleHost boundary cases

    // WHY: the google-host test guards the legacy-layout reload logic.
    // A wrong boundary (e.g. matching "evilgoogle.com") would trigger
    // an unnecessary cookie-clear + reload on unrelated sites.
    func test_isGoogleHost_subdomain_returnsTrue() {
        XCTAssertTrue(BrowserSurface.isGoogleHost("maps.google.com"))
        XCTAssertTrue(BrowserSurface.isGoogleHost("mail.google.com"))
    }

    func test_isGoogleHost_rootDomain_returnsTrue() {
        XCTAssertTrue(BrowserSurface.isGoogleHost("google.com"))
    }

    func test_isGoogleHost_prefixMatch_returnsFalse() {
        XCTAssertFalse(BrowserSurface.isGoogleHost("notgoogle.com"),
                       "a host that merely starts with 'google' must not match")
    }

    func test_isGoogleHost_suffixAfterTLD_returnsFalse() {
        XCTAssertFalse(BrowserSurface.isGoogleHost("google.com.evil.io"),
                       "a host with google.com as a subdomain must not match")
    }

    func test_isGoogleHost_nil_returnsFalse() {
        XCTAssertFalse(BrowserSurface.isGoogleHost(nil))
    }
}
