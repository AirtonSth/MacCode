import XCTest
@testable import Surfaces

/// Tests for the pure FontZoomLevel helper that clamps, serializes, and
/// deserializes the terminal font zoom delta (in 1-pt steps) for per-workspace
/// persistence.
///
/// WHY these tests matter:
/// - The zoom delta is stored as a raw string in the KV settings table.
///   A corrupt or out-of-range stored value must never produce an unusable
///   terminal (font too large to show the grid, or so small it renders as
///   invisible glyphs). Clamping before every read and write enforces that
///   invariant without relying on callers.
/// - The round-trip test pins the serialization contract: a stored value must
///   decode to the exact same int so restoring zoom is not lossy or offset.
/// - The nil-on-invalid test ensures that a missing or corrupt KV entry falls
///   back gracefully to the default zoom (delta 0) rather than applying garbage.
///
/// No @MainActor annotation needed: FontZoomLevel is a pure nonisolated enum.
final class FontZoomLevelTests: XCTestCase {

    // MARK: - clamp

    func test_clamp_withinBounds_returnsUnchanged() {
        // A value already inside [-20, 40] must pass through unchanged.
        // If clamp wrongly offset values, stored zoom would drift each restart.
        XCTAssertEqual(FontZoomLevel.clamp(0), 0,
            "zero (no zoom applied) must round-trip through clamp unchanged")
        XCTAssertEqual(FontZoomLevel.clamp(5), 5,
            "a typical zoom-in delta must survive clamp untouched")
        XCTAssertEqual(FontZoomLevel.clamp(-3), -3,
            "a typical zoom-out delta must survive clamp untouched")
        XCTAssertEqual(FontZoomLevel.clamp(FontZoomLevel.maxSteps), FontZoomLevel.maxSteps,
            "the maximum boundary value must be accepted as-is")
        XCTAssertEqual(FontZoomLevel.clamp(FontZoomLevel.minSteps), FontZoomLevel.minSteps,
            "the minimum boundary value must be accepted as-is")
    }

    func test_clamp_aboveMax_clampedToMax() {
        // An absurdly large font (e.g. 200pt) makes the terminal unusable: no
        // characters fit on screen. The stored delta must be capped so a runaway
        // Cmd-+ sequence or a corrupt stored value cannot lock the user out.
        let result = FontZoomLevel.clamp(FontZoomLevel.maxSteps + 1)
        XCTAssertEqual(result, FontZoomLevel.maxSteps,
            "a zoom delta above the maximum must be clamped to maxSteps to prevent unusably large fonts")
    }

    func test_clamp_belowMin_clampedToMin() {
        // An extremely negative delta renders text invisible (sub-1pt).
        // Clamping to minSteps guarantees at least a legible minimum size.
        let result = FontZoomLevel.clamp(FontZoomLevel.minSteps - 1)
        XCTAssertEqual(result, FontZoomLevel.minSteps,
            "a zoom delta below the minimum must be clamped to minSteps to prevent invisible text")
    }

    // MARK: - serialize / deserialize round-trip

    func test_serialize_deserialize_roundTrip() {
        // A zoom delta written to the settings table and read back must decode
        // to the exact same integer. Any off-by-one or format change would cause
        // the terminal to open with the wrong font size on every restart.
        let cases = [FontZoomLevel.minSteps, -1, 0, 1, FontZoomLevel.maxSteps]
        for steps in cases {
            let serialized = FontZoomLevel.serialize(steps)
            let restored = FontZoomLevel.deserialize(serialized)
            XCTAssertEqual(restored, steps,
                "serialize -> deserialize must be the identity for in-range value \(steps)")
        }
    }

    // MARK: - deserialize edge cases

    func test_deserialize_emptyString_returnsNil() {
        // An absent KV key returns an empty or nil string. The caller must treat
        // nil as \"use default zoom\" (delta 0) rather than applying a stale value.
        XCTAssertNil(FontZoomLevel.deserialize(""),
            "an empty stored string (absent key) must deserialize to nil so the caller defaults to 0")
    }

    func test_deserialize_nonNumericString_returnsNil() {
        // A corrupt or migrated-away key value must not crash or apply garbage zoom.
        XCTAssertNil(FontZoomLevel.deserialize("not-a-number"),
            "a non-numeric stored string must deserialize to nil rather than crashing or applying garbage")
    }

    func test_deserialize_outOfRangeValue_clamps() {
        // If an old app version stored an unclamped value (e.g. before bounds were
        // introduced), reading it must still produce a safe result. The clamping on
        // deserialization is the last line of defense.
        let tooHigh = FontZoomLevel.serialize(FontZoomLevel.maxSteps + 100)
        // serialize itself clamps, but construct the raw string manually to test
        // the deserialization clamp independently.
        let rawHigh = String(FontZoomLevel.maxSteps + 100)
        let rawLow = String(FontZoomLevel.minSteps - 100)
        XCTAssertEqual(FontZoomLevel.deserialize(rawHigh), FontZoomLevel.maxSteps,
            "deserializing an out-of-range high value must clamp to maxSteps")
        XCTAssertEqual(FontZoomLevel.deserialize(rawLow), FontZoomLevel.minSteps,
            "deserializing an out-of-range low value must clamp to minSteps")
        _ = tooHigh // silence unused-result warning
    }
}

final class TerminalFontSizeSettingTests: XCTestCase {

    func test_normalized_zeroMeansGhosttyDefault() {
        XCTAssertEqual(TerminalFontSizeSetting.normalized(0), 0,
                       "0 must keep Ghostty's configured default instead of forcing an app font size")
    }

    func test_normalized_clampsToLegibleRange() {
        XCTAssertEqual(TerminalFontSizeSetting.normalized(1), TerminalFontSizeSetting.minSize,
                       "too-small stored sizes must clamp up so text remains legible")
        XCTAssertEqual(TerminalFontSizeSetting.normalized(200), TerminalFontSizeSetting.maxSize,
                       "too-large stored sizes must clamp down so the terminal grid remains usable")
    }

    func test_normalized_rejectsNonFiniteValues() {
        XCTAssertEqual(TerminalFontSizeSetting.normalized(.nan), 0,
                       "a corrupt NaN setting must fall back to Ghostty default")
        XCTAssertEqual(TerminalFontSizeSetting.normalized(.infinity), 0,
                       "a corrupt infinite setting must fall back to Ghostty default")
    }

    func test_displayLabelMatchesPersistedChoice() {
        XCTAssertEqual(TerminalFontSizeSetting.displayLabel(0), "Ghostty default")
        XCTAssertEqual(TerminalFontSizeSetting.displayLabel(15.6), "16 pt",
                       "settings UI must show the exact normalized size new terminals will receive")
    }
}
