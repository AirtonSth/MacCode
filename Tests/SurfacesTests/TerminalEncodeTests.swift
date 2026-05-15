import XCTest
import AppKit
@testable import Surfaces

@MainActor
final class TerminalEncodeTests: XCTestCase {
    private func key(_ keyCode: UInt16, chars: String = "", ignoring: String = "",
                     flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: chars, charactersIgnoringModifiers: ignoring,
            isARepeat: false, keyCode: keyCode)!
    }

    func test_specialKeys_mapToVT100() {
        XCTAssertEqual(TerminalTextView.encode(key(36)), Data([0x0D]))                 // Return
        XCTAssertEqual(TerminalTextView.encode(key(48)), Data([0x09]))                 // Tab
        XCTAssertEqual(TerminalTextView.encode(key(51)), Data([0x7F]))                 // Backspace
        XCTAssertEqual(TerminalTextView.encode(key(53)), Data([0x1B]))                 // Esc
        XCTAssertEqual(TerminalTextView.encode(key(126)), Data([0x1B, 0x5B, 0x41]))    // Up
        XCTAssertEqual(TerminalTextView.encode(key(125)), Data([0x1B, 0x5B, 0x42]))    // Down
        XCTAssertEqual(TerminalTextView.encode(key(124)), Data([0x1B, 0x5B, 0x43]))    // Right
        XCTAssertEqual(TerminalTextView.encode(key(123)), Data([0x1B, 0x5B, 0x44]))    // Left
    }

    func test_printableChar_isUTF8() {
        let e = key(0, chars: "a", ignoring: "a")
        XCTAssertEqual(TerminalTextView.encode(e), Data("a".utf8))
    }

    func test_ctrlC_isETX() {
        let e = key(8, chars: "c", ignoring: "c", flags: [.control])
        XCTAssertEqual(TerminalTextView.encode(e), Data([0x03]))   // Ctrl-C → 0x03
    }

    func test_ctrlD_isEOT() {
        let e = key(2, chars: "d", ignoring: "d", flags: [.control])
        XCTAssertEqual(TerminalTextView.encode(e), Data([0x04]))   // Ctrl-D → 0x04
    }

    func test_optionAsMeta_prefixesEsc() {
        let e = key(0, chars: "b", ignoring: "b", flags: [.option])
        XCTAssertEqual(TerminalTextView.encode(e), Data([0x1B]) + Data("b".utf8))
    }
}
