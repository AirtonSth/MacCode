import XCTest
@testable import AppShell

/// T3 Code keybinding semantics: normalization, when-expression eval,
/// last-match-wins precedence, and loud handling of malformed config.
final class KeybindingConfigTests: XCTestCase {

    func test_parse_dropsInvalidRulesWithWarnings() {
        let json = Data(#"""
        [ {"key":"mod+k","command":"commandPalette.toggle"},
          {"command":"missing.key"},
          {"key":"mod+t"} ]
        """#.utf8)
        let cfg = KeybindingConfig.parse(json)
        XCTAssertEqual(cfg.bindings.count, 1, "only the complete rule survives")
        XCTAssertEqual(cfg.bindings.first?.command, "commandPalette.toggle")
        XCTAssertEqual(cfg.warnings.count, 2, "each dropped rule must warn, not vanish silently")
    }

    func test_parse_nonArrayIsLoudAndSafe() {
        let cfg = KeybindingConfig.parse(Data(#"{"key":"x"}"#.utf8))
        XCTAssertTrue(cfg.bindings.isEmpty)
        XCTAssertFalse(cfg.warnings.isEmpty, "a non-array config must warn and fall back to defaults")
    }

    func test_normalize_isModifierOrderAndAliasInsensitive() {
        XCTAssertEqual(KeybindingConfig.normalize("Cmd+Shift+K"),
                       KeybindingConfig.normalize("shift+command+k"),
                       "cmd/command alias + modifier order must canonicalize identically")
        XCTAssertEqual(KeybindingConfig.normalize("mod+k"), "mod+k")
    }

    func test_evalWhen_identifierNegationAndConjunction() {
        XCTAssertTrue(KeybindingConfig.evalWhen(nil, context: []))
        XCTAssertTrue(KeybindingConfig.evalWhen("", context: []))
        XCTAssertTrue(KeybindingConfig.evalWhen("terminalFocus", context: ["terminalFocus"]))
        XCTAssertFalse(KeybindingConfig.evalWhen("terminalFocus", context: []))
        XCTAssertTrue(KeybindingConfig.evalWhen("!terminalFocus", context: []))
        XCTAssertFalse(KeybindingConfig.evalWhen("!terminalFocus", context: ["terminalFocus"]))
        XCTAssertTrue(KeybindingConfig.evalWhen("a !b", context: ["a"]))
        XCTAssertFalse(KeybindingConfig.evalWhen("a !b", context: ["a", "b"]))
    }

    func test_command_lastMatchingRuleWinsAndWhenFilters() {
        let cfg = KeybindingConfig.parse(Data(#"""
        [ {"key":"mod+k","command":"first"},
          {"key":"Mod+K","command":"second"},
          {"key":"mod+k","command":"terminalOnly","when":"terminalFocus"} ]
        """#.utf8))
        XCTAssertEqual(cfg.command(forKey: "cmd+k"), "second",
                       "later rule overrides earlier; key match is normalized")
        XCTAssertEqual(cfg.command(forKey: "cmd+k", context: ["terminalFocus"]), "terminalOnly",
                       "a when-gated rule wins only when its context holds")
        XCTAssertNil(cfg.command(forKey: "cmd+j"), "an unbound chord resolves to nothing")
    }
}
