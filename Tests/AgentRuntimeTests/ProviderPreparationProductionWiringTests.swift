import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// S5 production wiring: ProviderPreparationStateMachine is owned by
/// AgentRunCoordinator accept→spawn, and Stop/cancelPreparation revokes
/// claimSpawn so sendTurn never starts.
final class ProviderPreparationProductionWiringTests: XCTestCase {
    private final class CountingRunner: AgentProviderRunner, @unchecked Sendable {
        let provider: AgentProvider = .codex
        private let lock = NSLock()
        private var _startCount = 0
        var startCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _startCount
        }

        func listModels() async -> [AgentModelDescriptor] { [] }
        func startRun(
            _ request: AgentRunRequest,
            onEvent: @escaping @Sendable (AgentRunEvent) -> Void
        ) async throws -> AgentRunHandle {
            lock.lock(); _startCount += 1; lock.unlock()
            let threadId = request.providerThreadId ?? UUID().uuidString
            onEvent(.status(.running))
            onEvent(.finished(.completed, finalMessage: "ok", providerThreadId: threadId))
            return AgentRunHandle(runId: request.runId, process: nil) {}
        }
    }

    private func makeRepos(_ label: String) throws -> (
        AgentThreadRepository,
        AgentMessageRepository,
        AgentRunRepository,
        ProviderSessionRuntimeRepository,
        String
    ) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (
            AgentThreadRepository(db: db),
            AgentMessageRepository(db: db),
            AgentRunRepository(db: db),
            ProviderSessionRuntimeRepository(db: db),
            tmp
        )
    }

    func test_cancelDuringOnRunPrepared_blocksSendTurn() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("prep-cancel")
        let thread = AgentThread(title: "prep", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = CountingRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: runner]
        )
        // Production seam: after durable prep, before claimSpawn/sendTurn.
        coordinator.onRunPrepared = { request, _ in
            coordinator.cancelPreparation(threadId: request.threadId)
        }

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                threadId: thread.id,
                provider: .codex,
                model: "fake-model",
                cwd: tmp,
                prompt: "should not spawn"
            ))
            XCTFail("expected cancel before provider spawn")
        } catch is AgentRunAcceptanceError {
            // expected
        } catch {
            // Some paths wrap; still require no provider write.
            XCTAssertTrue(
                "\(error)".localizedCaseInsensitiveContains("cancel")
                    || error is AgentRunAcceptanceError,
                "unexpected error: \(error)"
            )
        }

        XCTAssertEqual(runner.startCount, 0, "sendTurn must not run after Stop revoked spawn permit")
        XCTAssertFalse(coordinator.isPreparingProviderStart(threadId: thread.id))
        let phase = coordinator.preparationPhase(threadId: thread.id)
        XCTAssertTrue(
            phase == .terminal || phase == .stopping || phase == nil || phase == .accepting,
            "prep phase after cancel: \(String(describing: phase))"
        )
    }

    func test_happyPath_claimSpawnAllowsProviderStart() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("prep-happy")
        let thread = AgentThread(title: "prep-ok", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = CountingRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: runner]
        )

        let runId = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "spawn ok"
        ))
        XCTAssertEqual(runner.startCount, 1)
        XCTAssertNotNil(runId)
        // After successful claim, phase is running (or terminal if already finished).
        let phase = coordinator.preparationPhase(threadId: thread.id)
        XCTAssertTrue(
            phase == .running || phase == .terminal || phase == .stopping,
            "expected live/terminal prep after spawn, got \(String(describing: phase))"
        )
    }

    func test_cancelPreparation_publicAPI_revokesPendingSpawn() {
        let threadId = AgentThreadID()
        // Lightweight coordinator with empty providers is enough for cancel API.
        let tmp = NSTemporaryDirectory() + "rc2-prep-api-" + UUID().uuidString
        let (_, db) = try! Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: AgentMessageRepository(db: db),
            threadRepo: AgentThreadRepository(db: db),
            providers: [:]
        )
        coordinator.cancelPreparation(threadId: threadId)
        // No accept yet → stop is noop or terminal; isPreparing must be false.
        XCTAssertFalse(coordinator.isPreparingProviderStart(threadId: threadId))
    }
}
