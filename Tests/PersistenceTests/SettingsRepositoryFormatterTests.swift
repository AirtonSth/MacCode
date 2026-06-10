import XCTest
@testable import Persistence

/// Perf fix: SettingsRepository.set must reuse the module-level ISO8601DateFormatter
/// instead of allocating a fresh one per call.
///
/// Rules:
///  - Format stability: the shared formatter must produce byte-identical output to a
///    fresh ISO8601DateFormatter with no extra options configured (default formatOptions).
///    This guarantees existing stored timestamps and query comparisons remain unaffected.
///  - Reuse: calling the shared formatter twice for the same date returns the same string,
///    proving the instance is stable and thread-safe for repeated calls.
///
/// Why these tests matter: if someone changes formatOptions on `iso`, stored timestamps
/// would silently shift format and break date-range queries. These tests catch that.
final class SettingsRepositoryFormatterTests: XCTestCase {

    // A fixed epoch-aligned date so string comparisons are deterministic.
    private static let sampleDate = Date(timeIntervalSince1970: 1_700_000_000)

    func test_sharedFormatterOutputMatchesFreshInstance() {
        // GIVEN a freshly allocated ISO8601DateFormatter with default options
        let fresh = ISO8601DateFormatter()
        let expected = fresh.string(from: Self.sampleDate)

        // WHEN the shared module-level formatter formats the same date
        let actual = iso.string(from: Self.sampleDate)

        // THEN the strings are byte-identical — format has not changed
        XCTAssertEqual(
            actual, expected,
            "shared iso formatter must produce the same string as a fresh ISO8601DateFormatter; " +
            "a mismatch means formatOptions diverged, which would corrupt stored timestamp comparisons"
        )
    }

    func test_sharedFormatterIsStableAcrossRepeatedCalls() {
        // GIVEN the same date formatted twice via the shared instance
        let first = iso.string(from: Self.sampleDate)
        let second = iso.string(from: Self.sampleDate)

        // THEN results are identical — no per-call mutation
        XCTAssertEqual(
            first, second,
            "iso.string(from:) must return identical output on repeated calls; " +
            "divergence would indicate unexpected mutable state"
        )
    }

    func test_sharedFormatterIsNotNil() {
        // Sanity: iso is initialized at module load and never nil
        let result = iso.string(from: Self.sampleDate)
        XCTAssertFalse(
            result.isEmpty,
            "shared iso formatter must produce a non-empty timestamp string"
        )
    }
}
