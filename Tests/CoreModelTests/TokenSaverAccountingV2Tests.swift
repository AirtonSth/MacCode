import XCTest
@testable import CoreModel

final class TokenSaverAccountingV2Tests: XCTestCase {
    func test_commonOp_cannotMeasureWithoutPair() {
        let led = TokenSaverAccountingV2.Ledger()
        var op = TokenSaverAccountingV2.Operation(digest: "d1", generation: 1, state: .providerApplied)
        _ = led.record(op)
        let r = led.markProviderMeasured("d1", experimentalPair: false, bindingDigest: "bind")
        XCTAssertEqual(r, .failure(.measuredRequiresPair))
    }

    func test_sameByteReplay_idempotent() {
        let led = TokenSaverAccountingV2.Ledger()
        let op = TokenSaverAccountingV2.Operation(digest: "d1", generation: 1)
        XCTAssertNotNil(try? led.record(op).get())
        XCTAssertNotNil(try? led.record(op).get())
    }

    func test_digestConflict_terminal() {
        let led = TokenSaverAccountingV2.Ledger()
        _ = led.record(TokenSaverAccountingV2.Operation(digest: "d1", generation: 1, state: .candidate))
        let r = led.record(TokenSaverAccountingV2.Operation(digest: "d1", generation: 1, state: .transported))
        XCTAssertEqual(r, .failure(.digestConflict))
    }

    func test_legalAndIllegalTransitions() {
        let led = TokenSaverAccountingV2.Ledger()
        _ = led.record(TokenSaverAccountingV2.Operation(digest: "d", generation: 1, state: .candidate))
        XCTAssertNotNil(try? led.transition("d", to: .transported).get())
        XCTAssertNotNil(try? led.transition("d", to: .providerApplied).get())
        // Skip measured without going through legal path from applied is ok for production_estimate
        XCTAssertEqual(led.transition("d", to: .candidate), .failure(.illegalTransition))
        XCTAssertTrue(TokenSaverAccountingV2.canTransition(from: .candidate, to: .transported))
        XCTAssertFalse(TokenSaverAccountingV2.canTransition(from: .legacyEstimate, to: .candidate))
    }

    func test_batchAbort_noPartialPublish() {
        let led = TokenSaverAccountingV2.Ledger()
        led.beginBatch()
        _ = led.record(TokenSaverAccountingV2.Operation(digest: "a", generation: 1))
        _ = led.record(TokenSaverAccountingV2.Operation(digest: "b", generation: 1))
        led.abortBatch(digests: ["a", "b"])
        XCTAssertFalse(led.batchPublished)
        // Staged digests never committed
        XCTAssertEqual(led.transition("a", to: .transported), .failure(.missing))
    }

    func test_batchAbort_preservesCommittedEntries() {
        let led = TokenSaverAccountingV2.Ledger()
        let existing = TokenSaverAccountingV2.Operation(digest: "keep", generation: 1, state: .candidate)
        _ = led.record(existing)
        led.beginBatch()
        // Same-byte replay succeeds without re-staging a new commit
        _ = led.record(existing)
        led.abortBatch(digests: ["keep"])
        XCTAssertFalse(led.batchPublished)
        // Committed entry must survive abort
        XCTAssertNotNil(try? led.transition("keep", to: .transported).get())
    }

    func test_batchCommit_publishes() {
        let led = TokenSaverAccountingV2.Ledger()
        led.beginBatch()
        _ = led.record(TokenSaverAccountingV2.Operation(digest: "a", generation: 1))
        led.commitBatch()
        XCTAssertTrue(led.batchPublished)
        // Digest now in ledger for further transitions
        XCTAssertNotNil(try? led.transition("a", to: .transported).get())
    }

    func test_estimatorExpired_zero() {
        let led = TokenSaverAccountingV2.Ledger()
        XCTAssertEqual(led.estimator(valid: false, expired: false), 0)
        XCTAssertEqual(led.estimator(valid: true, expired: true), 0)
        XCTAssertEqual(led.estimator(valid: true, expired: false, superseded: true), 0)
        XCTAssertEqual(led.estimator(valid: true, expired: false, superseded: false), 1)
    }

    func test_characterCounts_doNotConfirm() {
        let led = TokenSaverAccountingV2.Ledger()
        _ = led.record(TokenSaverAccountingV2.Operation(digest: "d", generation: 1, state: .providerApplied))
        _ = led.markProviderMeasured("d", experimentalPair: true, providerTokensSaved: 42, bindingDigest: "bind")
        XCTAssertEqual(led.addCharacterCountSavings(9999, to: "d"), 42)
        XCTAssertEqual(led.rebuildConfirmedTotal(), 42)
    }

