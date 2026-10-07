import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// Provider runner that records the exact prompt and environment it was handed.
final class PromptCapturingRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private var _captured: String?
    private var _capturedEnvironment: [String: String] = [:]
    /// At most one waiter; taken under lock so resume runs at most once.
    private var _promptWaiter: CheckedContinuation<Void, Never>?

    init(provider: AgentProvider = .codex) { self.provider = provider }

    var capturedPrompt: String? {
        lock.lock(); defer { lock.unlock() }
        return _captured
    }

    var capturedEnvironment: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return _capturedEnvironment
    }

    /// Suspend until `startRun` has stored a prompt. Race-safe whether capture
    /// happens before or after this call; never resumes a continuation twice.
    func waitForPromptCapture() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if _captured != nil {
                lock.unlock()
                continuation.resume()
                return
            }
            precondition(_promptWaiter == nil, "PromptCapturingRunner supports a single prompt waiter")
            _promptWaiter = continuation
            lock.unlock()
        }
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        lock.lock()
        _captured = request.prompt
        _capturedEnvironment = request.environment
        let waiter = _promptWaiter
        _promptWaiter = nil
        lock.unlock()
        waiter?.resume()
        let handle = AgentRunHandle(runId: request.runId, process: nil) {}
        let tid = request.providerThreadId ?? UUID().uuidString
        Task.detached {
            onEvent(.status(.running))
            onEvent(.event(.threadStarted(threadId: tid, providerThreadId: tid)))
            onEvent(.finished(.completed, finalMessage: "done", providerThreadId: tid))
        }
        return handle
    }
}

final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _steps: [String] = []
    var steps: [String] { lock.withLock { _steps } }
    var count: Int { steps.count }
    func add(_ step: String) { lock.withLock { _steps.append(step) } }
}

final class ScopeRefreshingAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private var sessions: [AgentThreadID: AgentProviderSessionSummary] = [:]
    private(set) var requests: [AgentRunRequest] = []
    private(set) var retiredEnvironments: [[String: String]] = []
    private(set) var stopSessionCalls = 0

    init(provider: AgentProvider) {
        self.provider = provider
    }

    /// Seeds a resident idle session the coordinator can observe via `hasSession`
    /// without a durable provider thread id (the pre-continuity case).
    func seedIdleSession(
        threadId: AgentThreadID,
        providerThreadId: String? = nil,
        status: AgentRunStatus = .completed
    ) {
        lock.lock()
        sessions[threadId] = .init(
            threadId: threadId,
            provider: provider,
            status: status,
            providerThreadId: providerThreadId
        )
        lock.unlock()
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startSession(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }

    func sendTurn(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        let providerThreadID = request.providerThreadId ?? "continuity-\(provider.rawValue)"
        lock.lock()
        requests.append(request)
        sessions[request.threadId] = .init(
            threadId: request.threadId,
            provider: provider,
            status: .completed,
            providerThreadId: providerThreadID
        )
        lock.unlock()
        Task.detached {
            onEvent(.event(.threadStarted(threadId: providerThreadID, providerThreadId: providerThreadID)))
            onEvent(.finished(.completed, finalMessage: "done", providerThreadId: providerThreadID))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }

    func interruptTurn(threadId: AgentThreadID) throws {}
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {}
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {}

    func stopSession(threadId: AgentThreadID) throws {
        lock.lock()
        stopSessionCalls += 1
        if let request = requests.last(where: { $0.threadId == threadId }) {
            retiredEnvironments.append(request.environment)
        }
        sessions.removeValue(forKey: threadId)
        lock.unlock()
    }

    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] {
        lock.lock()
        defer { lock.unlock() }
        return Array(sessions.values)
    }
    func hasSession(threadId: AgentThreadID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessions[threadId] != nil
    }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}
}

final class AgentRunCoordinatorBotSecretScopeTests: XCTestCase {
    private func waitForRun(
        _ runID: AgentRunID,
        in repository: AgentRunRepository
    ) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let run = try repository.get(id: runID), run.status == .completed {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("run did not complete")
    }

