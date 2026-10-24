import XCTest
@testable import CoreModel

final class AgentEffortSelectionNormalizationTests: XCTestCase {
    func test_preservesAutomaticAndSupportedFixedEffort() {
        let supported: [AgentReasoningEffort] = [.low, .high]
        XCTAssertEqual(AgentEffortSelection.automatic.normalized(for: supported), .automatic)
        XCTAssertEqual(AgentEffortSelection.fixed(.low).normalized(for: supported), .fixed(.low))
    }

    func test_unsupportedFixedEffortUsesAutomaticOrSupportedFallback() {
        let supported: [AgentReasoningEffort] = [.low, .high]
        XCTAssertEqual(AgentEffortSelection.fixed(.medium).normalized(for: supported), .automatic)
        XCTAssertEqual(AgentEffortSelection.fixed(.medium).normalized(for: supported, supportsAutomatic: false), .fixed(.high))
        XCTAssertEqual(AgentEffortSelection.fixed(.medium).normalized(for: [.low], supportsAutomatic: false), .fixed(.low))
    }

    func test_emptyMetadataPreservesSelection() {
        let selection = AgentEffortSelection.fixed(.medium)
        XCTAssertEqual(selection.normalized(for: []), selection)
        XCTAssertEqual(selection.normalized(for: [], supportsAutomatic: false), selection)
    }
}
