import XCTest
import CoreModel
@testable import Surfaces
@testable import Persistence
@testable import AgentRuntime

/// Regression: completed agent runs must not fan out host lifecycle callbacks
/// (sidebar MRU promote / busy chrome) to Agent Apps in other workspaces.
@MainActor
final class AgentRunFinishWorkspaceGatingTests: XCTestCase {
    func test_shouldHandleRunFinish_requiresMatchingWorkspace() {
        let a = WorkspaceID()
        let b = WorkspaceID()
        XCTAssertTrue(
            AgentAppViewModel.shouldHandleRunFinishForWorkspace(
                threadWorkspace: a,
                surfaceWorkspace: a
            )
        )
        XCTAssertFalse(
            AgentAppViewModel.shouldHandleRunFinishForWorkspace(
                threadWorkspace: b,
                surfaceWorkspace: a
            ),
            "a finish in workspace B must not drive Agent App A host callbacks"
        )
        XCTAssertFalse(
            AgentAppViewModel.shouldHandleRunFinishForWorkspace(
                threadWorkspace: nil,
                surfaceWorkspace: a
            ),
            "unknown thread workspace must fail closed (no cross-workspace promote)"
        )
    }

    func test_shouldNotifyHostOfRunLifecycle_completedOnlyForOnRunCompleted() {
        let ws = WorkspaceID()
        XCTAssertTrue(
            AgentAppViewModel.shouldNotifyHostOfRunLifecycle(
                threadWorkspace: ws,
                surfaceWorkspace: ws,
                status: .completed,
                notifyOnCompletedOnly: true
            )
        )
        XCTAssertFalse(
            AgentAppViewModel.shouldNotifyHostOfRunLifecycle(
                threadWorkspace: ws,
                surfaceWorkspace: ws,
                status: .cancelled,
                notifyOnCompletedOnly: true
            ),
            "onRunCompleted (MRU promote) is completion-only"
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldNotifyHostOfRunLifecycle(
                threadWorkspace: ws,
                surfaceWorkspace: ws,
                status: .cancelled,
                notifyOnCompletedOnly: false
            ),
            "onRunStateChange may refresh busy chrome for any terminal status"
        )
        XCTAssertFalse(
            AgentAppViewModel.shouldNotifyHostOfRunLifecycle(
                threadWorkspace: WorkspaceID(),
                surfaceWorkspace: ws,
                status: .completed,
                notifyOnCompletedOnly: true
            )
        )
    }

    func test_didFinish_doesNotFireOnRunCompletedForOtherWorkspace_becauseMRUMustNotFanOut() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-finish-mru-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coord = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [
                .codex: FakeProviderRunner(provider: .codex),
                .claude: FakeProviderRunner(provider: .claude)
            ]
        )
        let wsA = WorkspaceID()
        let wsB = WorkspaceID()
        let vmA = AgentAppViewModel(
            workspaceID: wsA,
            cwd: tmp,
            coordinator: coord,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            draftRepo: AgentThreadDraftRepository(db: db),
            attachmentStore: AgentAttachmentStore(
                root: URL(fileURLWithPath: tmp).appendingPathComponent("agent-attachments")
            ),
            promptHistoryStore: PromptHistoryStore(db: db)
        )
        let vmB = AgentAppViewModel(
            workspaceID: wsB,
            cwd: tmp,
            coordinator: coord,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            draftRepo: AgentThreadDraftRepository(db: db),
            attachmentStore: AgentAttachmentStore(
                root: URL(fileURLWithPath: tmp).appendingPathComponent("agent-attachments-b")
            ),
            promptHistoryStore: PromptHistoryStore(db: db)
        )
        coord.addObserver(vmA)
        coord.addObserver(vmB)

        vmA.createThread(title: "A")
        let threadA = try XCTUnwrap(vmA.selectedThreadId)
        var completedA = 0
        var completedB = 0
        var stateA = 0
        var stateB = 0
        vmA.onRunCompleted = { completedA += 1 }
        vmB.onRunCompleted = { completedB += 1 }
        vmA.onRunStateChange = { stateA += 1 }
        vmB.onRunStateChange = { stateB += 1 }

        // Fan-out the same finish to both surfaces (coordinator observer model).
        vmA.runCoordinator(
            coord,
            didFinish: AgentRunID(),
            threadId: threadA,
            status: .completed,
            finalMessage: "done",
            providerThreadId: nil
        )
        vmB.runCoordinator(
            coord,
            didFinish: AgentRunID(),
            threadId: threadA,
            status: .completed,
            finalMessage: "done",
            providerThreadId: nil
        )
        // didFinish hops to MainActor; wait briefly for both tasks.
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(completedA, 1, "owning workspace must promote exactly once")
        XCTAssertEqual(completedB, 0, "foreign workspace must not promote on this finish")
        XCTAssertGreaterThanOrEqual(stateA, 1, "owning workspace may refresh busy chrome")
        XCTAssertEqual(stateB, 0, "foreign workspace must not refresh busy chrome for this finish")
    }
}
