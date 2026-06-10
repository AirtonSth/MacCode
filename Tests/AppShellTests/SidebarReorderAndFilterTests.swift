import XCTest
@testable import AppShell
@testable import CoreModel
import Persistence

/// Tests for sidebar reorder + filter coverage (T001/T003 from mac-sidebar-workspaces.md):
///   - T001: downward drag-reorder (upward-only was the previous coverage)
///   - T003: filtered-list reorder resolves against canonical `workspaces` array
///   - filterText / filteredWorkspaces: matching rules, empty-state, cwd match
///   - selection state is preserved when selected row moves through a reorder

@MainActor
final class SidebarReorderAndFilterTests: XCTestCase {

    // MARK: - Helpers

    private func make() throws -> (AppContext, AppCommandRouter, SidebarViewModel) {
        let dir = NSTemporaryDirectory() + "RC2SidebarReorder-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let vm = SidebarViewModel(context: ctx, router: router)
        return (ctx, router, vm)
    }

    // MARK: - T001: downward drag-reorder

    /// WHY: WorkspaceEditTests covers upward-only drag (third before first).
    /// Downward drag was not tested.  A bug in the position calculation only
    /// for downward moves would silently place the dragged workspace at the
    /// wrong index, scrambling the sidebar order the user set.
    ///
    /// Implementation note: reorderWorkspace(dragged, before: target) inserts
    /// dragged at target's pre-removal index.  When dragged is before target in
    /// the list, removing dragged shifts remaining items left, so the insert
    /// at targetIndex places dragged AFTER target (downward drag lands at end
    /// when target is the last element).
    func test_reorderWorkspace_downward_movesWorkspaceToEnd() throws {
        let (ctx, router, vm) = try make()
        let a = try router.createWorkspace(name: "alpha", cwd: "/a")
        let b = try router.createWorkspace(name: "beta",  cwd: "/b")
        let c = try router.createWorkspace(name: "gamma", cwd: "/c")
        vm.reload()

        // Drag alpha (index 0) "before" gamma (index 2).  After removing alpha
        // from [a,b,c] -> [b,c], insert at position 2 -> [b,c,a].
        vm.reorderWorkspace(a.id, before: c.id)

        let order = ctx.state.window.workspaces
        XCTAssertEqual(order, [b.id, c.id, a.id],
                       "downward drag: alpha at index 0 reordered before gamma at index 2 must produce [beta, gamma, alpha]  -  " +
                       "the position-based insert places the item at the pre-removal target index, after removal shifts the list")
    }

    /// WHY: Dragging the middle workspace to just before the first must produce
    /// [middle, first, last].  This is the upward-drag complement.
    func test_reorderWorkspace_upward_movesWorkspaceBeforeTarget() throws {
        let (ctx, router, vm) = try make()
        let a = try router.createWorkspace(name: "alpha", cwd: "/a")
        let b = try router.createWorkspace(name: "beta",  cwd: "/b")
        let c = try router.createWorkspace(name: "gamma", cwd: "/c")
        vm.reload()

        // Drag gamma (index 2) before alpha (index 0).
        // Remove gamma from [a,b,c] -> [a,b], insert at 0 -> [c,a,b].
        vm.reorderWorkspace(c.id, before: a.id)

        let order = ctx.state.window.workspaces
        XCTAssertEqual(order, [c.id, a.id, b.id],
                       "upward drag: gamma before alpha must produce [gamma, alpha, beta]  -  " +
                       "removing gamma then inserting at alpha's pre-removal index (0) must place it first")
    }

    /// WHY: Dragging a workspace to the same position must be a no-op so the
    /// sidebar does not flicker and the undo stack is not polluted with identity moves.
    func test_reorderWorkspace_samePosition_isNoOp() throws {
        let (ctx, router, vm) = try make()
        let a = try router.createWorkspace(name: "alpha", cwd: "/a")
        let b = try router.createWorkspace(name: "beta",  cwd: "/b")
        vm.reload()
        let originalOrder = ctx.state.window.workspaces

        // Drag alpha before itself -- no-op (dragged == target guard).
        vm.reorderWorkspace(a.id, before: a.id)

        XCTAssertEqual(ctx.state.window.workspaces, originalOrder,
                       "dragging a workspace to its own position must leave the order unchanged")
        _ = b  // suppress unused warning
    }