    func test_reusedProviderSessionsRefreshWhenBotSecretsChangeButReuseWhenUnchanged() async throws {
        for provider in [AgentProvider.claude, .codex, .grok] {
            let tmp = NSTemporaryDirectory() + "rc2-bot-secret-scope-" + provider.rawValue + "-" + UUID().uuidString
            let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
            let threadRepo = AgentThreadRepository(db: db)
            let messageRepo = AgentMessageRepository(db: db)
            let runRepo = AgentRunRepository(db: db)
            let thread = AgentThread(title: "bot secrets", provider: provider, model: "test")
            try threadRepo.upsert(thread)
            let adapter = ScopeRefreshingAdapter(provider: provider)
            let botID = BotID(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!)
            let secretStore = InMemoryBotSecretStore()
            let coordinator = AgentRunCoordinator(
                runRepo: runRepo,
                messageRepo: messageRepo,
                threadRepo: threadRepo,
                providerAdapters: [provider: adapter],
                botSecretStore: secretStore
            )
            let scope = BotSecretScopeTestState(botID: botID)
            coordinator.runEnvironmentProvider = { selectedProvider, selectedThread, _ in
                scope.environment(provider: selectedProvider, threadId: selectedThread)
            }

            func runTurn(_ prompt: String, providerThreadId: String? = nil) async throws {
                let runID = AgentRunID()
                _ = try await coordinator.startRun(.init(
                    runId: runID,
                    threadId: thread.id,
                    provider: provider,
                    model: "test",
                    cwd: tmp,
                    prompt: prompt,
                    providerThreadId: providerThreadId
                ))
                try await waitForRun(runID, in: runRepo)
            }

            try secretStore.save(botID: botID, name: "SERVICE_TOKEN", value: "one")
            try await runTurn("first")
            let providerThreadID = try XCTUnwrap(try threadRepo.get(id: thread.id)?.providerThreadId)

            try await runTurn("unchanged", providerThreadId: providerThreadID)
            XCTAssertEqual(adapter.stopSessionCalls, 0, "\(provider.rawValue) must reuse an unchanged secret scope")

            try secretStore.save(botID: botID, name: "SERVICE_TOKEN", value: "two")
            try await runTurn("updated", providerThreadId: providerThreadID)
            XCTAssertEqual(adapter.stopSessionCalls, 1, "\(provider.rawValue) must refresh after a secret update")

            try await runTurn("updated again", providerThreadId: providerThreadID)
            XCTAssertEqual(adapter.stopSessionCalls, 1, "\(provider.rawValue) must reuse an unchanged updated secret")

            try secretStore.delete(botID: botID, name: "SERVICE_TOKEN")
            try await runTurn("removed", providerThreadId: providerThreadID)
            XCTAssertEqual(adapter.stopSessionCalls, 2, "\(provider.rawValue) must refresh after a secret removal")

            try await runTurn("still removed", providerThreadId: providerThreadID)
            XCTAssertEqual(adapter.stopSessionCalls, 2, "\(provider.rawValue) must reuse an unchanged empty secret scope")
        }
    }

    func test_startRunFailsClosedOnProtectedSecretStorageFailureBeforeProviderAdmission() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-bot-secret-failure-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "secret failure", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = PromptCapturingRunner(provider: .codex)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner],
            botSecretStore: FailingBotSecretStore()
        )
        let admission = CallLog()
        coordinator.providerAdmissionCheck = { _, _ in admission.add("admission") }

        do {
            _ = try await coordinator.startRun(.init(
                threadId: thread.id,
                provider: .codex,
                model: "fake-model",
                cwd: tmp,
                prompt: "must not start",
                environment: [
                    BotSecretEnvironment.botIDEnvironmentKey:
                        "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
                ]
            ))
            XCTFail("secret storage failure must reject run admission")
        } catch {
            XCTAssertEqual(String(describing: error), "Protected secret storage is unavailable.")
        }
        XCTAssertTrue(admission.steps.isEmpty)
        XCTAssertNil(runner.capturedPrompt)
    }
}

private final class BotSecretScopeTestState: @unchecked Sendable {
    private let lock = NSLock()
    private let botID: BotID

    init(botID: BotID) {
        self.botID = botID
    }

    func environment(provider: AgentProvider, threadId: AgentThreadID) -> [String: String] {
        lock.withLock {
            var environment = [
                "REMOTE_CODE_AGENT_PROVIDER": provider.rawValue,
                BotSecretEnvironment.botIDEnvironmentKey: botID.value.uuidString,
            ]
            environment["RC_TOKEN_SAVER_THREAD_ID"] = threadId.value.uuidString
            return environment
        }
    }
}

private final class FailingBotSecretStore: BotSecretStore, @unchecked Sendable {
    private func fail() throws -> Never { throw SyntheticProtectedStorageFailure() }

    func list(botID: BotID) throws -> [BotSecretMetadata] { try fail() }
    func save(botID: BotID, name: String, value: String) throws { try fail() }
    func load(botID: BotID, name: String) throws -> String? { try fail() }
    func delete(botID: BotID, name: String) throws { try fail() }
    func deleteAll(botID: BotID) throws { try fail() }
}

private struct SyntheticProtectedStorageFailure: Error {}
