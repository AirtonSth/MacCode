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

    func test_missingRunner_terminalizesPreparation() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("prep-miss")
        let thread = AgentThread(title: "prep-miss", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [:] // no runner
        )
        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                threadId: thread.id,
                provider: .codex,
                model: "fake-model",
                cwd: tmp,
                prompt: "no runner"
            ))
            XCTFail("expected missing runner failure")
        } catch {
            // expected
        }
        XCTAssertFalse(
            coordinator.isPreparingProviderStart(threadId: thread.id),
            "pre-spawn failure must terminalize preparation"
        )
    }

    /// S5 race: accept A → Stop → accept B → late finish of A must not claim B.
    func test_capturedGeneration_lateFinishCannotClaimResentPrep() {
        var state = ProviderPreparationState()
        state = ProviderPreparationStateMachine.apply(
            state: state,
            event: .accept(draftMessageId: "A", atMs: 1)
        ).state
        let genA = state.generation
        state = ProviderPreparationStateMachine.apply(state: state, event: .stopRequested).state
        state = ProviderPreparationStateMachine.apply(
            state: state,
            event: .accept(draftMessageId: "B", atMs: 2)
        ).state
        let genB = state.generation
        XCTAssertNotEqual(genA, genB)

        // Late completion for A after B accepted — production must use genA.
        let lateA = ProviderPreparationStateMachine.finishAndClaimCapturedGeneration(
            state: state,
            acceptedGeneration: genA
        )
        XCTAssertNil(lateA, "cancelled generation A must never claim after B accepted")

        let claimB = ProviderPreparationStateMachine.finishAndClaimCapturedGeneration(
            state: state,
            acceptedGeneration: genB
        )
        XCTAssertEqual(claimB?.phase, .running)
        XCTAssertEqual(claimB?.generation, genB)
    }

    func test_twoSequentialTurns_acceptNotPoisoned() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("prep-seq")
        let thread = AgentThread(title: "prep-seq", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = CountingRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: runner]
        )
        let first = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "first"
        ))
        // Wait for terminal so exclusive mutation admits the next turn.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let row = try runRepo.get(id: first), row.finishedAt != nil { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let second = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "second"
        ))
        XCTAssertEqual(runner.startCount, 2, "second turn must claimSpawn after terminalize")
        XCTAssertNotEqual(first, second)
    }

    /// Codex IMPORTANT: Stop after surface claim but before startRun registers
    /// pendingProviderStarts must still block spawn. Reservation closes that gap.
    func test_reserveProviderStart_stopInClaimGap_blocksSpawn() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("prep-reserve")
        let thread = AgentThread(title: "prep-reserve", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = CountingRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: runner]
        )

        // Surface-side claim finished; startRun not registered yet.
        coordinator.reserveProviderStart(threadId: thread.id)
        coordinator.cancelPreparation(threadId: thread.id)

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                threadId: thread.id,
                provider: .codex,
                model: "fake-model",
                cwd: tmp,
                prompt: "must not spawn after gap Stop"
            ))
            // startRun may return if it registered then cancelled the handle
            // without throwing; provider must still not start.
        } catch {
            // Cancelled / acceptance rejection also OK.
        }

        XCTAssertEqual(
            runner.startCount,
            0,
            "Stop in claim→startRun gap must prevent provider start"
        )
    }

    /// Surface-only cancel before reserve must not leave pendingThreadStops that
    /// poison an immediate resend.
    func test_cancelWithoutReserve_doesNotPoisonResend() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("prep-no-poison")
        let thread = AgentThread(title: "prep-no-poison", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = CountingRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: runner]
        )

        // Graphify-only cancel: no reserve, no pending start.
        coordinator.cancelPreparation(threadId: thread.id)

        let runId = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "resend after surface-only cancel"
        ))
        XCTAssertEqual(runner.startCount, 1, "surface-only cancel must not poison next send")
        XCTAssertNotNil(runId)
    }
}
