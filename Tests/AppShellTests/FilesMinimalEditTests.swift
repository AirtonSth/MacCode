import XCTest
@testable import AppShell

/// WHY (P1 - FilesViewModel.minimalEdit): the cross-device patch pipeline
/// (T006-T010 from mac-aux-surfaces.md) relies on minimalEdit to compute the
/// smallest possible NSTextView replacement.  An incorrect implementation sends
/// the WRONG replacement range to the host, corrupting the remote editor state.
/// Because the host applies the patch by character offset, even a one-unit error
/// in `location` or `length` silently clobbers adjacent text.
///
/// minimalEdit is `static` (was private, now internal) on FilesViewModel.
/// It is a pure function: same input => same output, no concurrency needed.
/// Tests run on any thread; @MainActor annotation NOT required for pure statics.
final class FilesMinimalEditTests: XCTestCase {

    // MARK: - Identical strings

    /// WHY: when old == new the patch must be a zero-length no-op.
    /// A non-zero replacement here would corrupt the editor by injecting
    /// text where none changed.
    func test_identicalStrings_noOp() {
        let r = filesMinimalEdit(from:"hello", to: "hello")
        XCTAssertEqual(r.location, 5,
            "location must be at the end (after the shared prefix/suffix) for an identical pair")
        XCTAssertEqual(r.length, 0,
            "length must be 0 for identical strings - no bytes to replace")
        XCTAssertEqual(r.replacement, "",
            "replacement must be empty for identical strings")
    }

    // MARK: - Empty strings

    /// WHY: empty -> non-empty is a pure insert at location 0.
    func test_emptyOld_pureInsert() {
        let r = filesMinimalEdit(from:"", to: "abc")
        XCTAssertEqual(r.location, 0, "insert into empty must start at 0")
        XCTAssertEqual(r.length, 0, "nothing to delete from an empty string")
        XCTAssertEqual(r.replacement, "abc", "full new text must be the replacement")
    }

    /// WHY: non-empty -> empty is a pure deletion of the entire string.
    func test_nonEmptyOld_pureDeletion() {
        let r = filesMinimalEdit(from:"abc", to: "")
        XCTAssertEqual(r.location, 0, "deletion must start at offset 0")
        XCTAssertEqual(r.length, 3, "all 3 UTF-16 units must be deleted")
        XCTAssertEqual(r.replacement, "", "replacement is empty for a pure deletion")
    }

    // MARK: - Prefix-only change

    /// WHY: when only the beginning differs, the patch must cover exactly the
    /// differing prefix - not the whole string.
    func test_prefixChange_onlyPrefixInPatch() {
        let r = filesMinimalEdit(from:"abcdef", to: "XYcdef")
        XCTAssertEqual(r.location, 0, "change starts at the beginning")
        XCTAssertEqual(r.length, 2, "only 2 UTF-16 units (ab) are replaced")
        XCTAssertEqual(r.replacement, "XY")
    }

    // MARK: - Suffix-only change

    /// WHY: when only the end differs, the patch must cover exactly the
    /// differing suffix - not the whole string.
    func test_suffixChange_onlySuffixInPatch() {
        let r = filesMinimalEdit(from:"abcdef", to: "abcXYZ")
        XCTAssertEqual(r.location, 3, "unchanged prefix abc spans 3 UTF-16 units")
        XCTAssertEqual(r.length, 3, "3 units (def) are replaced")
        XCTAssertEqual(r.replacement, "XYZ")
    }

    // MARK: - Middle insertion

    /// WHY: inserting text in the middle must produce a zero-length patch at
    /// the insertion point, not a replacement covering the trailing shared suffix.
    func test_middleInsertion_zeroLengthPatch() {
        let r = filesMinimalEdit(from:"abdef", to: "abcdef")
        XCTAssertEqual(r.location, 2, "insertion point after shared prefix ab")
        XCTAssertEqual(r.length, 0, "nothing deleted - pure insertion")
        XCTAssertEqual(r.replacement, "c", "only the inserted character is the replacement")
    }

    // MARK: - Middle deletion

    /// WHY: deleting text in the middle must produce a patch that covers only
    /// the removed segment, not the surrounding unchanged text.
    func test_middleDeletion_coversOnlyDeletedSegment() {
        let r = filesMinimalEdit(from:"abcdef", to: "abdef")
        XCTAssertEqual(r.location, 2, "deletion starts after prefix ab")
        XCTAssertEqual(r.length, 1, "only c is deleted")
        XCTAssertEqual(r.replacement, "", "replacement is empty for pure deletion")
    }

