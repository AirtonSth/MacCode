import XCTest
@testable import SocketServer

/// Pure unit tests for the `git.diff` bounded-response v1 window.
///
/// WHY: iOS already ships the request/decoder half. These tests pin host clipping
/// semantics so a weak cellular link never receives more than the requested caps
/// while still reporting honest truncation and original line counts.
final class GitDiffBoundedResponseTests: XCTestCase {

    // MARK: Line count (iOS decoder parity)

    /// WHY: empty patch must report 0 lines, not 1, or the client rejects the
    /// payload as dishonest (`reportedTotal >= returnedLines` with empty text).
    func testLineCount_emptyIsZero() {
        XCTAssertEqual(GitDiffBoundedResponse.lineCount(""), 0)
    }

    /// WHY: trailing newline is a real empty final line under
    /// `omittingEmptySubsequences: false` — matching iOS `diffLineCount`.
    func testLineCount_trailingNewlineCountsFinalEmptyLine() {
        XCTAssertEqual(GitDiffBoundedResponse.lineCount("a"), 1)
        XCTAssertEqual(GitDiffBoundedResponse.lineCount("a\n"), 2)
        XCTAssertEqual(GitDiffBoundedResponse.lineCount("a\nb"), 2)
        XCTAssertEqual(GitDiffBoundedResponse.lineCount("a\nb\n"), 3)
        XCTAssertEqual(GitDiffBoundedResponse.lineCount("\n"), 2)
    }

    // MARK: Exact boundaries

    /// WHY: a budget that fits exactly must not mark truncated, or iOS would show
    /// a "diff truncated" affordance for a complete patch.
    func testBound_exactByteAndLineBoundariesAreNotTruncated() {
        let text = "hello" // 5 UTF-8 bytes, 1 line
        let byBytes = GitDiffBoundedResponse.bound(text: text, maxBytes: 5, maxLines: 10)
        XCTAssertEqual(byBytes.text, "hello")
        XCTAssertFalse(byBytes.truncated)
        XCTAssertEqual(byBytes.totalLines, 1)

        let twoLines = "a\nb"
        let byLines = GitDiffBoundedResponse.bound(text: twoLines, maxBytes: 1024, maxLines: 2)
        XCTAssertEqual(byLines.text, "a\nb")
        XCTAssertFalse(byLines.truncated)
        XCTAssertEqual(byLines.totalLines, 2)
    }

    // MARK: UTF-8 mid-scalar safety

    /// WHY: cutting mid-scalar would hand the client invalid UTF-8 (JSON encode
    /// failure or replacement characters). Multi-byte glyphs appear in diffs.
    func testBound_byteCapNeverSplitsMultiByteScalar() {
        // Each snowman is 3 UTF-8 bytes; a naive cut at 4 would split the second.
        let text = "☃☃☃"
        let window = GitDiffBoundedResponse.bound(text: text, maxBytes: 4, maxLines: 10)
        XCTAssertLessThanOrEqual(window.text.utf8.count, 4)
        XCTAssertEqual(window.text, "☃")
        XCTAssertTrue(window.truncated)
        XCTAssertEqual(window.totalLines, 1)
        XCTAssertFalse(window.text.unicodeScalars.contains("\u{FFFD}"))
    }

    // MARK: Line cap + trailing newline

    /// WHY: first N lines must match iOS split semantics, including that a
    /// trailing newline is its own empty line and can push past the line cap.
    func testBound_lineCapRespectsTrailingNewlineSemantics() {
        // "a\nb\n" → ["a","b",""] = 3 lines. Cap 2 → "a\nb".
        let window = GitDiffBoundedResponse.bound(text: "a\nb\n", maxBytes: 1024, maxLines: 2)
        XCTAssertEqual(window.text, "a\nb")
        XCTAssertTrue(window.truncated)
        XCTAssertEqual(window.totalLines, 3)
        XCTAssertEqual(GitDiffBoundedResponse.lineCount(window.text), 2)

        // Cap equal to full count keeps the trailing newline.
        let full = GitDiffBoundedResponse.bound(text: "a\nb\n", maxBytes: 1024, maxLines: 3)
        XCTAssertEqual(full.text, "a\nb\n")
        XCTAssertFalse(full.truncated)
        XCTAssertEqual(full.totalLines, 3)
    }

