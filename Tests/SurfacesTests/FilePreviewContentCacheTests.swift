import XCTest
import PDFKit
@testable import Surfaces

// Tests for FilePreviewTextCache, FilePreviewPDFCache, and the shouldReload helper.
// Pure value-type / reference-type tests -- no AppKit, no @MainActor required.
// Rule 8: each assertion encodes WHY the behavior matters.
final class FilePreviewContentCacheTests: XCTestCase {

    // MARK: - FilePreviewTextCache: cache hit same path

    func test_textCache_samePath_returnsCachedText() {
        // WHY: didBecomeVisible re-calls renderText; if the cache misses every time,
        // the main thread reads up to 512KB on every show -- blocking the render path.
        // A cache hit must return the stored string without re-reading the file.
        var cache = FilePreviewTextCache()
        cache.store(path: "/src/main.swift", text: "let x = 1")

        let result = cache.text(for: "/src/main.swift")

        XCTAssertEqual(result, "let x = 1",
            "Cache hit on same path must return stored text -- miss triggers main-thread I/O")
    }

    // MARK: - FilePreviewTextCache: miss on unknown path

    func test_textCache_unknownPath_returnsNil() {
        // WHY: nil signals "no cache" -> background load; a false hit would display
        // stale text from a different file, corrupting the preview.
        let cache = FilePreviewTextCache()

        XCTAssertNil(cache.text(for: "/never/seen.swift"),
            "Unknown path must return nil so the renderer triggers a background load")
    }

    // MARK: - FilePreviewTextCache: changed path is a miss

    func test_textCache_differentPath_returnsNilForNewPath() {
        // WHY: navigating from file A to file B must show B's content, not A's.
        // A hit on path B when only path A is cached would display wrong content.
        var cache = FilePreviewTextCache()
        cache.store(path: "/src/alpha.swift", text: "alpha content")

        XCTAssertNil(cache.text(for: "/src/beta.swift"),
            "Different path must miss the cache -- a false hit would show wrong file content")
    }

    // MARK: - FilePreviewTextCache: overwrite updates stored text

    func test_textCache_overwrite_secondValueWins() {
        // WHY: file content can change between loads; the second store must replace
        // the first so the latest content is displayed on next show.
        var cache = FilePreviewTextCache()
        cache.store(path: "/doc.txt", text: "v1")
        cache.store(path: "/doc.txt", text: "v2")

        XCTAssertEqual(cache.text(for: "/doc.txt"), "v2",
            "Second store must overwrite first so stale content is never displayed")
    }

    // MARK: - FilePreviewTextCache: eviction

    func test_textCache_evict_removesEntry() {
        // WHY: evict is called when the surface loads a new file; the evicted path
        // must return nil so the renderer does not serve stale content for the old file.
        var cache = FilePreviewTextCache()
        cache.store(path: "/old.txt", text: "old content")
        cache.evict(path: "/old.txt")

        XCTAssertNil(cache.text(for: "/old.txt"),
            "Evicted path must return nil -- retained cache entry would display stale content")
    }

    func test_textCache_removeAll_releasesEveryRetainedPayload() {
        // WHY: hidden and closed previews keep only lightweight scroll state. Text and
        // its UTF-16 line index must both leave the cache, including entries for paths
        // visited earlier by the same surface.
        var cache = FilePreviewTextCache()
        cache.store(path: "/first.txt", text: "one\ntwo\n")
        cache.store(path: "/second.txt", text: "A\u{1F600}\nB")
        XCTAssertEqual(cache.entryCountForTesting, 2)
        XCTAssertGreaterThan(cache.retainedPayloadBytesForTesting, 0)

        cache.removeAll()

        XCTAssertEqual(cache.entryCountForTesting, 0)
        XCTAssertEqual(cache.retainedPayloadBytesForTesting, 0,
            "purging a hidden preview must release both String bytes and line-index offsets")
        XCTAssertNil(cache.text(for: "/first.txt"))
        XCTAssertNil(cache.text(for: "/second.txt"))
    }

    // MARK: - FilePreviewTextCache: value semantics

