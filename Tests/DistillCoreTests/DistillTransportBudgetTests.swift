import XCTest
@testable import DistillCore

/// Item 218: explicit transport budget for the optimizer client. These tests
/// pin the PURE helpers (no live service): the request timeout band, the ~32MB
/// stdin cap, head/tail truncation, and original-payload preservation.
final class DistillTransportBudgetTests: XCTestCase {

    // WHY: the budget exists so a slow/hung optimizer never blocks the agent's
    // shell for ~a minute. If this constant drifts out of [5,10]s the whole
    // point (fail fast, fall back to raw) is defeated.
    func testRequestTimeoutIsInFiveToTenSecondBand() {
        let t = DistillServiceClient.requestTimeoutSeconds
        XCTAssertGreaterThanOrEqual(t, 5, "timeout must be >= 5s per item 218 budget")
        XCTAssertLessThanOrEqual(t, 10, "timeout must be <= 10s so shell never hangs ~a minute")
    }

    // WHY: truncation is best-effort optimization only. A payload within budget
    // must reach the optimizer byte-for-byte, otherwise we would corrupt the
    // common (small) case for no reason.
    func testUnderCapPassesThroughUnchanged() {
        let input = "hello optimizer, this fits well under the cap"
        let out = DistillServiceClient.headTailTruncate(input, cap: DistillServiceClient.stdinByteCap)
        XCTAssertEqual(out, input)
    }

    // WHY: the cap is the safety valve. Over-cap input must come back strictly
    // within the byte budget; if it could exceed the cap the transport budget
    // would be meaningless.
    func testOverCapResultStaysWithinByteCap() {
        let cap = 1_000
        let input = String(repeating: "A", count: cap * 4)
        let out = DistillServiceClient.headTailTruncate(input, cap: cap)
        XCTAssertLessThanOrEqual(out.utf8.count, cap, "truncated wire payload must never exceed cap")
        XCTAssertLessThan(out.utf8.count, input.utf8.count, "over-cap input must actually shrink")
    }

    // WHY: head/tail preservation is the contract. The optimizer must see both
    // ends of the data (the start and the failing tail of a log), separated by a
    // clear marker, or the summary loses the most diagnostic regions.
    func testOverCapPreservesHeadAndTailWithMarker() {
        let cap = 2_000
        let head = String(repeating: "H", count: 500)
        let tail = String(repeating: "T", count: 500)
        let middle = String(repeating: "M", count: cap * 5)
        let input = head + middle + tail

        let out = DistillServiceClient.headTailTruncate(input, cap: cap)

        XCTAssertTrue(out.hasPrefix(head), "head of original must be preserved on the wire")
        XCTAssertTrue(out.hasSuffix(tail), "tail of original must be preserved on the wire")
        XCTAssertTrue(
            out.contains(DistillServiceClient.truncationMarker),
            "a truncation marker must separate head from tail so the omission is explicit"
        )
        XCTAssertLessThanOrEqual(out.utf8.count, cap)
    }

    // WHY: store-before-loss (N5). The wire copy may be truncated, but the
    // caller's own DistillRequest.input must remain the byte-exact original so
    // it can fall back to raw when the optimizer is unavailable.
    func testOriginalRequestInputIsPreservedAfterCapping() {
        let original = String(repeating: "X", count: DistillServiceClient.stdinByteCap + 4_096)
        let request = DistillRequest(
            mode: .commandOutput,
            input: original,
            cacheState: "tool_output_hooked",
            rerankQuery: "panic root cause",
            topK: 3,
            encoderLane: "colbert-shadow"
        )

        let wire = DistillServiceClient.cappedForWire(request)

        // Original untouched (value type): caller still holds full payload.
        XCTAssertEqual(request.input, original, "caller's original payload must never be mutated")
        // Wire copy shrunk and within budget.
        XCTAssertLessThanOrEqual(wire.input.utf8.count, DistillServiceClient.stdinByteCap)
        XCTAssertLessThan(wire.input.utf8.count, original.utf8.count)
        // Every non-input field carried over unchanged so the optimizer request
        // is otherwise identical.
        XCTAssertEqual(wire.id, request.id)
        XCTAssertEqual(wire.mode, request.mode)
        XCTAssertEqual(wire.priority, request.priority)
        XCTAssertEqual(wire.cacheState, request.cacheState)
        XCTAssertEqual(wire.rerankQuery, request.rerankQuery)
        XCTAssertEqual(wire.topK, request.topK)
        XCTAssertEqual(wire.encoderLane, request.encoderLane)
        XCTAssertEqual(wire.maxOutputCharacters, request.maxOutputCharacters)
    }

    // WHY: under-cap requests must not be copied/altered at all -- the success
    // path stays identical, protecting the hot common case.
    func testUnderCapRequestReturnsIdenticalInput() {
        let request = DistillRequest(mode: .commandOutput, input: "small payload")
        let wire = DistillServiceClient.cappedForWire(request)
        XCTAssertEqual(wire.input, request.input)
    }

    // WHY: multibyte safety. Truncation cuts on Character boundaries, so the
    // wire string is always valid UTF-8 even when the cut lands mid-emoji.
    func testTruncationDoesNotSplitMultibyteScalars() {
        let cap = 64
        let input = String(repeating: "😀", count: 200) // 4 UTF-8 bytes each
        let out = DistillServiceClient.headTailTruncate(input, cap: cap)
        XCTAssertLessThanOrEqual(out.utf8.count, cap)
        // Round-tripping through UTF-8 must be lossless => no split scalar.
        XCTAssertEqual(Array(out.utf8), Array(String(decoding: Array(out.utf8), as: UTF8.self).utf8))
    }
}
