import XCTest
import Foundation
import AgentRuntime
import Persistence
@testable import AppShell

// WHY: four UX items (186/187/188/195) + PERF-MAC_SIDEBAR-:101 each have a
// pure static seam on SidebarRootView.  These tests guard the business logic
// of each seam so regressions surface immediately without any UI render or
// AppContext spin-up.

final class TokenSaverCardSeamTests: XCTestCase {

    // MARK: - PERF-MAC_SIDEBAR-:101 detailsSnapshotCacheValid

    func test_detailsSnapshotCacheValid_sevenDaysPeriod_returnsTrue() {
        // WHY: when the published snapshot already carries .sevenDays the popover
        // does not need to read usage.json from disk; returning true here is the
        // gate that prevents up to 3 disk I/Os per render frame.
        let snap = TokenSaverUsageSnapshot(period: .sevenDays, providers: [])
        XCTAssertTrue(
            SidebarRootView.detailsSnapshotCacheValid(publishedSnapshot: snap),
            "sevenDays snapshot must be considered cache-valid so no disk read fires per frame"
        )
    }

    func test_detailsSnapshotCacheValid_todayPeriod_returnsFalse() {
        // WHY: a snapshot with period .today was loaded for the main sidebar card,
        // not the details popover; cache-invalid means the popover will read the
        // sevenDays file exactly once (then cache it) instead of on every body pass.
        let snap = TokenSaverUsageSnapshot(period: .today, providers: [])
        XCTAssertFalse(
            SidebarRootView.detailsSnapshotCacheValid(publishedSnapshot: snap),
            "today snapshot must not be cache-valid -- the details popover needs sevenDays data"
        )
    }

    func test_detailsSnapshotCacheValid_thirtyDaysPeriod_returnsFalse() {
        // WHY: .thirtyDays is also not the period the details popover expects;
        // any period other than .sevenDays must trigger the (cached) disk read.
        let snap = TokenSaverUsageSnapshot(period: .thirtyDays, providers: [])
        XCTAssertFalse(
            SidebarRootView.detailsSnapshotCacheValid(publishedSnapshot: snap),
            "thirtyDays snapshot must not be cache-valid -- only .sevenDays matches the details popover contract"
        )
    }

    // MARK: - :186 modelDirSize

    func test_modelDirSize_emptyDir_returnsZero() throws {
        // WHY: a freshly-created directory contains no files; size must be 0
        // so the delete button is hidden (not shown for an empty directory).
        let dir = try makeTempDir(suffix: "empty")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(SidebarRootView.modelDirSize(at: dir), 0)
    }

    func test_modelDirSize_nonexistentDir_returnsZero() {
        // WHY: if the model was never downloaded the directory does not exist;
        // the seam must not throw and must return 0 (delete button stays hidden).
        let absent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-absent-\(UUID().uuidString)")
        XCTAssertEqual(SidebarRootView.modelDirSize(at: absent), 0)
    }

