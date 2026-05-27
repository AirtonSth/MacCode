import XCTest
@testable import AppShell
import Persistence

@MainActor
final class InsomniaSidebarTests: XCTestCase {
    private final class FakeInsomniaPowerManager: InsomniaPowerManaging {
        var activateReasons: [String] = []
        var activateOptions: [InsomniaPowerOptions] = []
        var deactivateCount = 0
        var shouldActivate = true

        func activate(reason: String, options: InsomniaPowerOptions) -> Bool {
            activateReasons.append(reason)
            activateOptions.append(options)
            return shouldActivate
        }

        func deactivate() {
            deactivateCount += 1
        }

        func releaseProcessAssertions() {}
    }

    private func make(
        dir: String = NSTemporaryDirectory() + "RC2Insomnia-" + UUID().uuidString,
        seedSettings: AppSettings? = nil,
        power: FakeInsomniaPowerManager = FakeInsomniaPowerManager()
    ) throws -> (AppContext, AppCommandRouter, SidebarViewModel, FakeInsomniaPowerManager) {
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        if let seedSettings {
            SettingsStore(db: ctx.db).save(seedSettings)
        }
        let vm = SidebarViewModel(context: ctx, router: router, insomniaPower: power)
        return (ctx, router, vm, power)
    }

    func test_defaultInactiveWhenUserHasNotChangedToggle() throws {
        let (ctx, _, vm, power) = try make()

        XCTAssertFalse(vm.insomniaEnabled)
        XCTAssertFalse(SettingsStore(db: ctx.db).load().insomniaEnabled,
                       "a user with no saved Insomnia choice must launch macOS without asking for an admin password")
        XCTAssertTrue(power.activateReasons.isEmpty,
                      "default inactive Insomnia must not acquire macOS keep-awake assertions on launch")
    }

    func test_toggleOffPersistsAndReloadsOff() throws {
        let dir = NSTemporaryDirectory() + "RC2InsomniaOff-" + UUID().uuidString
        let (ctx, _, vm, power) = try make(dir: dir, seedSettings: AppSettings(insomniaEnabled: true))

        vm.setInsomniaEnabled(false)

        let disabled = SettingsStore(db: ctx.db).load()
        XCTAssertFalse(vm.insomniaEnabled)
        XCTAssertFalse(disabled.insomniaEnabled, "turning Insomnia off must persist the inactive session")
        XCTAssertGreaterThan(power.deactivateCount, 0,
                             "turning Insomnia off must release the macOS keep-awake assertion")

        let (_, _, reloaded, reloadedPower) = try make(dir: dir)
        XCTAssertFalse(reloaded.insomniaEnabled)
        XCTAssertTrue(reloadedPower.activateReasons.isEmpty,
                      "a saved off choice must survive relaunch and must not reacquire keep-awake")
    }

    func test_toggleOnPersistsAndReloadsOn() throws {
        let dir = NSTemporaryDirectory() + "RC2InsomniaOn-" + UUID().uuidString
        let (ctx, _, vm, power) = try make(dir: dir, seedSettings: AppSettings(insomniaEnabled: false))

        vm.setInsomniaEnabled(true)

        XCTAssertTrue(vm.insomniaEnabled)
        XCTAssertTrue(SettingsStore(db: ctx.db).load().insomniaEnabled,
                      "turning Insomnia on must persist the active session")
        XCTAssertEqual(power.activateReasons, ["RemoteCode Insomnia"],
                       "turning Insomnia on must acquire the macOS keep-awake assertion")

        let (_, _, reloaded, reloadedPower) = try make(dir: dir)
        XCTAssertTrue(reloaded.insomniaEnabled)
        XCTAssertEqual(reloadedPower.activateReasons, ["RemoteCode Insomnia"],
                       "a saved on choice must survive relaunch and reacquire keep-awake")
    }

    func test_optionsPersistAndUpdateActiveSession() throws {
        let (ctx, _, vm, power) = try make(seedSettings: AppSettings(insomniaEnabled: false))

        vm.setInsomniaAllowDisplaySleep(false)
        vm.setInsomniaAllowSystemSleepWhenDisplayClosed(true)
        vm.setInsomniaAllowScreenSaverAfter45MinutesOfInactivity(false)
        var settings = SettingsStore(db: ctx.db).load()
        XCTAssertFalse(settings.insomniaAllowDisplaySleep)
        XCTAssertTrue(settings.insomniaAllowSystemSleepWhenDisplayClosed)
        XCTAssertFalse(settings.insomniaAllowScreenSaverAfter45MinutesOfInactivity)
        XCTAssertTrue(power.activateOptions.isEmpty,
                      "changing Insomnia options while inactive must persist preferences without starting a session")

        vm.setInsomniaEnabled(true)
        settings = SettingsStore(db: ctx.db).load()
        XCTAssertTrue(settings.insomniaEnabled)
        XCTAssertEqual(power.activateOptions.last, InsomniaPowerOptions(
            allowDisplaySleep: false,
            allowSystemSleepWhenDisplayClosed: true,
            allowScreenSaverAfter45MinutesOfInactivity: false
        ))

        vm.setInsomniaAllowDisplaySleep(true)
        XCTAssertEqual(power.activateOptions.last, InsomniaPowerOptions(
            allowDisplaySleep: true,
            allowSystemSleepWhenDisplayClosed: true,
            allowScreenSaverAfter45MinutesOfInactivity: false
        ), "adjusting options while active must immediately restart the active keep-awake assertion")
    }

    func test_powerAssertionFailurePersistsOff() throws {
        let power = FakeInsomniaPowerManager()
        power.shouldActivate = false
        let (ctx, _, vm, _) = try make(seedSettings: AppSettings(insomniaEnabled: false), power: power)

        vm.setInsomniaEnabled(true)

        let settings = SettingsStore(db: ctx.db).load()
        XCTAssertFalse(vm.insomniaEnabled)
        XCTAssertFalse(settings.insomniaEnabled,
                       "if macOS refuses the keep-awake assertion, the sidebar must fail loud by returning to off state")
        XCTAssertEqual(power.activateReasons, ["RemoteCode Insomnia"])
    }
}
