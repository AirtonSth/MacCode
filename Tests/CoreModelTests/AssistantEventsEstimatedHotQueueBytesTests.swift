import XCTest
@testable import CoreModel

final class AssistantEventsEstimatedHotQueueBytesTests: XCTestCase {
    func test_wireTranslationEstimateAccountsForEntireWireRequestPayload() {
        let wireRequest = "RCW1\tQ\t1\nG\tInspect 🚀.\n.\n"
        let withoutRequest = AssistantEvent.wireTranslation(.init(
            messageId: "message-1",
            originalText: "",
            rewrittenText: ""
        ))
        let withRequest = AssistantEvent.wireTranslation(.init(
            messageId: "message-1",
            originalText: "",
            rewrittenText: "",
            wireRequestText: wireRequest
        ))

        XCTAssertEqual(
            withRequest.estimatedHotQueueBytes - withoutRequest.estimatedHotQueueBytes,
            wireRequest.utf8.count,
            "hot-queue admission must include the provider-bound RCW1 request even when translated display text is empty"
        )
    }

    func test_legacyTranslationEstimateAccountsForOptionalWireRequestPayload() {
        let wireRequest = "RCW1\tQ\t1\nG\tInspect 🚀.\n.\n"
        let withoutRequest = AssistantEvent.sr1Translation(.init(
            messageId: "message-1",
            originalText: "",
            rewrittenText: ""
        ))
        let withRequest = AssistantEvent.sr1Translation(.init(
            messageId: "message-1",
            originalText: "",
            rewrittenText: "",
            wireRequestText: wireRequest
        ))

        XCTAssertEqual(
            withRequest.estimatedHotQueueBytes - withoutRequest.estimatedHotQueueBytes,
            wireRequest.utf8.count,
            "historical translation events carrying an RCW1 request must obey the same hot-queue byte ceiling"
        )
    }
}
