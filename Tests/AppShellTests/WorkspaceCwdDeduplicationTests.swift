import XCTest
@testable import AppShell
@testable import CoreModel
import Persistence

// MARK: - Pure helper tests (no @MainActor needed)

/// Tests for `SidebarViewModel.findExistingWorkspace(byCwd:in:)`.
/// The helper is `nonisolated static`, so these run off the main actor and
/// cannot accidentally regress into a race.
final class FindExistingWorkspaceByCwdTests: XCTestCase {

    // Build a minimal Workspace stub — only id and cwd matter.
    private func makeWorkspace(cwd: String) -> Workspace {
        Workspace.empty(name: "w", cwd: cwd)
    }

    // PASS: exact match -> existing id returned.
    func test_exactMatch_returnsExistingID() {
        let ws = makeWorkspace(cwd: "/Users/sam/projects/app")
        let url = URL(fileURLWithPath: "/Users/sam/projects/app")
        let result = SidebarViewModel.findExistingWorkspace(byCwd: url, in: [ws])
        XCTAssertEqual(result, ws.id,
            "adding a folder whose path exactly matches an existing workspace cwd must return that workspace id so the caller selects it instead of duplicating")
    }

    // PASS: trailing slash on incoming url -> still matches stored path without slash.
    func test_trailingSlashOnURL_normalizes() {
        let ws = makeWorkspace(cwd: "/Users/sam/projects/app")
        // URL(fileURLWithPath:isDirectory:true) appends a trailing slash
        let url = URL(fileURLWithPath: "/Users/sam/projects/app/")
        let result = SidebarViewModel.findExistingWorkspace(byCwd: url, in: [ws])
        XCTAssertEqual(result, ws.id,
            "a folder URL with a trailing slash must still match the stored cwd that lacks one — both sides are standardized before comparison")
    }

    // PASS: trailing slash stored in cwd -> matches url without slash.
    func test_trailingSlashInStoredCwd_normalizes() {
        let ws = makeWorkspace(cwd: "/Users/sam/projects/app/")
        let url = URL(fileURLWithPath: "/Users/sam/projects/app")
        let result = SidebarViewModel.findExistingWorkspace(byCwd: url, in: [ws])
        XCTAssertEqual(result, ws.id,
            "a stored cwd with a trailing slash must still match an incoming url without one after standardization")
    }

    // PASS: distinct cwd -> nil (no false positive).
    func test_distinctCwd_returnsNil() {
        let ws = makeWorkspace(cwd: "/Users/sam/projects/app")
        let url = URL(fileURLWithPath: "/Users/sam/projects/other")
        let result = SidebarViewModel.findExistingWorkspace(byCwd: url, in: [ws])
        XCTAssertNil(result,
            "a different cwd must never match an existing workspace — returning a wrong id would silently switch the user to the wrong project")
    }

    // PASS: empty list -> nil (no crash).
    func test_emptyWorkspaceList_returnsNil() {
        let url = URL(fileURLWithPath: "/Users/sam/projects/app")
        let result = SidebarViewModel.findExistingWorkspace(byCwd: url, in: [])
        XCTAssertNil(result,
            "searching an empty workspace list must return nil, not crash")
    }

    // PASS: returns the first match when multiple workspaces share the same cwd.
    func test_multipleWorkspacesWithSameCwd_returnsFirst() {
        let first = makeWorkspace(cwd: "/shared")
        let second = makeWorkspace(cwd: "/shared")
        let url = URL(fileURLWithPath: "/shared")
        let result = SidebarViewModel.findExistingWorkspace(byCwd: url, in: [first, second])
        XCTAssertEqual(result, first.id,
            "if somehow two workspaces share a cwd the helper must return the first one — consistent behavior prevents random selection")
    }
}

// MARK: - Integration test (touches SidebarViewModel -> @MainActor required)

@MainActor
final class WorkspaceCwdDeduplicationIntegrationTests: XCTestCase {

