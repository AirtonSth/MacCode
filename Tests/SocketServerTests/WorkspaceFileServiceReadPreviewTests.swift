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

    // MARK: - Explicit maxBytes on large-file preview

    func testLargeFileAbsentMaxBytesKeepsPreviewHeadBytes() throws {
        // WHY: Absent max_bytes must keep the deployed large-file preview contract so
        // existing clients still receive the full previewHeadBytes head, not a silent
        // zero or an unbounded full-file read over the weak link.
        let size = WorkspaceFileLimits.previewThresholdBytes + 1024
        _ = try makeTextFile(name: "absent-cap.txt", byteCount: size)

        let result = try service.read(root: root.path, path: "absent-cap.txt", maxBytes: nil)
        let obj = try XCTUnwrap(result.objectValue)
        let content = try XCTUnwrap(obj["content"]?.stringValue)

        XCTAssertTrue(obj["preview"]?.boolValue == true,
                      "large file without maxBytes must still use the preview path")
        XCTAssertTrue(obj["truncated"]?.boolValue == true,
                      "large-file preview without maxBytes must remain truncated")
        XCTAssertEqual(content.utf8.count, WorkspaceFileLimits.previewHeadBytes,
                       "absent maxBytes must return the full preview head so behavior matches production")
    }

    func testLargeFileMaxBytesOneCapsRawContentToOneByte() throws {
        // WHY: iOS request budgets send max_bytes as a hard weak-link ceiling. Ignoring
        // it on the preview path used to return ~32 KiB for max_bytes:1, blowing the budget.
        let size = WorkspaceFileLimits.previewThresholdBytes + 2048
        _ = try makeTextFile(name: "max-one.txt", byteCount: size, byte: 0x42) // 'B'

        let result = try service.read(root: root.path, path: "max-one.txt", maxBytes: 1)
        let obj = try XCTUnwrap(result.objectValue)
        let content = try XCTUnwrap(obj["content"]?.stringValue)

        XCTAssertTrue(obj["preview"]?.boolValue == true,
                      "large file must stay on the preview path when maxBytes is set")
        XCTAssertTrue(obj["truncated"]?.boolValue == true,
                      "max_bytes smaller than the file must mark truncated so clients know content is incomplete")
        XCTAssertLessThanOrEqual(content.utf8.count, 1,
                                 "explicit max_bytes:1 must cap raw/ASCII content to at most one byte")
        XCTAssertEqual(content, "B",
                       "the single returned byte must be the file head so callers still see a useful sample")
    }

    func testLargeFileMaxBytesZeroReturnsEmptyTruncated() throws {
        // WHY: max_bytes:0 is the existing small-file "empty budget" signal; the large-file
        // preview path must match so agents can request metadata without payload bytes.
        let size = WorkspaceFileLimits.previewThresholdBytes + 4096
        _ = try makeTextFile(name: "max-zero.txt", byteCount: size)

        let result = try service.read(root: root.path, path: "max-zero.txt", maxBytes: 0)
        let obj = try XCTUnwrap(result.objectValue)
        let content = try XCTUnwrap(obj["content"]?.stringValue)

        XCTAssertTrue(obj["preview"]?.boolValue == true,
                      "large file with max_bytes:0 must still be classified as preview")
        XCTAssertTrue(obj["truncated"]?.boolValue == true,
                      "max_bytes:0 on a non-empty large text file must report truncated like the small-file path")
        XCTAssertEqual(content, "",
                       "max_bytes:0 must return empty content so the weak link carries no body bytes")
        XCTAssertEqual(content.utf8.count, 0,
                       "empty content must mean zero raw UTF-8 bytes, not a whitespace placeholder")
    }
}
