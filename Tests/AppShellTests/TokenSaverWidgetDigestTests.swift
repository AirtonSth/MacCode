import XCTest
@testable import AppShell
import AgentRuntime
import CoreModel

final class TokenSaverWidgetDigestTests: XCTestCase {
    func testIdenticalDigestsAreNotRepublished() {
        // WHY (EV-25): every account-usage cycle republished a structurally
        // identical digest (only updated_at_ms moved) — 155 persisted events and
        // fan-outs per 10 min. Only a rendered field change may publish.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2Digest-\(UUID().uuidString)", isDirectory: true)
        let snapshot = TokenSaverUsageStore(appSupportDirectory: dir).load()
        func publish(saved: Int, at seconds: TimeInterval) {
            TokenSaverWidgetDigest.publish(
                enabled: true,
                subscribed: true,
                todaySavedTokens: saved,
                weekSavedTokens: saved,
                snapshot: snapshot,
                isRefreshing: false,
                updatedAt: Date(timeIntervalSince1970: seconds)
            )
        }
        publish(saved: 1_000, at: 1)
        let suppressedBefore = TokenSaverWidgetDigest.suppressedDuplicatePublishCountForTesting
        publish(saved: 1_000, at: 2)
        XCTAssertEqual(
            TokenSaverWidgetDigest.suppressedDuplicatePublishCountForTesting,
            suppressedBefore + 1,
            "same content with a newer timestamp must be suppressed"
        )
        publish(saved: 2_000, at: 3)
        XCTAssertEqual(
            TokenSaverWidgetDigest.suppressedDuplicatePublishCountForTesting,
            suppressedBefore + 1,
            "a changed savings figure must publish"
        )
        XCTAssertEqual(TokenSaverWidgetDigest.lastCachedBody()?["estimated_save_tokens"], .number(2_000))
    }

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
        // 2170M / 700M goal clamps to 1.0
        XCTAssertEqual(body["token_saver_progress"], .number(1.0))
        XCTAssertEqual(body["updated_at_ms"], .number(1_700_000_000_000))
    }

    func testSavingsProgressUsesFixedGoals() {
        XCTAssertEqual(TokenSaverWidgetDigest.savingsGoalTokens(scope: .today), 100_000_000)
        XCTAssertEqual(TokenSaverWidgetDigest.savingsGoalTokens(scope: .week), 700_000_000)
        XCTAssertEqual(
            TokenSaverWidgetDigest.savingsProgress(savedTokens: 100_000_000, scope: .today),
            1.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TokenSaverWidgetDigest.savingsProgress(savedTokens: 350_000_000, scope: .week),
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
            estimatedSaveTokens: 25_000_000,
            claudeUsedPercent: 10,
            codexUsedPercent: 20,
            grokUsedPercent: 30,
            isRefreshing: false
        )

        XCTAssertEqual(body["scope"], .string("today"))
        XCTAssertEqual(body["token_saver_progress"], .number(0.25))
    }

}
