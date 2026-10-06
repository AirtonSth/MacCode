import XCTest
@testable import CoreModel

/// WHY: Token Saver was removed, but threads written by older builds still
/// hold its events. `agent.thread.read` decodes stored events strictly, so a
/// case that no longer decodes would break every such thread.
final class LegacyAssistantEventDecodeTests: XCTestCase {
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

    func test_historicalItemHostMetadataEventStillDecodes() throws {
        let historical = AssistantEvent.itemHostMetadata(
            turnId: "turn-1",
            itemId: "item-1",
            distillApplied: true
        )
        let data = try JSONEncoder().encode(historical)
        let decoded = try JSONDecoder().decode(AssistantEvent.self, from: data)

        XCTAssertEqual(decoded, historical)
    }
}
