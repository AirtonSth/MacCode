import XCTest
@testable import AppShell
import CoreModel

final class TokenSaverAdapterMatrixRuntimeTests: XCTestCase {
    func test_scrubTokenSaverEnvironment_removesHintsAndManagedPath() {
        let managed = AgentSkillInstaller.defaultManagedCLIBinDirectory().path
        let env = [
            "PATH": "\(managed):/usr/bin",
            "RC_TOKEN_SAVER_DISTILL_HINT": "1",
            "RC_TOKEN_SAVER_POST_TOOL_USE": "1",
            "REMOTE_CODE_AGENT_PROVIDER": "claude",
        ]
        let cleaned = AppCommandRouter.scrubTokenSaverEnvironment(env)
        XCTAssertNil(cleaned["RC_TOKEN_SAVER_DISTILL_HINT"])
        XCTAssertNil(cleaned["RC_TOKEN_SAVER_POST_TOOL_USE"])
        XCTAssertEqual(cleaned["REMOTE_CODE_AGENT_PROVIDER"], "claude")
        XCTAssertFalse((cleaned["PATH"] ?? "").contains(managed))
        XCTAssertTrue((cleaned["PATH"] ?? "").contains("/usr/bin"))
    }
}
