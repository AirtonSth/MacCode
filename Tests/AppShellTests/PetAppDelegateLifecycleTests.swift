import AppKit
import XCTest
@testable import AppShell
import Persistence

@MainActor
final class PetAppDelegateLifecycleTests: XCTestCase {
    func test_defaultSettingsStartVisiblePetAtExisting150PercentVisualSizeWithoutTransparentCanvasPadding() throws {
        let fixture = try makeDelegate()
        defer { fixture.delegate.stopPetController() }

        fixture.delegate.startPetController()

        let settings = SettingsStore(db: fixture.context.db).load()
        XCTAssertTrue(settings.petEnabled)
        XCTAssertEqual(settings.petSize, 1.5)
        let pet = try XCTUnwrap(fixture.delegate.petController)
        XCTAssertTrue(pet.visualRuntimeIsLoadedForTests)
        let panel = try XCTUnwrap(pet.windowControllerForTests.petPanelForTests)
        XCTAssertTrue(panel.isVisible, "a fresh install must show the Pet immediately")

        let atlas = try PetAtlas.bundled()
        let row = try XCTUnwrap(atlas.manifest.row(for: .idle))
        var visualBounds: CGRect?
        for index in 0..<row.frames {
            let bounds = try opaqueBounds(of: atlas.frame(state: .idle, index: index).image)
            visualBounds = visualBounds.map { $0.union(bounds) } ?? bounds
        }
        let idleBounds = try XCTUnwrap(visualBounds)
        let existingSourcePixelScale = CGFloat(118.0 / 192.0)
        XCTAssertEqual(
            panel.frame.width,
            (idleBounds.width * existingSourcePixelScale * 1.5).rounded(),
            accuracy: 0.5,
            "the panel must omit stable transparent padding while preserving the current 150% cat size"
        )
        XCTAssertEqual(
            panel.frame.height,
            (idleBounds.height * existingSourcePixelScale * 1.5).rounded(),
            accuracy: 0.5,
            "visual placement must use the opaque animation envelope so the cat can touch the screen edge"
        )
    }

    func test_appDelegateOwnsPetStartStopAndDisabledMenuResult() throws {
        let fixture = try makeDelegate(petEnabled: false)
        defer { fixture.delegate.stopPetController() }

        fixture.delegate.startPetController()

        let pet = try XCTUnwrap(fixture.delegate.petController)
        XCTAssertFalse(pet.visualRuntimeIsLoadedForTests,
            "Explicitly disabled startup must keep lightweight projection without loading Pet artwork or windows.")
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

    func test_enablingExplicitlyDisabledPetLoadsVisualRuntimeOnDemand() async throws {
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
        petEnabled: Bool? = nil
    ) throws -> (delegate: AppDelegate, context: AppContext, router: AppCommandRouter) {
        let directory = NSTemporaryDirectory() + "RC2PetDelegate-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        if let petEnabled {
            SettingsStore(db: context.db).update { $0.petEnabled = petEnabled }
        }
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

private func opaqueBounds(of image: CGImage) throws -> CGRect {
    let mask = try XCTUnwrap(PetSpriteAlphaMask(image: image))
    var bounds: CGRect?
    for y in 0..<mask.height {
        for x in 0..<mask.width where mask.isOpaque(x: x, y: y) {
            let pixel = CGRect(x: x, y: y, width: 1, height: 1)
            bounds = bounds.map { $0.union(pixel) } ?? pixel
        }
    }
    return try XCTUnwrap(bounds)
}
