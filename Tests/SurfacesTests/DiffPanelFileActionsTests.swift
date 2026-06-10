import XCTest
@testable import Surfaces
import AgentRuntime

/// Unit tests for the changed-file-row action helpers on DiffPanelViewModel.
///
/// WHY: non-binary changed-file rows should offer "Open in Files tab" and
/// "Reveal in Finder" context actions so users can jump to an editor or Finder
/// without leaving the diff panel. Binary rows must NOT offer "Open in Files tab"
/// because there is nothing to show in the text editor; they already have their
/// own "Open in default app" escape hatch. Path resolution must join cwd and the
/// relative file path correctly so both actions target the real file on disk.
@MainActor
final class DiffPanelFileActionsTests: XCTestCase {

    // MARK: absolutePathURL — path join contract

    func test_absolutePathURL_joinsRelativePathToCwd() {
        let url = DiffPanelViewModel.absolutePathURL(cwd: "/Users/sam/project", relativePath: "src/main.swift")
        XCTAssertEqual(url.path, "/Users/sam/project/src/main.swift",
                       "absolute URL must be cwd + relativePath so the action opens the correct file on disk")
    }

    func test_absolutePathURL_handlesTopLevelRelativePath() {
        let url = DiffPanelViewModel.absolutePathURL(cwd: "/repo", relativePath: "README.md")
        XCTAssertEqual(url.path, "/repo/README.md",
                       "top-level relative paths must resolve to cwd/filename without extra slashes")
    }

    func test_absolutePathURL_normalizesTrailingSlashInCwd() {
        let url = DiffPanelViewModel.absolutePathURL(cwd: "/repo/", relativePath: "a/b.txt")
        XCTAssertEqual(url.path, "/repo/a/b.txt",
                       "a trailing slash in cwd must not produce a double-slash in the resolved path")
    }

    func test_absolutePathURL_resolvesDotDotComponents() {
        // A relative path that escapes the cwd should still standardize cleanly.
        let url = DiffPanelViewModel.absolutePathURL(cwd: "/repo/sub", relativePath: "../other.txt")
        XCTAssertEqual(url.path, "/repo/other.txt",
                       "'..' components must be resolved so the path targets the real file, not a symlink alias")
    }

    // MARK: isOpenInFilesTabApplicable — binary guard

    func test_textEntry_isApplicable() {
        let entry = GitFileEntry(path: "src/foo.swift", oldPath: nil,
                                 status: .modified, additions: 3, deletions: 1, binary: false)
        XCTAssertTrue(DiffPanelViewModel.isOpenInFilesTabApplicable(for: entry),
                      "a text file must be applicable so the 'Open in Files tab' menu item appears")
    }

    func test_binaryEntry_isNotApplicable() {
        let entry = GitFileEntry(path: "assets/logo.png", oldPath: nil,
                                 status: .modified, additions: 0, deletions: 0, binary: true)
        XCTAssertFalse(DiffPanelViewModel.isOpenInFilesTabApplicable(for: entry),
                       "a binary file must NOT be applicable — 'Open in Files tab' is meaningless for non-text files")
    }

    func test_untrackedTextEntry_isApplicable() {
        let entry = GitFileEntry(path: "new_file.txt", oldPath: nil,
                                 status: .untracked, additions: 5, deletions: 0, binary: false)
        XCTAssertTrue(DiffPanelViewModel.isOpenInFilesTabApplicable(for: entry),
                      "an untracked text file must also be applicable — the file exists on disk and can be opened in the editor")
    }

    func test_deletedTextEntry_isApplicable() {
        // Deleted files no longer exist on disk, but the action applicability
        // is a display concern (hide vs show the menu item). The caller decides
        // whether the file exists; the helper only cares about binary vs text.
        let entry = GitFileEntry(path: "gone.txt", oldPath: nil,
                                 status: .deleted, additions: 0, deletions: 4, binary: false)
        XCTAssertTrue(DiffPanelViewModel.isOpenInFilesTabApplicable(for: entry),
                      "a deleted-but-text entry reports applicable — the UI may handle the missing-file case separately")
    }

    // MARK: openInFilesTabAction injection

    func test_openInFilesTabAction_defaultsToNil() {
        let vm = DiffPanelViewModel(cwd: "/tmp")
        XCTAssertNil(vm.openInFilesTabAction,
                     "action must default to nil so surfaces that don't wire a router stay unchanged")
    }

    func test_openInFilesTabAction_isCallableWhenInjected() {
        let vm = DiffPanelViewModel(cwd: "/tmp")
        var captured: String?
        vm.openInFilesTabAction = { path in captured = path }
        vm.openInFilesTabAction?("src/main.swift")
        XCTAssertEqual(captured, "src/main.swift",
                       "injected action must be called with the relative path so the router can resolve the Files tab")
    }
}
