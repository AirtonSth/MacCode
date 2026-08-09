import XCTest
@testable import SocketServer

/// `surface.read_text` bounded-read contract.
///
/// WHY this exists: the iOS terminal mirror calls `surface.read_text` on its
/// hottest path and the response carried the whole transcript twice (`text` plus a
/// full `ansi_text` copy with scrollback) with no size parameter. On a ~200 kbps
/// cellular link that dominated the session's bytes. These tests pin both halves of
/// the fix: the window really bounds the payload, and it never lies about having
/// returned the whole transcript.
final class SurfaceReadTextWindowTests: XCTestCase {

    // MARK: Back-compat

    /// WHY: the iOS app must keep working against a host that predates this change
    /// and vice versa. A request without `max_bytes` must be byte-for-byte what it
    /// was before, with no new keys that a strict client could reject.
    func testAbsentMaxBytesLeavesTheResponseCompletelyUnchanged() {
        let fields: [String: JSONValue] = [
            "text": .string("hello\nworld"),
            "ansi_text": .string("\u{1B}[32mhello\u{1B}[0m\nworld"),
            "complete": .bool(true),
        ]
        XCTAssertEqual(SurfaceReadTextWindow.applied(to: fields, maxBytes: nil), fields)
    }

    /// WHY: `max_bytes: 0` must not be a way to ask for an empty transcript — that
    /// would let a client silently blind itself and then render "nothing happened".
    func testNonPositiveMaxBytesIsTreatedAsUnbounded() {
        let fields: [String: JSONValue] = ["text": .string("abc")]
        XCTAssertEqual(SurfaceReadTextWindow.applied(to: fields, maxBytes: 0), fields)
        XCTAssertEqual(SurfaceReadTextWindow.applied(to: fields, maxBytes: -10), fields)
        XCTAssertNil(SurfaceReadTextWindow.requestedMaxBytes(0))
        XCTAssertNil(SurfaceReadTextWindow.requestedMaxBytes(-1))
        XCTAssertEqual(SurfaceReadTextWindow.requestedMaxBytes(64), 64)
    }

    /// WHY: a budget larger than the transcript must not mark the response as
    /// truncated, or the client would show a "history was dropped" affordance for a
    /// complete transcript.
    func testBudgetLargerThanTranscriptIsNotReportedAsTruncated() {
        let window = SurfaceReadTextWindow.tail(of: "short", maxBytes: 4096)
        XCTAssertEqual(window.text, "short")
        XCTAssertFalse(window.truncatedHead)
    }

    // MARK: Windowing

    /// WHY: a terminal viewport shows the NEWEST output. Keeping the head would
    /// return the beginning of a long-running log and hide what just happened.
    func testWindowKeepsTheTailNotTheHead() {
        let text = (1...50).map { "line \($0)" }.joined(separator: "\n")
        let window = SurfaceReadTextWindow.tail(of: text, maxBytes: 40)
        XCTAssertTrue(window.truncatedHead)
        XCTAssertTrue(
            window.text.hasSuffix("line 50"),
            "the window must end at the newest output, got: \(window.text)"
        )
        XCTAssertFalse(window.text.contains("line 1\n"), "old head must be dropped")
        XCTAssertLessThanOrEqual(window.text.utf8.count, 40)
    }

    /// WHY: the budget is a wire budget. If the window could exceed it the parameter
    /// would not actually bound what crosses a metered link.
    func testWindowNeverExceedsTheRequestedByteBudget() {
        let text = String(repeating: "x", count: 10_000)
        for budget in [1, 7, 64, 512, 9_999] {
            let window = SurfaceReadTextWindow.tail(of: text, maxBytes: budget)
            XCTAssertLessThanOrEqual(
                window.text.utf8.count,
                budget,
                "budget \(budget) was exceeded"
            )
            XCTAssertTrue(window.truncatedHead)
        }
    }

    /// WHY: cutting mid-scalar would hand the client invalid UTF-8, which either
    /// throws in the JSON encoder or renders as replacement characters in the
    /// terminal. Multi-byte output (box drawing, emoji, CJK) is common in TUIs.
    func testWindowNeverSplitsAMultiByteScalar() {
        // Each snowman is 3 UTF-8 bytes; a naive byte cut at 10 would split one.
        let text = String(repeating: "☃", count: 20)
        let window = SurfaceReadTextWindow.tail(of: text, maxBytes: 10)
        XCTAssertLessThanOrEqual(window.text.utf8.count, 10)
        XCTAssertEqual(
            window.text,
            String(repeating: "☃", count: 3),
            "must drop to whole scalars rather than emit a partial sequence"
        )
        XCTAssertFalse(window.text.unicodeScalars.contains("\u{FFFD}"))
    }

    /// WHY: a scalar boundary can still be inside one user-visible grapheme. The
    /// host must not return only a combining mark or half a family emoji when the
    /// byte budget cannot fit the whole Character; that would corrupt terminal text.
    func testWindowNeverSplitsAnExtendedGraphemeCluster() {
        for cluster in ["e\u{301}", "👨‍👩‍👧‍👦"] {
            let window = SurfaceReadTextWindow.tail(
                of: "prefix" + cluster,
                maxBytes: cluster.utf8.count - 1
            )
            XCTAssertEqual(window.text, "", "cluster was split: \(window.text.debugDescription)")
        }
    }

