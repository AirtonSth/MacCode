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
}
