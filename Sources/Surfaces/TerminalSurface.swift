import Foundation
import AppKit
import CoreModel

/// Pipe-backed shell surface. This is a deliberate V1 simplification: it
/// runs the user's shell with stdin/stdout/stderr connected to pipes
/// (not a real PTY), so interactive programs that probe isatty() will
/// behave differently than in a normal terminal. Use the agent's
/// Codex/Claude CLI in --json/--print modes, which do not require a TTY.
@MainActor
public final class TerminalSurface: NSObject, Surface {
    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    private let textView: NSTextView
    private let scroll: NSScrollView
    private let inputField: NSTextField
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

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
        tv.backgroundColor = NSColor.black
        tv.textColor = NSColor.white
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
        input.placeholderString = "Type command and press Return (pipe-backed shell)"
        input.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        input.bezelStyle = .squareBezel
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
        process.executableURL = URL(fileURLWithPath: shell)
        // -i interactive without rc: we want command-line oriented behavior; use -s -i
        process.arguments = ["-i", "-l"]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["RC2_WORKSPACE_ID"] = workspaceID.value.uuidString
        env["RC2_SURFACE_ID"] = descriptor.id.value.uuidString
        env["TERM"] = "dumb"
        process.environment = env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.appendDataAsync(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.appendDataAsync(data) }
        }

        do {
            try process.run()
            appendString("[shell started: \(shell) cwd=\(cwd)]\n")
        } catch {
            appendString("[failed to start shell: \(error.localizedDescription)]\n")
        }
    }

    private func appendDataAsync(_ data: Data) {
        let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        appendString(s)
    }

    private func appendString(_ raw: String) {
        let clean = stripAnsi(raw)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.white
        ]
        textView.textStorage?.append(NSAttributedString(string: clean, attributes: attrs))
        textView.scrollToEndOfDocument(nil)
        descriptor.hasUnreadActivity = true
    }

    private func stripAnsi(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\u{1B}" {
                var j = s.index(after: i)
                if j < s.endIndex, s[j] == "[" {
                    j = s.index(after: j)
                    while j < s.endIndex {
                        let cc = s[j]
                        if cc.isLetter || cc == "~" { j = s.index(after: j); break }
                        j = s.index(after: j)
                    }
                    i = j
                    continue
                } else {
                    i = j
                    continue
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }

    @objc private func submit() {
        let line = inputField.stringValue + "\n"
        inputField.stringValue = ""
        sendText(line)
    }

    public func sendText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
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
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        try? stdinPipe.fileHandleForWriting.close()
    }

    public func snapshot() -> [String: String] {
        ["cwd": descriptor.metadata["cwd"] ?? "", "scrollback_chars": String(textView.string.count)]
    }
}
