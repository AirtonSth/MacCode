import XCTest
@testable import CoreModel

final class TokenSaverRecoveryProjectionsTests: XCTestCase {
    func test_defaultOff() {
        XCTAssertFalse(TokenSaverRecoveryProjections.defaultEnabled)
        XCTAssertFalse(TokenSaverRecoveryProjections.admitSearch(queryScopeDigest: "a", resultScopeDigest: "a"))
        XCTAssertFalse(TokenSaverRecoveryProjections.admitRetrieve(bytes: Data("a".utf8), original: Data("a".utf8), handle: "h"))
        let led = Self.measuredLedger(digest: "op", tokens: 10, binding: "b")
        let r = TokenSaverRecoveryProjections.ReceiptFactory.fromLocalLedger(ledger: led, operationDigest: "op")
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
        let empty = TokenSaverAccountingV2.Ledger()
        XCTAssertNil(TokenSaverRecoveryProjections.ReceiptFactory.fromLocalLedger(ledger: empty, operationDigest: "missing"))
        XCTAssertNil(TokenSaverRecoveryProjections.ReceiptFactory.fromProviderUsage(ledger: empty, operationDigest: "missing"))

        let unmeasured = TokenSaverAccountingV2.Ledger()
        _ = unmeasured.record(TokenSaverAccountingV2.Operation(digest: "op", generation: 1, state: .providerApplied))
        XCTAssertNil(TokenSaverRecoveryProjections.ReceiptFactory.fromLocalLedger(ledger: unmeasured, operationDigest: "op"))

        let led = Self.measuredLedger(digest: "op", tokens: 42, binding: "bind")
        let r = TokenSaverRecoveryProjections.ReceiptFactory.fromProviderUsage(ledger: led, operationDigest: "op")!
        XCTAssertEqual(r.tokens, 42)
        XCTAssertEqual(r.bindingDigest, "bind")
        XCTAssertEqual(r.source, .providerUsage)
        // Binding comes from ledger — cannot rebind via factory args
        XCTAssertEqual(TokenSaverRecoveryProjections.prefetchConfirmedSavings(used: true, receipt: r, creditBindingDigest: "bind"), 42)
        XCTAssertEqual(TokenSaverRecoveryProjections.prefetchConfirmedSavings(used: true, receipt: r, creditBindingDigest: "other"), 0)
        XCTAssertEqual(TokenSaverRecoveryProjections.prefetchConfirmedSavings(used: false, receipt: r, creditBindingDigest: "bind"), 0)

        let charOnly = TokenSaverAccountingV2.Ledger()
        _ = charOnly.record(TokenSaverAccountingV2.Operation(digest: "c", generation: 1, state: .providerApplied))
        _ = charOnly.addCharacterCountSavings(999, to: "c")
        XCTAssertNil(TokenSaverRecoveryProjections.ReceiptFactory.fromLocalLedger(ledger: charOnly, operationDigest: "c"))
        XCTAssertNil(TokenSaverRecoveryProjections.ReceiptFactory.fromLocalLedger(ledger: led, operationDigest: ""))
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
        XCTAssertFalse(rt.store(handle: "h1", scopeDigest: "scopeA", payload: payload))
        let hits = rt.search(queryScope: "scopeA", resultHandles: ["h1", "h2"])
        XCTAssertEqual(hits.map(\.handle), ["h1"])
        XCTAssertTrue(hits[0].excerpt.contains("blob"))
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
        rt.revoke("never-stored")
        XCTAssertFalse(rt.store(handle: "never-stored", scopeDigest: "s", payload: payload))
        rt.maxSearchHits = 1
        _ = rt.store(handle: "a1", scopeDigest: "scopeA", payload: payload)
        _ = rt.store(handle: "a2", scopeDigest: "scopeA", payload: payload)
        XCTAssertEqual(rt.search(queryScope: "scopeA", resultHandles: ["a1", "a2"]).count, 1)
        rt.excerptBytes = 4
        let hit = rt.search(queryScope: "scopeA", resultHandles: ["a2"]).first
        XCTAssertNotNil(hit)
        XCTAssertLessThanOrEqual(hit!.excerpt.utf8.count, 4)
    }

    private static func measuredLedger(digest: String, tokens: Int64, binding: String) -> TokenSaverAccountingV2.Ledger {
        let led = TokenSaverAccountingV2.Ledger()
        _ = led.record(TokenSaverAccountingV2.Operation(digest: digest, generation: 1, state: .providerApplied))
        _ = led.markProviderMeasured(digest, experimentalPair: true, providerTokensSaved: tokens, bindingDigest: binding)
        return led
    }
}
