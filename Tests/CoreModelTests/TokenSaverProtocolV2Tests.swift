import XCTest
@testable import CoreModel

final class TokenSaverProtocolV2Tests: XCTestCase {
    func test_hookNeverFallsThroughToGenericCompression() {
        let route = TokenSaverProtocolV2.routeCLISubcommand("hook")
        XCTAssertEqual(route, "hook_handler")
        XCTAssertFalse(
            TokenSaverProtocolV2.isHookFallthroughToGenericCompression(subcommand: "hook", routedTo: route)
        )
        XCTAssertTrue(
            TokenSaverProtocolV2.isHookFallthroughToGenericCompression(subcommand: "hook", routedTo: "compress")
        )
    }

    func test_missingRequiredField_isRaw() {
        let r = TokenSaverProtocolV2.decodeRequired(
            version: nil, capabilities: ["distill"], generation: 1, knownCapabilityEnums: ["distill"]
        )
        XCTAssertEqual(r, .rawMissingField("protocol_version"))
    }

    func test_peerUID_andModes() {
        let ok = TokenSaverProtocolV2.PeerIdentity(uid: 501, expectedUID: 501, dirMode: 0o700, socketMode: 0o600)
        XCTAssertTrue(ok.isAuthorized)
        let badUID = TokenSaverProtocolV2.PeerIdentity(uid: 502, expectedUID: 501, dirMode: 0o700, socketMode: 0o600)
        XCTAssertFalse(badUID.isAuthorized)
        let badMode = TokenSaverProtocolV2.PeerIdentity(uid: 501, expectedUID: 501, dirMode: 0o755, socketMode: 0o600)
        XCTAssertFalse(badMode.isAuthorized)
    }

    func test_noSecretInArgvEnv() {
        XCTAssertFalse(TokenSaverProtocolV2.containsSecretLeak(argv: ["distill", "hook"], env: ["PATH": "/bin"]))
        XCTAssertTrue(TokenSaverProtocolV2.containsSecretLeak(argv: ["--token=BOOTSTRAP_TOKEN"], env: [:]))
        XCTAssertTrue(TokenSaverProtocolV2.containsSecretLeak(argv: [], env: ["SIDECAR_SECRET": "x"]))
    }

    func test_grantsAreDistinct() {
        XCTAssertTrue(TokenSaverProtocolV2.grantAllows(.distill, requested: .distill))
        XCTAssertFalse(TokenSaverProtocolV2.grantAllows(.distill, requested: .search))
        XCTAssertFalse(TokenSaverProtocolV2.grantAllows(.search, requested: .retrieve))
        XCTAssertEqual(Set(TokenSaverProtocolV2.Grant.allCases.map(\.rawValue)).count, TokenSaverProtocolV2.Grant.allCases.count)
    }

    func test_deadlineExpiry_rawWithoutPostMutation() {
        let safe = TokenSaverProtocolV2.DeadlineState(expired: true, cleanupPerformed: true, mutatedAfterExpiry: false)
        XCTAssertTrue(safe.isSafeRaw)
        let unsafe = TokenSaverProtocolV2.DeadlineState(expired: true, cleanupPerformed: true, mutatedAfterExpiry: true)
        XCTAssertFalse(unsafe.isSafeRaw)
    }
}
