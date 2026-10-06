import XCTest
@testable import AppShell
import AgentRuntime
import CoreModel

final class AccountUsageWidgetDigestTests: XCTestCase {
    func testIdenticalDigestsAreNotRepublished() {
        // WHY (EV-25): every account-usage cycle republished a structurally
        // identical digest (only updated_at_ms moved) — 155 persisted events and
        // fan-outs per 10 min. Only a rendered field change may publish.
        func snapshot(claudeWeekly: Double) -> TokenSaverUsageSnapshot {
            TokenSaverUsageSnapshot(period: .sevenDays, providers: [
                TokenSaverProviderUsage(
                    provider: .claude,
                    weeklyUsedPercent: claudeWeekly,
                    weeklyWindowDurationMinutes: 10_080,
                    weeklyResetsAt: Date().addingTimeInterval(86_400)
                )
            ])
        }
        func publish(claudeWeekly: Double, at seconds: TimeInterval) {
            AccountUsageWidgetDigest.publish(
                subscribed: true,
                snapshot: snapshot(claudeWeekly: claudeWeekly),
                isRefreshing: false,
                updatedAt: Date(timeIntervalSince1970: seconds)
            )
        }
        publish(claudeWeekly: 10, at: 1)
        let suppressedBefore = AccountUsageWidgetDigest.suppressedDuplicatePublishCountForTesting
        publish(claudeWeekly: 10, at: 2)
        XCTAssertEqual(
            AccountUsageWidgetDigest.suppressedDuplicatePublishCountForTesting,
            suppressedBefore + 1,
            "same content with a newer timestamp must be suppressed"
        )
        publish(claudeWeekly: 20, at: 3)
        XCTAssertEqual(
            AccountUsageWidgetDigest.suppressedDuplicatePublishCountForTesting,
            suppressedBefore + 1,
            "a changed provider percentage must publish"
        )
        XCTAssertEqual(AccountUsageWidgetDigest.lastCachedBody()?["claude_used_percent"], .number(20))
    }

    func testPayloadCarriesProviderPercentagesWithTokenSaverOff() {
        // WHY: iOS still decodes the deprecated token_saver.digest event for its
        // provider rings. Token Saver is gone, so it must read as off with no
        // savings, while the account usage percentages keep flowing.
        let body = AccountUsageWidgetDigest.payload(
            subscribed: true,
            scope: .week,
            claudeUsedPercent: 94,
            codexUsedPercent: 1,
            grokUsedPercent: 187,
            isRefreshing: false,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(body["enabled"], .bool(false))
        XCTAssertEqual(body["subscribed"], .bool(true))
        XCTAssertEqual(body["scope"], .string("week"))
        XCTAssertEqual(body["estimated_save_tokens"], .number(0))
        XCTAssertEqual(body["token_saver_progress"], .number(0))
        XCTAssertEqual(body["token_saver_ring_available"], .bool(false))
        XCTAssertEqual(body["claude_used_percent"], .number(94))
        XCTAssertEqual(body["codex_used_percent"], .number(1))
        XCTAssertEqual(body["grok_used_percent"], .number(100), "percentages are clamped to 0...100")
        XCTAssertEqual(body["updated_at_ms"], .number(1_700_000_000_000))
    }

    func testPayloadDefaultsToTodayScope() {
        let body = AccountUsageWidgetDigest.payload(
            subscribed: true,
            claudeUsedPercent: 10,
            codexUsedPercent: 20,
            grokUsedPercent: 30,
            isRefreshing: false
        )

        XCTAssertEqual(body["scope"], .string("today"))
    }
}
