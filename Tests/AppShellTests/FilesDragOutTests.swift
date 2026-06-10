import XCTest
@testable import AppShell

/// Tests for the `fileOutDragInfo(absolutePath:)` pure helper introduced for P3 drag-file-out.
///
/// WHY these tests matter:
///  - `fileOutDragInfo` is the single place that maps a sidebar row to the URL and filename
///    placed on the drag pasteboard / NSFilePromiseProvider. If the URL is wrong, Finder receives
///    a reference to a non-existent path; if the filename is wrong, the receiving app shows a
///    misleading name. Both fields must be derived from the absolute path that the server provides.
///  - Keeping this logic in a pure helper (no AppKit, no MainActor) lets us assert the exact
///    URL and filename without running AppKit or constructing a real FileEntry.
final class FilesDragOutTests: XCTestCase {

    // MARK: - File rows

    func test_fileOutDragInfo_file_absoluteURLMatchesPath() {
        // WHY: the URL written to the pasteboard must point at the exact absolute path stored on
        // FileEntry.path; any deviation would make the drag promise reference a missing file.
        let info = fileOutDragInfo(absolutePath: "/Users/sam/workspace/README.md")
        XCTAssertEqual(info.absoluteURL.path, "/Users/sam/workspace/README.md",
            "absolute URL path must equal the input absolute path for files")
    }

    func test_fileOutDragInfo_file_isFileURL() {
        // WHY: NSFilePromiseProvider and NSPasteboard expect a file:// URL; a non-file URL would
        // silently produce a broken drag-accept on the receiving app (e.g. Finder ignores it).
        let info = fileOutDragInfo(absolutePath: "/Users/sam/workspace/main.swift")
        XCTAssertTrue(info.absoluteURL.isFileURL,
            "dragged file URL must be a file:// URL so Finder and other apps can accept the drop")
    }

    func test_fileOutDragInfo_file_promiseFilenameIsLastComponent() {
        // WHY: NSFilePromiseProvider.filePromiseProvider(_:fileNameForType:) returns this name;
        // the receiving app uses it as the saved filename. It must match the entry's own name,
        // not the full path, so the file appears with the correct short name at the destination.
        let info = fileOutDragInfo(absolutePath: "/Users/sam/workspace/src/App.swift")
        XCTAssertEqual(info.promiseFilename, "App.swift",
            "promise filename must be the last path component, not the full path")
    }

    // MARK: - Directory rows

    func test_fileOutDragInfo_directory_absoluteURLMatchesPath() {
        // WHY: directories can also be dragged out to Finder (e.g. drag a folder to Desktop).
        // The URL must point at the directory itself, not its parent or a made-up path.
        let info = fileOutDragInfo(absolutePath: "/Users/sam/workspace/src")
        XCTAssertEqual(info.absoluteURL.path, "/Users/sam/workspace/src",
            "absolute URL path must equal the input absolute path for directories")
    }

    func test_fileOutDragInfo_directory_promiseFilenameIsDirectoryName() {
        // WHY: when Finder accepts a directory drag, it uses the promise filename as the item
        // name shown in copy/move sheets. It must be the directory name, not a path fragment.
        let info = fileOutDragInfo(absolutePath: "/Users/sam/workspace/components")
        XCTAssertEqual(info.promiseFilename, "components",
            "promise filename for a directory must be the directory name (last path component)")
    }

    // MARK: - Edge cases

    func test_fileOutDragInfo_deepNestedFile_correctURL() {
        // WHY: deeply nested files are common in real workspaces; the URL must carry the full
        // absolute path unchanged regardless of nesting depth.
        let path = "/home/dev/project/src/a/b/c/d/e/types.ts"
        let info = fileOutDragInfo(absolutePath: path)
        XCTAssertEqual(info.absoluteURL.path, path,
            "URL path must be preserved verbatim for deeply nested files")
        XCTAssertEqual(info.promiseFilename, "types.ts",
            "filename must be last component even for deeply nested paths")
    }

    func test_fileOutDragInfo_pathWithSpaces_escapedCorrectly() {
        // WHY: workspaces and filenames with spaces are common on macOS (e.g. "My Project").
        // URL(fileURLWithPath:) must encode spaces so the resulting URL is valid for pasteboard
        // use; the promise filename must still be the human-readable name with spaces intact.
        let info = fileOutDragInfo(absolutePath: "/Users/sam/My Project/Notes Draft.md")
        XCTAssertEqual(info.absoluteURL.path, "/Users/sam/My Project/Notes Draft.md",
            "URL.path must round-trip path with spaces correctly")
        XCTAssertEqual(info.promiseFilename, "Notes Draft.md",
            "filename must preserve spaces so the receiving app shows a readable name")
    }
}
