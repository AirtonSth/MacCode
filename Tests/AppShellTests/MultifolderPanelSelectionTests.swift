import XCTest
@testable import AppShell
@testable import CoreModel

// MARK: - Pure helper: uniqueFolderURLs(_:excluding:)
//
// These tests cover the nonisolated static helper that deduplicates
// NSOpenPanel multi-selection results.  No AppKit or @MainActor required.

/// Verifies `SidebarViewModel.uniqueFolderURLs(_:excluding:)`:
/// the pure distillation step between an NSOpenPanel multi-selection result
/// and the workspace-add calls.  Correct behaviour here prevents duplicate
/// workspaces when the user picks the same folder twice (via aliases or
/// accidental re-selection) and avoids creating a workspace for a folder
/// that is already open.
final class MultifolderPanelSelectionTests: XCTestCase {

    // MARK: - Helpers

    private func makeWorkspace(cwd: String) -> Workspace {
        Workspace.empty(name: "w", cwd: cwd)
    }

    // MARK: - empty input

    /// An empty panel result must produce an empty add list.
    /// Prevents a needless reload cycle and router round-trips.
    func test_emptyURLs_returnsEmpty() {
        let result = SidebarViewModel.uniqueFolderURLs([], excluding: [])
        XCTAssertTrue(result.isEmpty,
            "zero panel-selected URLs must yield zero add requests — no URLs means nothing to add")
    }

    /// Empty URLs against a non-empty workspace list must still be empty.
    func test_emptyURLs_withExistingWorkspaces_returnsEmpty() {
        let ws = makeWorkspace(cwd: "/Users/sam/projects/app")
        let result = SidebarViewModel.uniqueFolderURLs([], excluding: [ws])
        XCTAssertTrue(result.isEmpty,
            "zero selected URLs must always yield zero add requests regardless of existing workspaces")
    }

    // MARK: - single URL

    /// A single new URL passes through unchanged.
    func test_singleNewURL_passesThrough() {
        let url = URL(fileURLWithPath: "/Users/sam/projects/alpha")
        let result = SidebarViewModel.uniqueFolderURLs([url], excluding: [])
        XCTAssertEqual(result, [url],
            "a single URL with no existing workspaces must pass through as-is")
    }

    /// A single URL that matches an existing workspace cwd must be excluded.
    /// Adding it would silently flash to the existing workspace — the caller
    /// (createWorkspace(fromFolder:)) already handles that; excluding here
    /// avoids the redundant router call.
    func test_singleURLMatchingExistingWorkspace_excluded() {
        let ws = makeWorkspace(cwd: "/Users/sam/projects/app")
        let url = URL(fileURLWithPath: "/Users/sam/projects/app")
        let result = SidebarViewModel.uniqueFolderURLs([url], excluding: [ws])
        XCTAssertTrue(result.isEmpty,
            "a folder already open as a workspace must be excluded from the add list — adding it again would duplicate or flash unexpectedly")
    }

    // MARK: - multiple URLs, intra-selection dedupe

    /// Two identical URLs in the panel result must collapse to one add request.
    /// This can happen when the user selects a folder and its alias, or
    /// accidentally opens the same path twice.
    func test_duplicateURLs_collapsedToOne() {
        let url = URL(fileURLWithPath: "/Users/sam/projects/shared")
        let result = SidebarViewModel.uniqueFolderURLs([url, url], excluding: [])
        XCTAssertEqual(result.count, 1,
            "duplicate URLs in the panel selection must collapse to a single add request — preventing twin workspaces for the same folder")
    }

    /// Trailing-slash vs. no-trailing-slash variants of the same path must be
    /// treated as one URL (same standardization rule used in findExistingWorkspace).
    func test_trailingSlashVariants_collapsedToOne() {
        let a = URL(fileURLWithPath: "/Users/sam/projects/app")
        let b = URL(fileURLWithPath: "/Users/sam/projects/app/")
        let result = SidebarViewModel.uniqueFolderURLs([a, b], excluding: [])
        XCTAssertEqual(result.count, 1,
            "a URL with and without a trailing slash refer to the same folder and must not produce two add requests")
    }

    /// Two distinct URLs must both appear in the result: no over-suppression.
    func test_twoDistinctURLs_bothKept() {
        let a = URL(fileURLWithPath: "/Users/sam/projects/alpha")
        let b = URL(fileURLWithPath: "/Users/sam/projects/beta")
        let result = SidebarViewModel.uniqueFolderURLs([a, b], excluding: [])
        XCTAssertEqual(result.count, 2,
            "two different folders must both appear as add requests — dedup must not over-suppress")
        XCTAssert(result.contains(a) && result.contains(b),
            "both folders must be present in the result")
    }

    // MARK: - cross-workspace dedup

    /// One of two panel-selected URLs already exists as a workspace cwd; only
    /// the new one should be in the add list.
    func test_oneExisting_oneNew_returnsOnlyNew() {
        let existing = makeWorkspace(cwd: "/Users/sam/projects/app")
        let urlA = URL(fileURLWithPath: "/Users/sam/projects/app")   // already open
        let urlB = URL(fileURLWithPath: "/Users/sam/projects/new")   // new
        let result = SidebarViewModel.uniqueFolderURLs([urlA, urlB], excluding: [existing])
        XCTAssertEqual(result, [urlB],
            "the folder already open as a workspace must be excluded; only the new folder must be returned for adding")
    }

    /// All selected URLs already exist as workspaces -> empty result.
    func test_allExisting_returnsEmpty() {
        let wsA = makeWorkspace(cwd: "/Users/sam/projects/a")
        let wsB = makeWorkspace(cwd: "/Users/sam/projects/b")
        let urlA = URL(fileURLWithPath: "/Users/sam/projects/a")
        let urlB = URL(fileURLWithPath: "/Users/sam/projects/b")
        let result = SidebarViewModel.uniqueFolderURLs([urlA, urlB], excluding: [wsA, wsB])
        XCTAssertTrue(result.isEmpty,
            "when every selected folder is already open as a workspace the add list must be empty — no new workspaces needed")
    }

    // MARK: - order preservation

    /// The output order must match the input order (minus excluded URLs).
    /// Predictable order avoids surprising the user when workspaces appear in
    /// the sidebar in a different sequence than the selection.
    func test_orderPreserved() {
        let urlA = URL(fileURLWithPath: "/z/alpha")
        let urlB = URL(fileURLWithPath: "/z/beta")
        let urlC = URL(fileURLWithPath: "/z/gamma")
        let result = SidebarViewModel.uniqueFolderURLs([urlA, urlB, urlC], excluding: [])
        XCTAssertEqual(result, [urlA, urlB, urlC],
            "add-request order must match panel-selection order so workspaces appear in the sidebar in the user-chosen sequence")
    }
}
