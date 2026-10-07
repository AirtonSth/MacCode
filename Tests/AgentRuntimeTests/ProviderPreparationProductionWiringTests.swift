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

    func test_cancelAfterSpawnClaim_blocksSendTurn() async throws {
        // WHY: claimSpawn unlocks before sendTurn. Desk stop uses
        // cancelPreparation, not stopRun, so a post-claim Stop must still
        // revoke the pending start and never enter the provider write.
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("prep-after-claim")
        let thread = AgentThread(title: "prep-after-claim", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = CountingRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: runner]
        )
        coordinator.afterSpawnClaimForTesting = { request in
            coordinator.cancelPreparation(threadId: request.threadId)
        }

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                threadId: thread.id,
                provider: .codex,
                model: "fake-model",
                cwd: tmp,
                prompt: "should not spawn after claim"
            ))
            XCTFail("expected cancel after spawn claim")
        } catch is AgentRunAcceptanceError {
            // expected
        } catch {
            XCTAssertTrue(
                "\(error)".localizedCaseInsensitiveContains("cancel")
                    || error is AgentRunAcceptanceError,
                "unexpected error: \(error)"
            )
        }

        XCTAssertEqual(runner.startCount, 0, "sendTurn must not run after Stop won post-claim")
        XCTAssertFalse(coordinator.isPreparingProviderStart(threadId: thread.id))
    }

    func test_stopRunAfterSpawnClaim_blocksSendTurn() async throws {
        // WHY: RPC/iOS Stop is stopRun. It must also win the post-claim gap
        // before sendTurn, not only the pre-claim preparation window.
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("prep-stop-after-claim")
        let thread = AgentThread(title: "prep-stop-after-claim", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = CountingRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: runner]
        )
        coordinator.afterSpawnClaimForTesting = { request in
            coordinator.stopRun(threadId: request.threadId)
        }

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                threadId: thread.id,
                provider: .codex,
                model: "fake-model",
                cwd: tmp,
                prompt: "should not spawn after stopRun"
            ))
            XCTFail("expected stopRun after spawn claim")
        } catch is AgentRunAcceptanceError {
            // expected
        } catch {
            XCTAssertTrue(
                "\(error)".localizedCaseInsensitiveContains("cancel")
                    || error is AgentRunAcceptanceError,
                "unexpected error: \(error)"
            )
        }

        XCTAssertEqual(runner.startCount, 0, "sendTurn must not run after stopRun won post-claim")
    }

    func test_cancelAfterSpawnConfirm_blocksSendTurn() async throws {
        // WHY: confirmSpawnClaimStillLive unlocks before sendTurn. Stop that
        // arrives in that last gap must still prevent the provider write.
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("prep-after-confirm")
        let thread = AgentThread(title: "prep-after-confirm", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = CountingRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: runner]
        )
        coordinator.afterSpawnConfirmForTesting = { request in
            coordinator.cancelPreparation(threadId: request.threadId)
        }

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                threadId: thread.id,
                provider: .codex,
                model: "fake-model",
                cwd: tmp,
                prompt: "should not spawn after confirm"
            ))
            XCTFail("expected cancel after spawn confirm")
        } catch is AgentRunAcceptanceError {
            // expected
        } catch {
            XCTAssertTrue(
                "\(error)".localizedCaseInsensitiveContains("cancel")
                    || error is AgentRunAcceptanceError,
                "unexpected error: \(error)"
            )
        }

        XCTAssertEqual(runner.startCount, 0, "sendTurn must not run after Stop won post-confirm")
    }

    func test_cancelPreparation_invalidatesPermitBeforeWithAcceptance() async throws {
        // WHY: cancelPreparation used to unlock before invalidateAcceptance,
        // so a concurrent withAcceptance could still claim the write.
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("prep-permit-invalidate")
        let thread = AgentThread(title: "prep-permit-invalidate", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = CountingRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: runner]
        )
        coordinator.afterSpawnConfirmForTesting = { request in
            guard let permit = request.acceptancePermit else {
                XCTFail("startRun must carry an acceptance permit")
                return
            }
            coordinator.cancelPreparation(threadId: request.threadId)
            do {
                try permit.withAcceptance { }
                XCTFail("withAcceptance must not claim after Stop recorded")
            } catch {
                XCTAssertTrue(
                    error is AgentRunAcceptanceError,
                    "unexpected error: \(error)"
                )
            }
        }

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                threadId: thread.id,
                provider: .codex,
                model: "fake-model",
                cwd: tmp,
                prompt: "permit already revoked"
            ))
            XCTFail("expected cancel after permit invalidation")
        } catch is AgentRunAcceptanceError {
            // expected
        } catch {
            XCTAssertTrue(
                "\(error)".localizedCaseInsensitiveContains("cancel")
                    || error is AgentRunAcceptanceError,
                "unexpected error: \(error)"
            )
        }

        XCTAssertEqual(runner.startCount, 0)
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
        let reservedRunId = AgentRunID()
        coordinator.reserveProviderStart(threadId: thread.id, runId: reservedRunId)
        coordinator.cancelPreparation(threadId: thread.id)

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                runId: reservedRunId,
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

    /// Overlapping same-thread reservations: late registration of cancelled run A
    /// must not clear run B's reservation (Codex multi-surface race).
    func test_runScopedReserve_lateSiblingCannotClearResend() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("prep-reserve-scope")
        let thread = AgentThread(title: "prep-scope", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = CountingRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: runner]
        )

        let runA = AgentRunID()
        let runB = AgentRunID()
        coordinator.reserveProviderStart(threadId: thread.id, runId: runA)
        coordinator.cancelPreparation(threadId: thread.id) // arms stop, clears A
        coordinator.reserveProviderStart(threadId: thread.id, runId: runB)

        // Late A registration: must not drop B's reservation.
        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                runId: runA,
                threadId: thread.id,
                provider: .codex,
                model: "fake-model",
                cwd: tmp,
                prompt: "late A"
            ))
        } catch {
            // cancelled expected
        }
        XCTAssertEqual(runner.startCount, 0, "cancelled A must not spawn")

        // Stop B while still reserved (no pending yet) must arm again.
        coordinator.cancelPreparation(threadId: thread.id)
        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                runId: runB,
                threadId: thread.id,
                provider: .codex,
                model: "fake-model",
                cwd: tmp,
                prompt: "B after Stop"
            ))
        } catch {
            // cancelled expected
        }
        XCTAssertEqual(
            runner.startCount,
            0,
            "Stop B after late A must still block B spawn (run-scoped reserve)"
        )
    }

    /// One Stop with two preexisting reservations must cancel both runs
    /// (not only the first late registration that consumes pendingThreadStops).
    func test_oneStop_cancelsEveryPreexistingReservation() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("prep-one-stop-two")
        let thread = AgentThread(title: "prep-one-stop", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = CountingRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: runner]
        )

        let runA = AgentRunID()
        let runB = AgentRunID()
        coordinator.reserveProviderStart(threadId: thread.id, runId: runA)
        coordinator.reserveProviderStart(threadId: thread.id, runId: runB)
        // Single Stop while both are reserved — no second Stop for B.
        coordinator.cancelPreparation(threadId: thread.id)

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                runId: runA,
                threadId: thread.id,
                provider: .codex,
                model: "fake-model",
                cwd: tmp,
                prompt: "late A"
            ))
        } catch { /* cancelled */ }
        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                runId: runB,
                threadId: thread.id,
                provider: .codex,
                model: "fake-model",
                cwd: tmp,
                prompt: "late B after A consumed thread stop"
            ))
        } catch { /* cancelled */ }

        XCTAssertEqual(
            runner.startCount,
            0,
            "one Stop must cancel every preexisting reserved run, including the sibling after pendingThreadStops is consumed"
        )
    }

    /// reserve A → Stop → reserve/start C → late-start A: C must spawn, A must not.
    /// (Stale thread-level pendingThreadStops must not cancel a fresh resend.)
    func test_freshResend_notPoisonedByStaleThreadStop_beforeLateCancelledA() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("prep-fresh-resend")
        let thread = AgentThread(title: "prep-fresh", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = CountingRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: runner]
        )

        let runA = AgentRunID()
        let runC = AgentRunID()
        coordinator.reserveProviderStart(threadId: thread.id, runId: runA)
        coordinator.cancelPreparation(threadId: thread.id)
        coordinator.reserveProviderStart(threadId: thread.id, runId: runC)

        let startedC = try await coordinator.startRun(AgentRunRequest(
            runId: runC,
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "fresh resend C"
        ))
        XCTAssertNotNil(startedC)
        XCTAssertEqual(runner.startCount, 1, "fresh resend C must start after Stop of A")

        // Wait for C terminal so exclusive mutation admits late A attempt.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let row = try runRepo.get(id: startedC), row.finishedAt != nil { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                runId: runA,
                threadId: thread.id,
                provider: .codex,
                model: "fake-model",
                cwd: tmp,
                prompt: "late cancelled A"
            ))
        } catch { /* cancelled expected */ }

        XCTAssertEqual(
            runner.startCount,
            1,
            "late cancelled A must not spawn; C alone must have started"
        )
    }

    /// Registered start exits before claim after Stop must not leave a thread
    /// stop that poisons a fresh resend (Codex IMPORTANT).
    func test_registeredStartFailAfterStop_doesNotPoisonResend() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("prep-admit-fail")
        let thread = AgentThread(title: "prep-admit-fail", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = CountingRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: runner]
        )

        let runA = AgentRunID()
        let gate = NSLock()
        var admitCalls = 0
        coordinator.providerAdmissionCheck = { _, _ in
            gate.lock()
            admitCalls += 1
            let n = admitCalls
            gate.unlock()
            if n == 1 {
                // Pause after registration so Stop can arm pendingThreadStops,
                // then fail before claimPreparationSpawnOrCancel.
                coordinator.cancelPreparation(threadId: thread.id)
                throw NSError(
                    domain: "RemoteCode.Test",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "admission refused after Stop"]
                )
            }
        }

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                runId: runA,
                threadId: thread.id,
                provider: .codex,
                model: "fake-model",
                cwd: tmp,
                prompt: "A fails after Stop mid-admit"
            ))
            XCTFail("expected admission failure for A")
        } catch {
            // expected
        }
        XCTAssertEqual(runner.startCount, 0, "A must not spawn")

        let runC = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "fresh C after A failed with stop armed"
        ))
        XCTAssertNotNil(runC)
        XCTAssertEqual(
            runner.startCount,
            1,
            "fresh resend must reach sendTurn after registered-start stop cleanup"
        )
    }

    /// RPC-style stopRun during reservation-only preflight must cancel the run
    /// so a late startRun cannot spawn (preparation await window).
    func test_stopRun_cancelsReservedPreflight_beforePendingRegister() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("prep-rpc-stop")
        let thread = AgentThread(title: "prep-rpc-stop", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = CountingRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: runner]
        )

        let runId = AgentRunID()
        coordinator.reserveProviderStart(threadId: thread.id, runId: runId)
        // No durable pending/active yet — pure preflight reservation.
        coordinator.stopRun(threadId: thread.id)

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                runId: runId,
                threadId: thread.id,
                provider: .codex,
                model: "fake-model",
                cwd: tmp,
                prompt: "must not spawn after RPC stop"
            ))
        } catch { /* cancelled */ }

        XCTAssertEqual(
            runner.startCount,
            0,
            "stopRun during reservation-only preflight must cancel that run"
        )
    }

    /// Cancelled preflight without startRun must not leave residual bookkeeping.
    func test_discardReservation_clearsCancelTokens() {
        let tmp = NSTemporaryDirectory() + "rc2-prep-discard-" + UUID().uuidString
        let (_, db) = try! Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: AgentMessageRepository(db: db),
            threadRepo: AgentThreadRepository(db: db),
            providers: [:]
        )
        let threadId = AgentThreadID()
        let runId = AgentRunID()
        coordinator.reserveProviderStart(threadId: threadId, runId: runId)
        coordinator.cancelPreparation(threadId: threadId)
        XCTAssertGreaterThan(
            coordinator.residualProviderStartBookkeepingCount(threadId: threadId),
            0,
            "cancel while reserved should leave a cancel token until discarded"
        )
        coordinator.discardProviderStartReservation(threadId: threadId, runId: runId)
        XCTAssertEqual(
            coordinator.residualProviderStartBookkeepingCount(threadId: threadId),
            0,
            "abandoned preflight must leave zero residual cancel/reserve entries"
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

        // Preparation-only cancel: no reserve, no pending start.
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
