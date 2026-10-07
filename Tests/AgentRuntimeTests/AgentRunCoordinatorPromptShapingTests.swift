import XCTest
@testable import AgentRuntime
@testable import CoreModel
@testable import Persistence

/// WHY: the provider receives the request prompt and the transcript keeps the
/// display text. Mixing them up either leaks host envelopes (bot brain, Mac
/// handoff summary) into the transcript, drops the bot instructions, or sends
/// display-only attachment markers to the provider.
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

    func test_hostBuiltPromptReachesProviderButTranscriptKeepsDisplay() async throws {
        let (coordinator, messageRepo, thread, tmp, runner) = try makeCoordinator()
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "BOT BRAIN\n\nhello bot",
            userMessageContent: "hello bot"
        ))
        await runner.waitForPromptCapture()

        XCTAssertEqual(runner.capturedPrompt, "BOT BRAIN\n\nhello bot",
                       "the bot brain must reach the provider")
        let messages = try messageRepo.list(threadId: thread.id)
        XCTAssertEqual(messages.first(where: { $0.role == .user })?.content, "hello bot",
                       "the transcript keeps what the user typed, never the host envelope")
    }

    func test_attachmentSummaryInTheDisplayTextNeverReachesTheProvider() async throws {
        let (coordinator, messageRepo, thread, tmp, runner) = try makeCoordinator()
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "review these",
            userMessageContent: "review these\n\n📎 notes.swift"
        ))
        await runner.waitForPromptCapture()

        XCTAssertEqual(runner.capturedPrompt, "review these",
                       "the display-only attachment summary must not be folded into the provider prompt")
        let messages = try messageRepo.list(threadId: thread.id)
        XCTAssertEqual(messages.first(where: { $0.role == .user })?.content, "review these\n\n📎 notes.swift")
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
