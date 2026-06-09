// TokenSaverDistillSupervisorTests.swift
//
// Covers P1: Token Saver sidecar health + supervised restart, and the
// `.starting` deadlock family.
//
// These tests exercise the PURE state-transition logic extracted into
// `TokenSaverDistillSupervisor`. The controller owns the process / timer side
// effects; the supervisor owns the decisions, so the deadlock-recovery and
// restart-backoff rules can be verified without launching a real Process
// (Rule 8 — every test pins WHY the transition matters, not just that some
// value comes back).

import DistillCore
import Foundation
import Testing
@testable import AppShell

@Suite("TokenSaverDistillSupervisor — health, restart, deadlock recovery")
struct TokenSaverDistillSupervisorTests {

    // `DistillServiceReadyEvent` has no public memberwise init across module
    // boundaries, so decode a fixture from its JSON wire format instead.
    private func ready() -> DistillServiceReadyEvent {
        let json = """
        {
          "event": "ready",
          "base_url": "http://127.0.0.1:55000",
          "host": "127.0.0.1",
          "port": 55000,
          "pid": 4242,
          "protocol": 1,
          "runtime": "mlx",
          "model_id": "test-model",
          "max_concurrent_requests": 8,
          "max_queue_depth": 64
        }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(DistillServiceReadyEvent.self, from: json)
    }

    // MARK: - Unexpected exit -> downgrade + restart scheduled

    /// WHY: a sidecar that crashes while `.running` must NOT silently leave the
    /// status at `.running` (fail-open). It has to downgrade so callers stop
    /// trusting a dead service, AND schedule a restart so the service recovers.
    @Test("crash while running -> downgraded out of .running + restart scheduled")
    func crashWhileRunningDowngradesAndRestarts() {
        let decision = TokenSaverDistillSupervisor.decide(
            status: .running(ready()),
            event: .processExited(wasUserStop: false),
            restartAttempts: 0
        )
        #expect(decision.shouldRestart)
        if case .running = decision.nextStatus {
            Issue.record("status stayed .running after crash — silent fail-open")
        }
        if case .failed = decision.nextStatus {
            // expected
        } else {
            Issue.record("expected .failed after crash, got \(decision.nextStatus)")
        }
    }

    /// WHY: a crash during startup (still `.starting`) must also downgrade and
    /// schedule a restart — otherwise the consumer poll loop spins on `.starting`.
    @Test("crash while starting -> downgraded + restart scheduled")
    func crashWhileStartingDowngradesAndRestarts() {
        let decision = TokenSaverDistillSupervisor.decide(
            status: .starting,
            event: .processExited(wasUserStop: false),
            restartAttempts: 0
        )
        #expect(decision.shouldRestart)
        #expect(decision.nextStatus != .starting)
    }

    // MARK: - User stop / eligibility gating must NOT auto-restart

    /// WHY: when `stop()` terminates the process intentionally, the termination
    /// handler must not resurrect it. Auto-restart here would fight the user /
    /// eligibility gate and relaunch a sidecar the user just disabled.
    @Test("user-initiated exit -> no restart, resets to idle")
    func userExitDoesNotRestart() {
        let decision = TokenSaverDistillSupervisor.decide(
            status: .running(ready()),
            event: .processExited(wasUserStop: true),
            restartAttempts: 0
        )
        #expect(!decision.shouldRestart)
        #expect(decision.nextStatus == .notStarted)
    }

    /// WHY: if eligibility already moved us to `.blocked` (e.g. subscription
    /// lapsed) a process exit must stay blocked, not restart.
    @Test("exit while blocked -> stays blocked, no restart")
    func exitWhileBlockedStaysBlocked() {
        let decision = TokenSaverDistillSupervisor.decide(
            status: .blocked("subscription required"),
            event: .processExited(wasUserStop: false),
            restartAttempts: 0
        )
        #expect(!decision.shouldRestart)
        #expect(decision.nextStatus == .blocked("subscription required"))
    }

    // MARK: - Dead-process startup wait is CAPPED (the .starting deadlock fix)

    /// WHY: this is the core deadlock. Before the fix, EOF on the ready stream
    /// while the process was DEAD left status at `.starting`, so the consumer
    /// poll loop (300 polls x 200ms = 60s) span the whole window every turn.
    /// The supervisor must transition OUT of `.starting` so the poll loop's
    /// `.failed` break fires immediately.
    @Test("EOF while dead during startup -> leaves .starting (caps poll wait)")
    func startupEOFWhileDeadCapsWait() {
        let decision = TokenSaverDistillSupervisor.decide(
            status: .starting,
            event: .startupEOFWhileDead,
            restartAttempts: 0
        )
        #expect(decision.nextStatus != .starting)
        if case .failed = decision.nextStatus {
            // expected — poll loop breaks on .failed
        } else {
            Issue.record("expected .failed to cap the startup wait, got \(decision.nextStatus)")
        }
        #expect(decision.shouldRestart)
    }

    /// WHY: a stray EOF event that arrives when we are NOT `.starting` (e.g.
    /// already `.running`) must be a no-op — it must not clobber a healthy
    /// running status or trigger a spurious restart.
    @Test("EOF-while-dead ignored when not .starting")
    func startupEOFIgnoredWhenNotStarting() {
        let running = TokenSaverDistillServiceStatus.running(ready())
        let decision = TokenSaverDistillSupervisor.decide(
            status: running,
            event: .startupEOFWhileDead,
            restartAttempts: 0
        )
        #expect(decision.nextStatus == running)
        #expect(!decision.shouldRestart)
    }

    // MARK: - stop() resets to a clean idle status FROM EVERY STATE

    /// WHY: the original `stop()` only reset from `.running`. A stop from
    /// `.starting` or `.failed` left the stale status behind, so a stuck
    /// `.starting` survived eligibility changes. The supervisor must return
    /// `.notStarted` for a stopRequested regardless of the source state.
    @Test("stopRequested from any state -> .notStarted, no restart")
    func stopResetsFromEveryState() {
        let states: [TokenSaverDistillServiceStatus] = [
            .notStarted,
            .blocked("x"),
            .starting,
            .running(ready()),
            .failed("boom")
        ]
        for state in states {
            let decision = TokenSaverDistillSupervisor.decide(
                status: state,
                event: .stopRequested,
                restartAttempts: 3
            )
            #expect(decision.nextStatus == .notStarted, "stop did not reset from \(state)")
            #expect(!decision.shouldRestart, "stop must never restart (from \(state))")
        }
    }

    // MARK: - Restart attempts are CAPPED (no infinite crash loop)

    /// WHY: a sidecar that crashes on every launch must eventually surface a
    /// terminal `.failed` instead of restarting forever. Past the cap, the
    /// supervisor must stop scheduling restarts.
    @Test("restart cap reached -> terminal .failed, no further restart")
    func restartCapStopsRestarting() {
        let decision = TokenSaverDistillSupervisor.decide(
            status: .running(ready()),
            event: .processExited(wasUserStop: false),
            restartAttempts: TokenSaverDistillSupervisor.maxRestartAttempts
        )
        #expect(!decision.shouldRestart)
        if case .failed = decision.nextStatus {
            // expected terminal state
        } else {
            Issue.record("expected terminal .failed at cap, got \(decision.nextStatus)")
        }
    }

    @Test("startup EOF at restart cap -> terminal .failed, no restart")
    func startupEOFCapStopsRestarting() {
        let decision = TokenSaverDistillSupervisor.decide(
            status: .starting,
            event: .startupEOFWhileDead,
            restartAttempts: TokenSaverDistillSupervisor.maxRestartAttempts
        )
        #expect(!decision.shouldRestart)
        if case .failed = decision.nextStatus {} else {
            Issue.record("expected terminal .failed at cap, got \(decision.nextStatus)")
        }
    }

    // MARK: - Exponential, capped backoff

    /// WHY: restarts must back off so a crash-looping sidecar does not hammer
    /// relaunches. The schedule must grow exponentially and clamp at the max so
    /// the delay never runs away.
    @Test("backoff is exponential and capped")
    func backoffExponentialAndCapped() {
        let b0 = TokenSaverDistillSupervisor.backoffSeconds(forAttempt: 0)
        let b1 = TokenSaverDistillSupervisor.backoffSeconds(forAttempt: 1)
        let b2 = TokenSaverDistillSupervisor.backoffSeconds(forAttempt: 2)
        #expect(b0 == TokenSaverDistillSupervisor.baseBackoffSeconds)
        #expect(b1 > b0)
        #expect(b2 > b1)
        // Never exceeds the cap, even for a large attempt count.
        let big = TokenSaverDistillSupervisor.backoffSeconds(forAttempt: 100)
        #expect(big == TokenSaverDistillSupervisor.maxBackoffSeconds)
    }
}
