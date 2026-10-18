import XCTest
@testable import AppShell

/// Tests for KeybindingConflictDetector pure logic (todo/macos-app.md :142).
///
/// Business rule: a user keybinding whose normalized chord equals a built-in
/// menu shortcut SILENTLY shadows that menu command. The Settings pane must
/// surface this, so the detector must report every such collision regardless of
/// how the user spelled the chord (Cmd+W vs mod+w). These tests encode WHY each
/// behavior matters, not just that it returns a value.
final class KeybindingConflictTests: XCTestCase {

    // MARK: - conflicts()

    func test_userBinding_cmdW_conflictsWith_closeTab() {
        // WHY: cmd+w is the File > Close Tab menu shortcut. A user rebinding it
        // would silently shadow a core menu action; that MUST be surfaced.
        let bindings = [Keybinding(key: "cmd+w", command: "tab.split", when: nil)]
        let result = KeybindingConflictDetector.conflicts(userBindings: bindings)
        XCTAssertEqual(result.count, 1, "cmd+w must produce exactly one conflict")
        XCTAssertEqual(result.first?.builtInMenuLabel, "Close Tab",
                       "the conflict must name the shadowed menu item so the user knows what breaks")
        XCTAssertEqual(result.first?.userCommand, "tab.split",
                       "the conflict must carry the user's command for display")
    }

    func test_nonConflictingChord_yieldsNoConflict() {
        // WHY: mod+shift+k is not used by any built-in menu item, so a binding on
        // it is safe and must NOT be flagged (false positives erode trust in the
        // warning icon).
        let bindings = [Keybinding(key: "mod+shift+k", command: "do.thing", when: nil)]
        let result = KeybindingConflictDetector.conflicts(userBindings: bindings)
        XCTAssertTrue(result.isEmpty, "a chord absent from the built-in map must not conflict")
    }

    func test_normalizationParity_cmdW_and_modW_detectSameConflict() {
        // WHY: the JSON may spell the same chord as "Cmd+W" or "mod+w".
        // Normalization parity guarantees both are caught; otherwise a user could
        // shadow a menu shortcut just by choosing a different spelling.
        let upper = KeybindingConflictDetector.conflicts(
            userBindings: [Keybinding(key: "Cmd+W", command: "x", when: nil)])
        let canonical = KeybindingConflictDetector.conflicts(
            userBindings: [Keybinding(key: "mod+w", command: "x", when: nil)])
        XCTAssertEqual(upper.first?.builtInMenuLabel, "Close Tab")
        XCTAssertEqual(canonical.first?.builtInMenuLabel, "Close Tab")
        XCTAssertEqual(upper.first?.chord, canonical.first?.chord,
                       "both spellings must normalize to the same chord key")
    }

