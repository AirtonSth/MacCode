import XCTest
@testable import AppShell

/// Verifies that applyFilter does not accumulate stale non-runnable IDs across
/// multiple filter passes (PERF-L93).
///
/// Business rule: a row is non-runnable iff it is a header or no-results row in
/// the CURRENT filter pass. IDs from a previous pass must not survive into the
/// next pass, otherwise nonRunnableRowIDs grows without bound across keystrokes.
///
/// The seam under test is `CommandPalette.isFilterPassNonRunnableID(_:)` - a pure
/// static function that encodes which IDs applyFilter owns and must clear between
/// passes.  Static IDs added by rebuildCommands (e.g. "agent.model.loading") are
/// NOT owned by applyFilter and must not be cleared.
@MainActor
final class CommandPaletteNonRunnableIDTests: XCTestCase {

    // MARK: - Owned IDs (applyFilter must clear these between passes)

    func test_sectionHeaderIDs_areFilterPassOwned() {
        // WHY: palette.section.* rows are re-created on every filter pass; if
        // stale ones survive the set grows by (categories * passes) entries.
        XCTAssertTrue(CommandPalette.isFilterPassNonRunnableID("palette.section.recent"))
        XCTAssertTrue(CommandPalette.isFilterPassNonRunnableID("palette.section.workspace"))
        XCTAssertTrue(CommandPalette.isFilterPassNonRunnableID("palette.section.agent"))
        XCTAssertTrue(CommandPalette.isFilterPassNonRunnableID("palette.section.project"))
        XCTAssertTrue(CommandPalette.isFilterPassNonRunnableID("palette.section.surfaces"))
    }

    func test_noResultsID_isFilterPassOwned() {
        // WHY: palette.noresults is inserted when a search yields nothing; it
        // must be cleared on the next pass so it cannot ghost-skip a valid row.
        XCTAssertTrue(CommandPalette.isFilterPassNonRunnableID("palette.noresults"))
    }

    // MARK: - Static IDs (rebuildCommands owns; applyFilter must NOT clear)

    func test_staticAgentLoadingID_isNotFilterPassOwned() {
        // WHY: agent.model.loading is inserted once by rebuildCommands and must
        // survive filter passes so the loading row stays non-selectable while
        // the model catalog is still fetching.
        XCTAssertFalse(CommandPalette.isFilterPassNonRunnableID("agent.model.loading"))
    }

    func test_arbitraryRunnableID_isNotFilterPassOwned() {
        // WHY: ordinary command IDs (workspace.new, surface.new.terminal, etc.)
        // must never be treated as filter-pass-owned or they would be
        // incorrectly cleared from nonRunnableRowIDs.
        XCTAssertFalse(CommandPalette.isFilterPassNonRunnableID("workspace.new"))
        XCTAssertFalse(CommandPalette.isFilterPassNonRunnableID("surface.new.terminal"))
        XCTAssertFalse(CommandPalette.isFilterPassNonRunnableID("agent.provider.claude"))
    }

    // MARK: - Stale-ID accumulation contract

    func test_filterPassClear_removesStaleHeaderIDsFromSecondPass() {
        // WHY: this is the exact bug from PERF-L93. Simulate two filter passes.
        // After pass-2, the set must contain only pass-2 IDs (pass-1 section
        // headers are gone). If isFilterPassNonRunnableID incorrectly returns
        // false for a header, the filter predicate would keep stale IDs in the
        // set.
        var ids: Set<String> = []

        // Pass 1 inserts section headers and a no-results row.
        let pass1IDs: Set<String> = [
            "palette.section.recent",
            "palette.section.workspace",
            "palette.noresults"
        ]
        ids.formUnion(pass1IDs)

        // Start of pass 2: clear filter-pass-owned IDs (what applyFilter now does).
        ids = ids.filter { !CommandPalette.isFilterPassNonRunnableID($0) }

        // Pass 2 inserts a different set (only one category visible this time).
        let pass2IDs: Set<String> = ["palette.section.agent"]
        ids.formUnion(pass2IDs)

        // Pass-1 IDs must be gone; pass-2 IDs must remain.
        for stale in pass1IDs {
            XCTAssertFalse(ids.contains(stale),
                           "stale id '\(stale)' from pass-1 must not survive into pass-2")
        }
        for current in pass2IDs {
            XCTAssertTrue(ids.contains(current),
                          "current id '\(current)' from pass-2 must still be present")
        }
    }

    func test_filterPassClear_preservesStaticIDs() {
        // WHY: rebuildCommands inserts agent.model.loading before any filter
        // pass. applyFilter must not remove it when clearing filter-pass-owned IDs.
        var ids: Set<String> = ["agent.model.loading"]

        // Simulate start of a filter pass.
        ids = ids.filter { !CommandPalette.isFilterPassNonRunnableID($0) }

        XCTAssertTrue(ids.contains("agent.model.loading"),
                      "static 'agent.model.loading' must survive the filter-pass clear")
    }
}
