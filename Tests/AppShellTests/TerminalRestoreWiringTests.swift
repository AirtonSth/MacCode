import XCTest
@testable import AppShell
@testable import CoreModel
@testable import Surfaces

@MainActor
final class TerminalRestoreWiringTests: XCTestCase {
    private func closeAndUnregisterAllSurfaces() {
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
    }

    func test_restoredLocalTerminalRetainsRestartAction() throws {
        // WHY: a restored shell can exit just like a newly-created shell. Losing
        // this callback removes the restart control and strands the user's tab.
        let directory = NSTemporaryDirectory() + "RC2TerminalRestore-" + UUID().uuidString
        defer {
            closeAndUnregisterAllSurfaces()
            try? FileManager.default.removeItem(atPath: directory)
        }

        do {
            let context = try AppContext(channel: .debug, appSupportOverride: directory)
            let router = AppCommandRouter(context: context)
            context.router = router
            let workspace = try router.createWorkspace(name: "Terminal restore", cwd: NSTemporaryDirectory())
            _ = try router.createSurface(
                workspace: workspace.id,
                type: .terminal,
                paneID: nil,
                title: "Restored shell"
            )
            context.saveSnapshot()
            closeAndUnregisterAllSurfaces()
        }

        let restoredContext = try AppContext(channel: .debug, appSupportOverride: directory)
        let restoredRouter = AppCommandRouter(context: restoredContext)
        restoredContext.router = restoredRouter
        restoredRouter.reinstantiateRestoredSurfaces()

        let restoredTerminal = try XCTUnwrap(
            SurfaceRegistry.shared.all().compactMap { $0 as? TerminalSurface }.first
        )
        XCTAssertNotNil(
            restoredTerminal.onRestartRequested,
            "restored local terminals must keep the same restart wiring as newly-created terminals"
        )
    }
}