    // MARK: - T003: filtered-list reorder

    /// WHY: When a filter is active, the sidebar renders a subset of workspaces.
    /// The drag-reorder must still resolve indices against the canonical
    /// (unfiltered) `workspaces` array so the operation makes sense
    /// after the filter is cleared.  A bug here would silently place the
    /// workspace at an index into the filtered array, corrupting the global order.
    func test_reorderWorkspace_withFilterActive_resolvesAgainstCanonicalOrder() throws {
        let (ctx, router, vm) = try make()
        let a = try router.createWorkspace(name: "alpha", cwd: "/a")
        let b = try router.createWorkspace(name: "HIDDEN", cwd: "/h")
        let c = try router.createWorkspace(name: "gamma", cwd: "/c")
        vm.reload()
        vm.filterText = "a"  // "alpha" and "gamma" visible; "HIDDEN" hidden

        let filtered = vm.filteredWorkspaces
        XCTAssertEqual(filtered.count, 2,
                       "filter 'a' must show exactly alpha and gamma")

        // Drag alpha (canonical index 0) "before" gamma (canonical index 2).
        // Reducer: remove alpha from [alpha, HIDDEN, gamma] -> [HIDDEN, gamma],
        // insert at 2 -> [HIDDEN, gamma, alpha].
        // Key invariant: the operation resolves against the canonical array,
        // not the filtered array, so HIDDEN stays at its correct canonical position.
        vm.reorderWorkspace(a.id, before: c.id)

        let canonicalOrder = ctx.state.window.workspaces
        let names = canonicalOrder.compactMap { ctx.state.workspaces[$0]?.name }
        // HIDDEN must still be present at some position (not dropped by the reorder).
        XCTAssertTrue(names.contains("HIDDEN"),
                      "reorder with filter active must not drop hidden workspaces from the canonical list")
        // Alpha ends up after gamma (downward drag semantics, see T001).
        XCTAssertTrue(names.firstIndex(of: "gamma")! < names.firstIndex(of: "alpha")!,
                      "downward drag of alpha before gamma must place alpha after gamma in the canonical order  -  " +
                      "the position resolves against the canonical array index of gamma")
        _ = b  // suppress unused warning
    }

    // MARK: - filterText / filteredWorkspaces matching rules

    /// WHY: filteredWorkspaces must match on workspace name (case-insensitive).
    /// A case-sensitive match would hide workspaces whose names the user typed
    /// in a different case, breaking the filter for any mixed-case name.
    func test_filteredWorkspaces_nameMatch_isCaseInsensitive() throws {
        let (_, router, vm) = try make()
        _ = try router.createWorkspace(name: "MyProject", cwd: "/my")
        _ = try router.createWorkspace(name: "other",     cwd: "/other")
        vm.reload()

        vm.filterText = "myproject"
        let result = vm.filteredWorkspaces
        XCTAssertEqual(result.count, 1,
                       "filter must match 'MyProject' when the user types 'myproject' (case-insensitive)")
        XCTAssertEqual(result.first?.name, "MyProject")
    }

    /// WHY: filteredWorkspaces must also match on `cwd` so users can find
    /// workspaces by path fragment when many share similar names.
    func test_filteredWorkspaces_cwdMatch() throws {
        let (_, router, vm) = try make()
        _ = try router.createWorkspace(name: "web",    cwd: "/Users/sam/projects/web-app")
        _ = try router.createWorkspace(name: "server", cwd: "/Users/sam/projects/api")
        vm.reload()

        vm.filterText = "web-app"
        let result = vm.filteredWorkspaces
        XCTAssertEqual(result.count, 1,
                       "filter must match on cwd substring so users can search by path")
        XCTAssertEqual(result.first?.name, "web")
    }

