import XCTest
import CoreModel
import Surfaces
@testable import AppShell

// T007/T011/T013/T014 -- WorkspacePrompting seam (:95)
//
// WHY: renameWorkspace, editDescription, removeWorkspace, and removeSelectedWorkspaces
// previously called NSAlert.runModal() or beginSheetModal directly.  Under XCTest there
// is no key window and no run loop to drive a sheet, so those paths were structurally
// untestable.  The WorkspacePrompting seam lets tests inject a fake prompter that
// immediately returns a pre-determined decision without spinning AppKit.
//
// These tests verify the DECISION side of each path: that a confirmed rename persists,
// a cancelled rename is a no-op, a confirmed remove closes the workspace, etc.
// The AppKitWorkspacePrompter default is not exercised here (it requires a live
// NSWindow); the confirmRemoveDecision() mapping is already covered by
// SidebarSheetSeamsTests.

@MainActor
final class WorkspacePromptingSeamTests: XCTestCase {

    // MARK: - Helpers

    private final class FakeInsomniaPowerManager: InsomniaPowerManaging {
        func activate(reason: String, options: InsomniaPowerOptions) -> Bool { true }
        func deactivate() {}
        func releaseProcessAssertions() {}
    }

    private final class FakeExternalPowerMonitor: ExternalPowerMonitoring {
        var currentPowerState: ExternalPowerState = .externalPower
        var onPowerStateChanged: (@MainActor (ExternalPowerState) -> Void)?
        func start() {}
        func stop() {}
    }

    /// Fake prompter that stores the last call and immediately returns the configured decision.
    private final class FakePrompter: SidebarViewModel.WorkspacePrompting {
        enum Call: Equatable {
            case promptForText(title: String, initial: String, multiline: Bool)
            case confirmRemoveOne(name: String)
            case confirmRemoveMany(count: Int)
        }

        var calls: [Call] = []

        var textDecision: SidebarViewModel.PromptDecision = .cancelled
        var removeDecision: SidebarViewModel.RemoveDecision = .cancelled

        func promptForText(
            title: String,
            message: String,
            initial: String,
            multiline: Bool,
            completion: @escaping @MainActor (SidebarViewModel.PromptDecision) -> Void
        ) {
            calls.append(.promptForText(title: title, initial: initial, multiline: multiline))
            completion(textDecision)
        }

        func confirmRemoveOne(
            name: String,
            completion: @escaping @MainActor (SidebarViewModel.RemoveDecision) -> Void
        ) {
            calls.append(.confirmRemoveOne(name: name))
            completion(removeDecision)
        }

        func confirmRemoveMany(
            count: Int,
            names: [String],
            completion: @escaping @MainActor (SidebarViewModel.RemoveDecision) -> Void
        ) {
            calls.append(.confirmRemoveMany(count: count))
            completion(removeDecision)
        }
    }

    private func closeAndUnregisterAllSurfaces() {
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
    }

    override func tearDown() {
        closeAndUnregisterAllSurfaces()
        super.tearDown()
    }

