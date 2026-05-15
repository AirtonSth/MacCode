import Foundation
import AppKit
import Darwin
import CoreModel
import CSystem
import DesignSystemKit

/// PTY-backed shell surface. Spawns the user's shell via `forkpty(3)` so
/// the child sees a real controlling terminal and `isatty()` returns true.
/// ANSI escapes are stripped on the way to NSTextView for readability;
/// raw bytes are still sent to the master fd via `sendText`.
@MainActor
public final class TerminalSurface: NSObject, Surface {
    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    private let textView: NSTextView
    private let scroll: NSScrollView
    private let inputField: NSTextField
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

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.backgroundColor = DS.NS.terminalBG
        tv.textColor = DS.NS.terminalFG
        tv.drawsBackground = true
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv
        self.textView = tv
        self.scroll = scroll

        let input = NSTextField()
        input.placeholderString = "Type a command and press Return"
        input.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        input.bezelStyle = .squareBezel
        input.drawsBackground = true
        input.backgroundColor = DS.NS.surface
        input.textColor = DS.NS.text
        input.focusRingType = .none
        self.inputField = input

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        input.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        container.addSubview(input)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: input.topAnchor, constant: -2),
            input.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            input.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            input.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            input.heightAnchor.constraint(equalToConstant: 24)
        ])
        self.view = container

        super.init()
        input.target = self
        input.action = #selector(submit)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var amaster: Int32 = -1
        let pid = rc2_forkpty(&amaster)
        if pid < 0 {
            appendString("[forkpty failed: \(String(cString: strerror(errno)))]\n")
            return
        }
        if pid == 0 {
            // Child: change to cwd, set env, exec the user's shell.
            _ = chdir(cwd)
            setenv("TERM", "xterm-256color", 1)
            setenv("RC2_WORKSPACE_ID", workspaceID.value.uuidString, 1)
            setenv("RC2_SURFACE_ID", descriptor.id.value.uuidString, 1)
            let shellName = (shell as NSString).lastPathComponent
            shell.withCString { sPath in
                ("-" + shellName).withCString { argv0 in
                    // Login shell: argv[0] is "-zsh" or similar.
                    let argv: [UnsafeMutablePointer<CChar>?] = [
                        strdup(argv0),
                        nil
                    ]
                    _ = execv(sPath, argv)
                }
            }
            _exit(127)
        }
        self.masterFD = amaster
        self.childPID = pid
        _ = rc2_set_winsize(masterFD, 40, 120)
        startReader()
        appendString("[shell started: \(shell) cwd=\(cwd) pid=\(pid)]\n")
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
            self.textView.textStorage?.setAttributedString(snap)
            self.textView.scrollToEndOfDocument(nil)
        }
    }

    private func appendString(_ raw: String) {
        guard let data = raw.data(using: .utf8) else { return }
        renderer.feed(data)
        scheduleFlush()
    }

    @objc private func submit() {
        let line = inputField.stringValue + "\n"
        inputField.stringValue = ""
        sendText(line)
    }

    public func sendText(_ text: String) {
        guard masterFD >= 0, let data = text.data(using: .utf8) else { return }
        data.withUnsafeBytes { ptr in
            _ = Darwin.write(masterFD, ptr.baseAddress, data.count)
        }
    }

    public func readText() -> String {
        textView.string
    }

    public func focus() {
        view.window?.makeFirstResponder(inputField)
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
