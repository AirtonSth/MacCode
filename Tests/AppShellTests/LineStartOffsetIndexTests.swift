import XCTest
@testable import AppShell

/// Tests for the pure helpers `buildLineStartOffsets(text:)` and `lineIndex(forCharOffset:in:)`.
///
/// WHY these tests matter:
///  - `buildLineStartOffsets` is the O(n) cache-build step that replaces the O(document)
///    substring+filter scan previously performed on every scroll-driven ruler repaint.
///    A wrong cache silently produces incorrect line numbers in the gutter - a visible
///    rendering bug. These tests lock down the contract so any regression is caught at
///    compile/test time.
///  - `lineIndex` is the O(log n) binary-search used on every paint call. An off-by-one
///    (returning line N when line N+1 is correct) would display the wrong number in the
///    ruler without any crash, making the bug hard to detect manually.
///  - Unicode safety: NSLayoutManager character indices are UTF-16 offsets. If the helpers
///    count Swift.String.Index (grapheme cluster) positions instead, multi-byte characters
///    (emoji, combining sequences) shift every subsequent line offset and break line numbers
///    for the remainder of the document.
final class LineStartOffsetIndexTests: XCTestCase {

    // MARK: - buildLineStartOffsets

    func test_buildLineStartOffsets_emptyString_returnsSingleZeroEntry() {
        // An empty document still has one line. Returning [0] means line 1 starts at offset 0.
        // If this returned [] the lineIndex helper would return 0 from the guard, which is
        // correct by coincidence, but the drawHashMarksAndLabels fallback branch depends on
        // at least [0] to avoid a redundant buildLineStartOffsets call.
        let offsets = buildLineStartOffsets(text: "")
        XCTAssertEqual(offsets, [0],
            "empty text must return [0] so the single empty line has a valid start offset")
    }

    func test_buildLineStartOffsets_singleLineNoNewline_returnsSingleEntry() {
        // "hello" has one line, starting at 0. No newline -> no additional entries.
        let offsets = buildLineStartOffsets(text: "hello")
        XCTAssertEqual(offsets, [0],
            "single line without trailing newline must return exactly [0]")
    }

    func test_buildLineStartOffsets_twoLines_returnsCorrectOffsets() {
        // "abc\nxyz": line 0 starts at 0, line 1 starts at 4 (3 chars + 1 newline = UTF-16 offset 4).
        // If the offset is wrong (e.g. 3 instead of 4) the ruler would show line 2's number
        // one character too early or too late.
        let offsets = buildLineStartOffsets(text: "abc\nxyz")
        XCTAssertEqual(offsets, [0, 4],
            "two-line text: line 0 starts at 0, line 1 starts at 4 (after 3 chars + newline)")
    }

    func test_buildLineStartOffsets_threeLines_allOffsetsCorrect() {
        // "a\nbb\nccc": offsets [0, 2, 5].
        // Line 0 "a": offset 0. Newline at index 1 -> line 1 starts at 2.
        // Line 1 "bb": offset 2. Newline at index 4 -> line 2 starts at 5.
        let offsets = buildLineStartOffsets(text: "a\nbb\nccc")
        XCTAssertEqual(offsets, [0, 2, 5],
            "three-line text must produce offsets [0, 2, 5]")
    }

    func test_buildLineStartOffsets_trailingNewline_addsExtraEntry() {
        // "a\n" has a trailing newline that creates an empty final line at offset 2.
        // The ruler must display an empty line number for that phantom line.
        let offsets = buildLineStartOffsets(text: "a\n")
        XCTAssertEqual(offsets, [0, 2],
            "trailing newline must produce an extra entry for the empty final line")
    }

    func test_buildLineStartOffsets_unicodeEmoji_usesUTF16Offsets() {
        // U+1F600 (grinning face) encodes as 2 UTF-16 code units (surrogate pair).
        // "A\u{1F600}\nB": line 0 has 3 UTF-16 units (A=1, emoji=2) + newline = line 1 starts at 4.
        // If the helper counted Swift grapheme clusters instead of UTF-16 units,
        // it would compute offset 3 (A=1 + emoji=1 cluster + newline=1), producing line 1
        // starting at 3 -- off by one. The ruler would then show the wrong number for every
        // line after the emoji.
        let text = "A\u{1F600}\nB"
        let offsets = buildLineStartOffsets(text: text)
        XCTAssertEqual(offsets, [0, 4],
            "emoji (surrogate pair = 2 UTF-16 units) must shift the next line start by 2, not 1")
    }

