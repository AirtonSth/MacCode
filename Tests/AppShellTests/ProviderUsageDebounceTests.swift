import XCTest
import CoreModel
import AgentRuntime
import Persistence
@testable import AppShell

/// WHY: providers do not share one accounting contract. Claude can publish
/// independent request charges before a final cumulative result; Codex/Grok
/// publish cumulative snapshots. Debouncing must preserve both without loss,
/// duplication, or advancing a baseline before a write succeeds.
@MainActor
final class ProviderUsageDebounceTests: XCTestCase {

    // MARK: - accumulator coalesces cumulative snapshots

    func test_multipleTokenUsageSnapshotsKeepLatestCumulativeTotal() throws {
        let appSupport = NSTemporaryDirectory() + "RC2UsageDebounce-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)

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

        let thread = AgentThread(title: "t", provider: .codex, model: "m")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m",
                           status: .running, startedAt: Date())
        try context.runRepo.upsert(run)

        // Provider snapshots are cumulative for the run, not independent deltas.
        for tokens in [50, 75, 100, 125] {
            context.coordinator.onAssistantEvent?(
                .tokenUsage(AssistantTokenUsage(inputTokens: tokens, outputTokens: 0, totalTokens: tokens)),
                thread.id,
                run.id
            )
        }

        // Explicit flush must write the latest 125-token snapshot once.
        context.flushPendingProviderUsage(runId: run.id)

