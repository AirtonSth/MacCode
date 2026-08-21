import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// Regression: abnormal run ends must persist a human-readable
/// `agent_runs.error_message` for claude / codex / grok, user Stop must stay
/// silent, and empty "completed" must not be a plain success.
///
/// WHY: live DB had 51 failed/interrupted runs with NULL error_message and 19
/// completed runs whose last message was still the user prompt — Agent App
/// appeared to "stop working" with no explanation.
final class AgentRunTerminalReasonTests: XCTestCase {

    private final class FinishRecorder: AgentRunObserver, @unchecked Sendable {
        private let lock = NSLock()
        private var _finished: [(AgentRunID, AgentRunStatus)] = []
        var finished: [(AgentRunID, AgentRunStatus)] {
            lock.lock(); defer { lock.unlock() }; return _finished
        }
        func runCoordinator(_ c: AgentRunCoordinator, didReceive event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID) {}
        func runCoordinator(_ c: AgentRunCoordinator, didFinish runId: AgentRunID, threadId: AgentThreadID, status: AgentRunStatus, finalMessage: String?, providerThreadId: String?) {
            lock.lock(); _finished.append((runId, status)); lock.unlock()
        }
        func runCoordinator(_ c: AgentRunCoordinator, didChangeStatus status: AgentRunStatus, runId: AgentRunID, threadId: AgentThreadID) {}
    }

