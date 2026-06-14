import XCTest
@testable import DistillCore

/// I5.8 / M10: masking A/B harness — keep masking on only if solve-rate is
/// non-inferior AND turn-count / retrieval-rate regressions stay under caps.
final class MaskingABHarnessTests: XCTestCase {
    func test_keepsMaskingWhenNonInferiorAndWithinCaps() {
        let baseline = MaskingABHarness.Arm(solved: [true, true, true, false], turnCounts: [4, 5, 6, 7], retrieves: [0, 0, 1, 0])
        let masked = MaskingABHarness.Arm(solved: [true, true, true, false], turnCounts: [4, 5, 6, 7], retrieves: [0, 1, 1, 0])
        let d = MaskingABHarness.evaluate(baseline: baseline, masked: masked)
        XCTAssertTrue(d.keepMaskingOn)
        XCTAssertEqual(d.reason, "non_inferior_within_caps")
    }

    func test_disablesWhenSolveRateDrops() {
        let baseline = MaskingABHarness.Arm(solved: [true, true, true, true], turnCounts: [4, 4, 4, 4], retrieves: [0, 0, 0, 0])
        let masked = MaskingABHarness.Arm(solved: [true, false, false, true], turnCounts: [4, 4, 4, 4], retrieves: [0, 0, 0, 0])
        let d = MaskingABHarness.evaluate(baseline: baseline, masked: masked)
        XCTAssertFalse(d.keepMaskingOn)
        XCTAssertEqual(d.reason, "solve_rate_inferior")
    }

    func test_disablesWhenTurnCountRegresses() {
        let baseline = MaskingABHarness.Arm(solved: [true, true], turnCounts: [4, 4], retrieves: [0, 0])
        let masked = MaskingABHarness.Arm(solved: [true, true], turnCounts: [8, 9], retrieves: [0, 0])
        let d = MaskingABHarness.evaluate(baseline: baseline, masked: masked)
        XCTAssertFalse(d.keepMaskingOn)
        XCTAssertEqual(d.reason, "turn_count_regression")
    }

    func test_disablesWhenRetrieveRateRegresses() {
        let baseline = MaskingABHarness.Arm(solved: [true, true], turnCounts: [4, 4], retrieves: [0, 0])
        let masked = MaskingABHarness.Arm(solved: [true, true], turnCounts: [4, 4], retrieves: [2, 3])
        let d = MaskingABHarness.evaluate(baseline: baseline, masked: masked)
        XCTAssertFalse(d.keepMaskingOn)
        XCTAssertEqual(d.reason, "retrieve_rate_regression")
    }
}