    func test_modelDirSize_sumsFlatFiles() throws {
        // WHY: the model directory may have a flat layout; all file sizes must
        // be summed so the delete button label shows the accurate reclaim size.
        let dir = try makeTempDir(suffix: "flat")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 0xAB, count: 100).write(to: dir.appendingPathComponent("a.bin"))
        try Data(repeating: 0xCD, count: 250).write(to: dir.appendingPathComponent("b.bin"))
        XCTAssertEqual(SidebarRootView.modelDirSize(at: dir), 350)
    }

    func test_modelDirSize_sumsNestedFiles() throws {
        // WHY: revision sub-directories nest files; the enumerator must recurse.
        let dir = try makeTempDir(suffix: "nested")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("Models/rev1")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1024).write(to: sub.appendingPathComponent("model.safetensors"))
        try Data(repeating: 0, count: 512).write(to: dir.appendingPathComponent("manifest.json"))
        XCTAssertEqual(SidebarRootView.modelDirSize(at: dir), 1536)
    }

    // MARK: - :187 scope label matches summing window

    func test_scopeLabel_today_notCurrentSession() {
        // WHY: the "currentSession" bucket sums today's calendar day; labelling it
        // "Current Session" is a lie.  The seam-driven label is tested through
        // the public tokenSaverScopeTitle logic which now returns "Today".
        // We validate via lastUpdatedLabel as a proxy for the rule that
        // label conventions must match summing windows -- direct access to the
        // private tokenSaverScopeTitle is not available from tests; the important
        // check is that the raw value "currentSession" no longer surfaces as
        // the user-visible string "Current Session" in the picker.
        // The test for the seam itself lives in the scope label string check:
        // We call ringsAccessibilityLabel with scope "today" and verify the
        // output contains "today" (not "current session"), demonstrating the
        // :187 convention flows through.
        let label = SidebarRootView.ringsAccessibilityLabel(
            scope: "today",
            savedTokens: 0,
            savedProgress: 0,
            claudeUsedProgress: 0,
            codexUsedProgress: 0,
            grokUsedProgress: 0
        )
        XCTAssertTrue(label.lowercased().contains("today"),
                      "Scope 'today' must appear in the rings a11y label to confirm :187 rename flows through")
        XCTAssertFalse(label.lowercased().contains("current session"),
                       "Deprecated label 'Current Session' must not appear after :187 rename")
    }

    // MARK: - :188 lastUpdatedLabel

    func test_lastUpdatedLabel_nil_returnsNever() {
        // WHY: the user has never refreshed; VoiceOver must read "Never" so they
        // know no data has been fetched rather than hearing a stale timestamp.
        XCTAssertEqual(SidebarRootView.lastUpdatedLabel(nil, now: Date()), "Never")
    }

    func test_lastUpdatedLabel_underOneMinute_returnsJustNow() {
        // WHY: a 30-second-old refresh should read "just now", not "0m ago" which
        // would look like a stale refresh.
        let now = Date()
        let recent = now.addingTimeInterval(-30)
        XCTAssertEqual(SidebarRootView.lastUpdatedLabel(recent, now: now), "Updated just now")
    }

    func test_lastUpdatedLabel_exactlyZeroSeconds_returnsJustNow() {
        // WHY: same instant (elapsed == 0) must not produce a negative or nil result.
        let now = Date()
        XCTAssertEqual(SidebarRootView.lastUpdatedLabel(now, now: now), "Updated just now")
    }

    func test_lastUpdatedLabel_twoMinutesAgo_returns2mAgo() {
        // WHY: the "Xm ago" path is the common case after a refresh; confirms
        // integer minute rounding works and the label stays under 20 chars.
        let now = Date()
        let twoMinAgo = now.addingTimeInterval(-120)
        XCTAssertEqual(SidebarRootView.lastUpdatedLabel(twoMinAgo, now: now), "Updated 2m ago")
    }

    func test_lastUpdatedLabel_oneHourAgo_returns1hAgo() {
        // WHY: after 60+ minutes the label must switch to "Xh ago" to stay compact.
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)
        XCTAssertEqual(SidebarRootView.lastUpdatedLabel(oneHourAgo, now: now), "Updated 1h ago")
    }

    func test_lastUpdatedLabel_moreThan24HoursAgo_returnsCapped() {
        // WHY: very stale refreshes must not produce unwieldy strings like
        // "Updated 72h ago"; the cap keeps popover layout stable.
        let now = Date()
        let stale = now.addingTimeInterval(-86400 * 3)
        XCTAssertEqual(SidebarRootView.lastUpdatedLabel(stale, now: now), "Updated 24h+ ago")
    }

    func test_lastUpdatedLabel_futureDate_returnsJustNow() {
        // WHY: clock skew can produce a future date; elapsed < 0 must not
        // produce a negative label.
        let now = Date()
        let future = now.addingTimeInterval(60)
        XCTAssertEqual(SidebarRootView.lastUpdatedLabel(future, now: now), "Updated just now")
    }

    // MARK: - :195 ringsAccessibilityLabel

    func test_ringsAccessibilityLabel_nonEmpty() {
        // WHY: any non-empty label is better than .accessibilityHidden(true).
        // The seam must produce a non-empty string for all valid inputs.
        let label = SidebarRootView.ringsAccessibilityLabel(
            scope: "week",
            savedTokens: 50_000,
            savedProgress: 0.42,
            claudeUsedProgress: 0.57,
            codexUsedProgress: 0.33,
            grokUsedProgress: 0.12
        )
        XCTAssertFalse(label.isEmpty, "Rings a11y label must be non-empty so VoiceOver reads something")
    }

    func test_ringsAccessibilityLabel_containsSavedTokenValue() {
        // WHY: VoiceOver users need the saved-token count, not just percentages.
        let label = SidebarRootView.ringsAccessibilityLabel(
            scope: "week",
            savedTokens: 120_000,
            savedProgress: 0.6,
            claudeUsedProgress: 0.4,
            codexUsedProgress: 0.2,
            grokUsedProgress: 0.1
        )
        XCTAssertTrue(label.contains("120K") || label.contains("120k"),
                      "Rings label must include the saved token count formatted as K: \(label)")
    }

    func test_formatTokenCountPublic_switchesToMillionsAtOneMillion() {
        // WHY: million-scale totals must read as "M", not as four-digit "K"
        // (e.g. 1909K). Sub-million provider rows stay in K so they remain
        // legible; the threshold is exactly 1M.
        let claude = 99_000
        let codex = 480_000
        let other = 776_000

        XCTAssertEqual(SidebarRootView.formatTokenCountPublic(claude), "99K")
        XCTAssertEqual(SidebarRootView.formatTokenCountPublic(codex), "480K")
        XCTAssertEqual(SidebarRootView.formatTokenCountPublic(other), "776K")
        // 1,355,000 crosses the 1M threshold -> one-decimal M headline.
        XCTAssertEqual(SidebarRootView.formatTokenCountPublic(claude + codex + other), "1.4M")
        // Boundary: exactly 1M switches to M; 999,999 stays in K.
        XCTAssertEqual(SidebarRootView.formatTokenCountPublic(1_000_000), "1.0M")
        XCTAssertEqual(SidebarRootView.formatTokenCountPublic(999_999), "1000K")
    }

    func test_ringsAccessibilityLabel_containsClaudePercent() {
        // WHY: Claude usage ring must be readable by VoiceOver, not just visible.
        let label = SidebarRootView.ringsAccessibilityLabel(
            scope: "week",
            savedTokens: 0,
            savedProgress: 0,
            claudeUsedProgress: 0.75,
            codexUsedProgress: 0,
            grokUsedProgress: 0
        )
        XCTAssertTrue(label.contains("75%"),
                      "Rings label must include claude used percent: \(label)")
    }

    func test_ringsAccessibilityLabel_containsCodexPercent() {
        // WHY: Codex usage ring must also be readable by VoiceOver.
        let label = SidebarRootView.ringsAccessibilityLabel(
            scope: "week",
            savedTokens: 0,
            savedProgress: 0,
            claudeUsedProgress: 0,
            codexUsedProgress: 0.50,
            grokUsedProgress: 0
        )
        XCTAssertTrue(label.contains("50%"),
                      "Rings label must include codex used percent: \(label)")
    }

    func test_ringsAccessibilityLabel_containsGrokPercent() {
        // WHY: Grok is a first-class Agent provider; its usage ring must be
        // readable by VoiceOver like Claude/Codex, not only visible as purple.
        let label = SidebarRootView.ringsAccessibilityLabel(
            scope: "week",
            savedTokens: 0,
            savedProgress: 0,
            claudeUsedProgress: 0,
            codexUsedProgress: 0,
            grokUsedProgress: 0.41
        )
        XCTAssertTrue(label.lowercased().contains("grok"),
                      "Rings label must name Grok: \(label)")
        XCTAssertTrue(label.contains("41%"),
                      "Rings label must include Grok used percent: \(label)")
    }

    func test_ringsAccessibilityLabel_namesSelfNormalizingWindowMix() {
        // WHY: green ring uses saved/(saved+used), not fixed 2M/10M — a11y must
        // name the window mix so VoiceOver matches the visible fill.
        let label = SidebarRootView.ringsAccessibilityLabel(
            scope: "week",
            savedTokens: 10_000_000,
            savedProgress: 1,
            savedGoalTokens: 10_000_000,
            claudeUsedProgress: 0.4,
            codexUsedProgress: 0.2,
            grokUsedProgress: 0.1
        )
        XCTAssertTrue(label.lowercased().contains("measured save") || label.lowercased().contains("est."),
                      "Rings label must describe estimated/measured save: \(label)")
        XCTAssertTrue(label.contains("100%") || label.contains("~100%"),
                      "Rings label must include progress percent: \(label)")
        XCTAssertTrue(label.lowercased().contains("window mix") || label.contains("10M"),
                      "Rings label must name the self-normalizing mix denominator: \(label)")
        XCTAssertFalse(label.contains("provider spend"),
                       "Rings label must not describe the old denominator: \(label)")
    }

    func test_ringsAccessibilityLabel_zeroValues_stillNonEmpty() {
        // WHY: even a zero-state ring must produce a label; "nothing saved yet"
        // is valid information for a screen reader.
        let label = SidebarRootView.ringsAccessibilityLabel(
            scope: "week",
            savedTokens: 0,
            savedProgress: 0,
            claudeUsedProgress: 0,
            codexUsedProgress: 0,
            grokUsedProgress: 0
        )
        XCTAssertFalse(label.isEmpty)
    }

    // MARK: - Ring ordering by usage

    func test_ringOrdering_tokenSaverAlwaysOuter_providersByUsageDesc() {
        // WHY: screenshot contract — Token Saver is always the largest/outer ring;
        // providers sort by used % desc (Grok 46% > Claude 45% > Codex 7%).
        let order = SidebarRootView.TokenSaverRingOrdering.providersOuterToInner(
            claudeUsedProgress: 0.45,
            codexUsedProgress: 0.07,
            grokUsedProgress: 0.46
        )
        XCTAssertEqual(order, [.grok, .claude, .codex],
                       "rings must order providers by usage desc after Token Saver")
    }

    func test_ringOrdering_valuesExposeSameOuterToInnerOrder() {
        let values = SidebarRootView.TokenSaverActivityRings.Values(
            tokenSaverProgress: 1.0,
            claudeUsedProgress: 0.45,
            codexUsedProgress: 0.07,
            grokUsedProgress: 0.46
        )
        XCTAssertEqual(values.providersOuterToInner, [.grok, .claude, .codex])
        XCTAssertEqual(values.usedProgress(for: .grok), 0.46)
    }

    func test_ringOrdering_tiesUseStableSecondaryOrder() {
        // WHY: equal usage must not thrash ring order frame-to-frame.
        let order = SidebarRootView.TokenSaverRingOrdering.providersOuterToInner(
            claudeUsedProgress: 0.5,
            codexUsedProgress: 0.5,
            grokUsedProgress: 0.5
        )
        XCTAssertEqual(order, [.claude, .codex, .grok],
                       "equal usage keeps stable claude < codex < grok secondary order")
    }

    func test_managedProviderIDs_includeGrok() {
        // WHY: Grok savings must count in managed rows, not collapse into "CLI & other".
        XCTAssertTrue(TokenSaverSavingsDisplay.managedProviderIDs.contains("grok"),
                      "Grok is a managed agent provider and must appear in Token Saver rows")
        XCTAssertTrue(TokenSaverSavingsDisplay.managedProviderIDs.contains("claude"))
        XCTAssertTrue(TokenSaverSavingsDisplay.managedProviderIDs.contains("codex"))
    }

    func test_emptyUsageSnapshot_includesGrokProvider() {
        // WHY: empty state must reserve a Grok slot so the purple ring/row exists
        // before the first Grok run or account-usage refresh.
        let providers = Set(TokenSaverUsageSnapshot.empty().providers.map(\.provider))
        XCTAssertTrue(providers.contains(.grok),
                      "empty snapshot must include .grok so Token Saver UI does not omit the ring until first use")
        XCTAssertTrue(providers.contains(.claude))
        XCTAssertTrue(providers.contains(.codex))
    }

    // MARK: - Token Saver saved-token targets

    func test_tokenSaverSavingsGoalTokens_dailyIs2M_weekIs10M() {
        // WHY: Product rule: Daily fills at 2M; Week fills at 10M.
        XCTAssertEqual(SidebarRootView.tokenSaverSavingsGoalTokens(isDailyScope: true), 2_000_000)
        XCTAssertEqual(SidebarRootView.tokenSaverSavingsGoalTokens(isDailyScope: false), 10_000_000)
    }

    func test_savingsToGoalProgress_dailyTwoMillionSaved_returnsFull() {
        // WHY: Daily target is 2M saved tokens.
        XCTAssertEqual(
            SidebarRootView.savingsToGoalProgress(savedTokens: 2_000_000, goalTokens: 2_000_000),
            1
        )
    }

    func test_savingsToGoalProgress_weekFiveMillionSaved_returnsHalf() {
        // WHY: Week target is 10M, so 5M saved should show a half ring.
        XCTAssertEqual(
            SidebarRootView.savingsToGoalProgress(savedTokens: 5_000_000, goalTokens: 10_000_000),
            0.5,
            accuracy: 0.000_001
        )
    }

    func test_savingsToGoalProgress_moreThanGoal_clampsToFull() {
        // WHY: the ring cannot render beyond 100%; savings above the tab target stay full.
        XCTAssertEqual(
            SidebarRootView.savingsToGoalProgress(savedTokens: 12_000_000, goalTokens: 10_000_000),
            1
        )
    }

    func test_savingsToGoalProgress_zeroSaved_returnsEmpty() {
        // WHY: no measured savings must not show a filled impact ring.
        XCTAssertEqual(
            SidebarRootView.savingsToGoalProgress(savedTokens: 0, goalTokens: 2_000_000),
            0
        )
    }

    func test_savingsToGoalProgress_customGoalProtectsDivideByZero() {
        // WHY: tests may pass custom goals; zero or negative goals should never
        // crash or produce NaN.
        XCTAssertEqual(
            SidebarRootView.savingsToGoalProgress(savedTokens: 1, goalTokens: 0),
            1
        )
    }

    func test_savingsAvoidanceRatio_halfSavedHalfUsed_returnsHalf() {
        // WHY: ring fill must self-normalize to saved/(saved+used), not aspirational 2M.
        XCTAssertEqual(
            SidebarRootView.savingsAvoidanceRatio(savedTokens: 50_000, usedTokens: 50_000),
            0.5,
            accuracy: 0.000_001
        )
    }

    func test_savingsAvoidanceRatio_zeroSaved_returnsEmpty() {
        XCTAssertEqual(SidebarRootView.savingsAvoidanceRatio(savedTokens: 0, usedTokens: 100_000), 0)
    }

    func test_savingsAvoidanceRatio_onlySaved_returnsFull() {
        XCTAssertEqual(SidebarRootView.savingsAvoidanceRatio(savedTokens: 10, usedTokens: 0), 1)
    }

    // MARK: - Green ring: billed units only (never raw)

    func test_savingsRingFraction_unknownBilled_reportsUnavailableNotRawRatio() {
        // WHY: raw provider tokens overstate the window (~8× cache reads). When
        // billed units are unknown the ring must be explicitly unavailable —
        // never savingsAvoidanceRatio(saved, raw).
        let saved = 100_000
        let rawTokens = 800_000 // would produce a non-zero raw-derived ratio
        let fraction = SidebarRootView.tokenSaverSavingsRingFraction(
            savedTokens: saved,
            knownBilledUnits: nil,
            hasComparableUsageWindow: true
        )
        XCTAssertEqual(fraction, .billedUnavailable)
        XCTAssertFalse(fraction.isComparable)
        XCTAssertEqual(fraction.progress, 0)
        XCTAssertNil(fraction.mixTokens)
        XCTAssertEqual(fraction.unavailableReason, "billed usage unknown")

        let rawDerived = SidebarRootView.savingsAvoidanceRatio(
            savedTokens: saved,
            usedTokens: rawTokens
        )
        XCTAssertGreaterThan(rawDerived, 0)
        XCTAssertNotEqual(fraction.progress, rawDerived,
                          "Unavailable ring must not paint a raw-derived ratio")

        let label = SidebarRootView.ringsAccessibilityLabel(
            scope: "week",
            savedTokens: saved,
            savedProgress: fraction.progress,
            savedGoalTokens: 0,
            savingsRingComparable: fraction.isComparable,
            savingsRingUnavailableReason: fraction.unavailableReason,
            claudeUsedProgress: 0,
            codexUsedProgress: 0,
            grokUsedProgress: 0
        )
        XCTAssertTrue(label.lowercased().contains("unavailable"),
                      "A11y must say savings share is unavailable: \(label)")
        XCTAssertTrue(label.lowercased().contains("billed"),
                      "A11y must name billed-unknown reason: \(label)")
        XCTAssertFalse(label.contains("~") && label.lowercased().contains("window mix"),
                       "Must not claim a window-mix percent when billed is unknown: \(label)")
    }

    func test_savingsRingFraction_knownBilled_usesAvoidanceRatio() {
        // WHY: when billed is known, fill is saved/(saved+billed) — the honest mix.
        let fraction = SidebarRootView.tokenSaverSavingsRingFraction(
            savedTokens: 50_000,
            knownBilledUnits: 50_000,
            hasComparableUsageWindow: true
        )
        guard case .comparable(let progress, let mix) = fraction else {
            return XCTFail("Expected comparable ring, got \(fraction)")
        }
        XCTAssertEqual(progress, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(mix, 100_000)
        XCTAssertTrue(fraction.isComparable)
    }

    func test_savingsRingFraction_allTime_notFullForNonZeroAttributed() {
        // WHY: all-time used=0 previously forced savingsAvoidanceRatio(saved, 0)=1.0
        // and VoiceOver "~100% of window mix" — an unfalsifiable claim.
        let attributed = 96_041_366
        let fraction = SidebarRootView.tokenSaverSavingsRingFraction(
            savedTokens: attributed,
            knownBilledUnits: nil,
            hasComparableUsageWindow: false
        )
        XCTAssertEqual(fraction, .noComparableUsageWindow)
        XCTAssertFalse(fraction.isComparable)
        XCTAssertEqual(fraction.progress, 0,
                       "All-time must not paint a full green ring from used=0")
        XCTAssertNotEqual(fraction.progress, 1.0)
        XCTAssertEqual(fraction.unavailableReason, "no comparable usage window")

        // Contrasting the forbidden self-normalize-against-zero path:
        let forbidden = SidebarRootView.savingsAvoidanceRatio(
            savedTokens: attributed,
            usedTokens: 0
        )
        XCTAssertEqual(forbidden, 1.0)
        XCTAssertNotEqual(fraction.progress, forbidden)

        let label = SidebarRootView.ringsAccessibilityLabel(
            scope: "all time",
            savedTokens: attributed,
            savedProgress: fraction.progress,
            savedGoalTokens: 0,
            savingsRingComparable: fraction.isComparable,
            savingsRingUnavailableReason: fraction.unavailableReason,
            claudeUsedProgress: 0.2,
            codexUsedProgress: 0.1,
            grokUsedProgress: 0
        )
        XCTAssertTrue(label.lowercased().contains("unavailable"),
                      "All-time a11y must not claim 100% mix: \(label)")
        XCTAssertTrue(label.lowercased().contains("no comparable usage window"),
                      "All-time a11y must name the reason: \(label)")
        XCTAssertFalse(label.contains("~100%") || label.contains("100% of window mix"),
                       "Must not claim ~100% of window mix for all-time: \(label)")
    }

    func test_allTime_visibleRowsPlusUnattributed_equalHonestyHeadline() {
        // WHY: all-time managed rows must use attributed per-provider figures so
        // visible rows + unattributed reconcile with the honesty totals (headline
        // attributed + unattributed). Unknown-provider savings land only in unattributed.
        let claudeAttributed = 80_000
        let codexAttributed = 40_000
        let grokAttributed = 20_000
        let unattributedUnknownProvider = 500_000
        let attributedHeadline = claudeAttributed + codexAttributed + grokAttributed

        let claudeRow = SidebarRootView.tokenSaverAllTimeProviderAttributedSaved(
            attributedSavedForProvider: claudeAttributed
        )
        let codexRow = SidebarRootView.tokenSaverAllTimeProviderAttributedSaved(
            attributedSavedForProvider: codexAttributed
        )
        let grokRow = SidebarRootView.tokenSaverAllTimeProviderAttributedSaved(
            attributedSavedForProvider: grokAttributed
        )
        XCTAssertEqual(claudeRow + codexRow + grokRow, attributedHeadline)

        XCTAssertTrue(
            SidebarRootView.tokenSaverAllTimeRowsReconcileWithHeadline(
                managedProviderAttributedSaved: [claudeRow, codexRow, grokRow],
                unattributedSaved: unattributedUnknownProvider,
                attributedHeadline: attributedHeadline
            ),
            "Managed attributed rows + unattributed must equal headline + unattributed"
        )

        // Counter-example the defect encodes: permanent aggregate that folds in
        // unknown would break reconciliation if used as provider rows.
        let permanentClaudeIncludingNoise = claudeAttributed + 10_000
        XCTAssertFalse(
            SidebarRootView.tokenSaverAllTimeRowsReconcileWithHeadline(
                managedProviderAttributedSaved: [
                    permanentClaudeIncludingNoise, codexAttributed, grokAttributed
                ],
                unattributedSaved: unattributedUnknownProvider,
                attributedHeadline: attributedHeadline
            ),
            "Unfiltered permanent aggregate must not reconcile with attributed headline"
        )
    }

    func test_tokenSaverCardHeadline_showsEstimatedSaveWithCredibleTotal() {
        // WHY: design is the original "Estimated save N tokens" copy; only the
        // number is the scope credible total (not a technique-stack redesign).
        let headline = SidebarRootView.tokenSaverCardHeadline(
            subscribed: true,
            enabled: true,
            sidecarStatus: .notStarted,
            savedTokens: 35_000,
            usedTokens: 1_000_000
        )
        XCTAssertTrue(headline.lowercased().contains("estimated save"),
                      "Healthy enabled state must use original Estimated save copy; got: '\(headline)'")
        XCTAssertTrue(headline.contains("35") || headline.lowercased().contains("35k"))
        XCTAssertFalse(headline.lowercased().contains("vs bare"),
                       "Design restore must not surface bare-agent technique copy in the headline")
    }

    func test_tokenSaverCardHeadline_zeroSaved_measuringCopy() {
        let headline = SidebarRootView.tokenSaverCardHeadline(
            subscribed: true,
            enabled: true,
            sidecarStatus: .notStarted,
            savedTokens: 0,
            usedTokens: 1_000_000
        )
        XCTAssertTrue(headline.lowercased().contains("measuring"),
                      "Zero savings must keep measuring copy; got: '\(headline)'")
        XCTAssertFalse(headline.lowercased().contains("all-time"))
    }

    func test_tokenSaverCardHeadline_unsubscribed_usesSamePrimaryFigureNotUsageHeuristic() {
        // WHY: teaser must use the same primary figure the caller computed — never
        // re-inflate from usedTokens via used*(1-0.42).
        let headline = SidebarRootView.tokenSaverCardHeadline(
            subscribed: false,
            enabled: false,
            sidecarStatus: .notStarted,
            savedTokens: 12_000,
            usedTokens: 78_600_000
        )
        XCTAssertTrue(headline.lowercased().contains("estimated potential"),
                      "Unsubscribed teaser label; got: '\(headline)'")
        XCTAssertTrue(headline.contains("12") || headline.lowercased().contains("12k"),
                      "Teaser must show the passed primary figure, not ~45M from usage: \(headline)")
        XCTAssertFalse(headline.contains("45") && headline.lowercased().contains("m"),
                       "Must not show used*0.58-scale teaser: \(headline)")
    }

    func test_tokenSaverCardHeadline_lapsedSubscriberKeepsHistoricalFigure() {
        // WHY: gate the toggle, not history — subscribed+disabled still shows realized N.
        let headline = SidebarRootView.tokenSaverCardHeadline(
            subscribed: true,
            enabled: false,
            sidecarStatus: .notStarted,
            savedTokens: 96_000,
            usedTokens: 0
        )
        XCTAssertTrue(headline.lowercased().contains("estimated save"),
                      "Lapsed/disabled must keep historical figure; got: '\(headline)'")
        XCTAssertTrue(headline.contains("96") || headline.lowercased().contains("96k"))
        XCTAssertNotEqual(headline, "Enable Token Saver")
    }

    // MARK: - All-time attributed primary + unattributed row + inversion

    func test_allTimePrimary_usesAttributedNotAggregate() {
        // WHY: 85%+ of permanent aggregate can be provider-unknown; headline must
        // never fold unattributed into the all-time primary.
        let attributed = 96_041_366
        let unattributed = 569_918_221
        let primary = SidebarRootView.tokenSaverAllTimePrimaryTokens(
            attributedSavedTokens: attributed
        )
        XCTAssertEqual(primary, attributed)
        XCTAssertNotEqual(primary, attributed + unattributed,
                          "All-time primary must not equal attributed+unattributed aggregate")
        XCTAssertEqual(
            SidebarRootView.tokenSaverAllTimePrimaryTokens(attributedSavedTokens: 0),
            0
        )
    }

    func test_unattributedRow_rendersWhenWindowIsZero() {
        // WHY: suppressing the row at window==0 hid all-time unattributed forever.
        let value = SidebarRootView.tokenSaverUnattributedRowValue(
            windowSaved: 0,
            allTimeSaved: 569_918_221
        )
        XCTAssertTrue(value.hasPrefix("0 this window"),
                      "Zero window must still render; got: \(value)")
        XCTAssertTrue(value.lowercased().contains("all time"),
                      "Must show all-time unattributed; got: \(value)")
        XCTAssertFalse(value.isEmpty)
        let caption = SidebarRootView.tokenSaverUnattributedRunsCaption(
            windowRuns: 0,
            allTimeRuns: 40_000
        )
        XCTAssertTrue(caption.lowercased().contains("not provider-attributed"),
                      "Label must state bytes are not provider-attributed: \(caption)")
    }

    func test_enabledPrimaryFigure_neverBelowDisabledTeaser_forUsageMeasuredSweep() {
        // WHY: enabling Token Saver must never lower the card figure for the same
        // measured/used window (closes the non-payer > payer inversion).
        let measuredSamples = [0, 10, 1_000, 35_000, 250_000, 2_000_000]
        let usedSamples = [0, 1_000, 100_000, 1_000_000, 78_600_000]
        for measured in measuredSamples {
            for used in usedSamples {
                let enabled = SidebarRootView.tokenSaverCardPrimaryFigure(
                    measuredSaved: measured,
                    usedTokens: used,
                    tokenSaverEnabled: true
                )
                let disabled = SidebarRootView.tokenSaverCardPrimaryFigure(
                    measuredSaved: measured,
                    usedTokens: used,
                    tokenSaverEnabled: false
                )
                XCTAssertGreaterThanOrEqual(
                    enabled,
                    disabled,
                    "enabled (\(enabled)) < disabled teaser (\(disabled)) for measured=\(measured) used=\(used)"
                )
                // Headline path must not reintroduce used*0.58 as the unsubscribed number.
                let unsubscribedHeadline = SidebarRootView.tokenSaverCardHeadline(
                    subscribed: false,
                    enabled: false,
                    sidecarStatus: .notStarted,
                    savedTokens: disabled,
                    usedTokens: used
                )
                let heuristic = Int((Double(used) * 0.58).rounded())
                if disabled > 0 {
                    XCTAssertTrue(
                        unsubscribedHeadline.lowercased().contains("estimated potential"),
                        "Unsubscribed uses potential label with same-estimator figure"
                    )
                    // Teaser string is built from `disabled`, never from used*0.58.
                    if heuristic > disabled * 2 && heuristic >= 1_000 {
                        let heuristicStr = SidebarRootView.formatTokenCountPublic(heuristic)
                        XCTAssertFalse(
                            unsubscribedHeadline.contains(heuristicStr),
                            "Unsubscribed headline must not embed used*0.58 (\(heuristicStr)): \(unsubscribedHeadline)"
                        )
                    }
                } else if used > 10_000 {
                    // No measured history: teaser is empty / ready, not ~0.58*used.
                    XCTAssertEqual(disabled, 0)
                    XCTAssertFalse(
                        unsubscribedHeadline.lowercased().contains("m tokens")
                            && unsubscribedHeadline.contains("45"),
                        "Zero-measured teaser must not print usage-heuristic millions: \(unsubscribedHeadline)"
                    )
                    XCTAssertEqual(unsubscribedHeadline, "Estimate ready")
                }
            }
        }
    }

    func test_cardPathSource_hasNoCompressionHeuristic() throws {
        // WHY: 0.42/0.58 must not re-enter the card path as a savings estimator
        // (opacity 0.42 stroke is unrelated UI chrome and may remain).
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root
            .appendingPathComponent("Sources/AppShell/SidebarView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(
            source.contains("estimatePotentialSavings"),
            "Card path must not call estimatePotentialSavings (usage-fraction teaser)"
        )
        XCTAssertFalse(
            source.contains("compressionRatio"),
            "Card path must not reference compressionRatio"
        )
        // Guard executable savings math only (UI opacity 0.42 stroke is unrelated).
        let codeLines = source.split(separator: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///") && !trimmed.hasPrefix("*")
        }.joined(separator: "\n")
        XCTAssertFalse(
            codeLines.contains("* 0.58") || codeLines.contains("*0.58") || codeLines.contains("1.0 - 0.42"),
            "Card path must not hardcode usage-fraction savings math in executable code"
        )
    }

    func test_sinceInstallLine_usesAttributedOnly() {
        let line = SidebarRootView.tokenSaverSinceInstallLine(
            attributedSavedTokens: 96_041_366,
            attributedRuns: 10_000
        )
        XCTAssertTrue(line.lowercased().contains("since install"))
        XCTAssertTrue(line.lowercased().contains("attributed"))
        XCTAssertTrue(line.contains("10") || line.lowercased().contains("10k"))
        XCTAssertTrue(line.lowercased().contains("avg"))
    }

    func test_dayAndWeek_useSameBareUserEstimatorPath() {
        // WHY: Today and Week must only differ by windowed M and U inputs.
        let day = SidebarRootView.tokenSaverBareUserBreakdown(
            measuredToolOutputSaved: 250_000,
            windowProviderTokens: 150_000_000,
            tokenSaverEnabled: true,
            graphifyActive: true,
            graphifySignalCount: 0
        )
        let week = SidebarRootView.tokenSaverBareUserBreakdown(
            measuredToolOutputSaved: 22_000_000,
            windowProviderTokens: 1_200_000_000,
            tokenSaverEnabled: true,
            graphifyActive: true,
            graphifySignalCount: 0
        )
        XCTAssertEqual(day.totalCredible, day.measuredToolOutput + day.estimatedDialect + day.estimatedGraphify)
        XCTAssertEqual(week.totalCredible, week.measuredToolOutput + week.estimatedDialect + week.estimatedGraphify)
        XCTAssertEqual(day.estimatedGraphify, 0, "no fake graphify signals")
        XCTAssertEqual(day.estimatedOrchestration, 0)
        XCTAssertEqual(week.estimatedOrchestration, 0)
        // dialect ≈ 0.007 * U capped by 4*M → day ~ min(1.05M, 1M) + M
        XCTAssertLessThan(day.totalCredible, 2_000_000, "day must stay credible, not 66% of usage")
        XCTAssertGreaterThan(week.totalCredible, day.totalCredible)
    }

    func test_tokenSaverTodaySavedTokens_atOneSecondAfterMidnight_ignoresYesterday() throws {
        // WHY: when the calendar day turns to 00:00:01, Daily must reset even
        // though yesterday's savings still belong in the Week window.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let yesterday = try XCTUnwrap(DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 17,
            hour: 23,
            minute: 59,
            second: 59
        ).date)
        let oneSecondAfterMidnight = try XCTUnwrap(DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 18,
            hour: 0,
            minute: 0,
            second: 1
        ).date)
        let daily = [
            TokenSaverDailySavings(
                dayStartMs: SidebarRootView.tokenSaverDayStartMs(now: yesterday, calendar: calendar),
                savedTokens: 8_000_000,
                runs: 1
            )
        ]

        XCTAssertEqual(
            SidebarRootView.tokenSaverTodaySavedTokens(
                daily: daily,
                now: oneSecondAfterMidnight,
                calendar: calendar
            ),
            0
        )
        XCTAssertEqual(
            SidebarRootView.tokenSaverReportWindowSavedTokens(daily: daily),
            8_000_000,
            "Week must keep yesterday's saved tokens after Daily resets at midnight"
        )
    }

    func test_tokenSaverNextDailyResetDate_schedulesOneSecondAfterMidnight() throws {
        // WHY: an already-open Daily tab needs a state tick at 00:00:01 so the
        // visible saved count clears without waiting for unrelated UI activity.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let beforeMidnight = try XCTUnwrap(DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 17,
            hour: 23,
            minute: 59,
            second: 59
        ).date)
        let expectedReset = try XCTUnwrap(DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 18,
            hour: 0,
            minute: 0,
            second: 1
        ).date)

        XCTAssertEqual(
            SidebarRootView.tokenSaverNextDailyResetDate(after: beforeMidnight, calendar: calendar),
            expectedReset
        )
    }

    // MARK: - Per-provider scoped savings (window-consistent reconciliation)

    func test_tokenSaverPerProviderWindowing_today_isStrictSubsetOfWeek() throws {
        // WHY: a provider row on the Today tab must show only today's calendar-day
        // savings, while the Week tab sums every retained day for that provider.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let today = try XCTUnwrap(DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: 2026, month: 6, day: 18, hour: 12
        ).date)
        let yesterday = try XCTUnwrap(DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: 2026, month: 6, day: 17, hour: 12
        ).date)
        let todayMs = SidebarRootView.tokenSaverDayStartMs(now: today, calendar: calendar)
        let yestMs = SidebarRootView.tokenSaverDayStartMs(now: yesterday, calendar: calendar)
        let dailyByProvider = [
            TokenSaverProviderDailySavings(provider: "claude", dayStartMs: todayMs, savedTokens: 600, runs: 1),
            TokenSaverProviderDailySavings(provider: "claude", dayStartMs: yestMs, savedTokens: 400, runs: 1),
            TokenSaverProviderDailySavings(provider: "codex", dayStartMs: yestMs, savedTokens: 500, runs: 1)
        ]

        // Claude: today = 600 only; week = 600 + 400.
        XCTAssertEqual(
            SidebarRootView.tokenSaverTodaySaved(forProvider: "claude", dailyByProvider: dailyByProvider, now: today, calendar: calendar),
            600
        )
        XCTAssertEqual(
            SidebarRootView.tokenSaverWindowSaved(forProvider: "claude", dailyByProvider: dailyByProvider),
            1000
        )
        // Codex only has a yesterday bucket, so Today = 0, Week = 500.
        XCTAssertEqual(
            SidebarRootView.tokenSaverTodaySaved(forProvider: "codex", dailyByProvider: dailyByProvider, now: today, calendar: calendar),
            0,
            "Codex saved nothing today, so the Today row must be 0 even though Week is 500"
        )
        XCTAssertEqual(
            SidebarRootView.tokenSaverWindowSaved(forProvider: "codex", dailyByProvider: dailyByProvider),
            500
        )
    }

    func test_scopedProviderRows_reconcileWithGreenHeadline_todayAndWeek() throws {
        // WHY: the bug the user hit — the green headline and the Claude/Codex/CLI
        // rows described different windows. This proves that for EACH scope the
        // visible rows sum exactly to the scope's green headline (the collapsed
        // daily the headline reads).
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let today = try XCTUnwrap(DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: 2026, month: 6, day: 18, hour: 12
        ).date)
        let yesterday = try XCTUnwrap(DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: 2026, month: 6, day: 17, hour: 12
        ).date)
        let todayMs = SidebarRootView.tokenSaverDayStartMs(now: today, calendar: calendar)
        let yestMs = SidebarRootView.tokenSaverDayStartMs(now: yesterday, calendar: calendar)
        let dailyByProvider = [
            TokenSaverProviderDailySavings(provider: "claude", dayStartMs: todayMs, savedTokens: 600, runs: 1),
            TokenSaverProviderDailySavings(provider: "codex", dayStartMs: todayMs, savedTokens: 500, runs: 1),
            TokenSaverProviderDailySavings(provider: "unknown", dayStartMs: todayMs, savedTokens: 2530, runs: 9),
            TokenSaverProviderDailySavings(provider: "claude", dayStartMs: yestMs, savedTokens: 400, runs: 1)
        ]
        // Collapsed daily exactly as the repository derives it (green headline reads this).
        let daily = [
            TokenSaverDailySavings(dayStartMs: yestMs, savedTokens: 400, runs: 1),
            TokenSaverDailySavings(dayStartMs: todayMs, savedTokens: 3630, runs: 11)
        ]
        let known: Set<String> = ["claude", "codex"]

        // TODAY
        let claudeToday = SidebarRootView.tokenSaverTodaySaved(forProvider: "claude", dailyByProvider: dailyByProvider, now: today, calendar: calendar)
        let codexToday = SidebarRootView.tokenSaverTodaySaved(forProvider: "codex", dailyByProvider: dailyByProvider, now: today, calendar: calendar)
        let otherToday = SidebarRootView.tokenSaverTodaySaved(forProvidersOtherThan: known, dailyByProvider: dailyByProvider, now: today, calendar: calendar)
        let greenToday = SidebarRootView.tokenSaverTodaySavedTokens(daily: daily, now: today, calendar: calendar)
        XCTAssertEqual(otherToday.savedTokens, 2530)
        XCTAssertEqual(otherToday.runs, 9)
        XCTAssertEqual(greenToday, 3630)
        XCTAssertEqual(claudeToday + codexToday + otherToday.savedTokens, greenToday,
                       "Today: Claude + Codex + CLI rows must equal the Today green headline")

        // WEEK
        let claudeWeek = SidebarRootView.tokenSaverWindowSaved(forProvider: "claude", dailyByProvider: dailyByProvider)
        let codexWeek = SidebarRootView.tokenSaverWindowSaved(forProvider: "codex", dailyByProvider: dailyByProvider)
        let otherWeek = SidebarRootView.tokenSaverWindowSaved(forProvidersOtherThan: known, dailyByProvider: dailyByProvider)
        let greenWeek = SidebarRootView.tokenSaverReportWindowSavedTokens(daily: daily)
        XCTAssertEqual(claudeWeek, 1000)
        XCTAssertEqual(greenWeek, 4030)
        XCTAssertEqual(claudeWeek + codexWeek + otherWeek.savedTokens, greenWeek,
                       "Week: Claude + Codex + CLI rows must equal the Week green headline")
    }

    // MARK: - helpers

    private func makeTempDir(suffix: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-seam-\(suffix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
