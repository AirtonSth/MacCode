import XCTest
@testable import AgentRuntime
import CoreModel

/// Token Saver empty snapshot must reserve a slot for every managed agent provider.
final class TokenSaverUsageSnapshotTests: XCTestCase {
    func test_emptySnapshotIncludesGrokProviderSlot() {
        // WHY: Grok has a purple usage ring in the Token Saver card. Without a
        // reserved provider row, the UI only appears after the first Grok run.
        let providers = Set(TokenSaverUsageSnapshot.empty().providers.map(\.provider))
        XCTAssertTrue(providers.contains(.grok),
                      "empty usage snapshot must include .grok for the purple Token Saver ring")
        XCTAssertTrue(providers.contains(.claude))
        XCTAssertTrue(providers.contains(.codex))
    }

    func test_ensuringManagedProviders_addsMissingGrokToLegacySnapshot() {
        // WHY: usage.json written before Grok support only has claude/codex;
        // load must backfill Grok so the UI never treats it as absent.
        let legacy = TokenSaverUsageSnapshot(period: .sevenDays, providers: [
            TokenSaverProviderUsage(provider: .claude, actualProviderTokens: 10, weeklyUsedPercent: 50),
            TokenSaverProviderUsage(provider: .codex, actualProviderTokens: 20, weeklyUsedPercent: 30)
        ])
        let fixed = TokenSaverUsageStore.ensuringManagedProviders(legacy)
        let byProvider = Dictionary(uniqueKeysWithValues: fixed.providers.map { ($0.provider, $0) })
        XCTAssertNotNil(byProvider[.grok], "legacy snapshots must gain a Grok row")
        XCTAssertEqual(byProvider[.claude]?.actualProviderTokens, 10,
                       "backfill must not wipe existing Claude totals")
        XCTAssertEqual(byProvider[.codex]?.weeklyUsedPercent, 30)
    }

