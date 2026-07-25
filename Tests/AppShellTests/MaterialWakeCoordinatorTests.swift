import XCTest
@testable import AppShell

final class MaterialWakeCoordinatorTests: XCTestCase {
    func testStreamOnlyNeverAllowed() {
        let d = MaterialWakeCoordinator.shouldSilentWake(
            kind: "agent.item.delta",
            wakePhaseA: true,
            wakePhaseBGit: true
        )
        XCTAssertFalse(d.allowed)
        XCTAssertEqual(d.reason, "stream_only")
    }

    func testPhaseAOffBlocksCriticalLifecycle() {
        let d = MaterialWakeCoordinator.shouldSilentWake(
            kind: "agent.run.completed",
            wakePhaseA: false,
            wakePhaseBGit: false
        )
        XCTAssertFalse(d.allowed)
        XCTAssertEqual(d.reason, "phase_a_off")
    }

    func testPhaseAOnAllowsCompletedAndForceBootEpoch() {
        let completed = MaterialWakeCoordinator.shouldSilentWake(
            kind: "agent.run.completed",
            wakePhaseA: true,
            wakePhaseBGit: false
        )
        XCTAssertTrue(completed.allowed)
        XCTAssertFalse(completed.force)

        let boot = MaterialWakeCoordinator.shouldSilentWake(
            kind: "host.boot_epoch",
            wakePhaseA: true,
            wakePhaseBGit: false
        )
        XCTAssertTrue(boot.allowed)
        XCTAssertTrue(boot.force)
    }

    func testPhaseBGitGated() {
        let off = MaterialWakeCoordinator.shouldSilentWake(
            kind: "git.push",
            wakePhaseA: true,
            wakePhaseBGit: false
        )
        XCTAssertFalse(off.allowed)
        let on = MaterialWakeCoordinator.shouldSilentWake(
            kind: "git.push",
            wakePhaseA: true,
            wakePhaseBGit: true
        )
        XCTAssertTrue(on.allowed)
    }

    func testFeatureFlagsDefaultOff() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: ConnectionFeatureFlags.wakePhaseAKey)
        defaults.removeObject(forKey: ConnectionFeatureFlags.wakePhaseBGitKey)
        defaults.removeObject(forKey: ConnectionFeatureFlags.wakeOutboxKey)
        defaults.removeObject(forKey: ConnectionFeatureFlags.selectiveCatchUpKey)
        defaults.removeObject(forKey: ConnectionFeatureFlags.transportKeepaliveExpKey)
        XCTAssertFalse(ConnectionFeatureFlags.wakePhaseAEnabled)
        XCTAssertFalse(ConnectionFeatureFlags.wakePhaseBGitEnabled)
        XCTAssertFalse(ConnectionFeatureFlags.wakeOutboxEnabled)
        XCTAssertFalse(ConnectionFeatureFlags.selectiveCatchUpEnabled)
        XCTAssertFalse(ConnectionFeatureFlags.transportKeepaliveExperimentEnabled)
        XCTAssertEqual(ConnectionFeatureFlags.inventory().count, 5)
    }
}