    // MARK: - Full replacement (no common prefix or suffix)

    /// WHY: when the strings share nothing, the patch must cover the entire old string.
    func test_noCommonPrefixOrSuffix_fullReplacement() {
        let r = filesMinimalEdit(from:"abc", to: "xyz")
        XCTAssertEqual(r.location, 0)
        XCTAssertEqual(r.length, 3)
        XCTAssertEqual(r.replacement, "xyz")
    }

    // MARK: - Multibyte (2-unit UTF-16) character

    /// WHY: emoji and supplementary-plane characters occupy 2 UTF-16 code units.
    /// The patch offsets must be in UTF-16 units (as NSTextView expects), not
    /// Swift character indices. A one-off here corrupts the remote document.
    func test_emojiAtStart_utf16Offsets() {
        // U+1F600 (GRINNING FACE) encodes to 2 UTF-16 units.
        let old = "\u{1F600}bc"   // [0xD83D, 0xDE00, 'b', 'c'] - 4 UTF-16 units
        let new = "\u{1F600}Xc"   // replace 'b' (offset 2) with 'X'
        let r = filesMinimalEdit(from:old, to: new)
        XCTAssertEqual(r.location, 2,
            "location must skip the 2-unit emoji surrogate pair; wrong offset corrupts editor state")
        XCTAssertEqual(r.length, 1, "only 'b' (1 UTF-16 unit) is replaced")
        XCTAssertEqual(r.replacement, "X")
    }

    /// WHY: inserting an emoji (2 UTF-16 units) must be reflected in the
    /// replacement string's UTF-16 encoding, not as a 1-unit placeholder.
    func test_insertEmoji_replacementIsCorrectUTF16() {
        let old = "ab"
        let new = "a\u{1F600}b"  // insert emoji between a and b
        let r = filesMinimalEdit(from:old, to: new)
        XCTAssertEqual(r.location, 1, "insertion point after 'a'")
        XCTAssertEqual(r.length, 0, "nothing deleted")
        // The replacement string must round-trip through NSString without loss.
        let nsStr = r.replacement as NSString
        XCTAssertEqual(nsStr.length, 2,
            "emoji occupies 2 UTF-16 units; NSString.length must be 2 or NSTextView will truncate")
    }

    // MARK: - Single character change

    func test_singleCharChange_exactLocation() {
        let r = filesMinimalEdit(from:"abcde", to: "abXde")
        XCTAssertEqual(r.location, 2)
        XCTAssertEqual(r.length, 1)
        XCTAssertEqual(r.replacement, "X")
    }

    // MARK: - Replacement shrinks length (partial overlap)

    /// WHY: if new text is shorter than old text in the changed region,
    /// length must equal the number of deleted UTF-16 units, not the replacement length.
    func test_replaceShorterText() {
        let r = filesMinimalEdit(from:"aXXXb", to: "aYb")
        XCTAssertEqual(r.location, 1, "change starts after 'a'")
        XCTAssertEqual(r.length, 3, "XXX (3 units) is replaced")
        XCTAssertEqual(r.replacement, "Y")
    }

    // MARK: - Replacement grows length

    func test_replaceLongerText() {
        let r = filesMinimalEdit(from:"aXb", to: "aYYYb")
        XCTAssertEqual(r.location, 1)
        XCTAssertEqual(r.length, 1, "X (1 unit) is replaced")
        XCTAssertEqual(r.replacement, "YYY")
    }

    // MARK: - Performance: 1 MB document (CI-gate Perf #2)

    /// WHY: filesMinimalEdit is called on every keystroke during a live edit session.
    /// On a 1MB document a naive O(n) scan must still complete well within the
    /// 500ms main-thread budget.  This measure{} block establishes a baseline so
    /// CI catches regressions (>10x) before they ship.
    /// Corresponds to mac-aux-surfaces.md Perf #2 / CI-gate P2 item.
    func test_performance_oneMegabyteDocument() {
        // Build a 1MB ASCII document (~1_048_576 UTF-16 units).
        let base = String(repeating: "abcdefghij", count: 104_858)
        // Simulate a single-character insertion at the midpoint.
        let midIndex = base.index(base.startIndex, offsetBy: base.count / 2)
        var modified = base
        modified.insert("X", at: midIndex)

        measure {
            _ = filesMinimalEdit(from: base, to: modified)
        }
    }
}
