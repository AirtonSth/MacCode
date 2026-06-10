import XCTest
@testable import Surfaces

// Pure-logic tests for BrowserKeyMapper and FindResultFormatter.
// Neither type touches @MainActor symbols, so no isolation annotation is needed.
// WHY: key equivalents and find-result formatting are pure mapping logic —
// testing them in isolation guarantees the user gets the expected muscle-memory
// shortcuts (Cmd+R/[/]) and a readable "n of m" find indicator regardless of
// WebKit/AppKit wiring details that cannot run in the test process.

final class BrowserKeyEquivAndFindTests: XCTestCase {

    // MARK: - BrowserKeyMapper

    func test_keyMapper_cmdR_mapsToReload() {
        let cmd = BrowserKeyMapper.command(for: "r", modifiers: .command)
        XCTAssertEqual(cmd, .reload,
            "Cmd+R must map to .reload so users can reload with keyboard muscle memory")
    }

    func test_keyMapper_cmdLeftBracket_mapsToBack() {
        let cmd = BrowserKeyMapper.command(for: "[", modifiers: .command)
        XCTAssertEqual(cmd, .back,
            "Cmd+[ must map to .back — standard macOS browser convention (Safari/Chrome)")
    }

    func test_keyMapper_cmdRightBracket_mapsToForward() {
        let cmd = BrowserKeyMapper.command(for: "]", modifiers: .command)
        XCTAssertEqual(cmd, .forward,
            "Cmd+] must map to .forward — standard macOS browser convention (Safari/Chrome)")
    }

    func test_keyMapper_otherKeys_returnNil() {
        XCTAssertNil(BrowserKeyMapper.command(for: "x", modifiers: .command),
            "unbound keys must not accidentally trigger browser commands")
        XCTAssertNil(BrowserKeyMapper.command(for: "r", modifiers: []),
            "bare R without Cmd must not reload — would interfere with text input")
        XCTAssertNil(BrowserKeyMapper.command(for: "r", modifiers: [.command, .shift]),
            "Cmd+Shift+R is not a bound browser command and must return nil")
    }

    // MARK: - FindResultFormatter

    func test_findFormatter_nonZeroMatch_rendersNOfM() {
        let label = FindResultFormatter.label(current: 3, total: 12, wrapped: false)
        XCTAssertEqual(label, "3 of 12",
            "find bar must show current-match position so user knows where they are in results")
    }

    func test_findFormatter_wrappedMatch_appendsWrapIndicator() {
        let label = FindResultFormatter.label(current: 1, total: 5, wrapped: true)
        XCTAssertEqual(label, "1 of 5 \u{21A9}",
            "wrapped search must signal wrap so user knows the result looped from the top/bottom")
    }

    func test_findFormatter_zeroMatches_rendersNoResults() {
        let label = FindResultFormatter.label(current: 0, total: 0, wrapped: false)
        XCTAssertEqual(label, "No results",
            "zero matches must show 'No results' so the user understands no text was found")
    }

    func test_findFormatter_firstOfOne_rendersOneOfOne() {
        let label = FindResultFormatter.label(current: 1, total: 1, wrapped: false)
        XCTAssertEqual(label, "1 of 1",
            "single match must still show count so user knows exactly one result exists")
    }
}