    /// Provider stream that dies with `.finished(.failed)` and no prior `.error`
    /// / turnCompleted — the "no terminal success event" path.
    private final class SilentFailRunner: AgentProviderRunner, @unchecked Sendable {
        let provider: AgentProvider
        init(provider: AgentProvider) { self.provider = provider }
        func listModels() async -> [AgentModelDescriptor] { [] }
        func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
            let threadId = request.providerThreadId ?? UUID().uuidString
            Task.detached {
                onEvent(.status(.running))
                onEvent(.event(.threadStarted(threadId: threadId, providerThreadId: threadId)))
                onEvent(.event(.turnStarted(turnId: "t1")))
                // Stream dies without a terminal success event and without stderr.
                onEvent(.finished(.failed, finalMessage: nil, providerThreadId: threadId))
            }
            return AgentRunHandle(runId: request.runId, process: nil) {}
        }
    }

    /// Provider that reports completed but never emits assistant text.
    private final class EmptyCompletedRunner: AgentProviderRunner, @unchecked Sendable {
        let provider: AgentProvider
        init(provider: AgentProvider = .codex) { self.provider = provider }
        func listModels() async -> [AgentModelDescriptor] { [] }
        func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
            let threadId = request.providerThreadId ?? UUID().uuidString
            Task.detached {
                onEvent(.status(.running))
                onEvent(.event(.threadStarted(threadId: threadId, providerThreadId: threadId)))
                onEvent(.event(.turnStarted(turnId: "t1")))
                onEvent(.event(.turnCompleted(turnId: "t1", finalMessage: nil)))
                onEvent(.finished(.completed, finalMessage: nil, providerThreadId: threadId))
            }
            return AgentRunHandle(runId: request.runId, process: nil) {}
        }
    }

    /// Stays running until cancel; cancel emits `.finished(.cancelled)`.
    private final class SyncCancelRunner: AgentProviderRunner, @unchecked Sendable {
        let provider: AgentProvider = .codex
        func listModels() async -> [AgentModelDescriptor] { [] }
        func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
            let threadId = request.providerThreadId ?? UUID().uuidString
            onEvent(.status(.running))
            onEvent(.event(.threadStarted(threadId: threadId, providerThreadId: threadId)))
            onEvent(.event(.turnStarted(turnId: "t1")))
            return AgentRunHandle(runId: request.runId, process: nil) {
                onEvent(.finished(.cancelled, finalMessage: nil, providerThreadId: threadId))
            }
        }
    }

    private func makeRepos(_ label: String) throws -> (
        AgentThreadRepository, AgentMessageRepository, AgentRunRepository, String
    ) {
        let tmp = NSTemporaryDirectory() + "rc2-terminal-reason-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (
            AgentThreadRepository(db: db),
            AgentMessageRepository(db: db),
            AgentRunRepository(db: db),
            tmp
        )
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - stream dies without terminal success → non-empty reason (per provider)

    func test_claude_streamDiesWithoutTerminalEvent_storesSpecificErrorMessage() async throws {
        try await assertSilentFailStoresReason(provider: .claude)
    }

    func test_codex_streamDiesWithoutTerminalEvent_storesSpecificErrorMessage() async throws {
        try await assertSilentFailStoresReason(provider: .codex)
    }

    func test_grok_streamDiesWithoutTerminalEvent_storesSpecificErrorMessage() async throws {
        try await assertSilentFailStoresReason(provider: .grok)
    }

    private func assertSilentFailStoresReason(provider: AgentProvider) async throws {
        let (threadRepo, messageRepo, runRepo, tmp) = try makeRepos(provider.rawValue)
        let thread = AgentThread(title: "silent-fail-\(provider.rawValue)", provider: provider, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [provider: SilentFailRunner(provider: provider)]
        )
        let recorder = FinishRecorder()
        coordinator.addObserver(recorder)

        let runId = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: provider, model: "fake-model", cwd: tmp, prompt: "hi"
        ))
        await waitUntil { recorder.finished.contains { $0.0 == runId } }

        let row = try runRepo.get(id: runId)
        XCTAssertEqual(row?.status, .failed,
                       "\(provider) stream death must finish as failed")
        let message = row?.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertFalse(message.isEmpty,
                       "\(provider) failed run must persist a non-empty error_message; got nil/empty " +
                       "(this is the silent 'app stopped working' bug)")
        XCTAssertTrue(
            message.contains(ProviderStderrClassifier.displayName(provider)),
            "\(provider) reason must name the provider; got: \(message)"
        )
        XCTAssertNotEqual(message.lowercased(), "failed")
        XCTAssertNotEqual(message.lowercased(), "unknown error")
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("stream")
                || message.localizedCaseInsensitiveContains("terminal")
                || message.localizedCaseInsensitiveContains("stderr"),
            "reason must describe the observed failure mode; got: \(message)"
        )
    }

    // MARK: - user Stop invents no error

    func test_userStop_storesNoInventedErrorMessage() async throws {
        let (threadRepo, messageRepo, runRepo, tmp) = try makeRepos("user-stop")
        let thread = AgentThread(title: "stop", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: SyncCancelRunner()]
        )
        let recorder = FinishRecorder()
        coordinator.addObserver(recorder)

        let runId = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: "hi"
        ))
        // Let the run register as running, then Stop.
        try? await Task.sleep(nanoseconds: 50_000_000)
        coordinator.stopRun(threadId: thread.id)
        await waitUntil { recorder.finished.contains { $0.0 == runId && $0.1 == .cancelled } }

        let row = try runRepo.get(id: runId)
        XCTAssertEqual(row?.status, .cancelled)
        XCTAssertNil(row?.errorMessage,
                     "user Stop must not invent an error_message; cancelled is a legitimate silent end")
        XCTAssertEqual(row?.terminalReason, "userStop")
    }

    // MARK: - empty completed is not silent success

    func test_completedWithNoAssistantOutput_isNotSilentPlainSuccess() async throws {
        let (threadRepo, messageRepo, runRepo, tmp) = try makeRepos("empty-completed")
        let thread = AgentThread(title: "empty", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: EmptyCompletedRunner()]
        )
        let recorder = FinishRecorder()
        coordinator.addObserver(recorder)

        let runId = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: "only user prompt"
        ))
        await waitUntil { recorder.finished.contains { $0.0 == runId } }

        let row = try runRepo.get(id: runId)
        XCTAssertNotEqual(row?.status, .completed,
                          "a run that produced no assistant answer must not be recorded as plain completed")
        XCTAssertEqual(row?.status, .failed)
        let message = row?.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertFalse(message.isEmpty,
                       "empty-output terminal must store a reason so the UI can explain what happened")
        XCTAssertTrue(message.localizedCaseInsensitiveContains("assistant"),
                      "reason should mention missing assistant response; got: \(message)")

        let messages = try messageRepo.list(threadId: thread.id)
        XCTAssertFalse(messages.contains { $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                       "sanity: this fixture must not have produced assistant content")
    }

    // MARK: - real stderr detail is preferred when present

    func test_failedWithProviderErrorEvent_storesThatDetail() async throws {
        let (threadRepo, messageRepo, runRepo, tmp) = try makeRepos("stderr-detail")
        let thread = AgentThread(title: "err", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let detail = "Error: authentication token expired"
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.claude: FakeProviderRunner(provider: .claude, scenario: .error(message: detail))]
        )
        let recorder = FinishRecorder()
        coordinator.addObserver(recorder)

        let runId = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .claude, model: "fake-model", cwd: tmp, prompt: "hi"
        ))
        await waitUntil { recorder.finished.contains { $0.0 == runId } }

        let row = try runRepo.get(id: runId)
        XCTAssertEqual(row?.status, .failed)
        XCTAssertEqual(row?.errorMessage, detail,
                       "when the provider emits a real error detail, that exact text must be the durable error_message")
    }
}
