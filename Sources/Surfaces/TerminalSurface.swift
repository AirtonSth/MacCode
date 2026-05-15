import Foundation
import AppKit
import Darwin
import CoreModel
import CSystem
import DesignSystemKit

/// An NSTextView that behaves like a real terminal: every keystroke is
/// translated to bytes and written straight to the pty (via `onKey`),
/// nothing is edited locally — the shell echoes back through the read
/// loop. Selection + ⌘C copy still work; ⌘V pastes into the pty.
@MainActor
final class TerminalTextView: NSTextView {
    var onKey: ((Data) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        return ok
    }

    override func keyDown(with event: NSEvent) {
        guard let bytes = TerminalTextView.encode(event) else { return }
        onKey?(bytes)
    }

    // Block local editing entry points; the pty owns the buffer.
    override func insertText(_ string: Any, replacementRange: NSRange) {}
    override func doCommand(by selector: Selector) {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "c":
                if selectedRange().length > 0 { copy(nil); return true }
                return false
            case "v":
                let s = NSPasteboard.general.string(forType: .string) ?? ""
                if let d = s.data(using: .utf8) { onKey?(d) }
                return true
            case "a", "x": // select-all / cut-as-copy fall through to default copy
                return super.performKeyEquivalent(with: event)
            default:
                return super.performKeyEquivalent(with: event)
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Map an NSEvent to the byte sequence a VT100/xterm app expects.
    static func encode(_ event: NSEvent) -> Data? {
        let flags = event.modifierFlags
        let ctrl = flags.contains(.control)
        let opt = flags.contains(.option)

        // Special keys by keyCode.
        switch event.keyCode {
        case 36, 76: return Data([0x0D])              // Return / Enter → CR
        case 48:     return Data([0x09])              // Tab
        case 51:     return Data([0x7F])              // Delete (backspace)
        case 117:    return Data([0x1B, 0x5B, 0x33, 0x7E]) // Forward delete ESC[3~
        case 53:     return Data([0x1B])              // Esc
        case 126:    return Data([0x1B, 0x5B, 0x41])  // Up
        case 125:    return Data([0x1B, 0x5B, 0x42])  // Down
        case 124:    return Data([0x1B, 0x5B, 0x43])  // Right
        case 123:    return Data([0x1B, 0x5B, 0x44])  // Left
        case 115:    return Data([0x1B, 0x5B, 0x48])  // Home
        case 119:    return Data([0x1B, 0x5B, 0x46])  // End
        case 116:    return Data([0x1B, 0x5B, 0x35, 0x7E]) // Page Up
        case 121:    return Data([0x1B, 0x5B, 0x36, 0x7E]) // Page Down
        default: break
        }

        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }

        if ctrl, let scalar = chars.unicodeScalars.first {
            let v = scalar.value
            // Ctrl-A..Ctrl-Z and friends → 0x01..0x1A etc.
            if v >= 0x40 && v < 0x80 {
                return Data([UInt8(v & 0x1F)])
            }
            if scalar == " " { return Data([0x00]) } // Ctrl-Space → NUL
        }

        let text = event.characters ?? chars
        guard var data = text.data(using: .utf8) else { return nil }
        if opt { // Option as Meta: prefix ESC
            data.insert(0x1B, at: data.startIndex)
        }
        return data
    }
}

/// PTY-backed shell surface. Spawns the user's shell via `forkpty(3)`
/// and renders its output through `ANSIRenderer`. The terminal view is
/// directly interactive — no separate input field (cmux model).
@MainActor
public final class TerminalSurface: NSObject, Surface {
    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    private let textView: TerminalTextView
    private let scroll: NSScrollView
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private let renderer = ANSIRenderer(rows: 40, cols: 120)
    private var pendingFlush = false

    public init(workspaceID: WorkspaceID, cwd: String, title: String = "terminal") throws {
        self.descriptor = SurfaceDescriptor(
            type: .terminal,
            title: title,
            iconName: "terminal",
            metadata: ["cwd": cwd, "workspace": workspaceID.value.uuidString]
        )

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = DS.NS.terminalBG
        scroll.wantsLayer = true
        scroll.layer?.masksToBounds = true
        scroll.contentView.wantsLayer = true
        scroll.contentView.layer?.masksToBounds = true

        let tv = TerminalTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.backgroundColor = DS.NS.terminalBG
        tv.textColor = DS.NS.terminalFG
        tv.drawsBackground = true
        tv.insertionPointColor = DS.NS.terminalFG
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv
        self.textView = tv
        self.scroll = scroll

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = DS.NS.terminalBG.cgColor
        container.layer?.masksToBounds = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        self.view = container

        super.init()

        tv.onKey = { [weak self] data in self?.writeToPTY(data) }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var amaster: Int32 = -1
        let pid = rc2_forkpty(&amaster)
        if pid < 0 {
            appendString("[forkpty failed: \(String(cString: strerror(errno)))]\n")
            return
        }
        if pid == 0 {
            _ = chdir(cwd)
            setenv("TERM", "xterm-256color", 1)
            setenv("RC2_WORKSPACE_ID", workspaceID.value.uuidString, 1)
            setenv("RC2_SURFACE_ID", descriptor.id.value.uuidString, 1)
            let shellName = (shell as NSString).lastPathComponent
            shell.withCString { sPath in
                ("-" + shellName).withCString { argv0 in
                    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(argv0), nil]
                    _ = execv(sPath, argv)
                }
            }
            _exit(127)
        }
        self.masterFD = amaster
        self.childPID = pid
        _ = rc2_set_winsize(masterFD, 40, 120)
        startReader()
    }

    private func startReader() {
        let src = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: .global())
        readSource = src
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(self.masterFD, &buf, buf.count)
            if n <= 0 { return }
            let data = Data(buf[0..<Int(n)])
            DispatchQueue.main.async { self.appendDataAsync(data) }
        }
        src.resume()
    }

    private func appendDataAsync(_ data: Data) {
        renderer.feed(data)
        descriptor.hasUnreadActivity = true
        scheduleFlush()
    }

    private func scheduleFlush() {
        if pendingFlush { return }
        pendingFlush = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingFlush = false
            let snap = self.renderer.snapshot()
            // Preserve the user's selection across redraws when possible.
            let sel = self.textView.selectedRange()
            self.textView.textStorage?.setAttributedString(snap)
            if sel.location + sel.length <= (self.textView.string as NSString).length {
                self.textView.setSelectedRange(sel)
            }
            self.scrollCursorToVisible(in: snap)
        }
    }

    private func scrollCursorToVisible(in snap: NSAttributedString) {
        let location = renderer.cursorOffset(in: snap.string)
        textView.scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    private func appendString(_ raw: String) {
        guard let data = raw.data(using: .utf8) else { return }
        renderer.feed(data)
        scheduleFlush()
    }

    private func writeToPTY(_ data: Data) {
        guard masterFD >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { ptr in
            _ = Darwin.write(masterFD, ptr.baseAddress, data.count)
        }
    }

    public func sendText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        writeToPTY(data)
    }

    public func readText() -> String {
        textView.string
    }

    public func focus() {
        view.window?.makeFirstResponder(textView)
        descriptor.hasUnreadActivity = false
    }

    public func unfocus() {}

    public func close() {
        readSource?.cancel()
        readSource = nil
        if childPID > 0 { kill(childPID, SIGHUP) }
        if masterFD >= 0 {
            Darwin.close(masterFD)
            masterFD = -1
        }
    }

    public func snapshot() -> [String: String] {
        ["cwd": descriptor.metadata["cwd"] ?? "", "scrollback_chars": String(textView.string.count)]
    }
}
