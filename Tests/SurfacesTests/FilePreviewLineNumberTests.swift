import XCTest
@testable import Surfaces

/// Tests for the pure line-number seams on FilePreviewSurface:
///   - the legacy scan retained as a correctness/benchmark oracle
///   - the immutable UTF-16 index used by the preview ruler
///
/// WHY these tests matter:
///   - PreviewLineNumberRulerView queries FilePreviewLineIndex on every scroll-driven
///     repaint to determine the 1-based number for the first visible line.
///     An off-by-one produces a wrong number in the gutter for every visible line,
///     with no crash to signal the regression.
///   - lineCount is used to reason about trailing-newline phantom lines; wrong count
///     means the last line number is never drawn.
///   - UTF-16 fidelity: NSLayoutManager character indices are UTF-16 offsets. If the
///     helpers count Swift grapheme clusters instead, multi-byte characters (emoji,
///     combining sequences) shift all subsequent line numbers.
final class FilePreviewLineNumberTests: XCTestCase {

    // MARK: - lineCount(for:)

    func test_lineCount_emptyString_returnsOne() {
        // An empty document has one line (line 1 exists, it is just empty).
        // Returning 0 would mean the ruler draws nothing for an empty file.
        XCTAssertEqual(FilePreviewSurface.lineCount(for: ""), 1,
            "empty string must report 1 line")
    }

    func test_lineCount_singleLineNoNewline_returnsOne() {
        XCTAssertEqual(FilePreviewSurface.lineCount(for: "hello"), 1,
            "single line without trailing newline must return 1")
    }

    func test_lineCount_twoLines_returnsTwo() {
        // "a\nb" has 2 lines.
        XCTAssertEqual(FilePreviewSurface.lineCount(for: "a\nb"), 2,
            "two-line text must return 2")
    }

    func test_lineCount_threeLines_returnsThree() {
        XCTAssertEqual(FilePreviewSurface.lineCount(for: "a\nb\nc"), 3,
            "three-line text must return 3")
    }

    func test_lineCount_trailingNewline_addsPhantomLine() {
        // "a\n" ends with a newline, creating a phantom empty final line.
        // The ruler must draw a line number for that line (matches editor behavior).
        XCTAssertEqual(FilePreviewSurface.lineCount(for: "a\n"), 2,
            "trailing newline creates an extra phantom line; count must be 2")
    }

    // MARK: - lineNumber(forCharacterOffset:in:)

    func test_lineNumber_offsetZero_returnsOne() {
        // Offset 0 is the first character -- always on line 1.
        XCTAssertEqual(FilePreviewSurface.lineNumber(forCharacterOffset: 0, in: "a\nb\nc"), 1,
            "offset 0 must always be line 1")
    }

    func test_lineNumber_negativeOffset_returnsOne() {
        // Defensive: NSLayoutManager should never produce a negative index, but guard it.
        XCTAssertEqual(FilePreviewSurface.lineNumber(forCharacterOffset: -1, in: "a\nb"), 1,
            "negative offset must clamp to line 1")
    }

    func test_lineNumber_offsetInFirstLine_returnsOne() {
        // Any offset before the first newline belongs to line 1.
        // "abc\nxyz": offsets 0, 1, 2 -> line 1.
        let text = "abc\nxyz"
        XCTAssertEqual(FilePreviewSurface.lineNumber(forCharacterOffset: 2, in: text), 1,
            "offset inside first line must return 1")
    }

    func test_lineNumber_offsetAtNewline_returnsOne() {
        // The newline character itself is still on line 1 (it terminates line 1).
        let text = "abc\nxyz"
        // "abc\n" -> newline is at UTF-16 offset 3
        XCTAssertEqual(FilePreviewSurface.lineNumber(forCharacterOffset: 3, in: text), 1,
            "newline character (end of line 1) must still return 1")
    }

    func test_lineNumber_offsetAtStartOfSecondLine_returnsTwo() {
        // "abc\nxyz": after the newline at offset 3, offset 4 is the first char of line 2.
        let text = "abc\nxyz"
        XCTAssertEqual(FilePreviewSurface.lineNumber(forCharacterOffset: 4, in: text), 2,
            "first offset after newline must be line 2")
    }

    func test_lineNumber_offsetInsideThirdLine_returnsThree() {
        // "a\nb\nc": line 1=offset 0, line 2=offset 2, line 3=offset 4.
        let text = "a\nb\nc"
        XCTAssertEqual(FilePreviewSurface.lineNumber(forCharacterOffset: 4, in: text), 3,
            "offset inside third line must return 3")
    }

