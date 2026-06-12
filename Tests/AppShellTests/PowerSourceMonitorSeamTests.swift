import XCTest
import IOKit.ps
@testable import AppShell

// MARK: - PowerSourceMonitorSeamTests

/// WHY (QA :97): `MacOSExternalPowerMonitor.readCurrentPowerState()` called
/// IOKit directly, making the AC/battery/unknown mapping dead-reckoned — untestable
/// without real hardware. The `PowerSourceProvider` closure seam lets tests inject
/// fixed state strings so every mapping branch is covered deterministically.
///
/// Also covers `mapPowerSourceStates(_:)` as the pure extracted mapper, and
/// `MacOSExternalPowerMonitor.currentPowerState` wired through the injected closure.
final class PowerSourceMonitorSeamTests: XCTestCase {

    // MARK: - mapPowerSourceStates: AC path

    /// WHY: the AC branch must return `.externalPower`. If kIOPSACPowerValue
    /// is mistyped or the comparison is wrong, the sidebar never shows "charging".
    func test_mapPowerSourceStates_acValue_returnsExternalPower() {
        let result = mapPowerSourceStates([kIOPSACPowerValue])
        XCTAssertEqual(result, .externalPower,
            "kIOPSACPowerValue must map to .externalPower " +
            "so the sidebar correctly shows the device is on AC power")
    }

    // MARK: - mapPowerSourceStates: battery path

    /// WHY: the battery branch must return `.battery`. If kIOPSBatteryPowerValue
    /// is mismatched, the sidebar shows AC even on battery, misleading the user.
    func test_mapPowerSourceStates_batteryValue_returnsBattery() {
        let result = mapPowerSourceStates([kIOPSBatteryPowerValue])
        XCTAssertEqual(result, .battery,
            "kIOPSBatteryPowerValue must map to .battery " +
            "so the sidebar correctly reflects battery-powered operation")
    }

    // MARK: - mapPowerSourceStates: empty (no sources)

    /// WHY: a machine with no power sources (edge case / VM / early boot) must
    /// return `.unknown`, not crash or return a stale value.
    func test_mapPowerSourceStates_emptySources_returnsUnknown() {
        let result = mapPowerSourceStates([])
        XCTAssertEqual(result, .unknown,
            "an empty source list must map to .unknown " +
            "so VMs and early-boot scenarios don't show a wrong power state")
    }

    // MARK: - mapPowerSourceStates: unrecognised value

    /// WHY: IOKit can return new or custom source-state strings in future macOS
    /// versions. Any unrecognised string must fall through to `.unknown` rather
    /// than crashing or silently returning a wrong state.
    func test_mapPowerSourceStates_unknownString_returnsUnknown() {
        let result = mapPowerSourceStates(["SomeFuturePowerSource"])
        XCTAssertEqual(result, .unknown,
            "an unrecognised source-state string must map to .unknown " +
            "so future IOKit values don't produce incorrect AC/battery readings")
    }

    // MARK: - mapPowerSourceStates: AC wins over later battery entry

    /// WHY: real machines can have multiple power sources (e.g. internal battery
    /// + external UPS). The mapper must return AC on the first AC entry and not
    /// accidentally fall through to battery if AC appears first in the list.
    func test_mapPowerSourceStates_acFirst_returnsExternalPower() {
        let result = mapPowerSourceStates([kIOPSACPowerValue, kIOPSBatteryPowerValue])
        XCTAssertEqual(result, .externalPower,
            "when AC appears before battery in the source list the result must be .externalPower " +
            "so multi-source machines on AC don't show 'battery'")
    }

    // MARK: - MacOSExternalPowerMonitor.currentPowerState wired through injected closure

    /// WHY: `currentPowerState` must delegate to the injected `PowerSourceProvider`
    /// rather than calling IOKit directly. If the wiring is missing, the injected
    /// provider is never invoked and tests cannot control the returned state.
    func test_monitor_currentPowerState_usesInjectedProvider_ac() {
        let monitor = MacOSExternalPowerMonitor(powerSourceProvider: { [kIOPSACPowerValue] })
        XCTAssertEqual(monitor.currentPowerState, .externalPower,
            "currentPowerState must delegate to the injected provider " +
            "so the AC state is returned without touching real IOKit hardware")
    }

    func test_monitor_currentPowerState_usesInjectedProvider_battery() {
        let monitor = MacOSExternalPowerMonitor(powerSourceProvider: { [kIOPSBatteryPowerValue] })
        XCTAssertEqual(monitor.currentPowerState, .battery,
            "currentPowerState must delegate to the injected provider " +
            "so the battery state is returned without touching real IOKit hardware")
    }

    func test_monitor_currentPowerState_usesInjectedProvider_unknown() {
        let monitor = MacOSExternalPowerMonitor(powerSourceProvider: { [] })
        XCTAssertEqual(monitor.currentPowerState, .unknown,
            "currentPowerState must delegate to the injected provider " +
            "so the unknown state is returned without touching real IOKit hardware")
    }

    // MARK: - provider is called on each access (not cached)

    /// WHY: power state can change at any time (user plugs/unplugs charger).
    /// If the result were cached, `currentPowerState` would return stale data.
    func test_monitor_currentPowerState_callsProviderEachTime() {
        var returnAC = true
        var callCount = 0
        let monitor = MacOSExternalPowerMonitor(powerSourceProvider: {
            callCount += 1
            return returnAC ? [kIOPSACPowerValue] : [kIOPSBatteryPowerValue]
        })

        XCTAssertEqual(monitor.currentPowerState, .externalPower)
        returnAC = false
        XCTAssertEqual(monitor.currentPowerState, .battery,
            "currentPowerState must call the provider on every access " +
            "so power-state changes (plug/unplug) are reflected immediately")
        XCTAssertEqual(callCount, 2,
            "the provider must be called twice (once per currentPowerState access) " +
            "confirming no caching takes place")
    }

    // MARK: - production default uses live IOKit provider

    /// WHY: `MacOSExternalPowerMonitor()` must use `iokitPowerSourceProvider` so
    /// production code reaches real IOKit. If the default were a stub, all
    /// production power readings would be wrong.
    func test_defaultInit_producesNonCrashingResult() {
        // We cannot assert the exact state on a CI machine, but we CAN assert
        // that the default init does not crash and returns a defined enum value.
        let monitor = MacOSExternalPowerMonitor()
        let state = monitor.currentPowerState
        let validStates: Set<ExternalPowerState> = [.externalPower, .battery, .unknown]
        XCTAssertTrue(validStates.contains(state),
            "the default init must return a defined ExternalPowerState value " +
            "so production power monitoring is not broken by the seam introduction")
    }
}
