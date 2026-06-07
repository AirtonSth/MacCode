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
        coordinator.promptCompressor = { prompt, _ in "COMPRESSED::" + prompt.uppercased() }

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
        coordinator.promptCompressor = { prompt, _ in prompt }
        let original = "explain this stack trace and fix the crash"
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: original
        ))
        await waitForPrompt(runner)

        XCTAssertEqual(runner.capturedPrompt, original)
        let messages = (try? messageRepo.list(threadId: thread.id)) ?? []
        XCTAssertEqual(messages.first(where: { $0.role == .user })?.content, original)
    }
}
