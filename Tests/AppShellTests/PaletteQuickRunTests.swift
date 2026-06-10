import XCTest
@testable import AppShell

/// Verifies the Cmd+1..9 quick-run pure helper added in P2.
///
/// WHY: the helper is the business-critical mapping between a key press and
/// the command that should execute.  Tests must break if:
///   - digit 1 no longer maps to the first runnable row,
///   - digit 9 no longer maps to the ninth runnable row,
///   - an out-of-range digit silently returns a wrong row,
///   - non-runnable rows (headers, overflow) are counted as targets.
///
/// Rule 8: each test encodes WHY the invariant matters, not just WHAT it does.
final class PaletteQuickRunTests: XCTestCase {

    // MARK: - Helpers

    private func makeCmd(id: String) -> PaletteCommand {
        PaletteCommand(id: id, title: id, action: {})
    }

    private func nineCommands() -> [PaletteCommand] {
        (1...9).map { makeCmd(id: "cmd\($0)") }
    }

    // MARK: - Digit 1 maps to first runnable row

    func test_digit1_mapsToFirstRunnableRow() {
        // WHY: Cmd+1 must run exactly the first visible command, not the second.
        let rows = nineCommands()
        let result = CommandPalette.commandForQuickRun(digit: 1, visibleRows: rows, nonRunnableIDs: [])
        XCTAssertEqual(result?.id, "cmd1", "digit 1 must target row index 0")
    }

    // MARK: - Digit 9 maps to ninth runnable row

    func test_digit9_mapsToNinthRunnableRow() {
        // WHY: Cmd+9 must reach the last shortcut target; off-by-one would skip it.
        let rows = nineCommands()
        let result = CommandPalette.commandForQuickRun(digit: 9, visibleRows: rows, nonRunnableIDs: [])
        XCTAssertEqual(result?.id, "cmd9", "digit 9 must target row index 8")
    }

    // MARK: - Digit exceeding row count returns nil

    func test_digitBeyondRowCount_returnsNil() {
        // WHY: pressing Cmd+5 with only 3 rows must no-op, never crash or run a
        // wrong command.
        let rows = [makeCmd(id: "a"), makeCmd(id: "b"), makeCmd(id: "c")]
        let result = CommandPalette.commandForQuickRun(digit: 5, visibleRows: rows, nonRunnableIDs: [])
        XCTAssertNil(result, "digit beyond row count must return nil")
    }

    // MARK: - Empty row list returns nil for any digit

    func test_emptyRows_returnsNil() {
        // WHY: palette may be empty (loading state); no crash, no ghost run.
        let result = CommandPalette.commandForQuickRun(digit: 1, visibleRows: [], nonRunnableIDs: [])
        XCTAssertNil(result, "empty row list must return nil for digit 1")
    }

    // MARK: - Out-of-range digits (0, 10) return nil

    func test_digitZero_returnsNil() {
        // WHY: digit 0 has no Cmd+0 binding; must be a no-op.
        let rows = nineCommands()
        let result = CommandPalette.commandForQuickRun(digit: 0, visibleRows: rows, nonRunnableIDs: [])
        XCTAssertNil(result, "digit 0 is out of range and must return nil")
    }

    func test_digitTen_returnsNil() {
        // WHY: only 1..9 are supported; digit 10 is never a valid key chord.
        let rows = nineCommands()
        let result = CommandPalette.commandForQuickRun(digit: 10, visibleRows: rows, nonRunnableIDs: [])
        XCTAssertNil(result, "digit 10 is out of range and must return nil")
    }

    // MARK: - Non-runnable rows are skipped in the 1-based count

    func test_nonRunnableHeader_skippedInCount() {
        // WHY: section headers are injected between commands; they must not
        // consume a digit slot.  If they did, Cmd+1 would fire the header and
        // no-op instead of running the first real command.
        let header = makeCmd(id: "palette.section.workspace")
        let cmd1   = makeCmd(id: "cmd1")
        let cmd2   = makeCmd(id: "cmd2")
        let rows = [header, cmd1, cmd2]
        let nonRunnable: Set<String> = ["palette.section.workspace"]

        let r1 = CommandPalette.commandForQuickRun(digit: 1, visibleRows: rows, nonRunnableIDs: nonRunnable)
        let r2 = CommandPalette.commandForQuickRun(digit: 2, visibleRows: rows, nonRunnableIDs: nonRunnable)
        XCTAssertEqual(r1?.id, "cmd1", "header must not count as digit-1 slot")
        XCTAssertEqual(r2?.id, "cmd2", "header must not count as digit-2 slot")
    }

    func test_nonRunnableOverflowRow_skippedInCount() {
        // WHY: \"Show all N more scripts\" overflow rows must not be quick-runnable;
        // they are non-runnable by design and must be invisible to digit mapping.
        let overflow = makeCmd(id: "project.run.more")
        let cmd1     = makeCmd(id: "cmd1")
        let rows = [overflow, cmd1]
        let nonRunnable: Set<String> = ["project.run.more"]

        let result = CommandPalette.commandForQuickRun(digit: 1, visibleRows: rows, nonRunnableIDs: nonRunnable)
        XCTAssertEqual(result?.id, "cmd1", "overflow row must not occupy digit-1 slot")
    }

    func test_allNonRunnable_returnsNilForDigit1() {
        // WHY: if every visible row is a header/overflow (edge case), no digit
        // should fire anything.
        let rows = [makeCmd(id: "palette.section.workspace"),
                    makeCmd(id: "palette.section.app")]
        let nonRunnable: Set<String> = ["palette.section.workspace", "palette.section.app"]
        let result = CommandPalette.commandForQuickRun(digit: 1, visibleRows: rows, nonRunnableIDs: nonRunnable)
        XCTAssertNil(result, "all-non-runnable list must return nil for any digit")
    }

    // MARK: - Ordering contract: nth runnable, not nth total row

    func test_mixedRunnable_correctNthMapping() {
        // WHY: with headers interspersed, digit N must still address the Nth
        // runnable command in visual order, not the Nth total row.
        //
        // Layout: [header-A, cmd1, cmd2, header-B, cmd3]
        // Cmd+3 must run cmd3, not header-B or row index 4.
        let hA   = makeCmd(id: "palette.section.a")
        let cmd1 = makeCmd(id: "cmd1")
        let cmd2 = makeCmd(id: "cmd2")
        let hB   = makeCmd(id: "palette.section.b")
        let cmd3 = makeCmd(id: "cmd3")
        let rows = [hA, cmd1, cmd2, hB, cmd3]
        let nonRunnable: Set<String> = ["palette.section.a", "palette.section.b"]

        XCTAssertEqual(
            CommandPalette.commandForQuickRun(digit: 3, visibleRows: rows, nonRunnableIDs: nonRunnable)?.id,
            "cmd3",
            "digit 3 must address the 3rd runnable row ignoring headers"
        )
    }
}
