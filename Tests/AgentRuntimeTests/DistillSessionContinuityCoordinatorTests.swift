import XCTest
@testable import AgentRuntime
@testable import CoreModel
@testable import Persistence

/// WHY: Distill decides between `session/load` and a new session (with a
/// handoff) from facts only the coordinator can read across app restarts: which
/// model the persisted session really ran, whether the provider rejected its
/// history, and the thread's recent conversation. A send that reached the
/// adapter with the wrong facts replays foreign reasoning into Anthropic (HTTP
/// 400) or opens a new session that has lost the conversation.
final class DistillSessionContinuityCoordinatorTests: XCTestCase {
    private struct Store {
        let db: SQLiteDB
        let thread: AgentThread
        let sessionRepo: ProviderSessionRuntimeRepository
        let messageRepo: AgentMessageRepository
        let coordinator: AgentRunCoordinator
        let adapter: RecordingDistillAdapter
    }

    private func makeStore(priorMessages: Int) throws -> Store {
        let tmp = NSTemporaryDirectory() + "rc-distill-continuity-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        // As in the field: the user already picked Claude for the thread, while
        // the persisted Distill session S1 ran muse-spark.
        var thread = AgentThread(title: "desk", provider: .distill, model: "claude/claude-opus-5-5")
        thread.providerThreadId = "S1"
        try threadRepo.upsert(thread)
        // A row written before acceptance was recorded: only `model` says what S1 ran.
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .distill,
            status: .completed,
            resumeCursor: "S1",
            cwd: tmp,
            model: "muse-spark-1.3-contributor"
        ))
        for index in 0..<priorMessages {
            try messageRepo.append(AgentMessage(
                threadId: thread.id,
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "message \(index) " + String(repeating: "x", count: 1_000)
            ))
        }
        let adapter = RecordingDistillAdapter()
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providerAdapters: [.distill: adapter]
        )
        return Store(db: db, thread: thread, sessionRepo: sessionRepo, messageRepo: messageRepo,
                     coordinator: coordinator, adapter: adapter)
    }

    private func send(_ store: Store, model: String, cursor: String, prompt: String) async throws -> AgentRunRequest {
        let before = store.adapter.requests.count
        _ = try await store.coordinator.startRun(AgentRunRequest(
            threadId: store.thread.id,
            provider: .distill,
            model: model,
            cwd: NSTemporaryDirectory(),
            prompt: prompt,
            providerThreadId: cursor
        ))
        try await waitUntil { store.adapter.requests.count > before }
        try await waitUntil { store.coordinator.activeRunId(threadId: store.thread.id) == nil }
        return try XCTUnwrap(store.adapter.requests.last)
    }

    func test_crossFamilySendCarriesPriorModelAndNewestTailOfALongThread() async throws {
        // 150 messages of ~1 KB: past both RCSEED limits (100 items, 64 KB), so
        // `contextSnapshot` is nil and only the tail can carry the conversation.
        let store = try makeStore(priorMessages: 150)
        XCTAssertNil(ConversationContextSnapshot.capture(
            messages: try store.messageRepo.list(threadId: store.thread.id),
            excludingCurrentUserText: nil
        ), "precondition: the RCSEED snapshot gives up on a thread this long")
        store.adapter.script = { _, onEvent in
            onEvent(.finished(.completed, finalMessage: "ok", providerThreadId: "S1"))
        }

        let request = try await send(store, model: "claude/claude-opus-5-5", cursor: "S1", prompt: "switch now")

        XCTAssertEqual(request.priorProviderSessionModel, "muse-spark-1.3-contributor",
                       "the adapter must see the model S1 ran, not the model this send requested")
        XCTAssertFalse(request.priorProviderSessionRetired)
        let tail = try XCTUnwrap(request.priorConversationTail, "a cross-family send must carry the conversation tail")
        XCTAssertTrue(tail.last?.content.hasPrefix("message 149 ") == true, "the newest prior message must be handed off")
        XCTAssertFalse(tail.contains { $0.content == "switch now" }, "the current prompt is sent once, as the prompt")
        XCTAssertGreaterThan(tail.count, DistillACPAdapter.handoffMaxMessages,
                             "one extra row tells the handoff that older messages exist")
        let handoff = DistillACPAdapter.handoffHistory(for: request)
        XCTAssertTrue(handoff.olderHistoryExists)
        XCTAssertEqual(handoff.messages.count, DistillACPAdapter.handoffMaxMessages)
    }

    func test_failedSwitchBeforeAcceptanceDoesNotRelabelTheOldSession() async throws {
        // WHY: the pending upsert writes the REQUESTED model into `model`. When the
        // switch attempt fails before Distill accepts its prompt, the cursor still
        // points at the muse-spark session; the next send must still see a
        // cross-family switch instead of `session/load` + 400.
        let store = try makeStore(priorMessages: 2)
        store.adapter.script = { _, onEvent in
            onEvent(.error("Distill ACP failure: spawn interrupted"))
            onEvent(.finished(.failed, finalMessage: nil, providerThreadId: "S1"))
        }
        _ = try await send(store, model: "claude/claude-opus-5-5", cursor: "S1", prompt: "first try")
        XCTAssertEqual(try store.sessionRepo.sessionModel(of: store.thread.id, resumeCursor: "S1"),
                       "claude/claude-opus-5-5", "precondition: the `model` column now names the failed request")

        store.adapter.script = { _, onEvent in
            onEvent(.finished(.completed, finalMessage: "ok", providerThreadId: "S1"))
        }
        let retry = try await send(store, model: "claude/claude-opus-5-5", cursor: "S1", prompt: "second try")
        XCTAssertEqual(retry.priorProviderSessionModel, "muse-spark-1.3-contributor")
        XCTAssertNotNil(retry.priorConversationTail)
    }

    func test_acceptedSessionModelAndRejectedHistorySurviveForTheNextSend() async throws {
        // WHY: after a switch, S2 ran Claude; a later Claude send must load it
        // (no handoff). Once the provider rejects S2's history, Retry — after a
        // restart too — must open a new session, so the rejection is persisted.
        let store = try makeStore(priorMessages: 2)
        store.adapter.script = { _, onEvent in
            onEvent(.event(.threadStarted(threadId: "S2", providerThreadId: "S2")))
            onEvent(.event(Self.sessionState(["sessionId": "S2", "acceptedModel": "claude/claude-opus-5-5"])))
            onEvent(.finished(.completed, finalMessage: "ok", providerThreadId: "S2"))
        }
        _ = try await send(store, model: "claude/claude-opus-5-5", cursor: "S1", prompt: "switch")

        store.adapter.script = { _, onEvent in
            onEvent(.event(Self.sessionState(["sessionId": "S2", "historyRejected": true])))
            onEvent(.error("[fresh-session:incompatible-history] The model rejected this Distill session's history"))
            onEvent(.finished(.failed, finalMessage: nil, providerThreadId: "S2"))
        }
        let sameFamily = try await send(store, model: "claude/claude-opus-5-5", cursor: "S2", prompt: "follow up")
        XCTAssertEqual(sameFamily.priorProviderSessionModel, "claude/claude-opus-5-5")
        XCTAssertFalse(sameFamily.priorProviderSessionRetired)
        XCTAssertNil(sameFamily.priorConversationTail, "a same-family send resumes S2 and needs no handoff")

        store.adapter.script = { _, onEvent in
            onEvent(.finished(.completed, finalMessage: "ok", providerThreadId: "S3"))
        }
        let retry = try await send(store, model: "claude/claude-opus-5-5", cursor: "S2", prompt: "retry")
        XCTAssertTrue(retry.priorProviderSessionRetired, "a rejected session must never be loaded again")
        XCTAssertNotNil(retry.priorConversationTail, "the replacement session needs the handoff")
    }

    private static func sessionState(_ state: [String: Any]) -> AssistantEvent {
        let data = try! JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        return .providerRuntime(ProviderRuntimeEvent(
            provider: .distill,
            source: "remotecode.distill",
            method: ProviderRuntimeEvent.distillSessionStateMethod,
            payloadJSON: String(decoding: data, as: UTF8.self),
            receivedAtMs: 0
        ))
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class RecordingDistillAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider = .distill
    private let lock = NSLock()
    private var _requests: [AgentRunRequest] = []
    private var _script: (@Sendable (AgentRunRequest, @escaping @Sendable (AgentRunEvent) -> Void) -> Void)?
    var requests: [AgentRunRequest] { lock.withLock { _requests } }
    var script: (@Sendable (AgentRunRequest, @escaping @Sendable (AgentRunEvent) -> Void) -> Void)? {
        get { lock.withLock { _script } }
        set { lock.withLock { _script = newValue } }
    }

    func listModels() async -> [AgentModelDescriptor] { [] }
    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }
    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        if let permit = request.acceptancePermit {
            try permit.withAcceptance { lock.withLock { _requests.append(request) } }
        } else {
            lock.withLock { _requests.append(request) }
        }
        onEvent(.status(.running))
        script?(request, onEvent)
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func interruptTurn(threadId: AgentThreadID) throws {}
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {}
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {}
    func stopSession(threadId: AgentThreadID) throws {}
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] { [] }
    func hasSession(threadId: AgentThreadID) -> Bool { false }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}
}
