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
    let body: String
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
        self.body = body
        self.output = output
        self.finalMessage = finalMessage
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let handle = AgentRunHandle(runId: request.runId, process: nil) {}
        let providerThreadId = request.providerThreadId ?? UUID().uuidString
        let itemType = self.itemType
        let body = self.body
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
            if !body.isEmpty {
                onEvent(.event(.itemDelta(itemId: itemId, bodyAppend: body, outputAppend: nil, summary: nil)))
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
        XCTAssertEqual(
            try messageRepo.outboundPayload(messageId: AgentMessageID(runID.value)),
            "COMPRESSED::" + original.uppercased(),
            "the transcript toggle must read the exact provider-bound prompt"
        )
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

    func test_sr1FinalResponseIsHumanizedBeforePersistence() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-response-humanize-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sr1 = """
        SR1
        S: tests green
        C: user asked in Portuguese
        O: saved counter updated
        P: macOS suite passed
        """
        let runner = ScriptedFinalRunner(provider: .claude, finalMessage: sr1)
        let thread = AgentThread(title: "sr1", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.claude: runner]
        )
        coordinator.tokenSaverRuntimeActive = { true }

        let humanized = "Os testes passaram, e o contador de tokens salvos foi atualizado."
        coordinator.finalResponseTranslator = { response, provider, threadId, _ in
            XCTAssertEqual(provider, .claude)
            XCTAssertEqual(threadId, thread.id)
            XCTAssertTrue(SR1ResponseDetector.isSR1(response))
            return humanized
        }

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            cwd: tmp,
            prompt: "Explique em português o resultado."
        ))
        let assistant = try await waitForAssistantMessage(messageRepo, threadId: thread.id)

        XCTAssertEqual(assistant.content, sr1,
                       "provider history must retain the SR1 wire text while the UI leg is persisted separately")
        let translation = try await waitForSR1Translation(
            coordinator,
            threadId: thread.id,
            messageId: assistant.id.value.uuidString
        )
        XCTAssertEqual(translation.originalText, sr1,
                       "persisted stream replay must retain the original SR1 text for view-original")
        XCTAssertEqual(translation.rewrittenText, humanized)
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
        let sr1 = "S: build pass. P: unit tests green."
        let runner = ScriptedFinalRunner(provider: .claude, finalMessage: sr1)
        let thread = AgentThread(title: "translated handle", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.claude: runner]
        )
        coordinator.tokenSaverRuntimeActive = { true }

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

        XCTAssertEqual(assistant.content, sr1,
                       "provider history must retain the original SR1 wire text")
        let translation = try await waitForSR1Translation(
            coordinator,
            threadId: thread.id,
            messageId: assistant.id.value.uuidString
        )
        XCTAssertEqual(translation.rewrittenText, "Build passed. Raw log retained.")
    }

    func test_sr1SemanticLineWithoutHeaderIsHumanizedBeforePersistence() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-response-humanize-line-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let compressed = "S: humanizacao codex acionada"
        let runner = ScriptedFinalRunner(provider: .codex, finalMessage: compressed)
        let thread = AgentThread(title: "sr1 line", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        coordinator.tokenSaverRuntimeActive = { true }

        coordinator.finalResponseTranslator = { response, provider, threadId, _ in
            XCTAssertEqual(provider, .codex)
            XCTAssertEqual(threadId, thread.id)
            XCTAssertTrue(SR1ResponseDetector.isSR1(response),
                          "single SR1 semantic lines from /distill must not be persisted as readable prose")
            return "Estado: humanizacao codex acionada"
        }

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "Responda em portugues."
        ))
        let assistant = try await waitForAssistantMessage(messageRepo, threadId: thread.id)

        XCTAssertEqual(assistant.content, compressed)
        let translation = try await waitForSR1Translation(
            coordinator,
            threadId: thread.id,
            messageId: assistant.id.value.uuidString
        )
        XCTAssertEqual(translation.rewrittenText, "Estado: humanizacao codex acionada")
    }

    func test_sr1SpaceDelimitedDistillLinesAreHumanizedBeforePersistence() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-response-humanize-space-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let compressed = """
        O Snake game criado.
        O file: /Users/samuelfajreldines/snake.html (single-file, zero deps)
        O feat: canvas 20x20 grid, score, wall+self collision, food respawn, game-over restart
        O ctrl: setas ou WASD; ESPACO reinicia
        P open: abrir snake.html no browser -> jogo roda
        """
        let runner = ScriptedFinalRunner(provider: .claude, finalMessage: compressed)
        let thread = AgentThread(title: "sr1 space", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.claude: runner]
        )
        coordinator.tokenSaverRuntimeActive = { true }

        coordinator.finalResponseTranslator = { response, provider, threadId, _ in
            XCTAssertEqual(provider, .claude)
            XCTAssertEqual(threadId, thread.id)
            XCTAssertTrue(SR1ResponseDetector.isSR1(response),
                          "real /distill output may use 'O text' and 'P text' without a colon after the prefix")
            return "O Snake game foi criado em /Users/samuelfajreldines/snake.html e pode ser aberto no navegador."
        }

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            cwd: tmp,
            prompt: "/distill crie o snage game em html"
        ))
        let assistant = try await waitForAssistantMessage(messageRepo, threadId: thread.id)

        XCTAssertEqual(assistant.content, compressed,
                       "provider history must retain the SR1 wire text")
        let translation = try await waitForSR1Translation(
            coordinator,
            threadId: thread.id,
            messageId: assistant.id.value.uuidString
        )
        XCTAssertEqual(
            translation.rewrittenText,
            "O Snake game foi criado em /Users/samuelfajreldines/snake.html e pode ser aberto no navegador."
        )
    }

    func test_mixedSR1AndHumanDistillAnswerIsHumanizedBeforePersistence() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-response-humanize-mixed-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let compressed = """
        S done.
        O created /tmp/index.html: self-contained Snake game.
        P verified:
        PASS inline JS parses.
        PASS HTTP smoke: 200, title present, canvas present.
        C controls:
        Arrow keys / WASD move.
        Space pauses.
        Enter restarts after game over.
        Touch buttons included.
        O criado /tmp/index.html: jogo Snake self-contained.
        """
        let runner = ScriptedFinalRunner(provider: .codex, finalMessage: compressed)
        let thread = AgentThread(title: "sr1 mixed", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        coordinator.tokenSaverRuntimeActive = { true }

        coordinator.finalResponseTranslator = { response, provider, threadId, _ in
            XCTAssertEqual(provider, .codex)
            XCTAssertEqual(threadId, thread.id)
            XCTAssertTrue(SR1ResponseDetector.isSR1(response),
                          "mixed compressed S/O/P/C lines plus a human sentence must still be treated as SR1")
            return "O jogo Snake foi criado em /tmp/index.html e verificado com sucesso."
        }

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "/distill crie o snage game em html"
        ))
        let assistant = try await waitForAssistantMessage(messageRepo, threadId: thread.id)

        XCTAssertEqual(assistant.content, compressed,
                       "provider history must retain the mixed SR1 wire text")
        let translation = try await waitForSR1Translation(
            coordinator,
            threadId: thread.id,
            messageId: assistant.id.value.uuidString
        )
        XCTAssertEqual(translation.rewrittenText, "O jogo Snake foi criado em /tmp/index.html e verificado com sucesso.")
    }

    func test_sr1AssistantMessageStreamIsHumanizedBeforeTimelinePersistence() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-stream-humanize-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let compressed = """
        Dict: S=state C=context D=action R=risk O=outcome N=no-go P=proof
        S received. D use /distill. D inspect /tmp, then create minimal HTML snake game.
        """
        let runner = ScriptedStreamRunner(provider: .codex, body: compressed)
        let thread = AgentThread(title: "sr1 stream", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let observer = RecordingObserver()
        coordinator.addObserver(observer)

        coordinator.finalResponseTranslator = { response, provider, threadId, _ in
            XCTAssertEqual(provider, .codex)
            XCTAssertEqual(threadId, thread.id)
            XCTAssertTrue(SR1ResponseDetector.isSR1(response))
            // Force the provider terminal callback to arrive while stream
            // humanization is still in flight. The translated delta must cross
            // the same durability barrier before terminal cleanup.
            try? await Task.sleep(nanoseconds: 50_000_000)
            return "Recebi o pedido em /distill e vou criar um jogo Snake HTML mínimo em /tmp."
        }

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "/distill crie o snage game em html"
        ))

        let expected = "Recebi o pedido em /distill e vou criar um jogo Snake HTML mínimo em /tmp."
        let liveDeadline = Date().addingTimeInterval(3)
        while Date() < liveDeadline,
              !observer.recordedEvents.contains(where: { $0.bodyAppendForTest == expected }) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let liveBodies = observer.recordedEvents.compactMap(\.bodyAppendForTest).joined(separator: "\n")
        XCTAssertTrue(liveBodies.contains(expected),
                      "live Agent App observers must receive the human-language text instead of the SR1 stream")
        XCTAssertFalse(liveBodies.contains("Dict: S=state"),
                       "raw SR1 provider text must not reach the live timeline")
        XCTAssertFalse(liveBodies.contains("S received."))

        let replayDeadline = Date().addingTimeInterval(3)
        while Date() < replayDeadline,
              !coordinator.latestStreamEvents(threadId: thread.id)
                .compactMap(\.bodyAppendForTest)
                .joined(separator: "\n")
                .contains(expected) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let persistedBodies = coordinator.latestStreamEvents(threadId: thread.id)
            .compactMap(\.bodyAppendForTest)
            .joined(separator: "\n")
        XCTAssertTrue(persistedBodies.contains(expected),
                      "replayed Agent App timelines must also use the humanized stream text")
        XCTAssertFalse(persistedBodies.contains("Dict: S=state"))
    }

    func test_activeTokenSaverHumanizesFreeProseIntermediateBeforeLiveOrReplayTimeline() async throws {
        // WHY: provider non-compliance must not leak natural-language commentary
        // into the Agent App while the all-SR2 contract is active.
        let tmp = NSTemporaryDirectory() + "rc2-ts-free-prose-stream-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let raw = "Checking role-based access before editing the controller."
        let wire = "@sr2 v0\no:cont\nd:check_access"
        let runner = ScriptedStreamRunner(provider: .codex, body: raw, finalMessage: wire)
        let thread = AgentThread(title: "free prose stream", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let observer = RecordingObserver()
        coordinator.addObserver(observer)
        coordinator.tokenSaverRuntimeActive = { true }
        coordinator.finalResponseTranslator = { response, _, _, _ in
            response == raw ? "Verificando o acesso por função antes de editar o controller." : "Continuando."
        }
        coordinator.reversibleProseStore = { _ in "stream-handle" }

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "Check access"
        ))

        let expected = "Verificando o acesso por função antes de editar o controller."
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              !observer.recordedEvents.contains(where: { $0.bodyAppendForTest == expected }) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let live = observer.recordedEvents.compactMap(\.bodyAppendForTest).joined(separator: "\n")
        let replay = coordinator.latestStreamEvents(threadId: thread.id)
            .compactMap(\.bodyAppendForTest)
            .joined(separator: "\n")

        XCTAssertTrue(live.contains(expected), live)
        XCTAssertFalse(live.contains(raw), live)
        XCTAssertTrue(replay.contains(expected), replay)
        XCTAssertFalse(replay.contains(raw), replay)
    }

    func test_tokenSaverOffStreamsFreeProseIntermediateVerbatim() async throws {
        // WHY: all-SR2 enforcement belongs to Token Saver and must not alter the
        // normal provider stream when that feature is disabled.
        let tmp = NSTemporaryDirectory() + "rc2-ts-off-free-prose-stream-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let raw = "Checking role-based access."
        let runner = ScriptedStreamRunner(provider: .codex, body: raw, finalMessage: raw)
        let thread = AgentThread(title: "off free prose", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let observer = RecordingObserver()
        coordinator.addObserver(observer)
        coordinator.tokenSaverRuntimeActive = { false }
        coordinator.finalResponseTranslator = { _, _, _, _ in
            XCTFail("Token Saver OFF must not humanize provider text")
            return "wrong"
        }

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "Check access"
        ))

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              !observer.recordedEvents.contains(where: { $0.bodyAppendForTest == raw }) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let live = observer.recordedEvents.compactMap(\.bodyAppendForTest).joined(separator: "\n")
        XCTAssertTrue(live.contains(raw), live)
    }

    func test_bufferedSR1AndDeferredTerminalRecordComplianceOnce() async throws {
        // WHY: A buffered SR1 item is translated before the provider terminal
        // is released, so both the item completion and the deferred final can
        // build a dual-channel plan for one run. Compliance owns the terminal
        // plan only; the run must contribute exactly one provider turn.
        SR2WirePolicy.sharedCompliance.reset()
        defer { SR2WirePolicy.sharedCompliance.reset() }

        let tmp = NSTemporaryDirectory() + "rc2-ts-buffered-sr1-compliance-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let compressed = "S state loaded.\nD run tests.\nO passed."
        let runner = ScriptedStreamRunner(
            provider: .claude,
            body: compressed,
            finalMessage: compressed
        )
        let thread = AgentThread(title: "buffered SR1 compliance", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.claude: runner]
        )
        coordinator.tokenSaverRuntimeActive = { true }
        coordinator.finalResponseTranslator = { response, provider, threadId, _ in
            XCTAssertEqual(provider, .claude)
            XCTAssertEqual(threadId, thread.id)
            XCTAssertTrue(SR1ResponseDetector.isSR1(response))
            try? await Task.sleep(nanoseconds: 50_000_000)
            return "Tests passed successfully."
        }

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            cwd: tmp,
            prompt: "/distill run the tests"
        ))
        let assistant = try await waitForAssistantMessage(messageRepo, threadId: thread.id)
        XCTAssertEqual(assistant.content, compressed)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              SR2WirePolicy.sharedCompliance.snapshot()["claude"]?.turns != 1 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let snapshot = SR2WirePolicy.sharedCompliance.snapshot()
        XCTAssertEqual(snapshot["claude"]?.turns, 1,
                       "buffered SR1 item plus deferred terminal must export one compliance turn")
        XCTAssertEqual(snapshot["claude"]?.misses, 0)
    }

    func test_inlineSR1AssistantMessageStreamIsHumanizedBeforeTimelinePersistence() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-inline-stream-humanize-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let compressed = "S come. C cwd=/tmp. D load /distill rule, then create minimal HTML snake game."
        let runner = ScriptedStreamRunner(provider: .codex, body: compressed)
        let thread = AgentThread(title: "inline sr1 stream", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let observer = RecordingObserver()
        coordinator.addObserver(observer)

        coordinator.finalResponseTranslator = { response, provider, threadId, _ in
            XCTAssertEqual(provider, .codex)
            XCTAssertEqual(threadId, thread.id)
            XCTAssertTrue(SR1ResponseDetector.isSR1(response),
                          "inline SR1 clauses like 'S ... C ... D ...' must be detected before the Agent App renders them")
            return "O contexto é /tmp. Vou carregar a regra /distill e criar um jogo Snake HTML mínimo."
        }

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "/distill crie o snage game em html"
        ))

        let expected = "O contexto é /tmp. Vou carregar a regra /distill e criar um jogo Snake HTML mínimo."
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              !observer.recordedEvents.contains(where: { $0.bodyAppendForTest == expected }) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let liveBodies = observer.recordedEvents.compactMap(\.bodyAppendForTest).joined(separator: "\n")
        XCTAssertTrue(liveBodies.contains(expected))
        XCTAssertFalse(liveBodies.contains("S come."))
        XCTAssertFalse(liveBodies.contains("C cwd=/tmp"))
    }

    func test_singleSemanticSR1ReasoningLineIsHumanizedBeforeTimelinePersistence() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-single-sr1-humanize-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let compressed = "S /distill ativo."
        let runner = ScriptedStreamRunner(provider: .codex, itemType: .reasoning, body: "", output: compressed)
        let thread = AgentThread(title: "single sr1 reasoning", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let observer = RecordingObserver()
        coordinator.addObserver(observer)

        coordinator.finalResponseTranslator = { response, provider, threadId, _ in
            XCTAssertEqual(provider, .codex)
            XCTAssertEqual(threadId, thread.id)
            XCTAssertTrue(SR1ResponseDetector.isSR1(response),
                          "single semantic lines like 'S /distill ativo.' must be treated as SR1 when streamed by the provider")
            return "O modo /distill está ativo."
        }

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "/distill crie o snage game em html"
        ))

        let expected = "O modo /distill está ativo."
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              !observer.recordedEvents.contains(where: { $0.bodyAppendForTest == expected }) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let liveBodies = observer.recordedEvents.compactMap(\.bodyAppendForTest).joined(separator: "\n")
        XCTAssertTrue(liveBodies.contains(expected))
        XCTAssertFalse(liveBodies.contains("S /distill ativo."))
    }

    func test_sr1ReasoningStreamIsHumanizedBeforeTimelinePersistence() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-reasoning-humanize-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let compressed = """
        S context loaded.
        C /tmp has no project scaffold for this task.
        D create one self-contained snake-game.html. P open file in browser directly; no server needed.
        """
        let runner = ScriptedStreamRunner(provider: .claude, itemType: .reasoning, body: "", output: compressed)
        let thread = AgentThread(title: "sr1 reasoning", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.claude: runner]
        )
        let observer = RecordingObserver()
        coordinator.addObserver(observer)

        coordinator.finalResponseTranslator = { response, provider, threadId, _ in
            XCTAssertEqual(provider, .claude)
            XCTAssertEqual(threadId, thread.id)
            XCTAssertTrue(SR1ResponseDetector.isSR1(response))
            return "O contexto foi carregado. Como /tmp não tem projeto, vou criar um arquivo HTML único para o Snake."
        }

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            cwd: tmp,
            prompt: "/distill crie o snage game em html"
        ))

        let expected = "O contexto foi carregado. Como /tmp não tem projeto, vou criar um arquivo HTML único para o Snake."
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              !observer.recordedEvents.contains(where: { $0.bodyAppendForTest == expected }) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let liveBodies = observer.recordedEvents.compactMap(\.bodyAppendForTest).joined(separator: "\n")
        XCTAssertTrue(liveBodies.contains(expected),
                      "reasoning/commentary rows shown in Agent App must be humanized before display")
        XCTAssertFalse(liveBodies.contains("S context loaded."))
        XCTAssertFalse(liveBodies.contains("C /tmp has no project scaffold"))
    }

    func test_normalFinalResponseDoesNotInvokeSR1Translator() async throws {
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

        // The translator hook is installed for the process lifetime, but this
        // fixture models Token Saver being OFF explicitly.
        coordinator.tokenSaverRuntimeActive = { false }
        coordinator.finalResponseTranslator = { _, _, _, _ in
            XCTFail("normal prose must not be sent through the SR1 humanizer")
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

    func test_shortFreeProseUsesActiveTokenSaverDualChannel() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-short-free-prose-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let shortReply = "Done."
        let runner = ScriptedFinalRunner(provider: .codex, finalMessage: shortReply)
        let thread = AgentThread(title: "short free prose", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        coordinator.tokenSaverRuntimeActive = { true }
        coordinator.finalResponseTranslator = { response, _, _, _ in
            XCTAssertEqual(response, shortReply)
            return response
        }
        coordinator.reversibleProseStore = { prose in
            XCTAssertEqual(prose, shortReply)
            return "deadbeef"
        }

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "Confirm completion."
        ))
        let assistant = try await waitForAssistantMessage(messageRepo, threadId: thread.id)

        XCTAssertTrue(SR2WirePolicy.isSR2(assistant.content), assistant.content)
        XCTAssertTrue(assistant.content.contains("[[rc:deadbeef]]"), assistant.content)
        XCTAssertFalse(assistant.content.contains(shortReply))
        let translation = try await waitForSR1Translation(
            coordinator,
            threadId: thread.id,
            messageId: assistant.id.value.uuidString
        )
        XCTAssertEqual(translation.rewrittenText, shortReply)
    }

    func test_concurrentMixedProviderDualChannelRecordsExactRunOnce() async throws {
        // WHY: compliance must be attributed to the run that produced the
        // response. Concurrent Claude/Codex turns must not use an arbitrary
        // active-run provider, and the same dual-channel plan must not be
        // counted by both AppContext and the coordinator.
        SR2WirePolicy.sharedCompliance.reset()
        defer { SR2WirePolicy.sharedCompliance.reset() }

        func makeFixture(
            provider: AgentProvider,
            finalMessage: String,
            handle: String?
        ) throws -> (AgentRunCoordinator, AgentMessageRepository, AgentThread, String) {
            let tmp = NSTemporaryDirectory() + "rc2-ts-compliance-" + provider.rawValue + "-" + UUID().uuidString
            let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
            let threadRepo = AgentThreadRepository(db: db)
            let messageRepo = AgentMessageRepository(db: db)
            let runRepo = AgentRunRepository(db: db)
            let thread = AgentThread(title: "compliance", provider: provider, model: "fake-model")
            try threadRepo.upsert(thread)
            let runner = ScriptedFinalRunner(provider: provider, finalMessage: finalMessage)
            let coordinator = AgentRunCoordinator(
                runRepo: runRepo,
                messageRepo: messageRepo,
                threadRepo: threadRepo,
                providers: [provider: runner]
            )
            coordinator.tokenSaverRuntimeActive = { true }
            coordinator.finalResponseTranslator = { response, resolvedProvider, resolvedThread, _ in
                XCTAssertEqual(resolvedProvider, provider)
                XCTAssertEqual(resolvedThread, thread.id)
                return provider == .claude ? "Claude UI text" : response
            }
            if let handle {
                coordinator.reversibleProseStore = { _ in handle }
            }
            return (coordinator, messageRepo, thread, tmp)
        }

        let claudeWire = "@sr2 v0\no:ok\np:claude.swift:1"
        let (claude, claudeMessages, claudeThread, claudeCwd) = try makeFixture(
            provider: .claude,
            finalMessage: claudeWire,
            handle: nil
        )
        let (codex, codexMessages, codexThread, codexCwd) = try makeFixture(
            provider: .codex,
            finalMessage: "Codex returned a free prose answer.",
            handle: "codex-handle"
        )

        async let claudeRun = claude.startRun(AgentRunRequest(
            threadId: claudeThread.id,
            provider: .claude,
            model: "fake-model",
            cwd: claudeCwd,
            prompt: "Claude compliance turn"
        ))
        async let codexRun = codex.startRun(AgentRunRequest(
            threadId: codexThread.id,
            provider: .codex,
            model: "fake-model",
            cwd: codexCwd,
            prompt: "Codex compliance turn"
        ))
        _ = try await (claudeRun, codexRun)

        _ = try await waitForAssistantMessage(claudeMessages, threadId: claudeThread.id)
        _ = try await waitForAssistantMessage(codexMessages, threadId: codexThread.id)

        let snapshot = SR2WirePolicy.sharedCompliance.snapshot()
        XCTAssertEqual(snapshot["claude"]?.turns, 1)
        XCTAssertEqual(snapshot["claude"]?.misses, 0)
        XCTAssertEqual(snapshot["codex"]?.turns, 1)
        XCTAssertEqual(snapshot["codex"]?.misses, 1)
        XCTAssertEqual(snapshot["codex"]?.enforced, 1)
        XCTAssertNil(snapshot["unknown"], "provider attribution must not fall back to an arbitrary concurrent run")
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

    private func waitForSR1Translation(
        _ coordinator: AgentRunCoordinator,
        threadId: AgentThreadID,
        messageId: String
    ) async throws -> AssistantSR1Translation {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            for event in coordinator.latestStreamEvents(threadId: threadId) {
                if case .sr1Translation(let translation) = event,
                   translation.messageId == messageId {
                    return translation
                }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for persisted SR1 translation event")
        throw XCTSkip("SR1 translation event did not persist")
    }
}
