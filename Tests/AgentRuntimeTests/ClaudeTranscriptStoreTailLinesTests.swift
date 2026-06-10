import XCTest
@testable import AgentRuntime

/// Tests for ClaudeTranscriptStore.tailLines(from:maxEvents:).
///
/// WHY: the tail helper replaces a whole-file String load with a bounded
/// backward scan so multi-MB sessions consume only O(maxEvents * lineSize)
/// memory instead of O(fileSize).  These tests verify correctness of the
/// pure seam before the FileHandle integration path runs.
final class ClaudeTranscriptStoreTailLinesTests: XCTestCase {

    // MARK: - Helpers

    private func data(_ lines: [String]) -> Data {
        lines.joined(separator: "\n").appending("\n").data(using: .utf8)!
    }

    // MARK: - last N lines returned in order

    func test_tailLines_moreLinesThanMax_returnsLastN() {
        // WHY: the primary contract - when the file has more lines than
        // maxEvents, only the last maxEvents lines are returned; earlier lines
        // are discarded so memory is bounded.
        let input = ["alpha", "beta", "gamma", "delta", "epsilon"]
        let result = ClaudeTranscriptStore.tailLines(from: data(input), maxEvents: 3)
        XCTAssertEqual(result, ["gamma", "delta", "epsilon"],
                       "Expected last 3 lines in forward order")
    }

    func test_tailLines_exactlyMaxLines_returnsAll() {
        // WHY: boundary - when line count equals maxEvents the helper must not
        // drop any line; an off-by-one would silently lose the oldest kept event.
        let input = ["line1", "line2", "line3"]
        let result = ClaudeTranscriptStore.tailLines(from: data(input), maxEvents: 3)
        XCTAssertEqual(result, ["line1", "line2", "line3"])
    }

    func test_tailLines_fewerLinesThanMax_returnsAll() {
        // WHY: small sessions (fresh threads) have fewer lines than maxEvents;
        // the helper must return all of them, not an empty or truncated set.
        let input = ["only-one", "only-two"]
        let result = ClaudeTranscriptStore.tailLines(from: data(input), maxEvents: 100)
        XCTAssertEqual(result, ["only-one", "only-two"])
    }

    func test_tailLines_maxEventsZero_returnsEmpty() {
        // WHY: maxEvents=0 is a degenerate caller; the helper must return an
        // empty array rather than crash or return arbitrary lines.
        let input = ["some-line"]
        let result = ClaudeTranscriptStore.tailLines(from: data(input), maxEvents: 0)
        XCTAssertTrue(result.isEmpty)
    }

    func test_tailLines_emptyData_returnsEmpty() {
        // WHY: an empty file (newly created session) must not crash; it returns
        // empty so readTranscript emits only the threadStarted sentinel.
        let result = ClaudeTranscriptStore.tailLines(from: Data(), maxEvents: 10)
        XCTAssertTrue(result.isEmpty)
    }

    func test_tailLines_singleLine_returnsIt() {
        // WHY: single-line files are valid (e.g. one-turn sessions); the
        // backward scanner must not discard the line as a "partial prefix".
        let input = ["{\"type\":\"assistant\"}"]
        let result = ClaudeTranscriptStore.tailLines(from: data(input), maxEvents: 5)
        XCTAssertEqual(result, ["{\"type\":\"assistant\"}"])
    }

    func test_tailLines_preservesForwardOrder() {
        // WHY: the event stream depends on temporal order; reversed or shuffled
        // lines would produce an incoherent transcript display.
        let input = (1...10).map { "line\($0)" }
        let result = ClaudeTranscriptStore.tailLines(from: data(input), maxEvents: 5)
        XCTAssertEqual(result, ["line6", "line7", "line8", "line9", "line10"])
    }

    func test_tailLines_maxEventsOne_returnsLastLine() {
        // WHY: maxEvents=1 is the extreme boundary; verifies the loop exits
        // after exactly one qualifying line and that it is the very last one.
        let input = ["first", "second", "third"]
        let result = ClaudeTranscriptStore.tailLines(from: data(input), maxEvents: 1)
        XCTAssertEqual(result, ["third"])
    }
}
