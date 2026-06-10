import XCTest
@testable import AppShell

// SidebarKeyIntentMapper and SidebarKeyInput are pure structs — no MainActor needed.
final class SidebarKeyIntentMapperTests: XCTestCase {

    private let mapper = SidebarKeyIntentMapper()

    // MARK: - Up / Down arrows

    func test_upArrow_returnsMoveUp() {
        // ↑ alone must move selection up without any modifier held.
        let input = SidebarKeyInput(character: Character(UnicodeScalar(0xF700)!)) // NSUpArrowFunctionKey
        XCTAssertEqual(mapper.action(for: input), .moveUp,
                       "↑ with no modifiers must move the sidebar selection up")
    }

    func test_downArrow_returnsMoveDown() {
        // ↓ alone must move selection down.
        let input = SidebarKeyInput(character: Character(UnicodeScalar(0xF701)!)) // NSDownArrowFunctionKey
        XCTAssertEqual(mapper.action(for: input), .moveDown,
                       "↓ with no modifiers must move the sidebar selection down")
    }

    func test_upArrow_withCommand_returnsNil() {
        // Cmd+↑ is a system shortcut (scroll to top); must not steal it.
        let input = SidebarKeyInput(character: Character(UnicodeScalar(0xF700)!), commandDown: true)
        XCTAssertNil(mapper.action(for: input),
                     "Cmd+↑ must not be captured by the sidebar — it belongs to the system")
    }

    func test_downArrow_withCommand_returnsNil() {
        let input = SidebarKeyInput(character: Character(UnicodeScalar(0xF701)!), commandDown: true)
        XCTAssertNil(mapper.action(for: input),
                     "Cmd+↓ must not be captured by the sidebar")
    }

    // MARK: - Return → open

    func test_return_returnsOpenSelected() {
        // ↩ must open the currently-selected workspace.
        let input = SidebarKeyInput(character: "\r")
        XCTAssertEqual(mapper.action(for: input), .openSelected,
                       "Return must open the selected workspace, matching standard macOS list behaviour")
    }

    func test_return_withCommand_returnsNil() {
        let input = SidebarKeyInput(character: "\r", commandDown: true)
        XCTAssertNil(mapper.action(for: input),
                     "Cmd+Return is not bound in the sidebar")
    }

    // MARK: - Cmd+Delete / Cmd+Backspace → remove

    func test_cmdDeleteFunctionKey_returnsRemoveSelected() {
        // Cmd+Delete (forward-delete key, 0xF728) must trigger workspace removal.
        let input = SidebarKeyInput(character: Character(UnicodeScalar(0xF728)!), commandDown: true)
        XCTAssertEqual(mapper.action(for: input), .removeSelected,
                       "Cmd+Delete must remove the selected workspace, matching standard macOS list behaviour")
    }

    func test_cmdBackspace_returnsRemoveSelected() {
        // Cmd+⌫ (DEL character, 0x7F) — the backspace key with Cmd — is an equally valid
        // remove shortcut on compact keyboards that lack a Forward-Delete key.
        let input = SidebarKeyInput(character: "\u{7F}", commandDown: true)
        XCTAssertEqual(mapper.action(for: input), .removeSelected,
                       "Cmd+Backspace must also remove the selected workspace for keyboards without a Forward-Delete key")
    }

    func test_deleteAlone_returnsNil() {
        // Delete without Cmd must NOT remove the workspace (accidental deletion guard).
        let input = SidebarKeyInput(character: Character(UnicodeScalar(0xF728)!), commandDown: false)
        XCTAssertNil(mapper.action(for: input),
                     "Delete without Cmd must not remove the workspace — require explicit Cmd modifier")
    }

    func test_backspaceAlone_returnsNil() {
        let input = SidebarKeyInput(character: "\u{7F}", commandDown: false)
        XCTAssertNil(mapper.action(for: input),
                     "Backspace without Cmd must not remove the workspace")
    }

    // MARK: - Cmd+F → focus filter

    func test_cmdF_returnsFocusFilter() {
        // Cmd+F must focus the workspace filter field, matching the macOS Find convention.
        let input = SidebarKeyInput(character: "f", commandDown: true)
        XCTAssertEqual(mapper.action(for: input), .focusFilter,
                       "Cmd+F must transfer keyboard focus to the filter field")
    }

    func test_fAlone_returnsNil() {
        // Typing 'f' without Cmd must not steal the keystroke (user might be naming a workspace).
        let input = SidebarKeyInput(character: "f")
        XCTAssertNil(mapper.action(for: input),
                     "Bare 'f' must not trigger the filter — only Cmd+F is bound")
    }

    // MARK: - Escape → clear filter

    func test_escape_returnsClearFilter() {
        // Esc must clear an active filter, restoring the full workspace list.
        let input = SidebarKeyInput(character: "\u{1B}")
        XCTAssertEqual(mapper.action(for: input), .clearFilter,
                       "Escape must clear the filter text so the full workspace list is restored")
    }

    func test_escape_withCommand_returnsNil() {
        let input = SidebarKeyInput(character: "\u{1B}", commandDown: true)
        XCTAssertNil(mapper.action(for: input),
                     "Cmd+Escape is not a sidebar binding")
    }

    // MARK: - Unmapped keys return nil

    func test_unmappedKeys_returnNil() {
        // Unbound keys (e.g. letter 'a', number '1') must be ignored so they
        // propagate to other responders.
        let unmapped: [SidebarKeyInput] = [
            SidebarKeyInput(character: "a"),
            SidebarKeyInput(character: "1"),
            SidebarKeyInput(character: " "),
            SidebarKeyInput(character: "\t"),
            SidebarKeyInput(character: "f", optionDown: true),
            SidebarKeyInput(character: "\r", shiftDown: true),
        ]
        for input in unmapped {
            XCTAssertNil(mapper.action(for: input),
                         "Character '\(input.character)' (cmd:\(input.commandDown) opt:\(input.optionDown) shift:\(input.shiftDown)) must not be captured")
        }
    }
}
