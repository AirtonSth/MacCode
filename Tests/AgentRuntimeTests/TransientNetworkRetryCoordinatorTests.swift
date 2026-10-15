import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: Distill turns keep dying with "[retryable:network] Distill network
/// failure: ... error decoding response body" and wait on a red Retry. A
/// transient network drop must resume the turn by itself, a bounded number
/// of times, and never retry auth/other failures.
final class TransientNetworkRetryCoordinatorTests: XCTestCase {
    static let realFailure = "[retryable:network] Distill network failure: Distill ACP RPC error: reqwest error stream: Transport error: error decoding response body"

    /// Fails with `failure` for the first `failures` starts, then completes.
    private final class FlakyRunner: AgentProviderRunner, @unchecked Sendable {
        let provider: AgentProvider = .codex
        let failure: String
        let failures: Int
        private let lock = NSLock()
        private var _requests: [AgentRunRequest] = []
        var requests: [AgentRunRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

        init(failure: String, failures: Int) {
            self.failure = failure
            self.failures = failures
        }

        func listModels() async -> [AgentModelDescriptor] { [] }

        func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
            lock.lock(); _requests.append(request); let attempt = _requests.count; lock.unlock()
            let providerThreadId = request.providerThreadId ?? "session-1"
            let fail = attempt <= failures
            let message = failure
            Task.detached {
                onEvent(.status(.running))
                onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
                onEvent(.event(.turnStarted(turnId: "t\(attempt)")))
                if fail {
                    onEvent(.error(message))
                    onEvent(.finished(.failed, finalMessage: nil, providerThreadId: providerThreadId))
                } else {
                    onEvent(.event(.turnCompleted(turnId: "t\(attempt)", finalMessage: "done")))
                    onEvent(.finished(.completed, finalMessage: "done", providerThreadId: providerThreadId))
                }
            }
            return AgentRunHandle(runId: request.runId, process: nil) {}
        }
    }

    private func start(_ runner: FlakyRunner) async throws -> (AgentRunCoordinator, AgentThread, AgentThreadRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-net-retry-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let thread = AgentThread(title: "net", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: AgentMessageRepository(db: db),
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        coordinator.networkRetryDelays = [0, 0, 0]
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: "do it"
        ))
        return (coordinator, thread, threadRepo)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func test_networkDropMidTurn_resumesOnTheSameSessionAndCompletes() async throws {
        let runner = FlakyRunner(failure: Self.realFailure, failures: 2)
        let (_, thread, threadRepo) = try await start(runner)

        await waitUntil { runner.requests.count >= 3 && (try? threadRepo.status(of: thread.id)) == .completed }

        XCTAssertEqual(runner.requests.count, 3, "two network failures, then the resumed turn completes")
        XCTAssertEqual(try threadRepo.status(of: thread.id), .completed)
        let resumed = runner.requests[1]
        XCTAssertEqual(resumed.providerThreadId, "session-1", "resume the same provider session")
        XCTAssertEqual(resumed.prompt, TransientNetworkRetry.prompt)
    }

    func test_persistentNetworkFailure_stopsAfterTheBound() async throws {
        let runner = FlakyRunner(failure: Self.realFailure, failures: 99)
        let (coordinator, thread, threadRepo) = try await start(runner)
        let expected = coordinator.networkRetryDelays.count + 1

        await waitUntil { runner.requests.count >= expected }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(runner.requests.count, expected, "never loops forever")
        XCTAssertEqual(try threadRepo.status(of: thread.id), .failed, "the Retry button stays for the user")
    }

    func test_nonNetworkFailure_isNotRetried() async throws {
        let runner = FlakyRunner(failure: "[auth-required] Distill authentication failed: 401", failures: 99)
        let (_, thread, threadRepo) = try await start(runner)

        await waitUntil { (try? threadRepo.status(of: thread.id)) == .failed }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(runner.requests.count, 1)
    }
}
