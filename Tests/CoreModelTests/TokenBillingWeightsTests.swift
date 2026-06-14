import XCTest
@testable import CoreModel

final class TokenBillingWeightsTests: XCTestCase {
    func test_assistantTokenUsageComputesProviderCacheWeightedUnits() {
        let usage = AssistantTokenUsage(
            inputTokens: 1_600,
            outputTokens: 40,
            totalTokens: 1_640,
            uncachedInputTokens: 1_000,
            cacheCreationInputTokens: 400,
            cacheReadInputTokens: 200
        )

        XCTAssertEqual(usage.billedInputTokenUnits, 1_520, accuracy: 0.001)
        XCTAssertEqual(usage.billedTotalTokenUnits, 1_560, accuracy: 0.001)
    }

    func test_assistantTokenUsageTreatsMissingSplitAsUncached() {
        let usage = AssistantTokenUsage(inputTokens: 500, outputTokens: 50, totalTokens: 550)

        XCTAssertEqual(usage.billedInputTokenUnits, 500, accuracy: 0.001)
        XCTAssertEqual(usage.billedTotalTokenUnits, 550, accuracy: 0.001)
    }
}
