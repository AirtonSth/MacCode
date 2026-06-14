import XCTest
@testable import DistillCore

final class NetPositiveGateTests: XCTestCase {
    private let gate = NetPositiveGate(floorCharacters: 2_000, warmResumeTTLSeconds: 300)

    func test_belowFloor_skips() {
        XCTAssertEqual(gate.decide(inputCharacters: 500, secondsSinceLastTurn: nil), .skipBelowFloor)
        XCTAssertEqual(gate.decide(inputCharacters: 1_999, secondsSinceLastTurn: 10_000), .skipBelowFloor)
    }

    func test_warmResumeWithinTTL_skips() {
        // Large enough, but a turn happened 30s ago => active session, skip the latency.
        XCTAssertEqual(gate.decide(inputCharacters: 8_000, secondsSinceLastTurn: 30), .skipWarmResume)
    }

    func test_coldAndLarge_compresses() {
        XCTAssertEqual(gate.decide(inputCharacters: 8_000, secondsSinceLastTurn: 600), .compress)
    }

    func test_unknownLastTurn_treatedAsCold_compresses() {
        // N5: unknown must map to cold so a genuinely cold prompt is never wrongly skipped.
        XCTAssertEqual(gate.decide(inputCharacters: 8_000, secondsSinceLastTurn: nil), .compress)
        XCTAssertTrue(gate.shouldCompress(inputCharacters: 8_000, secondsSinceLastTurn: nil))
    }

    func test_exactlyAtFloorAndTTLBoundaries() {
        // At the floor → eligible (not below). At exactly the TTL → no longer warm.
        XCTAssertEqual(gate.decide(inputCharacters: 2_000, secondsSinceLastTurn: 300), .compress)
        XCTAssertEqual(gate.decide(inputCharacters: 2_000, secondsSinceLastTurn: 299.9), .skipWarmResume)
    }

    func test_billedSavingsMustRemainPositiveAfterRetrieveDebit() {
        XCTAssertTrue(gate.acceptsBilledSavings(
            originalBilledTokenUnits: 1_000,
            compressedBilledTokenUnits: 600,
            retrieveDebitUnits: 100
        ))
        XCTAssertFalse(gate.acceptsBilledSavings(
            originalBilledTokenUnits: 1_000,
            compressedBilledTokenUnits: 950,
            retrieveDebitUnits: 100
        ), "M2: retrieve/reinjection debit can turn token savings into net-negative billed cost")
    }
}
