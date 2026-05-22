import XCTest
@testable import Surfaces

final class FilePreviewSurfaceTests: XCTestCase {
    @MainActor func test_textPreviewReadsBoundedPrefixForLargeFiles() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-large-preview-\(UUID().uuidString).txt")
        try ("start\n" + String(repeating: "x", count: 128)).write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let text = FilePreviewSurface.previewText(path: file.path, maxBytes: 16)

        XCTAssertTrue(text.hasPrefix("start"), "file preview should show the beginning of a large text file")
        XCTAssertTrue(text.contains("preview truncated"), "file preview must not read an unbounded text file into the UI")
    }
}
