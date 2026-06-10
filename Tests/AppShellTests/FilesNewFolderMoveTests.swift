import XCTest
@testable import AppShell

/// Tests for the two pure path helpers introduced for P1 New Folder + drag-to-move.
///
/// WHY these tests matter:
///  - `newFolderTargetPath` must uniquify names so concurrent agents creating "New Folder"
///    don't silently overwrite each other; the uniquification rule is observable product
///    behaviour, not implementation detail.
///  - `validateMove` enforces the security invariant that a directory cannot be moved into
///    itself or a descendant, and that paths cannot escape the workspace. Getting this wrong
///    would corrupt the workspace tree or allow sandbox escapes.
final class FilesNewFolderMoveTests: XCTestCase {

    // MARK: - newFolderTargetPath

    func test_newFolderTargetPath_noCollision_returnsNameUnderParent() {
        // A fresh name with no siblings must be returned as-is - adding a suffix would confuse
        // users who typed an explicit name.
        let result = newFolderTargetPath(parent: "src", name: "components", existingNames: [])
        XCTAssertEqual(result, "src/components",
            "non-colliding name in a subdirectory must be returned unchanged")
    }

    func test_newFolderTargetPath_inRootWithEmptyParent_returnsJustName() {
        // When `parent` is "" the folder is at workspace root; no leading slash or separator.
        let result = newFolderTargetPath(parent: "", name: "NewFolder", existingNames: [])
        XCTAssertEqual(result, "NewFolder",
            "empty parent means workspace root; path must be just the name with no separator")
    }

    func test_newFolderTargetPath_collision_appendsSuffix2() {
        // When a sibling named "components" already exists, the next available name is
        // "components 2" - this is the uniquification contract the UI relies on.
        let result = newFolderTargetPath(parent: "src", name: "components", existingNames: ["components"])
        XCTAssertEqual(result, "src/components 2",
            "first collision must produce name + \" 2\"")
    }

    func test_newFolderTargetPath_multipleCollisions_incrementsCounter() {
        // Both "components" and "components 2" exist; the helper must find "components 3".
        let result = newFolderTargetPath(parent: "src", name: "components", existingNames: ["components", "components 2"])
        XCTAssertEqual(result, "src/components 3",
            "second collision must increment to 3 not re-emit 2")
    }

    func test_newFolderTargetPath_skipsExistingCountedNames() {
        // "components", "components 2", "components 3" all exist; must yield "components 4".
        let existing: Set<String> = ["components", "components 2", "components 3"]
        let result = newFolderTargetPath(parent: "", name: "components", existingNames: existing)
        XCTAssertEqual(result, "components 4",
            "counter must skip every occupied slot, not just the first two")
    }

    // MARK: - validateMove

    func test_validateMove_validFileToSubdir_allowed() {
        // Moving a file into a peer sibling directory is the normal happy path.
        let root = "/workspace"
        let src = "/workspace/file.txt"
        let dst = "/workspace/src"
        XCTAssertTrue(validateMove(src: src, dstDir: dst, workspaceRoot: root),
            "moving a file into a sibling directory inside the workspace must be allowed")
    }

    func test_validateMove_dirIntoItself_rejected() {
        // A directory cannot be its own destination - this would create an infinite loop in the
        // tree and is a fundamental filesystem invariant.
        let root = "/workspace"
        let src = "/workspace/src"
        XCTAssertFalse(validateMove(src: src, dstDir: src, workspaceRoot: root),
            "moving a directory into itself must be rejected to prevent a cycle")
    }

    func test_validateMove_dirIntoDirectDescendant_rejected() {
        // Moving `/workspace/src` into `/workspace/src/lib` would make `lib` an ancestor of
        // itself - the quintessential cycle case.
        let root = "/workspace"
        let src = "/workspace/src"
        let dst = "/workspace/src/lib"
        XCTAssertFalse(validateMove(src: src, dstDir: dst, workspaceRoot: root),
            "moving a directory into a direct child must be rejected")
    }

    func test_validateMove_dirIntoDeepDescendant_rejected() {
        // Same invariant across multiple nesting levels.
        let root = "/workspace"
        let src = "/workspace/src"
        let dst = "/workspace/src/a/b/c"
        XCTAssertFalse(validateMove(src: src, dstDir: dst, workspaceRoot: root),
            "moving a directory into a deeply nested descendant must be rejected")
    }

    func test_validateMove_srcEscapesWorkspace_rejected() {
        // Paths that resolve outside the workspace root must never be accepted - this is the
        // sandbox boundary check.
        let root = "/workspace"
        let src = "/other/file.txt"
        let dst = "/workspace/src"
        XCTAssertFalse(validateMove(src: src, dstDir: dst, workspaceRoot: root),
            "source outside the workspace must be rejected")
    }

    func test_validateMove_dstEscapesWorkspace_rejected() {
        let root = "/workspace"
        let src = "/workspace/file.txt"
        let dst = "/other/place"
        XCTAssertFalse(validateMove(src: src, dstDir: dst, workspaceRoot: root),
            "destination outside the workspace must be rejected")
    }

    func test_validateMove_intoWorkspaceRoot_allowed() {
        // Moving a nested file back to workspace root is a valid operation.
        let root = "/workspace"
        let src = "/workspace/src/file.txt"
        let dst = "/workspace"
        XCTAssertTrue(validateMove(src: src, dstDir: dst, workspaceRoot: root),
            "moving a file to the workspace root must be allowed")
    }

    func test_validateMove_peerDirectories_allowed() {
        // Moving /workspace/a into /workspace/b (peer, not ancestor/descendant) must be allowed.
        let root = "/workspace"
        let src = "/workspace/a"
        let dst = "/workspace/b"
        XCTAssertTrue(validateMove(src: src, dstDir: dst, workspaceRoot: root),
            "moving between peer directories must be allowed")
    }

    func test_validateMove_pathPrefixTrap_notConfusedBySharedPrefix() {
        // /workspace/src must NOT be treated as a descendant of /workspace/srclonger.
        // Without the trailing-slash check this would incorrectly reject the move.
        let root = "/workspace"
        let src = "/workspace/srclonger"
        let dst = "/workspace/src"
        XCTAssertTrue(validateMove(src: src, dstDir: dst, workspaceRoot: root),
            "a path that shares a prefix but is not a descendant must not be rejected")
    }
}
