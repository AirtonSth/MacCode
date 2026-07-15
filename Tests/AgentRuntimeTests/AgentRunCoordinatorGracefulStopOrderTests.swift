import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

final class AgentRunCoordinatorGracefulStopOrderTests: XCTestCase {
    func test_stopDeliversProviderInterruptBeforeBoundedHandleFallback() async throws {
        let path = NSTemporaryDirectory() + "rc-stop-order-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: path).run()
        let threadRepo = AgentThreadRepository(db: db)
        let thread = AgentThread(title: "graceful stop", provider: .claude, model: "claude")
        try threadRepo.upsert(thread)
        let adapter = OrderedStopAdapter()
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: AgentMessageRepository(db: db),
            threadRepo: threadRepo,
            providerAdapters: [.claude: adapter]
        )
        coordinator.gracefulStopTimeout = 0.05

        let runId = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .claude,
            model: "claude",
            cwd: path,
            prompt: "long task"
        ))
        coordinator.stopRun(runId)

        XCTAssertEqual(
            adapter.events,
            ["interrupt"],
            "Stop must leave the live transport open after delivering Claude's native interrupt"
        )
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(
            adapter.events,
            ["interrupt", "cancel"],
            "an unacknowledged interrupt must receive the bounded cancel/kill fallback"
        )
    }
}

private final class OrderedStopAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider = .claude
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private var threadId: AgentThreadID?

    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedEvents
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
        lock.lock(); threadId = request.threadId; lock.unlock()
        onEvent(.status(.running))
        return AgentRunHandle(runId: request.runId, process: nil) { [weak self] in
            self?.record("cancel")
        }
    }

    func interruptTurn(threadId: AgentThreadID) throws { record("interrupt") }
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
        throw AgentProviderAdapterError.unsupported("test")
    }
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        throw AgentProviderAdapterError.unsupported("test")
    }
    func stopSession(threadId: AgentThreadID) throws { record("stopSession") }
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] {
        guard let threadId else { return [] }
        return [AgentProviderSessionSummary(
            threadId: threadId,
            provider: .claude,
            status: .running,
            providerThreadId: "provider-thread"
        )]
    }
    func hasSession(threadId: AgentThreadID) -> Bool { self.threadId == threadId }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}

    private func record(_ value: String) {
        lock.lock(); recordedEvents.append(value); lock.unlock()
    }
}
