import XCTest
@testable import CoreModel

final class TokenSaverRecoveryProjectionsTests: XCTestCase {
    func test_defaultOff() {
        XCTAssertFalse(TokenSaverRecoveryProjections.defaultEnabled)
        XCTAssertFalse(TokenSaverRecoveryProjections.admitSearch(queryScopeDigest: "a", resultScopeDigest: "a"))
        XCTAssertFalse(TokenSaverRecoveryProjections.admitRetrieve(bytes: Data("a".utf8), original: Data("a".utf8), handle: "h"))
        let r = TokenSaverRecoveryProjections.ReceiptFactory.fromLocalLedger(
            bindingDigest: "b", confirmedTokens: 10, ledgerDigestMatch: true
        )
        XCTAssertEqual(TokenSaverRecoveryProjections.admitPrefetchSavings(used: true, receipt: r, creditBindingDigest: "b"), 0)
    }

    func test_searchCrossScopeDenied() {
        XCTAssertFalse(TokenSaverRecoveryProjections.admitSearch(queryScopeDigest: "a", resultScopeDigest: "b", live: true))
        XCTAssertTrue(TokenSaverRecoveryProjections.admitSearch(queryScopeDigest: "a", resultScopeDigest: "a", live: true))
        XCTAssertFalse(TokenSaverRecoveryProjections.admitSearch(queryScopeDigest: "", resultScopeDigest: "", live: true))
    }

    func test_retrieveRevocationAndWhitespaceHandle() {
        XCTAssertTrue(TokenSaverRecoveryProjections.admitRetrieve(
            bytes: Data("a".utf8), original: Data("a".utf8), handle: "h1", revoked: false, live: true
        ))
        XCTAssertFalse(TokenSaverRecoveryProjections.admitRetrieve(
            bytes: Data("a".utf8), original: Data("a".utf8), handle: "h1", revoked: true, live: true
        ))
        XCTAssertFalse(TokenSaverRecoveryProjections.admitRetrieve(
            bytes: Data("a".utf8), original: Data("a".utf8), handle: "   ", live: true
        ))
        XCTAssertFalse(TokenSaverRecoveryProjections.admitRetrieve(
            bytes: Data("a".utf8), original: Data("b".utf8), handle: "h1", live: true
        ))
    }

    func test_receiptFactoryTrustedOnly() {
        XCTAssertNil(TokenSaverRecoveryProjections.ReceiptFactory.fromLocalLedger(
            bindingDigest: "b", confirmedTokens: 10, ledgerDigestMatch: false
        ))
        XCTAssertNil(TokenSaverRecoveryProjections.ReceiptFactory.fromProviderUsage(
            bindingDigest: "b", providerTokensSaved: 5, usageEventPresent: false
        ))
        let r = TokenSaverRecoveryProjections.ReceiptFactory.fromProviderUsage(
            bindingDigest: "bind", providerTokensSaved: 42, usageEventPresent: true
        )!
        XCTAssertEqual(TokenSaverRecoveryProjections.prefetchConfirmedSavings(used: true, receipt: r, creditBindingDigest: "bind"), 42)
        // Wrong binding → zero
        XCTAssertEqual(TokenSaverRecoveryProjections.prefetchConfirmedSavings(used: true, receipt: r, creditBindingDigest: "other"), 0)
        XCTAssertEqual(TokenSaverRecoveryProjections.prefetchConfirmedSavings(used: false, receipt: r, creditBindingDigest: "bind"), 0)
    }

    func test_dedupeHandles() {
        XCTAssertEqual(TokenSaverRecoveryProjections.dedupeHandles(["a", "b", "a", "", "  "]), ["a", "b"])
    }

    func test_manifestWorkspaceTaskResume() {
        XCTAssertTrue(TokenSaverRecoveryProjections.manifestKeepsCore(systemUntouched: true, coreToolsPresent: true))
        XCTAssertFalse(TokenSaverRecoveryProjections.admitManifest(systemUntouched: true, coreToolsPresent: false, live: true))
        XCTAssertTrue(TokenSaverRecoveryProjections.workspaceGapForcesFullSnapshot(true))
        XCTAssertFalse(TokenSaverRecoveryProjections.taskDoneRequiresProof(false))
        XCTAssertTrue(TokenSaverRecoveryProjections.resumeTailGapLoadsFull(true))
    }

    func test_runtime_scopeIsolationRetrieveRevoke() {
        let rt = TokenSaverRecoveryRuntime()
        rt.live = true
        let payload = Data("blob-content-for-excerpt-and-exact-match".utf8)
        XCTAssertTrue(rt.store(handle: "h1", scopeDigest: "scopeA", payload: payload))
        XCTAssertTrue(rt.store(handle: "h2", scopeDigest: "scopeB", payload: Data("other".utf8)))
        // Immutable: second store rejected
        XCTAssertFalse(rt.store(handle: "h1", scopeDigest: "scopeA", payload: payload))
        let hits = rt.search(queryScope: "scopeA", resultHandles: ["h1", "h2"])
        XCTAssertEqual(hits.map(\.handle), ["h1"])
        XCTAssertTrue(hits[0].excerpt.contains("blob"))
        // Exact retrieve requires expected bytes
        XCTAssertEqual(rt.retrieve(handle: "h1", expected: payload), payload)
        XCTAssertNil(rt.retrieve(handle: "h1", expected: Data("wrong".utf8)))
        rt.revoke("h1")
        XCTAssertNil(rt.retrieve(handle: "h1", expected: payload))
        XCTAssertFalse(rt.store(handle: "h1", scopeDigest: "scopeA", payload: payload))
        XCTAssertFalse(rt.store(handle: "h2", scopeDigest: "scopeZ", payload: Data("x".utf8)))
        XCTAssertTrue(rt.store(handle: "  h4  ", scopeDigest: "s", payload: payload))
        XCTAssertEqual(rt.retrieve(handle: "h4", expected: payload), payload)
        rt.revoke("  h4  ")
        XCTAssertNil(rt.retrieve(handle: "h4", expected: payload))
        let off = TokenSaverRecoveryRuntime()
        XCTAssertTrue(off.store(handle: "h3", scopeDigest: "s", payload: payload))
        XCTAssertNil(off.retrieve(handle: "h3", expected: payload))
        // Unknown revoke → tombstone blocks later store
        rt.revoke("never-stored")
        XCTAssertFalse(rt.store(handle: "never-stored", scopeDigest: "s", payload: payload))
        // Search budget
        rt.maxSearchHits = 1
        _ = rt.store(handle: "a1", scopeDigest: "scopeA", payload: payload)
        _ = rt.store(handle: "a2", scopeDigest: "scopeA", payload: payload)
        XCTAssertEqual(rt.search(queryScope: "scopeA", resultHandles: ["a1", "a2"]).count, 1)
        // Excerpt budget
        rt.excerptBytes = 4
        let hit = rt.search(queryScope: "scopeA", resultHandles: ["a2"]).first
        XCTAssertNotNil(hit)
        XCTAssertLessThanOrEqual(hit!.excerpt.utf8.count, 4)
    }
}