    func test_buildLineStartOffsets_unicodeCombiningChar_usesUTF16Offsets() {
        // Decomposed 'e' + combining acute accent: "e" (U+0065, 1 unit) + U+0301 (1 unit) = 2 UTF-16 units.
        // "e\u{0301}\nX": line 1 starts at 3 (e=1 + acute=1 + newline=1).
        let text = "e\u{0301}\nX"
        let offsets = buildLineStartOffsets(text: text)
        XCTAssertEqual(offsets, [0, 3],
            "combining character (2 UTF-16 units) must place line 1 start at offset 3")
    }

    // MARK: - lineIndex(forCharOffset:in:)

    func test_lineIndex_offsetZero_returnsLineZero() {
        // Offset 0 is the very first character, always on line 0.
        // This is the common case when the user has scrolled to the top.
        let offsets = [0, 5, 10]
        XCTAssertEqual(lineIndex(forCharOffset: 0, in: offsets), 0,
            "offset 0 must always resolve to line index 0")
    }

    func test_lineIndex_offsetInFirstLine_returnsLineZero() {
        // Any offset before the first newline belongs to line 0.
        let offsets = [0, 10, 20]
        XCTAssertEqual(lineIndex(forCharOffset: 7, in: offsets), 0,
            "offset inside line 0 must return 0")
    }

    func test_lineIndex_offsetAtExactLineStart_returnsCorrectLine() {
        // Offset 10 == offsets[1]: exactly the start of line 1.
        // An off-by-one (returning 0 or 2) would display the wrong line number
        // at the very top of the visible area on every scroll tick.
        let offsets = [0, 10, 20]
        XCTAssertEqual(lineIndex(forCharOffset: 10, in: offsets), 1,
            "offset at exact line start must return that line index")
    }

    func test_lineIndex_offsetInsideLastLine_returnsLastLineIndex() {
        // Offset 25 is inside line 2 (starts at 20). Must return 2, not 1.
        let offsets = [0, 10, 20]
        XCTAssertEqual(lineIndex(forCharOffset: 25, in: offsets), 2,
            "offset inside last line must return the last line index")
    }

    func test_lineIndex_offsetAtDocumentEnd_returnsLastLineIndex() {
        // NSLayoutManager can return a character index equal to the string length
        // when the cursor or visible range lands on the final newline or EOF.
        // offsets = [0, 5]: document length = 8 (e.g. "abc\nxyz\0").
        let offsets = [0, 5]
        XCTAssertEqual(lineIndex(forCharOffset: 8, in: offsets), 1,
            "offset at or past document end must clamp to the last known line index")
    }

    func test_lineIndex_emptyOffsets_returnsZeroSafely() {
        // Defensive: if the cache is empty for any reason, must not crash and must
        // return 0 (line 1), which matches the previous O(document) behavior for
        // an empty or uninitialized state.
        XCTAssertEqual(lineIndex(forCharOffset: 5, in: []), 0,
            "empty offsets must return 0 without crashing")
    }

    func test_lineIndex_singleEntry_alwaysReturnsZero() {
        // Single-line document: offsets = [0]. Any char offset must resolve to line 0.
        let offsets = [0]
        XCTAssertEqual(lineIndex(forCharOffset: 0, in: offsets), 0)
        XCTAssertEqual(lineIndex(forCharOffset: 999, in: offsets), 0,
            "single-entry offsets array: any offset must resolve to line 0")
    }

    // MARK: - Round-trip: offsets then index

    func test_roundTrip_buildThenIndex_multiLineText() {
        // Build the index for a known string, then confirm each line's start offset maps back
        // to the correct line. This is the primary perf-correctness invariant:
        // for every line start offset, lineIndex must return that line's index.
        // If this fails, the ruler will display wrong numbers for at least one line.
        let text = "first\nsecond\nthird"
        let offsets = buildLineStartOffsets(text: text)
        // offsets = [0, 6, 13]
        XCTAssertEqual(offsets.count, 3,
            "three lines (no trailing newline) must produce 3 offset entries")
        for (expectedLine, startOffset) in offsets.enumerated() {
            let got = lineIndex(forCharOffset: startOffset, in: offsets)
            XCTAssertEqual(got, expectedLine,
                "line \(expectedLine) starts at offset \(startOffset); lineIndex must return \(expectedLine), got \(got)")
        }
    }
}
