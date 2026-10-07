import XCTest
import Foundation
import AgentRuntime
@testable import AppShell

/// Pure copy behind the sidebar's provider account-usage control. Token Saver
/// was removed; these figures are what is left of its card, so they must stay
/// honest provider usage and never read as savings.
final class AccountUsageSidebarTests: XCTestCase {

    // MARK: - lastUpdatedLabel

    func test_lastUpdatedLabel_nil_returnsNever() {
        // WHY: the user has never refreshed; VoiceOver must read "Never" so they
        // know no data has been fetched rather than hearing a stale timestamp.
        XCTAssertEqual(SidebarRootView.lastUpdatedLabel(nil, now: Date()), "Never")
    }

    func test_lastUpdatedLabel_underOneMinute_returnsJustNow() {
        // WHY: a 30-second-old refresh should read "just now", not "0m ago" which
        // would look like a stale refresh.
        let now = Date()
        XCTAssertEqual(SidebarRootView.lastUpdatedLabel(now.addingTimeInterval(-30), now: now), "Updated just now")
    }

    func test_lastUpdatedLabel_exactlyZeroSeconds_returnsJustNow() {
        let now = Date()
        XCTAssertEqual(SidebarRootView.lastUpdatedLabel(now, now: now), "Updated just now")
    }

    func test_lastUpdatedLabel_twoMinutesAgo_returns2mAgo() {
        let now = Date()
        XCTAssertEqual(SidebarRootView.lastUpdatedLabel(now.addingTimeInterval(-120), now: now), "Updated 2m ago")
    }

    func test_lastUpdatedLabel_oneHourAgo_returns1hAgo() {
        let now = Date()
        XCTAssertEqual(SidebarRootView.lastUpdatedLabel(now.addingTimeInterval(-3600), now: now), "Updated 1h ago")
    }

    func test_lastUpdatedLabel_moreThan24HoursAgo_returnsCapped() {
        // WHY: very stale refreshes must not produce unwieldy strings like
        // "Updated 72h ago"; the cap keeps popover layout stable.
        let now = Date()
        XCTAssertEqual(SidebarRootView.lastUpdatedLabel(now.addingTimeInterval(-86400 * 3), now: now), "Updated 24h+ ago")
    }

    func test_lastUpdatedLabel_futureDate_returnsJustNow() {
        // WHY: clock skew can produce a future date; elapsed < 0 must not
        // produce a negative label.
        let now = Date()
        XCTAssertEqual(SidebarRootView.lastUpdatedLabel(now.addingTimeInterval(60), now: now), "Updated just now")
    }

    // MARK: - Card subtitle

    func test_subtitle_signedOut_asksToSignInEvenWithLocalUsage() {
        // WHY: account usage is refreshed only for a signed-in account, so the
        // signed-out card must say why it shows no account figures.
        XCTAssertEqual(
            AccountUsageDisplay.subtitle(signedIn: false, usedTokens: 5_000),
            "Sign in to track Claude + Codex + Grok usage"
        )
    }

    func test_subtitle_signedIn_reportsUsedTokensAcrossProviders() {
        XCTAssertEqual(
            AccountUsageDisplay.subtitle(signedIn: true, usedTokens: 1_355_000),
            "Used 1.4M in Claude + Codex + Grok"
        )
    }

    func test_subtitle_signedInWithoutUsage_doesNotInventAFigure() {
        XCTAssertEqual(
            AccountUsageDisplay.subtitle(signedIn: true, usedTokens: 0),
            "No provider usage recorded yet"
        )
    }

    func test_formatTokenCount_switchesToMillionsAtOneMillion() {
        // WHY: million-scale totals must read as "M", not as four-digit "K"
        // (e.g. 1909K). The threshold is exactly 1M.
        XCTAssertEqual(AccountUsageDisplay.formatTokenCount(99_000), "99K")
        XCTAssertEqual(AccountUsageDisplay.formatTokenCount(480_000), "480K")
        XCTAssertEqual(AccountUsageDisplay.formatTokenCount(1_000_000), "1.0M")
        XCTAssertEqual(AccountUsageDisplay.formatTokenCount(999_999), "1000K")
        XCTAssertEqual(AccountUsageDisplay.formatTokenCount(950), "950")
    }

    // MARK: - Provider captions

    func test_sessionCaption_sessionDataPresent_usesSessionLabel() {
        // WHY: when a live session probe exists, the caption must stay "Session used"
        // so providers with real session data are not re-labelled as weekly.
        let caption = AccountUsageDisplay.sessionCaption(
            effectiveSessionUsedPercent: 1,
            effectiveWeeklyUsedPercent: 84
        )
        XCTAssertEqual(caption, "Session used 1%")
    }

    func test_sessionCaption_sessionDataMissing_explainsWeeklyFallback() {
        // WHY: bare "Week used X%" next to Claude's "Session used 1%" looked like a
        // glitch; the fallback must name that session data is missing.
        let caption = AccountUsageDisplay.sessionCaption(
            effectiveSessionUsedPercent: nil,
            effectiveWeeklyUsedPercent: 47
        )
        XCTAssertEqual(caption, "Week used 47% (no session data)")
    }

    func test_sessionCaption_prefersSessionOverWeeklyWhenBothPresent() {
        let caption = AccountUsageDisplay.sessionCaption(
            effectiveSessionUsedPercent: 12.4,
            effectiveWeeklyUsedPercent: 90
        )
        XCTAssertEqual(caption, "Session used 12%")
    }

    func test_sessionCaption_nothingLoaded_saysSo() {
        XCTAssertEqual(
            AccountUsageDisplay.sessionCaption(effectiveSessionUsedPercent: nil, effectiveWeeklyUsedPercent: nil),
            "Session usage not loaded"
        )
    }

    func test_weeklyCaption_withoutProviderPercent_doesNotInventALimit() {
        // WHY: the old card divided local tokens by a made-up 1M weekly limit.
        // Without a provider-reported percentage there is no honest figure.
        XCTAssertEqual(AccountUsageDisplay.weeklyCaption(effectiveWeeklyUsedPercent: nil), "Weekly usage not loaded")
        XCTAssertEqual(AccountUsageDisplay.weeklyCaption(effectiveWeeklyUsedPercent: 63.6), "Weekly used 64%")
    }

    func test_providers_coverClaudeCodexAndGrok() {
        XCTAssertEqual(AccountUsageDisplay.providers, [.claude, .codex, .grok])
    }

    func test_emptyUsageSnapshot_includesEveryListedProvider() {
        // WHY: empty state must reserve a row for each provider before its first
        // run or account-usage refresh.
        let providers = Set(ProviderUsageSnapshot.empty().providers.map(\.provider))
        for provider in AccountUsageDisplay.providers {
            XCTAssertTrue(providers.contains(provider), "missing \(provider)")
        }
    }
}
