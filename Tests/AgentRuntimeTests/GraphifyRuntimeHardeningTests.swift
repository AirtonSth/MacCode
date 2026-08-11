import XCTest
@testable import AgentRuntime

/// S9: Graphify pin/bounds + Token Saver gate consistency.
final class GraphifyRuntimeHardeningTests: XCTestCase {
    func test_defaultPin_isIncompleteUntilCanary() {
        XCTAssertFalse(GraphifyRuntimeHardening.isPinComplete())
        XCTAssertGreaterThan(GraphifyRuntimeHardening.maxStdoutCaptureBytes, 0)
        XCTAssertGreaterThan(GraphifyRuntimeHardening.maxArtifactBytes, 0)
    }

    func test_watchers_requireRebuildCancelWhenInFlight() {
        XCTAssertFalse(
            GraphifyRuntimeHardening.mayStopWatchers(rebuildInFlight: true, rebuildCancelled: false)
        )
        XCTAssertTrue(
            GraphifyRuntimeHardening.mayStopWatchers(rebuildInFlight: true, rebuildCancelled: true)
        )
        XCTAssertTrue(
            GraphifyRuntimeHardening.mayStopWatchers(rebuildInFlight: false, rebuildCancelled: false)
        )
    }

    func test_tokenSaverOff_graphifyMustNotClaimActive() {
        let sample = TokenSaverFairnessSample(
            failOpenReason: "sidecar_unavailable",
            tokenSaverEnabled: false,
            graphifyRuntimeActive: true
        )
        XCTAssertFalse(sample.isGateConsistent)

        let ok = TokenSaverFairnessSample(
            tokenSaverEnabled: false,
            graphifyRuntimeActive: false
        )
        XCTAssertTrue(ok.isGateConsistent)
    }
}
