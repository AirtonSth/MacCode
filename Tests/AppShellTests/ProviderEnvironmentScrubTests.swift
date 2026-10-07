import XCTest
@testable import AppShell
@testable import AgentRuntime
import CoreModel

/// WHY: Token Saver is gone, but an environment inherited from an older build
/// can still carry its keys. They must never reach a provider, and a no-thread
/// provider environment must not put the managed bin on PATH.
final class ProviderEnvironmentScrubTests: XCTestCase {
    func test_scrubProviderEnvironment_removesLegacyKeysAndManagedPath() {
        let managed = AgentSkillInstaller.defaultManagedCLIBinDirectory().path
        let env = [
            "PATH": "\(managed):/usr/bin",
            "RC_TOKEN_SAVER_DISTILL_HINT": "1",
            "RC_TOKEN_SAVER_POST_TOOL_USE": "1",
            "RC_TOKEN_SAVER_ATTEMPT_ID": "attempt-1",
            "RC_TOKEN_SAVER_FUTURE_KEY": "x",
            "RC_GRAPHIFY_ENABLED": "1",
            "REMOTE_CODE_DISTILL_STATE_PATH": "/tmp/state.json",
            "REMOTE_CODE_AGENT_PROVIDER": "claude",
        ]
        let cleaned = AppCommandRouter.scrubProviderEnvironment(env)
        XCTAssertNil(cleaned["RC_TOKEN_SAVER_DISTILL_HINT"])
        XCTAssertNil(cleaned["RC_TOKEN_SAVER_POST_TOOL_USE"])
        XCTAssertNil(cleaned["RC_TOKEN_SAVER_ATTEMPT_ID"])
        XCTAssertNil(cleaned["RC_TOKEN_SAVER_FUTURE_KEY"])
        XCTAssertNil(cleaned["RC_GRAPHIFY_ENABLED"])
        XCTAssertNil(cleaned["REMOTE_CODE_DISTILL_STATE_PATH"])
        XCTAssertEqual(cleaned["REMOTE_CODE_AGENT_PROVIDER"], "claude")
        XCTAssertFalse((cleaned["PATH"] ?? "").contains(managed))
        XCTAssertTrue((cleaned["PATH"] ?? "").contains("/usr/bin"))
    }
}
