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

    func test_storedLegacyEventBytesStillDecodeStrictly() throws {
        // WHY: rows written by older builds are fixed bytes on disk. Decoding
        // them as stored, not a fresh round trip, proves the removal kept the
        // wire shape `agent.thread.read` meets.
        let stored = [
            #"{"sr1Translation":{"_0":{"messageId":"m-1","originalText":"O: legacy","rewrittenText":"legacy"}}}"#,
            #"{"wireTranslation":{"_0":{"itemId":"i-1","originalText":"RCW1","rewrittenText":"legacy","protocolVersion":"RCW1"}}}"#,
            #"{"itemHostMetadata":{"turnId":"turn-1","itemId":"item-1","distillApplied":true}}"#,
        ]
        let decoded = try stored.map { try JSONDecoder().decode(AssistantEvent.self, from: Data($0.utf8)) }

        guard case .sr1Translation(let sr1) = decoded[0] else { return XCTFail("\(decoded[0])") }
        XCTAssertEqual(sr1.rewrittenText, "legacy")
        guard case .wireTranslation(let wire) = decoded[1] else { return XCTFail("\(decoded[1])") }
        XCTAssertEqual(wire.protocolVersion, "RCW1")
        guard case .itemHostMetadata(let turnId, let itemId, let applied, let attestation) = decoded[2] else {
            return XCTFail("\(decoded[2])")
        }
        XCTAssertEqual([turnId, itemId], ["turn-1", "item-1"])
        XCTAssertEqual(applied, true)
        XCTAssertNil(attestation)
    }
}
