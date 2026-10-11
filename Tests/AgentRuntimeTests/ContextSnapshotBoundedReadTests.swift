import XCTest
@testable import AgentRuntime
@testable import CoreModel
@testable import Persistence

/// WHY: every Agent App and Bot send captures the prior conversation before the
/// provider starts. A thread over the seed bound has no snapshot, so hydrating
/// all of its rows only delays the run. The bounded read must still hand the
/// provider exactly the snapshot a whole-thread read would: a seed built from a
/// partial window would teach a fresh session a truncated history.
///
/// Scope: `AgentMessageRepository.append` already prunes a thread to its
/// newest 100 rows, below the 102-row window, so a thread written through it
/// reads the same rows as before. The over-bound counts below describe only a
/// thread left over 100 rows from before that cap, on its first send. They
/// guard the bound; they are not a speed gain for today's threads.
final class ContextSnapshotBoundedReadTests: XCTestCase {
    func test_longThreadWithStoredCurrentTurnReadsOneBoundedWindow() async throws {
        // WHY: a Bot send stores the Human row before the run starts, so the
        // window must hold that row and still prove the thread is over the bound.
        let f = try makeFixture()
        for index in 0..<500 {
            try f.insert(role: index.isMultiple(of: 2) ? .user : .assistant, content: "turn \(index)")
        }
        let runId = AgentRunID()
        try f.insert(id: runId.value, role: .user, content: "teammate line")
        let reads = f.observeReads()

        _ = try await f.coordinator.startRun(
            f.request(runId: runId, prompt: "compiled provider envelope"),
            recordUserMessage: false
        )

        let started = try XCTUnwrap(f.adapter.request, "the run must reach the provider")
        XCTAssertNil(started.contextSnapshot, "a thread over the seed bound has no snapshot")
        XCTAssertEqual(reads.wholeThreadReads, 0, "an over-bound thread must not be hydrated whole")
        XCTAssertEqual(reads.windowReads, 1, "no snapshot means no second, verifying read")
        // One step per row plus the step that ends the statement.
        XCTAssertGreaterThan(reads.bodySteps, 0, "the step filter must still match the message read")
        XCTAssertLessThanOrEqual(reads.bodySteps, ConversationContextSnapshot.boundedReadLimit + 1)
    }

    func test_longThreadBeforeCurrentTurnIsStoredReadsOneBoundedWindow() async throws {
        // WHY: an Agent App send captures before it stores the user row. The
        // same bound applies with no current row in the window.
        let f = try makeFixture()
        for index in 0..<500 {
            try f.insert(role: index.isMultiple(of: 2) ? .user : .assistant, content: "turn \(index)")
        }
        let reads = f.observeReads()

        _ = try await f.coordinator.startRun(f.request(runId: AgentRunID(), prompt: "next question"))

        let started = try XCTUnwrap(f.adapter.request, "the run must reach the provider")
        XCTAssertNil(started.contextSnapshot, "a thread over the seed bound has no snapshot")
        XCTAssertEqual(reads.wholeThreadReads, 0, "an over-bound thread must not be hydrated whole")
        XCTAssertEqual(reads.windowReads, 1, "no snapshot means no second, verifying read")
        XCTAssertGreaterThan(reads.bodySteps, 0, "the step filter must still match the message read")
        XCTAssertLessThanOrEqual(reads.bodySteps, ConversationContextSnapshot.boundedReadLimit + 1)
    }

    func test_threadAtTheItemBoundKeepsTheIdenticalSnapshotAndSeed() async throws {
        // WHY: the largest conversation that still fits must reach the provider
        // unchanged. A window one row short would drop it or cut its oldest turn.
        let f = try makeFixture()
        for index in 0..<ConversationContextSeed.maxItems {
            try f.insert(role: index.isMultiple(of: 2) ? .user : .assistant, content: "turn \(index)")
        }
        let runId = AgentRunID()
        try f.insert(id: runId.value, role: .user, content: "teammate line")
        let expected = try XCTUnwrap(ConversationContextSnapshot.capture(
            messages: try f.messageRepo.list(threadId: f.thread.id),
            excludingCurrentUserText: "compiled provider envelope",
            excludingCurrentUserMessageId: AgentMessageID(runId.value)
        ))
        XCTAssertEqual(expected.items.count, ConversationContextSeed.maxItems)
        let reads = f.observeReads()

        _ = try await f.coordinator.startRun(
            f.request(runId: runId, prompt: "compiled provider envelope"),
            recordUserMessage: false
        )

        let snapshot = try XCTUnwrap(f.adapter.request?.contextSnapshot)
        XCTAssertEqual(snapshot, expected)
        let seed = try XCTUnwrap(ConversationContextSeed.prepare(snapshot: snapshot))
        XCTAssertEqual(seed.encoded, ConversationContextSeed.prepare(snapshot: expected)?.encoded)
        XCTAssertEqual(reads.wholeThreadReads, 0, "a thread that fits the window needs no whole-thread read")
        XCTAssertEqual(reads.windowReads, 2, "capture and its verification each read one window")
    }

