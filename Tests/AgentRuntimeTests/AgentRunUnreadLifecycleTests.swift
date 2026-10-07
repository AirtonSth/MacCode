import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// The coordinator owns terminal run truth even when no Agent App surface exists.
/// Pet attention and every other host consumer therefore read one persisted
/// `AgentThread.hasUnread` value instead of depending on a view-model callback.
final class AgentRunUnreadLifecycleTests: XCTestCase {
    private func makeRepos(_ label: String) throws -> (
        AgentThreadRepository,
        AgentMessageRepository,
        AgentRunRepository,
        String
    ) {
        let support = NSTemporaryDirectory() + "rc2-unread-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: support).run()
        return (
            AgentThreadRepository(db: db),
            AgentMessageRepository(db: db),
            AgentRunRepository(db: db),
            support
        )
    }

    private func waitForThread(
        _ id: AgentThreadID,
        in repo: AgentThreadRepository,
        status: AgentRunStatus,
        timeout: TimeInterval = 3
    ) async throws -> AgentThread {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let thread = try repo.get(id: id), thread.status == status {
                return thread
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let thread = try XCTUnwrap(repo.get(id: id), "timed out waiting for thread status \(status.rawValue)")
        XCTAssertEqual(thread.status, status, "timed out waiting for thread status \(status.rawValue)")
        return thread
    }

    func test_terminalOutcomesPersistUnreadWithoutAgentAppObserver() async throws {
        let cases: [(status: AgentRunStatus, expectedUnread: Bool)] = [
            (.completed, true),
            (.failed, true),
            (.interrupted, true),
            (.cancelled, false),
        ]

        for item in cases {
            let (threadRepo, messageRepo, runRepo, support) = try makeRepos(item.status.rawValue)
            let thread = AgentThread(title: item.status.rawValue, provider: .codex, model: "fake-model")
            try threadRepo.upsert(thread)
            let coordinator = AgentRunCoordinator(
                runRepo: runRepo,
                messageRepo: messageRepo,
                threadRepo: threadRepo,
                providers: [.codex: TerminalOutcomeRunner(status: item.status)]
            )

            _ = try await coordinator.startRun(AgentRunRequest(
                threadId: thread.id,
                provider: .codex,
                model: "fake-model",
                cwd: support,
                prompt: "finish \(item.status.rawValue)"
            ))

            let persisted = try await waitForThread(thread.id, in: threadRepo, status: item.status)
            XCTAssertEqual(
                persisted.hasUnread,
                item.expectedUnread,
                "\(item.status.rawValue) must persist the host-owned unread policy even when no Agent App view model is observing the run"
            )
        }
    }

    func test_startRunClearsPreviousUnreadBeforeNewOutcome() async throws {
        let (threadRepo, messageRepo, runRepo, support) = try makeRepos("start-clears")
        var thread = AgentThread(title: "run again", provider: .codex, model: "fake-model")
        thread.hasUnread = true
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: HeldOpenRunner()]
        )

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: support,
            prompt: "run again"
        ))

        XCTAssertFalse(
            try XCTUnwrap(threadRepo.get(id: thread.id)).hasUnread,
            "starting a new run must clear the prior outcome before the next terminal result arrives"
        )

        coordinator.stopRun(threadId: thread.id)
        let cancelled = try await waitForThread(thread.id, in: threadRepo, status: .cancelled)
        XCTAssertFalse(cancelled.hasUnread, "a user cancellation must not recreate attention after start cleared it")
    }

    func test_startFailurePersistsUnreadWithoutAgentAppObserver() async throws {
        let (threadRepo, messageRepo, runRepo, support) = try makeRepos("start-failure")
        let thread = AgentThread(title: "cannot start", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: StartFailureRunner()]
        )

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                threadId: thread.id,
                provider: .codex,
                model: "fake-model",
                cwd: support,
                prompt: "fail to start"
            ))
            XCTFail("the throwing provider must fail the run start")
        } catch {
            // Expected. Persisted terminal truth is asserted below.
        }

        let failed = try XCTUnwrap(threadRepo.get(id: thread.id))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(
            failed.hasUnread,
            "a startup failure is actionable terminal work and must remain visible without an Agent App surface"
        )
    }

    func test_launchReconciliationPersistsInterruptedRunUnread() throws {
        let (threadRepo, messageRepo, runRepo, _) = try makeRepos("launch-interrupted")
        var thread = AgentThread(title: "lost process", provider: .codex, model: "fake-model")
        thread.status = .running
        try threadRepo.upsert(thread)
        try runRepo.upsert(AgentRun(
            id: AgentRunID(),
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .running
        ))
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [:]
        )

        try coordinator.reconcileOnLaunch()

        let interrupted = try XCTUnwrap(threadRepo.get(id: thread.id))
        XCTAssertEqual(interrupted.status, .interrupted)
        XCTAssertTrue(
            interrupted.hasUnread,
            "a run interrupted by process loss must appear in persistent attention after relaunch"
        )
    }
}

private final class TerminalOutcomeRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let status: AgentRunStatus

    init(status: AgentRunStatus) {
        self.status = status
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        let status = status
        // A `.completed` run with no assistant output is reclassified as failed
        // by ProviderStderrClassifier, so a genuine success carries a final reply.
        let finalMessage: String? = status == .completed ? "done" : nil
        Task.detached {
            try? await Task.sleep(nanoseconds: 20_000_000)
            onEvent(.finished(status, finalMessage: finalMessage, providerThreadId: "provider-thread"))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}

private final class HeldOpenRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        AgentRunHandle(runId: request.runId, process: nil) {
            onEvent(.finished(.cancelled, finalMessage: nil, providerThreadId: "provider-thread"))
        }
    }
}

private struct StartFailure: Error {}

private final class StartFailureRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        throw StartFailure()
    }
}
