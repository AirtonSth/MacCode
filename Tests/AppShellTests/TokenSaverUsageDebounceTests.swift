import XCTest
import CoreModel
import AgentRuntime
import Persistence
@testable import AppShell

/// WHY: debouncing must coalesce many per-token record() calls into one pending
/// total and a flush must emit the correct sum and reset the accumulator so no
/// token counts are lost.
@MainActor
final class TokenSaverUsageDebounceTests: XCTestCase {

    // MARK: - accumulator coalesces N events into one pending total

    func test_multipleTokenUsageEventsAccumulateIntoPendingTotal() throws {
        let appSupport = NSTemporaryDirectory() + "RC2UsageDebounce-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        let thread = AgentThread(title: "t", provider: .codex, model: "m")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m",
                           status: .running, startedAt: Date())
        try context.runRepo.upsert(run)

        // Fire 3 token events synchronously; nothing should be written to disk yet
        // (debounce window has not elapsed).
        for tokens in [100, 200, 300] {
            context.coordinator.onAssistantEvent?(
                .tokenUsage(AssistantTokenUsage(inputTokens: tokens, outputTokens: 0, totalTokens: tokens)),
                thread.id,
                run.id
            )
        }

        // Snapshot on disk must still be zero because the debounce timer has not fired.
        let beforeFlush = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
        let codexBefore = beforeFlush.providers.first { $0.provider == .codex }
        XCTAssertEqual(codexBefore?.actualProviderTokens ?? 0, 0,
                       "tokens must not be written to disk before the debounce window fires")
    }

    // MARK: - flush emits correct sum and resets accumulator

    func test_flushEmitsCorrectSumAndResetsAccumulator() throws {
        let appSupport = NSTemporaryDirectory() + "RC2UsageFlush-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        let thread = AgentThread(title: "t", provider: .claude, model: "m")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .claude, model: "m",
                           status: .running, startedAt: Date())
        try context.runRepo.upsert(run)

        // Accumulate tokens across 4 events.
        for tokens in [50, 75, 100, 125] {
            context.coordinator.onAssistantEvent?(
                .tokenUsage(AssistantTokenUsage(inputTokens: tokens, outputTokens: 0, totalTokens: tokens)),
                thread.id,
                run.id
            )
        }

        // Explicit flush must write the accumulated 350 tokens in a single record().
        context.flushPendingTokenSaverUsage(runId: run.id)

        // Give the background writer a moment to finish.
        let deadline = Date().addingTimeInterval(2)
        var snapshot = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
        while snapshot.providers.first(where: { $0.provider == .claude })?.actualProviderTokens == 0,
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            snapshot = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
        }

        let claude = snapshot.providers.first { $0.provider == .claude }
        XCTAssertEqual(claude?.actualProviderTokens, 350,
                       "flush must write the exact sum of all accumulated events; no counts dropped")

        // A second flush with the same runId must be a no-op (accumulator was reset).
        context.flushPendingTokenSaverUsage(runId: run.id)
        Thread.sleep(forTimeInterval: 0.05)
        let afterSecondFlush = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
        let claudeAfter = afterSecondFlush.providers.first { $0.provider == .claude }
        XCTAssertEqual(claudeAfter?.actualProviderTokens, 350,
                       "second flush with empty accumulator must not double-count or corrupt the total")
    }

    // MARK: - global flush drains all runs

    func test_globalFlushDrainsAllPendingRuns() throws {
        let appSupport = NSTemporaryDirectory() + "RC2UsageGlobalFlush-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        let threadA = AgentThread(title: "a", provider: .claude, model: "m")
        let threadB = AgentThread(title: "b", provider: .codex, model: "m")
        try context.threadRepo.upsert(threadA)
        try context.threadRepo.upsert(threadB)
        let runA = AgentRun(threadId: threadA.id, provider: .claude, model: "m",
                            status: .running, startedAt: Date())
        let runB = AgentRun(threadId: threadB.id, provider: .codex, model: "m",
                            status: .running, startedAt: Date())
        try context.runRepo.upsert(runA)
        try context.runRepo.upsert(runB)

        context.coordinator.onAssistantEvent?(
            .tokenUsage(AssistantTokenUsage(inputTokens: 200, outputTokens: 0, totalTokens: 200)),
            threadA.id, runA.id
        )
        context.coordinator.onAssistantEvent?(
            .tokenUsage(AssistantTokenUsage(inputTokens: 400, outputTokens: 0, totalTokens: 400)),
            threadB.id, runB.id
        )

        // Global flush (nil runId) must drain both runs.
        context.flushPendingTokenSaverUsage()

        let deadline = Date().addingTimeInterval(2)
        var snapshot = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
        while (snapshot.providers.first(where: { $0.provider == .claude })?.actualProviderTokens ?? 0) == 0,
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            snapshot = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
        }

        let claude = snapshot.providers.first { $0.provider == .claude }
        let codex = snapshot.providers.first { $0.provider == .codex }
        XCTAssertEqual(claude?.actualProviderTokens, 200,
                       "global flush must write claude run pending total")
        XCTAssertEqual(codex?.actualProviderTokens, 400,
                       "global flush must write codex run pending total")
    }

    // MARK: - run-end flush mirrors onRunFinished behaviour

    func test_runEndFlushPreservesTokensFromDebounceWindow() throws {
        let appSupport = NSTemporaryDirectory() + "RC2UsageRunEnd-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        let thread = AgentThread(title: "t", provider: .codex, model: "m")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m",
                           status: .running, startedAt: Date())
        try context.runRepo.upsert(run)

        // Simulate a burst that would be coalesced by the debounce timer.
        for tokens in [100, 150] {
            context.coordinator.onAssistantEvent?(
                .tokenUsage(AssistantTokenUsage(inputTokens: tokens, outputTokens: 0, totalTokens: tokens)),
                thread.id,
                run.id
            )
        }

        // Force-flush as the run-end path would -- debounce window must not be required.
        context.flushPendingTokenSaverUsage(runId: run.id)

        let deadline = Date().addingTimeInterval(2)
        var snapshot = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
        while (snapshot.providers.first(where: { $0.provider == .codex })?.actualProviderTokens ?? 0) == 0,
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            snapshot = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
        }

        let codex = snapshot.providers.first { $0.provider == .codex }
        XCTAssertEqual(codex?.actualProviderTokens, 250,
                       "run-end flush must not lose tokens that were buffered inside the debounce window")
    }
}
