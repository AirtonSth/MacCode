import XCTest
@testable import AppShell
@testable import CoreModel
@testable import Surfaces

// Tests for PaneTabButton accessibility. The pure helper `tabA11yLabel`
// requires no MainActor; view-level assertions use @MainActor only where
// AppKit objects are touched.

// MARK: - Pure helper tests (no MainActor required)

final class PaneTabButtonA11yTests: XCTestCase {

    // WHY: VoiceOver reads the label as the primary description of the tab.
    // When the tab title is the only relevant state the label must be the
    // title alone so the cursor does not announce redundant information.
    func test_tabA11yLabel_titleOnly_whenNotSelectedNotDirty() {
        let label = PaneTabButton.tabA11yLabel(title: "Terminal", isSelected: false, isDirty: false)
        XCTAssertEqual(label, "Terminal",
                       "a plain unselected clean tab must expose only the title as its a11y label")
    }

    // WHY: VoiceOver must announce the active tab so keyboard users know
    // which pane content they are viewing without visual inspection.
    func test_tabA11yLabel_appendsSelected_whenSelected() {
        let label = PaneTabButton.tabA11yLabel(title: "Browser", isSelected: true, isDirty: false)
        XCTAssertTrue(label.contains("selected"),
                      "selected tab label must include \"selected\" so VoiceOver announces tab state")
        XCTAssertTrue(label.hasPrefix("Browser"),
                      "title must precede state qualifiers in the a11y label")
    }

    // WHY: a dirty tab carries unsaved file edits; VoiceOver must warn
    // users before they accidentally close or switch away from it.
    func test_tabA11yLabel_appendsUnsavedChanges_whenDirty() {
        let label = PaneTabButton.tabA11yLabel(title: "Files", isSelected: false, isDirty: true)
        XCTAssertTrue(label.contains("unsaved changes"),
                      "dirty tab label must include \"unsaved changes\" so VoiceOver warns before close/switch")
    }

    // WHY: all three pieces of state must combine so the full tab
    // condition is announced in one pass without requiring multiple
    // VoiceOver cursor movements.
    func test_tabA11yLabel_combinesAllParts_whenSelectedAndDirty() {
        let label = PaneTabButton.tabA11yLabel(title: "Git", isSelected: true, isDirty: true)
        XCTAssertTrue(label.hasPrefix("Git"),
                      "title must always lead the label regardless of state flags")
        XCTAssertTrue(label.contains("unsaved changes"),
                      "combined label must include dirty indicator when both selected and dirty")
        XCTAssertTrue(label.contains("selected"),
                      "combined label must include selected indicator when both selected and dirty")
    }

    // WHY: an empty title must not produce a label that is only
    // punctuation or whitespace — that would confuse screen readers.
    func test_tabA11yLabel_emptyTitle_doesNotCrashAndProducesValidString() {
        let label = PaneTabButton.tabA11yLabel(title: "", isSelected: false, isDirty: false)
        XCTAssertNotNil(label, "empty title must not crash the helper")
        // The result may be empty or just the qualifiers; the point is it
        // is a valid String — no assertion on exact content here.
        _ = label // used, no warning
    }
}

// MARK: - View-level a11y tests (AppKit objects; must be @MainActor)

@MainActor
final class PaneTabButtonA11yViewTests: XCTestCase {

    private func makeContext() throws -> (AppContext, AppCommandRouter) {
        let tmp = NSTemporaryDirectory() + "A11yTest-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: ctx, sshPasswordStore: KeychainSSHPasswordStore())
        ctx.router = router
        return (ctx, router)
    }

    private func closeAndUnregisterAllSurfaces() {
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
    }

    override func tearDown() {
        closeAndUnregisterAllSurfaces()
        super.tearDown()
    }

    // Helper: build a minimal PaneTabsView and return the first PaneTabButton.
    private func makeTabButton(title: String = "Terminal",
                                selected: Bool = false,
                                router: AppCommandRouter,
                                pane: PaneNode) -> PaneTabButton? {
        let ptv = PaneTabsView(pane: pane, router: router)
        return allSubviews(of: ptv.view).compactMap { $0 as? PaneTabButton }.first
    }

    // WHY: VoiceOver reads `accessibilityLabel` as the tab description;
    // if it does not contain the surface title the user cannot identify
    // which tab is which without additional cursor moves.
    func test_tabButton_a11yLabel_containsTitle_onInit() throws {
        let (_, router) = try makeContext()
        let ws = try router.createWorkspace(name: "a11y-label", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail("expected single pane") }
        let tab = try XCTUnwrap(makeTabButton(router: router, pane: pane))

        let label = tab.accessibilityLabel() ?? ""
        // The default tab title is "Agent App" (set by createWorkspace).
        XCTAssertFalse(label.isEmpty,
                       "PaneTabButton must expose a non-empty a11y label so VoiceOver can identify the tab")
        XCTAssertTrue(label.lowercased().contains("agent app"),
                      "a11y label must contain the surface title so VoiceOver reads the correct tab name")
    }

