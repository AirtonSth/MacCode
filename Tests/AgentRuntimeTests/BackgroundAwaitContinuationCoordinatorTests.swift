import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// Integration coverage for the run-coordinator wiring of background-await
/// auto-continuation.
///
/// WHY: the reported bug is a full-access run that launched a background job (a
/// Playwright demo recording), ended its turn saying "Standing by for the demo
/// recording to complete.", and was marked `.completed` — finished, but not
/// actually done, and never resumed. The coordinator must re-invoke the agent a
/// bounded number of times for autonomous runs only, and never for supervised
/// runs or runs that genuinely finished.
final class BackgroundAwaitContinuationCoordinatorTests: XCTestCase {

    /// Provider runner that always finishes `.completed` with a fixed final
    /// message and counts how many times the coordinator started a run through it.
    private final class StallingRunner: AgentProviderRunner, @unchecked Sendable {
        let provider: AgentProvider
        let finalMessage: String
        private let lock = NSLock()
        private var _starts = 0
        var startCount: Int { lock.lock(); defer { lock.unlock() }; return _starts }

        init(provider: AgentProvider = .codex, finalMessage: String) {
            self.provider = provider
            self.finalMessage = finalMessage
        }

        func listModels() async -> [AgentModelDescriptor] { [] }

        func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
            lock.lock(); _starts += 1; lock.unlock()
            let handle = AgentRunHandle(runId: request.runId, process: nil) {}
            let final = finalMessage
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            Task.detached {
                onEvent(.status(.running))
                onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
                let turnId = UUID().uuidString
                onEvent(.event(.turnStarted(turnId: turnId)))
                let itemId = UUID().uuidString
                onEvent(.event(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .assistantMessage, startedAtMs: 0))))
                onEvent(.event(.itemDelta(itemId: itemId, bodyAppend: final, outputAppend: nil, summary: nil)))
                onEvent(.event(.itemCompleted(itemId: itemId, finalState: .completed)))
                onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: final)))
                onEvent(.status(.completed))
                onEvent(.finished(.completed, finalMessage: final, providerThreadId: providerThreadId))
            }
            return handle
        }
    }

    private func makeCoordinator(runner: StallingRunner) throws -> (AgentRunCoordinator, AgentThread, String) {
        let tmp = NSTemporaryDirectory() + "rc2-bg-await-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "bg-await", provider: runner.provider, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [runner.provider: runner])
        coordinator.backgroundAwaitContinuationDelay = 0
        return (coordinator, thread, tmp)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func test_fullAccessStallAwaitingBackgroundJob_autoNudgesUpToTheBoundThenStops() async throws {
        let runner = StallingRunner(finalMessage: "Standing by for the demo recording to complete.")
        let (coordinator, thread, tmp) = try makeCoordinator(runner: runner)

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp,
            prompt: "implement everything", permissionMode: .fullAccess
        ))

        // 1 user-initiated run + maxAutoContinuations auto-nudges, then it stops.
        let expected = BackgroundAwaitContinuation.maxAutoContinuations + 1
        await waitUntil { runner.startCount >= expected }
        // Stabilize and prove it does NOT exceed the bound (no runaway loop).
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(runner.startCount, expected,
                       "a full-access run stalled on a background job must auto-continue exactly \(BackgroundAwaitContinuation.maxAutoContinuations) times then stop — never silently sit at 'completed', never loop forever")
    }

    func test_fullAccessClaudeStallAwaitingDeployPoller_autoNudgesUpToTheBoundThenStops() async throws {
        // The reported bug: a Claude full-access run ended its turn saying
        // "I'll wait for the deploy poller to complete (it notifies me), then run …"
        // and was marked `.completed` — the deploy poller is a background job the app
        // cannot see, so nothing ever resumed the agent. This exact final message
        // (future-tense, first-person, async-job) must trip the detector and drive a
        // bounded auto-nudge, identical to the original demo-recording stall.
        let runner = StallingRunner(
            provider: .claude,
            finalMessage: "I'll wait for the deploy poller to complete (it notifies me), then run the summer-gate Chrome verification across multiple accounts.")
        let (coordinator, thread, tmp) = try makeCoordinator(runner: runner)

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .claude, model: "fake-model", cwd: tmp,
            prompt: "implement everything", permissionMode: .fullAccess
        ))

        let expected = BackgroundAwaitContinuation.maxAutoContinuations + 1
        await waitUntil { runner.startCount >= expected }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(runner.startCount, expected,
                       "a Claude full-access run stalled on a background deploy poller must auto-continue exactly \(BackgroundAwaitContinuation.maxAutoContinuations) times then stop — not sit silently at 'completed'")
    }

    func test_fullAccessMarkerStall_autoNudgesEvenWhenPhrasingIsNovel() async throws {
        // The robust path: the agent self-declares the stall with the marker, so the
        // real coordinator auto-nudges regardless of wording. This message's prose
        // ("Holding here until the canary bake finishes") matches NONE of the
        // heuristic phrase lists — only the marker makes recovery fire end-to-end.
        let runner = StallingRunner(
            provider: .claude,
            finalMessage: "\(BackgroundAwaitContinuation.awaitingMarker)\nHolding here until the canary bake finishes and the gate flips.")
        let (coordinator, thread, tmp) = try makeCoordinator(runner: runner)

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .claude, model: "fake-model", cwd: tmp,
            prompt: "ship it", permissionMode: .fullAccess
        ))

        let expected = BackgroundAwaitContinuation.maxAutoContinuations + 1
        await waitUntil { runner.startCount >= expected }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(runner.startCount, expected,
                       "a self-declared (marker) stall must auto-continue to the bound regardless of phrasing")
    }

    func test_supervisedStall_isNotAutoNudged() async throws {
        let runner = StallingRunner(finalMessage: "Standing by for the demo recording to complete.")
        let (coordinator, thread, tmp) = try makeCoordinator(runner: runner)

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp,
            prompt: "implement everything", permissionMode: .supervised
        ))

        // Give an auto-nudge every chance to (wrongly) fire, then assert it did not.
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(runner.startCount, 1,
                       "a supervised run must never be auto-nudged — the user drives resumption manually")
    }

    func test_fullAccessRunThatGenuinelyFinished_isNotAutoNudged() async throws {
        let runner = StallingRunner(finalMessage: "All four steps are done; the build is green and the PR is open.")
        let (coordinator, thread, tmp) = try makeCoordinator(runner: runner)

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp,
            prompt: "implement everything", permissionMode: .fullAccess
        ))

        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(runner.startCount, 1,
                       "a run whose final message is a real answer (not a background-await stall) must not be auto-nudged")
    }
}
