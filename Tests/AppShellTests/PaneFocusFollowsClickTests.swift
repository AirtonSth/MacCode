import XCTest
import CoreModel
@testable import AppShell

/// Focus-follows-click: clicking a pane's content area must route a
/// focusPane command so Cmd+W / Cmd+D act on the correct pane.
///
/// All tests exercise the pure `PaneTabsView.focusPaneCommand` seam — no
/// AppKit window, no MainActor required. The seam is the smallest unit
/// that can be wrong: if it returns nil when it should return a target
/// (or vice-versa), Cmd+W will close the wrong pane's tab.
@MainActor
final class PaneFocusFollowsClickTests: XCTestCase {

    // MARK: - focusPaneCommand pure resolver

    /// Clicking into an unfocused pane must yield a focus command.
    /// If it returns nil, the click is silently ignored and focus stays
    /// on the wrong pane, breaking every keyboard shortcut that uses
    /// focusedPaneID.
    func test_focusPaneCommand_returnsTarget_whenPaneIsNotFocused() {
        let workspace = WorkspaceID()
        let clickedPane = PaneID()
        let otherPane = PaneID()

        let result = PaneTabsView.focusPaneCommand(
            currentFocusedPaneID: otherPane,
            paneID: clickedPane,
            workspaceID: workspace
        )

        XCTAssertNotNil(result,
            "clicking an unfocused pane must produce a focus command; nil means " +
            "the click is dropped and keyboard shortcuts keep targeting the wrong pane")
        XCTAssertEqual(result?.pane, clickedPane,
            "the focus command must name the clicked pane, not the previously focused one")
        XCTAssertEqual(result?.workspace, workspace,
            "the focus command must carry the correct workspace so the reducer updates the right workspace state")
    }

    /// Clicking the pane that is already focused must return nil so the
    /// router skips a redundant state write. A non-nil return here would
    /// trigger unnecessary reconcile / refreshFromState cycles on every
    /// click inside the active pane.
    func test_focusPaneCommand_returnsNil_whenPaneAlreadyFocused() {
        let workspace = WorkspaceID()
        let pane = PaneID()

        let result = PaneTabsView.focusPaneCommand(
            currentFocusedPaneID: pane,
            paneID: pane,
            workspaceID: workspace
        )

        XCTAssertNil(result,
            "clicking the already-focused pane must be a no-op; a non-nil result " +
            "would cause redundant state mutations on every click inside the active pane")
    }

    /// When no pane is focused yet (nil currentFocusedPaneID), a click
    /// into any pane must produce a focus command. This covers the fresh
    /// workspace case before any pane has been explicitly focused.
    func test_focusPaneCommand_returnsTarget_whenNoCurrentFocus() {
        let workspace = WorkspaceID()
        let clickedPane = PaneID()

        let result = PaneTabsView.focusPaneCommand(
            currentFocusedPaneID: nil,
            paneID: clickedPane,
            workspaceID: workspace
        )

        XCTAssertNotNil(result,
            "with no prior focused pane, the first click must establish focus so " +
            "Cmd+W targets the correct pane immediately")
        XCTAssertEqual(result?.pane, clickedPane)
        XCTAssertEqual(result?.workspace, workspace)
    }

    /// The focused-pane check compares IDs by value, not by reference.
    /// Two distinct PaneID values that are equal must be treated as the
    /// same pane so round-tripping through serialization stays idempotent.
    func test_focusPaneCommand_idempotent_acrossDistinctObjectsWithSameID() {
        let rawUUID = UUID()
        let workspace = WorkspaceID()
        let focused = PaneID(rawUUID)
        let clicked = PaneID(rawUUID)  // same underlying UUID, different object

        let result = PaneTabsView.focusPaneCommand(
            currentFocusedPaneID: focused,
            paneID: clicked,
            workspaceID: workspace
        )

        XCTAssertNil(result,
            "equal PaneIDs with different Swift object identity must still be treated " +
            "as already-focused so deserialized state does not trigger spurious focus mutations")
    }

    // MARK: - focusPane router method

    /// focusPane is a no-op when the pane is already focused.
    /// A redundant state mutation here would trigger unnecessary UI rebuilds.
    func test_focusPane_isNoOp_whenPaneAlreadyFocused() throws {
        let tmp = NSTemporaryDirectory() + "RC2FocusPaneTest-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router

        let ws = try router.createWorkspace(name: "focus-noop", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail("expected single pane") }

        // The workspace already points focusedPaneID at the only pane.
        let before = ctx.state.workspaces[ws.id]?.focusedPaneID

        XCTAssertNoThrow(
            try router.focusPane(workspace: ws.id, pane: pane.id),
            "focusPane on the already-focused pane must not throw"
        )

        let after = ctx.state.workspaces[ws.id]?.focusedPaneID
        XCTAssertEqual(before, after,
            "no-op focusPane must not change focusedPaneID, avoiding unnecessary reconcile cycles")
    }

    /// focusPane updates focusedPaneID when targeting an unfocused pane.
    /// This is the live path that makes Cmd+W close the right pane's tab.
    func test_focusPane_updatesFocusedPaneID_whenPaneChanges() throws {
        let tmp = NSTemporaryDirectory() + "RC2FocusPaneSwitch-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router

        let ws = try router.createWorkspace(name: "focus-switch", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail("expected single pane") }

        // Split to get a second pane.
        let ptv = PaneTabsView(pane: pane, router: router)
        XCTAssertNotNil(ptv.performSplit(.right, type: .browser, title: "browser"))

        let updated = try XCTUnwrap(ctx.state.workspaces[ws.id])
        guard case .split(let split) = updated.layout,
              let secondPaneID = split.children.last?.paneIDs().first else {
            return XCTFail("expected two-pane split after performSplit")
        }

        // Simulate clicking the second pane's content area.
        try router.focusPane(workspace: ws.id, pane: secondPaneID)

        let final = try XCTUnwrap(ctx.state.workspaces[ws.id])
        XCTAssertEqual(final.focusedPaneID, secondPaneID,
            "clicking the right pane must update focusedPaneID so Cmd+W closes " +
            "the right-pane tab instead of the left-pane tab")
    }
}
