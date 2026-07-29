import XCTest
@testable import CoreModel

/// `contextTokens` is optional and must decode older persisted rows that omit it.
final class AssistantTokenUsageContextTokensTests: XCTestCase {

    func test_decode_missingContextTokensKey_isNil() throws {
        // Shape of the live bug row (fact 2) before contextTokens existed.
        let json = Data(#"""
        {"uncachedInputTokens":322,"cacheCreationInputTokens":98777,"cacheReadInputTokens":2757231,"inputTokens":2856330,"outputTokens":24243,"totalTokens":2880573,"contextWindow":200000}
        """#.utf8)
        let usage = try JSONDecoder().decode(AssistantTokenUsage.self, from: json)
        XCTAssertEqual(usage.totalTokens, 2_880_573)
        XCTAssertEqual(usage.contextWindow, 200_000)
        XCTAssertNil(usage.contextTokens,
                     "older SQLite/JSON rows without contextTokens must decode, not fail")
    }

    func test_roundTrip_preservesContextTokens() throws {
        let original = AssistantTokenUsage(
            inputTokens: 1_000,
            outputTokens: 40,
            totalTokens: 1_040,
            contextWindow: 200_000,
            contextTokens: 1_040
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AssistantTokenUsage.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.contextTokens, 1_040)
    }

    func test_defaultInit_contextTokensIsNil() {
        let usage = AssistantTokenUsage(inputTokens: 1, outputTokens: 1, totalTokens: 2)
        XCTAssertNil(usage.contextTokens)
    }
}
