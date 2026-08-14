import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// Provider runner that records the exact prompt it was handed, so we can prove
/// the Token Saver compression hook transforms the *outbound* prompt while the
/// *displayed* user message stays the original.
private final class PromptCapturingRunner: AgentProviderRunner, @unchecked Sendable {
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

private final class ScriptedFinalRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    let finalMessage: String

    init(provider: AgentProvider, finalMessage: String) {
        self.provider = provider
        self.finalMessage = finalMessage
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let handle = AgentRunHandle(runId: request.runId, process: nil) {}
        let finalMessage = self.finalMessage
        Task.detached {
            try? await Task.sleep(nanoseconds: 20_000_000)
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            let turnId = "turn-final"
            let itemId = "assistant-final"
            onEvent(.status(.running))
            onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            onEvent(.event(.turnStarted(turnId: turnId)))
            onEvent(.event(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .assistantMessage, startedAtMs: 0))))
            onEvent(.event(.itemDelta(itemId: itemId, bodyAppend: finalMessage, outputAppend: nil, summary: nil)))
            onEvent(.event(.itemCompleted(itemId: itemId, finalState: .completed)))
            onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: finalMessage)))
            onEvent(.finished(.completed, finalMessage: finalMessage, providerThreadId: providerThreadId))
        }
        return handle
    }
}

private final class ScriptedStreamRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    let itemType: AssistantItemType
    let bodyChunks: [String]
    let output: String?
    let finalMessage: String

    init(
        provider: AgentProvider,
        itemType: AssistantItemType = .assistantMessage,
        body: String,
        output: String? = nil,
        finalMessage: String = "done"
    ) {
        self.provider = provider
        self.itemType = itemType
        self.bodyChunks = body.isEmpty ? [] : [body]
        self.output = output
        self.finalMessage = finalMessage
    }

    init(provider: AgentProvider, bodyChunks: [String], finalMessage: String = "done") {
        self.provider = provider
        self.itemType = .assistantMessage
        self.bodyChunks = bodyChunks
        self.output = nil
        self.finalMessage = finalMessage
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let handle = AgentRunHandle(runId: request.runId, process: nil) {}
        let providerThreadId = request.providerThreadId ?? UUID().uuidString
        let itemType = self.itemType
        let bodyChunks = self.bodyChunks
        let output = self.output
        let finalMessage = self.finalMessage
        Task.detached {
            let turnId = "turn-stream"
            let itemId = "stream-item"
            onEvent(.status(.running))
            onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            onEvent(.event(.turnStarted(turnId: turnId)))
            onEvent(.event(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: itemType,
                startedAtMs: 0
            ))))
            for chunk in bodyChunks {
                onEvent(.event(.itemDelta(itemId: itemId, bodyAppend: chunk, outputAppend: nil, summary: nil)))
            }
            if let output {
                onEvent(.event(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: output, summary: "Reasoning")))
            }
            onEvent(.event(.itemCompleted(itemId: itemId, finalState: .completed)))
            onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: finalMessage)))
            onEvent(.finished(.completed, finalMessage: finalMessage, providerThreadId: providerThreadId))
        }
        return handle
    }
}

private final class RecordingObserver: AgentRunObserver {
    private let lock = NSLock()
    private var events: [AssistantEvent] = []

