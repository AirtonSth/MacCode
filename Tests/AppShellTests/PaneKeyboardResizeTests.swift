import XCTest
import CoreModel
@testable import AppShell

// Tests for P3 keyboard pane resize:
// pure helper paneResizeRatios(direction:ratios:paneIndex:step:min:)
// and the performKeyboardPaneResize seam on PaneTabsView.
//
// The pure helper carries no AppKit/MainActor dependency; the seam tests
// use PaneTabsView but only call the pure static, so no @MainActor is needed.

final class PaneKeyboardResizeTests: XCTestCase {

    // MARK: - Basic adjustment: step applied correctly

    // WHY: pressing Ctrl+Opt+Right on pane 0 of a two-pane horizontal split must
    // grow pane 0 by step and shrink pane 1 by step -- matching tmux/iTerm UX.
    func test_right_growsTargetPane_shrinksSibling() {
        let result = PaneTabsView.paneResizeRatios(
            direction: .right,
            ratios: [0.5, 0.5],
            paneIndex: 0,
            step: 0.1,
            min: 0.05
        )
        XCTAssertEqual(result[0], 0.6, accuracy: 1e-9,
                       "Ctrl+Opt+Right on pane 0 must increase its ratio by step")
        XCTAssertEqual(result[1], 0.4, accuracy: 1e-9,
                       "the sibling pane must shrink by the same step to keep sum=1")
    }

    // WHY: pressing Ctrl+Opt+Left on pane 0 must shrink it (move split leftward),
    // matching tmux 'resize-pane -L'.
    func test_left_shrinksTargetPane_growsSibling() {
        let result = PaneTabsView.paneResizeRatios(
            direction: .left,
            ratios: [0.5, 0.5],
            paneIndex: 0,
            step: 0.1,
            min: 0.05
        )
        XCTAssertEqual(result[0], 0.4, accuracy: 1e-9,
                       "Ctrl+Opt+Left on pane 0 must decrease its ratio by step")
        XCTAssertEqual(result[1], 0.6, accuracy: 1e-9)
    }

    // WHY: pressing Ctrl+Opt+Down on pane 0 of a two-pane vertical split grows it.
    func test_down_growsTargetPane_in_verticalSplit() {
        let result = PaneTabsView.paneResizeRatios(
            direction: .down,
            ratios: [0.5, 0.5],
            paneIndex: 0,
            step: 0.1,
            min: 0.05
        )
        XCTAssertEqual(result[0], 0.6, accuracy: 1e-9,
                       "Ctrl+Opt+Down on pane 0 in a vertical split must increase its ratio")
        XCTAssertEqual(result[1], 0.4, accuracy: 1e-9)
    }

    // WHY: pressing Ctrl+Opt+Up on pane 0 of a vertical split shrinks it.
    func test_up_shrinksTargetPane_in_verticalSplit() {
        let result = PaneTabsView.paneResizeRatios(
            direction: .up,
            ratios: [0.5, 0.5],
            paneIndex: 0,
            step: 0.1,
            min: 0.05
        )
        XCTAssertEqual(result[0], 0.4, accuracy: 1e-9,
                       "Ctrl+Opt+Up on pane 0 in a vertical split must decrease its ratio")
        XCTAssertEqual(result[1], 0.6, accuracy: 1e-9)
    }

    // MARK: - Three-pane: redistribute delta among all other panes evenly

    // WHY: in a three-pane split, growing pane 1 must shrink the OTHER two panes equally.
    func test_right_threePanes_redistributesDeltaEvenly() {
        let result = PaneTabsView.paneResizeRatios(
            direction: .right,
            ratios: [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0],
            paneIndex: 1,
            step: 0.06,
            min: 0.05
        )
        XCTAssertEqual(result[1], 1.0 / 3.0 + 0.06, accuracy: 1e-9,
                       "target pane must grow by step")
        XCTAssertEqual(result[0], result[2], accuracy: 1e-9,
                       "remaining panes must shrink symmetrically when they start equal")
        XCTAssertEqual(result.reduce(0, +), 1.0, accuracy: 1e-9,
                       "ratios must sum to 1 after resize")
    }

    // MARK: - Sum invariant

    // WHY: any resize combination must leave sum=1 so the split view never drifts.
    func test_sumAlwaysEqualsOne_afterLeftResize() {
        let result = PaneTabsView.paneResizeRatios(
            direction: .left,
            ratios: [0.3, 0.7],
            paneIndex: 1,
            step: 0.05,
            min: 0.05
        )
        XCTAssertEqual(result.reduce(0, +), 1.0, accuracy: 1e-9,
                       "sum must equal 1 after any resize so split ratios stay consistent")
    }

    func test_sumAlwaysEqualsOne_afterRightResize() {
        let result = PaneTabsView.paneResizeRatios(
            direction: .right,
            ratios: [0.2, 0.4, 0.4],
            paneIndex: 2,
            step: 0.08,
            min: 0.05
        )
        XCTAssertEqual(result.reduce(0, +), 1.0, accuracy: 1e-9)
    }

    // MARK: - Clamp: target pane never below min or above (1 - min)

    // WHY: without clamping, a pane could shrink to zero or become the full split;
    // min=0.05 keeps every pane visible and keyboard-accessible.
    func test_left_atMinBound_isNoop() {
        // pane 0 is already at min=0.05; pressing left must not push below min.
        let initial = [0.05, 0.95]
        let result = PaneTabsView.paneResizeRatios(
            direction: .left,
            ratios: initial,
            paneIndex: 0,
            step: 0.1,
            min: 0.05
        )
        XCTAssertEqual(result[0], 0.05, accuracy: 1e-9,
                       "pane at min boundary must not shrink further on left-resize (no-op)")
        XCTAssertEqual(result[1], 0.95, accuracy: 1e-9)
    }

