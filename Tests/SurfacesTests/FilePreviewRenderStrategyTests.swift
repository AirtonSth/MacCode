import XCTest
@testable import Surfaces

// Tests for FilePreviewSurface.renderStrategy(for:).
// All tests are pure (no AppKit state); @MainActor NOT required.
// Rule 8: each assertion encodes WHY the strategy matters - wrong strategy
// means the wrong renderer fires (QLPreviewView vs native widget).
final class FilePreviewRenderStrategyTests: XCTestCase {

    // MARK: - Native image types

    func test_imageExtensions_returnNative() {
        let imageExts = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "heic", "webp"]
        for ext in imageExts {
            XCTAssertEqual(
                FilePreviewSurface.renderStrategy(for: ext), .native,
                "'\(ext)' must use native image renderer, not QLPreviewView"
            )
        }
    }

    // MARK: - Native PDF

    func test_pdf_returnsNative() {
        // PDF has a first-class PDFView renderer with page-restore; QL would lose that.
        XCTAssertEqual(FilePreviewSurface.renderStrategy(for: "pdf"), .native)
    }

    // MARK: - Native text/code extensions

    func test_textAndCodeExtensions_returnNative() {
        let textExts = [
            "txt", "md", "swift", "py", "js", "ts", "json",
            "yaml", "yml", "sh", "rb", "go", "rs", "c", "cpp",
            "h", "java", "kt", "cs", "html", "css", "xml",
            "toml", "ini", "log"
        ]
        for ext in textExts {
            XCTAssertEqual(
                FilePreviewSurface.renderStrategy(for: ext), .native,
                "'\(ext)' must use native text renderer with find-bar support"
            )
        }
    }

    // MARK: - QuickLook fallback types

    func test_keynote_returnsQuickLook() {
        // .key cannot be rendered by any native renderer; QL provides free preview.
        XCTAssertEqual(FilePreviewSurface.renderStrategy(for: "key"), .quicklook)
    }

    func test_zip_returnsQuickLook() {
        // Archives have no native renderer; QL lists archive contents.
        XCTAssertEqual(FilePreviewSurface.renderStrategy(for: "zip"), .quicklook)
    }

    func test_mp3_returnsQuickLook() {
        // Audio files have no native renderer; QL provides playback UI.
        XCTAssertEqual(FilePreviewSurface.renderStrategy(for: "mp3"), .quicklook)
    }

    func test_mp4_returnsQuickLook() {
        XCTAssertEqual(FilePreviewSurface.renderStrategy(for: "mp4"), .quicklook)
    }

    func test_pages_returnsQuickLook() {
        XCTAssertEqual(FilePreviewSurface.renderStrategy(for: "pages"), .quicklook)
    }

    func test_numbers_returnsQuickLook() {
        XCTAssertEqual(FilePreviewSurface.renderStrategy(for: "numbers"), .quicklook)
    }

    func test_docx_returnsQuickLook() {
        XCTAssertEqual(FilePreviewSurface.renderStrategy(for: "docx"), .quicklook)
    }

    func test_unknownExtension_returnsQuickLook() {
        // Any unrecognized extension must fall back to QL rather than showing
        // a binary-blob text dump, which would be unreadable and confusing.
        XCTAssertEqual(FilePreviewSurface.renderStrategy(for: "xyz123"), .quicklook)
    }

    func test_emptyExtension_returnsQuickLook() {
        // Files with no extension (e.g. Makefile, Dockerfile) that are not in
        // the native set fall back to QL. An empty string is not a native key.
        XCTAssertEqual(FilePreviewSurface.renderStrategy(for: ""), .quicklook)
    }

    // MARK: - Case-insensitivity

    func test_uppercaseExtension_PNG_returnsNative() {
        // macOS filesystems are case-insensitive; extension case must not matter.
        XCTAssertEqual(FilePreviewSurface.renderStrategy(for: "PNG"), .native)
    }

    func test_uppercaseExtension_KEY_returnsQuickLook() {
        XCTAssertEqual(FilePreviewSurface.renderStrategy(for: "KEY"), .quicklook)
    }

    func test_mixedCaseExtension_Pdf_returnsNative() {
        XCTAssertEqual(FilePreviewSurface.renderStrategy(for: "Pdf"), .native)
    }

    func test_mixedCaseExtension_Mp3_returnsQuickLook() {
        XCTAssertEqual(FilePreviewSurface.renderStrategy(for: "Mp3"), .quicklook)
    }
}