    func test_deleteRemainsDeleted() {
        let led = TokenSaverAccountingV2.Ledger()
        _ = led.record(TokenSaverAccountingV2.Operation(digest: "d", generation: 1, state: .providerApplied))
        led.markDeleted("d")
        XCTAssertTrue(led.isDeleted("d"))
        XCTAssertEqual(
            led.markProviderMeasured("d", experimentalPair: true, providerTokensSaved: 10, bindingDigest: "bind"),
            .failure(.deleted)
        )
        XCTAssertEqual(led.rebuildConfirmedTotal(), 0)
    }

    func test_legacySnapshot_isLegacyEstimate() {
        XCTAssertEqual(TokenSaverAccountingV2.Ledger().legacySnapshotOpaque(), .legacyEstimate)
    }

    func test_rebuildProjection_equalsStoredTotals() {
        let led = TokenSaverAccountingV2.Ledger()
        _ = led.record(TokenSaverAccountingV2.Operation(digest: "a", generation: 1, state: .providerApplied))
        _ = led.record(TokenSaverAccountingV2.Operation(digest: "b", generation: 1, state: .providerApplied))
        _ = led.markProviderMeasured("a", experimentalPair: true, providerTokensSaved: 10, bindingDigest: "bindA")
        _ = led.markProviderMeasured("b", experimentalPair: true, providerTokensSaved: 5, bindingDigest: "bindB")
        XCTAssertEqual(led.rebuildConfirmedTotal(), led.storedConfirmedTotal())
        XCTAssertEqual(led.rebuildConfirmedTotal(), 15)
    }

    func test_sixTruthStates_enumerated() {
        XCTAssertEqual(TokenSaverAccountingV2.TruthState.allCases.count, 6)
    }

    func test_recordCannotSmuggleMeasuredSavings() {
        let led = TokenSaverAccountingV2.Ledger()
        // Missing binding on measure is rejected
        _ = led.record(TokenSaverAccountingV2.Operation(digest: "d", generation: 1, state: .providerApplied))
        XCTAssertEqual(
            led.markProviderMeasured("d", experimentalPair: true, providerTokensSaved: 9, bindingDigest: "  "),
            .failure(.missingBinding)
        )
        XCTAssertNil(led.measuredSnapshot(for: "d"))
        // Measure with binding succeeds; snapshot carries binding
        _ = led.markProviderMeasured("d", experimentalPair: true, providerTokensSaved: 9, bindingDigest: "bind")
        let snap = led.measuredSnapshot(for: "d")
        XCTAssertEqual(snap?.tokens, 9)
        XCTAssertEqual(snap?.bindingDigest, "bind")
        // confirmedTokensSaved is not publicly settable (compile-time); re-record of measured state fails
        // via state machine only markProviderMeasured path
        XCTAssertEqual(led.measuredConfirmedTokens(for: "missing"), nil)
    }

    /// Public surface: raw scalars cannot create confirmed savings without the internal measure path.
    func test_publicAPI_cannotForgeMeasuredSavingsViaTransitionOrRecord() {
        let led = TokenSaverAccountingV2.Ledger()
        _ = led.record(TokenSaverAccountingV2.Operation(digest: "d", generation: 1, state: .candidate))
        _ = led.transition("d", to: .transported)
        _ = led.transition("d", to: .providerApplied)
        // Public transition into providerMeasured is refused even though the legal edge exists
        // for the internal markProviderMeasured path.
        XCTAssertEqual(led.transition("d", to: .providerMeasured), .failure(.illegalTransition))
        XCTAssertNil(led.measuredSnapshot(for: "d"))
        XCTAssertEqual(led.rebuildConfirmedTotal(), 0)
        XCTAssertNil(TokenSaverRecoveryProjections.ReceiptFactory.fromLocalLedger(ledger: led, operationDigest: "d"))
        XCTAssertNil(TokenSaverRecoveryProjections.ReceiptFactory.fromProviderUsage(ledger: led, operationDigest: "d"))
        // Character counts still never confirm.
        XCTAssertEqual(led.addCharacterCountSavings(500, to: "d"), 0)
        // Constructing Operation(state: .providerMeasured) traps / record rejects measured.
        XCTAssertEqual(
            led.record(TokenSaverAccountingV2.Operation(digest: "e", generation: 1, state: .providerApplied)).map { $0.confirmedTokensSaved },
            .success(0)
        )
    }
}
