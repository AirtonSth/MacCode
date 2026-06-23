import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// Tests encoding the "exactly one terminal event per run" contract (T002/T003).
///
/// WHY: the iOS mirror depends on exactly one didFinish callback per run.
///  T002 - double-finish: a run that emits .finished twice must call didFinish once
///  T003 - phantom-run: a runId that was never started must never call didFinish
///
/// Uses the existing FakeProviderRunner/SpyProviderAdapter fakes.
final class CoordinatorTerminalEventTests: XCTestCase {

    func test_coordinator_doubleFinishedRun_callsDidFinishOnce() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-double-finish-run-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "double finish", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)

        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [.codex: DoubleFinishRunner()])

        actor FinishTracker {
            var calledRunIds: [AgentRunID] = []
            func record(_ id: AgentRunID) { calledRunIds.append(id) }
        }
        let tracker = FinishTracker()

        class Observer: AgentRunObserver {
            let tracker: FinishTracker
            init(_ t: FinishTracker) { tracker = t }
            func runCoordinator(_ c: AgentRunCoordinator, didReceive event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID) {}
            func runCoordinator(_ c: AgentRunCoordinator, didFinish runId: AgentRunID, threadId: AgentThreadID, status: AgentRunStatus, finalMessage: String?, providerThreadId: String?) {
                Task { await tracker.record(runId) }
            }
            func runCoordinator(_ c: AgentRunCoordinator, didChangeStatus status: AgentRunStatus, runId: AgentRunID, threadId: AgentThreadID) {}
        }
        let obs = Observer(tracker)
        coordinator.addObserver(obs)

        let runId = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: "real"
        ))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await tracker.calledRunIds.filter({ $0 == runId }).count >= 2 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        let occurrences = await tracker.calledRunIds.filter { $0 == runId }.count
        XCTAssertEqual(occurrences, 1,
                       "a provider that emits .finished twice must still produce exactly one didFinish callback for the run")
    }

    // MARK: - T003: phantom-run never calls didFinish

    func test_coordinator_phantomRun_neverCallsDidFinish() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-phantom-run-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "phantom", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)

        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [.codex: FakeProviderRunner(provider: .codex)])

        actor FinishTracker {
            var calledRunIds: [AgentRunID] = []
            func record(_ id: AgentRunID) { calledRunIds.append(id) }
        }
        let tracker = FinishTracker()

        class Observer: AgentRunObserver {
            let tracker: FinishTracker
            init(_ t: FinishTracker) { tracker = t }
            func runCoordinator(_ c: AgentRunCoordinator, didReceive event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID) {}
            func runCoordinator(_ c: AgentRunCoordinator, didFinish runId: AgentRunID, threadId: AgentThreadID, status: AgentRunStatus, finalMessage: String?, providerThreadId: String?) {
                Task { await tracker.record(runId) }
            }
            func runCoordinator(_ c: AgentRunCoordinator, didChangeStatus status: AgentRunStatus, runId: AgentRunID, threadId: AgentThreadID) {}
        }
        let obs = Observer(tracker)
        coordinator.addObserver(obs)

        // Start one real run and wait for it to finish.
        let realRunId = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: "real"
        ))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await tracker.calledRunIds.contains(realRunId) { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        // The phantom run ID was never started through coordinator.startRun.
        let phantomRunId = AgentRunID()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let finalIds = await tracker.calledRunIds
        XCTAssertFalse(finalIds.contains(phantomRunId),
                       "a runId that was never started must never receive a didFinish callback — phantom runs must not appear in the iOS mirror's thread list")
        XCTAssertTrue(finalIds.contains(realRunId),
                      "the real run must have called didFinish (sanity check on observer wiring)")
    }

    // MARK: - Exactly-one-terminal-event-per-run (property)

    func test_coordinator_exactlyOneFinishPerRun_acrossMultipleTurns() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-one-finish-per-run-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "multi-turn", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)

        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [.codex: FakeProviderRunner(provider: .codex, scenario: .simpleAssistant(reply: "ok"))])

        actor RunFinishes {
            var runIds: [AgentRunID] = []
            func record(_ id: AgentRunID) { runIds.append(id) }
        }
        let finishes = RunFinishes()

        class Observer: AgentRunObserver {
            let finishes: RunFinishes
            init(_ f: RunFinishes) { finishes = f }
            func runCoordinator(_ c: AgentRunCoordinator, didReceive event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID) {}
            func runCoordinator(_ c: AgentRunCoordinator, didFinish runId: AgentRunID, threadId: AgentThreadID, status: AgentRunStatus, finalMessage: String?, providerThreadId: String?) {
                Task { await finishes.record(runId) }
            }
            func runCoordinator(_ c: AgentRunCoordinator, didChangeStatus status: AgentRunStatus, runId: AgentRunID, threadId: AgentThreadID) {}
        }
        let obs = Observer(finishes)
        coordinator.addObserver(obs)

        let runCount = 5
        var startedIds: [AgentRunID] = []
        for i in 0..<runCount {
            let id = try await coordinator.startRun(AgentRunRequest(
                threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: "turn \(i)"
            ))
            startedIds.append(id)
            // Wait for this run to finish before starting the next.
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if await finishes.runIds.contains(id) { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        // Small stabilization pause.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let allFinished = await finishes.runIds

        for id in startedIds {
            let occurrences = allFinished.filter { $0 == id }.count
            XCTAssertEqual(occurrences, 1,
                           "run \(id) must have exactly one didFinish call — duplicate calls confuse the iOS mirror's turn tracker")
        }
        XCTAssertEqual(Set(allFinished).count, runCount,
                       "every started run must produce exactly one terminal event — no runs may be silently swallowed")
    }
}

// MARK: - DoubleFinishRunner

/// AgentProviderRunner that emits .finished twice to simulate a buggy adapter.
/// The coordinator must guard against this and call didFinish exactly once.
private final class DoubleFinishRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        let handle = AgentRunHandle(runId: request.runId, process: nil) {}
        Task.detached {
            let threadId = request.providerThreadId ?? UUID().uuidString
            onEvent(.status(.running))
            onEvent(.event(.threadStarted(threadId: threadId, providerThreadId: threadId)))
            onEvent(.event(.turnStarted(turnId: "t1")))
            onEvent(.event(.turnCompleted(turnId: "t1", finalMessage: "done")))
            onEvent(.finished(.completed, finalMessage: "done", providerThreadId: threadId))
            // Second .finished — the coordinator must deduplicate this.
            onEvent(.finished(.completed, finalMessage: "done-again", providerThreadId: threadId))
        }
        return handle
    }
}
