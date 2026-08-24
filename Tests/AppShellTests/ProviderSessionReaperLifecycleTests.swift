import XCTest
@testable import AppShell
import CoreModel

final class ProviderSessionReaperLifecycleTests: XCTestCase {
    @MainActor
    func test_appContextReapsIdleProviderSessionsAndSkipsRunningThreads() throws {
        let tmp = NSTemporaryDirectory() + "rc2-app-context-reaper-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let old = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 10_000)
        let idle = AgentThread(title: "idle", provider: .codex, model: "gpt-5.5")
        var running = AgentThread(title: "running", provider: .claude, model: "claude-opus-4-7")
        running.status = .running
        try ctx.threadRepo.upsert(idle)
        try ctx.threadRepo.upsert(running)
        try ctx.providerSessionRuntimeRepo.upsert(ProviderSessionRuntime(threadId: idle.id, provider: .codex, status: .completed, resumeCursor: "idle", updatedAt: old))
        try ctx.providerSessionRuntimeRepo.upsert(ProviderSessionRuntime(threadId: running.id, provider: .claude, status: .completed, resumeCursor: "running", updatedAt: old))
        try ctx.providerPendingCallbackRepo.record(threadId: idle.id, request: AssistantPendingRequest(
            id: "approval-1",
            turnId: "turn-1",
            kind: .commandExecution,
            title: "Run tests",
            createdAtMs: 1_000_000
        ))

        let result = try ctx.reapIdleProviderSessions(now: now, idleAge: 60)

        XCTAssertEqual(result.stoppedThreadIds, [idle.id],
                       "app lifecycle reaping must stop stale idle provider sessions")
        XCTAssertEqual(result.skippedActiveThreadIds, [running.id],
                       "app lifecycle reaping must skip threads still marked running")
        XCTAssertEqual(result.staledCallbackThreadIds, [idle.id],
                       "app lifecycle reaping must stale callbacks attached to provider sessions it stops")
        XCTAssertEqual(try ctx.providerSessionRuntimeRepo.get(threadId: idle.id)?.status, .interrupted)
        XCTAssertEqual(try ctx.providerSessionRuntimeRepo.get(threadId: running.id)?.status, .completed)
        XCTAssertEqual(try ctx.providerPendingCallbackRepo.get(threadId: idle.id, requestId: "approval-1", kind: .approval)?.state, .stale)
    }

    @MainActor
    func test_appContextFailsClosedBeforeReapingWhenRunningRoutingIsCorrupt() throws {
        let tmp = NSTemporaryDirectory() + "rc2-app-context-reaper-corrupt-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let old = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 10_000)
        let idle = AgentThread(title: "idle victim", provider: .codex, model: "gpt-5.5")
        let routing = AgentRoutingConfiguration(
            mode: .auto,
            manualSelection: AgentModelSelection(provider: .claude, modelId: "claude-opus-4-7"),
            eligibleProviders: [.claude],
            revision: 2
        )
        var corruptRunning = AgentThread(
            title: "corrupt running",
            provider: .claude,
            model: "claude-opus-4-7",
            routingConfiguration: routing
        )
        corruptRunning.status = .running
        try ctx.threadRepo.upsert(idle)
        try ctx.threadRepo.upsert(corruptRunning)
        try ctx.providerSessionRuntimeRepo.upsert(
            ProviderSessionRuntime(
                threadId: idle.id,
                provider: .codex,
                status: .completed,
                resumeCursor: "idle",
                updatedAt: old
            )
        )
        try ctx.db.execute(
            "UPDATE agent_thread_routing SET configuration_json = '{}' "
                + "WHERE thread_id = '\(corruptRunning.id.value.uuidString)';"
        )

        XCTAssertThrowsError(
            try ctx.reapIdleProviderSessions(now: now, idleAge: 60),
            "corrupt running persistence must abort the lifecycle tick before any session is stopped"
        )
        XCTAssertEqual(
            try ctx.providerSessionRuntimeRepo.get(threadId: idle.id)?.status,
            .completed,
            "a failed active-thread snapshot must leave otherwise reap-eligible sessions untouched"
        )
    }
}
