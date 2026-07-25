import XCTest
@testable import AgentRuntime

/// WHY: with the CLI engine now the default for `.claude`, a missing `claude`
/// binary is the first failure a fresh user hits. The message must point at the
/// official NATIVE installer (not `npm`, which is exactly the toolchain we moved
/// away from), name the real searched locations, and offer the Settings path.
final class ClaudeCLIMissingBinaryMessageTests: XCTestCase {

    func test_message_leadsWithNativeInstaller_notNpm() {
        let m = ClaudeRunner.missingBinaryMessage("claude")
        XCTAssertTrue(m.contains("claude.ai/install.sh"), "must point at the official native installer")
        XCTAssertFalse(m.contains("npm install"),
                       "must NOT recommend npm — that is the Node toolchain this change removes")
    }

    func test_message_namesSettingsAndRealSearchLocations() {
        let m = ClaudeRunner.missingBinaryMessage("claude")
        XCTAssertTrue(m.contains("Settings"), "must tell the user they can set a custom path")
        // These locations are actually on ProcessLocator's search path.
        XCTAssertTrue(m.contains("/opt/homebrew/bin"))
        XCTAssertTrue(m.contains("/usr/local/bin"))
        XCTAssertTrue(m.contains("~/.local/bin"))
    }

    func test_unavailableError_rendersMessageWithoutPrefix() {
        // The transcript renders errors via String(describing:); the dedicated
        // error must surface the guidance verbatim, no "unsupported:" prefix.
        let err = ClaudeCLIUnavailableError(message: ClaudeRunner.missingBinaryMessage("claude"))
        XCTAssertEqual(String(describing: err), ClaudeRunner.missingBinaryMessage("claude"))
        XCTAssertFalse(String(describing: err).contains("unsupported"))
    }
}