        // Give the background writer a moment to finish.
        let deadline = Date().addingTimeInterval(2)
        var snapshot = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
        while snapshot.providers.first(where: { $0.provider == .codex })?.actualProviderTokens == 0,
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            snapshot = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
        }

        let codex = snapshot.providers.first { $0.provider == .codex }
        XCTAssertEqual(codex?.actualProviderTokens, 125,
                       "flush must not add cumulative provider snapshots together")

        // A second flush with the same runId must be a no-op (accumulator was reset).
        context.flushPendingProviderUsage(runId: run.id)
        Thread.sleep(forTimeInterval: 0.05)
        let afterSecondFlush = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
        let codexAfter = afterSecondFlush.providers.first { $0.provider == .codex }
        XCTAssertEqual(codexAfter?.actualProviderTokens, 125,
                       "second flush with empty accumulator must not double-count or corrupt the total")
    }

    // MARK: - global flush drains all runs

    func test_globalFlushDrainsAllPendingRuns() throws {
        let appSupport = NSTemporaryDirectory() + "RC2UsageGlobalFlush-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)

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
        context.flushPendingProviderUsage()

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

        let thread = AgentThread(title: "t", provider: .codex, model: "m")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m",
                           status: .running, startedAt: Date())
        try context.runRepo.upsert(run)

        // Simulate cumulative snapshots that arrive inside the debounce window.
        for tokens in [100, 150] {
            context.coordinator.onAssistantEvent?(
                .tokenUsage(AssistantTokenUsage(inputTokens: tokens, outputTokens: 0, totalTokens: tokens)),
                thread.id,
                run.id
            )
        }

        // Force-flush as the run-end path would -- debounce window must not be required.
        context.flushPendingProviderUsage(runId: run.id)

        let deadline = Date().addingTimeInterval(2)
        var snapshot = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
        while (snapshot.providers.first(where: { $0.provider == .codex })?.actualProviderTokens ?? 0) == 0,
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            snapshot = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
        }

        let codex = snapshot.providers.first { $0.provider == .codex }
        XCTAssertEqual(codex?.actualProviderTokens, 150,
                       "run-end flush must persist the latest cumulative snapshot exactly once")
    }

    func test_debounceFlushThenLaterSnapshotPersistsOnlyGrowth() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2UsageGrowth-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)

        let thread = AgentThread(title: "t", provider: .codex, model: "m")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m",
                           status: .running, startedAt: Date())
        try context.runRepo.upsert(run)

        context.coordinator.onAssistantEvent?(
            .tokenUsage(.init(inputTokens: 100, totalTokens: 100)),
            thread.id, run.id
        )
        context.flushPendingProviderUsage(runId: run.id)
        await waitForProviderTokens(100, provider: .codex, appSupport: context.appSupportDirectory)

        context.coordinator.onAssistantEvent?(
            .tokenUsage(.init(inputTokens: 300, totalTokens: 300)),
            thread.id, run.id
        )
        context.flushPendingProviderUsage(runId: run.id)
        await waitForProviderTokens(300, provider: .codex, appSupport: context.appSupportDirectory)

        let codex = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory)
            .load().providers.first { $0.provider == .codex }
        XCTAssertEqual(codex?.actualProviderTokens, 300,
                       "a post-flush cumulative snapshot must add only 200 new tokens")
        XCTAssertEqual(codex?.eligibleRuns, 0,
                       "Token Saver was removed: provider usage counts no eligible runs")
    }

    func test_incrementalClaudeRequestsReconcileWithFinalCumulativeReceipt() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2UsageMixedClaude-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let thread = AgentThread(title: "claude mixed usage", provider: .claude, model: "m")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .claude, model: "m",
                           status: .running, startedAt: Date())
        try context.runRepo.upsert(run)

        for tokens in [100, 150] {
            context.coordinator.onAssistantEvent?(
                .tokenUsage(.init(
                    inputTokens: tokens,
                    totalTokens: tokens,
                    semantics: .incremental
                )),
                thread.id,
                run.id
            )
        }
        context.flushPendingProviderUsage(runId: run.id)
        await waitForProviderTokens(250, provider: .claude, appSupport: context.appSupportDirectory)

        // The final modelUsage receipt covers both requests and is authoritative.
        // Only its 10-token growth may be persisted.
        context.coordinator.onAssistantEvent?(
            .tokenUsage(.init(
                inputTokens: 260,
                totalTokens: 260,
                semantics: .cumulative
            )),
            thread.id,
            run.id
        )
        context.flushPendingProviderUsage(runId: run.id)
        await waitForProviderTokens(260, provider: .claude, appSupport: context.appSupportDirectory)

        // An older cumulative receipt arriving late cannot subtract or duplicate.
        context.coordinator.onAssistantEvent?(
            .tokenUsage(.init(
                inputTokens: 240,
                totalTokens: 240,
                semantics: .cumulative
            )),
            thread.id,
            run.id
        )
        context.flushPendingProviderUsage(runId: run.id)
        try await Task.sleep(for: .milliseconds(50))
        let claude = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory)
            .load().providers.first { $0.provider == .claude }
        XCTAssertEqual(claude?.actualProviderTokens, 260)
        XCTAssertEqual(claude?.eligibleRuns, 0)
    }

    func test_failedWriteRetriesWithoutLosingOrDoubleCountingUsage() async throws {
        enum ForcedWriteFailure: Error { case expected }

        let appSupport = NSTemporaryDirectory() + "RC2UsageRetry-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let thread = AgentThread(title: "retry usage", provider: .grok, model: "m")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .grok, model: "m",
                           status: .running, startedAt: Date())
        try context.runRepo.upsert(run)

        let attempted = expectation(description: "first usage write attempted")
        context.beforeProviderUsageWriteForTesting = {
            attempted.fulfill()
            throw ForcedWriteFailure.expected
        }
        context.coordinator.onAssistantEvent?(
            .tokenUsage(.init(inputTokens: 100, totalTokens: 100, semantics: .cumulative)),
            thread.id,
            run.id
        )
        context.flushPendingProviderUsage(runId: run.id)
        await fulfillment(of: [attempted], timeout: 2)
        context.beforeProviderUsageWriteForTesting = nil

        await waitForProviderTokens(100, provider: .grok, appSupport: context.appSupportDirectory)

        // Retrying or replaying the same cumulative snapshot stays idempotent.
        context.coordinator.onAssistantEvent?(
            .tokenUsage(.init(inputTokens: 100, totalTokens: 100, semantics: .cumulative)),
            thread.id,
            run.id
        )
        context.flushPendingProviderUsage(runId: run.id)
        try await Task.sleep(for: .milliseconds(50))
        let grok = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory)
            .load().providers.first { $0.provider == .grok }
        XCTAssertEqual(grok?.actualProviderTokens, 100)
        XCTAssertEqual(grok?.eligibleRuns, 0)
    }

    func test_lateCumulativeEventAfterRunFinishPersistsOnlyGrowth() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2UsageLate-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let thread = AgentThread(title: "late receipt", provider: .codex, model: "m")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m",
                           status: .running, startedAt: Date())
        try context.runRepo.upsert(run)

        context.coordinator.onAssistantEvent?(
            .tokenUsage(.init(totalTokens: 100, semantics: .cumulative)),
            thread.id,
            run.id
        )
        context.flushPendingProviderUsage(runId: run.id)
        await waitForProviderTokens(100, provider: .codex, appSupport: context.appSupportDirectory)
        context.coordinator.onRunFinished?(thread.id, run.id, .completed)
        await Task.yield()

        context.coordinator.onAssistantEvent?(
            .tokenUsage(.init(totalTokens: 150, semantics: .cumulative)),
            thread.id,
            run.id
        )
        context.flushPendingProviderUsage(runId: run.id)
        await waitForProviderTokens(150, provider: .codex, appSupport: context.appSupportDirectory)
        XCTAssertEqual(
            TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory)
                .load().providers.first { $0.provider == .codex }?.eligibleRuns,
            0
        )
    }

    func test_lateIncrementalReplayAfterRunFinishIsIgnored() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2UsageLateIncrement-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let thread = AgentThread(title: "late increment", provider: .claude, model: "m")
        try context.threadRepo.upsert(thread)
        var run = AgentRun(threadId: thread.id, provider: .claude, model: "m",
                           status: .running, startedAt: Date())
        try context.runRepo.upsert(run)

        context.coordinator.onAssistantEvent?(
            .tokenUsage(.init(totalTokens: 100, semantics: .incremental)),
            thread.id,
            run.id
        )
        context.flushPendingProviderUsage(runId: run.id)
        await waitForProviderTokens(100, provider: .claude, appSupport: context.appSupportDirectory)
        run.status = .completed
        run.finishedAt = Date()
        try context.runRepo.upsert(run)
        context.coordinator.onRunFinished?(thread.id, run.id, .completed)
        await waitForTombstones(1, in: context)

        // Incremental events have no event ID. Once terminal, a repeated payload
        // must be treated as a replay; legitimate final growth arrives as a
        // cumulative provider receipt.
        context.coordinator.onAssistantEvent?(
            .tokenUsage(.init(totalTokens: 100, semantics: .incremental)),
            thread.id,
            run.id
        )
        context.flushPendingProviderUsage(runId: run.id)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory)
                .load().providers.first { $0.provider == .claude }?.actualProviderTokens,
            100
        )
    }

    func test_completedUsageTombstonesAreBoundedAndEvictedRunsFailClosed() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2UsageTombstones-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        context.providerUsageTombstoneLimitForTesting = 2
        let thread = AgentThread(title: "bounded tombstones", provider: .codex, model: "m")
        try context.threadRepo.upsert(thread)
        var runs: [AgentRun] = []

        for index in 1...3 {
            var run = AgentRun(threadId: thread.id, provider: .codex, model: "m",
                               status: .running, startedAt: Date())
            try context.runRepo.upsert(run)
            context.coordinator.onAssistantEvent?(
                .tokenUsage(.init(totalTokens: 10, semantics: .cumulative)),
                thread.id,
                run.id
            )
            context.flushPendingProviderUsage(runId: run.id)
            await waitForProviderTokens(
                index * 10,
                provider: .codex,
                appSupport: context.appSupportDirectory
            )
            run.status = .completed
            run.finishedAt = Date()
            try context.runRepo.upsert(run)
            context.coordinator.onRunFinished?(thread.id, run.id, .completed)
            await waitForTombstone(run.id, in: context)
            XCTAssertEqual(context.completedUsageTombstoneCountForTesting, min(index, 2))
            runs.append(run)
        }

        XCTAssertEqual(context.completedUsageTombstoneCountForTesting, 2)

        // The first terminal baseline was evicted. Its DB terminal status makes
        // a very late receipt fail closed instead of rebuilding from zero and
        // charging the run a second time.
        let evicted = try XCTUnwrap(runs.first)
        context.coordinator.onAssistantEvent?(
            .tokenUsage(.init(totalTokens: 20, semantics: .cumulative)),
            thread.id,
            evicted.id
        )
        context.flushPendingProviderUsage(runId: evicted.id)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory)
                .load().providers.first { $0.provider == .codex }?.actualProviderTokens,
            30
        )
    }

    private func waitForTombstones(_ expected: Int, in context: AppContext) async {
        let deadline = Date().addingTimeInterval(2)
        while context.completedUsageTombstoneCountForTesting != expected,
              Date() < deadline {
            await Task.yield()
        }
        XCTAssertEqual(context.completedUsageTombstoneCountForTesting, expected)
    }

    private func waitForTombstone(_ runId: AgentRunID, in context: AppContext) async {
        let deadline = Date().addingTimeInterval(2)
        while !context.hasCompletedUsageTombstoneForTesting(runId: runId),
              Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(context.hasCompletedUsageTombstoneForTesting(runId: runId))
    }

    /// Waits until `expected` usage writes have failed. Unlike a wall-clock wait
    /// for the retry timer, this observes the failure counter: the retry interval
    /// is asserted from the scheduled delay, so no spec has to sit out a 60 s cap.
    private func waitForUsageWriteFailures(
        _ expected: Int,
        in context: AppContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(2)
        while context.providerUsageConsecutiveWriteFailuresForTesting < expected,
              Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThanOrEqual(
            context.providerUsageConsecutiveWriteFailuresForTesting,
            expected,
            "expected \(expected) failed usage writes",
            file: file,
            line: line
        )
    }

    private func waitForProviderTokens(
        _ expected: Int,
        provider: AgentProvider,
        appSupport: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(2)
        var actual = 0
        repeat {
            actual = TokenSaverUsageStore(appSupportDirectory: appSupport)
                .load().providers.first { $0.provider == provider }?.actualProviderTokens ?? 0
            if actual == expected { return }
            try? await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
        XCTFail("expected \(expected) provider tokens, got \(actual)", file: file, line: line)
    }

    func test_providerUsageFlushPersistsCacheWeightedBillingUnits() throws {
        let appSupport = NSTemporaryDirectory() + "RC2UsageBilling-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)

        let thread = AgentThread(title: "t", provider: .claude, model: "m")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .claude, model: "m",
                           status: .running, startedAt: Date())
        try context.runRepo.upsert(run)

        context.coordinator.onAssistantEvent?(
            .tokenUsage(AssistantTokenUsage(
                inputTokens: 1_600,
                outputTokens: 40,
                totalTokens: 1_640,
                uncachedInputTokens: 1_000,
                cacheCreationInputTokens: 400,
                cacheReadInputTokens: 200
            )),
            thread.id,
            run.id
        )
        context.flushPendingProviderUsage(runId: run.id)

        let deadline = Date().addingTimeInterval(2)
        var snapshot = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
        while (snapshot.providers.first(where: { $0.provider == .claude })?.actualProviderTokens ?? 0) == 0,
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            snapshot = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
        }

        let claude = snapshot.providers.first { $0.provider == .claude }
        XCTAssertEqual(claude?.actualProviderTokens, 1_640)
        XCTAssertEqual(claude?.actualProviderBilledTokenUnits ?? 0, 1_560, accuracy: 0.001)
        XCTAssertEqual(claude?.estimatedRawBilledTokenUnits ?? 0, 1_560, accuracy: 0.001)
    }

    // MARK: - failed-write retry backs off instead of spinning

    /// WHY: a write can fail for a reason that outlives the request (read-only or
    /// full App Support). Retrying it every debounce window is ~80 wakeups a
    /// minute, each one a cross-process flock plus a failed atomic write, for as
    /// long as the app stays open. The retry must slow down, and a later success
    /// must restore the prompt window rather than inherit the grown one.
    func test_failedUsageWritesBackOffAndASuccessResetsTheRetryWindow() async throws {
        enum ForcedWriteFailure: Error { case expected }

        let appSupport = NSTemporaryDirectory() + "RC2UsageBackoff-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let thread = AgentThread(title: "usage backoff", provider: .codex, model: "m")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m",
                           status: .running, startedAt: Date())
        try context.runRepo.upsert(run)

        context.beforeProviderUsageWriteForTesting = { throw ForcedWriteFailure.expected }
        context.coordinator.onAssistantEvent?(
            .tokenUsage(.init(totalTokens: 100, semantics: .cumulative)),
            thread.id,
            run.id
        )

        for failures in 1...3 {
            context.flushPendingProviderUsage(runId: run.id)
            await waitForUsageWriteFailures(failures, in: context)
        }

        let scheduled = Array(context.providerUsageRetryDelaysForTesting.prefix(3))
        XCTAssertEqual(scheduled.count, 3, "three failed writes must schedule three retries")
        for (index, expected) in [0.75, 1.5, 3.0].enumerated() where index < scheduled.count {
            XCTAssertEqual(
                scheduled[index], expected, accuracy: 0.0001,
                "retry \(index + 1) must wait \(expected) s, not the debounce window"
            )
        }

        // A successful write restores the prompt retry window.
        context.beforeProviderUsageWriteForTesting = nil
        context.flushPendingProviderUsage(runId: run.id)
        await waitForProviderTokens(100, provider: .codex, appSupport: context.appSupportDirectory)
        XCTAssertEqual(context.providerUsageConsecutiveWriteFailuresForTesting, 0)

        // A fresh delta failing again starts the backoff over at the window.
        let scheduledBeforeFinalFailure = context.providerUsageRetryDelaysForTesting.count
        context.beforeProviderUsageWriteForTesting = { throw ForcedWriteFailure.expected }
        context.coordinator.onAssistantEvent?(
            .tokenUsage(.init(totalTokens: 200, semantics: .cumulative)),
            thread.id,
            run.id
        )
        context.flushPendingProviderUsage(runId: run.id)
        await waitForUsageWriteFailures(1, in: context)
        let restartedRetry = context.providerUsageRetryDelaysForTesting
            .dropFirst(scheduledBeforeFinalFailure)
            .first ?? -1
        XCTAssertEqual(restartedRetry, 0.75, accuracy: 0.0001)

        // The backoff must not drop or duplicate the pending delta: the tokens
        // parked across the failed attempts land exactly once when the store
        // becomes writable again.
        context.beforeProviderUsageWriteForTesting = nil
        context.flushPendingProviderUsage(runId: run.id)
        await waitForProviderTokens(200, provider: .codex, appSupport: context.appSupportDirectory)
        try await Task.sleep(for: .milliseconds(50))
        let codex = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory)
            .load().providers.first { $0.provider == .codex }
        XCTAssertEqual(codex?.actualProviderTokens, 200)
        XCTAssertEqual(codex?.eligibleRuns, 0)
    }

    func test_usageWriteRetryDelayDoublesAndSaturatesAtTheCap() {
        let window = AppContext.providerUsageRetryDelay(consecutiveFailures: 1)
        XCTAssertEqual(window, 0.75, accuracy: 0.0001,
                       "the first retry keeps the debounce window")
        XCTAssertEqual(
            AppContext.providerUsageRetryDelay(consecutiveFailures: 0),
            window,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AppContext.providerUsageRetryDelay(consecutiveFailures: -3),
            window,
            accuracy: 0.0001
        )
        for (failures, expected) in [(2, 1.5), (3, 3.0), (7, 48.0), (8, 60.0), (1_000, 60.0)] {
            XCTAssertEqual(
                AppContext.providerUsageRetryDelay(consecutiveFailures: failures),
                expected,
                accuracy: 0.0001,
                "\(failures) consecutive failures"
            )
        }
    }
}
