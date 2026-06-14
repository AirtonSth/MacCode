import XCTest
@testable import DistillCore

final class TokenSaverRoutingPolicyTests: XCTestCase {
    func test_centralRouteOrderIsDeterministicThenBERTThenLLM() {
        XCTAssertEqual(TokenSaverRoutingPolicy.orderedStages, [.deterministic, .encoderBERT, .llmMLX])
    }

    func test_currentMLXInventoryCoversAllModesAndLanes() {
        let modes = Set(TokenSaverRoutingPolicy.currentMLXInventory.compactMap(\.currentMLXMode))
        XCTAssertEqual(modes, Set(DistillMode.allCasesForPolicyTests))

        let lanes = Set(TokenSaverRoutingPolicy.currentMLXInventory.map(\.lane))
        XCTAssertEqual(lanes, Set(TokenSaverLane.allCases))
    }

    func test_onlyAbstractiveLaneCanUseLLMWithExplicitJustification() {
        XCTAssertFalse(TokenSaverRoutingPolicy.permitsLLM(lane: .commandOutput, justification: "classification"))
        XCTAssertFalse(TokenSaverRoutingPolicy.permitsLLM(lane: .longText, justification: ""))
        XCTAssertTrue(TokenSaverRoutingPolicy.permitsLLM(lane: .sr1Humanize, justification: "abstractive translation"))
    }

    func test_encoderFailureDoesNotAutoEscalateToLLM() {
        for lane in TokenSaverLane.allCases where lane != .sr1Humanize {
            XCTAssertEqual(
                TokenSaverRoutingPolicy.fallbackAfterEncoderFailure(for: lane),
                .verbatim,
                "\(lane) must fail open to verbatim/deterministic behavior, not spend LLM tokens automatically"
            )
        }
    }

    func test_routingTelemetryMarksLLMBypass() {
        let deterministic = TokenSaverRouteTelemetryEvent(lane: .toolOutputHook, stage: .deterministic, wallClockMilliseconds: 12)
        XCTAssertTrue(deterministic.resolvedWithoutLLM)

        let llm = TokenSaverRouteTelemetryEvent(lane: .sr1Humanize, stage: .llmMLX, wallClockMilliseconds: 200)
        XCTAssertFalse(llm.resolvedWithoutLLM)
    }
}

private extension DistillMode {
    static let allCasesForPolicyTests: [DistillMode] = [
        .commandOutput,
        .longText,
        .watchSummary,
        .sr1Humanize
    ]
}