    private func make() throws -> (AppContext, AppCommandRouter) {
        let dir = NSTemporaryDirectory() + "RC2CwdDedup-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        return (ctx, router)
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2Dedup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // PASS: adding the same folder twice must not create a second workspace.
    func test_duplicateCwd_selectsExistingWorkspaceInsteadOfCreating() throws {
        let folder = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (ctx, router) = try make()
        let vm = SidebarViewModel(context: ctx, router: router)

        XCTAssertTrue(vm.createWorkspace(fromFolder: folder), "first call must succeed")
        let countAfterFirst = ctx.state.workspaces.count

        XCTAssertTrue(vm.createWorkspace(fromFolder: folder), "second call with same folder must return true (selects, not error)")
        XCTAssertEqual(ctx.state.workspaces.count, countAfterFirst,
            "adding the same cwd a second time must select the existing workspace, not create a duplicate — accidental duplicates appear via drag-drop, Open Recent, and Cmd+N")
    }

    // PASS: distinct cwd must still create a new workspace (no over-suppression).
    func test_distinctCwd_createsBothWorkspaces() throws {
        let folderA = try makeTempDir()
        let folderB = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: folderA)
            try? FileManager.default.removeItem(at: folderB)
        }
        let (ctx, router) = try make()
        let vm = SidebarViewModel(context: ctx, router: router)

        XCTAssertTrue(vm.createWorkspace(fromFolder: folderA))
        XCTAssertTrue(vm.createWorkspace(fromFolder: folderB))
        XCTAssertEqual(ctx.state.workspaces.count, 2,
            "two different folders must produce two separate workspaces — dedup must not over-suppress")
    }

    // FAIL-LOUD: a folder that cannot be added must say so.
    func test_staleFolderAdd_surfacesTheFailureInsteadOfDoingNothing() throws {
        let (ctx, router) = try make()
        let stale = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2Stale-\(UUID().uuidString)", isDirectory: true)
        var messages: [String] = []
        var details: [String] = []
        let vm = SidebarViewModel(
            context: ctx,
            router: router,
            operationErrorPresenter: { message, detail in
                messages.append(message)
                details.append(detail)
            }
        )

        XCTAssertFalse(vm.createWorkspace(fromFolder: stale),
                       "a folder that does not exist must not report success")
        XCTAssertEqual(ctx.state.workspaces.count, 0, "a failed add must not create a workspace")

        XCTAssertEqual(messages.count, 1,
            "WHY: the picker closes on the user's gesture, so silently returning false leaves them with no row, no error and no idea what happened — the same path serves drag-drop and a stale File ▸ Open Recent entry")
        XCTAssertEqual(messages.first, "Could not add \(stale.lastPathComponent)")
        XCTAssertEqual(details.first,
            "That folder no longer exists. It may have been moved, renamed or deleted.",
            "WHY: LayoutError's generic text says a workspace is closed; on this path the folder itself is gone, so the reason must name the folder")
    }

    // Unrelated failures must keep their own message, not claim the folder vanished.
    //
    // NOTE: this spec references `addWorkspaceFailureDetail(for:)`, which the fix
    // introduced, so it cannot compile against the pre-fix source and has no
    // "before" of its own. The behavioural before/after lives in
    // `test_staleFolderAdd_surfacesTheFailureInsteadOfDoingNothing`, which uses
    // only API that already existed.
    func test_addWorkspaceFailureDetail_keepsUnderlyingMessageForOtherErrors() throws {
        struct OtherError: LocalizedError {
            var errorDescription: String? { "db is locked" }
        }

        XCTAssertEqual(SidebarViewModel.addWorkspaceFailureDetail(for: OtherError()), "db is locked")
        XCTAssertEqual(
            SidebarViewModel.addWorkspaceFailureDetail(for: LayoutError.workspaceNotFound),
            "That folder no longer exists. It may have been moved, renamed or deleted.",
            "only the stale-folder case is translated; a true disk/db failure must not be reported as a missing folder"
        )
    }
}
