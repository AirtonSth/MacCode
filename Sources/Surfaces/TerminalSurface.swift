import Foundation
import AppKit
import Darwin
import Carbon.HIToolbox
import CoreModel
import Persistence
import RemoteCodeCSystem
import DesignSystemKit
import os

private let terminalLog = Logger(subsystem: "io.remotecode.surfaces", category: "terminal")

/// An NSTextView that behaves like a real terminal: every keystroke is
/// translated to bytes and written straight to the pty (via `onKey`),
/// nothing is edited locally — the shell echoes back through the read
/// loop. Selection + ⌘C copy still work; ⌘V pastes into the pty.
@MainActor
final class TerminalTextView: NSTextView {
    var onKey: ((Data) -> Void)?
    /// Called when a paste is classified as requiring confirmation.
    /// The receiver should present a sheet and, on confirmation, call
    /// `onKey` with the text encoded as UTF-8.
    var onPasteNeedsConfirm: ((String) -> Void)?

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
        if TerminalKeyboardInput.shouldUseTextInput(for: event) {
            if let text = TerminalKeyboardInput.literalShellText(for: event),
               let data = text.data(using: .utf8) {
                onKey?(data)
                return
            }
            interpretKeyEvents([event])
            return
        }
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
                switch PasteGuard.classify(s) {
                case .safe:
                    if let d = s.data(using: .utf8) { onKey?(d) }
                case .needsConfirm:
                    onPasteNeedsConfirm?(s)
                }
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

enum TerminalKeyboardInput {
    static func shouldUseTextInput(for event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            return false
        }
        return !isRawTerminalKey(event.keyCode)
    }

    static func isRawTerminalKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 36, 76, 48, 51, 117, 53, 126, 125, 124, 123, 115, 119, 116, 121:
            return true
        default:
            return false
        }
    }

    static func literalShellText(for event: NSEvent) -> String? {
        guard shouldUseTextInput(for: event) else { return nil }
        if let text = event.characters, !text.isEmpty {
            return text == "\"" || text == "~" ? text : nil
        }

        let shifted = event.modifierFlags.contains(.shift)
        switch (event.keyCode, shifted) {
        case (50, true):
            return "~"
        case (50, false):
            return "`"
        case (39, true):
            return "\""
        case (39, false):
            return "'"
        default:
            return translatedTextIgnoringDeadKeys(for: event)
        }
    }

    private static func translatedTextIgnoringDeadKeys(for event: NSEvent) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = unsafeBitCast(rawLayoutData, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }

        let modifierKeyState = UInt32((event.modifierFlags.rawValue >> 16) & 0xFF)
        var deadKeyState: UInt32 = 0
        var actualLength = 0
        var unicode = [UniChar](repeating: 0, count: 8)
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(
                layout,
                UInt16(event.keyCode),
                UInt16(kUCKeyActionDown),
                modifierKeyState,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                unicode.count,
                &actualLength,
                &unicode
            )
        }
        guard status == noErr, actualLength > 0 else { return nil }
        return String(utf16CodeUnits: unicode, count: actualLength)
    }
}

@MainActor
private final class TerminalDropContainerView: NSView {
    var onFileDrop: (([String]) -> Void)?
    var onLayout: (() -> Void)?
    var onWindowChanged: ((NSWindow?) -> Void)?

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
        onWindowChanged?(window)
    }
}

// MARK: - Drag payload resolver (pure, non-MainActor, testable)

/// Resolves an NSDraggingInfo pasteboard into the text that should be sent to
/// the terminal when the user drops a plain-text item or a file URL onto the
/// terminal view.
///
/// Keeping this pure (no AppKit UI, no actor) lets unit tests cover the
/// conversion logic without a live drag session or window server.
///
/// Rules:
/// - If the pasteboard carries a plain `.string` value, that string is returned
///   as-is (the caller is responsible for applying `PasteGuard` before sending).
/// - If no plain string is present but a file URL can be read, the POSIX path
///   of the first URL is returned. The caller uses `DroppedFilePaths` for
///   multi-file drops with shell-escaping; this helper is for the single-item
///   plain-text seam.
/// - Returns `nil` when neither type is readable.
public enum TerminalDragPayload {
    /// Extract the plain-text value from a pasteboard for terminal input.
    /// Returns `nil` when the pasteboard has no readable `.string` content.
    public nonisolated static func plainText(from pasteboard: NSPasteboard) -> String? {
        pasteboard.string(forType: .string)
    }

    /// Sanitise `text` for terminal drag input.
    ///
    /// Returns the same string when it is safe to send immediately (single-line,
    /// no dangerous control characters, per `PasteGuard`). Returns `nil` when the
    /// content needs confirmation — the caller must invoke the confirm callback
    /// before sending.
    ///
    /// This is the pure seam tests exercise: `PasteGuard.classify` is the
    /// underlying rule; drag re-uses those semantics so the terminal never
    /// silently executes a multi-line command dropped from another source.
    public nonisolated static func safeTextToSend(_ text: String) -> String? {
        switch PasteGuard.classify(text) {
        case .safe: return text
        case .needsConfirm: return nil
        }
    }
}

// MARK: - Restart decision helper (pure, non-MainActor, testable)

/// Captures the minimal information needed to decide whether and how to
/// restart a dead terminal, and to produce the parameters for the new spawn.
/// Keeping this pure (no AppKit, no actor) lets unit tests cover the logic
/// without a live UI.
public enum TerminalRestartDecision {
    /// Returns `(cwd, title)` if `descriptor` represents a restartable local
    /// shell (type `.terminal`, non-empty cwd). Returns `nil` for SSH surfaces
    /// and placeholders — those have their own reconnect flow.
    public static func spawnRequest(from descriptor: SurfaceDescriptor) -> (cwd: String, title: String)? {
        guard descriptor.type == .terminal,
              let cwd = descriptor.metadata["cwd"], !cwd.isEmpty else { return nil }
        return (cwd, descriptor.title)
    }
}

// MARK: - Paste guard (pure, non-MainActor, testable)

