import XCTest
@testable import Surfaces

// Tests for FilePreviewScrollCache -- pure value type, no AppKit, no MainActor needed.
// Rule 8: each test encodes WHY the behavior matters, not just what it does.
final class FilePreviewScrollCacheTests: XCTestCase {

    // MARK: - store + retrieve

    func test_storeAndRetrieve_preservesScrollOffset() {
        // WHY: hide tears down the view; restore on visible must land at the exact saved Y offset,
        //      not silently reset to zero (which would break the user's reading position).
        var cache = FilePreviewScrollCache()
        let entry = FilePreviewScrollCache.Entry(scrollOffsetY: 450.5, pdfPageIndex: 0)
        cache.store(path: "/a/file.txt", entry: entry)

        let got = cache.entry(for: "/a/file.txt")

        XCTAssertEqual(got.scrollOffsetY, 450.5, accuracy: 0.001,
            "Stored scroll offset must survive a cache round-trip -- loss causes scroll reset on re-show")
        XCTAssertEqual(got.pdfPageIndex, 0,
            "PDF page must not be contaminated when only scrollOffsetY was set")
    }

    func test_storeAndRetrieve_preservesPDFPage() {
        // WHY: PDF viewers in split layouts show page N; hide/show must reopen at page N,
        //      not page 0 -- which forces the user to manually navigate back.
        var cache = FilePreviewScrollCache()
        let entry = FilePreviewScrollCache.Entry(scrollOffsetY: 0, pdfPageIndex: 7)
        cache.store(path: "/docs/report.pdf", entry: entry)

        let got = cache.entry(for: "/docs/report.pdf")

        XCTAssertEqual(got.pdfPageIndex, 7,
            "PDF page index must survive a cache round-trip -- loss resets to page 0 on re-show")
    }

    // MARK: - missing key returns defaults

    func test_missingPath_returnsDefaultEntry() {
        // WHY: the first time a file is shown there is no saved state; returning (0,0)
        //      means \"do not restore\" and the renderText/renderPDF guards skip the scroll call.
        //      A non-zero default would scroll a fresh view to an arbitrary position.
        let cache = FilePreviewScrollCache()
        let got = cache.entry(for: "/never/seen.txt")

        XCTAssertEqual(got.scrollOffsetY, 0,
            "Unknown path must return scrollOffsetY==0 so renderText does not attempt to restore")
        XCTAssertEqual(got.pdfPageIndex, 0,
            "Unknown path must return pdfPageIndex==0 so renderPDF skips the go(to:) call")
    }

    // MARK: - distinct paths are isolated

    func test_distinctPaths_doNotCrossContaminate() {
        // WHY: a split layout can show file A on left and file B on right simultaneously;
        //      hiding file A must not overwrite file B's cached state.
        var cache = FilePreviewScrollCache()
        cache.store(path: "/src/alpha.txt", entry: .init(scrollOffsetY: 100, pdfPageIndex: 0))
        cache.store(path: "/src/beta.txt",  entry: .init(scrollOffsetY: 200, pdfPageIndex: 0))

        XCTAssertEqual(cache.entry(for: "/src/alpha.txt").scrollOffsetY, 100, accuracy: 0.001,
            "alpha scroll must not be overwritten by storing beta")
        XCTAssertEqual(cache.entry(for: "/src/beta.txt").scrollOffsetY, 200, accuracy: 0.001,
            "beta scroll must not be overwritten by storing alpha")
    }

    // MARK: - overwrite same path

    func test_storeTwice_secondEntryWins() {
        // WHY: hide -> show -> hide (scroll further) -> show must restore the LATEST position,
        //      not the stale first-hide position.
        var cache = FilePreviewScrollCache()
        cache.store(path: "/doc.txt", entry: .init(scrollOffsetY: 10, pdfPageIndex: 0))
        cache.store(path: "/doc.txt", entry: .init(scrollOffsetY: 99, pdfPageIndex: 0))

        XCTAssertEqual(cache.entry(for: "/doc.txt").scrollOffsetY, 99, accuracy: 0.001,
            "Second store must overwrite the first so the most-recent scroll position is restored")
    }

    // MARK: - default Entry values

    func test_defaultEntry_hasZeroOffsetAndZeroPage() {
        // WHY: renderText guards on `saved.scrollOffsetY != 0` and renderPDF guards on
        //      `saved.pdfPageIndex > 0`; Entry() must satisfy both guards so no-op restore
        //      is the correct default for a freshly opened file.
        let entry = FilePreviewScrollCache.Entry()

        XCTAssertEqual(entry.scrollOffsetY, 0,
            "Entry() scrollOffsetY must be 0 so renderText skips the restore scroll call")
        XCTAssertEqual(entry.pdfPageIndex, 0,
            "Entry() pdfPageIndex must be 0 so renderPDF skips the go(to:) call")
    }

    // MARK: - value semantics

    func test_cacheHasValueSemantics_copyIsIndependent() {
        // WHY: FilePreviewScrollCache is a struct; callers that store a local copy (e.g.
        //      didBecomeHidden capturing `var entry`) must not accidentally mutate the cache.
        var original = FilePreviewScrollCache()
        original.store(path: "/x.txt", entry: .init(scrollOffsetY: 50, pdfPageIndex: 0))

        var copy = original
        copy.store(path: "/x.txt", entry: .init(scrollOffsetY: 999, pdfPageIndex: 0))

        XCTAssertEqual(original.entry(for: "/x.txt").scrollOffsetY, 50, accuracy: 0.001,
            "Mutating a copy must not affect the original -- struct value semantics required")
        XCTAssertEqual(copy.entry(for: "/x.txt").scrollOffsetY, 999, accuracy: 0.001,
            "Mutating the copy must be reflected in the copy")
    }
}