    func test_systemRowsFillingTheWindowFallBackToTheWholeThread() async throws {
        // WHY: system rows are not seed items, so a full window of them cannot
        // prove the thread is over the bound. Deciding from the window alone
        // would seed a fresh session with a history missing its oldest turns.
        let f = try makeFixture()
        for index in 0..<60 {
            try f.insert(role: index.isMultiple(of: 2) ? .user : .assistant, content: "turn \(index)")
        }
        for index in 0..<50 {
            try f.insert(role: .system, content: "notice \(index)")
        }
        let runId = AgentRunID()
        try f.insert(id: runId.value, role: .user, content: "teammate line")
        let expected = try XCTUnwrap(ConversationContextSnapshot.capture(
            messages: try f.messageRepo.list(threadId: f.thread.id),
            excludingCurrentUserText: "compiled provider envelope",
            excludingCurrentUserMessageId: AgentMessageID(runId.value)
        ))
        XCTAssertEqual(expected.items.count, 60)
        let reads = f.observeReads()

        _ = try await f.coordinator.startRun(
            f.request(runId: runId, prompt: "compiled provider envelope"),
            recordUserMessage: false
        )

        XCTAssertEqual(f.adapter.request?.contextSnapshot, expected)
        XCTAssertEqual(reads.windowReads, 2, "capture and its verification each try the window first")
        XCTAssertEqual(reads.wholeThreadReads, 2, "an undecided window is settled by the whole thread")
    }

    private func makeFixture() throws -> Fixture {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let thread = AgentThread(title: "bounded-read", provider: .codex, model: "gpt-test")
        try threadRepo.upsert(thread)
        let adapter = BoundedReadCapturingAdapter()
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerAdapters: [.codex: adapter]
        )
        return Fixture(db: db, messageRepo: messageRepo, thread: thread, adapter: adapter, coordinator: coordinator)
    }
}

private final class Fixture {
    let db: SQLiteDB
    let messageRepo: AgentMessageRepository
    let thread: AgentThread
    let adapter: BoundedReadCapturingAdapter
    let coordinator: AgentRunCoordinator
    private let formatter = ISO8601DateFormatter()
    private var inserted = 0

    init(
        db: SQLiteDB,
        messageRepo: AgentMessageRepository,
        thread: AgentThread,
        adapter: BoundedReadCapturingAdapter,
        coordinator: AgentRunCoordinator
    ) {
        self.db = db
        self.messageRepo = messageRepo
        self.thread = thread
        self.adapter = adapter
        self.coordinator = coordinator
    }

    /// Writes the row directly: `AgentMessageRepository.append` prunes a thread
    /// to its newest 100 rows, so it cannot build a thread over the seed bound.
    func insert(id: UUID = UUID(), role: AgentMessageRole, content: String) throws {
        let st = try db.prepare("""
            INSERT INTO agent_messages(id, thread_id, role, content, created_at, attachments_json)
            VALUES(?, ?, ?, ?, ?, '[]');
            """)
        try st.bind(1, id.uuidString)
        try st.bind(2, thread.id.value.uuidString)
        try st.bind(3, role.rawValue)
        try st.bind(4, content)
        try st.bind(5, formatter.string(from: Date(timeIntervalSince1970: 1_780_000_000 + Double(inserted))))
        _ = try st.step()
        inserted += 1
    }

    func request(runId: AgentRunID, prompt: String) -> AgentRunRequest {
        AgentRunRequest(
            runId: runId,
            threadId: thread.id,
            provider: .codex,
            model: "gpt-test",
            cwd: "/tmp/context-bounded-read",
            prompt: prompt
        )
    }

    /// Counts message reads from this point on.
    func observeReads() -> ReadObservation {
        let observation = ReadObservation(messageRepo: messageRepo)
        db.beforeStatementStepForTesting = { observation.recordStep($0) }
        return observation
    }
}

private final class ReadObservation: @unchecked Sendable {
    private let messageRepo: AgentMessageRepository
    private let wholeThreadReadsBefore: Int
    private let windowReadsBefore: Int
    private let lock = NSLock()
    private var _bodySteps = 0

    init(messageRepo: AgentMessageRepository) {
        self.messageRepo = messageRepo
        wholeThreadReadsBefore = messageRepo.fullListCountForTesting
        windowReadsBefore = messageRepo.listRecentCountForTesting
    }

    var wholeThreadReads: Int { messageRepo.fullListCountForTesting - wholeThreadReadsBefore }
    var windowReads: Int { messageRepo.listRecentCountForTesting - windowReadsBefore }
    /// Steps of statements that hydrate a thread's message bodies.
    var bodySteps: Int { lock.withLock { _bodySteps } }

    func recordStep(_ sql: String) {
        guard sql.contains("content"), sql.contains("FROM agent_messages WHERE thread_id = ?") else { return }
        lock.withLock { _bodySteps += 1 }
    }
}

private final class BoundedReadCapturingAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let lock = NSLock()
    private var _request: AgentRunRequest?
    var request: AgentRunRequest? { lock.withLock { _request } }

    func listModels() async -> [AgentModelDescriptor] { [] }
    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }
    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        if let permit = request.acceptancePermit {
            try permit.withAcceptance { lock.withLock { _request = request } }
        } else {
            lock.withLock { _request = request }
        }
        onEvent(.status(.running))
        onEvent(.finished(.completed, finalMessage: "ok", providerThreadId: "t"))
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
