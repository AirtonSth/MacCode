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

    init(provider: AgentProvider = .codex) { self.provider = provider }

    var capturedPrompt: String? {
        lock.lock(); defer { lock.unlock() }
        return _captured
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        lock.lock(); _captured = request.prompt; lock.unlock()
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

private extension AssistantEvent {
    var bodyAppendForTest: String? {
        if case .itemDelta(_, let bodyAppend, _, _) = self {
            return bodyAppend
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
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, runner.capturedPrompt == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func test_promptCompressorTransformsOutboundButPreservesDisplayedMessage() async throws {
        let (coordinator, messageRepo, thread, tmp, runner) = try makeCoordinator()
        coordinator.promptCompressor = { prompt, _, _ in "COMPRESSED::" + prompt.uppercased() }

        let original = "Please refactor the widget renderer in file Foo.swift, keep ID abc-123"
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: original
        ))
        await waitForPrompt(runner)

        XCTAssertEqual(runner.capturedPrompt, "COMPRESSED::" + original.uppercased(),
                       "the provider must receive the compressed prompt")
        let messages = (try? messageRepo.list(threadId: thread.id)) ?? []
        XCTAssertEqual(messages.first(where: { $0.role == .user })?.content, original,
                       "the displayed user message must remain the original, uncompressed text")
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
        coordinator.promptCompressor = { prompt, _, _ in prompt }
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

        XCTAssertEqual(assistant.content, humanized,
                       "the Agent App transcript must persist the human-language answer, not the SR1 compressed provider response")
        XCTAssertFalse(assistant.content.contains("SR1"))
        XCTAssertFalse(assistant.content.contains("S: tests green"))
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

        XCTAssertEqual(assistant.content, "Estado: humanizacao codex acionada")
        XCTAssertFalse(assistant.content.contains("S:"))
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

        XCTAssertFalse(assistant.content.contains("O file:"),
                       "the Agent App transcript must not persist raw /distill SR1 lines")
        XCTAssertFalse(assistant.content.contains("P open:"))
        XCTAssertTrue(assistant.content.contains("Snake game foi criado"))
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

        XCTAssertEqual(assistant.content, "O jogo Snake foi criado em /tmp/index.html e verificado com sucesso.")
        XCTAssertFalse(assistant.content.contains("S done."))
        XCTAssertFalse(assistant.content.contains("O created"))
        XCTAssertFalse(assistant.content.contains("P verified"))
        XCTAssertFalse(assistant.content.contains("C controls"))
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
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              !observer.recordedEvents.contains(where: { $0.bodyAppendForTest == expected }) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let liveBodies = observer.recordedEvents.compactMap(\.bodyAppendForTest).joined(separator: "\n")
        XCTAssertTrue(liveBodies.contains(expected),
                      "live Agent App observers must receive the human-language text instead of the SR1 stream")
        XCTAssertFalse(liveBodies.contains("Dict: S=state"),
                       "raw SR1 provider text must not reach the live timeline")
        XCTAssertFalse(liveBodies.contains("S received."))

        let persistedBodies = coordinator.latestStreamEvents(threadId: thread.id)
            .compactMap(\.bodyAppendForTest)
            .joined(separator: "\n")
        XCTAssertTrue(persistedBodies.contains(expected),
                      "replayed Agent App timelines must also use the humanized stream text")
        XCTAssertFalse(persistedBodies.contains("Dict: S=state"))
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
}
