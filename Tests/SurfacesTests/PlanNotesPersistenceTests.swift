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
        return try makeVM(workspaceID: WorkspaceID(), tmp: tmp, db: db)
    }

    private func makeVM(workspaceID: WorkspaceID, tmp: String, db: SQLiteDB) throws -> AgentAppViewModel {
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coord = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(provider: .codex),
                        .claude: FakeProviderRunner(provider: .claude)]
        )
        return AgentAppViewModel(
            workspaceID: workspaceID, cwd: tmp,
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

    // WHY: notes are durable, not session state. A cold surface (app relaunch)
    // must never invent notes for an opened thread, must publish the durable
    // read once it lands, and must republish an already-loaded thread's notes on
    // the switch turn instead of waiting for the open bundle.
    func test_planNotes_coldSurfaceHydratesDurableNotesAndWarmSwitchPublishesThem() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-plan-notes-relaunch-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let workspaceID = WorkspaceID()
        let threadRepo = AgentThreadRepository(db: db)
        var threadA = AgentThread(workspaceId: workspaceID, title: "A", provider: .codex, model: "fake-model")
        threadA.status = .completed
        try threadRepo.upsert(threadA)
        var threadB = AgentThread(workspaceId: workspaceID, title: "B", provider: .codex, model: "fake-model")
        threadB.status = .completed
        try threadRepo.upsert(threadB)
        try PlanNotesStore(db: db).save("durable A", threadId: threadA.id)
        try PlanNotesStore(db: db).save("durable B", threadId: threadB.id)

        let vm = try makeVM(workspaceID: workspaceID, tmp: tmp, db: db)
        vm.selectThread(threadA.id)
        XCTAssertEqual(vm.planNotes, "",
                       "a cold surface must show nothing for a thread whose notes it has not read yet")

        await vm.waitForSelectThreadHydrationForTesting()
        XCTAssertEqual(vm.planNotes, "durable A",
                       "the open bundle's read must publish the opened thread's durable notes")

        vm.selectThread(threadB.id)
        XCTAssertEqual(vm.planNotes, "",
                       "switching threads must drop the leaving thread's notes before its own read lands")
        await vm.waitForSelectThreadHydrationForTesting()
        XCTAssertEqual(vm.planNotes, "durable B")

        vm.selectThread(threadA.id)
        XCTAssertEqual(vm.planNotes, "durable A",
                       "an already-loaded thread must republish its notes on the switch turn itself")
    }

    // WHY: notes are per-thread user state; a deleted thread must not keep a
    // cached copy on the surface for the life of the tab.
    func test_planNotes_deleteEvictsCachedNotesForThatThread() async throws {
        let vm = try makeVM()
        vm.createThread(title: "keep")
        let keep = try XCTUnwrap(vm.selectedThreadId)
        vm.createThread(title: "doomed")
        let doomed = try XCTUnwrap(vm.selectedThreadId)
        vm.planNotes = "notes owned by doomed"
        vm.savePlanNotes()
        XCTAssertTrue(vm.threadCacheResidueForTesting.contains(doomed),
                      "precondition: saving notes caches them for that thread")

        await vm.deleteThread(doomed)

        XCTAssertFalse(vm.threadCacheResidueForTesting.contains(doomed),
                       "a deleted thread must not keep its notes cached on the surface")
        XCTAssertEqual(vm.selectedThreadId, keep)
        XCTAssertEqual(vm.planNotes, "",
                       "the fallback thread must not show the deleted thread's notes")
    }
}
