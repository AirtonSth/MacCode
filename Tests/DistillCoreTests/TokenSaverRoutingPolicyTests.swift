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
        XCTAssertTrue(TokenSaverRoutingPolicy.permitsLLM(lane: .commandOutput, justification: "classification"))
        XCTAssertTrue(TokenSaverRoutingPolicy.permitsLLM(lane: .longText, justification: ""))
        XCTAssertTrue(TokenSaverRoutingPolicy.permitsLLM(lane: .watchSummary, justification: nil))
        XCTAssertTrue(TokenSaverRoutingPolicy.permitsLLM(lane: .toolOutputHook, justification: nil))
        XCTAssertTrue(TokenSaverRoutingPolicy.permitsLLM(lane: .wireEncode, justification: "abstractive translation"))
        XCTAssertFalse(TokenSaverRoutingPolicy.permitsLLM(lane: .followUpPrompt, justification: "abstractive"))
    }

    func test_encoderFailureEscalatesEligibleLanesToLLM() {
        let eligible: [TokenSaverLane] = [.commandOutput, .longText, .watchSummary, .toolOutputHook]
        for lane in eligible {
            XCTAssertEqual(
                TokenSaverRoutingPolicy.fallbackAfterEncoderFailure(for: lane),
                .llmMLX,
                "WHY: Token-Saver-admitted eligible payloads must invoke the local LLM after crusher/BERT miss"
            )
            XCTAssertTrue(
                TokenSaverRoutingPolicy.stages(for: lane).contains(.llmMLX),
                "WHY: eligible lanes include .llmMLX in the deterministic→BERT→LLM order (\(lane))"
            )
        }
        for lane in [TokenSaverLane.wireEncode, .wireRenderEnglish, .naturalLanguage] {
            XCTAssertEqual(TokenSaverRoutingPolicy.fallbackAfterEncoderFailure(for: lane), .deterministic)
        }
    }

    func test_followUpPromptDoesNotEscalateToLLM() {
        XCTAssertEqual(
            TokenSaverRoutingPolicy.fallbackAfterEncoderFailure(for: .followUpPrompt),
            .verbatim,
            "WHY: user-authored follow-up text is never-list and must stay off the local LLM"
        )
        XCTAssertFalse(TokenSaverRoutingPolicy.stages(for: .followUpPrompt).contains(.llmMLX))
        XCTAssertFalse(TokenSaverRoutingPolicy.permitsLLM(lane: .followUpPrompt, justification: "abstractive"))
    }

    func test_routingTelemetryMarksLLMBypass() {
        let deterministic = TokenSaverRouteTelemetryEvent(lane: .toolOutputHook, stage: .deterministic, wallClockMilliseconds: 12)
        XCTAssertTrue(deterministic.resolvedWithoutLLM)

        let llm = TokenSaverRouteTelemetryEvent(lane: .wireEncode, stage: .llmMLX, wallClockMilliseconds: 200)
        XCTAssertFalse(llm.resolvedWithoutLLM)

        let api = TokenSaverRouteTelemetryEvent(lane: .naturalLanguage, stage: .apiExternal, wallClockMilliseconds: 80)
        XCTAssertFalse(api.resolvedWithoutLLM)
    }
}

private extension DistillMode {
    static let allCasesForPolicyTests: [DistillMode] = [
        .commandOutput,
        .longText,
        .watchSummary,
        .wireEncode,
        .wireRenderEnglish,
        .naturalLanguage
    ]
}