    private func make() throws -> (AppContext, AppCommandRouter, SidebarViewModel) {
        let dir = NSTemporaryDirectory() + "RC2PromptSeam-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let vm = SidebarViewModel(
            context: ctx,
            router: router,
            insomniaPower: FakeInsomniaPowerManager(),
            powerMonitor: FakeExternalPowerMonitor()
        )
        return (ctx, router, vm)
    }

    // MARK: - T007: renameWorkspace -- confirmed

    /// WHY: when the user types a new name and clicks Save, renameWorkspace must
    /// persist the new name via the router.  A bug here means workspace renames
    /// are silently lost even though the prompter was shown.
    func test_renameWorkspace_confirmed_persistsNewName() throws {
        let (_, router, vm) = try make()
        let ws = try router.createWorkspace(name: "Old Name", cwd: NSTemporaryDirectory())
        vm.reload()

        let fake = FakePrompter()
        fake.textDecision = .committed("Renamed WS")
        vm.workspacePrompter = fake

        vm.renameWorkspace(ws)

        XCTAssertEqual(fake.calls.count, 1,
                       "renameWorkspace must invoke the prompter exactly once -- " +
                       "zero calls means the seam is not wired and the rename dialog never appears")
        let updated = try router.listWorkspaces().first(where: { $0.id == ws.id })
        XCTAssertEqual(updated?.name, "Renamed WS",
                       "confirmed rename must persist the new name via the router -- " +
                       "the old name here means the committed decision never reached the persistence layer")
    }

    // MARK: - T007b: renameWorkspace -- cancelled

    /// WHY: when the user cancels, renameWorkspace must NOT change the workspace name.
    /// A cancel that still reaches the router would silently overwrite workspace names,
    /// which is a data-loss bug.
    func test_renameWorkspace_cancelled_preservesOldName() throws {
        let (_, router, vm) = try make()
        let ws = try router.createWorkspace(name: "Old Name", cwd: NSTemporaryDirectory())
        vm.reload()

        let fake = FakePrompter()
        fake.textDecision = .cancelled
        vm.workspacePrompter = fake

        vm.renameWorkspace(ws)

        let unchanged = try router.listWorkspaces().first(where: { $0.id == ws.id })
        XCTAssertEqual(unchanged?.name, "Old Name",
                       "a cancelled rename must leave the name unchanged -- " +
                       "a mutated name here means Cancel overwrites the workspace name")
    }

    // MARK: - T011: editDescription -- confirmed

    /// WHY: confirmed description edit must persist the text via the router.
    /// Without this test, a broken wiring silently discards user notes.
    func test_editDescription_confirmed_persistsText() throws {
        let (_, router, vm) = try make()
        let ws = try router.createWorkspace(name: "WS", cwd: NSTemporaryDirectory())
        vm.reload()

        let fake = FakePrompter()
        fake.textDecision = .committed("My note")
        vm.workspacePrompter = fake

        vm.editDescription(ws)

        XCTAssertEqual(fake.calls.count, 1,
                       "editDescription must invoke the prompter exactly once")
        let updated = try router.listWorkspaces().first(where: { $0.id == ws.id })
        XCTAssertEqual(updated?.metadata["description"], "My note",
                       "confirmed description edit must persist the note -- " +
                       "nil or empty here means the decision never reached setWorkspaceDescription()")

        // Verify multiline flag is passed -- description uses a taller text view.
        if case .promptForText(_, _, let multiline) = fake.calls[0] {
            XCTAssertTrue(multiline,
                          "editDescription must request the multiline text field -- " +
                          "false here produces a clipped single-line input for long notes, " +
                          "making the description field unusable for multi-sentence text")
        } else {
            XCTFail("expected promptForText call, got \(fake.calls)")
        }
    }

    // MARK: - T013: removeWorkspace -- confirmed

    /// WHY: when the user confirms removal, the workspace must no longer appear in
    /// the workspace list.  A bug here means the Remove menu item appears to work
    /// but leaves the workspace alive in the database.
    func test_removeWorkspace_confirmed_removesFromList() throws {
        let (_, router, vm) = try make()
        let ws = try router.createWorkspace(name: "Target", cwd: NSTemporaryDirectory())
        vm.reload()

        let fake = FakePrompter()
        fake.removeDecision = .confirmed
        vm.workspacePrompter = fake

        vm.removeWorkspace(ws)

        let remaining = try router.listWorkspaces()
        XCTAssertFalse(remaining.map(\.id).contains(ws.id),
                       "confirmed removeWorkspace must remove the workspace from the list -- " +
                       "the workspace still exists here, meaning closeWorkspace() was never called")
        XCTAssertEqual(fake.calls, [.confirmRemoveOne(name: "Target")],
                       "removeWorkspace must use confirmRemoveOne with the workspace name -- " +
                       "a mismatched call means the prompter is invoked with the wrong operation")
    }

    // MARK: - T013b: removeWorkspace -- cancelled

    /// WHY: a cancelled removal must leave the workspace alive.  A cancel that
    /// still triggers closeWorkspace() is a silent data-loss bug.
    func test_removeWorkspace_cancelled_preservesWorkspace() throws {
        let (_, router, vm) = try make()
        let ws = try router.createWorkspace(name: "Target", cwd: NSTemporaryDirectory())
        vm.reload()

        let fake = FakePrompter()
        fake.removeDecision = .cancelled
        vm.workspacePrompter = fake

        vm.removeWorkspace(ws)

        let remaining = try router.listWorkspaces()
        XCTAssertTrue(remaining.map(\.id).contains(ws.id),
                      "cancelled removeWorkspace must preserve the workspace -- " +
                      "absent here means Cancel deleted the workspace anyway, a data-loss bug")
    }

    // MARK: - T014: removeSelectedWorkspaces -- confirmed

    /// WHY: the batch remove path uses confirmRemoveMany, which the single-item path
    /// does not exercise.  Without a test, a broken confirmRemoveMany wiring silently
    /// skips the remove and neither removes nor errors -- the user sees nothing happen.
    func test_removeSelectedWorkspaces_confirmed_removesAllSelected() throws {
        let (_, router, vm) = try make()
        let ws1 = try router.createWorkspace(name: "A", cwd: NSTemporaryDirectory())
        let ws2 = try router.createWorkspace(name: "B", cwd: NSTemporaryDirectory())
        vm.reload()
        vm.selectedWorkspaceIDs = [ws1.id, ws2.id]

        let fake = FakePrompter()
        fake.removeDecision = .confirmed
        vm.workspacePrompter = fake

        vm.removeSelectedWorkspaces()

        let remaining = try router.listWorkspaces()
        XCTAssertFalse(remaining.map(\.id).contains(ws1.id),
                       "confirmed batch remove must close workspace A -- " +
                       "still present here means closeWorkspaces() was not called for A")
        XCTAssertFalse(remaining.map(\.id).contains(ws2.id),
                       "confirmed batch remove must close workspace B -- " +
                       "still present here means closeWorkspaces() was not called for B")
        XCTAssertEqual(fake.calls, [.confirmRemoveMany(count: 2)],
                       "batch remove must use confirmRemoveMany with the correct count -- " +
                       "wrong count means the wrong number of workspaces was described in the confirm dialog")
    }

    // MARK: - Default prompter is AppKitWorkspacePrompter

    /// WHY: the production init must wire an AppKitWorkspacePrompter so that
    /// the prompt paths are never nil.  A nil prompter silently no-ops every
    /// rename/remove action, which is invisible to the user.
    func test_defaultPrompterIsWiredAfterInit() throws {
        let (_, _, vm) = try make()
        XCTAssertNotNil(vm.workspacePrompter,
                        "SidebarViewModel.init must wire a non-nil workspacePrompter -- " +
                        "nil means every rename/remove action is a silent no-op in production")
        XCTAssertTrue(vm.workspacePrompter is SidebarViewModel.AppKitWorkspacePrompter,
                      "the default prompter must be AppKitWorkspacePrompter -- " +
                      "another type here means the production AppKit modal path is bypassed unintentionally")
    }
}
