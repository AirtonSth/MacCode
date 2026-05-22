import Foundation
import AppKit
import Darwin
import CoreModel
import Persistence
import CSystem
import DesignSystemKit

/// An NSTextView that behaves like a real terminal: every keystroke is
/// translated to bytes and written straight to the pty (via `onKey`),
/// nothing is edited locally — the shell echoes back through the read
/// loop. Selection + ⌘C copy still work; ⌘V pastes into the pty.
@MainActor
final class TerminalTextView: NSTextView {
    var onKey: ((Data) -> Void)?

    convenience init() {
        self.init(frame: .zero)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hideAppKitCaret()
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        hideAppKitCaret()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        hideAppKitCaret()
    }

    private func hideAppKitCaret() {
        // The PTY cursor is drawn into the attributed terminal buffer by
        // ANSIRenderer. Hiding AppKit's caret prevents a second cursor
        // from appearing when the text view is first responder.
        insertionPointColor = .clear
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        return ok
    }

    override func keyDown(with event: NSEvent) {
        guard let bytes = TerminalTextView.encode(event) else { return }
        onKey?(bytes)
    }

    // Forward direct text insertions (including AppKit text drops) to the pty;
    // the shell still owns the rendered buffer through the read loop.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String?
        if let string = string as? String {
            text = string
        } else if let attributed = string as? NSAttributedString {
            text = attributed.string
        } else {
            text = nil
        }
        guard let text, let data = text.data(using: .utf8) else { return }
        onKey?(data)
    }
    override func doCommand(by selector: Selector) {}

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return DroppedFilePaths.canReadFileDrop(from: sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return DroppedFilePaths.canReadFileDrop(from: sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = DroppedFilePaths.paths(from: sender.draggingPasteboard)
        guard !paths.isEmpty else { return super.performDragOperation(sender) }
        guard let data = DroppedFilePaths.terminalInputText(for: paths).data(using: .utf8) else { return false }
        onKey?(data)
        return true
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let paths = DroppedFilePaths.paths(from: pasteboard)
        guard !paths.isEmpty else { return super.readSelection(from: pasteboard, type: type) }
        guard let data = DroppedFilePaths.terminalInputText(for: paths).data(using: .utf8) else { return false }
        onKey?(data)
        return true
    }

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

@MainActor
private final class TerminalDropContainerView: NSView {
    var onFileDrop: (([String]) -> Void)?
    var onLayout: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(DroppedFilePaths.pasteboardTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(DroppedFilePaths.pasteboardTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return DroppedFilePaths.canReadFileDrop(from: sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return DroppedFilePaths.canReadFileDrop(from: sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = DroppedFilePaths.paths(from: sender.draggingPasteboard)
        guard !paths.isEmpty else { return false }
        onFileDrop?(paths)
        return true
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onLayout?()
    }
}

/// PTY-backed shell surface. Spawns the user's shell via `forkpty(3)`
/// and renders its output through `ANSIRenderer`. The terminal view is
/// directly interactive — no separate input field (cmux model).
@MainActor
public final class TerminalSurface: NSObject, Surface {
    public enum Launch {
        case shell(cwd: String)
        case ssh(profile: SSHHostProfile, cwd: String)
        case sshPlaceholder(cwd: String)
    }

    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    private let ghosttyView: GhosttyTerminalView
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private let renderer = ANSIRenderer(
        rows: TerminalViewportGeometry.fallbackSize.rows,
        cols: TerminalViewportGeometry.fallbackSize.cols
    )
    private var terminalSize = TerminalViewportGeometry.fallbackSize
    private var savedSSHPassword: String?
    private var didSendSavedSSHPassword = false
    private var isVisible = true
    private let historyRepo: TerminalOutputRepository?
    private let historyWorkspaceID: String
    private let historyQueue = DispatchQueue(label: "rc2.terminal.history", qos: .utility)
    private var pendingHistoryData = Data()
    private var historyFlushScheduled = false
    private var nextHistoryChunkIndex: Int64 = 1
    private nonisolated static let maxHistoryChunkBytes = 64 * 1024

    public convenience init(workspaceID: WorkspaceID, cwd: String, title: String = "terminal") throws {
        try self.init(workspaceID: workspaceID, title: title, launch: .shell(cwd: cwd))
    }

    public init(workspaceID: WorkspaceID, title: String, launch: Launch, historyRepo: TerminalOutputRepository? = nil) throws {
        self.historyRepo = historyRepo
        self.historyWorkspaceID = workspaceID.value.uuidString
        let cwd: String
        let type: SurfaceType
        var metadata: [String: String]
        switch launch {
        case .shell(let shellCwd):
            cwd = shellCwd
            type = .terminal
            metadata = ["cwd": shellCwd, "workspace": workspaceID.value.uuidString]
        case .ssh(let profile, let shellCwd):
            cwd = shellCwd
            type = .ssh
            savedSSHPassword = profile.password
            metadata = [
                "cwd": shellCwd,
                "workspace": workspaceID.value.uuidString,
                "ssh_profile_id": profile.id.value.uuidString,
                "ssh_destination": profile.destination,
                "ssh_label": profile.label,
                "ssh_status": "connecting"
            ]
            if let port = profile.port { metadata["ssh_port"] = String(port) }
            if let identity = profile.identityFile { metadata["ssh_identity_file"] = identity }
            if !profile.options.isEmpty { metadata["ssh_options"] = profile.options.joined(separator: "\n") }
        case .sshPlaceholder(let shellCwd):
            cwd = shellCwd
            type = .ssh
            metadata = [
                "cwd": shellCwd,
                "workspace": workspaceID.value.uuidString,
                "ssh_status": "disconnected"
            ]
        }
        self.descriptor = SurfaceDescriptor(
            type: type,
            title: title,
            iconName: type == .ssh ? "network" : "terminal",
            metadata: metadata
        )

        // Match cmux/Ghostty's defensive startup sizing: begin with a
        // non-zero view so AppKit has real bounds before the first resize.
        let initialFrame = NSRect(
            x: 0,
            y: 0,
            width: 800,
            height: 600
        )
        let terminalView = GhosttyTerminalView(frame: initialFrame)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        self.ghosttyView = terminalView
        let container = TerminalDropContainerView(frame: initialFrame)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = DS.NS.terminalBG.cgColor
        container.layer?.masksToBounds = true
        container.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: container.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        self.view = container

        super.init()
        if let historyRepo {
            nextHistoryChunkIndex = (try? historyRepo.nextChunkIndex(surfaceID: descriptor.id.value.uuidString)) ?? 1
        }

        terminalView.onInputData = { [weak self] data in self?.writeToPTY(data) }
        terminalView.onTerminalSizeChange = { [weak self] size in
            guard let self else { return }
            self.applyTerminalSize(size, sendToPTY: self.masterFD >= 0)
        }
        container.onFileDrop = { [weak self] paths in
            guard let data = DroppedFilePaths.terminalInputText(for: paths).data(using: .utf8) else { return }
            self?.writeToPTY(data)
        }
        container.onLayout = { [weak self] in
            self?.ghosttyView.forceRefresh()
        }
        applyTerminalSize(TerminalViewportGeometry.fallbackSize, sendToPTY: false, force: true)

        if case .sshPlaceholder = launch {
            appendString("[ssh disconnected]\nSelect a saved SSH host or add a new one to connect.\n")
            return
        }

        var amaster: Int32 = -1
        let pid = rc2_forkpty(&amaster)
        if pid < 0 {
            appendString("[forkpty failed: \(String(cString: strerror(errno)))]\n")
            return
        }
        if pid == 0 {
            _ = chdir(cwd)
            setenv("TERM", "xterm-256color", 1)
            setenv("COLORTERM", "truecolor", 1)
            setenv("CLICOLOR", "1", 1)
            unsetenv("NO_COLOR")
            setenv("TERM_PROGRAM", "ghostty", 1)
            setenv("RC2_WORKSPACE_ID", workspaceID.value.uuidString, 1)
            setenv("RC2_SURFACE_ID", descriptor.id.value.uuidString, 1)
            if getenv("LANG") == nil {
                setenv("LANG", "en_US.UTF-8", 1)
            }
            switch launch {
            case .shell:
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                let shellName = (shell as NSString).lastPathComponent
                shell.withCString { sPath in
                    ("-" + shellName).withCString { argv0 in
                        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(argv0), nil]
                        _ = execv(sPath, argv)
                    }
                }
            case .sshPlaceholder:
                _exit(0)
            case .ssh(let profile, _):
                let args = ["ssh"] + SSHCommandBuilder.sshArguments(for: profile)
                "/usr/bin/ssh".withCString { sPath in
                    let argv = args.map { strdup($0) } + [nil]
                    argv.withUnsafeBufferPointer { ptr in
                        _ = execv(sPath, ptr.baseAddress)
                    }
                }
            }
            _exit(127)
        }
        self.masterFD = amaster
        self.childPID = pid
        applyTerminalSize(terminalSize, sendToPTY: true, force: true)
        startReader()
    }

    private func applyTerminalSize(_ size: TerminalViewportSize, sendToPTY: Bool, force: Bool = false) {
        guard force || size != terminalSize else { return }
        terminalSize = size
        renderer.resize(rows: size.rows, cols: size.cols)
        if sendToPTY, masterFD >= 0 {
            _ = rc2_set_winsize(masterFD, Int32(size.rows), Int32(size.cols))
        }
    }

    private func startReader() {
        let src = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: .global())
        readSource = src
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(self.masterFD, &buf, buf.count)
            if n <= 0 {
                DispatchQueue.main.async { self.handlePTYEOF() }
                return
            }
            let data = Data(buf[0..<Int(n)])
            DispatchQueue.main.async { self.appendDataAsync(data) }
        }
        src.resume()
    }

    private func handlePTYEOF() {
        readSource?.cancel()
        readSource = nil
        if masterFD >= 0 {
            Darwin.close(masterFD)
            masterFD = -1
        }
        reapChildIfExited()
    }

    private func reapChildIfExited() {
        guard childPID > 0 else { return }
        var status: Int32 = 0
        if waitpid(childPID, &status, WNOHANG) == childPID {
            childPID = -1
        }
    }

    private func appendDataAsync(_ data: Data) {
        enqueueHistory(data)
        renderer.feed(data)
        autoSubmitSavedSSHPasswordIfNeeded(from: data)
        descriptor.hasUnreadActivity = true
        // HC-1: stream raw PTY output to the mirror in real time.
        SurfaceOutputBus.shared.emit(descriptor.id, data)
        if isVisible {
            ghosttyView.processOutput(data)
        }
    }

    private func appendString(_ raw: String) {
        guard let data = raw.data(using: .utf8) else { return }
        enqueueHistory(data)
        renderer.feed(data)
        SurfaceOutputBus.shared.emit(descriptor.id, data)
        if isVisible {
            ghosttyView.processOutput(data)
        }
    }

    public func appendSystemText(_ raw: String) {
        appendString(raw)
    }

    private func autoSubmitSavedSSHPasswordIfNeeded(from data: Data) {
        guard !didSendSavedSSHPassword,
              let savedSSHPassword,
              !savedSSHPassword.isEmpty,
              let raw = String(data: data, encoding: .utf8)?.lowercased(),
              raw.contains("password:") || raw.contains("passphrase") else { return }
        didSendSavedSSHPassword = true
        sendText(savedSSHPassword + "\n")
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
        ghosttyView.readViewportText() ?? renderer.snapshot().string
    }

    public func focus() {
        view.window?.makeFirstResponder(ghosttyView)
        ghosttyView.forceRefresh()
        descriptor.hasUnreadActivity = false
    }

    public func unfocus() {}

    public func didBecomeVisible() {
        guard !isVisible else { return }
        isVisible = true
        let snapshot = renderer.snapshot().string
        if let data = snapshot.data(using: .utf8) {
            ghosttyView.resetSurfaceOutput(data)
        } else {
            ghosttyView.forceRefresh()
        }
    }

    public func didBecomeHidden() {
        guard isVisible else { return }
        isVisible = false
        ghosttyView.closeSurface()
    }

    public func close() {
        flushHistory(wait: true)
        readSource?.cancel()
        readSource = nil
        if childPID > 0 {
            let pid = childPID
            childPID = -1
            kill(pid, SIGHUP)
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                _ = waitpid(pid, &status, 0)
            }
        }
        if masterFD >= 0 {
            Darwin.close(masterFD)
            masterFD = -1
        }
        ghosttyView.closeSurface()
    }

    public func flushPersistedHistory() {
        flushHistory(wait: true)
    }

    private func enqueueHistory(_ data: Data) {
        guard historyRepo != nil, !data.isEmpty else { return }
        pendingHistoryData.append(data)
        if pendingHistoryData.count >= Self.maxHistoryChunkBytes {
            flushHistory(wait: false)
        } else {
            scheduleHistoryFlush()
        }
    }

    private func scheduleHistoryFlush() {
        guard !historyFlushScheduled else { return }
        historyFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.historyFlushScheduled = false
            self?.flushHistory(wait: false)
        }
    }

    private func flushHistory(wait: Bool) {
        guard let historyRepo, !pendingHistoryData.isEmpty else { return }
        let data = pendingHistoryData
        pendingHistoryData.removeAll(keepingCapacity: true)
        let surfaceID = descriptor.id.value.uuidString
        let workspaceID = historyWorkspaceID
        let chunkIndex = nextHistoryChunkIndex
        nextHistoryChunkIndex += 1
        let write = DispatchWorkItem {
            try? historyRepo.append(surfaceID: surfaceID, workspaceID: workspaceID, chunkIndex: chunkIndex, data: data)
        }
        if wait {
            historyQueue.sync(execute: write)
        } else {
            historyQueue.async(execute: write)
        }
    }

    public func snapshot() -> [String: String] {
        ["cwd": descriptor.metadata["cwd"] ?? "", "scrollback_chars": String(readText().count)]
    }
}