    var recordedEvents: [AssistantEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func runCoordinator(_ c: AgentRunCoordinator, didReceive event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func runCoordinator(_ c: AgentRunCoordinator, didFinish runId: AgentRunID, threadId: AgentThreadID, status: AgentRunStatus, finalMessage: String?, providerThreadId: String?) {}

    func runCoordinator(_ c: AgentRunCoordinator, didChangeStatus status: AgentRunStatus, runId: AgentRunID, threadId: AgentThreadID) {}
}

private final class UserInputCapturingAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private(set) var capturedUserInput: (threadId: AgentThreadID, requestId: String, verbatimText: String, outboundText: String)?

    init(provider: AgentProvider = .claude) {
        self.provider = provider
    }

    func listModels() async -> [AgentModelDescriptor] { [] }
    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }
    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func interruptTurn(threadId: AgentThreadID) throws {}
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {}
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        try respondToUserInput(threadId: threadId, requestId: requestId, verbatimText: text, outboundText: text)
    }
    func respondToUserInput(threadId: AgentThreadID, requestId: String, verbatimText: String, outboundText: String) throws {
        lock.lock()
        capturedUserInput = (threadId, requestId, verbatimText, outboundText)
        lock.unlock()
    }
    func stopSession(threadId: AgentThreadID) throws {}
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] { [] }
    func hasSession(threadId: AgentThreadID) -> Bool { true }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}
}

private final class ScopeRefreshingAdapter: AgentProviderAdapter, @unchecked Sendable {
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
    /// without a durable provider thread id (the pre-continuity Token Saver case).
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

private extension AssistantEvent {
    var bodyAppendForTest: String? {
        if case .itemDelta(_, let bodyAppend, _, _) = self {
            return bodyAppend
        }
        return nil
    }

    var outputAppendForTest: String? {
        if case .itemDelta(_, _, let outputAppend, _) = self {
            return outputAppend
        }
        return nil
    }

    var turnCompletedFinalMessageForTest: String? {
        if case .turnCompleted(_, let finalMessage) = self {
            return finalMessage
        }
        return nil
    }
}

final class TokenSaverCompressionTests: XCTestCase {
    private func makeCoordinator() throws -> (AgentRunCoordinator, AgentMessageRepository, AgentThread, String, PromptCapturingRunner) {
        let tmp = NSTemporaryDirectory() + "rc2-ts-compress-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "t", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = PromptCapturingRunner(provider: .codex)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        return (coordinator, messageRepo, thread, tmp, runner)
    }

    private func waitForPrompt(_ runner: PromptCapturingRunner) async {
        await runner.waitForPromptCapture()
    }

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

