import XCTest
@testable import Surfaces
import AgentRuntime

/// Tests for DiffPanelViewModel.buildDiffSegments — the pure, nonisolated
/// helper that classifies diff lines off the main thread (PERF-008).
///
/// WHY each test matters:
/// - If buildDiffSegments misclassifies a line, the wrong color is shown in
///   the diff viewer: green lines appear grey, headers appear as context, etc.
/// - If empty input returns non-empty segments, the styled diff view shows
///   phantom content when rawDiff is cleared.
/// - If the cap is not respected upstream, TextKit lays out a multi-MB
///   attributed string synchronously on the main thread — the original stall.
/// - If the generation guard fails, a slow background task can overwrite
///   the styledDiff that belongs to a newer rawDiff assignment.
///
/// All tests call the nonisolated static helper directly — no @MainActor
/// isolation needed; no view model construction required.
final class DiffPanelOffMainBuildTests: XCTestCase {

    // MARK: - Empty input

    /// WHY: when rawDiff is cleared (e.g. user deselects a file), the styled
    /// diff must also become empty. A non-empty result would leave stale
    /// colored lines on screen.
    func test_buildDiffSegments_emptyString_returnsEmpty() {
        let result = DiffPanelViewModel.buildDiffSegments("")
        XCTAssertTrue(result.isEmpty,
                      "empty rawDiff must produce zero segments so the diff view clears")
    }

    // MARK: - Addition lines

    /// WHY: added lines (+) must classify as .add so they receive the green
    /// foreground/background. Misclassification hides the addition from the
    /// user at a glance.
    func test_buildDiffSegments_additionLine_classifiesAsAdd() {
        let result = DiffPanelViewModel.buildDiffSegments("+added line")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].kind, .add,
                       "a line starting with + (not +++) must be classified as .add")
    }

    // MARK: - Deletion lines

    /// WHY: deleted lines (-) must classify as .del so they receive the red
    /// color. Showing a deletion as context hides the removal from the reviewer.
    func test_buildDiffSegments_deletionLine_classifiesAsDel() {
        let result = DiffPanelViewModel.buildDiffSegments("-removed line")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].kind, .del,
                       "a line starting with - (not ---) must be classified as .del")
    }

    // MARK: - Hunk header lines

    /// WHY: hunk headers (@@ ... @@) must be classified as .hunk so they
    /// receive the accent color that visually separates diff sections.
    func test_buildDiffSegments_hunkHeader_classifiesAsHunk() {
        let result = DiffPanelViewModel.buildDiffSegments("@@ -1,4 +1,5 @@ func foo()")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].kind, .hunk,
                       "a line starting with @@ must be classified as .hunk")
    }

    // MARK: - Diff header lines

    /// WHY: git diff meta-headers (diff --git, +++, ---) must be classified
    /// as .header so they receive the warning-yellow color that signals file
    /// boundaries. Showing them as context or +/- would be confusing.
    func test_buildDiffSegments_diffGitHeader_classifiesAsHeader() {
        let result = DiffPanelViewModel.buildDiffSegments("diff --git a/foo.swift b/foo.swift")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].kind, .header,
                       "diff --git lines must be classified as .header")
    }

    func test_buildDiffSegments_tripleAddHeader_classifiesAsHeader() {
        let result = DiffPanelViewModel.buildDiffSegments("+++ b/foo.swift")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].kind, .header,
                       "+++ lines (file rename header) must be .header, not .add")
    }

    func test_buildDiffSegments_tripleDelHeader_classifiesAsHeader() {
        let result = DiffPanelViewModel.buildDiffSegments("--- a/foo.swift")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].kind, .header,
                       "--- lines (file rename header) must be .header, not .del")
    }

    // MARK: - Context lines

    /// WHY: unchanged context lines must classify as .context so they receive
    /// the secondary-text color. Misclassifying them as .add/.del would show
    /// false green/red noise in the diff view.
    func test_buildDiffSegments_contextLine_classifiesAsContext() {
        let result = DiffPanelViewModel.buildDiffSegments(" unchanged line")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].kind, .context,
                       "a line with a leading space must be classified as .context")
    }

    // MARK: - Multi-line ordering and text preservation

    /// WHY: segments must appear in source order, one per input line. If
    /// order is wrong, the diff reads backwards or lines are skipped, which
    /// breaks every code review use case.
    func test_buildDiffSegments_multiLine_preservesOrderAndKind() {
        let input = """
        diff --git a/f.swift b/f.swift
        @@ -1,2 +1,3 @@
         context
        +added
        -removed
        """
        let result = DiffPanelViewModel.buildDiffSegments(input)
        XCTAssertEqual(result.count, 5,
                       "5 input lines must produce exactly 5 segments")
        XCTAssertEqual(result[0].kind, .header)
        XCTAssertEqual(result[1].kind, .hunk)
        XCTAssertEqual(result[2].kind, .context)
        XCTAssertEqual(result[3].kind, .add)
        XCTAssertEqual(result[4].kind, .del)
    }

    /// WHY: the segment text must include the trailing newline appended by
    /// buildDiffSegments so that AttributedString assembly produces correct
    /// line breaks. Missing newlines would collapse all lines into one run.
    func test_buildDiffSegments_segmentText_includesTrailingNewline() {
        let result = DiffPanelViewModel.buildDiffSegments("+hello")
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].text.hasSuffix("\n"),
                      "each segment text must end with a newline for correct line breaks in AttributedString")
        XCTAssertTrue(result[0].text.hasPrefix("+"),
                      "segment text must preserve the original line content")
    }

    // MARK: - Cap respected (upstream)

    /// WHY: the 400K-char cap is applied before buildDiffSegments is called.
    /// This test confirms that a 400K-char input (already capped) is processed
    /// without truncation inside buildDiffSegments itself — the function must
    /// handle the full allowed window without silently dropping lines.
    func test_buildDiffSegments_capSizedInput_processesAllLines() {
        // Build a source that is exactly at the cap limit (400K chars).
        // Each line is 41 chars ("+padding...\n"), ~9756 lines total.
        let lineBody = "+padding" + String(repeating: "x", count: 32)  // 40 chars + newline = 41
        var lines: [String] = []
        var total = 0
        let cap = 400 * 1024
        while total + lineBody.count + 1 <= cap {
            lines.append(lineBody)
            total += lineBody.count + 1  // +1 for the \n that split will reattach
        }
        let source = lines.joined(separator: "\n")
        XCTAssertLessThanOrEqual(source.count, cap,
                                 "test setup: source must not exceed cap")
        let result = DiffPanelViewModel.buildDiffSegments(source)
        XCTAssertEqual(result.count, lines.count,
                       "buildDiffSegments must produce one segment per input line without dropping any")
        XCTAssertTrue(result.allSatisfy { $0.kind == .add },
                      "all lines start with + so all segments must be .add")
    }
}