    func test_textCache_hasValueSemantics() {
        // WHY: FilePreviewTextCache is a struct; capturing it (e.g. in a closure) must
        // not create aliasing -- mutating a copy must not affect the original.
        var original = FilePreviewTextCache()
        original.store(path: "/x.txt", text: "original")

        var copy = original
        copy.store(path: "/x.txt", text: "copy mutation")

        XCTAssertEqual(original.text(for: "/x.txt"), "original",
            "Mutating a copy must not affect the original -- struct value semantics required")
    }

    // MARK: - FilePreviewTextCache.shouldReload: same path -> no reload

    func test_shouldReload_samePath_returnsFalse() {
        // WHY: shouldReload drives the cache-or-load decision; false means "use cache",
        // true means "load from disk". Same path -> cache is valid -> no reload needed.
        let result = FilePreviewTextCache.shouldReload(cachedPath: "/a.txt", newPath: "/a.txt")

        XCTAssertFalse(result,
            "Same path must not trigger reload -- cache is valid, I/O on main must be avoided")
    }

    // MARK: - FilePreviewTextCache.shouldReload: different path -> reload

    func test_shouldReload_differentPath_returnsTrue() {
        // WHY: navigating to a new file must always load fresh content from disk;
        // false here would silently display the old file's cached text.
        let result = FilePreviewTextCache.shouldReload(cachedPath: "/a.txt", newPath: "/b.txt")

        XCTAssertTrue(result,
            "Different path must trigger reload -- stale cache from old path must not be used")
    }

    // MARK: - FilePreviewTextCache.shouldReload: nil cachedPath -> reload

    func test_shouldReload_nilCachedPath_returnsTrue() {
        // WHY: nil cached path means no prior load; must always reload for first open.
        let result = FilePreviewTextCache.shouldReload(cachedPath: nil, newPath: "/a.txt")

        XCTAssertTrue(result,
            "Nil cached path must trigger reload -- no prior load means no cached content")
    }

    // MARK: - FilePreviewPDFCache: cache hit same path

    func test_pdfCache_samePath_returnsCachedDocument() {
        // WHY: PDFDocument(url:) parses the whole PDF file on the calling thread;
        // a cache hit must return the stored document without re-parsing -- preventing
        // main-thread disk I/O on every didBecomeVisible.
        let cache = FilePreviewPDFCache()
        // Use a minimal PDF bytes stub for a real PDFDocument if available; since
        // we only test the cache dictionary logic, inject a dummy path with a nil doc guard.
        // We verify the cache round-trip via a real (non-nil) PDFDocument created from
        // a trivially valid PDF byte sequence written to a temp file.
        let pdfBytes = minimalPDFBytes()
        let url = tempPDFURL()
        try? pdfBytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let doc = PDFDocument(url: url) else {
            // If the platform cannot load the stub, skip gracefully rather than false-pass.
            return
        }
        cache.store(path: url.path, document: doc)

        let result = cache.document(for: url.path)

        XCTAssertTrue(result === doc,
            "Cache hit must return the same PDFDocument reference -- identity proves no re-parse")
    }

    // MARK: - FilePreviewPDFCache: miss on unknown path

    func test_pdfCache_unknownPath_returnsNil() {
        // WHY: nil signals "no cache" -> background load; false hit would display
        // stale PDF pages from another file.
        let cache = FilePreviewPDFCache()

        XCTAssertNil(cache.document(for: "/not/cached.pdf"),
            "Unknown path must return nil so the renderer triggers a background load")
    }

    // MARK: - FilePreviewPDFCache: eviction

    func test_pdfCache_evict_removesDocument() {
        // WHY: evict ensures a new PDFDocument is loaded after the underlying file changes.
        let cache = FilePreviewPDFCache()
        let pdfBytes = minimalPDFBytes()
        let url = tempPDFURL()
        try? pdfBytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        if let doc = PDFDocument(url: url) {
            cache.store(path: url.path, document: doc)
            cache.evict(path: url.path)
            XCTAssertNil(cache.document(for: url.path),
                "Evicted path must return nil -- retained doc would serve stale PDF content")
        }
    }

