import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

final class FakeRunnerTests: XCTestCase {
    func test_fakeRunner_emitsCompleteTimeline() async throws {
        let runner = FakeProviderRunner(scenario: .simpleAssistant(reply: "OK"))
        let req = AgentRunRequest(threadId: AgentThreadID(), provider: .codex, model: "fake-model", cwd: "/tmp", prompt: "hi")

        actor Collector {
            var events: [AssistantEvent] = []
            var finishedStatus: AgentRunStatus?
            var finishedMessage: String?
            func add(_ e: AssistantEvent) { events.append(e) }
            func finish(_ status: AgentRunStatus, message: String?) { finishedStatus = status; finishedMessage = message }
        }
        let collector = Collector()
        let done = expectation(description: "finished")
        _ = try await runner.startRun(req) { ev in
            switch ev {
            case .event(let e):
                Task { await collector.add(e) }
            case .finished(let st, let m, _):
                Task { await collector.finish(st, message: m); done.fulfill() }
            case .status, .error: break
            }
        }
        await fulfillment(of: [done], timeout: 3)
        let events = await collector.events
        let status = await collector.finishedStatus
        let message = await collector.finishedMessage
        XCTAssertEqual(status, .completed)
        XCTAssertEqual(message, "OK")
        XCTAssertTrue(events.contains { if case .turnCompleted = $0 { return true } else { return false } })
    }

    func test_coordinator_persistsAssistantOnTurnCompleted() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "t", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [.codex: FakeProviderRunner(scenario: .simpleAssistant(reply: "OK"))])
        let req = AgentRunRequest(threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: "hi")
        _ = try await coordinator.startRun(req)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let messages = (try? messageRepo.list(threadId: thread.id)) ?? []
            if messages.contains(where: { $0.role == .assistant && $0.content == "OK" }) {
                XCTAssertEqual(messages.filter { $0.role == .assistant && $0.content == "OK" }.count, 1,
                               "turn completion + finish must not duplicate the final assistant reply")
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("assistant reply must persist from the turn completion event")
    }
}
