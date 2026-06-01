import XCTest
import AppKit
@testable import Surfaces

/// Regression for the silent-vanish crash: terminal output rendered into a
/// CAMetalLayer whose window was off screen (minimized/occluded) dereferenced a
/// freed GPU texture and trapped (EXC_BREAKPOINT in AGX
/// `renderCommandEncoderWithDescriptor:`), which Ghostty's embedded crash
/// reporter turned into a silent `_exit`. The render gate must refuse to draw
/// whenever the window is not actually on screen — `window != nil` is NOT
/// sufficient because a minimized window keeps a non-nil window.
final class GhosttyRenderGateTests: XCTestCase {
    private func onScreenSelected(
        windowVisible: Bool = true,
        windowMiniaturized: Bool = false,
        windowOnScreen: Bool = true,
        windowPresent: Bool = true
    ) -> Bool {
        GhosttyTerminalView.canRender(
            visibleInUI: true,
            isHidden: false,
            hasNonEmptyBounds: true,
            windowPresent: windowPresent,
            windowVisible: windowVisible,
            windowMiniaturized: windowMiniaturized,
            windowOnScreen: windowOnScreen
        )
    }

    func test_rendersWhenWindowIsFullyOnScreen() {
        XCTAssertTrue(onScreenSelected(),
            "a selected, sized terminal in an on-screen window must render")
    }

    func test_doesNotRenderWhenWindowMinimized() {
        XCTAssertFalse(
            onScreenSelected(windowVisible: true, windowMiniaturized: true, windowOnScreen: false),
            "a minimized window has no valid Metal drawable — rendering into it traps the GPU driver and silently kills the app"
        )
    }

    func test_doesNotRenderWhenWindowOccludedOrOffScreen() {
        XCTAssertFalse(
            onScreenSelected(windowOnScreen: false),
            "when the window's content is not on screen (occluded/ordered out) the drawable is invalid and must not be rendered"
        )
    }

    func test_doesNotRenderWhenWindowOrderedOut() {
        XCTAssertFalse(
            onScreenSelected(windowVisible: false, windowOnScreen: false),
            "an ordered-out (invisible) window must not be rendered into"
        )
    }

    func test_doesNotRenderWithoutAWindow() {
        XCTAssertFalse(
            onScreenSelected(windowVisible: false, windowOnScreen: false, windowPresent: false),
            "a view with no window has no drawable to render into"
        )
    }

    func test_doesNotRenderWhenUnselectedOrHiddenEvenIfWindowOnScreen() {
        XCTAssertFalse(
            GhosttyTerminalView.canRender(
                visibleInUI: false, isHidden: false, hasNonEmptyBounds: true,
                windowPresent: true, windowVisible: true, windowMiniaturized: false, windowOnScreen: true),
            "an unselected tab must not render even if its window is on screen")
        XCTAssertFalse(
            GhosttyTerminalView.canRender(
                visibleInUI: true, isHidden: true, hasNonEmptyBounds: true,
                windowPresent: true, windowVisible: true, windowMiniaturized: false, windowOnScreen: true),
            "a hidden view must not render")
        XCTAssertFalse(
            GhosttyTerminalView.canRender(
                visibleInUI: true, isHidden: false, hasNonEmptyBounds: false,
                windowPresent: true, windowVisible: true, windowMiniaturized: false, windowOnScreen: true),
            "a zero-sized view has no drawable and must not render")
    }
}
