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

    // MARK: - Footer rings

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func test_ringProgress_prefersLiveSessionOverWeekly_likeTheIOSRings() {
        // WHY: the paired iPhone rings read session ?? weekly (digest "today").
        // A different rule here would show two numbers for one account.
        let usage = ProviderTokenUsage(
            provider: .claude,
            currentSessionUsedPercent: 12,
            currentSessionResetsAt: now.addingTimeInterval(3_600),
            weeklyUsedPercent: 90,
            weeklyResetsAt: now.addingTimeInterval(86_400)
        )
        XCTAssertEqual(try XCTUnwrap(AccountUsageDisplay.ringProgress(usage, now: now)), 0.12, accuracy: 0.0001)
    }

    func test_ringProgress_expiredSessionFallsBackToWeekly() {
        let usage = ProviderTokenUsage(
            provider: .codex,
            currentSessionUsedPercent: 70,
            currentSessionResetsAt: now.addingTimeInterval(-60),
            weeklyUsedPercent: 42,
            weeklyResetsAt: now.addingTimeInterval(86_400)
        )
        XCTAssertEqual(try XCTUnwrap(AccountUsageDisplay.ringProgress(usage, now: now)), 0.42, accuracy: 0.0001)
    }

    func test_ringProgress_nothingLoaded_isNilNotZero() {
        // WHY: an unloaded provider must draw a faint "no data" ring, never a
        // ring that reads as 0% used.
        XCTAssertNil(AccountUsageDisplay.ringProgress(ProviderTokenUsage(provider: .grok), now: now))
    }

    func test_ringProgress_expiredWeekReadsZero_andOverLimitClampsToFull() {
        let expired = ProviderTokenUsage(provider: .grok, weeklyUsedPercent: 56, weeklyResetsAt: now.addingTimeInterval(-1))
        XCTAssertEqual(AccountUsageDisplay.ringProgress(expired, now: now), 0)
        let over = ProviderTokenUsage(provider: .grok, weeklyUsedPercent: 130, weeklyResetsAt: now.addingTimeInterval(60))
        XCTAssertEqual(AccountUsageDisplay.ringProgress(over, now: now), 1)
    }

    private func mixedSnapshot() -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(period: .sevenDays, providers: [
            ProviderTokenUsage(provider: .claude, actualProviderTokens: 27_605_158_124),
            ProviderTokenUsage(provider: .codex, weeklyUsedPercent: 42, weeklyResetsAt: now.addingTimeInterval(86_400)),
            ProviderTokenUsage(
                provider: .grok,
                currentSessionUsedPercent: 12,
                currentSessionResetsAt: now.addingTimeInterval(600),
                weeklyUsedPercent: 56,
                weeklyResetsAt: now.addingTimeInterval(86_400)
            ),
            ProviderTokenUsage(provider: .distill, actualProviderTokens: 3_852_818_295, weeklyUsedPercent: 99)
        ])
    }

    func test_ringsAccessibilityValue_readsEveryProviderAndSkipsDistill() {
        // WHY: the rings are the only always-visible usage signal, so VoiceOver
        // must hear each real percentage and which window it is from; a missing
        // probe says "not loaded" and Distill never joins Claude/Codex/Grok
        // (the old footer summed it into a lifetime "40361M").
        XCTAssertEqual(
            AccountUsageDisplay.ringsAccessibilityValue(signedIn: true, snapshot: mixedSnapshot(), now: now),
            "Claude not loaded, Codex week 42%, Grok session 12%"
        )
    }

    func test_ringsHelp_listsRingsOuterToInnerAndOffersDetails() {
        XCTAssertEqual(
            AccountUsageDisplay.ringsHelp(signedIn: true, snapshot: mixedSnapshot(), now: now),
            "Account usage\nClaude not loaded\nCodex week 42%\nGrok session 12%\nClick for details"
        )
    }

    func test_rings_signedOut_askToSignInInsteadOfShowingFigures() {
        // WHY: account usage refreshes only for a signed-in account, so the
        // signed-out rings must say why they show nothing.
        XCTAssertEqual(
            AccountUsageDisplay.ringsAccessibilityValue(signedIn: false, snapshot: mixedSnapshot(), now: now),
            "Sign in to track Claude, Codex and Grok usage"
        )
        XCTAssertEqual(
            AccountUsageDisplay.ringsHelp(signedIn: false, snapshot: mixedSnapshot(), now: now),
            "Sign in to track Claude, Codex and Grok usage"
        )
    }

    func test_footer_mountsRingsLeftOfInsomniaToggleInsteadOfAFullWidthRow() throws {
        // WHY: the owner asked for subtle rings beside Insomnia, not a second
        // full-width "Account usage" row; both Workspaces and Bots share this footer.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sidebar = try String(contentsOf: root.appendingPathComponent("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        let footerStart = try XCTUnwrap(sidebar.range(of: "private var footerUtilityControls: some View {"))
        let footer = String(sidebar[footerStart.upperBound...].prefix(400))
        XCTAssertFalse(footer.contains("AccountUsageSidebarControl"), "no standalone account-usage row")
        let rowStart = try XCTUnwrap(sidebar.range(of: "private var insomniaControl: some View {"))
        let row = String(sidebar[rowStart.upperBound...].prefix(600))
        let rings = try XCTUnwrap(row.range(of: "AccountUsageSidebarControl(vm: vm, onOpenAccount: onOpenAccount)"))
        let toggle = try XCTUnwrap(row.range(of: "insomniaToggle"))
        XCTAssertLessThan(rings.lowerBound, toggle.lowerBound, "rings sit to the left of the toggle")
        let control = try String(
            contentsOf: root.appendingPathComponent("Sources/AppShell/AccountUsageSidebarControl.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(control.contains("chart.bar.xaxis"))
        XCTAssertFalse(control.contains("in Claude + Codex + Grok"), "the lifetime token sum is gone from the footer")
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
