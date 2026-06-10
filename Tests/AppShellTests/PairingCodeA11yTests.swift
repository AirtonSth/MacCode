import XCTest
@testable import AppShell

/// Tests for the pure accessibility-label helper for pairing codes.
///
/// WHY: The 6-digit security code in the pairing sheet is read by VoiceOver
/// as a single string (e.g. "342781"), which forces the user to hear "three
/// hundred forty-two thousand seven hundred eighty-one" — unhelpful for
/// security verification. The fix spaces the digits so VoiceOver announces
/// each individually: "3 4 2 7 8 1". These tests pin the contract of the
/// pure mapping so it cannot silently regress.
///
///   R1 — each character in the code is separated by a single space.
///   R2 — the label is prefixed with "Pairing code: " so the field role is
///         clear to VoiceOver before the digits are read.
///   R3 — single-character codes are handled without trailing spaces.
///   R4 — empty codes produce just the prefix (no crash, no double space).
final class PairingCodeA11yTests: XCTestCase {

    // MARK: - R1 + R2: standard 6-digit code

    func test_sixDigitCode_spacedAndPrefixed() {
        let label = AppDelegate.pairingCodeAccessibilityLabel("342781")
        XCTAssertEqual(label, "Pairing code: 3 4 2 7 8 1",
            "6-digit code must be spaced so VoiceOver announces each digit individually, " +
            "and prefixed so the field purpose is clear before the digits begin")
    }

    // MARK: - R1: general digit spacing

    func test_codeCharactersAreSeparatedBySingleSpace() {
        let label = AppDelegate.pairingCodeAccessibilityLabel("ABC")
        XCTAssertEqual(label, "Pairing code: A B C",
            "all characters must be separated by exactly one space regardless of value")
    }

    // MARK: - R3: single character

    func test_singleCharCode_noTrailingSpace() {
        let label = AppDelegate.pairingCodeAccessibilityLabel("9")
        XCTAssertEqual(label, "Pairing code: 9",
            "a single-character code must not acquire a trailing space that would " +
            "produce a confusing extra pause when read by VoiceOver")
    }

    // MARK: - R4: empty string

    func test_emptyCode_producesOnlyPrefix() {
        let label = AppDelegate.pairingCodeAccessibilityLabel("")
        XCTAssertEqual(label, "Pairing code: ",
            "an empty code must produce only the prefix without crashing or " +
            "emitting extra spaces — the fallback copy is better than a crash")
    }
}