    func test_lineNumber_offsetPastEnd_returnsLastLine() {
        // NSLayoutManager can return charIndex == string.length when at EOF.
        // "a\nb": length = 3 (UTF-16). Offset 3 is past end; must clamp to last line (2).
        let text = "a\nb"
        XCTAssertEqual(FilePreviewSurface.lineNumber(forCharacterOffset: 100, in: text), 2,
            "offset past end must clamp to the last line")
    }

    func test_lineNumber_emptyString_offsetZero_returnsOne() {
        XCTAssertEqual(FilePreviewSurface.lineNumber(forCharacterOffset: 0, in: ""), 1,
            "empty string at offset 0 must return 1")
    }

    // MARK: - UTF-16 fidelity

    func test_lineNumber_emojiBeforeNewline_offsetAfterNewline_returnsTwo() {
        // U+1F600 (grinning face) is 2 UTF-16 code units.
        // "A\u{1F600}\nB": A=1, emoji=2, newline=1 -> total 4 UTF-16 units before 'B'.
        // lineNumber at UTF-16 offset 4 must be 2.
        // If helper counts Swift grapheme clusters (emoji=1) it would compute offset 3
        // and return 1 for offset 4, producing a wrong gutter number for every line after emoji.
        let text = "A\u{1F600}\nB"
        XCTAssertEqual(FilePreviewSurface.lineNumber(forCharacterOffset: 4, in: text), 2,
            "emoji (2 UTF-16 units) before newline: offset 4 must be line 2")
    }

    func test_lineNumber_combiningCharBeforeNewline_offsetAfterNewline_returnsTwo() {
        // Decomposed 'e' (U+0065) + combining acute (U+0301) = 2 UTF-16 units.
        // "e\u{0301}\nX": e=1, acute=1, newline=1 -> offset 3 is 'X' on line 2.
        let text = "e\u{0301}\nX"
        XCTAssertEqual(FilePreviewSurface.lineNumber(forCharacterOffset: 3, in: text), 2,
            "combining char (2 UTF-16 units) before newline: offset 3 must be line 2")
    }

    // MARK: - Round-trip consistency

    func test_roundTrip_lineCountMatchesMaxLineNumber() {
        // The highest line number reachable must equal lineCount.
        // Uses the last character position in each line.
        let texts = ["single", "a\nb", "a\nb\nc", "x\ny\nz\n"]
        for text in texts {
            let count = FilePreviewSurface.lineCount(for: text)
            let nsLen = (text as NSString).length
            // Last meaningful offset is just before the end (or 0 for empty).
            let lastOffset = max(0, nsLen - 1)
            let maxLine = FilePreviewSurface.lineNumber(forCharacterOffset: lastOffset, in: text)
            // For text ending in \n, last offset is the newline itself (still on the penultimate
            // line); count is one more. For non-trailing-newline text they must be equal.
            XCTAssertTrue(
                maxLine == count || maxLine == count - 1,
                "text '\(text)': lineCount=\(count) maxLine=\(maxLine) -- must be equal or differ by 1 (trailing newline phantom)"
            )
        }
    }

    func test_precomputedIndex_matchesLegacyAcrossUTF16OffsetsAndBounds() {
        // WHY: the ruler now uses the cached index while the legacy scan remains the
        // correctness oracle. Every UTF-16 position, including emoji and EOF, must agree.
        let texts = [
            "",
            "single",
            "\n\n",
            "a\nb\n",
            "a\r\nb\r\n",
            "A\u{1F600}\nB",
            "e\u{0301}\nsecond\nthird",
        ]
        for text in texts {
            let index = FilePreviewLineIndex(text: text)
            let utf16Length = (text as NSString).length
            for offset in -1...(utf16Length + 2) {
                XCTAssertEqual(
                    index.lineNumber(forCharacterOffset: offset),
                    FilePreviewSurface.lineNumber(forCharacterOffset: offset, in: text),
                    "cached index must match the reference scan for offset \(offset) in \(String(reflecting: text))"
                )
            }
        }
    }

    func test_textCache_overwriteAndEvictionReplaceTheLineIndex() throws {
        // WHY: a reused preview surface may load a different text at the same path.
        // Its line index must change atomically with the text, and eviction must drop both.
        var cache = FilePreviewTextCache()
        let path = "/preview/reloaded.txt"
        cache.store(path: path, text: "one\ntwo")
        XCTAssertEqual(try XCTUnwrap(cache.cachedEntry(for: path)).lineIndex.lineCount, 2)

        cache.store(path: path, text: "one\ntwo\nthree\n")
        let reloaded = try XCTUnwrap(cache.cachedEntry(for: path))
        XCTAssertEqual(reloaded.text, "one\ntwo\nthree\n")
        XCTAssertEqual(reloaded.lineIndex.lineCount, 4, "trailing newline must retain the phantom final line")

        cache.evict(path: path)
        XCTAssertNil(cache.cachedEntry(for: path), "eviction must remove text and its precomputed offsets together")
    }

