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

    func test_fullAccessMarkerBeforeRCW1_autoNudgesAfterHumanTranslation() async throws {
        // Regression: RCW1 transport extraction intentionally removes provider
        // preamble text before local rendering. When the preamble was the host's
        // [[RC_AWAITING]] signal, terminal handling classified only the translated
        // prose and silently left an incomplete full-access run as completed.
        let wire = "RCW1\tA\t1\nO\tIN_PROGRESS\nA\tAwaiting delegated worker result.\n.\n"
        for provider in [AgentProvider.claude, .codex, .grok] {
            let runner = StallingRunner(
                provider: provider,
                finalMessage: "\(BackgroundAwaitContinuation.awaitingMarker)\n\(wire)"
            )
            let (coordinator, thread, tmp) = try makeCoordinator(runner: runner)
            coordinator.finalResponseTranslator = { response, translatedProvider, _, _ in
                XCTAssertEqual(translatedProvider, provider)
                XCTAssertEqual(response, wire.trimmingCharacters(in: .whitespacesAndNewlines),
                               "the renderer must still receive only the strict RCW1 payload")
                return "IN_PROGRESS\n\nAction: Awaiting delegated worker result."
            }

            _ = try await coordinator.startRun(AgentRunRequest(
                threadId: thread.id, provider: provider, model: "fake-model", cwd: tmp,
                prompt: "finish the delegated workflow", permissionMode: .fullAccess
            ))

            let expected = BackgroundAwaitContinuation.maxAutoContinuations + 1
            await waitUntil { runner.startCount >= expected }
            try? await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertTrue(
                coordinator.autoContinuationThreadIdsForTesting.contains(thread.id),
                "the raw RCW1 terminal must reach the incomplete-turn classifier for \(provider.rawValue)"
            )
            XCTAssertEqual(
                runner.startCount,
                expected,
                "RCW1 translation must not erase the raw incomplete-turn marker for \(provider.rawValue)"
            )
        }
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

    func test_fullAccessWorkflowHandoff_autoNudgesWithWorkflowPromptNotBackground() async throws {
        // Incident: Phase 2 ends with "Next: Phase 3 — Review" and no marker → was
        // green completed forever. Must auto-nudge with the workflow prompt, never
        // the BashOutput background-await prompt.
        let handoff = """
        **PHASE 2 RESULT: HIGH_CONFIDENCE**
        Strategy is executable.
        **Next: Phase 3 — Review**
        """
        let runner = PromptCapturingStallingRunner(finalMessage: handoff)
        let (coordinator, thread, tmp) = try makePromptCapturingCoordinator(runner: runner)

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .claude, model: "fake-model", cwd: tmp,
            prompt: "implement all in todo.md /sam-work", permissionMode: .fullAccess
        ))

        await waitUntil { runner.startCount >= 2 }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertGreaterThanOrEqual(runner.startCount, 2,
                                    "workflow handoff must auto-nudge at least once")
        XCTAssertTrue(
            runner.prompts.contains(where: { $0 == IncompleteTurnContinuation.workflowContinuationPrompt }),
            "auto-nudge must use the workflow continuation prompt"
        )
        XCTAssertFalse(
            runner.prompts.contains(BackgroundAwaitContinuation.continuationPrompt),
            "workflow handoff must NOT use the background BashOutput prompt"
        )
    }

    func test_fullAccessPhaseHandoffWithMisusedMarker_usesWorkflowPrompt() async throws {
        // Phase 1 ended with Proceeding to Phase 2 + [[RC_AWAITING]]. Workflow
        // classification must win over the marker so we do not send BashOutput.
        let handoff = """
        Phase 1 COMPLETE.
        Proceeding to Phase 2: **REFINE** — stress-test the implementation strategy.

        [[RC_AWAITING]]
        """
        let runner = PromptCapturingStallingRunner(finalMessage: handoff)
        let (coordinator, thread, tmp) = try makePromptCapturingCoordinator(runner: runner)

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .claude, model: "fake-model", cwd: tmp,
            prompt: "/sam-work", permissionMode: .fullAccess
        ))

        await waitUntil { runner.startCount >= 2 }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(
            runner.prompts.contains(where: { $0 == IncompleteTurnContinuation.workflowContinuationPrompt }),
            "misused marker on phase handoff must still get the workflow prompt"
        )
        XCTAssertFalse(
            runner.prompts.contains(BackgroundAwaitContinuation.continuationPrompt),
            "must not send background-await prompt when workflow handoff matches"
        )
    }

    /// Like StallingRunner but records every start prompt for reason assertions.
    private final class PromptCapturingStallingRunner: AgentProviderRunner, @unchecked Sendable {
        let provider: AgentProvider
        let finalMessage: String
        private let lock = NSLock()
        private var _starts = 0
        private var _prompts: [String] = []
        var startCount: Int { lock.lock(); defer { lock.unlock() }; return _starts }
        var prompts: [String] { lock.lock(); defer { lock.unlock() }; return _prompts }

        init(provider: AgentProvider = .claude, finalMessage: String) {
            self.provider = provider
            self.finalMessage = finalMessage
        }

        func listModels() async -> [AgentModelDescriptor] { [] }

        func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
            lock.lock()
            _starts += 1
            _prompts.append(request.prompt)
            lock.unlock()
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

    private func makePromptCapturingCoordinator(runner: PromptCapturingStallingRunner) throws -> (AgentRunCoordinator, AgentThread, String) {
        let tmp = NSTemporaryDirectory() + "rc2-wf-handoff-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "wf-handoff", provider: runner.provider, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [runner.provider: runner])
        coordinator.backgroundAwaitContinuationDelay = 0
        return (coordinator, thread, tmp)
    }
}