    /// WHY: the first retained line should be whole so the mirror never renders a
    /// line that starts mid-word as if that were the real output. It must drop only
    /// the partial leading line, not every line but the last — over-trimming would
    /// throw away scrollback the budget could afford.
    func testWindowDropsOnlyThePartialLeadingLine() {
        // 22 bytes. A 14-byte tail lands mid-way through the "aaaa" line, so the
        // window should start at the next line boundary and keep everything after it.
        let text = "aaaaaaaaaa\nbbbbb\nccccc"
        let window = SurfaceReadTextWindow.tail(of: text, maxBytes: 14)
        XCTAssertTrue(window.truncatedHead)
        XCTAssertEqual(
            window.text,
            "bbbbb\nccccc",
            "expected the partial leading line dropped and both whole lines kept"
        )
        XCTAssertFalse(
            window.text.hasPrefix("a"),
            "a partial leading line must never survive the cut"
        )
    }

    /// WHY: when no newline fits, returning nothing would be worse than returning a
    /// partial line — the user would see an empty terminal for live output.
    func testWindowStillReturnsContentWhenNoNewlineFitsInTheBudget() {
        let window = SurfaceReadTextWindow.tail(
            of: String(repeating: "z", count: 100),
            maxBytes: 10
        )
        XCTAssertEqual(window.text.utf8.count, 10)
        XCTAssertTrue(window.truncatedHead)
    }

    // MARK: Honesty

    /// WHY: this is the anti-fake-freshness gate. A bounded response is a WINDOW,
    /// and the client must be able to tell it apart from a complete transcript;
    /// otherwise it would cache a partial transcript as the authoritative one.
    func testTruncatedResponseAdvertisesTruncationAndTheAppliedBudget() {
        let fields: [String: JSONValue] = [
            "text": .string(String(repeating: "a", count: 500)),
            "complete": .bool(true),
        ]
        let applied = SurfaceReadTextWindow.applied(to: fields, maxBytes: 100)
        XCTAssertEqual(applied[SurfaceReadTextWindow.truncatedHeadKey]?.boolValue, true)
        XCTAssertEqual(applied[SurfaceReadTextWindow.appliedMaxBytesKey]?.intValue, 100)
    }

    /// WHY: if only the plain text were bounded, a client asking for a bounded read
    /// would still receive an unbounded ANSI copy — the larger of the two — and the
    /// parameter would buy almost nothing on the link it exists for.
    func testBothTranscriptCarriersAreBoundedByTheSameBudget() {
        let fields: [String: JSONValue] = [
            "text": .string(String(repeating: "a", count: 5_000)),
            "ansi_text": .string(String(repeating: "b", count: 5_000)),
        ]
        let applied = SurfaceReadTextWindow.applied(to: fields, maxBytes: 256)
        XCTAssertLessThanOrEqual(applied["text"]!.stringValue!.utf8.count, 256)
        XCTAssertLessThanOrEqual(applied["ansi_text"]!.stringValue!.utf8.count, 256)
    }

    /// WHY: a bounded read must not become a way to lose the sequence barrier or the
    /// partial/health metadata the client uses to decide whether to trust the body.
    func testWindowingPreservesEveryNonTranscriptField() {
        let fields: [String: JSONValue] = [
            "text": .string(String(repeating: "a", count: 500)),
            "surface_seq": .number(42),
            "complete": .bool(false),
            "partial": .bool(true),
            "partial_reason": .string("pending_bytes"),
            "pending_bytes": .number(17),
            "rows": .number(40),
            "cols": .number(120),
        ]
        let applied = SurfaceReadTextWindow.applied(to: fields, maxBytes: 64)
        XCTAssertEqual(applied["surface_seq"]?.intValue, 42)
        XCTAssertEqual(applied["complete"]?.boolValue, false)
        XCTAssertEqual(applied["partial"]?.boolValue, true)
        XCTAssertEqual(applied["partial_reason"]?.stringValue, "pending_bytes")
        XCTAssertEqual(applied["pending_bytes"]?.intValue, 17)
        XCTAssertEqual(applied["rows"]?.intValue, 40)
        XCTAssertEqual(applied["cols"]?.intValue, 120)
    }

    /// WHY: a response whose transcript already fit must not be labelled truncated,
    /// even though a budget was supplied — otherwise the client can never distinguish
    /// "you have everything" from "there is more".
    func testUntruncatedBoundedResponseReportsTruncatedFalse() {
        let fields: [String: JSONValue] = ["text": .string("tiny")]
        let applied = SurfaceReadTextWindow.applied(to: fields, maxBytes: 4096)
        XCTAssertEqual(applied[SurfaceReadTextWindow.truncatedHeadKey]?.boolValue, false)
        XCTAssertEqual(applied["text"]?.stringValue, "tiny")
    }
}