    func test_reusedProviderSessionsRefreshExactTurnScopeForClaudeCodexAndGrok() async throws {
        // WHY: a resident provider process cannot mutate its environment. Every
        // Token Saver attempt must launch with the current exact scope while the
        // provider thread id preserves conversation continuity.
        for provider in [AgentProvider.claude, .codex, .grok] {
            let tmp = NSTemporaryDirectory() + "rc2-ts-scope-refresh-" + provider.rawValue + "-" + UUID().uuidString
            let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
            let threadRepo = AgentThreadRepository(db: db)
            let messageRepo = AgentMessageRepository(db: db)
            let runRepo = AgentRunRepository(db: db)
            let thread = AgentThread(title: "scope", provider: provider, model: "test")
            try threadRepo.upsert(thread)
            let adapter = ScopeRefreshingAdapter(provider: provider)
            let coordinator = AgentRunCoordinator(
                runRepo: runRepo,
                messageRepo: messageRepo,
                threadRepo: threadRepo,
                providerAdapters: [provider: adapter]
            )
            coordinator.runEnvironmentProvider = { selectedProvider, selectedThread, _ in
                [
                    "RC_TOKEN_SAVER_DISTILL_HINT": "1",
                    "RC_TOKEN_SAVER_WORKSPACE_ID": "workspace-2",
                    "RC_TOKEN_SAVER_PROJECT_ID": "project-2",
                    "RC_TOKEN_SAVER_THREAD_ID": selectedThread.value.uuidString,
                    "REMOTE_CODE_AGENT_PROVIDER": selectedProvider.rawValue,
                ]
            }
            coordinator.promptCompressor = { prompt, _, _, _ in
                guard prompt == "first" else { return prompt }
                return "RCW1\tQ\t1\nG\tfirst\n.\n"
            }

            let firstRunID = AgentRunID()
            _ = try await coordinator.startRun(.init(
                runId: firstRunID,
                threadId: thread.id,
                provider: provider,
                model: "test",
                cwd: tmp,
                prompt: "first"
            ))
            try await waitForRun(firstRunID, in: runRepo)

            let continuedThread = try XCTUnwrap(try threadRepo.get(id: thread.id))
            let providerThreadID = try XCTUnwrap(continuedThread.providerThreadId)
            let secondRunID = AgentRunID()
            _ = try await coordinator.startRun(.init(
                runId: secondRunID,
                threadId: thread.id,
                provider: provider,
                model: "test",
                cwd: tmp,
                prompt: "second",
                providerThreadId: providerThreadID
            ))
            try await waitForRun(secondRunID, in: runRepo)

            XCTAssertEqual(adapter.requests.count, 2, "\(provider.rawValue) must execute both turns")
            XCTAssertEqual(adapter.requests[0].environment["RC_TOKEN_SAVER_WIRE_VERSION"], "1",
                           "\(provider.rawValue) must atomically admit RCW1 for the encoded turn")
            XCTAssertNil(adapter.requests[1].environment["RC_TOKEN_SAVER_WIRE_VERSION"],
                         "\(provider.rawValue) must explicitly reset wire admission when the next turn bypasses encoding")
            XCTAssertTrue(RCWireProtocol.isWire(adapter.requests[0].prompt))
            XCTAssertEqual(adapter.requests[1].prompt, "second")
            let firstEnvironment = adapter.requests[0].environment
            let secondEnvironment = adapter.requests[1].environment
            XCTAssertEqual(firstEnvironment["RC_TOKEN_SAVER_ATTEMPT_ID"], firstRunID.value.uuidString)
            XCTAssertEqual(secondEnvironment["RC_TOKEN_SAVER_ATTEMPT_ID"], secondRunID.value.uuidString)
            XCTAssertNotEqual(firstEnvironment["RC_TOKEN_SAVER_ATTEMPT_ID"], secondEnvironment["RC_TOKEN_SAVER_ATTEMPT_ID"])
            XCTAssertEqual(adapter.retiredEnvironments, [firstEnvironment], "\(provider.rawValue) must deny reuse of the run-1 process scope")
            XCTAssertEqual(adapter.requests[1].providerThreadId, providerThreadID, "\(provider.rawValue) must preserve provider conversation continuity")
        }
    }

    func test_startRun_refusesStaleTokenSaverScopeWhenLiveSessionLacksDurableProviderThreadId() async throws {
        // WHY: provider process env is immutable after launch. A live adapter
        // session with no durable providerThreadId has no safe resume handle, so
        // a new Token Saver admission scope cannot reuse that process (wrong
        // workspace/project/attempt isolation) and also cannot stop+restart it
        // without losing continuity. Refuse the run instead of silently reusing
        // or incorrectly tearing down the stale session.
        let tmp = NSTemporaryDirectory() + "rc2-ts-scope-refuse-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "stale-scope", provider: .claude, model: "test")
        try threadRepo.upsert(thread)

        let adapter = ScopeRefreshingAdapter(provider: .claude)
        // Live idle session, no durable provider continuity id, no prior coordinator scope.
        adapter.seedIdleSession(threadId: thread.id, providerThreadId: nil, status: .completed)
        XCTAssertTrue(adapter.hasSession(threadId: thread.id))

        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerAdapters: [.claude: adapter]
        )
        coordinator.runEnvironmentProvider = { selectedProvider, selectedThread, _ in
            [
                "RC_TOKEN_SAVER_DISTILL_HINT": "1",
                "RC_TOKEN_SAVER_WORKSPACE_ID": "workspace-new",
                "RC_TOKEN_SAVER_PROJECT_ID": "project-new",
                "RC_TOKEN_SAVER_THREAD_ID": selectedThread.value.uuidString,
                "REMOTE_CODE_AGENT_PROVIDER": selectedProvider.rawValue,
            ]
        }

