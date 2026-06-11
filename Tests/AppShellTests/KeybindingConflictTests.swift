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
        XCTAssertEqual(result.first?.builtInMenuLabel, "Quit RemoteCode")
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
}
