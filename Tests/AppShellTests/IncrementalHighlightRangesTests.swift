import XCTest
@testable import AppShell

/// Tests for the pure `changedLineRanges(oldText:newText:)` helper.
///
/// WHY these tests matter:
///  - The helper is the sole gate deciding which lines get re-tokenized on every remote patch
///    (PERF-MAC_FILES-014). Getting it wrong either silently skips re-highlighting changed lines
///    (visible rendering artifact) or re-highlights too many lines (negates the perf win).
///  - Returning the WRONG range passes NSTextStorage an out-of-bounds NSRange, which crashes.
///  - Unicode safety: a wrong answer for multibyte characters causes either a crash or a
///    misaligned attribute boundary that corrupts the attributed string.
final class IncrementalHighlightRangesTests: XCTestCase {

    // MARK: - No change -> empty result

    func test_identicalText_returnsEmpty() {
        // When old == new there are no changed lines; re-highlight must be skipped entirely
        // (calling setAttributes on an empty range is a no-op, but the goal is zero calls).
        let result = changedLineRanges(oldText: "hello\nworld", newText: "hello\nworld")
        XCTAssertTrue(result.isEmpty, "identical texts must return no ranges")
    }

    func test_bothEmpty_returnsEmpty() {
        let result = changedLineRanges(oldText: "", newText: "")
        XCTAssertTrue(result.isEmpty, "both empty must return no ranges")
    }

    // MARK: - Single-line change -> that line's UTF-16 range in newText

    func test_singleLineChange_middleLine_rangeCoversOnlyThatLine() {
        // "line0\nLINE1\nline2" -- only line index 1 changed.
        // Perf win: re-highlight 1 line instead of 3.
        let old = "line0\nline1\nline2"
        let new = "line0\nLINE1\nline2"
        let nsNew = new as NSString
        let result = changedLineRanges(oldText: old, newText: new)
        guard result.count == 1 else {
            XCTFail("single changed line must yield exactly one range; got \(result.count)")
            return
        }
        // The range must be valid (not out of bounds).
        XCTAssertLessThanOrEqual(NSMaxRange(result[0]), nsNew.length,
                                 "range must not extend past end of newText")
        // The range must cover the changed line content "LINE1\n".
        let covered = nsNew.substring(with: result[0])
        XCTAssertTrue(covered.hasPrefix("LINE1"),
                      "range must cover the changed line; got \"\(covered)\"")
        // The range must NOT include unchanged prefix line "line0".
        XCTAssertFalse(covered.contains("line0"),
                       "range must not include the unchanged prefix line")
    }

    func test_singleLineChange_firstLine_rangeStartsAtZero() {
        let old = "alpha\nbeta"
        let new = "ALPHA\nbeta"
        let nsNew = new as NSString
        let result = changedLineRanges(oldText: old, newText: new)
        guard result.count == 1 else {
            XCTFail("expected one range; got \(result.count)")
            return
        }
        XCTAssertEqual(result[0].location, 0,
                       "change on line 0 must start at UTF-16 offset 0")
        let covered = nsNew.substring(with: result[0])
        XCTAssertTrue(covered.hasPrefix("ALPHA"),
                      "range must cover changed first line; got \"\(covered)\"")
    }

    func test_singleLineChange_lastLine_rangeEndsAtDocumentEnd() {
        let old = "alpha\nbeta"
        let new = "alpha\nBETA"
        let nsNew = new as NSString
        let result = changedLineRanges(oldText: old, newText: new)
        guard result.count == 1 else {
            XCTFail("expected one range; got \(result.count)")
            return
        }
        // Last line has no trailing newline; range must reach the end of the string.
        XCTAssertEqual(NSMaxRange(result[0]), nsNew.length,
                       "change on last line must include up to end of string")
        let covered = nsNew.substring(with: result[0])
        XCTAssertTrue(covered.hasPrefix("BETA"),
                      "range must cover changed last line; got \"\(covered)\"")
    }

    // MARK: - Multi-line change -> spanning range

    func test_multiLineChange_returnsUnionRange() {
        // Lines 1 and 2 changed; line 0 unchanged.
        // Perf win: re-highlight 2 lines instead of 4.
        let old = "unchanged\nfoo\nbar\nstable"
        let new = "unchanged\nFOO\nBAR\nstable"
        let nsNew = new as NSString
        let result = changedLineRanges(oldText: old, newText: new)
        guard result.count == 1 else {
            XCTFail("contiguous changed lines must yield one union range; got \(result.count)")
            return
        }
        let covered = nsNew.substring(with: result[0])
        XCTAssertTrue(covered.contains("FOO"), "range must include first changed line")
        XCTAssertTrue(covered.contains("BAR"), "range must include second changed line")
        XCTAssertFalse(covered.contains("unchanged"),
                       "range must not include the unchanged prefix line")
        XCTAssertFalse(covered.contains("stable"),
                       "range must not include the unchanged suffix line")
    }

    func test_allLinesChanged_rangeCoversEntireDocument() {
        let old = "a\nb"
        let new = "X\nY"
        let nsNew = new as NSString
        let result = changedLineRanges(oldText: old, newText: new)
        guard result.count == 1 else {
            XCTFail("all lines changed must yield one range; got \(result.count)")
            return
        }
        XCTAssertEqual(result[0].location, 0)
        XCTAssertEqual(NSMaxRange(result[0]), nsNew.length,
                       "all lines changed must cover entire document")
    }

