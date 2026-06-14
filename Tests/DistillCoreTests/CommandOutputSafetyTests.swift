import XCTest
@testable import DistillCore

/// I7.5 / I7.6 / I2.9 / I10.8 safety + budget helpers.
final class CommandOutputSafetyTests: XCTestCase {
    func test_omittedRegionErrorScanRefusesSummary() {
        XCTAssertTrue(CommandOutputSafety.omittedRegionHasError("...\nTraceback (most recent call last)\n..."))
        XCTAssertTrue(CommandOutputSafety.omittedRegionHasError("line\nFAILED test_x\nline"))
        XCTAssertFalse(CommandOutputSafety.omittedRegionHasError("just some ordinary log lines here"))
    }

    func test_intentParityGateNeedsExpansionRegionAnd98Percent() {
        XCTAssertFalse(CommandOutputSafety.intentParityMeetsGate(expansionRegionAgreements: 99, expansionRegionSamples: 100)) // <500 samples
        XCTAssertTrue(CommandOutputSafety.intentParityMeetsGate(expansionRegionAgreements: 495, expansionRegionSamples: 500))
        XCTAssertFalse(CommandOutputSafety.intentParityMeetsGate(expansionRegionAgreements: 480, expansionRegionSamples: 500)) // 96%
    }

    func test_latencyBudgets() {
        XCTAssertTrue(DistillLatencyBudget.withinDeterministicBudget(p95Millis: 250))
        XCTAssertFalse(DistillLatencyBudget.withinDeterministicBudget(p95Millis: 400))
        XCTAssertTrue(DistillLatencyBudget.mlxDeadlineExceeded(elapsedMillis: 1500))
        XCTAssertFalse(DistillLatencyBudget.mlxDeadlineExceeded(elapsedMillis: 800))
    }

    func test_headTailWindowingAndCompositeDetection() {
        let big = String(repeating: "H", count: 3000) + String(repeating: "T", count: 3000)
        let (head, tail) = SubtypeWindowing.headTailWindows(big, windowChars: 2048)
        XCTAssertTrue(head.hasPrefix("H"))
        XCTAssertTrue(tail.hasSuffix("T"))
        XCTAssertTrue(SubtypeWindowing.isComposite(headKind: "build_output", tailKind: "test_report"))
        XCTAssertFalse(SubtypeWindowing.isComposite(headKind: "log", tailKind: "log"))
        XCTAssertTrue(SubtypeWindowing.isComposite(headKind: nil, tailKind: "log"))
    }
}
