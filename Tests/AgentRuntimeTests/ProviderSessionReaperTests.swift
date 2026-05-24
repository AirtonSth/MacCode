import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

final class ProviderSessionReaperTests: XCTestCase {
    func test_reaperStopsOnlyIdleRecoverableSessionsAndSkipsActiveThreads() throws {
        let tmp = NSTemporaryDirectory() + "rc2-provider-reaper-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let callbackRepo = ProviderPendingCallbackRepository(db: db)
        let old = Date(timeIntervalSince1970: 100)
        let cutoff = Date(timeIntervalSince1970: 200)

        let idle = AgentThread(title: "idle", provider: .codex, model: "gpt-5.5")
        let active = AgentThread(title: "active", provider: .claude, model: "claude-opus-4-7")
        let running = AgentThread(title: "running", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(idle)
        try threadRepo.upsert(active)
        try threadRepo.upsert(running)
        try sessionRepo.upsert(ProviderSessionRuntime(threadId: idle.id, provider: .codex, status: .completed, resumeCursor: "idle-session", updatedAt: old))
        try sessionRepo.upsert(ProviderSessionRuntime(threadId: active.id, provider: .claude, status: .completed, resumeCursor: "active-session", updatedAt: old))
        try sessionRepo.upsert(ProviderSessionRuntime(threadId: running.id, provider: .codex, status: .running, resumeCursor: "running-session", updatedAt: old))
        try callbackRepo.record(threadId: idle.id, request: AssistantPendingRequest(
            id: "approval-1",
            turnId: "turn-1",
            kind: .commandExecution,
            title: "Run tests",
            createdAtMs: 100_000
        ))
        try callbackRepo.record(threadId: active.id, userInput: AssistantUserInputRequest(
            id: "question-1",
            turnId: "turn-1",
            prompt: "Continue?",
            createdAtMs: 100_000
        ))

        let reaper = ProviderSessionReaper(sessionRepo: sessionRepo, pendingCallbackRepo: callbackRepo) { [active.id, running.id] }
        let result = try reaper.reapIdleSessions(olderThan: cutoff)

        XCTAssertEqual(result.stoppedThreadIds, [idle.id],
                       "reaper must stop stale idle sessions so old provider runtimes do not pile up over long app sessions")
        XCTAssertEqual(result.skippedActiveThreadIds, [active.id],
                       "reaper must not stop a recoverable session while RemoteCode still considers the thread active")
        XCTAssertEqual(result.staledCallbackThreadIds, [idle.id],
                       "when a provider session is reaped, live pending callbacks for that session must become stale immediately instead of leaving dead approval buttons")
        XCTAssertEqual(try sessionRepo.get(threadId: idle.id)?.status, .interrupted)
        XCTAssertEqual(try sessionRepo.get(threadId: active.id)?.status, .completed)
        XCTAssertEqual(try sessionRepo.get(threadId: running.id)?.status, .running,
                       "running sessions are not idle candidates even if older than the cutoff")
        XCTAssertEqual(try callbackRepo.get(threadId: idle.id, requestId: "approval-1", kind: .approval)?.state, .stale)
        XCTAssertEqual(try callbackRepo.get(threadId: active.id, requestId: "question-1", kind: .userInput)?.state, .pending,
                       "callbacks for active threads must remain actionable")
    }
}
