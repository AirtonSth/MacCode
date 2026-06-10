import XCTest
@testable import SocketServer

/// Tests for the read-strategy helper and the preview path in WorkspaceFileService.read().
///
/// Business rule: files larger than previewThresholdBytes must not be fully buffered
/// into a JSONValue.string; instead, a head preview with a truncated marker is returned
/// so that large files do not cause unnecessary memory pressure on the host process.
final class WorkspaceFileServiceReadPreviewTests: XCTestCase {

    // MARK: - Pure helper: readStrategy(fileSize:cap:headBytes:)

    func testReadStrategyUnderCapReturnsFull() {
        // A file whose size equals or is below the threshold must be read in full
        // so that small files continue to deliver complete content.
        let result = readStrategy(fileSize: 100, cap: 1000)
        XCTAssertEqual(result, .full,
                       "fileSize 100 <= cap 1000 must yield .full so small files are not downgraded to preview")
    }

    func testReadStrategyAtExactCapReturnsFull() {
        // Boundary: size == cap is not "over" the threshold, so full read applies.
        let cap: Int64 = 512 * 1024
        let result = readStrategy(fileSize: cap, cap: cap)
        XCTAssertEqual(result, .full,
                       "fileSize exactly at cap must yield .full; preview applies only when fileSize > cap")
    }

    func testReadStrategyOverCapReturnsPreview() {
        // A file one byte over the threshold must switch to preview mode.
        let cap: Int64 = 512 * 1024
        let result = readStrategy(fileSize: cap + 1, cap: cap)
        XCTAssertEqual(result, .preview(headBytes: WorkspaceFileLimits.previewHeadBytes),
                       "fileSize one byte over cap must yield .preview to avoid buffering the whole file")
    }

    func testReadStrategyPreviewHeadBytesUsesDefault() {
        // When headBytes is omitted the default from WorkspaceFileLimits is used.
        let result = readStrategy(fileSize: 999_999, cap: 1)
        if case .preview(let h) = result {
            XCTAssertEqual(h, WorkspaceFileLimits.previewHeadBytes,
                           "default headBytes must equal WorkspaceFileLimits.previewHeadBytes so all callers agree on head size")
        } else {
            XCTFail("expected .preview for fileSize >> cap")
        }
    }

    func testReadStrategyCustomHeadBytes() {
        // A caller may override headBytes; the strategy must honour it.
        let result = readStrategy(fileSize: 10_000, cap: 1, headBytes: 4096)
        XCTAssertEqual(result, .preview(headBytes: 4096),
                       "custom headBytes must be forwarded so callers can tune the preview size independently")
    }

    // MARK: - WorkspaceFileService.read() integration

    private var root: URL!
    private let service = WorkspaceFileService()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc2-preview-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makeTextFile(name: String, byteCount: Int, byte: UInt8 = 0x41) throws -> URL {
        // 0x41 = 'A'; valid ASCII / UTF-8 so decodeText succeeds.
        let url = root.appendingPathComponent(name)
        try Data(repeating: byte, count: byteCount).write(to: url)
        return url
    }

    func testSmallFileReturnsFullContentAndNoPreviewFlag() throws {
        // A file under the threshold must deliver complete content without any
        // preview degradation, preserving the original read contract.
        let size = WorkspaceFileLimits.previewThresholdBytes / 2
        _ = try makeTextFile(name: "small.txt", byteCount: size)

        let result = try service.read(root: root.path, path: "small.txt")
        let obj = try XCTUnwrap(result.objectValue)

        XCTAssertFalse(obj["truncated"]?.boolValue == true,
                       "small file must not be marked truncated")
        XCTAssertFalse(obj["preview"]?.boolValue == true,
                       "small file must not be marked as preview")
        let content = try XCTUnwrap(obj["content"]?.stringValue)
        XCTAssertEqual(content.utf8.count, size,
                       "small file content length must equal the written byte count so callers receive all data")
    }

    func testLargeFileReturnsPreviewWithTruncatedTrue() throws {
        // A file exceeding previewThresholdBytes must NOT buffer the whole file.
        // The response must be marked truncated and preview = true so clients
        // know to offer a "load more" or chunked-read action instead of silently
        // showing incomplete content.
        let size = WorkspaceFileLimits.previewThresholdBytes + 1024
        _ = try makeTextFile(name: "large.txt", byteCount: size)

        let result = try service.read(root: root.path, path: "large.txt")
        let obj = try XCTUnwrap(result.objectValue)

        XCTAssertTrue(obj["truncated"]?.boolValue == true,
                      "large file must be marked truncated so clients know content is incomplete")
        XCTAssertTrue(obj["preview"]?.boolValue == true,
                      "large file must be marked preview so clients can distinguish preview from a maxBytes truncation")
    }

    func testLargeFilePreviewHeadIsAtMostPreviewHeadBytes() throws {
        // The preview head must not exceed previewHeadBytes so memory usage is bounded.
        let size = WorkspaceFileLimits.previewThresholdBytes + 64 * 1024
        _ = try makeTextFile(name: "bigfile.txt", byteCount: size)

        let result = try service.read(root: root.path, path: "bigfile.txt")
        let obj = try XCTUnwrap(result.objectValue)
        let content = try XCTUnwrap(obj["content"]?.stringValue)

        XCTAssertLessThanOrEqual(content.utf8.count, WorkspaceFileLimits.previewHeadBytes,
                                 "preview content must be capped at previewHeadBytes to bound host memory usage")
    }

    func testLargeFileReportsTotalSizeNotPreviewSize() throws {
        // The "size" field must reflect the actual file size, not the head byte count,
        // so clients can display "showing first N KB of M MB" without a second stat call.
        let totalSize = WorkspaceFileLimits.previewThresholdBytes + 1024
        _ = try makeTextFile(name: "sized.txt", byteCount: totalSize)

        let result = try service.read(root: root.path, path: "sized.txt")
        let obj = try XCTUnwrap(result.objectValue)

        guard case .number(let reportedSize) = obj["size"] else {
            XCTFail("size field must be a JSON number")
            return
        }
        XCTAssertEqual(Int(reportedSize), totalSize,
                       "size field must reflect the full file size, not the preview head length")
    }

    func testFileAtExactThresholdIsReadInFull() throws {
        // A file whose byte count equals the threshold exactly must be read in full.
        // This confirms the boundary condition: > threshold triggers preview, == does not.
        let size = WorkspaceFileLimits.previewThresholdBytes
        _ = try makeTextFile(name: "boundary.txt", byteCount: size)

        let result = try service.read(root: root.path, path: "boundary.txt")
        let obj = try XCTUnwrap(result.objectValue)

        XCTAssertFalse(obj["preview"]?.boolValue == true,
                       "file at exact threshold byte count must not be downgraded to preview")
        let content = try XCTUnwrap(obj["content"]?.stringValue)
        XCTAssertEqual(content.utf8.count, size,
                       "file at exact threshold must deliver all bytes so the boundary is consistent with the helper")
    }
}