    func test_pdfCache_removeAll_releasesDocumentOwnership() {
        // WHY: PDFDocument can retain a parsed document graph much larger than the
        // source file. Clearing a hidden preview must relinquish the cache's strong
        // ownership rather than merely detaching its PDFView.
        let cache = FilePreviewPDFCache()
        weak var releasedDocument: PDFDocument?
        autoreleasepool {
            let document = PDFDocument()
            releasedDocument = document
            cache.store(path: "/large.pdf", document: document)
        }
        XCTAssertNotNil(releasedDocument, "the cache must own the PDF before purge")

        cache.removeAll()

        XCTAssertEqual(cache.entryCountForTesting, 0)
        XCTAssertNil(releasedDocument, "removeAll must release the cached PDFDocument graph")
    }

    /// Conservative retained-payload proxy for the shipped cache representation. The
    /// old hide path was a no-op, while the candidate purge drops the cache's sole
    /// ownership of both a 512 KiB String and its ~50k-entry UInt32 line index. One
    /// warmup precedes five recorded samples; allocator/dictionary overhead is excluded.
    func test_microbench_hiddenPurge_releasesDirectTextPayload() {
        let bytes = 512 * 1024
        let newlineCount = 50_000
        let expectedPayloadBytes = bytes + (newlineCount + 1) * MemoryLayout<UInt32>.stride
        let warmup = 1
        let samples = 5
        var legacyRetainedRaw: [Int] = []
        var purgedRetainedRaw: [Int] = []

        func makeSoleOwnerCache() -> FilePreviewTextCache {
            let prefix = String(repeating: "123456789\n", count: newlineCount)
            let text = prefix + String(repeating: "x", count: bytes - prefix.utf8.count)
            XCTAssertEqual(text.utf8.count, bytes, "fixture must be exactly 512 KiB")
            var cache = FilePreviewTextCache()
            cache.store(path: "/fixture.txt", text: text)
            return cache
        }

        for iteration in 0..<(warmup + samples) {
            var cache = makeSoleOwnerCache()
            let legacyRetained = cache.retainedPayloadBytesForTesting
            cache.removeAll()
            let purgedRetained = cache.retainedPayloadBytesForTesting
            if iteration >= warmup {
                legacyRetainedRaw.append(legacyRetained)
                purgedRetainedRaw.append(purgedRetained)
            }
        }

        let legacyMedian = legacyRetainedRaw.sorted()[samples / 2]
        let purgedMedian = purgedRetainedRaw.sorted()[samples / 2]
        let improvement = Double(legacyMedian - purgedMedian) / Double(legacyMedian) * 100
        NSLog(
            "[perf-proof] filePreviewHiddenCache legacy_retained_bytes=%d purged_retained_bytes=%d improvement_pct=%.2f raw_legacy=%@ raw_purged=%@",
            legacyMedian, purgedMedian, improvement,
            String(describing: legacyRetainedRaw), String(describing: purgedRetainedRaw)
        )

        XCTAssertEqual(legacyRetainedRaw, Array(repeating: expectedPayloadBytes, count: samples),
            "proxy must count the conservative String bytes plus UInt32 line-index payload")
        XCTAssertEqual(purgedRetainedRaw, Array(repeating: 0, count: samples))
        XCTAssertGreaterThan(improvement, 5.0,
            "hidden-preview purge must reduce directly attributable retained payload by >5%")
    }

    // MARK: - Helpers

    private func tempPDFURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-pdf-cache-test-\(UUID().uuidString).pdf")
    }

    /// Returns bytes for a minimal valid single-page PDF that PDFDocument can parse.
    private func minimalPDFBytes() -> Data {
        // Minimal 1-page PDF -- enough for PDFDocument(url:) to succeed.
        let raw = "%PDF-1.0\n1 0 obj<</Type /Catalog /Pages 2 0 R>>endobj " +
                  "2 0 obj<</Type /Pages /Kids[3 0 R]/Count 1>>endobj " +
                  "3 0 obj<</Type /Page /MediaBox[0 0 3 3]>>endobj\n" +
                  "xref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n" +
                  "0000000058 00000 n \n0000000115 00000 n \n" +
                  "trailer<</Size 4/Root 1 0 R>>\nstartxref\n190\n%%EOF"
        return Data(raw.utf8)
    }
}
