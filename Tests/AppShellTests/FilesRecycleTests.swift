import XCTest
@testable import AppShell

/// Tests for the `recycleURLs(forAbsolutePaths:)` pure helper introduced for P2 Move-to-Trash.
///
/// WHY these tests matter:
///  - `recycleURLs` is the single place that maps selected file paths -> the URL array passed
///    to `NSWorkspace.shared.recycle`. If it maps the wrong paths or produces empty output
///    the recycle call silently does nothing; the files stay on disk instead of going to Trash.
///  - Keeping this logic in a pure helper (no AppKit, no MainActor) lets us assert the exact
///    URLs that will be recycled without running AppKit or stubbing the whole VM.
final class FilesRecycleTests: XCTestCase {

    // MARK: - recycleURLs(forAbsolutePaths:)

    func test_recycleURLs_singlePath_returnsMatchingURL() {
        // WHY: a single-file delete must produce exactly one URL whose path matches the
        // absolute path stored on the FileEntry — getting this wrong would recycle the wrong file.
        let urls = recycleURLs(forAbsolutePaths: ["/Users/sam/workspace/README.md"])
        XCTAssertEqual(urls.count, 1, "one input path must produce exactly one URL")
        XCTAssertEqual(urls[0].path, "/Users/sam/workspace/README.md",
            "URL path must match the absolute path passed in")
    }

    func test_recycleURLs_multiplePaths_allMapped() {
        // WHY: a multi-select delete must include every selected path; dropping any entry
        // would leave orphaned files on disk instead of moving them to Trash.
        let inputs = ["/ws/a.txt", "/ws/b.txt", "/ws/sub/c.swift"]
        let urls = recycleURLs(forAbsolutePaths: inputs)
        XCTAssertEqual(urls.count, 3, "all input paths must be mapped to URLs")
        XCTAssertEqual(urls.map(\.path), inputs,
            "URL paths must match input paths in order")
    }

    func test_recycleURLs_emptyInput_returnsEmpty() {
        // WHY: delete on zero entries must not produce a spurious recycle call with a
        // non-empty URL list — the guard in FilesViewModel.delete already blocks this path
        // but the helper must also be safe to call with [] in isolation.
        let urls = recycleURLs(forAbsolutePaths: [])
        XCTAssertTrue(urls.isEmpty, "empty input must yield empty URL array")
    }

    func test_recycleURLs_directoryPath_producedAsFileURL() {
        // WHY: directories are also valid recycle targets (e.g. deleting a folder via the
        // context menu). The URL must be a file URL (isFileURL == true) so NSWorkspace.recycle
        // can locate it on the local file-system.
        let urls = recycleURLs(forAbsolutePaths: ["/ws/mydir"])
        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(urls[0].isFileURL,
            "URL for a directory must be a file URL so NSWorkspace.recycle can find it")
        XCTAssertEqual(urls[0].path, "/ws/mydir",
            "directory path must be preserved exactly")
    }

    func test_recycleURLs_preservesOrder() {
        // WHY: NSWorkspace.recycle processes all URLs atomically but callers may rely on
        // index-correspondence when inspecting the trashedURLs completion map; order must
        // match the input slice.
        let inputs = ["/a", "/b", "/c", "/d"]
        let urls = recycleURLs(forAbsolutePaths: inputs)
        XCTAssertEqual(urls.map(\.path), inputs,
            "URL order must match input order for caller index-correspondence")
    }

    // MARK: - filesDeleteSelectionUpdate

    func test_deleteSelectionUpdate_deletedSelectedPathClearsEditorAndDirtyPaths() {
        let update = filesDeleteSelectionUpdate(
            selectedPath: "src/App.swift",
            deletedPaths: ["src/App.swift", "README.md"],
            dirtyPaths: ["src/App.swift", "README.md", "docs/Guide.md"]
        )

        XCTAssertTrue(update.shouldClearSelectedEditor,
            "deleting the selected file must clear the editor state before recycling")
        XCTAssertEqual(update.dirtyPaths, ["docs/Guide.md"],
            "all deleted paths must be removed from dirtyPaths while unrelated dirty files remain")
    }

    func test_deleteSelectionUpdate_unselectedDeleteKeepsEditor() {
        let update = filesDeleteSelectionUpdate(
            selectedPath: "src/App.swift",
            deletedPaths: ["README.md"],
            dirtyPaths: ["src/App.swift", "README.md"]
        )

        XCTAssertFalse(update.shouldClearSelectedEditor,
            "deleting another file must not clear the currently selected editor")
        XCTAssertEqual(update.dirtyPaths, ["src/App.swift"],
            "dirtyPaths should clear only the deleted file")
    }
}
