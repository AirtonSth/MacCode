import XCTest
@testable import CoreModel

final class TokenSaverCapacityOpsTests: XCTestCase {
    private func validProfile() -> TokenSaverCapacityOps.CapacityProfile {
        TokenSaverCapacityOps.CapacityProfile(
            concurrency: 2, maxBytesPerTurn: 1000, maxRSSBytes: 1000,
            expiresAt: Date().addingTimeInterval(3600), signed: true
        )
    }

    func test_missingProfile_off() {
        let rt = TokenSaverCapacityOps.Runtime()
        XCTAssertEqual(rt.evaluate(profile: nil, rss: 0, bytes: 0), .offMissingOrExpiredProfile)
    }

    func test_expiredProfile_off() {
        let rt = TokenSaverCapacityOps.Runtime()
        let p = TokenSaverCapacityOps.CapacityProfile(
            concurrency: 2, maxBytesPerTurn: 1000, maxRSSBytes: 1000,
            expiresAt: Date().addingTimeInterval(-10), signed: true
        )
        XCTAssertEqual(rt.evaluate(profile: p, rss: 0, bytes: 0), .offMissingOrExpiredProfile)
    }

    func test_zeroRSSProfile_invalid() {
        let p = TokenSaverCapacityOps.CapacityProfile(
            concurrency: 2, maxBytesPerTurn: 1000, maxRSSBytes: 0,
            expiresAt: Date().addingTimeInterval(3600), signed: true
        )
        XCTAssertFalse(p.isValid())
    }

    func test_breach_raw() {
        let rt = TokenSaverCapacityOps.Runtime()
        let p = TokenSaverCapacityOps.CapacityProfile(
            concurrency: 2, maxBytesPerTurn: 100, maxRSSBytes: 100,
            expiresAt: Date().addingTimeInterval(3600), signed: true
        )
        XCTAssertEqual(rt.evaluate(profile: p, rss: 200, bytes: 0), .rawBreach)
    }

    func test_killSwitch_rawNext() {
        let rt = TokenSaverCapacityOps.Runtime()
        rt.activateKillSwitch()
        XCTAssertTrue(rt.nextInvocationIsRaw())
        XCTAssertEqual(rt.evaluate(profile: validProfile(), rss: 0, bytes: 0), .rawKillSwitch)
    }

    func test_rollback_doesNotKillProviderWithoutContract() {
        let rt = TokenSaverCapacityOps.Runtime()
        rt.rollback(terminateHealthyProvider: true, contractAllows: false)
        XCTAssertFalse(rt.lastProviderTerminated)
        rt.rollback(terminateHealthyProvider: true, contractAllows: true)
        XCTAssertTrue(rt.lastProviderTerminated)
    }

    func test_staleOps_blocksPromotion() {
        let rt = TokenSaverCapacityOps.Runtime()
        rt.setOpsTelemetryFresh(false)
        XCTAssertTrue(rt.promotionBlockedByStaleOps())
    }

    func test_deleteEpoch_fencesLateOutcomes() {
        let rt = TokenSaverCapacityOps.Runtime()
        let started = rt.currentDeleteEpoch()
        XCTAssertEqual(rt.lateOutcome(outcomeEpoch: started, revocationNormal: true), "quarantine")
        rt.advanceDeleteEpoch()
        // Pre-deletion outcome is late vs advanced epoch → rejected
        XCTAssertEqual(rt.lateOutcome(outcomeEpoch: started, revocationNormal: true), "rejected")
        // Same-epoch (started after advance) not rejected solely by epoch
        let after = rt.currentDeleteEpoch()
        XCTAssertEqual(rt.lateOutcome(outcomeEpoch: after, revocationNormal: true), "quarantine")
    }
}
