import XCTest
@testable import DistillCore
@testable import CoreModel

final class TokenSaverTypedCrushersBridgeTests: XCTestCase {
    func test_pytestFailureLines_excludesSummary() {
        let out = """
        test_a FAILED
        test_b FAILED
        ===== 2 failed, 3 passed in 0.1s =====
        """
        let lines = TokenSaverTypedCrushersBridge.pytestFailureLines(from: out)
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines.contains(where: { $0.contains("=====") }))
    }

    func test_bridgeObserve_doesNotThrow() {
        TokenSaverTypedCrushersBridge.observeToolOutput(
            toolName: "Bash",
            output: "test_a FAILED\n===== 1 failed ====="
        )
        TokenSaverTypedCrushersBridge.observeToolOutput(
            toolName: "Grep",
            output: "a.swift:1:hit",
            bindingDigest: "abc"
        )
        XCTAssertTrue(true)
    }

    func test_extractRecoveryHandles_hexAndRcv1() {
        let out = "see [[rc:deadbeefcafebabe]] and [[rc:rcv1.550e8400-e29b-41d4-a716-446655440000.secret]]"
        let hs = TokenSaverTypedCrushersBridge.extractRecoveryHandles(from: out)
        XCTAssertEqual(hs.count, 2)
        XCTAssertTrue(hs.contains("deadbeefcafebabe"))
        XCTAssertTrue(hs.contains("rcv1.550e8400-e29b-41d4-a716-446655440000.secret"))
    }

    func test_searchScopeRequiresBindingDigestMatch() {
        // Default OFF → deny regardless
        XCTAssertFalse(TokenSaverRecoveryBridge.observeSearch(queryScope: "a", resultScope: "b"))
        // Live would deny mismatch via projections
        XCTAssertFalse(TokenSaverRecoveryProjections.admitSearch(
            queryScopeDigest: "scopeA", resultScopeDigest: "scopeB", live: true
        ))
        XCTAssertTrue(TokenSaverRecoveryProjections.admitSearch(
            queryScopeDigest: "scopeA", resultScopeDigest: "scopeA", live: true
        ))
    }

    func test_productionBridge_independentScopes() {
        // Missing result scope → empty → deny when live
        XCTAssertFalse(TokenSaverRecoveryProjections.admitSearch(
            queryScopeDigest: "query-scope", resultScopeDigest: "", live: true
        ))
        // Production bridge API: mismatch via observeSearch
        XCTAssertFalse(TokenSaverRecoveryBridge.observeSearch(queryScope: "q", resultScope: "r"))
        XCTAssertFalse(TokenSaverRecoveryProjections.admitSearch(
            queryScopeDigest: "query-scope", resultScopeDigest: "other-scope", live: true
        ))
        XCTAssertTrue(TokenSaverRecoveryProjections.admitSearch(
            queryScopeDigest: "query-scope", resultScopeDigest: "query-scope", live: true
        ))
        // exercise observeToolOutput with independent scopes (fail-open, default OFF)
        TokenSaverTypedCrushersBridge.observeToolOutput(
            toolName: "Grep", output: "hit",
            bindingDigest: "query-scope", resultScopeDigest: "other-scope"
        )
        TokenSaverTypedCrushersBridge.observeToolOutput(
            toolName: "Grep", output: "hit",
            bindingDigest: "query-scope" // missing result → empty
        )
    }
}
