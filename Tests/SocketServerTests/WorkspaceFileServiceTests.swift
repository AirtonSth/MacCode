import XCTest
import CoreModel
@testable import SocketServer

final class WorkspaceFileServiceTests: XCTestCase {
    private var root: URL!
    private let service = WorkspaceFileService()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc2-files-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testListReturnsRelativeParentPathInsideWorkspace() throws {
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)

        let listed = try service.list(root: root.path, path: "Sources")

        XCTAssertEqual(listed.objectValue?["parent_path"]?.stringValue, "",
                       "Files navigation must return workspace-relative parent paths so macOS and iOS do not navigate by absolute host paths")
    }

    func testListRelativePathsStayWorkspaceRelativeWhenTmpRootIsSymlinked() throws {
        let tmpRootPath = "/tmp/rc2-files-symlink-\(UUID().uuidString)"
        let tmpRoot = URL(fileURLWithPath: tmpRootPath, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        try "print(\"nested\")".write(to: tmpRoot.appendingPathComponent("src/nested.swift"), atomically: true, encoding: .utf8)

        let rootList = try service.list(root: tmpRootPath, path: nil)
        let rootEntries = try XCTUnwrap(rootList.objectValue?["entries"]?.arrayValue)
        let srcEntry = try XCTUnwrap(rootEntries.first { $0.objectValue?["name"]?.stringValue == "src" })
        XCTAssertEqual(srcEntry.objectValue?["relative_path"]?.stringValue, "src",
                       "Files rows must keep workspace-relative paths even when macOS reports /tmp children through /private/tmp")

        let srcList = try service.list(root: tmpRootPath, path: "src")
        XCTAssertEqual(srcList.objectValue?["relative_path"]?.stringValue, "src",
                       "expanded folders must round-trip the same workspace-relative path the UI sends back")
        XCTAssertEqual(srcList.objectValue?["parent_path"]?.stringValue, "",
                       "expanded folder breadcrumbs must not inherit /private/tmp path fragments")
        let srcEntries = try XCTUnwrap(srcList.objectValue?["entries"]?.arrayValue)
        let nested = try XCTUnwrap(srcEntries.first { $0.objectValue?["name"]?.stringValue == "nested.swift" })
        XCTAssertEqual(nested.objectValue?["relative_path"]?.stringValue, "src/nested.swift",
                       "nested file selection must open the intended file instead of a corrupted path such as rkspace/src/nested.swift")
    }

    func testSvgIsPreviewMediaNotEditableText() throws {
        let svg = root.appendingPathComponent("logo.svg")
        try "<svg><text>RemoteCode</text></svg>".write(to: svg, atomically: true, encoding: .utf8)

        let read = try service.read(root: root.path, path: "logo.svg")
        let identity = try XCTUnwrap(read.objectValue?["identity"]?.objectValue)

        XCTAssertEqual(identity["kind"]?.stringValue, "image",
                       "media extensions such as SVG must use pretty preview classification instead of becoming editable plain text")
        XCTAssertNil(read.objectValue?["content"]?.stringValue,
                     "known media binaries/text containers must not be decoded into the source editor by default")
    }

    func testUTF16TextWithoutBOMCanBeReadForEditing() throws {
        let file = root.appendingPathComponent("notes.txt")
        let text = "hello from utf16"
        try XCTUnwrap(text.data(using: .utf16LittleEndian)).write(to: file)

        let read = try service.read(root: root.path, path: "notes.txt")

        XCTAssertEqual(read.objectValue?["content"]?.stringValue, text,
                       "safe UTF-16 text without a BOM must still be readable/editable instead of being treated as unknown binary")
        XCTAssertEqual(read.objectValue?["encoding"]?.stringValue, "utf-16le")
    }

    func testUnknownBinaryIsNotDecodedAsText() throws {
        let file = root.appendingPathComponent("archive.bin")
        try Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00, 0x00, 0x00]).write(to: file)

        let read = try service.read(root: root.path, path: "archive.bin")
        let identity = try XCTUnwrap(read.objectValue?["identity"]?.objectValue)

        XCTAssertEqual(identity["kind"]?.stringValue, "binary")
        XCTAssertNil(read.objectValue?["content"]?.stringValue,
                     "unknown binary files must show metadata only; decoding arbitrary bytes can corrupt the reader and editor")
    }

    func testCreateRenameAndDeleteStayInsideWorkspaceForFilesSidebarActions() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)

        let created = try service.createFile(root: root.path, path: "Sources/NewFile.swift", content: "")
        let createdPath = try XCTUnwrap(created.objectValue?["relative_path"]?.stringValue)
        XCTAssertEqual(createdPath, "Sources/NewFile.swift",
                       "the Files sidebar add-file action must create the exact workspace-relative file the user requested")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(createdPath).path))

        let renamed = try service.rename(root: root.path, path: "Sources/NewFile.swift", newName: "Renamed.swift")
        XCTAssertEqual(renamed.objectValue?["relative_path"]?.stringValue, "Sources/Renamed.swift",
                       "rename must keep the file in its current directory instead of allowing path injection")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/NewFile.swift").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/Renamed.swift").path))

        _ = try service.createFile(root: root.path, path: "Sources/DeleteMe.swift", content: "")
        let deleted = try service.delete(root: root.path, paths: ["Sources/Renamed.swift", "Sources/DeleteMe.swift"])
        XCTAssertEqual(deleted.objectValue?["deleted"]?.arrayValue?.compactMap(\.stringValue).sorted(),
                       ["Sources/DeleteMe.swift", "Sources/Renamed.swift"],
                       "multi-select delete must remove every selected workspace-relative file in one host operation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/Renamed.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/DeleteMe.swift").path))
    }

    func testFilesSidebarMutationsRejectEscapingAndOverwritePaths() throws {
        try service.createFile(root: root.path, path: "keep.txt", content: "")

        XCTAssertThrowsError(try service.createFile(root: root.path, path: "../escape.txt", content: ""),
                             "add-file must not write outside the workspace root")
        XCTAssertThrowsError(try service.rename(root: root.path, path: "keep.txt", newName: "../escape.txt"),
                             "rename from the Files context menu must reject names that escape the current directory")
        XCTAssertThrowsError(try service.rename(root: root.path, path: "keep.txt", newName: "keep.txt"),
                             "rename must not overwrite an existing workspace path silently")
        XCTAssertThrowsError(try service.delete(root: root.path, paths: [""]),
                             "bulk delete must not allow deleting the workspace root")
    }

    func testListUsesExtensionClassificationAndDoesNotReadFileBytes() throws {
        // Write a .swift file that contains raw binary bytes so content-based
        // classification would disagree with the extension. Listing must return
        // the extension-derived kind ("code") and must NOT read the bytes -- which
        // is verified by confirming the kind matches the extension, not the content.
        let swiftFile = root.appendingPathComponent("Main.swift")
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]).write(to: swiftFile) // JPEG magic bytes

        let listed = try service.list(root: root.path, path: nil)
        let entries = try XCTUnwrap(listed.objectValue?["entries"]?.arrayValue)
        let entry = try XCTUnwrap(entries.first(where: { $0.objectValue?["name"]?.stringValue == "Main.swift" }))
        let identity = try XCTUnwrap(entry.objectValue?["identity"]?.objectValue)

        XCTAssertEqual(identity["kind"]?.stringValue, "code",
                       "listing must classify by extension only; reading file bytes in a directory listing is wasteful and must not occur")
        XCTAssertEqual(identity["language"]?.stringValue, "swift",
                       "language must be derived from the file extension without reading content")
    }

    func testListIdentitySchemaMatchesAllConsumerFields() throws {
        // FilesSurface consumes kind, mime, is_editable, editability_reason, language.
        // All must be present in listing entries so the sidebar can render without a
        // second round-trip to read the file.
        let file = root.appendingPathComponent("readme.md")
        try "# hello".write(to: file, atomically: true, encoding: .utf8)

        let listed = try service.list(root: root.path, path: nil)
        let entries = try XCTUnwrap(listed.objectValue?["entries"]?.arrayValue)
        let entry = try XCTUnwrap(entries.first(where: { $0.objectValue?["name"]?.stringValue == "readme.md" }))
        let identity = try XCTUnwrap(entry.objectValue?["identity"]?.objectValue)

        XCTAssertNotNil(identity["kind"]?.stringValue, "FilesSurface requires identity.kind in listing")
        XCTAssertNotNil(identity["mime"]?.stringValue, "FilesSurface requires identity.mime in listing")
        XCTAssertNotNil(identity["is_editable"], "FilesSurface requires identity.is_editable in listing")
        XCTAssertNotNil(identity["editability_reason"]?.stringValue, "FilesSurface requires identity.editability_reason in listing")
        // language is optional for md but the key must be present (null is valid)
        XCTAssertTrue(identity.keys.contains("language"), "FilesSurface reads identity.language; key must exist in listing entries")
    }

    func testEditSaveRejectsExternallyGrownFileBeforeReadingWholeFile() throws {
        let file = root.appendingPathComponent("notes.txt")
        try "small".write(to: file, atomically: true, encoding: .utf8)
        let opened = try FileEditSessionStore.shared.open(
            surfaceID: SurfaceID(),
            workspaceID: WorkspaceID(),
            root: root.path,
            path: "notes.txt"
        )
        let sessionID = try XCTUnwrap(opened.objectValue?["session_id"]?.stringValue)
        defer { _ = try? FileEditSessionStore.shared.close(sessionID: sessionID) }

        try Data(repeating: 0x61, count: WorkspaceFileLimits.editBytes + 1).write(to: file)

        XCTAssertThrowsError(try FileEditSessionStore.shared.save(sessionID: sessionID),
                             "save conflict checks must not read an externally-grown file without the edit size cap")
    }
}
