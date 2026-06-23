import XCTest
import AppKit
import Darwin
import CoreModel
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

    func test_shiftedQuoteAndTildeUseTextInputCompositionPath() {
        let quote = key(39, chars: "\"", ignoring: "'", flags: [.shift])
        let tilde = key(50, chars: "~", ignoring: "`", flags: [.shift])

        XCTAssertTrue(TerminalKeyboardInput.shouldUseTextInput(for: quote),
                      "shifted quote must go through AppKit text input so international dead-key layouts can commit a literal double quote")
        XCTAssertTrue(TerminalKeyboardInput.shouldUseTextInput(for: tilde),
                      "shifted tilde must go through AppKit text input so international dead-key layouts can commit a literal tilde")
    }

    func test_deadKeyEventsUseTextInputCompositionPath() {
        let deadKey = key(50, chars: "", ignoring: "")

        XCTAssertTrue(TerminalKeyboardInput.shouldUseTextInput(for: deadKey),
                      "dead keys start with no printable characters; terminal input must let AppKit compose them instead of dropping the event")
    }

    func test_reportedQuoteAndTildeCommitLiteralShellCharacters() {
        let quote = key(39, chars: "\"", ignoring: "'", flags: [.shift])
        let tilde = key(50, chars: "~", ignoring: "`", flags: [.shift])

        XCTAssertEqual(TerminalKeyboardInput.literalShellText(for: quote), "\"",
                       "terminal input must commit a reported literal double quote instead of letting text composition swallow shell syntax")
        XCTAssertEqual(TerminalKeyboardInput.literalShellText(for: tilde), "~",
                       "terminal input must commit a reported literal tilde instead of letting text composition swallow shell syntax")
    }

    func test_deadQuoteAndTildeKeysCommitLiteralShellCharacters() {
        let quote = key(39, chars: "", ignoring: "", flags: [.shift])
        let tilde = key(50, chars: "", ignoring: "", flags: [.shift])

        XCTAssertEqual(TerminalKeyboardInput.literalShellText(for: quote), "\"",
                       "when the keyboard reports shifted quote as a dead key, terminal input must still commit a literal double quote")
        XCTAssertEqual(TerminalKeyboardInput.literalShellText(for: tilde), "~",
                       "when the keyboard reports shifted tilde as a dead key, terminal input must still commit a literal tilde")
    }

    func test_ordinaryPrintableTextDoesNotUseLiteralShellBypass() {
        let e = key(0, chars: "a", ignoring: "a")

        XCTAssertNil(TerminalKeyboardInput.literalShellText(for: e),
                     "ordinary printable text should continue through AppKit text input instead of the shell literal bypass")
    }

    func test_controlOptionAndNavigationBypassTextInputCompositionPath() {
        let ctrlC = key(8, chars: "\u{03}", ignoring: "c", flags: [.control])
        let optionB = key(11, chars: "∫", ignoring: "b", flags: [.option])
        let upArrow = key(126)
        let downArrow = key(125)
        let enter = key(36)

        XCTAssertFalse(TerminalKeyboardInput.shouldUseTextInput(for: ctrlC),
                       "terminal control shortcuts must stay raw so Ctrl-C still interrupts the PTY")
        XCTAssertFalse(TerminalKeyboardInput.shouldUseTextInput(for: optionB),
                       "Option-as-Meta must stay raw so shells receive ESC-prefixed input")
        XCTAssertFalse(TerminalKeyboardInput.shouldUseTextInput(for: upArrow),
                       "navigation keys must stay raw VT input instead of becoming text commands")
        XCTAssertFalse(TerminalKeyboardInput.shouldUseTextInput(for: downArrow),
                       "TUI Down-arrow navigation must stay on Ghostty's raw key path instead of sidebar/text-input handling")
        XCTAssertFalse(TerminalKeyboardInput.shouldUseTextInput(for: enter),
                       "Enter must stay raw CR input so command submission remains immediate")
    }

    func test_reportedDigitUsesTextInputPathForTerminalPromptChoices() {
        let five = key(23, chars: "5", ignoring: "5")

        XCTAssertTrue(TerminalKeyboardInput.shouldUseTextInput(for: five),
                      "numbered TUI choices like 5 must reach the active terminal as printable text")
        XCTAssertEqual(GhosttyTerminalKeyInput.text(for: five), "5",
                       "Ghostty text extraction must preserve the exact digit typed for terminal prompt choices")
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

    func test_inputPumpRetriesPartialWritesUntilExactOrderedBytesArrive() {
        let chunks = LockedTerminalChunks()
        let pump = TerminalInputPump { data, offset in
            let remaining = data.count - offset
            let count = min(3, remaining)
            chunks.append(data.subdata(in: offset..<(offset + count)))
            return .wrote(count)
        }

        XCTAssertEqual(pump.enqueue(Data("abcdef".utf8)), .accepted)
        XCTAssertEqual(pump.enqueue(Data("ghij".utf8)), .accepted)
        pump.drain()

        XCTAssertEqual(String(data: chunks.joined(), encoding: .utf8), "abcdefghij",
                       "large terminal input must be written in order even when the PTY accepts only partial chunks")
    }

    func test_inputPumpRetriesInterruptedAndWouldBlockWritesWithoutDroppingBytes() {
        let chunks = LockedTerminalChunks()
        let attempts = LockedCounter()
        let pump = TerminalInputPump(retryDelay: 0) { data, offset in
            let attempt = attempts.increment()
            if attempt == 1 { return .interrupted }
            if attempt == 2 { return .wouldBlock }
            chunks.append(data.subdata(in: offset..<data.count))
            return .wrote(data.count - offset)
        }

        XCTAssertEqual(pump.enqueue(Data("retry-me".utf8)), .accepted)
        pump.drain()

        XCTAssertEqual(String(data: chunks.joined(), encoding: .utf8), "retry-me",
                       "EINTR/EAGAIN are normal PTY pressure signals and must not make remote input disappear")
    }

    func test_inputPumpRejectsQueueOverflowBeforeReportingSuccess() {
        let pump = TerminalInputPump(maxQueuedBytes: 4) { _, _ in .wrote(1) }

        XCTAssertEqual(pump.enqueue(Data("12345".utf8)), .queueFull,
                       "remote paste must fail loudly when the bounded input queue cannot accept the payload")
    }

    func test_inputPumpDeadStateRejectsFutureInputAsProcessExited() {
        let pump = TerminalInputPump { _, _ in .wrote(1) }
        pump.stop()

        XCTAssertEqual(pump.enqueue(Data("x".utf8)), .processExited,
                       "after terminal death, iOS/macOS input must receive process_exited instead of silent success")
    }

    func test_ghosttySurfaceSlotRemovesPointerBeforeCloseSoStaleRefreshesCannotReuseIt() {
        let slot = GhosttySurfaceSlot()
        let generation = slot.beginCreate()!
        let fakeSurface = UnsafeMutableRawPointer(bitPattern: 0x1)!

        XCTAssertTrue(slot.install(fakeSurface, generation: generation))
        XCTAssertEqual(slot.liveSurface(), fakeSurface)

        XCTAssertEqual(slot.removeForClose(), fakeSurface)
        XCTAssertNil(slot.liveSurface(),
                     "closing must clear the live pointer before free so delayed refresh/input paths cannot use stale Ghostty memory")
        slot.markClosed()
        XCTAssertNil(slot.removeForClose(),
                     "double close must be idempotent because app/window teardown can race terminal surface teardown")
    }

    func test_terminalStartupEnvironmentProtectsTerminalIdentityAndPreservesUserShellConfig() {
        let workspaceID = WorkspaceID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let surfaceID = SurfaceID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let environment = TerminalStartupEnvironment(
            parent: [
                "TERM": "dumb",
                "COLORTERM": "none",
                "TERM_PROGRAM": "Apple_Terminal",
                "ZDOTDIR": "/tmp/custom-zdotdir",
                "SHELL": "/bin/bash",
                "LANG": "pt_BR.UTF-8"
            ],
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )

        XCTAssertEqual(environment.assignments["TERM"], "xterm-256color",
                       "terminal identity must be owned by the managed terminal renderer, not inherited from the launching app")
        XCTAssertEqual(environment.assignments["COLORTERM"], "truecolor")
        XCTAssertEqual(environment.assignments["TERM_PROGRAM"], "ghostty")
        XCTAssertNil(environment.assignments["ZDOTDIR"],
                     "custom ZDOTDIR must stay inherited so zsh user config is preserved")
        XCTAssertNil(environment.assignments["LANG"],
                     "an existing locale must not be overwritten by the terminal helper")
        XCTAssertEqual(TerminalStartupEnvironment.shellPath(from: ["SHELL": "/bin/bash"]), "/bin/bash")
    }

    func test_terminalStartupEnvironmentBlanksOnlyKnownInheritedAgentSelectionKeys() {
        let workspaceID = WorkspaceID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        let surfaceID = SurfaceID(UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
        let environment = TerminalStartupEnvironment(
            parent: [
                "ANTHROPIC_API_KEY": "secret",
                "ANTHROPIC_MODEL": "stale-model",
                "OPENAI_API_KEY": "user-terminal-secret"
            ],
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )

        XCTAssertEqual(environment.assignments["ANTHROPIC_API_KEY"], "",
                       "known inherited Claude selection/auth env is blanked to avoid leaking stale app agent state into long-running terminals")
        XCTAssertEqual(environment.assignments["ANTHROPIC_MODEL"], "")
        XCTAssertNil(environment.assignments["OPENAI_API_KEY"],
                     "unmanaged user shell secrets must remain inherited instead of being logged, copied, or selectively erased")
        XCTAssertTrue(environment.removals.contains("NO_COLOR"))
    }

    func test_tickCoalescerAllowsOnlyOnePendingMainQueueTickUnderConcurrentWakeups() {
        let coalescer = TerminalTickCoalescer()
        let accepted = LockedCounter()

        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            if coalescer.trySchedule() {
                _ = accepted.increment()
            }
        }

        XCTAssertEqual(accepted.current, 1,
                       "Ghostty can fire wakeups from renderer/io threads; the terminal runtime must coalesce them under a lock so bulk output cannot flood the main queue and freeze input")
        XCTAssertFalse(coalescer.trySchedule(),
                       "a pending tick must stay pending until the main-queue tick runs")

        coalescer.complete()

        XCTAssertTrue(coalescer.trySchedule(),
                      "after the queued tick runs, a later Ghostty wakeup must be allowed to schedule the next render pass")
    }

    func test_terminalFileDescriptorEnablesNonBlockingWritesForBackpressure() {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        defer {
            close(fds[0])
            close(fds[1])
        }

        XCTAssertTrue(TerminalFileDescriptorFlags.enableNonBlocking(fds[1]))
        let flags = fcntl(fds[1], F_GETFL)

        XCTAssertNotEqual(flags & O_NONBLOCK, 0,
                          "PTY input must return EAGAIN under backpressure instead of blocking the input pump and making a long-running terminal stop accepting keystrokes")
    }
}

private final class LockedTerminalChunks {
    private let lock = NSLock()
    private var chunks: [Data] = []

    func append(_ data: Data) {
        lock.lock(); chunks.append(data); lock.unlock()
    }

    func joined() -> Data {
        lock.lock(); defer { lock.unlock() }
        return chunks.reduce(into: Data()) { $0.append($1) }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }

    var current: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
