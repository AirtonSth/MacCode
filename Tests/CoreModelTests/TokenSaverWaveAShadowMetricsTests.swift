import XCTest
@testable import CoreModel

final class TokenSaverWaveAShadowMetricsTests: XCTestCase {
    let d1 = String(repeating: "ab", count: 32)
    let d2 = String(repeating: "cd", count: 32)

    func test_emitToLedger() {
        let ledger = TokenSaverWaveAShadowMetrics.Ledger()
        let before = Data("provider-payload".utf8)
        XCTAssertEqual(TokenSaverWaveAShadowMetrics.observeWithoutMutation(before), before)
        XCTAssertNotNil(TokenSaverWaveAShadowMetrics.emit(
            bindingDigest: d1, cacheVolatileTokens: 3, queueCohortSize: 1, pair: nil, ledger: ledger
        ))
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger.snapshot().first?.providerRoundsAvoided, 0)
    }

    func test_ledgerBoundsLongRunningShadowRecords() {
        let ledger = TokenSaverWaveAShadowMetrics.Ledger(maxRecords: 2)
        for _ in 0..<5 {
            XCTAssertNotNil(TokenSaverWaveAShadowMetrics.emit(
                bindingDigest: d1,
                cacheVolatileTokens: 0,
                queueCohortSize: 0,
                pair: nil,
                ledger: ledger
            ))
        }
        XCTAssertEqual(ledger.count, 2)
        XCTAssertEqual(ledger.droppedRecords, 3)
    }

    func test_defaultLedgerCapIs128() {
        XCTAssertEqual(TokenSaverWaveAShadowMetrics.ledgerRecordCountLimit, 128)
        let ledger = TokenSaverWaveAShadowMetrics.Ledger()
        let limit = TokenSaverWaveAShadowMetrics.ledgerRecordCountLimit
        for index in 0..<(limit + 40) {
            // Distinct digests so ring overwrite is not masked by equal payloads.
            let digest = String(format: "%064x", index)
            XCTAssertNotNil(TokenSaverWaveAShadowMetrics.emit(
                bindingDigest: digest,
                cacheVolatileTokens: index,
                queueCohortSize: 1,
                pair: nil,
                ledger: ledger
            ))
        }
        XCTAssertEqual(ledger.count, limit)
        XCTAssertEqual(ledger.droppedRecords, 40)
    }

    func test_retentionEstimate_256RecordsTo128Window() {
        let uncapped = 256 // prior default ledgerRecordCountLimit
        let limit = TokenSaverWaveAShadowMetrics.ledgerRecordCountLimit
        let reduction = Double(uncapped - limit) / Double(uncapped)
        XCTAssertGreaterThan(reduction, 0.49)
        XCTAssertEqual(limit, 128)
        // Basis: modest shadow record ~400B (digest + ints; paired evidence
        // is larger and scales with the same ceiling).
        // 256 × 400B ≈ 102.4KB → 128 × 400B ≈ 51.2KB (−50%).
        let perRecord = 400
        XCTAssertEqual(uncapped * perRecord, 102_400)
        XCTAssertEqual(limit * perRecord, 51_200)
    }

    func test_pairBoundToSameBinding() {
        let pair = TokenSaverWaveAShadowMetrics.PairedControlEvidence(
            pairID: "p1", bindingDigest: d1,
            treatmentTrajectoryID: "t", controlTrajectoryID: "c",
            treatmentRounds: 2, controlRounds: 5,
            treatmentUsageTokens: 100, controlUsageTokens: 250,
            sameTaskCorpus: true, sameTaskSuccess: true, retriesMatched: true
        )
        XCTAssertTrue(pair.isComplete)
        let ok = TokenSaverWaveAShadowMetrics.Record(
            bindingDigest: d1, cacheVolatileTokens: 0, queueCohortSize: 0, pair: pair
        )
        XCTAssertEqual(ok?.providerRoundsAvoided, 3)
        XCTAssertNotNil(ok?.pair)
        // Cross-binding pair rejected
        XCTAssertNil(TokenSaverWaveAShadowMetrics.Record(
            bindingDigest: d2, cacheVolatileTokens: 0, queueCohortSize: 0, pair: pair
        ))
    }

    func test_incompletePairRejectedOrZero() {
        let pair = TokenSaverWaveAShadowMetrics.PairedControlEvidence(
            pairID: "p1", bindingDigest: d1,
            treatmentTrajectoryID: "t", controlTrajectoryID: "c",
            treatmentRounds: 2, controlRounds: 5,
            treatmentUsageTokens: 100, controlUsageTokens: 250,
            sameTaskCorpus: true, sameTaskSuccess: false, retriesMatched: true
        )
        XCTAssertFalse(pair.isComplete)
        XCTAssertNil(TokenSaverWaveAShadowMetrics.Record(
            bindingDigest: d1, cacheVolatileTokens: 0, queueCohortSize: 0, pair: pair
        ))
    }
}
