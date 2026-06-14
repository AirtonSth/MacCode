import XCTest
@testable import DistillCore

/// I2.4 verbatim fail-open + I6.4 gated char limit with safe truncation.
final class I2I6FinalTests: XCTestCase {
    // I2.4: a verbatim fallback serves the original with no savings and no handle.
    func test_verbatimFallbackServesOriginalWithNoSavings() {
        let lossy = DistillResponse(
            requestID: UUID(), output: "short summary", inputCharacters: 100,
            inputTokens: 50, outputTokens: 5, originalHandle: nil)
        let original = String(repeating: "x", count: 100)
        let fallback = lossy.verbatimFallback(input: original)
        XCTAssertEqual(fallback.output, original)
        XCTAssertEqual(fallback.savedTokens, 0, "verbatim fallback claims no savings")
        XCTAssertNil(fallback.originalHandle)
    }

    // I6.4: gated 4000→2000, and truncation keeps failing-test lines + an elision marker.
    func test_charGateLimitAndSafeTruncation() {
        XCTAssertEqual(CommandOutputCharGate.limit(gatedToTwoThousand: false), 4000)
        XCTAssertEqual(CommandOutputCharGate.limit(gatedToTwoThousand: true), 2000)

        var lines = (1...100).map { "ordinary log line number \($0) with some filler text here" }
        lines.append("FAILED tests/test_login.py::test_expired")  // last line, past any small cut
        let text = lines.joined(separator: "\n")
        let truncated = CommandOutputCharGate.truncate(text, limit: 500)
        XCTAssertLessThan(truncated.count, text.count)
        XCTAssertTrue(truncated.contains("FAILED tests/test_login.py::test_expired"), "failing line must survive truncation (I6.4)")
        XCTAssertTrue(truncated.contains("lines elided"), "explicit elision marker, never silent")
        // Never split mid-line: every kept line is a whole original line (or the marker).
        for line in truncated.split(separator: "\n").map(String.init) where !line.contains("elided") {
            XCTAssertTrue(lines.contains(line), "no mid-line split")
        }
    }
}
