import XCTest
@testable import AppShell
import AgentRuntime
import CoreModel

final class TokenSaverWidgetDigestTests: XCTestCase {
    func testPayloadMatchesGlanceableCardContract() {
        let body = TokenSaverWidgetDigest.payload(
            enabled: true,
            subscribed: true,
            scope: .week,
            estimatedSaveTokens: 2_170_000_000,
            claudeUsedPercent: 94,
            codexUsedPercent: 1,
            grokUsedPercent: 87,
            isRefreshing: false,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(body["enabled"], .bool(true))
        XCTAssertEqual(body["subscribed"], .bool(true))
        XCTAssertEqual(body["scope"], .string("week"))
        XCTAssertEqual(body["estimated_save_tokens"], .number(2_170_000_000))
        XCTAssertEqual(body["claude_used_percent"], .number(94))
        XCTAssertEqual(body["codex_used_percent"], .number(1))
        XCTAssertEqual(body["grok_used_percent"], .number(87))
        XCTAssertEqual(body["token_saver_ring_available"], .bool(true))
        // 2170M / 35M goal clamps to 1.0
        XCTAssertEqual(body["token_saver_progress"], .number(1.0))
        XCTAssertEqual(body["updated_at_ms"], .number(1_700_000_000_000))
    }

    func testSavingsProgressUsesFixedGoals() {
        XCTAssertEqual(
            TokenSaverWidgetDigest.savingsProgress(savedTokens: 5_000_000, scope: .today),
            1.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TokenSaverWidgetDigest.savingsProgress(savedTokens: 17_500_000, scope: .week),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TokenSaverWidgetDigest.savingsProgress(savedTokens: 0, scope: .week),
            0,
            accuracy: 0.0001
        )
    }
    func testPayloadDefaultsToTodayScope() {
        let body = TokenSaverWidgetDigest.payload(
            enabled: true,
            subscribed: true,
            estimatedSaveTokens: 1_250_000,
            claudeUsedPercent: 10,
            codexUsedPercent: 20,
            grokUsedPercent: 30,
            isRefreshing: false
        )

        XCTAssertEqual(body["scope"], .string("today"))
        XCTAssertEqual(body["token_saver_progress"], .number(0.25))
    }

}
