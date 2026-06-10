import XCTest
import AppKit
@testable import Surfaces
import CoreModel
import Persistence
import AgentRuntime

/// Integration tests: plan notes persist per-thread through the ViewModel
/// using a real SQLite DB + PlanNotesStore.
///
/// Rule 8 intent: the business contract is "notes typed in one thread survive
/// navigation away and back". Tests would fail if:
///   - selectThread blanks notes instead of loading persisted ones
///   - savePlanNotes uses the wrong key (e.g., workspaceID instead of threadID)
///   - a second thread's save overwrites the first thread's notes
@MainActor
final class PlanNotesPersistenceTests: XCTestCase {

    private func makeVM() throws -> AgentAppViewModel {
        let tmp = NSTemporaryDirectory() + "rc2-plan-notes-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coord = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(provider: .codex),
                        .claude: FakeProviderRunner(provider: .claude)]
        )
        return AgentAppViewModel(
            workspaceID: WorkspaceID(), cwd: tmp,
            coordinator: coord, threadRepo: threadRepo,
            messageRepo: messageRepo,
            planNotesStore: PlanNotesStore(db: db)
        )
    }

    func test_planNotes_persistAndRestoreOnThreadSwitch() throws {
        let vm = try makeVM()

        vm.createThread(title: "Thread A")
        let idA = try XCTUnwrap(vm.selectedThreadId)

        // User types notes on thread A and we save them.
        vm.planNotes = "notes for A"
        vm.savePlanNotes()

        // User opens thread B.
        vm.createThread(title: "Thread B")
        let idB = try XCTUnwrap(vm.selectedThreadId)
        XCTAssertNotEqual(idA, idB)

        // Notes on B should default to empty.
        XCTAssertEqual(vm.planNotes, "",
                       "a freshly opened thread must show empty notes, not bleed from thread A")

        // User switches back to thread A.
        vm.selectThread(idA)

        XCTAssertEqual(vm.planNotes, "notes for A",
                       "notes must be restored when the user navigates back to thread A")
    }

    func test_planNotes_twoThreadsIndependent() throws {
        let vm = try makeVM()

        vm.createThread(title: "Alpha")
        let idA = try XCTUnwrap(vm.selectedThreadId)
        vm.planNotes = "alpha notes"
        vm.savePlanNotes()

        vm.createThread(title: "Beta")
        let idB = try XCTUnwrap(vm.selectedThreadId)
        vm.planNotes = "beta notes"
        vm.savePlanNotes()

        // Switch back and verify isolation.
        vm.selectThread(idA)
        XCTAssertEqual(vm.planNotes, "alpha notes",
                       "saving beta notes must not overwrite alpha notes — threads must be isolated")

        vm.selectThread(idB)
        XCTAssertEqual(vm.planNotes, "beta notes",
                       "beta notes must survive after alpha is also read back")
    }

    func test_planNotes_emptyByDefaultOnNewThread() throws {
        let vm = try makeVM()
        vm.createThread(title: "Fresh")
        XCTAssertEqual(vm.planNotes, "",
                       "a new thread with no saved notes must show an empty editor, not a crash or stale value")
    }
}
