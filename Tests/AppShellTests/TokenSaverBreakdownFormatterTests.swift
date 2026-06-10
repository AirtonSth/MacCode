import XCTest
import Persistence
@testable import AppShell

/// Tests for `TokenSaverBreakdownFormatter`.
///
/// Why each test matters:
/// - `testRowsPerMode_aggregatesAcrossProviders`: the formatter MUST collapse
///   per-(provider,mode) entries from `summary.modes` into per-mode totals.
///   Without this, each provider would appear as a separate row, which is wrong.
/// - `testRowsSortedDescendingBySavedTokens`: the most impactful mode must
///   appear first so the user immediately sees where savings come from.
/// - `testAverageSavedPerRun_matchesSummaryComputed`: `averageSavedPerRun` on
///   the summary must equal totalSaved/totalRuns rounded, and the formatter must
///   not change that value -- it is derived from provider rows, not mode rows.
/// - `testZeroState_emptyModes_returnsEmpty`: when no runs have been recorded
///   the breakdown must be empty (zero-state is safe, not a crash or stub row).
/// - `testZeroSavedTokensRowIncluded`: a mode with zero savedTokens but
///   nonzero runs must still appear so the UI can render it as inactive.
final class TokenSaverBreakdownFormatterTests: XCTestCase {

    private let formatter = TokenSaverBreakdownFormatter()

    // MARK: - helpers

    private func summary(
        providerSaved: Int = 0,
        providerRuns: Int = 0,
        modes: [TokenSaverModeSavings] = []
    ) -> TokenSaverSavingsSummary {
        let providers: [TokenSaverProviderSavings] = providerRuns > 0 ? [
            TokenSaverProviderSavings(
                provider: "claude",
                savedTokens: providerSaved,
                inputTokens: providerSaved + 10,
                outputTokens: 10,
                runs: providerRuns
            )
        ] : []
        return TokenSaverSavingsSummary(providers: providers, daily: [], modes: modes)
    }

    // MARK: - tests

    /// Modes from two different providers with the same mode key must be merged
    /// into one row with summed savedTokens and runs.
    func testRowsPerMode_aggregatesAcrossProviders() {
        let modes = [
            TokenSaverModeSavings(provider: "claude", mode: "command-output", savedTokens: 1000, runs: 5),
            TokenSaverModeSavings(provider: "codex",  mode: "command-output", savedTokens: 500,  runs: 3),
            TokenSaverModeSavings(provider: "claude", mode: "prompt",         savedTokens: 200,  runs: 2),
        ]
        let s = summary(modes: modes)
        let rows = formatter.rows(from: s)

        XCTAssertEqual(rows.count, 2, "Two distinct modes -> two rows")

        let cmdRow = rows.first { $0.mode == "command-output" }
        XCTAssertNotNil(cmdRow)
        XCTAssertEqual(cmdRow?.savedTokens, 1500, "claude(1000) + codex(500) = 1500")
        XCTAssertEqual(cmdRow?.runs, 8,           "5 + 3 = 8")

        let promptRow = rows.first { $0.mode == "prompt" }
        XCTAssertNotNil(promptRow)
        XCTAssertEqual(promptRow?.savedTokens, 200)
        XCTAssertEqual(promptRow?.runs, 2)
    }

    /// Highest savedTokens must be first so the UI leads with the most impactful mode.
    func testRowsSortedDescendingBySavedTokens() {
        let modes = [
            TokenSaverModeSavings(provider: "claude", mode: "prompt",         savedTokens: 100,  runs: 1),
            TokenSaverModeSavings(provider: "claude", mode: "sr1",            savedTokens: 5000, runs: 10),
            TokenSaverModeSavings(provider: "claude", mode: "command-output", savedTokens: 900,  runs: 4),
        ]
        let rows = formatter.rows(from: summary(modes: modes))
        XCTAssertEqual(rows.map(\.mode), ["sr1", "command-output", "prompt"],
                       "Rows must be sorted by savedTokens descending")
    }

    /// `averageSavedPerRun` is computed on the summary from provider rows, not
    /// mode rows. The formatter does NOT alter it. 300 saved / 3 runs = 100.
    func testAverageSavedPerRun_matchesSummaryComputed() {
        let s = summary(providerSaved: 300, providerRuns: 3)
        XCTAssertEqual(s.averageSavedPerRun, 100,
                       "averageSavedPerRun must be totalSaved/totalRuns rounded")
    }

    /// Zero-state: `summary.modes` is empty -> `rows(from:)` must return [].
    /// The popover hides the breakdown section in this case; no stub/placeholder.
    func testZeroState_emptyModes_returnsEmpty() {
        let rows = formatter.rows(from: .empty)
        XCTAssertTrue(rows.isEmpty, "No mode rows -> breakdown is empty")
    }

    /// `averageSavedPerRun` is 0 when there are no runs.
    func testAverageSavedPerRun_zeroWhenNoRuns() {
        XCTAssertEqual(TokenSaverSavingsSummary.empty.averageSavedPerRun, 0)
    }

    /// A mode that was compressed but saved 0 tokens must still appear so the UI
    /// can show it as an inactive/zero row (e.g. prompt mode that yielded no gain).
    func testZeroSavedTokensRowIncluded() {
        let modes = [
            TokenSaverModeSavings(provider: "claude", mode: "prompt", savedTokens: 0, runs: 3),
        ]
        let rows = formatter.rows(from: summary(modes: modes))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].savedTokens, 0)
        XCTAssertEqual(rows[0].runs, 3)
    }

    /// Single mode, single provider: row values match the mode entry exactly.
    func testSingleModePassthrough() {
        let modes = [
            TokenSaverModeSavings(provider: "claude", mode: "sr1", savedTokens: 4200, runs: 7),
        ]
        let rows = formatter.rows(from: summary(modes: modes))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].mode, "sr1")
        XCTAssertEqual(rows[0].savedTokens, 4200)
        XCTAssertEqual(rows[0].runs, 7)
    }
}
