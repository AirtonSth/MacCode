import XCTest
@testable import Surfaces

/// Tests for the P2 PDF-nil error state: verifies the preconditions that route
/// `renderPDF` into the `showPDFError` branch.
///
/// WHY these tests matter:
///  - Before this fix, `PDFDocument(url:)` returning nil (corrupt file, wrong MIME, etc.)
///    left the preview pane silently blank. Users had no indication the file failed to load.
///    The fix adds a `showPDFError(over:)` overlay; tests here pin the routing invariants
///    that make the error overlay reachable.
///  - Separate focused classes so the responsibility is clear and any future move
///    of `showPDFError` to a different type is caught immediately.

// MARK: - FilePreviewPDFErrorTests: renderStrategy routing invariant for PDF

// MARK: - PDF must be routed to native renderer for the error overlay to fire

/// Extra targeted test: verifies the precondition for showPDFError.
/// WHY: if PDF were routed to .quicklook the PDFDocument(url:) call would never
/// execute and `showPDFError` would be unreachable, silently hiding corrupt-PDF errors.
final class FilePreviewPDFRoutingTests: XCTestCase {

    func test_renderStrategy_pdf_mustBeNative_forErrorOverlayPath() {
        // WHY: showPDFError is only reachable through the .native branch.
        // If this assertion ever fails, corrupt PDFs will silently show a blank pane.
        XCTAssertEqual(FilePreviewSurface.renderStrategy(for: "pdf"), .native,
            "PDF must use .native renderer so the PDFDocument nil-check and error overlay are reachable")
    }

    func test_renderStrategy_PDFUppercase_mustBeNative() {
        // WHY: file extensions from the OS may be uppercase; normalization must happen
        // before the lookup so uppercase PDF is not accidentally routed to quicklook.
        XCTAssertEqual(FilePreviewSurface.renderStrategy(for: "PDF"), .native,
            "uppercase PDF extension must also use .native renderer")
    }
}