    func test_multipleBindings_onlyConflictingFlagged() {
        // WHY: in a realistic config mixing safe and unsafe bindings, exactly the
        // shadowing one must be reported, preserving binding order.
        let bindings = [
            Keybinding(key: "mod+shift+k", command: "safe", when: nil),
            Keybinding(key: "cmd+q", command: "danger", when: nil)
        ]
        let result = KeybindingConflictDetector.conflicts(userBindings: bindings)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.builtInMenuLabel, "Quit MacCode")
        XCTAssertEqual(result.first?.userCommand, "danger")
    }

    // MARK: - builtInMenuChords invariants

    func test_builtInMenuChords_areAllInNormalizedForm() {
        // WHY: the detector compares chords by string equality against
        // KeybindingConfig.normalize(userKey). If any built-in entry were not in
        // normalized form (stray spaces, unsorted modifiers, "cmd" not "mod"),
        // real conflicts would silently slip through. Guard the invariant.
        for entry in KeybindingConflictDetector.builtInMenuChords {
            XCTAssertEqual(entry.chord, KeybindingConfig.normalize(entry.chord),
                           "built-in chord \(entry.chord) is not in canonical normalized form")
            XCTAssertFalse(entry.chord.contains(" "),
                           "built-in chord \(entry.chord) must not contain spaces")
            XCTAssertFalse(entry.chord.contains("cmd"),
                           "built-in chord \(entry.chord) must use mod, not cmd")
        }
    }

    func test_builtInMenuChords_modifiersAreSorted() {
        // WHY: normalize() sorts modifiers lexically. A hand-written entry like
        // "shift+mod+t" would never match a normalized user key. Re-normalizing
        // each entry and comparing proves the modifier ordering is canonical.
        for entry in KeybindingConflictDetector.builtInMenuChords {
            let mods = entry.chord.split(separator: "+").map(String.init)
                .filter { ["mod", "ctrl", "alt", "opt", "shift"].contains($0) }
            XCTAssertEqual(mods, mods.sorted(),
                           "modifiers in \(entry.chord) must be lexically sorted")
        }
    }

    // MARK: - isNonCharacterKey()

    func test_isNonCharacterKey_trueForF1() {
        // WHY: "f1" is a named function key. AppDelegate writes the key token
        // directly into NSMenuItem.keyEquivalent, which expects a single printable
        // character. "f1" is not a printable character, so the shortcut silently
        // fails. The user must be warned.
        XCTAssertTrue(KeybindingConflictDetector.isNonCharacterKey("f1"),
                      "f1 is a named function key and must be flagged as non-character")
    }

    func test_isNonCharacterKey_trueForSpace() {
        // WHY: "space" is the spelled-out token for the space bar. As a raw
        // keyEquivalent it is not interpreted as the space character, so any
        // binding that relies on it will silently not fire via AppDelegate.
        XCTAssertTrue(KeybindingConflictDetector.isNonCharacterKey("space"),
                      "space token must be flagged as non-character")
    }

    func test_isNonCharacterKey_trueForEscape() {
        // WHY: "escape" is a control key. Writing "escape" into keyEquivalent
        // does not map to the Escape key; the shortcut will not trigger.
        XCTAssertTrue(KeybindingConflictDetector.isNonCharacterKey("escape"),
                      "escape must be flagged as non-character")
    }

    func test_isNonCharacterKey_trueForTab() {
        // WHY: "tab" is a whitespace-control key. Same failure mode: a raw
        // keyEquivalent of "tab" is not recognized by AppKit as the Tab key.
        XCTAssertTrue(KeybindingConflictDetector.isNonCharacterKey("tab"),
                      "tab must be flagged as non-character")
    }

    func test_isNonCharacterKey_trueForArrowUp() {
        // WHY: arrow keys are named navigation keys. Writing "up" into
        // keyEquivalent produces no working shortcut, so the user must be warned.
        XCTAssertTrue(KeybindingConflictDetector.isNonCharacterKey("up"),
                      "up (arrow) must be flagged as non-character")
    }

    func test_isNonCharacterKey_falseForLowercaseLetter() {
        // WHY: "a" is a single printable character. It maps correctly to
        // NSMenuItem.keyEquivalent. A false positive here would erode trust in
        // the warning (users would see warnings on every ordinary binding).
        XCTAssertFalse(KeybindingConflictDetector.isNonCharacterKey("a"),
                       "a single letter must not be flagged as non-character")
    }

    func test_isNonCharacterKey_falseForDigit() {
        // WHY: "1" is a printable digit and works as a raw keyEquivalent. Same
        // false-positive risk as letters.
        XCTAssertFalse(KeybindingConflictDetector.isNonCharacterKey("1"),
                       "a digit must not be flagged as non-character")
    }

    func test_isNonCharacterKey_falseForPunctuation() {
        // WHY: "]" and "," are printable characters used in AppDelegate's own
        // built-in menu chords (Next Tab, Settings). They work as keyEquivalent.
        XCTAssertFalse(KeybindingConflictDetector.isNonCharacterKey("]"),
                       "] must not be flagged as non-character")
        XCTAssertFalse(KeybindingConflictDetector.isNonCharacterKey(","),
                       ", must not be flagged as non-character")
    }

    func test_isNonCharacterKey_stripsModifiersBeforeClassifying() {
        // WHY: a real binding from the JSON looks like "mod+f1" or "mod+shift+escape"
        // after normalize(). isNonCharacterKey must strip modifiers first and
        // classify only the key token, not the full chord string.
        XCTAssertTrue(KeybindingConflictDetector.isNonCharacterKey("mod+f1"),
                      "mod+f1 must be flagged: the key token f1 is non-character")
        XCTAssertTrue(KeybindingConflictDetector.isNonCharacterKey("mod+shift+escape"),
                      "mod+shift+escape must be flagged: the key token escape is non-character")
        XCTAssertFalse(KeybindingConflictDetector.isNonCharacterKey("mod+shift+k"),
                       "mod+shift+k must not be flagged: k is a printable character")
    }

    func test_isNonCharacterKey_caseInsensitiveViaNormalize() {
        // WHY: the user might spell "F1" or "Escape" in the JSON. normalize()
        // lowercases everything, so isNonCharacterKey must handle mixed-case input
        // correctly via the normalize path.
        XCTAssertTrue(KeybindingConflictDetector.isNonCharacterKey("F1"),
                      "F1 (uppercase) must be flagged after normalize lowercases it")
        XCTAssertTrue(KeybindingConflictDetector.isNonCharacterKey("Escape"),
                      "Escape (mixed-case) must be flagged after normalize lowercases it")
    }
}
