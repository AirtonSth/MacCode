import XCTest
import AgentRuntime
import Persistence
@testable import AppShell

/// Verifies that SidebarViewModel.tokenSaverSnapshot produces the correct
/// computed values from sample JSON usage data + DB rows.
///
/// Business rule: moving the file read + SQL aggregate off the main actor
/// must not change the values that get assigned to tokenSaverEnabled,
/// tokenSaverUsageSnapshot, and tokenSaverSavingsSummary. This test encodes
/// that invariant by running the pure helper directly against known inputs.
final class TokenSaverSnapshotHelperTests: XCTestCase {

    // MARK: - Helpers

    private func makeDB() throws -> SQLiteDB {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return db
    }

    private func makeAppSupport() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2TSHelperTest-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - Tests

    func test_noContext_returnsEmptyUsageAndSavings() throws {
        let db = try makeDB()
        let store = SettingsStore(db: db)

        let result = SidebarViewModel.tokenSaverSnapshot(
            settingsStore: store,
            appSupportDirectory: nil,
            savingsRepo: nil
        )

        XCTAssertFalse(result.enabled,
            "tokenSaverEnabled must default to false when no appSupportDirectory is provided")
        XCTAssertEqual(result.usage, .empty(),
            "usage snapshot must be .empty() when appSupportDirectory is nil")
        XCTAssertEqual(result.savings, .empty,
            "savings summary must be .empty when appSupportDirectory is nil")
    }

    func test_enabledFlagReflectsStoredSettings() throws {
        let db = try makeDB()
        let store = SettingsStore(db: db)
        store.save(AppSettings(tokenSaverEnabled: true))
        let appSupport = makeAppSupport()

        let result = SidebarViewModel.tokenSaverSnapshot(
            settingsStore: store,
            appSupportDirectory: appSupport,
            savingsRepo: nil
        )

        XCTAssertTrue(result.enabled,
            "tokenSaverEnabled must reflect the value persisted in SettingsStore")
    }

    func test_usageSnapshotParsesWrittenJSON() throws {
        let db = try makeDB()
        let store = SettingsStore(db: db)
        let appSupport = makeAppSupport()

        let expected = TokenSaverUsageSnapshot(
            period: .sevenDays,
            providers: [
                TokenSaverProviderUsage(
                    provider: .claude,
                    actualProviderTokens: 120_000,
                    estimatedRawTokens: 300_000,
                    eligibleRuns: 5
                )
            ]
        )
        try TokenSaverUsageStore(appSupportDirectory: appSupport).save(expected)

        let result = SidebarViewModel.tokenSaverSnapshot(
            settingsStore: store,
            appSupportDirectory: appSupport,
            savingsRepo: nil
        )

        XCTAssertEqual(result.usage.usedTokens, 120_000,
            "usedTokens must equal actualProviderTokens written to usage.json")
        XCTAssertEqual(result.usage.measuredSavedTokens, 180_000,
            "measuredSavedTokens must equal estimatedRaw - actual from usage.json")
        XCTAssertEqual(result.usage.eligibleRuns, 5,
            "eligibleRuns must match the value written to usage.json")
    }

    func test_savingsSummaryAggregatesDBRows() throws {
        let db = try makeDB()
        let store = SettingsStore(db: db)
        let appSupport = makeAppSupport()
        let repo = TokenSaverSavingsRepository(db: db)
        let now = Date(timeIntervalSince1970: 1_000_000_000)

        try repo.record(provider: "claude", mode: "longText",
                        inputTokens: 1_000, outputTokens: 200, at: now)
        try repo.record(provider: "claude", mode: "longText",
                        inputTokens: 2_000, outputTokens: 400, at: now)

        let result = SidebarViewModel.tokenSaverSnapshot(
            settingsStore: store,
            appSupportDirectory: appSupport,
            savingsRepo: repo
        )

        let claudeSavings = result.savings.savings(for: "claude")
        XCTAssertNotNil(claudeSavings,
            "savings summary must contain a row for provider 'claude' after recording events")
        XCTAssertEqual(claudeSavings?.savedTokens, 2_400,
            "savedTokens must equal sum of (input - output) across both recorded events")
        XCTAssertEqual(claudeSavings?.runs, 2,
            "runs must equal the number of recorded savings events")
    }
}