        let safetyMessage =
            "Provider process scope changed before a durable provider thread id was available; refusing to reuse stale Token Saver scope."

        do {
            _ = try await coordinator.startRun(.init(
                threadId: thread.id,
                provider: .claude,
                model: "test",
                cwd: tmp,
                prompt: "must not reuse stale scope",
                providerThreadId: nil
            ))
            XCTFail("startRun must refuse when Token Saver scope arrives against a live session without durable providerThreadId")
        } catch let error as AgentProviderAdapterError {
            guard case .unsupported(let detail) = error else {
                return XCTFail("expected .unsupported safety refusal, got \(error)")
            }
            XCTAssertEqual(detail, safetyMessage,
                           "refusal must carry the exact stale Token Saver scope safety intent")
        }

        XCTAssertTrue(adapter.hasSession(threadId: thread.id),
                      "refusal must leave the resident session in place — stopping without a resume handle drops continuity incorrectly")
        XCTAssertEqual(adapter.stopSessionCalls, 0,
                       "must not stopSession on scope refusal without a durable providerThreadId")
        XCTAssertTrue(adapter.requests.isEmpty,
                      "must not reuse the stale live session by sending a turn under the new Token Saver scope")
        XCTAssertTrue(adapter.retiredEnvironments.isEmpty)
        XCTAssertNil(try threadRepo.get(id: thread.id)?.providerThreadId,
                     "coordinator must not invent a providerThreadId when continuity was never established")
    }

    func test_promptCompressorTransformsOutboundButPreservesDisplayedMessage() async throws {
        let (coordinator, messageRepo, thread, tmp, runner) = try makeCoordinator()
        coordinator.promptCompressor = { prompt, _, _, _ in "COMPRESSED::" + prompt.uppercased() }
        coordinator.runEnvironmentProvider = { _, _, _ in
            [
                "RC_TOKEN_SAVER_DISTILL_HINT": "1",
                "RC_TOKEN_SAVER_WORKSPACE_ID": "workspace",
                "RC_TOKEN_SAVER_PROJECT_ID": "project",
                "RC_TOKEN_SAVER_THREAD_ID": thread.id.value.uuidString,
            ]
        }

        let original = "Please refactor the widget renderer in file Foo.swift, keep ID abc-123"
        let runID = AgentRunID()
        _ = try await coordinator.startRun(AgentRunRequest(
            runId: runID, threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: original
        ))
        await waitForPrompt(runner)

        XCTAssertEqual(runner.capturedPrompt, "COMPRESSED::" + original.uppercased(),
                       "the provider must receive the compressed prompt")
        XCTAssertEqual(runner.capturedEnvironment["RC_TOKEN_SAVER_ATTEMPT_ID"], runID.value.uuidString)
        let messages = (try? messageRepo.list(threadId: thread.id)) ?? []
        XCTAssertEqual(messages.first(where: { $0.role == .user })?.content, original,
                       "the displayed user message must remain the original, uncompressed text")
    }

