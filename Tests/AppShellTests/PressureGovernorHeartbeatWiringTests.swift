import XCTest
@testable import AppShell
@testable import AppLifecycleSupport
@testable import AgentRuntime

/// S7 production wiring: AppDiagnostics heartbeat drives
/// PressureGovernorCoordinator.ingest + execute (not test-only).
@MainActor
final class PressureGovernorHeartbeatWiringTests: XCTestCase {
    func test_heartbeatIngest_osCritical_executesNonDestructivePlan() {
        GraphifyWorkspaceService.shared.setPressurePauseEnsureAndWatch(false)
        // Reset coordinator by ingesting from a fresh instance path: use the
        // shared production governor and drive OS-critical samples.
        let profile = ManagedProcessMemoryProfile.resolve(physicalMemoryBytes: 16 * 1024 * 1024 * 1024)
        let sample = AppDiagnostics.ManagedAggregateSample(
            appFootprintKB: 100_000,
            providerProcessCount: 0,
            providerRootCount: 0,
            providerRSSKB: 0,
            sidecarProcessCount: 0,
            sidecarRootCount: 0,
            sidecarRSSKB: 0,
            totalManagedRSSKB: 100_000,
            previousTotalManagedRSSKB: nil,
            sampleIntervalSeconds: 5,
            deltaManagedRSSKB: nil,
            slopeKBPerMinute: nil,
            highWaterManagedRSSKB: 100_000,
            isComplete: true,
            pressureDecision: .critical,
            admissionDecision: .admit,
            profile: profile
        )
        let surface = AppDiagnostics.SurfaceSnapshot(
            surfaceCount: 1,
            terminalCount: 0,
            runningTerminals: 0,
            pendingBytes: 0,
            droppedBytes: 0,
            historyFailures: 0
        )

        // Two samples may be required for RSS escalation; OS critical is immediate.
        AppDiagnostics.ingestPressureFromHeartbeatSampleForTesting(
            sample: sample,
            activeAgentThreads: 0,
            surface: surface
        )

        XCTAssertEqual(
            AppDiagnostics.pressureGovernor.currentState().level,
            .critical,
            "live heartbeat path must advance the production pressure coordinator"
        )
        XCTAssertFalse(AppDiagnostics.lastPressureIngestEmittedForTesting.isEmpty)
        XCTAssertNotNil(AppDiagnostics.lastPressureExecuteOutcomeForTesting)
        // Non-destructive Graphify pause is a real side effect of execute.
        if AppDiagnostics.lastPressureExecuteOutcomeForTesting?.applied
            .contains(.pauseGraphifyEnsureAndWatchCallbacks) == true
        {
            XCTAssertTrue(GraphifyWorkspaceService.shared.isPressurePauseEnsureAndWatch)
        }
        XCTAssertFalse(PressureGovernorCoordinator.killsActiveTurns)
        XCTAssertFalse(PressureGovernorCoordinator.defersScheduledOccurrences)

        // Cleanup so other tests are not poisoned.
        GraphifyWorkspaceService.shared.setPressurePauseEnsureAndWatch(false)
    }

    func test_pressureGovernor_isSharedProcessInstance() {
        let a = ObjectIdentifier(AppDiagnostics.pressureGovernor)
        let b = ObjectIdentifier(AppDiagnostics.pressureGovernor)
        XCTAssertEqual(a, b)
    }
}