    /// WHY: filteredWorkspaces with an empty filterText must return all workspaces.
    /// An empty string is the default/reset state; returning a subset would hide
    /// workspaces the user expects to see after clearing the search field.
    func test_filteredWorkspaces_emptyFilter_returnsAll() throws {
        let (_, router, vm) = try make()
        _ = try router.createWorkspace(name: "alpha", cwd: "/a")
        _ = try router.createWorkspace(name: "beta",  cwd: "/b")
        _ = try router.createWorkspace(name: "gamma", cwd: "/c")
        vm.reload()

        vm.filterText = ""
        XCTAssertEqual(vm.filteredWorkspaces.count, 3,
                       "empty filterText must return the complete workspace list  -  " +
                       "returning a subset would hide workspaces without the user asking")
    }

    /// WHY: When no workspace matches the filter, filteredWorkspaces must return
    /// an empty array, not nil or the full list.  The view uses this to decide
    /// whether to show an empty-state message; a non-empty array would hide the
    /// empty-state and show stale rows instead.
    func test_filteredWorkspaces_noMatch_returnsEmpty() throws {
        let (_, router, vm) = try make()
        _ = try router.createWorkspace(name: "alpha", cwd: "/a")
        vm.reload()

        vm.filterText = "zzznomatch"
        XCTAssertTrue(vm.filteredWorkspaces.isEmpty,
                      "a filter with no matches must return an empty array so the view can show the empty-state message")
    }

    // MARK: - Selection persists across hidden rows

    /// WHY: When a filter is applied after a workspace is selected, the selection
    /// must be preserved even if the selected workspace is not in filteredWorkspaces.
    /// The backing `selectedWorkspaceID` must remain stable so switching back to
    /// an unfiltered view restores the user's previous position.
    func test_filterDoesNotClearSelectedWorkspaceID() throws {
        let (_, router, vm) = try make()
        let a = try router.createWorkspace(name: "alpha", cwd: "/a")
        _ = try router.createWorkspace(name: "beta", cwd: "/b")
        vm.reload()
        vm.select(a.id)
        XCTAssertEqual(vm.selectedWorkspaceID, a.id)

        // Apply a filter that hides alpha.
        vm.filterText = "beta"
        XCTAssertEqual(vm.filteredWorkspaces.count, 1, "only beta is visible")

        // The backing selection must not be cleared just because the selected
        // workspace is no longer in the visible list.
        XCTAssertEqual(vm.selectedWorkspaceID, a.id,
                       "selectedWorkspaceID must not be cleared when the selected workspace is hidden by a filter  -  " +
                       "clearing it would lose the user's position when they clear the filter")
    }

    // MARK: - uniqueFolderURLs deduplication (pure helper)

    /// WHY: uniqueFolderURLs is the single dedup gate before multi-folder add.
    /// If it fails to remove an already-present workspace, two workspaces with
    /// the same cwd are created, breaking the Open Recent / dedup invariant.
    func test_uniqueFolderURLs_removesExistingWorkspaceCwds() throws {
        let (_, router, vm) = try make()
        let ws = try router.createWorkspace(name: "existing", cwd: "/tmp/existing")
        vm.reload()

        let urls = [URL(fileURLWithPath: "/tmp/existing"), URL(fileURLWithPath: "/tmp/new")]
        let deduped = SidebarViewModel.uniqueFolderURLs(urls, excluding: vm.workspaces)

        XCTAssertEqual(deduped.count, 1,
                       "a URL whose cwd already exists in workspaces must be excluded from the add batch")
        XCTAssertEqual(deduped.first?.path, "/tmp/new",
                       "the new (non-duplicate) URL must survive deduplication")
        _ = ws  // suppress unused warning
    }

    /// WHY: uniqueFolderURLs must also remove intra-selection duplicates
    /// (same path appears twice in the panel selection, e.g. folder + alias).
    func test_uniqueFolderURLs_removesIntraSelectionDuplicates() {
        let url = URL(fileURLWithPath: "/tmp/myproject")
        let deduped = SidebarViewModel.uniqueFolderURLs([url, url], excluding: [])
        XCTAssertEqual(deduped.count, 1,
                       "two identical URLs in the selection must be collapsed to one  -  " +
                       "creating duplicate workspaces breaks the cwd-uniqueness invariant")
    }
}
