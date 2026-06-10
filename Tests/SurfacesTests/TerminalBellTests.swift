import XCTest
@testable import Surfaces

// BellHandler is a pure, non-MainActor helper; no @MainActor annotation needed.
// These tests verify that bell preferences map to the correct effect set.
// WHY: the bell handler is the only code path that decides whether the user
// hears a sound or sees a flash when the PTY emits 0x07. Incorrect mapping
// silently ignores user preferences or produces unwanted side-effects.
final class TerminalBellTests: XCTestCase {

    // MARK: - dot always present

    func test_dot_alwaysTrue_whenSoundOff_flashOff() {
        // The dot (activity indicator) must always be set regardless of prefs;
        // it is the lowest-distraction feedback and must never be suppressed.
        let prefs = BellPreferences(sound: false, flash: false)
        let effects = BellHandler.effects(prefs: prefs)
        XCTAssertTrue(effects.dot,
            "dot must always be true: it is the baseline bell feedback regardless of sound/flash prefs")
    }

    func test_dot_alwaysTrue_whenSoundOn_flashOff() {
        let prefs = BellPreferences(sound: true, flash: false)
        let effects = BellHandler.effects(prefs: prefs)
        XCTAssertTrue(effects.dot,
            "dot must remain true even when sound is enabled; the two effects are independent")
    }

    func test_dot_alwaysTrue_whenSoundOff_flashOn() {
        let prefs = BellPreferences(sound: false, flash: true)
        let effects = BellHandler.effects(prefs: prefs)
        XCTAssertTrue(effects.dot,
            "dot must remain true even when flash is enabled; the two effects are independent")
    }

    func test_dot_alwaysTrue_whenBothOn() {
        let prefs = BellPreferences(sound: true, flash: true)
        let effects = BellHandler.effects(prefs: prefs)
        XCTAssertTrue(effects.dot,
            "dot must remain true when all effects are enabled")
    }

    // MARK: - sound preference maps to playSound effect

    func test_soundPref_true_producesPlaySound() {
        // If the user enables bell sound, the effect must request NSSound.beep().
        // Failing to set playSound=true means the user's preference is silently ignored.
        let prefs = BellPreferences(sound: true, flash: false)
        let effects = BellHandler.effects(prefs: prefs)
        XCTAssertTrue(effects.playSound,
            "sound=true pref must produce playSound=true so NSSound.beep() is called on bell")
    }

    func test_soundPref_false_suppressesPlaySound() {
        // If the user disables bell sound, the effect must NOT request NSSound.beep().
        // Firing the sound when pref is false disturbs the user against their setting.
        let prefs = BellPreferences(sound: false, flash: false)
        let effects = BellHandler.effects(prefs: prefs)
        XCTAssertFalse(effects.playSound,
            "sound=false pref must produce playSound=false so no beep fires")
    }

    // MARK: - flash preference maps to flash effect

    func test_flashPref_true_producesFlash() {
        // If the user enables bell flash, the effect must request a visual flash.
        // Failing to set flash=true means the user's preference is silently ignored
        // (particularly relevant for accessibility / silent environments).
        let prefs = BellPreferences(sound: false, flash: true)
        let effects = BellHandler.effects(prefs: prefs)
        XCTAssertTrue(effects.flash,
            "flash=true pref must produce flash=true so the visual bell is shown on bell")
    }

    func test_flashPref_false_suppressesFlash() {
        // If the user disables flash, no visual disturbance must occur.
        let prefs = BellPreferences(sound: false, flash: false)
        let effects = BellHandler.effects(prefs: prefs)
        XCTAssertFalse(effects.flash,
            "flash=false pref must produce flash=false so no visual flash fires")
    }

    // MARK: - combined: both on

    func test_bothPrefs_true_producesBothEffects() {
        // When the user enables both sound and flash, both effects must fire.
        // A partial delivery (e.g. only sound) silently breaks the user's setting.
        let prefs = BellPreferences(sound: true, flash: true)
        let effects = BellHandler.effects(prefs: prefs)
        XCTAssertTrue(effects.playSound,
            "sound=true + flash=true must produce playSound=true")
        XCTAssertTrue(effects.flash,
            "sound=true + flash=true must produce flash=true")
    }

    // MARK: - combined: both off (default)

    func test_bothPrefs_false_suppressesBothEffects() {
        // Default preferences produce no sound and no flash; only the dot is active.
        // This is the baseline that avoids surprising new users with unexpected sounds.
        let prefs = BellPreferences(sound: false, flash: false)
        let effects = BellHandler.effects(prefs: prefs)
        XCTAssertFalse(effects.playSound,
            "default prefs (sound=false) must not produce sound; new users must not be surprised by unexpected beeps")
        XCTAssertFalse(effects.flash,
            "default prefs (flash=false) must not produce flash")
        XCTAssertTrue(effects.dot,
            "default prefs must still produce the dot as the minimal bell feedback")
    }

    // MARK: - Equatable

    func test_bellPreferences_equatable() {
        // BellPreferences must be Equatable so stored values can be compared
        // against a new incoming value without triggering unnecessary side-effects.
        XCTAssertEqual(BellPreferences(sound: true, flash: false),
                       BellPreferences(sound: true, flash: false),
            "identical BellPreferences must compare equal")
        XCTAssertNotEqual(BellPreferences(sound: true, flash: false),
                          BellPreferences(sound: false, flash: false),
            "differing BellPreferences must not compare equal")
    }

    func test_bellEffects_equatable() {
        XCTAssertEqual(BellEffects(playSound: true, flash: false, dot: true),
                       BellEffects(playSound: true, flash: false, dot: true),
            "identical BellEffects must compare equal")
        XCTAssertNotEqual(BellEffects(playSound: true, flash: false, dot: true),
                          BellEffects(playSound: false, flash: false, dot: true),
            "differing BellEffects must not compare equal")
    }

    // MARK: - default initializer reflects silent-by-default policy

    func test_bellPreferences_defaultInit_isSilent() {
        // The no-arg default must be sound=false, flash=false so a fresh install
        // never beeps or flashes without explicit user opt-in.
        let prefs = BellPreferences()
        XCTAssertFalse(prefs.sound,
            "default BellPreferences must have sound=false (silent by default on first launch)")
        XCTAssertFalse(prefs.flash,
            "default BellPreferences must have flash=false (no flash by default on first launch)")
    }
}
