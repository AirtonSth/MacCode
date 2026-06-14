import XCTest
@testable import CoreModel

final class AgentProviderInstructionTextTests: XCTestCase {
    func test_providerPreamblesStayCompactAndPreserveRequiredControls() {
        let defaultPreamble = AgentProviderInstructionText.providerPreamble(for: .default)
        let planPreamble = AgentProviderInstructionText.providerPreamble(for: .plan)

        XCTAssertLessThanOrEqual(defaultPreamble.count, 130,
                                 "F17: fixed default preamble is appended after compression every turn; keep it tight")
        XCTAssertLessThanOrEqual(planPreamble.count, 190,
                                 "F17: fixed plan preamble is appended after compression every turn; keep it tight")
        XCTAssertTrue(defaultPreamble.contains("preserve unrelated work"))
        XCTAssertTrue(defaultPreamble.contains("verify"))
        XCTAssertTrue(planPreamble.contains("Plan mode."))
        XCTAssertTrue(planPreamble.contains("Do not edit"))
        XCTAssertTrue(planPreamble.contains("ExitPlanMode"))
    }

    func test_developerInstructionsStayCompactAndPlanOnly() {
        let defaultInstructions = AgentProviderInstructionText.developerInstructions(for: .default)
        let planInstructions = AgentProviderInstructionText.developerInstructions(for: .plan)

        XCTAssertLessThanOrEqual(defaultInstructions.count, 110)
        XCTAssertLessThanOrEqual(planInstructions.count, 90)
        XCTAssertTrue(planInstructions.contains("Plan only"))
        XCTAssertTrue(planInstructions.contains("Do not edit"))
    }
}
