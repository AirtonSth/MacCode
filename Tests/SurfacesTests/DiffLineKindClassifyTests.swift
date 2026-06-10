import XCTest
import AgentRuntime

/// Direct table tests for DiffLineKind.classify (T027).
///
/// WHY: DiffPanelOffMainBuildTests verifies classify indirectly through
/// buildDiffSegments. A false-positive in classify (e.g. a +++ line
/// rendered as .add, or a bare + line rendered as .header) surfaces as a
/// wrong foreground color for every line in the diff viewer -- a "Sure: ..."
/// style silent mistranslation that no integration test catches before a
/// real diff is shown to the user.
final class DiffLineKindClassifyTests: XCTestCase {

    // MARK: - .add

    func test_classify_singlePlusLine_returnsAdd() {
        XCTAssertEqual(DiffLineKind.classify("+added this line"),
                       .add,
                       "a line starting with exactly one + must be .add (green in diff view)")
    }

    func test_classify_plusWithEmptyContent_returnsAdd() {
        XCTAssertEqual(DiffLineKind.classify("+"),
                       .add,
                       "bare '+' with no content is still a valid add line")
    }

    // MARK: - .del

    func test_classify_singleMinusLine_returnsDel() {
        XCTAssertEqual(DiffLineKind.classify("-removed this line"),
                       .del,
                       "a line starting with exactly one - must be .del (red in diff view)")
    }

    func test_classify_minusWithEmptyContent_returnsDel() {
        XCTAssertEqual(DiffLineKind.classify("-"),
                       .del,
                       "bare '-' with no content is still a valid del line")
    }

    // MARK: - .header (must NOT be .add or .del despite leading +/-)

    /// WHY: +++ is the new-file header in unified diff format. Misclassifying
    /// it as .add shows a green header line that looks like a content addition,
    /// confusing every code review that uses the diff viewer.
    func test_classify_triplePlus_returnsHeader_notAdd() {
        XCTAssertEqual(DiffLineKind.classify("+++ b/Sources/Foo.swift"),
                       .header,
                       "+++ must be .header, not .add -- it is a file-path header")
        XCTAssertNotEqual(DiffLineKind.classify("+++ b/File.swift"), .add)
    }

    /// WHY: --- is the old-file header in unified diff format. Misclassifying
    /// it as .del shows a red header line, making file boundaries invisible in
    /// the color scheme.
    func test_classify_tripleMinus_returnsHeader_notDel() {
        XCTAssertEqual(DiffLineKind.classify("--- a/Sources/Foo.swift"),
                       .header,
                       "--- must be .header, not .del -- it is a file-path header")
        XCTAssertNotEqual(DiffLineKind.classify("--- a/File.swift"), .del)
    }

    func test_classify_diffGitLine_returnsHeader() {
        XCTAssertEqual(DiffLineKind.classify("diff --git a/Foo.swift b/Foo.swift"),
                       .header,
                       "diff --git ... lines must be .header (file boundary marker)")
    }

    // MARK: - .hunk

    func test_classify_hunkHeader_returnsHunk() {
        XCTAssertEqual(DiffLineKind.classify("@@ -1,4 +1,5 @@ func foo()"),
                       .hunk,
                       "@@ lines must be .hunk (accent color separating diff sections)")
    }

    func test_classify_doubleAtBare_returnsHunk() {
        XCTAssertEqual(DiffLineKind.classify("@@"),
                       .hunk,
                       "bare @@ is a valid (if degenerate) hunk header")
    }

    // MARK: - .context

    func test_classify_leadingSpaceLine_returnsContext() {
        XCTAssertEqual(DiffLineKind.classify(" unchanged context line"),
                       .context,
                       "lines with a leading space are context (secondary-text color)")
    }

    func test_classify_emptyLine_returnsContext() {
        XCTAssertEqual(DiffLineKind.classify(""),
                       .context,
                       "empty lines (common at end of diff) must be .context, not a crash")
    }

    func test_classify_arbitraryWord_returnsContext() {
        XCTAssertEqual(DiffLineKind.classify("index abc123..def456 100644"),
                       .context,
                       "lines that are not +/-/@@ / diff --git fall through to .context")
    }

    // MARK: - Boundary: ++ and -- are NOT triple-plus/minus

    func test_classify_doublePlus_returnsAdd() {
        // ++ is two plus signs and is NOT +++ so it is a content addition.
        XCTAssertEqual(DiffLineKind.classify("++not-a-header"),
                       .add,
                       "++ does not match +++ guard; the line is treated as .add")
    }

    func test_classify_doubleMinus_returnsDel() {
        XCTAssertEqual(DiffLineKind.classify("--not-a-header"),
                       .del,
                       "-- does not match --- guard; the line is treated as .del")
    }
}
