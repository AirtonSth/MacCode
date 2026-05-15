import XCTest
@testable import AgentRuntime
import CoreModel

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
}
