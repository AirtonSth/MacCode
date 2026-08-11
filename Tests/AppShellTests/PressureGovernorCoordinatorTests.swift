import XCTest
@testable import AppLifecycleSupport

/// S7: pressure coordinator never kills active turns or defers schedules;
/// stale epoch executes zero mutations.
final class PressureGovernorCoordinatorTests: XCTestCase {
    func test_staleEpoch_executesZeroMutations() {
        let coord = PressureGovernorCoordinator(
            state: PressureGovernorState(level: .warning, epoch: 5)
        )
        let plan = PressureMutationPlan(
            actions: PressureGovernorStateMachine.warningActions,
            target: PressureMutationTarget(
                epoch: 4,
                surfaceVisible: false,
                providerSessionActive: false,
                sidecarRequestGeneration: 1
            )
        )
        let live = PressureMutationTarget(
            epoch: 5,
            surfaceVisible: false,
            providerSessionActive: false,
            sidecarRequestGeneration: 1
        )
        let outcome = coord.execute(plan: plan, liveTarget: live)
        XCTAssertTrue(outcome.applied.isEmpty)
        XCTAssertEqual(outcome.reason, "stale_epoch")
    }

    func test_visibleSurface_skipsUIReclaim() {
        let coord = PressureGovernorCoordinator(
            state: PressureGovernorState(level: .warning, epoch: 1)
        )
        let target = PressureMutationTarget(
            epoch: 1,
            surfaceVisible: true,
            providerSessionActive: false,
            sidecarRequestGeneration: 0
        )
        let plan = PressureMutationPlan(
            actions: [.reclaimHiddenRecomputableUI, .deferMaintenancePrune],
            target: target
        )
        let outcome = coord.execute(plan: plan, liveTarget: target)
        XCTAssertFalse(outcome.applied.contains(.reclaimHiddenRecomputableUI))
        XCTAssertTrue(outcome.applied.contains(.deferMaintenancePrune))
    }

    func test_invariants_neverKillOrDeferSchedule() {
        XCTAssertFalse(PressureGovernorCoordinator.killsActiveTurns)
        XCTAssertFalse(PressureGovernorCoordinator.defersScheduledOccurrences)
        XCTAssertFalse(CapacityUXStatus.pressureDefersScheduledOccurrences)
        XCTAssertFalse(CapacityUXStatus.userMayReleaseLiveProviderRSS)
    }

    func test_ingest_osCritical_updatesState() {
        let coord = PressureGovernorCoordinator()
        let t0 = Date(timeIntervalSince1970: 9_000)
        let result = coord.ingest(
            sample: PressureSample(
                date: t0,
                osSignal: .critical,
                managedRSSFraction: 0.2,
                isComplete: true
            ),
            now: t0
        )
        XCTAssertEqual(result.state.level, .critical)
        XCTAssertEqual(coord.currentState().level, .critical)
    }

    func test_capacityUX_accessibleSummary_mentionsEnvelope() {
        let status = CapacityUXStatus(
            hardwareTierName: "unmeasured-host",
            envelope: .unmeasured,
            hostPressure: .warning,
            providerTreePressure: .normal,
            degradationActions: ["pause Graphify ensure"],
            unavailableSections: ["hangWatchdog"],
            canExportDiagnostics: true
        )
        XCTAssertTrue(status.accessibleSummary.contains("unmeasured"))
        XCTAssertTrue(status.accessibleSummary.contains("host pressure warning"))
        XCTAssertTrue(status.canExportDiagnostics)
    }
}