    /// Same-process A/B for the actual ruler lookup seam: the legacy prefix scan
    /// versus the shipped immutable index. The 512 KiB fixture has 50,000 newlines;
    /// each sample resolves exactly 1,000 positions near the top and near EOF.
    func test_microbench_precomputedIndex_removesDepthSlope() {
        let bytes = 512 * 1024
        let newlineCount = 50_000
        let line = "123456789\n" // 10 ASCII/UTF-16 units.
        let prefix = String(repeating: line, count: newlineCount)
        let text = prefix + String(repeating: "x", count: bytes - prefix.utf8.count)
        let index = FilePreviewLineIndex(text: text)
        let utf16Length = (text as NSString).length
        let lookups = 1_000
        let topOffsets = (0..<lookups).map { ($0 * 7) % 8_000 }
        let bottomOffsets = (0..<lookups).map { utf16Length - 1 - (($0 * 7) % 8_000) }
        let warmup = 2
        let samples = 5

        XCTAssertEqual(text.utf8.count, bytes, "fixture must be exactly 512 KiB")
        XCTAssertEqual(index.lineCount, newlineCount + 1, "fixture must expose ~50k gutter lines")
        XCTAssertEqual(topOffsets.count, lookups)
        XCTAssertEqual(bottomOffsets.count, lookups)

        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }

        func time(_ offsets: [Int], lookup: (Int) -> Int) -> Double {
            var checksum = 0
            let start = DispatchTime.now().uptimeNanoseconds
            for offset in offsets { checksum &+= lookup(offset) }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            XCTAssertGreaterThan(checksum, 0)
            return Double(elapsed) / 1_000_000.0
        }

        let legacy: (Int) -> Int = {
            FilePreviewSurface.lineNumber(forCharacterOffset: $0, in: text)
        }
        let indexed: (Int) -> Int = { index.lineNumber(forCharacterOffset: $0) }

        for _ in 0..<warmup {
            _ = time(topOffsets, lookup: legacy)
            _ = time(topOffsets, lookup: indexed)
            _ = time(bottomOffsets, lookup: legacy)
            _ = time(bottomOffsets, lookup: indexed)
        }

        var legacyTop: [Double] = []
        var indexedTop: [Double] = []
        var legacyBottom: [Double] = []
        var indexedBottom: [Double] = []
        for sample in 0..<samples {
            if sample.isMultiple(of: 2) {
                legacyTop.append(time(topOffsets, lookup: legacy))
                indexedTop.append(time(topOffsets, lookup: indexed))
                legacyBottom.append(time(bottomOffsets, lookup: legacy))
                indexedBottom.append(time(bottomOffsets, lookup: indexed))
            } else {
                indexedBottom.append(time(bottomOffsets, lookup: indexed))
                legacyBottom.append(time(bottomOffsets, lookup: legacy))
                indexedTop.append(time(topOffsets, lookup: indexed))
                legacyTop.append(time(topOffsets, lookup: legacy))
            }
        }

        let legacyTopMedian = median(legacyTop)
        let indexedTopMedian = median(indexedTop)
        let legacyBottomMedian = median(legacyBottom)
        let indexedBottomMedian = median(indexedBottom)
        let bottomImprovement = (legacyBottomMedian - indexedBottomMedian) / legacyBottomMedian * 100
        let legacyDepthSlope = legacyBottomMedian / legacyTopMedian
        let indexedDepthSlope = indexedBottomMedian / indexedTopMedian

        NSLog(
            "[perf-proof] filePreviewGutter legacy_top_ms=%@ indexed_top_ms=%@ legacy_bottom_ms=%@ indexed_bottom_ms=%@ improvement_pct=%.2f legacy_slope=%.3f indexed_slope=%.3f raw_legacy_top=%@ raw_indexed_top=%@ raw_legacy_bottom=%@ raw_indexed_bottom=%@",
            String(legacyTopMedian), String(indexedTopMedian),
            String(legacyBottomMedian), String(indexedBottomMedian),
            bottomImprovement, legacyDepthSlope, indexedDepthSlope,
            String(describing: legacyTop), String(describing: indexedTop),
            String(describing: legacyBottom), String(describing: indexedBottom)
        )
        XCTAssertGreaterThan(
            bottomImprovement,
            5.0,
            "indexed EOF lookup must beat the prefix scan by >5% (got \(bottomImprovement)%)"
        )
        XCTAssertLessThan(
            indexedDepthSlope,
            1.5,
            "indexed lookup must stay flat from top to EOF (slope \(indexedDepthSlope)x)"
        )
    }
}
