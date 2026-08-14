import XCTest
@testable import AgentRuntime
import CoreModel

final class WireTranslationPersistenceTests: XCTestCase {
    func test_wireTranslationEventRoundTripsAndIndexesByMessageId() throws {
        let messageId = UUID().uuidString
        let wire = "RCW1\tA\t1\nO\tFocused tests passed.\n.\n"
        let request = "RCW1\tQ\t1\nG\tRun focused tests.\n.\n"
        let rendered = "Focused tests passed."
        let event = AssistantEvent.wireTranslation(.init(
            messageId: messageId,
            originalText: wire,
            rewrittenText: rendered,
            wireRequestText: request
        ))

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AssistantEvent.self, from: data)
        var state = AssistantTimelineState()
        state.apply(decoded)

        XCTAssertEqual(state.sr1TranslationsByMessageId[messageId]?.originalText, wire)
        XCTAssertEqual(state.sr1TranslationsByMessageId[messageId]?.rewrittenText, rendered)
        XCTAssertEqual(state.tokenSaverTranslationsByMessageId[messageId]?.wireRequestText, request,
                       "restart replay must retain the exact provider-bound request for explicit disclosure")
    }

    func test_historicalSR1EventStillDecodesForExistingThreads() throws {
        let messageId = UUID().uuidString
        let historical = AssistantEvent.sr1Translation(.init(
            messageId: messageId,
            originalText: "O: legacy result",
            rewrittenText: "Legacy result"
        ))
        let data = try JSONEncoder().encode(historical)
        let decoded = try JSONDecoder().decode(AssistantEvent.self, from: data)
        var state = AssistantTimelineState()
        state.apply(decoded)

        XCTAssertEqual(state.sr1TranslationsByMessageId[messageId]?.rewrittenText, "Legacy result")
    }
}