/// Classifies a candidate paste payload so the terminal can confirm before
/// sending multi-line or control-character content to the shell.
///
/// Keeping this pure (no AppKit, no actor) lets unit tests cover the logic
/// without a live UI.
public enum PasteGuard {
    /// The result of classifying a paste string.
    public enum Classification: Equatable {
        /// Safe to send immediately (single-line, no control characters).
        case safe
        /// Requires user confirmation before sending; `reason` is a
        /// short human-readable explanation.
        case needsConfirm(reason: String)
    }

    /// Whether bracketed-paste mode is enabled by default.
    /// When `true`, the terminal should send the bracketed-paste escape
    /// sequences (ESC[?2004h / ESC[?2004l) around pasted content.
    public static let bracketedPasteEnabled = true

    /// Classify `text` as safe or requiring confirmation.
    ///
    /// Rules:
    /// - Empty → `.safe`
    /// - Contains a newline character (`\n`, `\r`) → `.needsConfirm(reason: "multi-line")`
    /// - Contains a C0 control character (U+0000–U+001F, excluding `\t`),
    ///   DEL (U+007F), or ESC (U+001B) → `.needsConfirm(reason: "control-characters")`
    /// - Otherwise → `.safe`
    public static func classify(_ text: String) -> Classification {
        guard !text.isEmpty else { return .safe }
        for scalar in text.unicodeScalars {
            let v = scalar.value
            // Newlines
            if v == 0x0A || v == 0x0D { return .needsConfirm(reason: "multi-line") }
            // C0 controls (0x00-0x1F) except horizontal tab (0x09)
            // ESC (0x1B) is in this range and also blocked
            if v <= 0x1F && v != 0x09 { return .needsConfirm(reason: "control-characters") }
            // DEL
            if v == 0x7F { return .needsConfirm(reason: "control-characters") }
        }
        return .safe
    }
}

// MARK: - Bell detector (pure, non-MainActor, testable)

/// Detects whether a PTY data chunk contains a real BEL (0x07) — one that is
/// NOT the OSC string-terminator in an `ESC ] ... BEL` sequence.
///
/// Background: OSC (Operating System Command) sequences use BEL as one of the
/// two legal string terminators (the other is `ESC \`). A title-set sequence
/// looks like: `ESC (0x1B) ] (0x5D) 0 ; <title> BEL (0x07)`. The 0x07 there
/// terminates the OSC and must NOT be treated as an audible bell — doing so
/// produces spurious "unread" activity dots every time the shell changes the tab
/// title (UX-TERM-BEL-FALSE-POSITIVE).
///
/// Keeping this pure (no AppKit, no actor) lets unit tests cover the scanning
/// logic without a live terminal.
public enum BellDetector {
    /// Returns `true` when `data` contains at least one BEL byte (0x07) that
    /// is NOT acting as an OSC string-terminator.
    ///
    /// State machine:
    /// - Scanning normally: 0x1B starts `.afterESC`.
    /// - `.afterESC + 0x5D` → `.inOSC` (inside OSC payload).
    /// - `.inOSC + 0x07` → OSC-terminator BEL, ignored; back to `.scanning`.
    /// - `.inOSC + 0x1B` → starts `.afterESCinOSC` (two-byte ST path).
    /// - `.afterESCinOSC + 0x5C` → two-byte ST, back to `.scanning`.
    /// - `.afterESCinOSC + anything-else` → ESC aborted the OSC; re-evaluate the
    ///   byte in ground state (a following 0x07 is a real BEL).
    /// - `.scanning + 0x07` → real BEL, return `true`.
    /// - Any other byte resets `.afterESC` back to `.scanning`.
    public nonisolated static func containsStandaloneBEL(_ data: Data) -> Bool {
        var state: State = .scanning
        for byte in data {
            switch state {
            case .scanning:
                if byte == 0x07 { return true }
                if byte == 0x1B { state = .afterESC }
            case .afterESC:
                if byte == 0x5D { state = .inOSC } else { state = .scanning }
            case .inOSC:
                if byte == 0x07 { state = .scanning }      // OSC BEL terminator
                else if byte == 0x1B { state = .afterESCinOSC }
                // else: still inside OSC payload — remain in .inOSC
            case .afterESCinOSC:
                // 0x5C = '\\' completes the two-byte ST (ESC \), terminating the
                // OSC with no bell. Any other byte means the ESC did NOT form ST:
                // a bare ESC aborts the OSC string and returns to ground (xterm
                // treats ESC as an anywhere->escape transition), so this byte is
                // re-evaluated as if scanning -- a following 0x07 is a real BEL.
                if byte == 0x5C {
                    state = .scanning
                } else {
                    state = .scanning
                    if byte == 0x07 { return true }
                    if byte == 0x1B { state = .afterESC }
                }
            }
        }
        return false
    }

    private enum State { case scanning, afterESC, inOSC, afterESCinOSC }
}

// MARK: - Bell preferences (pure, non-MainActor, testable)

/// User-configurable bell preferences.
///
/// Keeping this pure (no AppKit, no actor) lets unit tests cover the logic
/// without a live UI. The surface reads this at bell time and passes it to
/// `BellHandler.effects(prefs:)` to decide which side-effects to apply.
public struct BellPreferences: Equatable {
    /// Play the system beep (`NSSound.beep()`) when a bell is received.
    public var sound: Bool
    /// Show a brief visual flash on the terminal view when a bell is received.
    public var flash: Bool

    /// Default: silent — no sound, no flash. New installs must not produce
    /// unexpected audio or visual disturbance without explicit user opt-in.
    public init(sound: Bool = false, flash: Bool = false) {
        self.sound = sound
        self.flash = flash
    }
}

/// The resolved set of side-effects to apply for a single bell event.
public struct BellEffects: Equatable {
    /// Whether to call `NSSound.beep()`.
    public let playSound: Bool
    /// Whether to trigger a visual flash on the terminal view.
    public let flash: Bool
    /// Whether to mark the surface as having unread activity (dot).
    /// Always `true` — the dot is the lowest-distraction baseline feedback.
    public let dot: Bool
}

