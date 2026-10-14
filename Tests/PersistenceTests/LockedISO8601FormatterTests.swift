import XCTest
@testable import Persistence

/// The fast path must be invisible: every stored timestamp, keyset cursor and
/// equality check depends on reading back exactly the Date the formatter would.
final class LockedISO8601FormatterTests: XCTestCase {
    private func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        if fractional { formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
        return formatter
    }

    func test_canonicalParseIsBitIdenticalToTheFormatter_becauseStoredDatesAreComparedForEquality() {
        var generator = SystemRandomNumberGenerator()
        for fractional in [false, true] {
            let reference = formatter(fractional: fractional)
            let wrapped = LockedISO8601Formatter(formatter(fractional: fractional))
            // 1900-01-01 … 2200-01-01 in milliseconds, plus both ends.
            let low: Int64 = -2_208_988_800_000, high: Int64 = 7_258_118_400_000
            var instants = [low, high - 1, 0, 951_782_400_000 /* 2000-02-29 */]
            for _ in 0..<100_000 { instants.append(Int64.random(in: low..<high, using: &generator)) }
            for milliseconds in instants {
                let text = reference.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
                XCTAssertNotNil(LockedISO8601Formatter.parseCanonical(text, fractional: fractional), text)
                let expected = reference.date(from: text)?.timeIntervalSinceReferenceDate.bitPattern
                let actual = wrapped.date(from: text)?.timeIntervalSinceReferenceDate.bitPattern
                if expected != actual {
                    XCTFail("\(text): formatter \(String(describing: expected)) fast \(String(describing: actual))")
                    return
                }
            }
        }
    }

    func test_nonCanonicalInputStillGetsTheFormattersAnswer_becauseOnlyTheWrittenShapesAreShortcut() {
        let inputs = [
            "2026-02-30T00:00:00Z", "2026-13-01T00:00:00Z", "2026-10-14T24:00:00Z", "2026-10-14T23:60:00Z",
            "2026-10-14T23:59:60Z", "2026-10-14T04:14:42z", "2026-10-14T04:14:42+00:00", "2026-10-14T04:14:42+02:00",
            "2026-10-14T04:14:42.1Z", "2026-10-14T04:14:42.12Z", "2026-10-14T04:14:42.123456Z", "2026-10-14 04:14:42Z",
            "1899-12-31T23:59:59Z", "1582-10-10T00:00:00Z", "0001-01-01T00:00:00Z", "+2026-10-14T04:14:42Z",
            "2026-10-14T04:14:42.123Z", "2026-10-14T04:14:42Z", "", "garbage", "2026-1O-14T04:14:42Z",
        ]
        for fractional in [false, true] {
            let reference = formatter(fractional: fractional)
            let wrapped = LockedISO8601Formatter(formatter(fractional: fractional))
            for input in inputs {
                XCTAssertEqual(
                    wrapped.date(from: input)?.timeIntervalSinceReferenceDate.bitPattern,
                    reference.date(from: input)?.timeIntervalSinceReferenceDate.bitPattern,
                    "\(fractional ? "fractional" : "plain") \(input)"
                )
            }
        }
    }

    func test_otherFormatOptionsNeverTakeTheFastPath_becauseItOnlyKnowsTwoShapes() {
        let custom = ISO8601DateFormatter()
        custom.formatOptions = [.withFullDate]
        let wrapped = LockedISO8601Formatter(custom)
        for input in ["2026-10-14T04:14:42Z", "2026-10-14"] {
            XCTAssertEqual(wrapped.date(from: input), custom.date(from: input), input)
        }
    }
}
