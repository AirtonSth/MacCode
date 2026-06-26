import XCTest
@testable import Surfaces
import CoreModel
import Persistence
import AgentRuntime

/// Regression guards for the agent-app "new tab clones the other tab" bug
/// (Bug A) and the per-surface thread-binding contract introduced to fix it.
///
/// Contract proven here (all at the view-model layer, where the bug lived):
///  - A new agent tab opens thread-free; it does NOT auto-adopt threads.first.
///  - reloadThreads() is a pure data reload and never mutates the selection.
///  - A surface restored/created with an explicit initialThreadId binds to
///    exactly that thread (not threads.first).
///  - Selecting a thread fires onSelectedThreadChanged so the host can persist
///    the per-surface binding for app-restart restore.
///  - Two surfaces in one workspace keep independent selections.
///  - A bound thread deleted elsewhere reconciles to the fresh state (no
///    dangling selection).
@MainActor
final class AgentSurfaceThreadBindingTests: XCTestCase {

    private struct Harness {
        let vmFactory: (AgentThreadID?) -> AgentAppViewModel
        let threadRepo: AgentThreadRepository
        let messageRepoForTests: AgentMessageRepository
        let workspaceID: WorkspaceID
    }

    private func makeHarness() throws -> Harness {
        let tmp = NSTemporaryDirectory() + "rc2-bind-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo  = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo     = AgentRunRepository(db: db)
        let workspaceID = WorkspaceID()
        let coord = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [
                .codex: FakeProviderRunner(provider: .codex),
                .claude: FakeProviderRunner(provider: .claude)
            ]
        )
        let factory: (AgentThreadID?) -> AgentAppViewModel = { initial in
            AgentAppViewModel(
                workspaceID: workspaceID, cwd: tmp,
                coordinator: coord, threadRepo: threadRepo, messageRepo: messageRepo,
                initialThreadId: initial
            )
        }
        return Harness(vmFactory: factory, threadRepo: threadRepo, messageRepoForTests: messageRepo, workspaceID: workspaceID)
    }

    @discardableResult
    private func seedThread(_ h: Harness, title: String) throws -> AgentThread {
        let t = AgentThread(workspaceId: h.workspaceID, title: title, provider: .codex, model: "fake-model")
        try h.threadRepo.upsert(t)
        return t
    }

    // MARK: Bug A — a new tab must not adopt the workspace's first thread

    func test_newSurface_inWorkspaceWithThreads_opensThreadFree() throws {
        let h = try makeHarness()
        try seedThread(h, title: "Existing A")
        try seedThread(h, title: "Existing B")

        let vm = h.vmFactory(nil) // a brand-new tab passes no initial thread

        XCTAssertNil(vm.selectedThreadId,
            "A new agent tab must open thread-free, not adopt threads.first (Bug A).")
        XCTAssertEqual(vm.threads.count, 2, "The rail still lists the workspace's threads.")
    }

    func test_reloadThreads_isPure_neverMutatesSelection() throws {
        let h = try makeHarness()
        try seedThread(h, title: "Existing A")
        let vm = h.vmFactory(nil)
        XCTAssertNil(vm.selectedThreadId)

        vm.reloadThreads()
        vm.reloadThreads()

        XCTAssertNil(vm.selectedThreadId,
            "reloadThreads() must be a pure data reload and never auto-select a thread.")
    }

    // MARK: Per-surface binding (restore / explicit)

    func test_initialThreadId_bindsThatExactThread_notFirst() throws {
        let h = try makeHarness()
        let first = try seedThread(h, title: "First")
        let second = try seedThread(h, title: "Second")

        let vm = h.vmFactory(second.id)

        XCTAssertEqual(vm.selectedThreadId, second.id,
            "A surface restored with initialThreadId binds to exactly that thread.")
        XCTAssertNotEqual(vm.selectedThreadId, first.id)
    }

    func test_initialThreadId_missingThread_staysFresh() throws {
        let h = try makeHarness()
        try seedThread(h, title: "Existing")
        let ghost = AgentThreadID()

        let vm = h.vmFactory(ghost) // bound id no longer exists

        XCTAssertNil(vm.selectedThreadId,
            "A binding to a non-existent thread must not fall back to threads.first.")
    }

    // MARK: Persistence callback

    func test_selectThread_firesBindingCallback() throws {
        let h = try makeHarness()
        let t = try seedThread(h, title: "T")
        let vm = h.vmFactory(nil)

        var observed: [AgentThreadID?] = []
        vm.onSelectedThreadChanged = { observed.append($0) }

        vm.selectThread(t.id)

        XCTAssertEqual(observed, [t.id],
            "Selecting a thread must notify the host so it can persist the per-surface binding.")
    }

    func test_createThread_bindsNewDistinctThread() throws {
        let h = try makeHarness()
        let existing = try seedThread(h, title: "Existing")
        let vm = h.vmFactory(nil)
        XCTAssertNil(vm.selectedThreadId)

        vm.createThread(title: "New thread")

        XCTAssertNotNil(vm.selectedThreadId)
        XCTAssertNotEqual(vm.selectedThreadId, existing.id,
            "Starting a new thread binds the surface to a fresh, distinct thread.")
    }

    // MARK: Independent selection across surfaces

    func test_twoSurfaces_keepIndependentSelection() throws {
        let h = try makeHarness()
        let a = try seedThread(h, title: "A")
        let b = try seedThread(h, title: "B")

        let vm1 = h.vmFactory(nil)
        let vm2 = h.vmFactory(nil)

        vm1.selectThread(a.id)
        vm2.selectThread(b.id)

        XCTAssertEqual(vm1.selectedThreadId, a.id)
        XCTAssertEqual(vm2.selectedThreadId, b.id,
            "Two agent surfaces in one workspace must own independent selected threads.")
    }

    // MARK: PERSISTENCE-DATA-002 — title repair must not bump updatedAt

    func test_placeholderTitleRepair_preservesUpdatedAt() throws {
        let h = try makeHarness()
        // A placeholder-titled thread with a deliberately OLD activity time.
        let old = Date(timeIntervalSince1970: 1_000_000)
        var t = AgentThread(workspaceId: h.workspaceID, title: AgentThreadTitle.defaultTitle,
                            provider: .codex, model: "fake-model")
        t.updatedAt = old
        try h.threadRepo.upsert(t)
        try h.messageRepoForTests.append(AgentMessage(threadId: t.id, role: .user, content: "Implement the parser"))

        let vm = h.vmFactory(nil)
        vm.reloadThreads() // runs repairPlaceholderThreadTitles

        let repaired = try XCTUnwrap(try h.threadRepo.get(id: t.id))
        XCTAssertFalse(AgentThreadTitle.isPlaceholder(repaired.title),
            "the placeholder title is repaired from the first user message")
        XCTAssertEqual(repaired.updatedAt.timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 0.001,
            "a cosmetic title repair must NOT bump updatedAt (it reorders the rail otherwise).")
    }

    // MARK: Deletion recovery

    func test_boundThreadDeletedElsewhere_reconcilesToFresh() throws {
        let h = try makeHarness()
        let t = try seedThread(h, title: "Doomed")
        let vm = h.vmFactory(t.id)
        XCTAssertEqual(vm.selectedThreadId, t.id)

        var observed: [AgentThreadID?] = []
        vm.onSelectedThreadChanged = { observed.append($0) }

        try h.threadRepo.delete(id: t.id)
        vm.reloadThreads()

        XCTAssertNil(vm.selectedThreadId,
            "A bound thread deleted from another client must reconcile to the fresh state.")
        XCTAssertEqual(observed, [nil], "The cleared binding is persisted (nil).")
    }
}
