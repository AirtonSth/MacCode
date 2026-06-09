import XCTest
@testable import Surfaces

/// Tests that the Web Inspector toggle is wired correctly.
///
/// WHY: Dev-server-preview use case requires Safari Web Inspector to attach to
/// the embedded WKWebView. `isInspectable = true` must be set in debug builds
/// on macOS 13.3+ and must NOT be set in release builds. The `isInspectableEnabled()`
/// helper encodes exactly this contract so that regressions (e.g. accidentally
/// enabling in release, or removing the availability guard) cause test failures.
final class BrowserSurfaceInspectableTests: XCTestCase {

    /// In a DEBUG build (which is what the test runner compiles under),
    /// `isInspectableEnabled()` must return `true` when the OS is 13.3+.
    /// If it ever returns `false` in this context the dev-server-preview
    /// feature is silently broken.
    @MainActor
    func testIsInspectableEnabledInDebugBuild() {
        if #available(macOS 13.3, *) {
            XCTAssertTrue(
                BrowserSurface.isInspectableEnabled(),
                "isInspectable must be enabled in DEBUG builds on macOS 13.3+ " +
                "so Safari Web Inspector can attach to the embedded webView"
            )
        } else {
            // Pre-13.3: feature cannot be enabled — not a failure.
            XCTAssertFalse(BrowserSurface.isInspectableEnabled())
        }
    }
}
