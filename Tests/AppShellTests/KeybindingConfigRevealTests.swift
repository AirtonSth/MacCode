import XCTest
@testable import AppShell

/// Tests for KeybindingConfigReveal pure helpers.
///
/// Business rule: the Reveal-config button and the keybindings parser must agree
/// on the config file location, and the default template must be a well-formed
/// JSON array so new users see an immediately parseable file.
final class KeybindingConfigRevealTests: XCTestCase {

    // MARK: - configPath

    func test_configPath_isUnderDotRemotecodeDirectory() {
        // The path must live inside ~/.remotecode/ so it is co-located with
        // other RemoteCode config files and matches KeybindingConfig.defaultPath.
        let path = KeybindingConfigReveal.configPath
        XCTAssertTrue(path.contains("/.remotecode/"),
                      "configPath must be inside the .remotecode directory; got: \(path)")
    }

    func test_configPath_endsWithKeybindingsJson() {
        // File name is load-bearing: KeybindingConfig.load(path:) reads exactly this file.
        let path = KeybindingConfigReveal.configPath
        XCTAssertTrue(path.hasSuffix("/keybindings.json"),
                      "configPath must end with /keybindings.json; got: \(path)")
    }

    func test_configPath_matchesKeybindingConfigDefaultPath() {
        // Both the reveal helper and the parser must reference the same file;
        // a mismatch means the button creates/opens a file the parser never reads.
        XCTAssertEqual(
            KeybindingConfigReveal.configPath,
            KeybindingConfig.defaultPath,
            "KeybindingConfigReveal.configPath must match KeybindingConfig.defaultPath"
        )
    }

    // MARK: - defaultTemplate

    func test_defaultTemplate_isNonEmpty() {
        XCTAssertFalse(KeybindingConfigReveal.defaultTemplate.isEmpty,
                       "defaultTemplate must not be empty")
    }

    func test_defaultTemplate_containsCommentHeader() {
        // Users need contextual guidance; the template must include at least
        // one comment line explaining the format.
        let template = KeybindingConfigReveal.defaultTemplate
        XCTAssertTrue(template.contains("//"),
                      "defaultTemplate must contain a comment (// ...) to guide new users")
    }

    func test_defaultTemplate_jsonArrayIsParseableByKeybindingConfig() {
        // Strip comment lines (KeybindingConfig.parse feeds raw JSON).
        // The JSON body must be a valid array so KeybindingConfig.parse does not
        // return a warning about a non-array top-level value.
        let template = KeybindingConfigReveal.defaultTemplate
        let jsonLines = template
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        guard let data = jsonLines.data(using: .utf8) else {
            XCTFail("defaultTemplate JSON body could not be encoded as UTF-8")
            return
        }
        let cfg = KeybindingConfig.parse(data)
        XCTAssertTrue(cfg.warnings.isEmpty,
                      "defaultTemplate JSON must parse without warnings; got: \(cfg.warnings)")
    }
}
