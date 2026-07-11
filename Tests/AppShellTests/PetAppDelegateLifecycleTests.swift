import AppKit
import XCTest
@testable import AppShell
import Persistence

@MainActor
final class PetAppDelegateLifecycleTests: XCTestCase {
    func test_appDelegateOwnsPetStartStopAndDisabledMenuResult() throws {
        let fixture = try makeDelegate(petEnabled: false)
        defer { fixture.delegate.stopPetController() }

        fixture.delegate.startPetController()

        let pet = try XCTUnwrap(fixture.delegate.petController)
        XCTAssertFalse(pet.visualRuntimeIsLoadedForTests,
            "Default-off startup must keep lightweight projection without loading Pet artwork or windows.")
        XCTAssertFalse(fixture.delegate.togglePetPopover(),
            "The menu command must reject a disabled Pet instead of opening hidden UI.")
        fixture.delegate.stopPetController()
        XCTAssertNil(fixture.delegate.petController,
            "The same stop owner used by app termination must release the Pet controller.")
    }

    func test_enabledMenuCommandOpensPetPopoverThroughOwnedController() throws {
        let fixture = try makeDelegate(petEnabled: true)
        defer { fixture.delegate.stopPetController() }
        fixture.delegate.startPetController()
        let pet = try XCTUnwrap(fixture.delegate.petController)

        XCTAssertTrue(fixture.delegate.togglePetPopover())
        XCTAssertTrue(pet.windowControllerForTests.isPopoverVisible)
    }

    func test_enablingDefaultOffPetLoadsVisualRuntimeOnDemand() async throws {
        let fixture = try makeDelegate(petEnabled: false)
        defer { fixture.delegate.stopPetController() }
        fixture.delegate.startPetController()
        let pet = try XCTUnwrap(fixture.delegate.petController)
        XCTAssertFalse(pet.visualRuntimeIsLoadedForTests)

        SettingsStore(db: fixture.context.db).update { $0.petEnabled = true }
        NotificationCenter.default.post(name: .petSettingsDidChange, object: nil)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(pet.visualRuntimeIsLoadedForTests,
            "Enabling Pet must create and wire the visual runtime without restarting the app.")
        XCTAssertTrue(fixture.delegate.togglePetPopover())
    }

    func test_petContextActionsSynchronizeAnOpenSettingsViewModel() async throws {
        let fixture = try makeDelegate(petEnabled: true)
        defer { fixture.delegate.stopPetController() }
        let settingsViewModel = SettingsViewModel(context: fixture.context)
        fixture.delegate.startPetController()
        let pet = try XCTUnwrap(fixture.delegate.petController)

        pet.windowControllerForTests.onToggleAnimations?()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(settingsViewModel.appSettings.petAnimationsEnabled)

        settingsViewModel.setPetReadyCounterEnabled(false)
        let afterSettingsWrite = SettingsStore(db: fixture.context.db).reload()
        XCTAssertFalse(afterSettingsWrite.petAnimationsEnabled,
            "A Settings write must not overwrite the newer Pet context-menu mutation.")
        XCTAssertFalse(afterSettingsWrite.petReadyCounterEnabled)

        pet.windowControllerForTests.onHidePet?()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(settingsViewModel.appSettings.petEnabled)
    }

    private func makeDelegate(
        petEnabled: Bool
    ) throws -> (delegate: AppDelegate, context: AppContext, router: AppCommandRouter) {
        let directory = NSTemporaryDirectory() + "RC2PetDelegate-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        SettingsStore(db: context.db).update { $0.petEnabled = petEnabled }
        let router = AppCommandRouter(context: context)
        context.router = router
        let windowController = MainWindowController(context: context, router: router)
        router.windowController = windowController
        let delegate = AppDelegate(channel: .debug, appSupportOverride: directory)
        delegate.context = context
        delegate.router = router
        delegate.windowController = windowController
        delegate.settings = SettingsWindowController(context: context)
        return (delegate, context, router)
    }
}
