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

    func test_ghosttyCtrlC_usesUnmodifiedTextForTerminalInterrupt() {
        let e = key(8, chars: "\u{03}", ignoring: "c", flags: [.control])

        XCTAssertEqual(GhosttyTerminalKeyInput.text(for: e), "c",
                       "Ctrl-C must be delivered to Ghostty as the C key plus the Control modifier so Ghostty encodes ETX instead of printable CSI-u text")
    }

    func test_ctrlD_isEOT() {
        let e = key(2, chars: "d", ignoring: "d", flags: [.control])
        XCTAssertEqual(TerminalTextView.encode(e), Data([0x04]))   // Ctrl-D → 0x04
    }

    func test_ghosttyCtrlD_usesUnmodifiedTextForTerminalEOF() {
        let e = key(2, chars: "\u{04}", ignoring: "d", flags: [.control])

        XCTAssertEqual(GhosttyTerminalKeyInput.text(for: e), "d",
                       "Ctrl-D must stay key-based terminal control input so shells receive EOF instead of literal text")
    }

    func test_ghosttyPlainEscape_doesNotSendControlText() {
        let e = key(53, chars: "\u{1B}", ignoring: "\u{1B}")

        XCTAssertNil(GhosttyTerminalKeyInput.text(for: e),
                     "Plain Escape is a key event, not printable text; sending it as text confuses TUI shortcut handling")
    }

    func test_optionAsMeta_prefixesEsc() {
        let e = key(0, chars: "b", ignoring: "b", flags: [.option])
        XCTAssertEqual(TerminalTextView.encode(e), Data([0x1B]) + Data("b".utf8))
    }

    func test_terminalTextViewHidesAppKitCaretBecauseRendererOwnsCursor() {
        let textView = TerminalTextView()

        XCTAssertEqual(textView.insertionPointColor, .clear,
                       "the terminal renderer draws the PTY cursor; AppKit's insertion caret must stay hidden so users never see two cursors")
        XCTAssertTrue(textView.isEditable,
                      "the terminal must remain editable enough for AppKit text input, paste, and drops while local mutations are routed to the PTY")
    }

    func test_droppedFilePaths_areShellEscapedForTerminalInput() {
        let text = DroppedFilePaths.terminalInputText(for: [
            "/tmp/plain.txt",
            "/tmp/has space.txt",
            "/tmp/it'works.swift"
        ])

        XCTAssertEqual(text, "/tmp/plain.txt '/tmp/has space.txt' '/tmp/it'\\''works.swift'",
                       "dragged files must land as shell-safe path text without pressing Return")
    }

    func test_fileURLPasteboardReadsDraggedFilePaths() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/plain.txt")]))

        XCTAssertEqual(DroppedFilePaths.paths(from: pasteboard), ["/tmp/plain.txt"],
                       "Finder file-url drops must resolve to absolute path text")
    }

    func test_fileURLStringPasteboardReadsDraggedFilePaths() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("file:///tmp/plain.txt", forType: .fileURL)

        XCTAssertEqual(DroppedFilePaths.paths(from: pasteboard), ["/tmp/plain.txt"],
                       "Finder file-url string drops must resolve to absolute path text")
    }
}