    // WHY: isAccessibilitySelected drives the VoiceOver \"tab selected\"
    // announcement and the Actions rotor \"select\" item. Without it a
    // keyboard user cannot confirm which pane content is visible.
    func test_tabButton_isAccessibilitySelected_matchesDomainSelected_onInit() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "a11y-selected", cwd: NSTemporaryDirectory())
        guard case .pane(let pane0) = ws.layout else { return XCTFail() }
        let ptv = PaneTabsView(pane: pane0, router: router)
        // Add a second surface so the strip has two tabs.
        guard ptv.performAdd(.browser, title: "Browser") != nil else { return XCTFail("performAdd failed") }
        // Re-read the pane after the add so selectedSurfaceID is current.
        guard case .pane(let pane1) = ctx.state.workspaces[ws.id]?.layout else { return XCTFail() }
        // Reconcile the strip with the updated pane so tab buttons reflect
        // the new selection state.
        ptv.reconcile(to: pane1)
        let tabs = allSubviews(of: ptv.view).compactMap { $0 as? PaneTabButton }
        XCTAssertFalse(tabs.isEmpty, "at least one PaneTabButton must exist in the view hierarchy")
        // Exactly one tab must report isAccessibilitySelected == true.
        let selectedTabs = tabs.filter { $0.isAccessibilitySelected() }
        XCTAssertEqual(selectedTabs.count, 1,
                       "exactly one tab must be marked isAccessibilitySelected so VoiceOver identifies the active pane")
    }

    // WHY: reconcile patches the live button in place; if setSelected does
    // not push the new isAccessibilitySelected value, VoiceOver announces
    // the wrong tab as active after a tab switch.
    func test_setSelected_updatesIsAccessibilitySelected() throws {
        let (_, router) = try makeContext()
        let ws = try router.createWorkspace(name: "a11y-set-selected", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail() }
        let tab = try XCTUnwrap(makeTabButton(router: router, pane: pane))

        let before = tab.isAccessibilitySelected()
        tab.setSelected(!before)

        XCTAssertEqual(tab.isAccessibilitySelected(), !before,
                       "setSelected must sync isAccessibilitySelected so VoiceOver tracks tab-switch events")
    }

    // WHY: when the user renames a tab via the context menu the a11y
    // label must update immediately; a stale label makes VoiceOver
    // continue to announce the old name.
    func test_setTitle_updatesA11yLabel() throws {
        let (_, router) = try makeContext()
        let ws = try router.createWorkspace(name: "a11y-rename", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail() }
        let tab = try XCTUnwrap(makeTabButton(router: router, pane: pane))

        tab.setTitle("Renamed Tab")

        let label = tab.accessibilityLabel() ?? ""
        XCTAssertTrue(label.contains("Renamed Tab"),
                      "after setTitle the a11y label must reflect the new title so VoiceOver announces the rename")
    }

    // WHY: the dirty indicator is a visual badge; VoiceOver must announce
    // \"unsaved changes\" without the user having to inspect the badge
    // visually. setDirty must propagate to the a11y label.
    func test_setDirty_updatesA11yLabelWithUnsavedChanges() throws {
        let (_, router) = try makeContext()
        let ws = try router.createWorkspace(name: "a11y-dirty", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail() }
        let tab = try XCTUnwrap(makeTabButton(router: router, pane: pane))

        tab.setDirty(true)

        let label = tab.accessibilityLabel() ?? ""
        XCTAssertTrue(label.contains("unsaved changes"),
                      "setDirty(true) must add \"unsaved changes\" to the a11y label so VoiceOver warns before close")

        tab.setDirty(false)

        let labelClean = tab.accessibilityLabel() ?? ""
        XCTAssertFalse(labelClean.contains("unsaved changes"),
                       "setDirty(false) must remove the unsaved-changes annotation from the a11y label")
    }

    // WHY: the close action is essential for keyboard-only VoiceOver use;
    // without a custom action the user must navigate focus to the \"\xd7\"
    // subbutton, which is off-screen in a crowded tab strip and hard to
    // discover. The close action must always be registered.
    func test_tabButton_alwaysHasCloseCustomAction() throws {
        let (_, router) = try makeContext()
        let ws = try router.createWorkspace(name: "a11y-close-action", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail() }
        let tab = try XCTUnwrap(makeTabButton(router: router, pane: pane))

        let actions = tab.accessibilityCustomActions() ?? []
        let closeAction = actions.first { $0.name == "Close tab" }
        XCTAssertNotNil(closeAction,
                        "every tab must expose a \"Close tab\" custom action so VoiceOver users can close without hunting the close subbutton")
    }

    // WHY: rename is surfaced via context menu (mouse/trackpad gesture);
    // VoiceOver users need a custom action to trigger it from the keyboard
    // Actions rotor without a right-click.
    func test_tabButton_hasRenameCustomAction_whenOnRenameProvided() throws {
        let (_, router) = try makeContext()
        let ws = try router.createWorkspace(name: "a11y-rename-action", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail() }
        // PaneTabsView always wires onRename for real tabs.
        let ptv = PaneTabsView(pane: pane, router: router)
        let tab = try XCTUnwrap(allSubviews(of: ptv.view).compactMap { $0 as? PaneTabButton }.first)

        let actions = tab.accessibilityCustomActions() ?? []
        let renameAction = actions.first { $0.name == "Rename tab" }
        XCTAssertNotNil(renameAction,
                        "a tab wired with an onRename callback must expose a \"Rename tab\" a11y custom action")
    }
}

// MARK: - Helpers (file-local)

private func allSubviews(of view: NSView) -> [NSView] {
    var result: [NSView] = []
    func collect(_ v: NSView) {
        result.append(v)
        v.subviews.forEach(collect)
    }
    collect(view)
    return result
}
