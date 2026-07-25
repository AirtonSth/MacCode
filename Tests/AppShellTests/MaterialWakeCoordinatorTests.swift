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

    func testFeatureFlagsDefaultsPhaseAAndKeepaliveOn() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: ConnectionFeatureFlags.wakePhaseAKey)
        defaults.removeObject(forKey: ConnectionFeatureFlags.wakePhaseBGitKey)
        defaults.removeObject(forKey: ConnectionFeatureFlags.wakeOutboxKey)
        defaults.removeObject(forKey: ConnectionFeatureFlags.selectiveCatchUpKey)
        defaults.removeObject(forKey: ConnectionFeatureFlags.transportKeepaliveExpKey)
        XCTAssertTrue(
            ConnectionFeatureFlags.wakePhaseAEnabled,
            "wake_phase_a defaults on so material silent wakes ship without a canary flip"
        )
        XCTAssertTrue(
            ConnectionFeatureFlags.transportKeepaliveExperimentEnabled,
            "transport keepalive defaults on (25s HTTP idle) for 3G RRC"
        )
        XCTAssertFalse(ConnectionFeatureFlags.wakePhaseBGitEnabled)
        XCTAssertFalse(ConnectionFeatureFlags.wakeOutboxEnabled)
        XCTAssertFalse(ConnectionFeatureFlags.selectiveCatchUpEnabled)
        XCTAssertEqual(ConnectionFeatureFlags.inventory().count, 5)

        // Kill switch: explicit false must win over default-on.
        defaults.set(false, forKey: ConnectionFeatureFlags.wakePhaseAKey)
        defaults.set(false, forKey: ConnectionFeatureFlags.transportKeepaliveExpKey)
        XCTAssertFalse(ConnectionFeatureFlags.wakePhaseAEnabled)
        XCTAssertFalse(ConnectionFeatureFlags.transportKeepaliveExperimentEnabled)
        defaults.removeObject(forKey: ConnectionFeatureFlags.wakePhaseAKey)
        defaults.removeObject(forKey: ConnectionFeatureFlags.transportKeepaliveExpKey)
    }

    func testFlagValueUnsetUsesDefaultOn() {
        let defaults = UserDefaults.standard
        let key = "connection.flag.test_default_on_\(UUID().uuidString)"
        defaults.removeObject(forKey: key)
        XCTAssertTrue(ConnectionFeatureFlags.flagValue(key: key, defaultOn: true, defaults: defaults))
        XCTAssertFalse(ConnectionFeatureFlags.flagValue(key: key, defaultOn: false, defaults: defaults))
        defaults.set(false, forKey: key)
        XCTAssertFalse(ConnectionFeatureFlags.flagValue(key: key, defaultOn: true, defaults: defaults))
        defaults.set(true, forKey: key)
        XCTAssertTrue(ConnectionFeatureFlags.flagValue(key: key, defaultOn: false, defaults: defaults))
        defaults.removeObject(forKey: key)
    }

    func testSilentPayloadIncludesWatermarkSinceSeqAndBootEpoch() {
        let payload = MaterialWakeCoordinator.makeSilentPayload(
            eventSeq: 77,
            reason: "agent.run.completed",
            bootEpoch: "12",
            watermark: "80"
        )
        let data = payload.asPushData()
        XCTAssertEqual(data["rc2_catch_up"], "1")
        XCTAssertEqual(data["rc2_since_seq"], "77")
        XCTAssertEqual(data["rc2_boot_epoch"], "12")
        XCTAssertEqual(data["rc2_wm"], "80")
        XCTAssertEqual(data["rc2_schema"], SilentCatchUpV1.schemaVersion)
        // Privacy: free-form agent text cannot be smuggled via wm.
        let scrubbed = MaterialWakeCoordinator.makeSilentPayload(
            eventSeq: 1,
            reason: "x",
            bootEpoch: "not-a-number",
            watermark: "agent said hello"
        )
        XCTAssertNil(scrubbed.bootEpoch)
        XCTAssertNil(scrubbed.watermark)
    }
}
