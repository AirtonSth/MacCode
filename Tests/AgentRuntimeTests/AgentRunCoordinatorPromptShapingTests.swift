import XCTest
@testable import AgentRuntime
@testable import CoreModel
@testable import Persistence

/// WHY: the coordinator decides which text the provider receives. The
/// transcript must always keep what the user typed, while a host-built prompt
/// (bot brain, Mac handoff summary) must reach the provider instead of the
/// display text. Getting this wrong either leaks host envelopes into the
/// transcript or silently drops the bot instructions.
final class AgentRunCoordinatorPromptShapingTests: XCTestCase {
    func test_plainPromptReachesProviderAndTranscriptVerbatim() async throws {
        let (coordinator, messageRepo, thread, tmp, runner) = try makeCoordinator()
        let original = "build the project and run the tests"
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: original
        ))
        await runner.waitForPromptCapture()

        XCTAssertEqual(runner.capturedPrompt, original)
        let messages = try messageRepo.list(threadId: thread.id)
        XCTAssertEqual(messages.first(where: { $0.role == .user })?.content, original)
    }

    func test_hostPromptThatOverridesDisplayReachesProviderButTranscriptKeepsDisplay() async throws {
        let (coordinator, messageRepo, thread, tmp, runner) = try makeCoordinator()
        var request = AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "BOT BRAIN\n\nhello bot",
            userMessageContent: "hello bot"
        )
        request.providerPromptOverridesDisplay = true
        _ = try await coordinator.startRun(request)
        await runner.waitForPromptCapture()

        XCTAssertEqual(runner.capturedPrompt, "BOT BRAIN\n\nhello bot",
                       "the bot brain must reach the provider")
        let messages = try messageRepo.list(threadId: thread.id)
        XCTAssertEqual(messages.first(where: { $0.role == .user })?.content, "hello bot",
                       "the transcript keeps what the user typed, never the host envelope")
    }

    func test_promptThatDoesNotOverrideDisplaySendsTheDisplayText() async throws {
        let (coordinator, messageRepo, thread, tmp, runner) = try makeCoordinator()
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "host-side copy",
            userMessageContent: "what the user typed"
        ))
        await runner.waitForPromptCapture()

        XCTAssertEqual(runner.capturedPrompt, "what the user typed",
                       "without the override flag the provider gets exactly the displayed text")
        let messages = try messageRepo.list(threadId: thread.id)
        XCTAssertEqual(messages.first(where: { $0.role == .user })?.content, "what the user typed")
    }

    private func makeCoordinator() throws -> (AgentRunCoordinator, AgentMessageRepository, AgentThread, String, PromptCapturingRunner) {
        let tmp = NSTemporaryDirectory() + "rc2-prompt-shaping-" + UUID().uuidString
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
}
