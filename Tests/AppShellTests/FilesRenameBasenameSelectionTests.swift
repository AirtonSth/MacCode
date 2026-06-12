import XCTest
@testable import AppShell

/// WHY (rename basename pre-selection): when a user invokes Rename on "report.md",
/// the text field should pre-select "report" so they can retype the name without
/// manually deselecting ".md". Selecting the full name forces the user to reposition
/// the cursor or delete the extension, which defeats the UX intent.
/// filesBasenameSelectionRange is a pure function; no AppKit surface needed.
/// All ranges are in UTF-16 units, matching NSTextField.selectedRange expectations.
final class FilesRenameBasenameSelectionTests: XCTestCase {

    // MARK: - Standard extension

    /// WHY: "report.md" -> select "report" (len 6); renaming to "report2.md" requires
    /// only overtyping the name, not touching the extension.
    func test_singleExtension_selectsBasename() {
        let r = filesBasenameSelectionRange(for: "report.md")
        XCTAssertEqual(r.location, 0, "basename starts at UTF-16 offset 0")
        XCTAssertEqual(r.length, 6, "\"report\" is 6 UTF-16 units; extension .md excluded")
    }

    // MARK: - No extension

    /// WHY: "Makefile" has no dot -> the whole name is the basename.
    /// Selecting a substring here would silently drop characters from the name.
    func test_noExtension_selectsAll() {
        let r = filesBasenameSelectionRange(for: "Makefile")
        XCTAssertEqual(r.location, 0)
        XCTAssertEqual(r.length, 8, "\"Makefile\" is 8 UTF-16 units; full name must be selected")
    }

    // MARK: - Dotfile

    /// WHY: ".gitignore" starts with a dot; that dot is NOT an extension separator.
    /// Selecting from offset 1 would leave the leading dot deselected, breaking the name.
    func test_dotfile_selectsAll() {
        let r = filesBasenameSelectionRange(for: ".gitignore")
        XCTAssertEqual(r.location, 0)
        XCTAssertEqual(r.length, 10, "\".gitignore\" is 10 UTF-16 units; full name must be selected")
    }

    // MARK: - Multiple dots (last-dot rule)

    /// WHY: "foo.tar.gz" -> last dot is before "gz"; basename = "foo.tar" (7 units).
    /// Using first-dot would leave "tar.gz" as the extension, which is non-standard.
    /// Using last-dot matches how macOS Finder treats compound extensions.
    func test_multiDot_lastDotRule_selectsFooTar() {
        let r = filesBasenameSelectionRange(for: "foo.tar.gz")
        XCTAssertEqual(r.location, 0)
        XCTAssertEqual(r.length, 7, "\"foo.tar\" is 7 UTF-16 units; last-dot rule leaves .gz as extension")
    }

    // MARK: - Empty string

    /// WHY: empty name is a degenerate case; must return a zero-length range at 0
    /// rather than crashing or returning NSNotFound.
    func test_emptyString_zeroRange() {
        let r = filesBasenameSelectionRange(for: "")
        XCTAssertEqual(r.location, 0)
        XCTAssertEqual(r.length, 0, "empty name -> zero-length selection, no crash")
    }

    // MARK: - Unicode / emoji in basename

    /// WHY: emoji occupies 2 UTF-16 code units (surrogate pair). If the range is
    /// computed in Swift character indices instead of UTF-16 units, the NSTextField
    /// selectedRange will be off by one surrogate, corrupting the selection.
    func test_emojiInBasename_utf16Units() {
        // "\u{1F600}" = GRINNING FACE = 2 UTF-16 units; ".txt" = 4 units
        // Name: "\u{1F600}face.txt" -> basename "\u{1F600}face" = 6 UTF-16 units
        let name = "\u{1F600}face.txt"
        let r = filesBasenameSelectionRange(for: name)
        XCTAssertEqual(r.location, 0)
        XCTAssertEqual(r.length, 6,
            "emoji(2 units) + \"face\"(4 units) = 6 UTF-16 units; wrong unit breaks NSTextField selection")
    }

    // MARK: - Dotfile with a dot in the stem after index 0

    /// WHY: ".env.local" starts with a dot (dotfile) but also has a dot at index 4.
    /// The leading dot is not an extension separator, but the dot at index 4 is.
    /// Last-dot rule: last dot is at UTF-16 offset 4 -> basename ".env" (4 units).
    func test_dotfileWithExtension_lastDotRule() {
        let r = filesBasenameSelectionRange(for: ".env.local")
        XCTAssertEqual(r.location, 0)
        XCTAssertEqual(r.length, 4, "\".env\" is 4 UTF-16 units; \".local\" is the extension via last-dot rule")
    }

    // MARK: - Single character name + extension

    /// WHY: "a.b" -> basename "a" (1 unit). Boundary case for minimal valid name.
    func test_singleCharBasename() {
        let r = filesBasenameSelectionRange(for: "a.b")
        XCTAssertEqual(r.location, 0)
        XCTAssertEqual(r.length, 1, "\"a\" is 1 UTF-16 unit")
    }

    // MARK: - Trailing dot (no extension after dot)

    /// WHY: "archive." ends in a dot with no extension chars after it.
    /// The last dot is still an extension separator under last-dot rule;
    /// basename = "archive" (7 units), extension = "" (empty).
    /// This matches shell/Finder behavior: a trailing dot produces an empty extension.
    func test_trailingDot_basenameExcludesDot() {
        let r = filesBasenameSelectionRange(for: "archive.")
        XCTAssertEqual(r.location, 0)
        XCTAssertEqual(r.length, 7, "\"archive\" is 7 UTF-16 units; trailing dot marks an empty extension")
    }
}
