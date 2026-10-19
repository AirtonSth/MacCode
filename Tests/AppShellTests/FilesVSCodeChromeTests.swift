import XCTest
@testable import AppShell
import CoreModel
import SocketServer

/// Pure helpers behind the VS Code-style Files chrome: icon colors, status bar language
/// label, caret math, and the explorer collapse-all action.
@MainActor
final class FilesVSCodeChromeTests: XCTestCase {
    private enum StubError: Error { case unused }

    /// Router that fails every call. `collapseAll()` never touches the router.
    private final class StubRouter: FilesSurfaceRouting {
        func filesEditClose(sessionID: String) throws -> JSONValue { throw StubError.unused }
        func filesStateGet(surface: SurfaceID) throws -> JSONValue { throw StubError.unused }
        func fsWorkspaceList(workspace: WorkspaceID, path: String?) throws -> JSONValue { throw StubError.unused }
        func filesStateUpdate(surface: SurfaceID, patch: [String: JSONValue], baseRevision: Int?, deviceID: String?) throws -> JSONValue { throw StubError.unused }
        func filesEditOpen(surface: SurfaceID, path: String) throws -> JSONValue { throw StubError.unused }
        func fsWorkspaceRead(workspace: WorkspaceID, path: String, maxBytes: Int?) throws -> JSONValue { throw StubError.unused }
        func filesEditSave(sessionID: String) throws -> JSONValue { throw StubError.unused }
        func filesEditDiscard(sessionID: String) throws -> JSONValue { throw StubError.unused }
        func fsWorkspaceCreateFile(workspace: WorkspaceID, path: String, content: String) throws -> JSONValue { throw StubError.unused }
        func fsWorkspaceCreateDirectory(workspace: WorkspaceID, path: String) throws -> JSONValue { throw StubError.unused }
        func fsWorkspaceMoveItem(workspace: WorkspaceID, sourcePath: String, destinationDirectoryPath: String) throws -> JSONValue { throw StubError.unused }
        func fsWorkspaceRename(workspace: WorkspaceID, path: String, newName: String) throws -> JSONValue { throw StubError.unused }
        func filesOpenTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, path: String) throws -> SurfaceDescriptor { throw StubError.unused }
        func filesSplitTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, direction: SplitDirection, path: String) throws -> SurfaceDescriptor { throw StubError.unused }
        func filesEditApplyPatch(sessionID: String, baseDraftRevision: Int, rangeLocation: Int, rangeLength: Int, replacement: String, deviceID: String?) throws -> JSONValue { throw StubError.unused }
    }

    // Swift and TypeScript must not share a color, or the explorer cannot tell them apart.
    func test_fileIconColorHex_swiftAndTypescriptDiffer() {
        XCTAssertNotEqual(fileIconColorHex(for: "A.swift"), fileIconColorHex(for: "a.ts"),
            "swift and ts icons must differ so file types are distinguishable in the explorer")
    }

    // Unknown extensions fall back to the neutral gray, never a random accent.
    func test_fileIconColorHex_unknownUsesDefaultGray() {
        XCTAssertEqual(fileIconColorHex(for: "notes.xyz"), 0x9D9D9D,
            "unknown extensions must use the VS Code default gray so they look neutral")
    }

    // Extension matching is case-insensitive, so README.SWIFT gets the same icon as main.swift.
    func test_fileIconColorHex_isCaseInsensitive() {
        XCTAssertEqual(fileIconColorHex(for: "MAIN.SWIFT"), fileIconColorHex(for: "main.swift"),
            "extension lookup must ignore case so upper-case files keep their type color")
    }

    func test_languageDisplayName_mapsKnownIds() {
        XCTAssertEqual(languageDisplayName("swift"), "Swift",
            "status bar must show the human name, not the raw language id")
        XCTAssertEqual(languageDisplayName("typescript"), "TypeScript",
            "status bar must show TypeScript with its canonical capitalization")
    }

    func test_languageDisplayName_nilIsPlainText() {
        XCTAssertEqual(languageDisplayName(nil), "Plain Text",
            "a file with no language must read as Plain Text in the status bar")
    }

    // Caret math must use 1-based lines and columns, matching the Ln/Col status label.
    func test_caretLineColumn_secondLineStart() {
        let result = caretLineColumn(text: "ab\ncd", utf16Offset: 4)
        XCTAssertEqual(result.line, 2, "offset 4 is on line 2 of \"ab\\ncd\"")
        XCTAssertEqual(result.column, 2, "offset 4 is the second column of line 2")
    }

    func test_caretLineColumn_documentStart() {
        let result = caretLineColumn(text: "ab\ncd", utf16Offset: 0)
        XCTAssertEqual(result.line, 1, "offset 0 must map to line 1, not a zero-based index")
        XCTAssertEqual(result.column, 1, "offset 0 must map to column 1, not a zero-based index")
    }

    // Collapse-all must clear every expanded folder, so the tree returns to its flat root view.
    func test_collapseAll_clearsExpandedPaths() {
        let model = FilesViewModel(
            surfaceID: SurfaceID(),
            workspaceID: WorkspaceID(),
            root: "/workspace",
            router: StubRouter()
        )
        defer { model.close() }
        model.expandedPaths = ["src", "src/app"]

        model.collapseAll()

        XCTAssertTrue(model.expandedPaths.isEmpty,
            "collapse-all must clear every expanded folder so the explorer returns to a flat view")
    }
}
