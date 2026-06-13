import XCTest
import AppKit
@testable import Surfaces
import CoreModel
import Persistence
import AgentRuntime

// UX-XPLAT-DELETE-UNDO: thread delete stays immediate + final (the existing
// contract in AgentAppViewModelTests is unchanged). These tests pin the ADDITIVE
// undo layer: a transient in-memory snapshot lets the user recover an accidental
// delete for a short window without deferring the actual DELETE.
@MainActor
final class AgentThreadDeletionUndoTests: XCTestCase {

    private func makeVM() throws -> AgentAppViewModel {
        let tmp = NSTemporaryDirectory() + "rc2-vm-undo-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coord = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                        threadRepo: threadRepo,
                                        providers: [.codex: FakeProviderRunner(provider: .codex),
                                                    .claude: FakeProviderRunner(provider: .claude)])
        return AgentAppViewModel(workspaceID: WorkspaceID(), cwd: tmp,
                                 coordinator: coord, threadRepo: threadRepo,
                                 messageRepo: messageRepo,
                                 promptHistoryStore: PromptHistoryStore(db: db))
    }

    // WHY: deleting a thread must remain instant and persisted — but an accidental
    // delete is destructive, so the snapshot must be available to undo. This proves
    // BOTH at once: the row is gone from the store immediately, AND an undo handle exists.
    func test_deleteThread_removesImmediatelyButOffersUndo() throws {
        let vm = try makeVM()
        vm.createThread(title: "keep")
        let keep = vm.selectedThreadId!
        vm.createThread(title: "doomed")
        let doomed = vm.selectedThreadId!
        let msg = AgentMessage(threadId: doomed, role: .user, content: "important work")
        try vm.messageRepo.append(msg)

        vm.deleteThread(doomed)

        // Immediate-delete contract: gone from store and from the list right away.
        XCTAssertNil(try vm.threadRepo.get(id: doomed),
                     "delete must remove the row immediately; undo is a separate snapshot, not a deferred delete")
        XCTAssertFalse(vm.threads.contains { $0.id == doomed })
        XCTAssertEqual(vm.selectedThreadId, keep, "selection must fall back to a remaining thread")
        // Additive undo affordance is armed.
        XCTAssertEqual(vm.pendingThreadDeletionUndo?.count, 1,
                       "an accidental delete must leave a recoverable snapshot")
    }

    // WHY: the whole point of undo is data recovery. Restoring must bring back the
    // thread AND its messages (FK-safe: thread row first, then messages).
    func test_undoLastThreadDeletion_restoresThreadAndMessagesWithinWindow() throws {
        let vm = try makeVM()
        vm.createThread(title: "doomed")
        let doomed = vm.selectedThreadId!
        let m1 = AgentMessage(threadId: doomed, role: .user, content: "first", createdAt: Date(timeIntervalSince1970: 1))
        let m2 = AgentMessage(threadId: doomed, role: .assistant, content: "second", createdAt: Date(timeIntervalSince1970: 2))
        try vm.messageRepo.append(m1)
        try vm.messageRepo.append(m2)

        vm.deleteThread(doomed)
        XCTAssertNil(try vm.threadRepo.get(id: doomed))
        XCTAssertTrue(((try? vm.messageRepo.list(threadId: doomed)) ?? []).isEmpty,
                      "messages CASCADE-delete with the thread, so undo must re-insert them")

        let restored = vm.undoLastThreadDeletion()

        XCTAssertTrue(restored, "undo within the window must succeed")
        XCTAssertEqual(try vm.threadRepo.get(id: doomed)?.title, "doomed",
                       "the deleted thread row must come back intact")
        let rows = try vm.messageRepo.list(threadId: doomed)
        XCTAssertEqual(rows.map(\.content), ["first", "second"],
                       "all messages must be restored in their original order")
        XCTAssertNil(vm.pendingThreadDeletionUndo, "the snapshot is consumed once undone")
        XCTAssertEqual(vm.selectedThreadId, doomed, "undo must reselect the restored thread")
    }

    // WHY: undo is a brief safety net, not permanent. After the window lapses the
    // snapshot is dropped and the delete is final — undo must NOT resurrect it.
    func test_undoLastThreadDeletion_isNoOpAfterWindowLapses() throws {
        let vm = try makeVM()
        var now = Date(timeIntervalSince1970: 1000)
        vm.setClockForTests { now }
        vm.createThread(title: "doomed")
        let doomed = vm.selectedThreadId!

        vm.deleteThread(doomed)
        XCTAssertNotNil(vm.pendingThreadDeletionUndo)

        // Advance past the 10s window.
        now = now.addingTimeInterval(AgentAppViewModel.threadDeletionUndoWindow + 1)
        let restored = vm.undoLastThreadDeletion()

        XCTAssertFalse(restored, "undo after the window must do nothing")
        XCTAssertNil(try vm.threadRepo.get(id: doomed),
                     "a delete is permanent once the undo window lapses")
        XCTAssertNil(vm.pendingThreadDeletionUndo, "the stale snapshot must be dropped")
    }

    // WHY: bulk delete must be recoverable as a unit — count drives the toast copy
    // and every deleted thread must come back.
    func test_undoLastThreadDeletion_restoresAllThreadsFromBulkDelete() throws {
        let vm = try makeVM()
        vm.createThread(title: "a")
        let a = vm.selectedThreadId!
        vm.createThread(title: "b")
        let b = vm.selectedThreadId!

        vm.deleteThreads([a, b])
        XCTAssertEqual(vm.pendingThreadDeletionUndo?.count, 2,
                       "the toast count must reflect every deleted thread")
        XCTAssertNil(try vm.threadRepo.get(id: a))
        XCTAssertNil(try vm.threadRepo.get(id: b))

        XCTAssertTrue(vm.undoLastThreadDeletion())
        XCTAssertNotNil(try vm.threadRepo.get(id: a), "bulk undo must restore every thread")
        XCTAssertNotNil(try vm.threadRepo.get(id: b), "bulk undo must restore every thread")
    }

    // MARK: pure seam

    // WHY: the expiry predicate is the contract for "how long can I undo" and must
    // be exact at the boundary so the window is neither too short nor unbounded.
    func test_isWithinUndoWindow_boundaryIsExclusive() {
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(AgentAppViewModel.ThreadDeletionUndo.isWithinUndoWindow(
            capturedAt: t0, now: t0, window: 10), "the instant of delete is inside the window")
        XCTAssertTrue(AgentAppViewModel.ThreadDeletionUndo.isWithinUndoWindow(
            capturedAt: t0, now: t0.addingTimeInterval(9.999), window: 10))
        XCTAssertFalse(AgentAppViewModel.ThreadDeletionUndo.isWithinUndoWindow(
            capturedAt: t0, now: t0.addingTimeInterval(10), window: 10),
            "at exactly the window the snapshot has expired")
    }

    // WHY: agent_messages has a thread_id FK with ON DELETE CASCADE under
    // foreign_keys=ON. Re-inserting a message before its parent thread row would
    // violate the FK, so the restore plan must order the thread first and messages
    // oldest→newest. This test guards against the historical FK-breakage regression.
    func test_restorePlan_ordersMessagesOldestFirstForFKSafeReinsert() {
        let threadId = AgentThreadID()
        let thread = AgentThread(id: threadId, workspaceId: WorkspaceID(), title: "t", provider: .codex, model: "gpt-5.5")
        let older = AgentMessage(threadId: threadId, role: .user, content: "older", createdAt: Date(timeIntervalSince1970: 1))
        let newer = AgentMessage(threadId: threadId, role: .assistant, content: "newer", createdAt: Date(timeIntervalSince1970: 5))
        let snapshot = AgentAppViewModel.ThreadDeletionUndo.ThreadSnapshot(thread: thread, messages: [newer, older])

        let plan = AgentAppViewModel.ThreadDeletionUndo.restorePlan(for: snapshot)

        XCTAssertEqual(plan.thread.id, threadId, "the parent thread must be the restore anchor")
        XCTAssertEqual(plan.messagesInAppendOrder.map(\.content), ["older", "newer"],
                       "messages must re-append oldest→newest so FK + display order survive")
    }
}
