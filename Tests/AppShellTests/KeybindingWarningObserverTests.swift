import XCTest
@testable import AppShell

// T037 -- keybinding parse-warning observer seam (:19)
//
// WHY: KeybindingConfig.parse() produces `warnings` for malformed rules but
// previously neither logged them nor called any observer.  A user with a typo
// in keybindings.json would see no error anywhere; the bad rule is silently
// dropped and the keybinding simply stops working.
//
// :19 adds:
//   1. os_log emission (keybindingLog.warning) for every warning -- visible in
//      Console.app and the Xcode debug console but not assertable from XCTest.
//   2. `onWarningsEmitted` -- a static observer closure that fires synchronously
//      from parse() whenever warnings exist.  Tests inject a capturing closure
//      to prove the fail-loud contract without relying on os_log side-effects.
//
// These tests pin the contract: if warnings are generated, the observer is called.

final class KeybindingWarningObserverTests: XCTestCase {

    override func tearDown() {
        // Always clear the seam so other tests are not affected.
        KeybindingConfig.onWarningsEmitted = nil
        super.tearDown()
    }

    // MARK: - T037a: malformed JSON fires observer

    /// WHY: a keybindings.json that is not a JSON array is the most common user
    /// mistake (e.g. a bare object or totally invalid content).  The observer must
    /// fire with at least one warning so a test or future telemetry can detect it.
    /// If no warning fires, the bad file is silently ignored and the user has no
    /// way to discover why their keybindings stopped working.
    func test_parse_malformedJSON_firesObserver() {
        var captured: [String]? = nil
        KeybindingConfig.onWarningsEmitted = { captured = $0 }

        _ = KeybindingConfig.parse(Data("NOT JSON".utf8))

        XCTAssertNotNil(captured,
                        "parsing non-JSON must fire onWarningsEmitted -- " +
                        "nil means the fail-loud contract is not met and the broken file is invisible")
        XCTAssertFalse(captured?.isEmpty ?? true,
                       "at least one warning must be emitted for a malformed file -- " +
                       "an empty array means the observer fires but carries no actionable information")
    }

    // MARK: - T037b: missing key/command field fires observer

    /// WHY: a rule missing the required `key` or `command` field is dropped
    /// silently from production bindings.  The observer must fire with a warning
    /// that identifies which rule was dropped so a developer can fix the file.
    /// Without this, a typo like `"cmd"` instead of `"key"` produces no feedback.
    func test_parse_missingKeyField_firesObserver() {
        var captured: [String]? = nil
        KeybindingConfig.onWarningsEmitted = { captured = $0 }

        let json = Data("""
        [{"command":"commandPalette.toggle"}]
        """.utf8)
        _ = KeybindingConfig.parse(json)

        XCTAssertNotNil(captured,
                        "a rule missing the 'key' field must fire onWarningsEmitted -- " +
                        "nil means the dropped rule is invisible to any observer or telemetry")
        XCTAssertEqual(captured?.count, 1,
                       "exactly one warning must be emitted for one malformed rule -- " +
                       "a different count means the wrong number of rules was flagged")
        XCTAssertTrue(captured?.first?.contains("0") ?? false,
                      "the warning must reference rule index 0 so the user can locate the broken entry -- " +
                      "a warning without the index is ambiguous in a file with many rules")
    }

    // MARK: - T037c: valid file does NOT fire observer

    /// WHY: the observer must fire ONLY when there are problems.  Firing on a
    /// clean file would create spurious noise in telemetry or test output.
    func test_parse_validFile_doesNotFireObserver() {
        var fired = false
        KeybindingConfig.onWarningsEmitted = { _ in fired = true }

        let json = Data("""
        [{"key":"mod+k","command":"commandPalette.toggle"}]
        """.utf8)
        _ = KeybindingConfig.parse(json)

        XCTAssertFalse(fired,
                       "a valid keybindings file must NOT fire onWarningsEmitted -- " +
                       "a false positive here would generate spurious warnings on every app launch")
    }

    // MARK: - T037d: warnings are also present in the returned config

    /// WHY: the observer is an additional channel; the warnings array on the
    /// returned config must still be populated so callers that inspect it
    /// (e.g. a future Settings UI) see the same warnings.  Decoupling the two
    /// would mean one channel has the warnings and the other does not, which is
    /// a silent divergence bug.
    func test_parse_warnings_inReturnedConfigMatchObserver() {
        var observedWarnings: [String] = []
        KeybindingConfig.onWarningsEmitted = { observedWarnings = $0 }

        let json = Data("""
        [{"command":"only-command-no-key"}]
        """.utf8)
        let config = KeybindingConfig.parse(json)

        XCTAssertEqual(config.warnings, observedWarnings,
                       "warnings in the returned KeybindingConfig must equal those sent to onWarningsEmitted -- " +
                       "a mismatch means the observer and the struct tell different stories about the same parse")
    }

    // MARK: - T037e: observer cleared between tests does not interfere

    /// WHY: onWarningsEmitted is a static property and must be nil-safe.
    /// After tearDown sets it to nil, a subsequent parse must not crash.
    func test_parse_nilObserver_doesNotCrash() {
        KeybindingConfig.onWarningsEmitted = nil   // explicitly nil (mirrors tearDown state)
        let json = Data("BAD".utf8)
        let config = KeybindingConfig.parse(json)  // must not crash or throw

        XCTAssertFalse(config.warnings.isEmpty,
                       "parse must still return warnings even when onWarningsEmitted is nil -- " +
                       "a nil observer must not suppress the warnings array on the config struct")
    }
}
