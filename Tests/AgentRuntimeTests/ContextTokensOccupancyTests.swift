import XCTest
@testable import AgentRuntime
import CoreModel

/// `contextTokens` is current-request context occupancy.
/// Session-cumulative billing buckets (Claude/Grok `modelUsage`, Codex `total`)
/// must not populate it — that is what inflated the Agent App header to 999%.
final class ContextTokensOccupancyTests: XCTestCase {

    // MARK: - Claude

    /// Live-bug shape: session-cumulative modelUsage with huge cacheReadInputTokens.
    /// totalTokens stays billing-correct; contextTokens must stay nil.
    func test_claude_cumulativeModelUsage_doesNotSetContextTokens() {
        // Exact field values from the proven live SQLite tokenUsage row
        // (fact 2): uncached 322 + creation 98777 + read 2757231 = 2856330 input;
        // + output 24243 = 2880573 total against a 200000 window.
        let line = #"""
        {"type":"result","subtype":"success","result":"done","modelUsage":{"claude-sonnet-4-6":{"inputTokens":322,"cacheCreationInputTokens":98777,"cacheReadInputTokens":2757231,"outputTokens":24243,"contextWindow":200000}}}
        """#
        let usage = firstTokenUsage(from: ClaudeParser().parseLine(line))
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.inputTokens, 2_856_330)
        XCTAssertEqual(usage?.outputTokens, 24_243)
        XCTAssertEqual(usage?.totalTokens, 2_880_573,
                       "totalTokens keeps cumulative billing meaning")
        XCTAssertEqual(usage?.uncachedInputTokens, 322)
        XCTAssertEqual(usage?.cacheCreationInputTokens, 98_777)
        XCTAssertEqual(usage?.cacheReadInputTokens, 2_757_231)
        XCTAssertEqual(usage?.contextWindow, 200_000)
        XCTAssertNil(usage?.contextTokens,
                     "cumulative modelUsage must not drive context occupancy (would clamp to 999%)")
    }

    func test_claude_perRequestUsage_setsContextTokensFromSingleRequestBuckets() {
        // Per-request Anthropic usage: input_tokens is uncached only; cache
        // buckets are separate. Occupancy = uncached + creation + read + output.
        let line = #"""
        {"type":"usage","usage":{"input_tokens":322,"cache_creation_input_tokens":98777,"cache_read_input_tokens":50000,"output_tokens":100,"context_window":200000}}
        """#
        let usage = firstTokenUsage(from: ClaudeParser().parseLine(line))
        XCTAssertEqual(usage?.inputTokens, 149_099,
                       "provider input includes uncached, cache creation, and cache read")
        XCTAssertEqual(usage?.totalTokens, 149_199,
                       "an interrupted run without modelUsage must retain every billed bucket")
        XCTAssertEqual(usage?.uncachedInputTokens, 322)
        XCTAssertEqual(usage?.cacheCreationInputTokens, 98_777)
        XCTAssertEqual(usage?.cacheReadInputTokens, 50_000)
        XCTAssertEqual(usage?.billedTotalTokenUnits, 322 + (98_777 * 1.25) + (50_000 * 0.1) + 100)
        XCTAssertEqual(usage?.contextWindow, 200_000)
        XCTAssertEqual(usage?.contextTokens, 322 + 98_777 + 50_000 + 100,
                       "context occupancy must sum all four single-request buckets")
        XCTAssertEqual(usage?.contextTokens, usage?.totalTokens,
                       "per-request billing and occupancy include the same reported token buckets")
    }

    /// Sampled live payload shape (fact 4): assistant → message.usage is the
    /// per-request source the gauge must use (8+504+98273+1 = 98786 ≈ 49% of 200k).
    func test_claude_assistantMessageUsage_setsContextTokensFromPerRequestBuckets() {
        let line = #"""
        {"type":"assistant","message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":8,"cache_creation_input_tokens":504,"cache_read_input_tokens":98273,"output_tokens":1,"service_tier":"standard"},"content":[{"type":"text","text":"ok"}]}}
        """#
        let usage = firstTokenUsage(from: ClaudeParser().parseLine(line))
        XCTAssertNotNil(usage, "assistant message.usage must emit tokenUsage")
        XCTAssertEqual(usage?.contextTokens, 98_786,
                       "occupancy = uncached + cache creation + cache read + output")
        XCTAssertEqual(usage?.inputTokens, 98_785)
        XCTAssertEqual(usage?.outputTokens, 1)
        XCTAssertEqual(usage?.totalTokens, 98_786,
                       "interrupted runs must not undercount cache creation/read without modelUsage")
        XCTAssertEqual(usage?.uncachedInputTokens, 8)
        XCTAssertEqual(usage?.cacheCreationInputTokens, 504)
        XCTAssertEqual(usage?.cacheReadInputTokens, 98_273)
        XCTAssertEqual(usage?.billedTotalTokenUnits, 8 + (504 * 1.25) + (98_273 * 0.1) + 1)
        XCTAssertEqual(usage?.resolvedSemantics, .incremental,
                       "each assistant message usage is an independent Claude API request")
    }

    // MARK: - Grok

    func test_grok_cumulativeModelUsage_doesNotSetContextTokens() {
        let usage = GrokParser.tokenUsage(from: [
            "modelUsage": [
                "grok-4.5": [
                    "inputTokens": 25_103,
                    "outputTokens": 18,
                    "cacheReadInputTokens": 2_757_231,
                    "contextWindow": 256_000
                ]
            ]
        ])
        XCTAssertEqual(usage?.totalTokens, 25_103 + 2_757_231 + 18)
        XCTAssertEqual(usage?.contextWindow, 256_000,
                       "Grok modelUsage may still surface contextWindow for the gauge ceiling")
        XCTAssertNil(usage?.contextTokens,
                     "cumulative modelUsage cache re-reads must not set contextTokens")
    }

    func test_grok_perRequestUsage_setsContextTokensAndContextWindow() {
        let usage = GrokParser.tokenUsage(from: [
            "usage": [
                "input_tokens": 1_000,
                "cache_read_input_tokens": 4_000,
                "output_tokens": 50,
                "total_tokens": 5_050,
                "context_window": 256_000
            ]
        ])
        XCTAssertEqual(usage?.totalTokens, 5_050)
        XCTAssertEqual(usage?.inputTokens, 5_000)
        XCTAssertEqual(usage?.contextWindow, 256_000)
        XCTAssertEqual(usage?.contextTokens, 1_000 + 4_000 + 50,
                       "per-request occupancy = uncached + cache read + output")
    }

    func test_grokACP_usageUpdate_setsContextTokens() {
        let mapper = GrokACPEventMapper(sessionId: "ctx-tokens")
        let events = mapper.consumeSessionUpdate([
            "sessionUpdate": "usage_update",
            "usage": [
                "inputTokens": 12_000,
                "outputTokens": 80,
                "totalTokens": 12_080,
                "contextWindow": 256_000
            ]
        ])
        let usage = firstTokenUsage(from: events)
        XCTAssertEqual(usage?.totalTokens, 12_080)
        XCTAssertEqual(usage?.contextWindow, 256_000)
        XCTAssertEqual(usage?.contextTokens, 12_080,
                       "ACP usage_update is per-request; occupancy matches totalTokens")
    }

    // MARK: - Helpers

    private func firstTokenUsage(from events: [AssistantEvent]) -> AssistantTokenUsage? {
        events.compactMap { event -> AssistantTokenUsage? in
            if case .tokenUsage(let usage) = event { return usage }
            return nil
        }.first
    }
}