    // MARK: - Insertion (newText has more lines)

    func test_lineInsertion_rangeCoversInsertedLines() {
        // A new line is inserted between "a" and "c".
        let old = "a\nc"
        let new = "a\nb\nc"
        let nsNew = new as NSString
        let result = changedLineRanges(oldText: old, newText: new)
        guard result.count == 1 else {
            XCTFail("insertion must yield one range; got \(result.count)")
            return
        }
        XCTAssertLessThanOrEqual(NSMaxRange(result[0]), nsNew.length,
                                 "range must not extend past end of newText after insertion")
        let covered = nsNew.substring(with: result[0])
        XCTAssertTrue(covered.contains("b"),
                      "range must include the inserted line; got \"\(covered)\"")
    }

    func test_lineInsertionAtEnd_rangeCoversNewLine() {
        let old = "first"
        let new = "first\nsecond"
        let nsNew = new as NSString
        let result = changedLineRanges(oldText: old, newText: new)
        guard result.count == 1 else {
            XCTFail("end-insertion must yield one range; got \(result.count)")
            return
        }
        XCTAssertLessThanOrEqual(NSMaxRange(result[0]), nsNew.length)
        let covered = nsNew.substring(with: result[0])
        XCTAssertTrue(covered.contains("second"),
                      "range must include appended line; got \"\(covered)\"")
    }

    // MARK: - Deletion (newText has fewer lines)

    func test_lineDeletion_rangeCoversAffectedRegionInNewText() {
        // Middle line deleted.
        let old = "alpha\nbeta\ngamma"
        let new = "alpha\ngamma"
        let nsNew = new as NSString
        let result = changedLineRanges(oldText: old, newText: new)
        guard result.count == 1 else {
            XCTFail("deletion must yield one range; got \(result.count)")
            return
        }
        XCTAssertLessThanOrEqual(NSMaxRange(result[0]), nsNew.length,
                                 "range must stay within bounds of shorter newText")
        // After deletion, "gamma" is now at line 1 -- the changed region in newText.
        let covered = nsNew.substring(with: result[0])
        XCTAssertTrue(covered.contains("gamma"),
                      "range must cover the line now occupying the changed position; got \"\(covered)\"")
    }

    // MARK: - Unicode safety

    func test_unicodeMultibyte_rangeIsUTF16Safe() {
        // Precomposed e-acute (U+00E9) is 1 UTF-16 unit.
        // Line 0 unchanged, line 1 changed.
        let old = "caf\u{00E9}\nold line"
        let new = "caf\u{00E9}\nnew line"
        let nsNew = new as NSString
        let result = changedLineRanges(oldText: old, newText: new)
        guard result.count == 1 else {
            XCTFail("unicode: single changed line must yield one range; got \(result.count)")
            return
        }
        XCTAssertLessThanOrEqual(NSMaxRange(result[0]), nsNew.length,
                                 "unicode: range must not exceed UTF-16 length")
        let covered = nsNew.substring(with: result[0])
        XCTAssertTrue(covered.hasPrefix("new line"),
                      "unicode: range must cover changed line; got \"\(covered)\"")
    }

    func test_unicodeEmoji_rangeIsUTF16Safe() {
        // Emoji in unchanged prefix line; changed line follows.
        // U+1F600 (grinning face) encodes as 2 UTF-16 code units (surrogate pair).
        // Ensures UTF-16 length of emoji does not shift the computed offset.
        let old = "\u{1F600}\nold"
        let new = "\u{1F600}\nnew"
        let nsNew = new as NSString
        let result = changedLineRanges(oldText: old, newText: new)
        guard result.count == 1 else {
            XCTFail("emoji prefix: single changed line must yield one range; got \(result.count)")
            return
        }
        // rangeStart must be AFTER the emoji (2 UTF-16 units) + newline (1) = offset 3.
        XCTAssertEqual(result[0].location, 3,
                       "emoji prefix: changed line must start at UTF-16 offset 3 (emoji=2 + newline=1)")
        XCTAssertLessThanOrEqual(NSMaxRange(result[0]), nsNew.length)
        let covered = nsNew.substring(with: result[0])
        XCTAssertTrue(covered.hasPrefix("new"),
                      "emoji prefix: range must cover changed line; got \"\(covered)\"")
    }

    func test_unicodeCombiningCharacter_rangeIsUTF16Safe() {
        // Decomposed e + combining acute accent: "e" (U+0065) + U+0301 = 2 UTF-16 units.
        // Change is on line 1; offset must reflect UTF-16 length of line 0 + newline.
        let old = "e\u{0301}\nold"
        let new = "e\u{0301}\nnew"
        let nsNew = new as NSString
        let result = changedLineRanges(oldText: old, newText: new)
        guard result.count == 1 else {
            XCTFail("combining char: single changed line must yield one range; got \(result.count)")
            return
        }
        // "e" (1) + U+0301 (1) + newline (1) = offset 3.
        XCTAssertEqual(result[0].location, 3,
                       "combining char: changed line must start at UTF-16 offset 3")
        XCTAssertLessThanOrEqual(NSMaxRange(result[0]), nsNew.length)
        let covered = nsNew.substring(with: result[0])
        XCTAssertTrue(covered.hasPrefix("new"),
                      "combining char: range must cover changed line; got \"\(covered)\"")
    }
}
