import XCTest
import CoreModel
@testable import Surfaces

// BrowserSurface is @MainActor; its static helpers inherit that isolation.
// Under the Swift 6 compiler these calls must come from a MainActor context,
// so the test case itself is MainActor-isolated. (Pre-existing build blocker
// for the whole SwiftPM test bundle — unrelated to git-tab work.)
@MainActor
final class BrowserSurfaceTests: XCTestCase {
    func test_defaultInitialURL_isRemoteCodeFromApp() {
        XCTAssertEqual(BrowserSurface.defaultInitialURL.absoluteString,
                       "https://www.remotecode.io/from-app")
    }

    func test_normalizedInitialURL_mapsAboutBlankToRemoteCodeFromApp() throws {
        let aboutBlank = try XCTUnwrap(URL(string: "about:blank"))

        XCTAssertEqual(BrowserSurface.normalizedInitialURL(aboutBlank).absoluteString,
                       "https://www.remotecode.io/from-app")
    }

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

    func test_hostNavigationChangeCallbackCarriesExactURLAndTitle() throws {
        let surface = BrowserSurface(workspaceID: WorkspaceID(), initialURL: nil, title: "browser")
        var observed: (SurfaceID, String, String?)?
        surface.onNavigationChange = { id, url, title in
            observed = (id, url, title)
        }

        let url = try XCTUnwrap(URL(string: "file:///Users/dev/project/index.html"))
        surface.publishNavigationChange(url: url, title: "Local file")

        XCTAssertEqual(observed?.0, surface.descriptor.id)
        XCTAssertEqual(observed?.1, "file:///Users/dev/project/index.html",
                       "manual host browser navigation must emit the exact URL so iOS can mirror it")
        XCTAssertEqual(observed?.2, "Local file")
        XCTAssertEqual(surface.descriptor.title, "Local file")
    }

    func test_toolbarExposesOpenInDefaultBrowserButton() {        let surface = BrowserSurface(workspaceID: WorkspaceID(), initialURL: nil, title: "browser")

        XCTAssertTrue(Self.containsButtonTooltip("Open in Default Browser", in: surface.view),
                      "browser toolbar needs a direct affordance for opening the current URL in the Mac default browser")
    }

    func test_openInDefaultBrowserUsesCurrentRetainedURL() throws {
        let surface = BrowserSurface(workspaceID: WorkspaceID(), initialURL: nil, title: "browser")
        let url = try XCTUnwrap(URL(string: "https://example.com/docs"))
        var opened: URL?
        surface.externalURLOpener = { opened = $0 }

        surface.navigate(to: url)
        surface.openInDefaultBrowserAction()

        XCTAssertEqual(opened, url,
                       "opening externally must send the browser tab's current URL to macOS default URL handling")
    }

    func test_navigationStateObserverScriptHooksSPARouteChanges() {
        let script = BrowserSurface.navigationStateObserverScript

        XCTAssertTrue(script.contains("history.pushState"),
                      "SPA link clicks commonly update the URL with pushState, so the browser toolbar must observe that path")
        XCTAssertTrue(script.contains("history.replaceState"),
                      "replaceState must also notify so redirects inside the same document update the toolbar URL")
        XCTAssertTrue(script.contains("popstate"),
                      "Back/Forward inside an SPA must resync the address bar after the history entry changes")
        XCTAssertTrue(script.contains(BrowserSurface.navigationStateMessageHandlerName),
                      "the injected script must post route changes back to BrowserSurface")
    }

    func test_navigationChromeSyncUsesClickedPageURLAndHistoryState() throws {
        let surface = BrowserSurface(workspaceID: WorkspaceID(), initialURL: nil, title: "browser")
        let accountURL = try XCTUnwrap(URL(string: "https://remotecode.io/account"))
        var observed: (String, String?)?
        surface.onNavigationChange = { _, url, title in
            observed = (url, title)
        }

        surface.syncNavigationChromeForTesting(
            url: accountURL,
            title: "My account",
            canGoBack: true,
            canGoForward: false
        )

        XCTAssertEqual(surface.addressBarStringForTesting, "https://remotecode.io/account",
                       "after an in-page link changes WebKit's URL, the toolbar must show the clicked page URL instead of the original page")
        XCTAssertTrue(surface.backButtonIsEnabledForTesting,
                      "after a clicked link creates browser history, Back must become enabled")
        XCTAssertFalse(surface.forwardButtonIsEnabledForTesting,
                       "Forward must stay disabled until the user actually goes back")
        XCTAssertEqual(observed?.0, "https://remotecode.io/account",
                       "the iOS mirror must receive the same URL that the toolbar shows")
        XCTAssertEqual(observed?.1, "My account")
        XCTAssertEqual(surface.descriptor.metadata["url"], "https://remotecode.io/account")
    }

    // SEP-3: url/title KVO, didFinish, and the SPA script payload all fire
    // for one navigation. Repeats with identical url+title must not re-fan-out
    // (snapshot-save schedule + BotBrowserStore write + EventBus publish),
    // while any change must still reach the iOS mirror.
    func test_repeatNavigationPublish_dedupesIdenticalValues() throws {
        let surface = BrowserSurface(workspaceID: WorkspaceID(), initialURL: nil, title: "browser")
        var fireCount = 0
        surface.onNavigationChange = { _, _, _ in fireCount += 1 }
        let url = try XCTUnwrap(URL(string: "https://example.com/docs"))

        surface.publishNavigationChange(url: url, title: "Docs")
        surface.publishNavigationChange(url: url, title: "Docs")
        surface.publishNavigationChange(url: url, title: "Docs")
        XCTAssertEqual(fireCount, 1,
            "identical repeats must fan out once so snapshot saves and mirror publishes stay latest-wins")

        surface.publishNavigationChange(url: url, title: "Docs v2")
        XCTAssertEqual(fireCount, 2,
            "a changed title must still emit host state for the iOS mirror")

        let other = try XCTUnwrap(URL(string: "https://example.com/other"))
        surface.publishNavigationChange(url: other, title: "Docs v2")
        XCTAssertEqual(fireCount, 3,
            "a changed URL must still emit host state for the iOS mirror")
    }

    private static func containsButtonTooltip(_ tooltip: String, in view: NSView) -> Bool {
        if let button = view as? NSButton, button.toolTip == tooltip {
            return true
        }
        return view.subviews.contains { containsButtonTooltip(tooltip, in: $0) }
    }
}
