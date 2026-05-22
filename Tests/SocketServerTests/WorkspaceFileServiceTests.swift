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
