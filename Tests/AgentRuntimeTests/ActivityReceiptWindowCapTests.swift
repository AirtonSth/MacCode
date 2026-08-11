import XCTest
@testable import AgentRuntime

/// Bounds for Subagents activity receipt materialization (memory loop).
final class ActivityReceiptWindowCapTests: XCTestCase {
    func test_activityReceiptDefaultWindows() {
        XCTAssertEqual(AgentOrchestrationRuntime.defaultActivityReceiptLimit, 128)
        XCTAssertEqual(AgentOrchestrationRuntime.defaultChildActivityReceiptLimit, 64)
        // Child window must stay well below primary so nested storms cannot
        // dominate the selected-thread history budget.
        XCTAssertLessThan(
            AgentOrchestrationRuntime.defaultChildActivityReceiptLimit,
            AgentOrchestrationRuntime.defaultActivityReceiptLimit
        )
    }

    func test_retentionEstimate_256PrimaryTo128_and_128ChildTo64() {
        let priorPrimary = 256
        let primary = AgentOrchestrationRuntime.defaultActivityReceiptLimit
        let primaryReduction = Double(priorPrimary - primary) / Double(priorPrimary)
        XCTAssertGreaterThan(primaryReduction, 0.49)
        XCTAssertEqual(primary, 128)

        let priorChild = 128
        let child = AgentOrchestrationRuntime.defaultChildActivityReceiptLimit
        let childReduction = Double(priorChild - child) / Double(priorChild)
        XCTAssertGreaterThan(childReduction, 0.49)
        XCTAssertEqual(child, 64)

        // Basis: modest admission receipt ≈ 400B (UUIDs + digests + model strings).
        // Primary: 256 × 400B ≈ 102KB → 128 × 400B ≈ 51KB (−50%).
        // Child: 128 × 400B ≈ 51KB → 64 × 400B ≈ 26KB (−50%).
        let perReceipt = 400
        XCTAssertEqual(priorPrimary * perReceipt, 102_400)
        XCTAssertEqual(primary * perReceipt, 51_200)
        XCTAssertEqual(priorChild * perReceipt, 51_200)
        XCTAssertEqual(child * perReceipt, 25_600)
    }
}