    func test_right_atMaxBound_isNoop() {
        // pane 0 ratio would exceed 1-min if grown; must clamp to 1-min.
        // With min=0.05, max = 0.95. Start at [0.90, 0.10]; step=0.10 would push to 1.0.
        let result = PaneTabsView.paneResizeRatios(
            direction: .right,
            ratios: [0.92, 0.08],
            paneIndex: 0,
            step: 0.1,
            min: 0.05
        )
        XCTAssertLessThanOrEqual(result[0], 0.95 + 1e-9,
                                 "pane ratio must not exceed (1 - min) when grown past the ceiling")
        XCTAssertGreaterThanOrEqual(result[1], 0.05 - 1e-9,
                                    "sibling ratio must not fall below min when the target pane is clamped")
    }

    func test_clamp_alreadyAtMinForDown() {
        let result = PaneTabsView.paneResizeRatios(
            direction: .up,
            ratios: [0.05, 0.95],
            paneIndex: 0,
            step: 0.1,
            min: 0.05
        )
        XCTAssertEqual(result[0], 0.05, accuracy: 1e-9,
                       "no-op at lower bound for up-direction resize")
    }

    // MARK: - Out-of-bounds paneIndex: identity

    // WHY: an invalid paneIndex must return ratios unchanged to avoid index crashes.
    func test_outOfBounds_paneIndex_returnsIdentity() {
        let ratios = [0.5, 0.5]
        let result = PaneTabsView.paneResizeRatios(
            direction: .right,
            ratios: ratios,
            paneIndex: 5,
            step: 0.1,
            min: 0.05
        )
        XCTAssertEqual(result, ratios,
                       "out-of-bounds paneIndex must return ratios unchanged to avoid crashes")
    }

    // MARK: - Single pane: identity

    // WHY: a single-child split is degenerate; any resize is a no-op.
    func test_singlePane_isNoop() {
        let result = PaneTabsView.paneResizeRatios(
            direction: .right,
            ratios: [1.0],
            paneIndex: 0,
            step: 0.1,
            min: 0.05
        )
        XCTAssertEqual(result, [1.0],
                       "single-pane splits cannot be resized -- must return identity")
    }

    // MARK: - Non-default step

    // WHY: step must be configurable (coarse/fine) so the caller can use a
    // different step without the helper assuming a hardcoded value.
    func test_customStep_appliedExactly() {
        let result = PaneTabsView.paneResizeRatios(
            direction: .right,
            ratios: [0.5, 0.5],
            paneIndex: 0,
            step: 0.04,
            min: 0.05
        )
        XCTAssertEqual(result[0], 0.54, accuracy: 1e-9,
                       "helper must use the provided step, not a hardcoded default")
    }

    // MARK: - performKeyboardPaneResize: routes to paneResize reducer

    // WHY: the seam must thread the computed ratios through the router so the
    // RatioSplitView re-renders and iOS/macOS state stays in sync.
    @MainActor
    func test_performKeyboardPaneResize_right_updatesLayoutState() throws {
        let tmp = NSTemporaryDirectory() + "PaneKBResize-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: ctx, sshPasswordStore: KeychainSSHPasswordStore())
        ctx.router = router

        let ws = try router.createWorkspace(name: "kb-resize", cwd: NSTemporaryDirectory())
        guard case .pane(let pane0) = ws.layout else { return XCTFail("expected single pane") }
        let view = PaneTabsView(pane: pane0, router: router)
        _ = view.performSplit(.right, type: .browser, title: "Browser")
        guard case .split(let split) = ctx.state.workspaces[ws.id]!.layout else {
            return XCTFail("expected split after performSplit")
        }
        XCTAssertEqual(split.ratios[0], 0.5, accuracy: 1e-4)

        let leftPane = try XCTUnwrap(split.children.first?.find(paneID: pane0.id))
        let resizeView = PaneTabsView(
            pane: leftPane,
            router: router,
            splitContext: PaneSplitContext(
                splitID: split.id,
                paneIndex: 0,
                ratios: split.ratios,
                orientation: .horizontal
            )
        )

        XCTAssertTrue(
            resizeView.performKeyboardPaneResize(direction: .right),
            "performKeyboardPaneResize must return true when it successfully resizes the split"
        )

        guard case .split(let updated) = ctx.state.workspaces[ws.id]!.layout else {
            return XCTFail("layout must remain a split after keyboard resize")
        }
        XCTAssertGreaterThan(updated.ratios[0], 0.5,
                             "Ctrl+Opt+Right must increase the focused pane's share of the split")
        XCTAssertLessThan(updated.ratios[1], 0.5,
                          "the sibling pane must shrink when the focused pane grows")
        XCTAssertEqual(updated.ratios.reduce(0, +), 1.0, accuracy: 1e-9,
                       "ratios must sum to 1 after keyboard resize")
    }

    // WHY: when there is no splitContext, the resize must be a no-op (return false)
    // rather than crashing -- a pane without a parent split has nothing to resize.
    @MainActor
    func test_performKeyboardPaneResize_noSplitContext_returnsFalse() throws {
        let tmp = NSTemporaryDirectory() + "PaneKBResizeNoop-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: ctx, sshPasswordStore: KeychainSSHPasswordStore())
        ctx.router = router
        let ws = try router.createWorkspace(name: "kb-noop", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail() }

        let view = PaneTabsView(pane: pane, router: router)
        XCTAssertFalse(
            view.performKeyboardPaneResize(direction: .right),
            "a pane without a splitContext cannot resize -- must return false, not crash"
        )
    }
}
