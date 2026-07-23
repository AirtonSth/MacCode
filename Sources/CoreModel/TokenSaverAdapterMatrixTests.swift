import XCTest
@testable import CoreModel

final class TokenSaverAdapterMatrixTests: XCTestCase {
    func test_mixedCLIAndSDK_isIllegalAndOff() {
        let mode = TokenSaverAdapterMatrix.mergeMode(cliSettingsOverlay: true, sdkHooks: true)
        XCTAssertEqual(mode, .mixedIllegal)
        XCTAssertEqual(TokenSaverAdapterMatrix.laneAfterMerge(mode), .off)
    }

    func test_settingsUntouched() {
        let d = Data("user-settings".utf8)
        XCTAssertTrue(TokenSaverAdapterMatrix.settingsUntouched(before: d, after: d))
        XCTAssertFalse(TokenSaverAdapterMatrix.settingsUntouched(before: d, after: Data("x".utf8)))
    }

    func test_crossUser_zeroCallbacksAllTurns() {
        for turn in TokenSaverAdapterMatrix.CrossUserTurn.allCases {
            XCTAssertFalse(TokenSaverAdapterMatrix.tokenSaverCallbacksAllowed(isSameUser: false, turn: turn))
            XCTAssertTrue(TokenSaverAdapterMatrix.tokenSaverCallbacksAllowed(isSameUser: true, turn: turn))
        }
    }

    func test_builtinVsMCP_fields() {
        XCTAssertEqual(TokenSaverAdapterMatrix.replacementField(for: .claudeBuiltin, proposed: "content"), "content")
        XCTAssertNil(TokenSaverAdapterMatrix.replacementField(for: .claudeBuiltin, proposed: "mcp_content"))
        XCTAssertEqual(TokenSaverAdapterMatrix.replacementField(for: .claudeMCP, proposed: "mcp_content"), "mcp_content")
        XCTAssertNil(TokenSaverAdapterMatrix.replacementField(for: .unknown, proposed: "content"))
    }

    func test_collision_noReplacement() {
        let c = TokenSaverAdapterMatrix.collision(reason: "duplicate_option")
        XCTAssertFalse(c.replacementPerformed)
    }

    func test_codexHookActive_requiresContract() {
        XCTAssertFalse(TokenSaverAdapterMatrix.codexHookActive(hasProvenMCPContract: false))
        XCTAssertTrue(TokenSaverAdapterMatrix.codexHookActive(hasProvenMCPContract: true))
    }
}
