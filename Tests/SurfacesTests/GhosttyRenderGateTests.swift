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
        windowPresent: Bool = true,
        windowIsKey: Bool = false,
        windowOnActiveSpace: Bool = true
    ) -> Bool {
        GhosttyTerminalView.canRender(
            visibleInUI: true,
            isHidden: false,
            hasNonEmptyBounds: true,
            windowPresent: windowPresent,
            windowVisible: windowVisible,
            windowMiniaturized: windowMiniaturized,
            windowOnScreen: windowOnScreen,
            windowIsKey: windowIsKey,
            windowOnActiveSpace: windowOnActiveSpace
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
                windowMiniaturized: false, windowOnScreen: false, windowIsKey: false, windowOnActiveSpace: true),
            "a selected terminal whose view is mid-move (windowless) must not render — keying on visibleInUI alone freezes on nextDrawable")
    }

    func test_selectedTerminalInNotYetOnScreenNewWindowIsNotRenderable() {
        // Reattached to a new window that has not been ordered front yet: window
        // present but not visible / not on screen. Still must not render.
        XCTAssertFalse(
            GhosttyTerminalView.canRender(
                visibleInUI: true, isHidden: false, hasNonEmptyBounds: true,
                windowPresent: true, windowVisible: false,
                windowMiniaturized: false, windowOnScreen: false, windowIsKey: false, windowOnActiveSpace: true),
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
            windowMiniaturized: false, windowOnScreen: false, windowIsKey: false, windowOnActiveSpace: true)
        XCTAssertTrue(visibleInUI, "precondition: the moved tab is still logically selected")
        XCTAssertNotEqual(renderable, visibleInUI,
            "render decision must NOT equal visibleInUI in the windowless mid-move state — that equality was the freeze bug")
    }

    func test_doesNotRenderWhenUnselectedOrHiddenEvenIfWindowOnScreen() {
        XCTAssertFalse(
            GhosttyTerminalView.canRender(
                visibleInUI: false, isHidden: false, hasNonEmptyBounds: true,
                windowPresent: true, windowVisible: true, windowMiniaturized: false, windowOnScreen: true, windowIsKey: false, windowOnActiveSpace: true),
            "an unselected tab must not render even if its window is on screen")
        XCTAssertFalse(
            GhosttyTerminalView.canRender(
                visibleInUI: true, isHidden: true, hasNonEmptyBounds: true,
                windowPresent: true, windowVisible: true, windowMiniaturized: false, windowOnScreen: true, windowIsKey: false, windowOnActiveSpace: true),
            "a hidden view must not render")
        XCTAssertFalse(
            GhosttyTerminalView.canRender(
                visibleInUI: true, isHidden: false, hasNonEmptyBounds: false,
                windowPresent: true, windowVisible: true, windowMiniaturized: false, windowOnScreen: true, windowIsKey: false, windowOnActiveSpace: true),
            "a zero-sized view has no drawable and must not render")
    }

    // MARK: - occlusionState false-negative heal (audit #1)
    //
    // `occlusionState.contains(.visible)` has documented AppKit false-negatives:
    // after a Space switch / display sleep-wake it can report not-visible while the
    // window is genuinely front and on screen, with no follow-up notification — and
    // because syncOcclusion pushes that into a CACHED ghostty occlusion latch and
    // neither keyDown nor scrollWheel re-derived it, the renderer stayed suspended
    // forever (frozen frame, dead scroll, dead echo). A KEY window is, by definition,
    // the focused front window of the active app, so it has a live on-screen
    // drawable: the gate now treats key as on-screen.

    func test_keyWindowRendersEvenWhenOcclusionStateFalseNegatives() {
        XCTAssertTrue(
            onScreenSelected(windowOnScreen: false, windowIsKey: true, windowOnActiveSpace: true),
            "a KEY window must render even when occlusionState falsely reports not-visible — that latch was the freeze (audit #1)")
    }

    func test_keyWindowFlagDoesNotOverrideGpuSafetyGuards() {
        // The heal must NOT defeat the AGX-trap guards: a minimized or ordered-out
        // window has no valid drawable even if AppKit somehow reported it as key.
        XCTAssertFalse(
            onScreenSelected(windowVisible: true, windowMiniaturized: true, windowOnScreen: false, windowIsKey: true, windowOnActiveSpace: true),
            "a minimized window has no drawable — isKey must not force a render into it")
        XCTAssertFalse(
            onScreenSelected(windowVisible: false, windowOnScreen: false, windowIsKey: true, windowOnActiveSpace: true),
            "an ordered-out (invisible) window has no drawable — isKey must not force a render into it")
    }

    // MARK: - Key-window override needs the active Space (S-F2)
    //
    // A window can stay key while the user is looking at another Space (a Space
    // switch with no other app taking focus). Its occlusionState correctly says
    // not-visible, so the only thing that could re-enable rendering is the key
    // override, and the window has no on-screen drawable there. Rendering into it
    // is the AGX off-screen trap that Ghostty's crash reporter turns into a
    // silent exit, so the override must also require the active Space.

    func test_keyWindowOnAnInactiveSpaceDoesNotRender() {
        XCTAssertFalse(
            onScreenSelected(windowOnScreen: false, windowIsKey: true, windowOnActiveSpace: false),
            "a key window whose Space is not shown has no drawable; the key override must not render into it (S-F2)")
    }

    func test_inactiveSpaceDoesNotBlockAnOcclusionVisibleWindow() {
        // The Space check narrows only the key override. AppKit's own on-screen
        // signal still wins, so a correctly visible window keeps rendering.
        XCTAssertTrue(
            onScreenSelected(windowOnScreen: true, windowIsKey: false, windowOnActiveSpace: false),
            "occlusionState visible is authoritative; the Space check applies only to the key override")
    }

    func test_keyWindowDoesNotRescueAnUnselectedOrHiddenTab() {
        XCTAssertFalse(
            GhosttyTerminalView.canRender(
                visibleInUI: false, isHidden: false, hasNonEmptyBounds: true,
                windowPresent: true, windowVisible: true, windowMiniaturized: false,
                windowOnScreen: true, windowIsKey: true, windowOnActiveSpace: true),
            "an unselected tab must still not render even in a key window")
    }

    // MARK: - surfaceClosed resurrection (audit #4)
    //
    // `surfaceClosed` latches permanently after closeSurface(); ensureSurface then
    // returns forever, so a still-visible tab whose surface was closed on the wrong
    // instance (clone / cross-client yank / double-close) is frozen for input AND
    // scroll until app relaunch. Resurrection must fire ONLY when the view is still
    // mounted on a window with bounds AND the owner is not legitimately closing.

    func test_resurrects_whenClosedButViewStillVisibleAndOwnerNotClosing() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldResurrectClosedSurface(
                surfaceClosed: true, hasWindow: true, hasNonEmptyBounds: true, ownerClosing: false),
            "a surface closed on a still-mounted view whose owner is alive must be rebuilt, not left frozen")
    }

    func test_doesNotResurrect_duringLegitimateTeardown() {
        XCTAssertFalse(
            GhosttyTerminalView.shouldResurrectClosedSurface(
                surfaceClosed: true, hasWindow: true, hasNonEmptyBounds: true, ownerClosing: true),
            "a legitimate close (owner is tearing down) must stay closed")
    }

    func test_doesNotResurrect_whenViewIsUnmountedOrZeroSized() {
        XCTAssertFalse(
            GhosttyTerminalView.shouldResurrectClosedSurface(
                surfaceClosed: true, hasWindow: false, hasNonEmptyBounds: true, ownerClosing: false),
            "a windowless (unmounted) view must not resurrect")
        XCTAssertFalse(
            GhosttyTerminalView.shouldResurrectClosedSurface(
                surfaceClosed: true, hasWindow: true, hasNonEmptyBounds: false, ownerClosing: false),
            "a zero-sized view has no drawable to rebuild into")
    }

    func test_doesNotResurrect_whenNotClosed() {
        XCTAssertFalse(
            GhosttyTerminalView.shouldResurrectClosedSurface(
                surfaceClosed: false, hasWindow: true, hasNonEmptyBounds: true, ownerClosing: false),
            "an open surface is not a resurrection candidate")
    }
}
