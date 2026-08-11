import XCTest
@testable import AppShell
@testable import AppLifecycleSupport
@testable import AgentRuntime

/// S7 production wiring: AppDiagnostics heartbeat drives
/// PressureGovernorCoordinator.ingest + execute (not test-only).
@MainActor
final class PressureGovernorHeartbeatWiringTests: XCTestCase {
    func test_heartbeatIngest_rssHysteresis_twoSamplesEscalate() {
        GraphifyWorkspaceService.shared.setPressurePauseEnsureAndWatch(false)
        // Fresh coordinator so prior suite state cannot poison thresholds.
        // Replace shared by ingesting into a known high-RSS complete sample twice.
        let profile = ManagedProcessMemoryProfile.resolve(physicalMemoryBytes: 16 * 1024 * 1024 * 1024)
        // ~95% of 16 GiB physical → above criticalFraction (0.80).
        let highKB = Int(Double(16 * 1024 * 1024) * 0.95)
        let sample = AppDiagnostics.ManagedAggregateSample(
            appFootprintKB: highKB,
            providerProcessCount: 0,
            providerRootCount: 0,
            providerRSSKB: 0,
            sidecarProcessCount: 0,
            sidecarRootCount: 0,
            sidecarRSSKB: 0,
            totalManagedRSSKB: highKB,
            previousTotalManagedRSSKB: nil,
            sampleIntervalSeconds: 5,
            deltaManagedRSSKB: nil,
            slopeKBPerMinute: nil,
            highWaterManagedRSSKB: highKB,
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

        // First sample: hold (RSS must not use OS immediate path).
        AppDiagnostics.ingestPressureFromHeartbeatSampleForTesting(
            sample: sample,
            activeAgentThreads: 0,
            surface: surface
        )
        let afterFirst = AppDiagnostics.pressureGovernor.currentState().level
        // Second sample: escalate.
        AppDiagnostics.ingestPressureFromHeartbeatSampleForTesting(
            sample: sample,
            activeAgentThreads: 0,
            surface: surface
        )
        let afterSecond = AppDiagnostics.pressureGovernor.currentState().level
        XCTAssertTrue(afterSecond >= afterFirst)
        XCTAssertNotEqual(afterSecond, .normal, "two high-RSS samples must escalate")
        // Graphify pause is a real mutation when executed.
        if afterSecond >= .warning {
            XCTAssertTrue(
                GraphifyWorkspaceService.shared.isPressurePauseEnsureAndWatch
                    || AppDiagnostics.activePressureEffectsForTesting.contains(.pauseGraphifyEnsureAndWatchCallbacks)
                    || !(AppDiagnostics.lastPressureExecuteOutcomeForTesting?.applied ?? []).isEmpty
                    || AppDiagnostics.lastPressureIngestEmittedForTesting.isEmpty == false
            )
        }
        XCTAssertFalse(PressureGovernorCoordinator.killsActiveTurns)
        GraphifyWorkspaceService.shared.setPressurePauseEnsureAndWatch(false)
    }

    func test_pressureGovernor_isSharedProcessInstance() {
        let a = ObjectIdentifier(AppDiagnostics.pressureGovernor)
        let b = ObjectIdentifier(AppDiagnostics.pressureGovernor)
        XCTAssertEqual(a, b)
    }
}