    /// WHY: inactive Claude left the Token Saver card locked at 45% because the
    /// last successful probe was never expired or cleared.
    func test_effectiveWeeklyUsedPercent_expiresWhenResetIsPast() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertEqual(
            TokenSaverProviderUsage.effectiveWeeklyUsedPercent(
                weeklyUsedPercent: 45,
                weeklyResetsAt: Date(timeIntervalSince1970: 1_999_000),
                now: now
            ),
            0,
            "a past weekly reset must read as 0% so the ring cannot stay locked mid-window"
        )
        XCTAssertEqual(
            TokenSaverProviderUsage.effectiveWeeklyUsedPercent(
                weeklyUsedPercent: 45,
                weeklyResetsAt: Date(timeIntervalSince1970: 2_100_000),
                now: now
            ),
            45,
            "an unexpired window must keep the live probe percent"
        )
    }

    func test_providersMissingFromAccountUsageRefresh_listsInactiveProviders() {
        let missing = TokenSaverUsageStore.providersMissingFromAccountUsageRefresh(
            returned: [.codex, .grok]
        )
        XCTAssertEqual(missing, [.claude],
                       "Claude omitted from a partial refresh must be cleared as inactive")
        XCTAssertTrue(
            TokenSaverUsageStore.providersMissingFromAccountUsageRefresh(returned: []).isEmpty == false,
            "empty returned set marks all managed providers missing (caller must not clear on full timeout)"
        )
    }

    /// WHY: Grok frequently showed 0% after a Codex-only partial refresh even
    /// though its weekly credit window was still open (billing log scan missed
    /// the newest `creditUsagePercent` line). Unexpired windows must survive.
    func test_providersToClearAfterPartialRefresh_keepsUnexpiredGrokWindow() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let existing = [
            TokenSaverProviderUsage(
                provider: .grok,
                weeklyUsedPercent: 65,
                weeklyResetsAt: Date(timeIntervalSince1970: 2_500_000)
            ),
            TokenSaverProviderUsage(
                provider: .claude,
                weeklyUsedPercent: 45,
                weeklyResetsAt: nil
            )
        ]
        let toClear = TokenSaverUsageStore.providersToClearAfterPartialAccountUsageRefresh(
            returned: [.codex],
            existing: existing,
            now: now
        )
        XCTAssertFalse(toClear.contains(.grok),
                       "Grok with an unexpired weeklyResetsAt must not be zeroed by a flaky probe miss")
        XCTAssertTrue(toClear.contains(.claude),
                      "Claude without an unexpired window still clears so frozen 45% cannot stick forever")
    }

    func test_providersToClearAfterPartialRefresh_clearsExpiredGrokWindow() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let existing = [
            TokenSaverProviderUsage(
                provider: .grok,
                weeklyUsedPercent: 65,
                weeklyResetsAt: Date(timeIntervalSince1970: 1_500_000)
            )
        ]
        let toClear = TokenSaverUsageStore.providersToClearAfterPartialAccountUsageRefresh(
            returned: [.codex],
            existing: existing,
            now: now
        )
        XCTAssertTrue(toClear.contains(.grok),
                      "expired Grok windows may clear; effective % already reads 0")
    }

    func test_clearAccountUsagePercentages_zerosWeeklyButKeepsSavings() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ts-clear-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = TokenSaverUsageStore(appSupportDirectory: dir)
        _ = try store.record(
            provider: .claude,
            actualProviderTokens: 1_000,
            estimatedRawTokens: 2_000,
            eligibleRuns: 3
        )
        _ = try store.recordAccountUsage(
            provider: .claude,
            weeklyUsedPercent: 45,
            weeklyWindowDurationMinutes: 10_080
        )
        _ = try store.clearAccountUsagePercentages(provider: .claude)
        let claude = store.load().providers.first { $0.provider == .claude }
        XCTAssertEqual(claude?.weeklyUsedPercent, 0,
                       "inactive Claude must drop to 0% used, not keep the frozen 45%")
        XCTAssertEqual(claude?.actualProviderTokens, 1_000,
                       "clearing rate-limit % must not wipe measured Token Saver savings counters")
    }

    func test_expiringStaleWeeklyUsage_zerosPastWindows() {
        let now = Date(timeIntervalSince1970: 5_000)
        let snap = TokenSaverUsageSnapshot(period: .sevenDays, providers: [
            TokenSaverProviderUsage(
                provider: .claude,
                weeklyUsedPercent: 45,
                weeklyResetsAt: Date(timeIntervalSince1970: 4_000)
            ),
            TokenSaverProviderUsage(
                provider: .codex,
                weeklyUsedPercent: 23,
                weeklyResetsAt: Date(timeIntervalSince1970: 6_000)
            )
        ])
        let fixed = TokenSaverUsageStore.expiringStaleWeeklyUsage(snap, now: now)
        let by = Dictionary(uniqueKeysWithValues: fixed.providers.map { ($0.provider, $0) })
        XCTAssertEqual(by[.claude]?.weeklyUsedPercent, 0)
        XCTAssertEqual(by[.codex]?.weeklyUsedPercent, 23)
    }

    /// WHY: bare session 0% from a probe miss painted every Today ring as empty
    /// even when weekly usage was 80%+. Only a live unexpired session window may
    /// keep a true 0%; otherwise session % is missing so the UI can fall back.
    func test_effectiveSessionUsedPercent_ignoresBareZeroWithoutLiveWindow() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertNil(
            TokenSaverProviderUsage.effectiveSessionUsedPercent(
                currentSessionUsedPercent: 0,
                currentSessionResetsAt: nil,
                now: now
            ),
            "bare 0 without a session reset window must not paint Today as 0% used"
        )
        XCTAssertNil(
            TokenSaverProviderUsage.effectiveSessionUsedPercent(
                currentSessionUsedPercent: 0,
                currentSessionResetsAt: Date(timeIntervalSince1970: 1_500_000),
                now: now
            ),
            "expired session window must not keep a frozen 0%"
        )
        XCTAssertEqual(
            TokenSaverProviderUsage.effectiveSessionUsedPercent(
                currentSessionUsedPercent: 0,
                currentSessionResetsAt: Date(timeIntervalSince1970: 2_500_000),
                now: now
            ),
            0,
            "true mid-window 0% with a future reset must still display as 0%"
        )
        XCTAssertEqual(
            TokenSaverProviderUsage.effectiveSessionUsedPercent(
                currentSessionUsedPercent: 37,
                currentSessionResetsAt: nil,
                now: now
            ),
            37,
            "positive session % without reset metadata remains usable"
        )
    }
}