    /// WHY: Swift treats CRLF as one Character. The wire contract is LF-delimited,
    /// so Character-only iteration would miss every CRLF and exceed max_lines.
    func testBound_lineCapCountsLFInsideCRLFAndLeavesLoneCRAlone() {
        let crlf = GitDiffBoundedResponse.bound(
            text: "a\r\nb\r\nc",
            maxBytes: 1024,
            maxLines: 2
        )
        XCTAssertEqual(GitDiffBoundedResponse.lineCount(crlf.text), 2)
        XCTAssertLessThanOrEqual(crlf.text.utf8.count, 1024)
        XCTAssertTrue(crlf.truncated)
        XCTAssertEqual(crlf.totalLines, 3)

        let loneCR = GitDiffBoundedResponse.bound(
            text: "a\rb",
            maxBytes: 1024,
            maxLines: 1
        )
        XCTAssertEqual(loneCR.text, "a\rb")
        XCTAssertFalse(loneCR.truncated)
        XCTAssertEqual(loneCR.totalLines, 1)
    }

    // MARK: Both caps together

    /// WHY: the wire window is the intersection of both budgets. Line room must
    /// not excuse a byte overage, and byte room must not excuse a line overage.
    func testBound_bothCapsApplyTogether() {
        // Many short lines: line cap binds first.
        let manyLines = (0..<20).map { "L\($0)" }.joined(separator: "\n")
        let byLines = GitDiffBoundedResponse.bound(text: manyLines, maxBytes: 10_000, maxLines: 3)
        XCTAssertEqual(GitDiffBoundedResponse.lineCount(byLines.text), 3)
        XCTAssertTrue(byLines.truncated)
        XCTAssertEqual(byLines.totalLines, 20)
        XCTAssertLessThanOrEqual(byLines.text.utf8.count, 10_000)

        // One long line: byte cap binds; truncated while returned lines == total.
        let longLine = String(repeating: "x", count: 100)
        let byBytes = GitDiffBoundedResponse.bound(text: longLine, maxBytes: 10, maxLines: 50)
        XCTAssertEqual(byBytes.text, String(repeating: "x", count: 10))
        XCTAssertTrue(byBytes.truncated)
        XCTAssertEqual(byBytes.totalLines, 1)
        XCTAssertEqual(GitDiffBoundedResponse.lineCount(byBytes.text), 1,
                       "byte clip mid-line may keep total_lines == returned lines while truncated")
    }

    // MARK: Param parse fail-closed

    func testParseOptInCaps_absentIsLegacy() throws {
        // WHY: only response_version opts in; max_* alone must not change shape.
        let caps = try GitDiffBoundedResponse.parseOptInCaps([
            "max_bytes": .number(100),
            "max_lines": .number(10),
        ])
        XCTAssertNil(caps)
    }

    func testParseOptInCaps_acceptsValidV1() throws {
        let caps = try GitDiffBoundedResponse.parseOptInCaps([
            "response_version": .number(1),
            "max_bytes": .number(128 * 1024),
            "max_lines": .number(400),
        ])
        XCTAssertEqual(caps?.maxBytes, 128 * 1024)
        XCTAssertEqual(caps?.maxLines, 400)
    }

    func testParseOptInCaps_rejectsInvalidBounds() {
        let invalid: [[String: JSONValue]] = [
            ["response_version": .number(1)], // missing caps
            ["response_version": .number(1), "max_bytes": .number(0), "max_lines": .number(10)],
            ["response_version": .number(1), "max_bytes": .number(-1), "max_lines": .number(10)],
            ["response_version": .number(1), "max_bytes": .number(10), "max_lines": .number(0)],
            ["response_version": .number(1), "max_bytes": .number(1.5), "max_lines": .number(10)],
            ["response_version": .number(2), "max_bytes": .number(10), "max_lines": .number(10)],
            ["response_version": .number(1),
             "max_bytes": .number(Double(GitDiffBoundedResponse.maxBytesCeiling + 1)),
             "max_lines": .number(10)],
            ["response_version": .number(1), "max_bytes": .number(10),
             "max_lines": .number(Double(GitDiffBoundedResponse.maxLinesCeiling + 1))],
        ]
        for params in invalid {
            XCTAssertThrowsError(try GitDiffBoundedResponse.parseOptInCaps(params)) { error in
                guard let rpc = error as? JSONRPCError else {
                    return XCTFail("expected JSONRPCError")
                }
                XCTAssertEqual(rpc.code, -32602)
            }
        }
    }

    /// WHY: response JSON must be the exact keys iOS validates before paint.
    func testWindowJSON_shape() {
        let json = GitDiffBoundedResponse.Window(
            text: "diff",
            truncated: true,
            totalLines: 9
        ).json
        guard case .object(let body) = json else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(body["version"], .number(1))
        XCTAssertEqual(body["text"], .string("diff"))
        XCTAssertEqual(body["truncated"], .bool(true))
        XCTAssertEqual(body["total_lines"], .number(9))
        XCTAssertEqual(body.count, 4, "no extra keys that a strict client might reject")
    }
}
