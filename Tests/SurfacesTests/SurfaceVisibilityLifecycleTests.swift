import AppKit
import CoreModel
import XCTest
@testable import Surfaces

@MainActor
final class SurfaceVisibilityLifecycleTests: XCTestCase {
    private var registered: [SurfaceID] = []

    override func tearDown() {
        for id in registered {
            SurfaceRegistry.shared.unregister(id)
        }
        SurfaceRegistry.shared.setVisibleSurfaceIDs([])
        registered.removeAll()
        super.tearDown()
    }

    func test_setVisibleSurfaceIDsDoesNotRepeatLifecycleForUnchangedVisibleSet() {
        let surface = FakeSurface()
        register(surface)

        SurfaceRegistry.shared.setVisibleSurfaceIDs([surface.descriptor.id])
        SurfaceRegistry.shared.setVisibleSurfaceIDs([surface.descriptor.id])

        XCTAssertEqual(surface.visibleCount, 1,
                       "selected terminal surfaces must not receive duplicate visible transitions during repeated workspace refreshes")
        XCTAssertEqual(surface.hiddenCount, 1,
                       "registration must synchronize a new surface to the registry's initially-hidden truth exactly once")
    }

    func test_setVisibleSurfaceIDsHidesOldSurfaceAndShowsNewSurfaceOnce() {
        let first = FakeSurface()
        let second = FakeSurface()
        register(first)
        register(second)

        SurfaceRegistry.shared.setVisibleSurfaceIDs([first.descriptor.id])
        SurfaceRegistry.shared.setVisibleSurfaceIDs([second.descriptor.id])

        XCTAssertEqual(first.visibleCount, 1)
        XCTAssertEqual(first.hiddenCount, 2,
                       "switching tabs must hide the previous terminal exactly once")
        XCTAssertEqual(second.visibleCount, 1,
                       "switching tabs must show the newly selected terminal exactly once")
        XCTAssertEqual(second.hiddenCount, 1)
    }

    func test_registerSynchronizesSurfaceWhenVisibleSetAlreadyContainsItsID() {
        let surface = FakeSurface()
        SurfaceRegistry.shared.setVisibleSurfaceIDs([surface.descriptor.id])

        register(surface)

        XCTAssertEqual(surface.visibleCount, 1)
        XCTAssertEqual(surface.hiddenCount, 0)
    }

    private func register(_ surface: FakeSurface) {
        SurfaceRegistry.shared.register(surface)
        registered.append(surface.descriptor.id)
    }
}

@MainActor
private final class FakeSurface: Surface {
    var descriptor = SurfaceDescriptor(type: .terminal, title: "terminal", iconName: "terminal")
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
    var visibleCount = 0
    var hiddenCount = 0

    func focus() {}
    func unfocus() {}
    func didBecomeVisible() { visibleCount += 1 }
    func didBecomeHidden() { hiddenCount += 1 }
    func close() {}
    func sendText(_ text: String) {}
    func readText() -> String { "" }
    func snapshot() -> [String: String] { [:] }
}