    func test_followUpCompressorTransformsOutboundButPreservesVerbatimAnswer() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-followup-compress-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "follow-up", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let adapter = UserInputCapturingAdapter(provider: .claude)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerAdapters: [.claude: adapter]
        )
        coordinator.promptCompressor = { _, _, _, _ in
            XCTFail("free-form follow-up answers should use followUpPromptCompressor when present")
            return "WRONG"
        }
        coordinator.followUpPromptCompressor = { prompt, provider, threadId in
            XCTAssertEqual(provider, .claude)
            XCTAssertEqual(threadId, thread.id)
            return "COMPRESSED::" + prompt
        }

        let original = "Here is a long follow-up stack trace at /tmp/Foo.swift:42 with error code 17"
        try await coordinator.respondToUserInput(threadId: thread.id, requestId: "free-form-1", text: original)

        XCTAssertEqual(adapter.capturedUserInput?.verbatimText, original,
                       "UI/history must preserve the exact user answer")
        XCTAssertEqual(adapter.capturedUserInput?.outboundText, "COMPRESSED::" + original,
                       "free-form follow-up dispatch must use the compressed outbound text")
    }

    func test_noCompressorSendsOriginalUnchanged() async throws {
        let (coordinator, messageRepo, thread, tmp, runner) = try makeCoordinator()
        // No promptCompressor set → Token Saver inactive → verbatim passthrough.
        let original = "build the project and run the tests"
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: original
        ))
        await waitForPrompt(runner)

        XCTAssertEqual(runner.capturedPrompt, original)
        let messages = (try? messageRepo.list(threadId: thread.id)) ?? []
        XCTAssertEqual(messages.first(where: { $0.role == .user })?.content, original)
    }

    func test_failOpenCompressorReturningInputLeavesPromptIntact() async throws {
        let (coordinator, messageRepo, thread, tmp, runner) = try makeCoordinator()
        // Fail-open contract: compressor returns its input on any failure.
        coordinator.promptCompressor = { prompt, _, _, _ in prompt }
        let original = "explain this stack trace and fix the crash"
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: original
        ))
        await waitForPrompt(runner)

        XCTAssertEqual(runner.capturedPrompt, original)
        let messages = (try? messageRepo.list(threadId: thread.id)) ?? []
        XCTAssertEqual(messages.first(where: { $0.role == .user })?.content, original)
    }

    func test_wireFinalResponseIsRenderedBeforePersistenceAndKeepsRawMetadata() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-response-humanize-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let wire = "RCW1\tA\t1\nO\tSaved counter updated.\nE\tmacOS suite passed.\n.\n"
        let runner = ScriptedFinalRunner(provider: .claude, finalMessage: wire)
        let thread = AgentThread(title: "wire", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.claude: runner]
        )

        let rendered = "Tests passed and the saved-token counter was updated."
        coordinator.finalResponseTranslator = { response, provider, threadId, _ in
            XCTAssertEqual(provider, .claude)
            XCTAssertEqual(threadId, thread.id)
            XCTAssertTrue(RCWireProtocol.isWire(response))
            return rendered
        }

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            cwd: tmp,
            prompt: "Explain the result."
        ))
        let assistant = try await waitForAssistantMessage(messageRepo, threadId: thread.id)

        XCTAssertEqual(assistant.content, rendered,
                       "the transcript must persist readable text, not provider wire")
        XCTAssertFalse(assistant.content.contains("RCW1"))
        let translation = try await waitForWireTranslation(
            coordinator,
            threadId: thread.id,
            messageId: assistant.id.value.uuidString
        )
        XCTAssertEqual(translation.originalText, wire,
                       "persisted stream replay must retain the original provider wire for disclosure")
        XCTAssertEqual(translation.rewrittenText, rendered)
    }

    func test_providerPreambleBeforeWireIsRenderedWithoutTransportLeak() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-response-preamble-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let wire = "RCW1\tA\t1\nO\tThe provider matrix passed.\nE\tClaude exited 0.\n.\n"
        let raw = "Response in the requested RCW1 frame:\n\n" + wire
        let runner = ScriptedFinalRunner(provider: .claude, finalMessage: raw)
        let thread = AgentThread(title: "wire preamble", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.claude: runner]
        )

        let rendered = "The provider matrix passed. Claude exited 0."
        coordinator.finalResponseTranslator = { response, _, _, _ in
            XCTAssertEqual(response, wire.trimmingCharacters(in: .whitespacesAndNewlines),
                           "the local renderer must receive only the strict frame payload")
            return rendered
        }

        _ = try await coordinator.startRun(.init(
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            cwd: tmp,
            prompt: "Run the provider matrix."
        ))
        let assistant = try await waitForAssistantMessage(messageRepo, threadId: thread.id)
        let translation = try await waitForWireTranslation(
            coordinator,
            threadId: thread.id,
            messageId: assistant.id.value.uuidString
        )

        XCTAssertEqual(assistant.content, rendered)
        XCTAssertFalse(assistant.content.contains("RCW1"),
                       "a provider preamble must not make private wire visible")
        XCTAssertEqual(translation.originalText, raw,
                       "the exact nonconforming provider response remains available in disclosure")
        XCTAssertEqual(translation.rewrittenText, rendered)
    }

    func test_finalAssistantHandleMarkerIsStrippedBeforePersistenceAndTurnCompletedDisplay() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-final-handle-strip-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let final = "Build passed. Full raw output available.\n[[rc:deadbeef]]"
        let runner = ScriptedFinalRunner(provider: .codex, finalMessage: final)
        let thread = AgentThread(title: "final handle", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let observer = RecordingObserver()
        coordinator.addObserver(observer)

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "Summarize the build output."
        ))
        let assistant = try await waitForAssistantMessage(messageRepo, threadId: thread.id)

        XCTAssertEqual(assistant.content, "Build passed. Full raw output available.",
                       "final assistant persistence must strip retrieve handles so transcript text stays human-facing")
        XCTAssertFalse(assistant.content.contains("[[rc:"))
        let turnCompleted = observer.recordedEvents.compactMap(\.turnCompletedFinalMessageForTest).last
        XCTAssertEqual(turnCompleted, assistant.content,
                       "turnCompleted display payload must match the sanitized persisted assistant text")
    }

    func test_finalResponseTranslatorOutputHandleMarkerIsStrippedBeforePersistence() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-translated-handle-strip-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let wire = "RCW1\tA\t1\nO\tBuild passed.\nE\tunit tests green.\n.\n"
        let runner = ScriptedFinalRunner(provider: .claude, finalMessage: wire)
        let thread = AgentThread(title: "translated handle", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.claude: runner]
        )

        coordinator.finalResponseTranslator = { _, _, _, _ in
            "Build passed. Raw log retained.\n[[rc:cafebabe]]"
        }

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            cwd: tmp,
            prompt: "Explain the build result."
        ))
        let assistant = try await waitForAssistantMessage(messageRepo, threadId: thread.id)

        XCTAssertEqual(assistant.content, "Build passed. Raw log retained.",
                       "translated final text must be sanitized before it reaches transcript persistence")
        XCTAssertFalse(assistant.content.contains("[[rc:"))
    }

    func test_wireAssistantStreamRendersDeterministicallyWithoutLeakingRawFrame() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-wire-stream-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let wire = "RCW1\tA\t1\nA\tInspecting App.swift.\n.\nRCW1\tA\t2\nO\tThe race was fixed.\nE\tFocused tests passed.\n.\n"
        let runner = ScriptedStreamRunner(provider: .codex, body: wire)
        let thread = AgentThread(title: "wire stream", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let observer = RecordingObserver()
        coordinator.addObserver(observer)
        coordinator.finalResponseTranslator = { _, _, _, _ in
            XCTFail("complete streamed frames use the deterministic renderer without an MLX wait")
            return "wrong"
        }

        _ = try await coordinator.startRun(.init(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: "Fix the race."
        ))

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              !observer.recordedEvents.compactMap(\.bodyAppendForTest).joined().contains("Focused tests passed") {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let visible = observer.recordedEvents.compactMap(\.bodyAppendForTest).joined(separator: "")
        XCTAssertTrue(visible.contains("Action: Inspecting App.swift."))
        XCTAssertTrue(visible.contains("The race was fixed."))
        XCTAssertTrue(visible.contains("Evidence: Focused tests passed."))
        XCTAssertFalse(visible.contains("RCW1"), "raw wire must never leak into the primary transcript")

        var timeline = AssistantTimelineState()
        for event in coordinator.latestStreamEvents(threadId: thread.id) { timeline.apply(event) }
        let metadata = try XCTUnwrap(timeline.tokenSaverTranslationsByItemId["stream-item"])
        XCTAssertEqual(metadata.originalText, wire)
        XCTAssertTrue(metadata.rewrittenText.contains("Focused tests passed"))
    }

    func test_splitWireSentinelNeverLeaksPartialTransportText() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-wire-split-sentinel-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let wire = "RCW1\tA\t1\nO\tThe split frame stayed private.\n.\n"
        let runner = ScriptedStreamRunner(
            provider: .grok,
            bodyChunks: ["R", "C", "W", "1\t", "A\t1\n", "O\tThe split frame stayed private.\n", ".\n"]
        )
        let thread = AgentThread(title: "split wire sentinel", provider: .grok, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.grok: runner]
        )
        let observer = RecordingObserver()
        coordinator.addObserver(observer)
        coordinator.finalResponseTranslator = { response, _, _, _ in response }

        _ = try await coordinator.startRun(.init(
            threadId: thread.id, provider: .grok, model: "fake-model", cwd: tmp, prompt: "Report the result."
        ))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            var currentTimeline = AssistantTimelineState()
            for event in coordinator.latestStreamEvents(threadId: thread.id) { currentTimeline.apply(event) }
            if currentTimeline.tokenSaverTranslationsByItemId["stream-item"]?.originalText == wire {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let visible = observer.recordedEvents.compactMap(\.bodyAppendForTest).joined()
        XCTAssertEqual(visible, "The split frame stayed private.")
        XCTAssertFalse(visible.contains("RCW1"))
        XCTAssertFalse(visible.hasPrefix("R"), "a fragmented sentinel must remain buffered until classified")
        var timeline = AssistantTimelineState()
        for event in coordinator.latestStreamEvents(threadId: thread.id) { timeline.apply(event) }
        XCTAssertEqual(timeline.tokenSaverTranslationsByItemId["stream-item"]?.originalText, wire)
    }

    func test_truncatedWireStreamShowsReadableErrorAndKeepsRawDisclosure() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-wire-truncated-stream-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let raw = "RCW1\tA\t1\nO\tThis frame was truncated"
        let runner = ScriptedStreamRunner(provider: .claude, bodyChunks: ["RC", "W1\tA\t1\n", "O\tThis frame was truncated"])
        let thread = AgentThread(title: "truncated wire", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.claude: runner]
        )
        let observer = RecordingObserver()
        coordinator.addObserver(observer)
        coordinator.finalResponseTranslator = { response, _, _, _ in response }

        _ = try await coordinator.startRun(.init(
            threadId: thread.id, provider: .claude, model: "fake-model", cwd: tmp, prompt: "Report the result."
        ))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            var currentTimeline = AssistantTimelineState()
            for event in coordinator.latestStreamEvents(threadId: thread.id) { currentTimeline.apply(event) }
            if currentTimeline.tokenSaverTranslationsByItemId["stream-item"]?.originalText == raw {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let visible = observer.recordedEvents.compactMap(\.bodyAppendForTest).joined()
        XCTAssertTrue(visible.contains("Token Saver could not decode"))
        XCTAssertFalse(visible.contains("RCW1"), "malformed transport must not masquerade as fluent output")
        var timeline = AssistantTimelineState()
        for event in coordinator.latestStreamEvents(threadId: thread.id) { timeline.apply(event) }
        let metadata = try XCTUnwrap(timeline.tokenSaverTranslationsByItemId["stream-item"])
        XCTAssertEqual(metadata.originalText, raw)
        let wireMetadata = coordinator.latestStreamEvents(threadId: thread.id).compactMap { event -> AssistantWireTranslation? in
            guard case .wireTranslation(let translation) = event else { return nil }
            return translation
        }.last
        XCTAssertEqual(wireMetadata?.fallbackReason, "deterministic_render")
    }

    func test_reasoningStreamIsNeverDecodedAsAssistantWire() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-wire-reasoning-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let raw = "RCW1\tA\t1\nA\tprivate reasoning record\n.\n"
        let runner = ScriptedStreamRunner(provider: .claude, itemType: .reasoning, body: "", output: raw)
        let thread = AgentThread(title: "reasoning", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.claude: runner]
        )
        let observer = RecordingObserver()
        coordinator.addObserver(observer)
        coordinator.finalResponseTranslator = { _, _, _, _ in
            XCTFail("RCW1 v1 covers assistant messages, not reasoning/tool protocol events")
            return "wrong"
        }

        _ = try await coordinator.startRun(.init(
            threadId: thread.id, provider: .claude, model: "fake-model", cwd: tmp, prompt: "Inspect."
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)
        let output = observer.recordedEvents.compactMap(\.outputAppendForTest).joined()
        XCTAssertEqual(output, raw)
    }

    func test_normalFinalResponseDoesNotInvokeWireTranslator() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-response-normal-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let normal = "Sure, I can explain the result in normal prose."
        let runner = ScriptedFinalRunner(provider: .codex, finalMessage: normal)
        let thread = AgentThread(title: "normal", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: runner]
        )

        coordinator.finalResponseTranslator = { _, _, _, _ in
            XCTFail("normal prose must not be sent through the wire renderer")
            return "wrong"
        }

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "Explain the result."
        ))
        let assistant = try await waitForAssistantMessage(messageRepo, threadId: thread.id)

        XCTAssertEqual(assistant.content, normal)
    }

    func test_plainProviderResponseToAdmittedWireStaysReadableAndPersistsFallbackDisclosure() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-wire-plain-fallback-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let plain = "Approval is required before I can inspect the fixture."
        let runner = ScriptedFinalRunner(provider: .claude, finalMessage: plain)
        let thread = AgentThread(title: "wire fallback", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.claude: runner]
        )
        let requestWire = try RCWireProtocol.serialize(.init(
            direction: .request,
            sequence: 1,
            records: [.init(kind: .goal, value: "Inspect the fixture.")]
        ))
        coordinator.promptCompressor = { _, _, _, _ in requestWire }
        coordinator.finalResponseTranslator = { _, _, _, _ in
            XCTFail("human-readable provider fallback must not wait for local rendering")
            return "wrong"
        }

        _ = try await coordinator.startRun(.init(
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            cwd: tmp,
            prompt: "Inspect the fixture and explain the result."
        ))
        let assistant = try await waitForAssistantMessage(messageRepo, threadId: thread.id)
        let translation = try await waitForWireTranslation(
            coordinator,
            threadId: thread.id,
            messageId: assistant.id.value.uuidString
        )

        XCTAssertEqual(assistant.content, plain,
                       "a provider protocol miss must remain readable instead of becoming an empty or raw-wire reply")
        XCTAssertEqual(translation.originalText, plain,
                       "the exact provider response must survive for transport disclosure")
        XCTAssertEqual(translation.rewrittenText, plain)
        XCTAssertEqual(translation.fallbackReason, "provider_plaintext_fallback",
                       "the UI must distinguish provider nonconformance from a successful decoded frame")
        XCTAssertEqual(translation.wireRequestText, requestWire,
                       "the disclosure must retain what RemoteCode actually sent")
    }

    private func waitForAssistantMessage(
        _ messageRepo: AgentMessageRepository,
        threadId: AgentThreadID
    ) async throws -> AgentMessage {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let assistant = ((try? messageRepo.list(threadId: threadId)) ?? []).first(where: { $0.role == .assistant }) {
                return assistant
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for assistant message")
        throw XCTSkip("assistant message did not persist")
    }

    private func waitForWireTranslation(
        _ coordinator: AgentRunCoordinator,
        threadId: AgentThreadID,
        messageId: String
    ) async throws -> AssistantWireTranslation {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            for event in coordinator.latestStreamEvents(threadId: threadId) {
                if case .wireTranslation(let translation) = event,
                   translation.messageId == messageId {
                    return translation
                }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for persisted wire translation metadata")
        throw XCTSkip("wire translation metadata did not persist")
    }
}