/// Pure mapping from bell preferences to bell effects.
///
/// Keeping this non-MainActor lets unit tests cover the logic without AppKit.
/// The surface is responsible for executing the returned effects on the main actor.
public enum BellHandler {
    /// Map `prefs` to the set of effects that should be applied on the next bell.
    /// `dot` is always `true`; `playSound` and `flash` mirror the preference flags.
    public nonisolated static func effects(prefs: BellPreferences) -> BellEffects {
        BellEffects(playSound: prefs.sound, flash: prefs.flash, dot: true)
    }
}

// MARK: - Export format helpers (pure, non-MainActor, testable)

/// Supported export formats for terminal output.
public enum TerminalExportFormat {
    /// Plain UTF-8 text (ANSI escape sequences stripped by the caller).
    case txt
    /// Raw ANSI escape sequence text.
    case ansi
}

/// Pure helpers for the "Save Output..." action.
public enum TerminalExportHelpers {
    /// Returns the file extension string for a given export format.
    /// Used to derive the default filename presented to the user.
    public nonisolated static func fileExtension(for format: TerminalExportFormat) -> String {
        switch format {
        case .txt:  return "txt"
        case .ansi: return "ansi"
        }
    }
}

// MARK: - Copy-on-select decision (pure, non-MainActor, testable)

/// Pure gate for the copy-on-select preference.
public enum TerminalCopyOnSelect {
    /// Returns `true` only when the preference is enabled AND a non-empty
    /// selection exists. Either condition alone must not trigger a copy.
    public nonisolated static func shouldCopy(prefEnabled: Bool, hasSelection: Bool) -> Bool {
        prefEnabled && hasSelection
    }
}

