import XCTest
@testable import AgentRuntime
import CoreModel

/// Tests for ClaudeStreamingCLIAdapter.sr1TranslationPayload.
///
/// Why these tests matter:
/// - P3 requires original SR1 text preserved in persisted stream event so a
///   "view original" affordance is possible.
/// - The helper is the seam: wiring it into the coordinator persistence path
///   must not silently drop the original.
final class SR1TranslationPayloadTests: XCTestCase {

    // MARK: - rewrite present

    func test_payloadCarriesBothOriginalAndRewrittenWhenTextsDiffer() {
        let original = "S: task complete. R: none. O: result=42"
        let rewritten = "Task complete. No risk. Result: 42."

        let payload = ClaudeStreamingCLIAdapter.sr1TranslationPayload(
            original: original,
            rewritten: rewritten
        )

        XCTAssertEqual(payload["originalText"] as? String, original,
                       "payload must carry original SR1 text so view-original affordance can surface it")
        XCTAssertEqual(payload["rewrittenText"] as? String, rewritten,
                       "payload must carry the translated text shown to users")
        XCTAssertEqual(payload["sr1Translated"] as? Bool, true,
                       "sr1Translated flag must be true when a rewrite actually occurred")
    }

    func test_originalFieldIsAbsentWhenNoRewriteOccurred() {
        let text = "Hello, how can I help you today?"

        let payload = ClaudeStreamingCLIAdapter.sr1TranslationPayload(
            original: text,
            rewritten: text
        )

        XCTAssertNil(payload["originalText"],
                     "originalText must be omitted when original == rewritten to avoid redundant storage")
        XCTAssertEqual(payload["rewrittenText"] as? String, text,
                       "rewrittenText must still be present even when no rewrite occurred")
        XCTAssertEqual(payload["sr1Translated"] as? Bool, false,
                       "sr1Translated flag must be false when original and rewritten are identical")
    }

    // MARK: - round-trip

    func test_roundTripOriginalFromPayloadJSON() throws {
        let original = "D: deploy service. C: staging env. P: smoke tests pass."
        let rewritten = "Deploy service to staging. Smoke tests pass."

        let payload = ClaudeStreamingCLIAdapter.sr1TranslationPayload(
            original: original,
            rewritten: rewritten
        )

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "payload must round-trip through JSON without data loss"
        )

        XCTAssertEqual(decoded["originalText"] as? String, original,
                       "original SR1 text must survive JSON round-trip intact for view-original affordance")
        XCTAssertEqual(decoded["rewrittenText"] as? String, rewritten,
                       "rewritten text must survive JSON round-trip intact")
        XCTAssertEqual(decoded["sr1Translated"] as? Bool, true)
    }

    func test_roundTripNoRewriteFromPayloadJSON() throws {
        let text = "The build succeeded."

        let payload = ClaudeStreamingCLIAdapter.sr1TranslationPayload(
            original: text,
            rewritten: text
        )

        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "no-rewrite payload must also round-trip cleanly"
        )

        XCTAssertNil(decoded["originalText"],
                     "no-rewrite round-trip must not inject originalText")
        XCTAssertEqual(decoded["rewrittenText"] as? String, text)
        XCTAssertEqual(decoded["sr1Translated"] as? Bool, false)
    }

    func test_sr1TranslationEventRoundTripsAndIndexesByMessageId() throws {
        let messageId = UUID().uuidString
        let original = "S: tests pass. P: focused suite green."
        let rewritten = "Focused tests passed."
        let event = AssistantEvent.sr1Translation(AssistantSR1Translation(
            messageId: messageId,
            originalText: original,
            rewrittenText: rewritten
        ))

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AssistantEvent.self, from: data)
        var state = AssistantTimelineState()
        state.apply(decoded)

        XCTAssertEqual(
            state.sr1TranslationsByMessageId[messageId]?.originalText,
            original,
            "persisted SR1 translation events must preserve the original text for the view-original affordance"
        )
        XCTAssertEqual(state.sr1TranslationsByMessageId[messageId]?.rewrittenText, rewritten)
    }

    func test_sr1TranslationEventIndexesByItemIdForStreamingItems() {
        let itemId = "item-123"
        let original = "D inspect repo. O patch applied."
        let rewritten = "I inspected the repo and applied the patch."
        var state = AssistantTimelineState()

        state.apply(.sr1Translation(AssistantSR1Translation(
            itemId: itemId,
            originalText: original,
            rewrittenText: rewritten
        )))

        XCTAssertEqual(
            state.sr1TranslationsByItemId[itemId]?.originalText,
            original,
            "streaming item translations must also keep original SR1 text in the timeline state"
        )
        XCTAssertEqual(state.sr1TranslationsByItemId[itemId]?.rewrittenText, rewritten)
    }

    // MARK: - edge cases

    func test_emptyRewrittenTextWithOriginalDiffer() {
        // Edge: translator returns empty string (fail-open path returns original,
        // but helper itself must still handle arbitrary inputs correctly).
        let original = "S: done"
        let rewritten = ""

        let payload = ClaudeStreamingCLIAdapter.sr1TranslationPayload(
            original: original,
            rewritten: rewritten
        )

        XCTAssertEqual(payload["originalText"] as? String, original,
                       "originalText must still be present even when rewritten is empty")
        XCTAssertEqual(payload["rewrittenText"] as? String, "",
                       "rewrittenText reflects whatever the translator produced")
        XCTAssertEqual(payload["sr1Translated"] as? Bool, true,
                       "strings differ so sr1Translated must be true regardless of content")
    }

    func test_unicodePreservedInBothFields() {
        let original = "S: \u{1F4E6} shipped. C: EU\u{20AC} region."
        let rewritten = "Package shipped to EU region."

        let payload = ClaudeStreamingCLIAdapter.sr1TranslationPayload(
            original: original,
            rewritten: rewritten
        )

        XCTAssertEqual(payload["originalText"] as? String, original,
                       "unicode characters in SR1 original must not be mangled in the payload")
        XCTAssertEqual(payload["rewrittenText"] as? String, rewritten)
    }
}
