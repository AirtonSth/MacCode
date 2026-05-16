import XCTest
@testable import CoreModel

final class AssistantTimelineTests: XCTestCase {
    func test_timeline_appliesItemLifecycle() {
        var s = AssistantTimelineState()
        s.apply(.threadStarted(threadId: "t", providerThreadId: "pt"))
        s.apply(.turnStarted(turnId: "turn1"))
        s.apply(.itemStarted(item: AssistantItem(id: "i1", turnId: "turn1", type: .assistantMessage, startedAtMs: 0)))
        s.apply(.itemDelta(itemId: "i1", bodyAppend: "Hel", outputAppend: nil, summary: nil))
        s.apply(.itemDelta(itemId: "i1", bodyAppend: "lo", outputAppend: nil, summary: nil))
        s.apply(.itemCompleted(itemId: "i1", finalState: .completed))
        s.apply(.turnCompleted(turnId: "turn1", finalMessage: "Hello"))
        XCTAssertEqual(s.threadId, "t")
        XCTAssertEqual(s.providerThreadId, "pt")
        XCTAssertEqual(s.turns.count, 1)
        XCTAssertEqual(s.turns[0].items.count, 1)
        XCTAssertEqual(s.turns[0].items[0].body, "Hello")
        XCTAssertEqual(s.turns[0].items[0].state, .completed)
        XCTAssertTrue(s.turns[0].finished)
        XCTAssertEqual(s.turns[0].finalAssistantMessage, "Hello")
    }

    func test_timeline_handlesError() {
        var s = AssistantTimelineState()
        s.apply(.error(message: "boom", recoverable: false))
        XCTAssertEqual(s.error, "boom")
    }

    func test_latestAssistantMessage_skipsEmptyTrailingTurns() {
        var s = AssistantTimelineState()
        s.apply(.turnStarted(turnId: "real"))
        s.apply(.itemStarted(item: AssistantItem(id: "a1", turnId: "real", type: .assistantMessage, startedAtMs: 1)))
        s.apply(.itemDelta(itemId: "a1", bodyAppend: "final answer", outputAppend: nil, summary: nil))
        s.apply(.turnCompleted(turnId: "real", finalMessage: "final answer"))
        s.apply(.itemStarted(item: AssistantItem(id: "empty", turnId: "", type: .assistantMessage, startedAtMs: 2)))
        XCTAssertEqual(s.latestAssistantMessage, "final answer",
                       "persistence must use the last real assistant reply, not a trailing empty turn")
    }
}