// MARK: - TerminalSurface

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
    private var processAlive = false
    private var exitStatus: Int32?
    private var terminationSignal: Int32?
    private var terminalDeadReason: String?
    private var lastOutputAt: Date?
    private var inputPump: TerminalInputPump?
    private var readSource: DispatchSourceRead?
    private let renderer = ANSIRenderer(
        rows: TerminalViewportGeometry.fallbackSize.rows,
        cols: TerminalViewportGeometry.fallbackSize.cols
    )
    private var terminalSize = TerminalViewportGeometry.fallbackSize
    private var savedSSHPassword: String?
    private var didSendSavedSSHPassword = false
    private var awaitingSSHFirstOutput = false
    private var isVisible = true
    private let historyRepo: TerminalOutputRepository?
    private let outputBus: SurfaceOutputBus
    private let historyWorkspaceID: String
    private let historyQueue = DispatchQueue(label: "rc2.terminal.history", qos: .utility)
    private var pendingHistoryData = Data()
    private var historyFlushScheduled = false
    private var isClosing = false
    private var nextHistoryChunkIndex: Int64 = 1
    private var historyWriteFailures = 0
    private var outputPartial = false
    private var outputPendingBytes = 0
    private var totalOutputBytes = 0
    private var outputBytesAtLastTelemetry = 0
    private var lastOutputTelemetryAt = Date.distantPast
    private var readerAllowsRender = true
    private var isDrainingHiddenBacklog = false
    private var hiddenBacklogDrainGeneration = 0
    private var focusRepairGeneration = 0
    private var busyStatePollActive = false
    private var busyStateProbeUntil = Date.distantPast
    private var lastPublishedBusyState = false
    private var didBeepForDeadInput = false
    private var parkingWindow: NSWindow?
    private var parkingConstraints: [NSLayoutConstraint] = []
    private var needsHistoryReplay = false
    private var restartBannerButton: NSButton?

    /// Bell preferences, configurable by the user. Defaults to silent (no sound,
    /// no flash) so new installs do not produce unexpected audio or visual output.
    public var bellPreferences = BellPreferences()

    /// When `true`, any non-empty mouse selection is automatically copied to the
    /// system pasteboard (copy-on-select). Defaults to `false` so existing
    /// behavior is unchanged; the user must opt in via preferences.
    public var copyOnSelectEnabled: Bool = false

    /// Called on the main actor when the user taps "Restart shell" on the
    /// dead-terminal banner. The caller (AppCommandRouter) replaces this
    /// surface with a fresh one in the same pane and cwd.
    public var onRestartRequested: (() -> Void)?
    private static let hiddenBacklogQuietDelay: TimeInterval = 0.25
    private static let busyStateProbeDuration: TimeInterval = 2.0
    private static let busyStatePollInterval: TimeInterval = 0.25
    private static let outputTelemetryByteInterval = 8 * 1024 * 1024
    private static let outputTelemetryTimeInterval: TimeInterval = 60
    private nonisolated static let maxHistoryChunkBytes = 64 * 1024

    public var viewportSize: TerminalViewportSize {
        terminalSize
    }

    public var isBusy: Bool {
        Self.isTerminalJobBusy(
            processAlive: processAlive,
            shellPID: childPID,
            foregroundProcessGroup: foregroundProcessGroup()
        )
    }

    var ownsTerminalFocusForTesting: Bool {
        view.window?.firstResponder === ghosttyView
    }

    public convenience init(workspaceID: WorkspaceID, cwd: String, title: String = "terminal") throws {
        try self.init(workspaceID: workspaceID, title: title, launch: .shell(cwd: cwd))
    }

    public init(
        workspaceID: WorkspaceID,
        title: String,
        launch: Launch,
        restoredSurfaceID: SurfaceID? = nil,
        historyRepo: TerminalOutputRepository? = nil,
        outputBus: SurfaceOutputBus = .shared
    ) throws {
        self.historyRepo = historyRepo
        self.outputBus = outputBus
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
            id: restoredSurfaceID ?? SurfaceID(),
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
        terminalView.setAccessibilityIdentifier("surface.terminal.view.\(descriptor.id.value.uuidString)")
        self.ghosttyView = terminalView
        let container = TerminalDropContainerView(frame: initialFrame)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.setAccessibilityIdentifier("surface.terminal.\(descriptor.id.value.uuidString)")
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
            needsHistoryReplay = restoredSurfaceID != nil
        }

        terminalView.onInputData = { [weak self] data in
            guard let self else { return }
            let status = self.writeToPTY(data)
            if status == .processExited, !self.didBeepForDeadInput {
                self.didBeepForDeadInput = true
                NSSound.beep()
            }
        }
        // Forward paste-confirmation requests from the Ghostty view to any
        // app-level handler wired on this surface (e.g. AppCommandRouter).
        terminalView.onPasteNeedsConfirm = { [weak self] (text: String) in
            guard let self else { return }
            let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
            let alert = NSAlert()
            alert.messageText = "Paste \(lineCount) lines into the terminal?"
            alert.informativeText = "The pasted text spans multiple lines or contains control characters and will run immediately."
            alert.addButton(withTitle: "Paste")
            alert.addButton(withTitle: "Cancel")
            let onResponse: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
                guard resp == .alertFirstButtonReturn, let data = text.data(using: .utf8) else { return }
                _ = self?.writeToPTY(data)
            }
            if let window = self.ghosttyView.window {
                alert.beginSheetModal(for: window, completionHandler: onResponse)
            } else {
                onResponse(alert.runModal())
            }
        }
        terminalView.onTerminalSizeChange = { [weak self] size in
            guard let self else { return }
            self.applyTerminalSize(size, sendToPTY: self.masterFD >= 0)
        }
        container.onFileDrop = { [weak self] paths in
            guard let data = DroppedFilePaths.terminalInputText(for: paths).data(using: .utf8) else { return }
            _ = self?.writeToPTY(data)
        }
        container.onLayout = { [weak self, weak container] in
            guard let self,
                  !self.isClosing,
                  self.isVisible,
                  container?.window != nil else { return }
            self.ghosttyView.refreshSurfaceOnly()
        }
        container.onWindowChanged = { [weak self] window in
            self?.handleContainerWindowChanged(window)
        }
        applyTerminalSize(TerminalViewportGeometry.fallbackSize, sendToPTY: false, force: true)

        if case .sshPlaceholder = launch {
            appendString("[ssh disconnected]\nSelect a saved SSH host or add a new one to connect.\n")
            terminalDeadReason = "ssh_disconnected"
            publishRuntimeHealth()
            return
        }

        var amaster: Int32 = -1
        let pid = rc2_forkpty(&amaster)
        if pid < 0 {
            appendString("[forkpty failed: \(String(cString: strerror(errno)))]\n")
            terminalDeadReason = "fork_failed"
            terminalLog.error("terminal.spawn_failed surface=\(self.descriptor.id.value.uuidString, privacy: .public) errno=\(errno, privacy: .public)")
            publishRuntimeHealth()
            return
        }
        if pid == 0 {
            _ = chdir(cwd)
            TerminalStartupEnvironment(workspaceID: workspaceID, surfaceID: descriptor.id).applyToCurrentProcess()
            switch launch {
            case .shell:
                let shell = TerminalStartupEnvironment.shellPath()
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
        self.processAlive = true
        self.exitStatus = nil
        self.terminationSignal = nil
        self.terminalDeadReason = nil
        self.lastOutputAt = Date()
        if !TerminalFileDescriptorFlags.enableNonBlocking(amaster) {
            NSLog("RemoteCode terminal failed to enable nonblocking PTY input: %@", String(cString: strerror(errno)))
        }
        configureInputPump(fd: amaster)
        applyTerminalSize(terminalSize, sendToPTY: true, force: true)
        startReader()
        terminalLog.info("terminal.spawned surface=\(self.descriptor.id.value.uuidString, privacy: .public) type=\(self.descriptor.type.rawValue, privacy: .public) pid=\(pid, privacy: .public) rows=\(self.terminalSize.rows, privacy: .public) cols=\(self.terminalSize.cols, privacy: .public)")
        if case .ssh(let profile, _) = launch {
            awaitingSSHFirstOutput = true
            let host = profile.label.isEmpty ? profile.destination : profile.label
            appendString("[connecting to \(host)…]\r\n")
        }
        publishRuntimeHealth()
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
        let fd = masterFD
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        readSource = src
        // The read source owns the fd. It is closed here — on the source's own
        // queue, after the final event handler returns — so the main thread never
        // closes masterFD out from under an in-flight background read() (data race
        // + closed-fd / fd-reuse hazard). close()/handlePTYEOF only cancel().
        src.setCancelHandler { Darwin.close(fd) }
        var buf = [UInt8](repeating: 0, count: 4096)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var output = Data()
            var shouldClose = false

            while true {
                let n = read(fd, &buf, buf.count)
                if n > 0 {
                    output.append(contentsOf: buf[0..<Int(n)])
                    continue
                }
                if n == 0 {
                    shouldClose = true
                    break
                }
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                }
                shouldClose = true
                break
            }

            if !output.isEmpty {
                let data = output
                // Read readerAllowsRender on main (where it is written); sampling it
                // on this background queue is a data race.
                DispatchQueue.main.async { self.appendDataAsync(data, renderAllowedAtRead: self.readerAllowsRender) }
            }
            if shouldClose {
                DispatchQueue.main.async { self.handlePTYEOF() }
            }
        }
        src.resume()
    }

    private func handlePTYEOF() {
        terminalLog.info("terminal.pty_eof surface=\(self.descriptor.id.value.uuidString, privacy: .public) pid=\(self.childPID, privacy: .public)")
        readSource?.cancel()   // cancel handler closes the fd on the source's queue
        readSource = nil
        masterFD = -1
        let status = reapChildIfExited()
        markTerminalDead(reason: "process_exited", exitStatus: status)
    }

    private func reapChildIfExited() -> Int32? {
        guard childPID > 0 else { return exitStatus }
        var status: Int32 = 0
        if waitpid(childPID, &status, WNOHANG) == childPID {
            childPID = -1
            return status
        }
        return nil
    }

    private func appendDataAsync(_ data: Data, renderAllowedAtRead: Bool) {
        guard !isClosing else { return }
        enqueueHistory(data)
        recordOutputTelemetry(bytes: data.count)
        if awaitingSSHFirstOutput {
            awaitingSSHFirstOutput = false
            descriptor.metadata["ssh_status"] = "connected"
        }
        autoSubmitSavedSSHPasswordIfNeeded(from: data)
        lastOutputAt = Date()
        descriptor.hasUnreadActivity = true
        // BEL (0x07): keep activity feedback non-visual. Some long-running CLIs
        // emit repeated bells, and repainting the terminal background reads as
        // pane flicker. Use BellDetector so that 0x07 acting as an OSC string-
        // terminator (e.g. inside ESC ] 0 ; title BEL) does not trigger a false
        // unread-activity dot (UX-TERM-BEL-FALSE-POSITIVE).
        if BellDetector.containsStandaloneBEL(data) { handleBell() }
        // HC-1: stream raw PTY output to the mirror in real time.
        outputBus.emit(descriptor.id, data)
        if renderAllowedAtRead {
            renderer.feed(data)
        }
        if renderAllowedAtRead, renderDiagnostics().canRender {
            ghosttyView.processOutput(data)
        } else {
            outputPendingBytes += data.count
            continueHiddenBacklogDrainIfNeeded()
            ghosttyView.processOutput(data, render: false)
        }
        scheduleBusyStateRefresh()
    }

    private func appendString(_ raw: String) {
        guard let data = raw.data(using: .utf8) else { return }
        enqueueHistory(data)
        recordOutputTelemetry(bytes: data.count)
        renderer.feed(data)
        lastOutputAt = Date()
        outputBus.emit(descriptor.id, data)
        if renderDiagnostics().canRender {
            ghosttyView.processOutput(data)
        } else {
            outputPendingBytes += data.count
            ghosttyView.processOutput(data, render: false)
        }
    }

    private func renderDiagnostics() -> TerminalRenderDiagnostics {
        let window = view.window
        return TerminalRenderDiagnostics(
            logicalVisible: isVisible,
            registryVisible: SurfaceRegistry.shared.isVisible(descriptor.id),
            drainingHiddenBacklog: isDrainingHiddenBacklog,
            windowAttached: window != nil,
            parked: window != nil && window === parkingWindow,
            hasUsableBounds: view.bounds.width > 1 && view.bounds.height > 1,
            hiddenAncestor: Self.isHiddenOrHasHiddenAncestor(view)
        )
    }

    private func handleContainerWindowChanged(_ window: NSWindow?) {
        guard !isClosing else { return }
        if let window, window !== parkingWindow {
            closeParkingWindowIfNeeded()
            if isVisible {
                ghosttyView.refreshSurfaceOnly()
            }
            replayPersistedHistoryIfNeeded()
            return
        }
        guard window == nil else { return }
        scheduleParkingIfDetached()
    }

    /// Joins persisted history chunk payloads into a single contiguous byte
    /// sequence ready for `resetSurfaceOutput`. Pure so it can be unit-tested
    /// without AppKit or a live Ghostty surface.
    nonisolated static func assembleReplayPayload(from chunkData: [Data]) -> Data {
        chunkData.reduce(into: Data()) { $0.append($1) }
    }

    private func replayPersistedHistoryIfNeeded() {
        guard needsHistoryReplay, let historyRepo else { return }
        needsHistoryReplay = false
        let surfaceID = descriptor.id.value.uuidString
        historyQueue.async { [weak self] in
            let window: TerminalOutputWindow?
            do {
                window = try historyRepo.readWindow(surfaceID: surfaceID)
            } catch {
                NSLog("RemoteCode terminal history restore failed surface=%@ error=%@", surfaceID, String(describing: error))
                window = nil
            }
            guard let window, !window.chunks.isEmpty else { return }
            let payload = TerminalSurface.assembleReplayPayload(from: window.chunks.map(\.data))
            guard !payload.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isClosing else { return }
                self.ghosttyView.resetSurfaceOutput(payload)
            }
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
        _ = sendTextStatus(savedSSHPassword + "\n")
    }

    @discardableResult
    private func writeToPTY(_ data: Data) -> TerminalInputStatus {
        guard !data.isEmpty else { return .accepted }
        guard processAlive, masterFD >= 0, terminalDeadReason == nil else { return .processExited }
        guard let inputPump else { return .writeFailed }
        let status = inputPump.enqueue(data)
        if status == .accepted {
            scheduleBusyStateRefresh()
        }
        if status != .accepted {
            terminalLog.error("terminal.input_rejected surface=\(self.descriptor.id.value.uuidString, privacy: .public) status=\(status.rawValue, privacy: .public) pid=\(self.childPID, privacy: .public)")
            publishRuntimeHealth()
        }
        return status
    }

    private func configureInputPump(fd: Int32) {
        let pump = TerminalInputPump(writer: { data, offset in
            data.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return .wrote(0) }
                let n = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if n > 0 { return .wrote(n) }
                if n < 0, errno == EINTR { return .interrupted }
                if n < 0, errno == EAGAIN || errno == EWOULDBLOCK { return .wouldBlock }
                return .failed(errno)
            }
        })
        pump.onTerminalFailure = { [weak self] status in
            DispatchQueue.main.async {
                if let self {
                    terminalLog.error("terminal.input_failed surface=\(self.descriptor.id.value.uuidString, privacy: .public) status=\(status.rawValue, privacy: .public) pid=\(self.childPID, privacy: .public)")
                }
                self?.markTerminalDead(reason: status.rawValue, exitStatus: nil)
            }
        }
        inputPump = pump
    }

    public func sendTextStatus(_ text: String) -> TerminalInputStatus {
        guard let data = text.data(using: .utf8) else { return .writeFailed }
        return writeToPTY(data)
    }

    public func sendText(_ text: String) {
        _ = sendTextStatus(text)
    }

    public func runtimeHealth() -> TerminalRuntimeHealth {
        TerminalRuntimeHealth(
            processAlive: processAlive,
            childPID: childPID > 0 ? childPID : nil,
            exitStatus: exitStatus,
            terminationSignal: terminationSignal,
            ptyOpen: masterFD >= 0,
            inputAccepting: processAlive && terminalDeadReason == nil && (inputPump?.inputAccepting ?? false),
            terminalDeadReason: terminalDeadReason,
            lastOutputAt: lastOutputAt,
            outputPartial: outputPartial,
            outputPendingBytes: outputPendingBytes,
            historyWriteFailures: historyWriteFailures,
            droppedOutputBytes: ghosttyView.droppedOutputBytes,
            rows: terminalSize.rows,
            cols: terminalSize.cols,
            renderDiagnostics: renderDiagnostics()
        )
    }

    static func isTerminalJobBusy(
        processAlive: Bool,
        shellPID: Int32,
        foregroundProcessGroup: Int32?
    ) -> Bool {
        guard processAlive, shellPID > 0, let foregroundProcessGroup else { return false }
        return foregroundProcessGroup != shellPID
    }

    static func shouldContinueBusyStatePolling(isBusy: Bool, now: Date, probeUntil: Date) -> Bool {
        isBusy || now < probeUntil
    }

    private func foregroundProcessGroup() -> Int32? {
        guard masterFD >= 0 else { return nil }
        let group = tcgetpgrp(masterFD)
        return group > 0 ? group : nil
    }

    public func readTextSnapshot() -> TerminalTextSnapshot {
        if !isVisible && outputPendingBytes > 0 {
            return TerminalTextSnapshot(
                text: renderer.snapshot().string,
                ansiText: renderer.ansiSnapshot(includeScrollback: true),
                complete: false,
                source: "ansi_fallback",
                timestamp: Date(),
                partialReason: outputPartial ? "hidden_output_cap" : "hidden_output_pending",
                pendingBytes: outputPendingBytes,
                rows: terminalSize.rows,
                cols: terminalSize.cols,
                renderDiagnostics: renderDiagnostics()
            )
        }
        let diagnostics = renderDiagnostics()
        if let text = ghosttyView.readViewportText() {
            let rendererText = renderer.snapshot().string
            let complete = diagnostics.canRender && Self.readTextComplete(
                outputPartial: outputPartial,
                outputPendingBytes: outputPendingBytes,
                historyWriteFailures: historyWriteFailures
            )
            let partialReason = Self.readTextPartialReason(
                outputPartial: outputPartial,
                outputPendingBytes: outputPendingBytes,
                historyWriteFailures: historyWriteFailures,
                renderBlockedReason: diagnostics.blockedReason
            )
            if Self.shouldPreferRendererSnapshotForReadText(viewportText: text, rendererText: rendererText) {
                return TerminalTextSnapshot(
                    text: rendererText,
                    ansiText: renderer.ansiSnapshot(includeScrollback: true),
                    complete: complete,
                    source: "ansi_renderer",
                    timestamp: Date(),
                    partialReason: partialReason,
                    pendingBytes: outputPendingBytes,
                    rows: terminalSize.rows,
                    cols: terminalSize.cols,
                    renderDiagnostics: diagnostics
                )
            }
            return TerminalTextSnapshot(
                text: text,
                ansiText: renderer.ansiSnapshot(matchingVisibleText: text),
                complete: complete,
                source: "ghostty_viewport",
                timestamp: Date(),
                partialReason: partialReason,
                pendingBytes: outputPendingBytes,
                rows: terminalSize.rows,
                cols: terminalSize.cols,
                renderDiagnostics: diagnostics
            )
        }
        return TerminalTextSnapshot(
            text: renderer.snapshot().string,
            ansiText: renderer.ansiSnapshot(includeScrollback: true),
            complete: false,
            source: "ansi_fallback",
            timestamp: Date(),
            partialReason: "ghostty_unavailable",
            pendingBytes: outputPendingBytes,
            rows: terminalSize.rows,
            cols: terminalSize.cols,
            renderDiagnostics: diagnostics
        )
    }

    static func readTextComplete(outputPartial: Bool, outputPendingBytes: Int, historyWriteFailures: Int) -> Bool {
        !outputPartial && outputPendingBytes == 0 && historyWriteFailures == 0
    }

    static func readTextPartialReason(outputPartial: Bool, outputPendingBytes: Int, historyWriteFailures: Int, renderBlockedReason: String? = nil) -> String? {
        if outputPartial { return "hidden_output_cap" }
        if outputPendingBytes > 0 { return "hidden_output_pending" }
        if historyWriteFailures > 0 { return "history_persistence_failed" }
        if let renderBlockedReason { return renderBlockedReason }
        return nil
    }

    private func publishRuntimeHealth() {
        SurfaceRuntimeBus.shared.emit(descriptor.id, runtimeHealth())
    }

    private func scheduleBusyStateRefresh() {
        busyStateProbeUntil = max(busyStateProbeUntil, Date().addingTimeInterval(Self.busyStateProbeDuration))
        guard !busyStatePollActive else { return }
        busyStatePollActive = true
        pollBusyState()
    }

    private func pollBusyState() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.busyStatePollInterval) { [weak self] in
            guard let self, !self.isClosing else { return }
            let busy = self.isBusy
            if busy != self.lastPublishedBusyState {
                self.lastPublishedBusyState = busy
                self.publishRuntimeHealth()
            }
            let now = Date()
            guard Self.shouldContinueBusyStatePolling(
                isBusy: busy,
                now: now,
                probeUntil: self.busyStateProbeUntil
            ) else {
                self.busyStatePollActive = false
                return
            }
            self.pollBusyState()
        }
    }

    private func recordOutputTelemetry(bytes: Int) {
        guard bytes > 0 else { return }
        totalOutputBytes += bytes
        let now = Date()
        let byteDelta = totalOutputBytes - outputBytesAtLastTelemetry
        guard byteDelta >= Self.outputTelemetryByteInterval ||
                now.timeIntervalSince(lastOutputTelemetryAt) >= Self.outputTelemetryTimeInterval else { return }
        outputBytesAtLastTelemetry = totalOutputBytes
        lastOutputTelemetryAt = now
        let diagnostics = renderDiagnostics()
        terminalLog.info("terminal.output_health surface=\(self.descriptor.id.value.uuidString, privacy: .public) pid=\(self.childPID, privacy: .public) totalBytes=\(self.totalOutputBytes, privacy: .public) pendingBytes=\(self.outputPendingBytes, privacy: .public) droppedBytes=\(self.ghosttyView.droppedOutputBytes, privacy: .public) historyFailures=\(self.historyWriteFailures, privacy: .public) canRender=\(diagnostics.canRender, privacy: .public) blocked=\(diagnostics.blockedReason ?? "none", privacy: .public)")
    }

    func handleBell() {
        let fx = BellHandler.effects(prefs: bellPreferences)
        if fx.dot { descriptor.hasUnreadActivity = true }
        if fx.playSound { NSSound.beep() }
        if fx.flash { flashTerminalView() }
    }

    /// Applies a brief white-flash overlay on the terminal container view to
    /// provide a visual bell. The flash is implemented as a CABasicAnimation on
    /// the container layer so it is non-blocking and does not interfere with
    /// terminal rendering.
    private func flashTerminalView() {
        guard let layer = view.layer else { return }
        let flash = CALayer()
        flash.frame = layer.bounds
        flash.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
        flash.opacity = 0
        layer.addSublayer(flash)
        CATransaction.begin()
        CATransaction.setCompletionBlock { flash.removeFromSuperlayer() }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.35
        anim.toValue = 0
        anim.duration = 0.15
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flash.opacity = 0
        flash.add(anim, forKey: "bell_flash")
        CATransaction.commit()
    }

    private func markTerminalDead(reason: String, exitStatus: Int32?) {
        guard processAlive || terminalDeadReason == nil else { return }
        let wasAlive = processAlive
        processAlive = false
        self.exitStatus = exitStatus ?? self.exitStatus
        if let rawStatus = self.exitStatus, (rawStatus & 0x7F) != 0 {
            terminationSignal = rawStatus & 0x7F
        }
        terminalDeadReason = reason
        inputPump?.stop(reason: .processExited)
        terminalLog.info("terminal.dead surface=\(self.descriptor.id.value.uuidString, privacy: .public) reason=\(reason, privacy: .public) rawStatus=\(self.exitStatus ?? -1, privacy: .public) signal=\(self.terminationSignal ?? -1, privacy: .public) totalBytes=\(self.totalOutputBytes, privacy: .public) pendingBytes=\(self.outputPendingBytes, privacy: .public) droppedBytes=\(self.ghosttyView.droppedOutputBytes, privacy: .public) historyFailures=\(self.historyWriteFailures, privacy: .public)")
        if wasAlive, !isClosing {
            appendString("\r\n" + Self.processExitedBanner(rawStatus: exitStatus) + "\r\n")
            showRestartBannerIfEligible()
        }
        publishRuntimeHealth()
    }

    private static func processExitedBanner(rawStatus: Int32?) -> String {
        guard let rawStatus else { return "[process exited]" }
        if (rawStatus & 0x7F) != 0 {
            return "[process terminated (signal \(rawStatus & 0x7F))]"
        }
        return "[process exited (code \((rawStatus >> 8) & 0xFF))]"
    }

    // MARK: - Restart shell banner button

    private func showRestartBannerIfEligible() {
        // Only local shell terminals can be restarted inline; SSH has its own
        // reconnect flow. Also skip if the caller hasn't wired onRestartRequested
        // (e.g. unit-test stubs that don't go through AppCommandRouter).
        guard TerminalRestartDecision.spawnRequest(from: descriptor) != nil,
              onRestartRequested != nil,
              restartBannerButton == nil else { return }

        let btn = NSButton()
        btn.title = "Restart shell"
        btn.bezelStyle = .rounded
        btn.isBordered = true
        btn.target = self
        btn.action = #selector(restartBannerTapped)
        btn.setAccessibilityIdentifier("terminal.restart-shell-button")
        btn.setAccessibilityLabel("Restart shell")
        btn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            btn.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        ])
        restartBannerButton = btn
    }

    @objc private func restartBannerTapped() {
        onRestartRequested?()
    }

    private func removeRestartBanner() {
        restartBannerButton?.removeFromSuperview()
        restartBannerButton = nil
    }

    public func readText() -> String {
        readTextSnapshot().text
    }

    static func shouldPreferRendererSnapshotForReadText(viewportText: String, rendererText: String) -> Bool {
        guard rendererText.contains(where: { $0.isNewline }),
              rendererText.count > viewportText.count else { return false }
        return visibleLineCount(viewportText) <= 1
    }

    private static func visibleLineCount(_ text: String) -> Int {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }

    public func focus() {
        // Explicit user request: allowed to take focus from a field editor.
        repairTerminalFocus(reason: "surface_focus", force: true)
    }

    public func repairTerminalFocus(reason: String, force: Bool = false) {
        focusRepairGeneration &+= 1
        let generation = focusRepairGeneration
        guard !applyFocusIfReady(force: force) else { return }
        scheduleFocusRetry(generation: generation, delay: nil, force: force)
        scheduleFocusRetry(generation: generation, delay: 0.05, force: force)
    }

    @discardableResult
    private func applyFocusIfReady(force: Bool = false) -> Bool {
        guard isVisible,
              !isClosing,
              let window = view.window,
              window !== parkingWindow,
              view.bounds.width > 1,
              view.bounds.height > 1,
              !Self.isHiddenOrHasHiddenAncestor(view),
              window.attachedSheet == nil,
              force || !Self.anotherResponderIsEditing(in: window, terminalView: ghosttyView) else { return false }
        window.makeFirstResponder(ghosttyView)
        ghosttyView.refreshSurfaceOnly()
        descriptor.hasUnreadActivity = false
        return true
    }

    /// Don't yank focus back to the terminal if the user is actively editing
    /// another control in the same window (e.g. a sidebar text field). A field
    /// editor (`NSText`) or text view that is the current first responder and
    /// isn't our own terminal view means focus is intentionally elsewhere
    /// (UX-011).
    private static func anotherResponderIsEditing(in window: NSWindow, terminalView: NSView) -> Bool {
        guard let responder = window.firstResponder else { return false }
        guard responder !== terminalView else { return false }
        if let text = responder as? NSText {
            // The shared field editor's delegate is the control being edited.
            if let edited = text.delegate as? NSView, edited === terminalView { return false }
            return true
        }
        if let textView = responder as? NSTextView, textView !== terminalView {
            return true
        }
        return false
    }

    private static func isHiddenOrHasHiddenAncestor(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let node = current {
            if node.isHidden { return true }
            current = node.superview
        }
        return false
    }

    private func scheduleFocusRetry(generation: Int, delay: TimeInterval?, force: Bool) {
        let attempt = { [weak self] in
            guard let self else { return }
            guard self.focusRepairGeneration == generation else { return }
            _ = self.applyFocusIfReady(force: force)
        }
        if let delay {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: attempt)
        } else {
            DispatchQueue.main.async(execute: attempt)
        }
    }

    public func unfocus() {}

    public func didBecomeVisible() {
        guard !isVisible else { return }
        isVisible = true
        readerAllowsRender = true
        ghosttyView.setOcclusion(visible: true)
        let hadHiddenOutput = outputPendingBytes > 0
        outputPendingBytes = 0
        if hadHiddenOutput {
            beginHiddenBacklogDrain()
        }
        // Paint the latest frame synchronously on reveal so a busy terminal
        // shows its current state immediately instead of a stale/partial frame
        // for the quiet-delay window; the drain timer now only settles the
        // pending/partial flags, it no longer gates the visible refresh
        // (UX-013).
        ghosttyView.forceRefresh()
        scheduleVisibleRefresh()
    }

    private func scheduleVisibleRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.isClosing else { return }
            self.ghosttyView.refreshSurfaceOnly()
        }
    }

    public func didBecomeHidden() {
        guard isVisible else { return }
        isVisible = false
        readerAllowsRender = false
        isDrainingHiddenBacklog = false
        ghosttyView.setOcclusion(visible: false)
        scheduleParkingIfDetached()
    }

    private func beginHiddenBacklogDrain() {
        isDrainingHiddenBacklog = true
        hiddenBacklogDrainGeneration &+= 1
        scheduleHiddenBacklogDrainCompletion(generation: hiddenBacklogDrainGeneration)
    }

    private func continueHiddenBacklogDrainIfNeeded() {
        guard isDrainingHiddenBacklog else { return }
        hiddenBacklogDrainGeneration &+= 1
        scheduleHiddenBacklogDrainCompletion(generation: hiddenBacklogDrainGeneration)
    }

    private func scheduleHiddenBacklogDrainCompletion(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hiddenBacklogQuietDelay) { [weak self] in
            guard let self,
                  self.hiddenBacklogDrainGeneration == generation,
                  self.isVisible,
                  !self.isClosing else { return }
            self.isDrainingHiddenBacklog = false
            self.outputPendingBytes = 0
            self.ghosttyView.refreshSurfaceOnly()
        }
    }

    public func close() {
        guard !isClosing else { return }
        isClosing = true
        removeRestartBanner()
        closeParkingWindowIfNeeded()
        flushHistory(wait: true)
        readSource?.cancel()
        readSource = nil
        inputPump?.stop(reason: .processExited)
        if childPID > 0 {
            let pid = childPID
            childPID = -1
            processAlive = false
            terminalDeadReason = terminalDeadReason ?? "closed"
            terminalLog.info("terminal.close surface=\(self.descriptor.id.value.uuidString, privacy: .public) pid=\(pid, privacy: .public)")
            kill(pid, SIGHUP)
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                _ = waitpid(pid, &status, 0)
            }
        }
        // fd is closed by the read source's cancel handler (see startReader),
        // after the last in-flight read completes — not directly on main.
        masterFD = -1
        ghosttyView.closeSurface()
        publishRuntimeHealth()
    }

    private func scheduleParkingIfDetached() {
        guard parkingWindow == nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.parkInHiddenWindowIfNeeded()
        }
    }

    private func parkInHiddenWindowIfNeeded() {
        guard !isClosing,
              !isVisible,
              view.window == nil else { return }

        let frame = NSRect(x: 0, y: 0, width: max(view.bounds.width, 800), height: max(view.bounds.height, 600))
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.isExcludedFromWindowsMenu = true

        let content = NSView(frame: frame)
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content

        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        parkingConstraints = [
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ]
        NSLayoutConstraint.activate(parkingConstraints)
        parkingWindow = window
    }

    private func closeParkingWindowIfNeeded() {
        guard let window = parkingWindow else { return }
        NSLayoutConstraint.deactivate(parkingConstraints)
        parkingConstraints.removeAll()
        parkingWindow = nil
        if view.window === window {
            view.removeFromSuperview()
        }
        window.contentView = nil
        window.close()
    }

    public func flushPersistedHistory() {
        flushHistory(wait: true)
    }

    private func enqueueHistory(_ data: Data) {
        guard !isClosing, historyRepo != nil, !data.isEmpty else { return }
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
        guard let historyRepo, !pendingHistoryData.isEmpty else {
            if wait {
                historyQueue.sync {}
            }
            return
        }
        // Hand ownership of the accumulated buffer to the write item instead of
        // copying it out and clearing in place: with copy-on-write, reassigning
        // a fresh empty Data lets the write item keep the only reference, so the
        // >64KB burst is moved rather than duplicated (PERF-007).
        let data = pendingHistoryData
        pendingHistoryData = Data()
        let surfaceID = descriptor.id.value.uuidString
        let workspaceID = historyWorkspaceID
        let chunkIndex = nextHistoryChunkIndex
        nextHistoryChunkIndex += 1
        let write = DispatchWorkItem {
            do {
                try historyRepo.append(surfaceID: surfaceID, workspaceID: workspaceID, chunkIndex: chunkIndex, data: data)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.historyWriteFailures += 1
                    self?.outputPartial = true
                    self?.publishRuntimeHealth()
                }
                NSLog("RemoteCode terminal history write failed surface=%@ chunk=%lld error=%@", surfaceID, chunkIndex, String(describing: error))
            }
        }
        if wait {
            historyQueue.sync(execute: write)
        } else {
            historyQueue.async(execute: write)
        }
    }

    /// Exports the full scrollback (including ANSI sequences when format is
    /// `.ansi`, or raw text when format is `.txt`) to `url`.
    /// The caller is responsible for presenting the NSSavePanel and providing
    /// the destination URL.
    public func saveOutput(format: TerminalExportFormat, to url: URL) throws {
        let content: String
        switch format {
        case .ansi:
            content = renderer.ansiSnapshot(includeScrollback: true)
        case .txt:
            content = renderer.snapshot().string
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    public func snapshot() -> [String: String] {
        ["cwd": descriptor.metadata["cwd"] ?? "", "scrollback_chars": String(readText().count)]
    }
}
