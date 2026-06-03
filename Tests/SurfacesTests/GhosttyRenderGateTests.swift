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

    // MARK: - Split / move freeze regression
    //
    // Moving a terminal to a split pane or a new window reparents its NSView: the
    // workspace rebuild removes the view subtree from its window before re-adding
    // it, so the view is *transiently windowless* while the tab is still the
    // selected one (visibleInUI stays true). The pre-fix code gated the
    // post-resize/create refresh AND Ghostty's occlusion on `visibleInUI` alone,
    // so it kept driving the renderer into a windowless / not-yet-on-screen
    // CAMetalLayer → `nextDrawable` starvation → the terminal "stops updating" and
    // the held GPU drawable can stall the WindowServer (whole-system freeze). The
    // render/occlusion decision must use the full on-screen gate (`canRender`), of
    // which `visibleInUI` is only one input — never `visibleInUI` by itself.

    func test_selectedTerminalMidMoveBetweenWindowsIsNotRenderable() {
        // visibleInUI == true (tab still selected) but the view lost its window
        // during the reparent. canRender must say NO so the renderer stays
        // suspended and no refresh is emitted into a windowless drawable.
        XCTAssertFalse(
            GhosttyTerminalView.canRender(
                visibleInUI: true, isHidden: false, hasNonEmptyBounds: true,
                windowPresent: false, windowVisible: false,
                windowMiniaturized: false, windowOnScreen: false),
            "a selected terminal whose view is mid-move (windowless) must not render — keying on visibleInUI alone freezes on nextDrawable")
    }

    func test_selectedTerminalInNotYetOnScreenNewWindowIsNotRenderable() {
        // Reattached to a new window that has not been ordered front yet: window
        // present but not visible / not on screen. Still must not render.
        XCTAssertFalse(
            GhosttyTerminalView.canRender(
                visibleInUI: true, isHidden: false, hasNonEmptyBounds: true,
                windowPresent: true, windowVisible: false,
                windowMiniaturized: false, windowOnScreen: false),
            "a selected terminal in a new window that is not yet on screen must not render")
    }

    func test_renderGateIsNotMereTabVisibility() {
        // The defect was keying the renderer on tab-selection (visibleInUI). Prove
        // the gate diverges from visibleInUI exactly in the freeze states: tab is
        // selected, yet the surface must NOT render.
        let visibleInUI = true
        let renderable = GhosttyTerminalView.canRender(
            visibleInUI: visibleInUI, isHidden: false, hasNonEmptyBounds: true,
            windowPresent: false, windowVisible: false,
            windowMiniaturized: false, windowOnScreen: false)
        XCTAssertTrue(visibleInUI, "precondition: the moved tab is still logically selected")
        XCTAssertNotEqual(renderable, visibleInUI,
            "render decision must NOT equal visibleInUI in the windowless mid-move state — that equality was the freeze bug")
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
