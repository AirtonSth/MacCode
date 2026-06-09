import XCTest
@testable import Surfaces

/// Tests for StagingHelper.pathArgs — the pure function that translates a
/// user file-selection into the validated arg list for `git add`.
///
/// WHY each assertion matters:
///   • empty selection → nil: the commit button must be disabled (no accidental
///     "git add" with no paths).
///   • empty all-list → nil: guards against a race where files disappear between
///     UI render and button press.
///   • subset selection: only the selected paths reach `git add`, so unselected
///     files are NOT staged — the core per-file-commit contract.
///   • stale paths dropped silently: if a file disappears from the working tree
///     between selection and commit, the arg list is still valid (no phantom path).
///   • paths with spaces: returned as individual array elements so Process passes
///     them verbatim — no shell quoting issue.
///   • result is sorted: deterministic ordering aids test assertions and makes
///     git history reproducible.
final class StagingHelperTests: XCTestCase {

    func test_emptySelected_returnsNil() {
        // Empty selection must disable the commit button — no-op, not a "git add" of everything.
        let result = StagingHelper.pathArgs(selected: [], all: ["a.txt", "b.txt"])
        XCTAssertNil(result, "empty selection must return nil so the caller treats it as a no-op")
    }

    func test_emptyAll_returnsNil() {
        // If the changed-file list is empty the button is already disabled upstream,
        // but the helper must still be safe when called in that state.
        let result = StagingHelper.pathArgs(selected: ["a.txt"], all: [])
        XCTAssertNil(result, "selection against an empty changed-file list must return nil")
    }

    func test_subsetSelection_returnsOnlySelectedPaths() {
        // Core contract: only checked files go to `git add`; unchecked files are NOT staged.
        let result = StagingHelper.pathArgs(selected: ["b.txt"], all: ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(result, ["b.txt"],
                       "only the selected path must appear in the git-add arg list")
    }

    func test_fullSelection_returnsAllPaths() {
        let all = ["a.txt", "b.txt", "c.txt"]
        let result = StagingHelper.pathArgs(selected: Set(all), all: all)
        XCTAssertEqual(result, all.sorted(),
                       "selecting all files must include every path")
    }

    func test_stalePathDropped_doesNotPropagatePhantomPath() {
        // A file that was in the UI but no longer in the working tree must be silently
        // dropped — passing a non-existent path to `git add` would cause an error.
        let result = StagingHelper.pathArgs(selected: ["ghost.swift", "real.swift"],
                                            all: ["real.swift"])
        XCTAssertEqual(result, ["real.swift"],
                       "paths not in the changed-file list must be silently dropped")
    }

    func test_stalePathDropped_allStale_returnsNil() {
        // If every selected path is stale the effective selection is empty → nil.
        let result = StagingHelper.pathArgs(selected: ["ghost.swift"], all: ["real.swift"])
        XCTAssertNil(result, "all-stale selection must return nil, not an empty array")
    }

    func test_pathWithSpaces_returnedAsIndividualElement() {
        // Paths with spaces must appear as a single element — Process passes them
        // verbatim to execve, so no quoting is needed and none must be added.
        let path = "src/my module/some file.swift"
        let result = StagingHelper.pathArgs(selected: [path], all: [path])
        XCTAssertEqual(result, [path],
                       "a path containing spaces must be a single element, not split")
    }

    func test_resultIsSorted_forDeterministicGitHistory() {
        // Sorted output makes `git add` calls reproducible across runs.
        let result = StagingHelper.pathArgs(selected: ["z.txt", "a.txt", "m.txt"],
                                            all: ["a.txt", "m.txt", "z.txt"])
        XCTAssertEqual(result, ["a.txt", "m.txt", "z.txt"],
                       "paths must be returned in sorted order for reproducibility")
    }
}
