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
    public enum PlainTextDropDecision: Equatable {
        case send(String)
        case confirm(String)
        case reject
    }

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

    public nonisolated static func plainTextDropDecision(
        from pasteboard: NSPasteboard,
        confirmationAvailable: Bool
    ) -> PlainTextDropDecision {
        guard let text = plainText(from: pasteboard), !text.isEmpty else { return .reject }
        if let safe = safeTextToSend(text) { return .send(safe) }
        return confirmationAvailable ? .confirm(text) : .reject
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

    public static func confirmationLineCount(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = 1
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0D:
                count += 1
                previousWasCR = true
            case 0x0A:
                if !previousWasCR { count += 1 }
                previousWasCR = false
            default:
                previousWasCR = false
            }
        }
        return count
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

private final class TerminalReaderMainHandoffHook: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    func set(_ action: (@Sendable () -> Void)?) {
        lock.lock()
        self.action = action
        lock.unlock()
    }

    func fire() {
        lock.lock()
        let action = action
        lock.unlock()
        action?()
    }
}

private final class TerminalReaderWillPublishHook: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable (Data) -> Void)?

    func set(_ action: (@Sendable (Data) -> Void)?) {
        lock.lock()
        self.action = action
        lock.unlock()
    }

    func fire(_ data: Data) {
        lock.lock()
        let action = action
        lock.unlock()
        action?(data)
    }
}

/// PTY-backed shell surface. Spawns the user's shell via `forkpty(3)`
/// and renders its output through `ANSIRenderer`. The terminal view is
/// directly interactive — no separate input field (cmux model).
@MainActor
public final class TerminalSurface: NSObject, Surface, TerminalHistoryCoordinatorDelegate {
    public enum Launch {
        case shell(cwd: String)
        case ssh(profile: SSHHostProfile, cwd: String)
        case sshPlaceholder(cwd: String)
    }

    /// Includes disposition work whose immediate owner no longer has a surface
    /// (for example, PTY preparation that failed after fork). App termination
    /// waits this registry in addition to registered surface barriers.
    public static func activeProcessDispositionBarrier() -> SurfaceTerminationBarrier? {
        let works = TerminalPTYProcessRuntime.activeApplicationTerminationWorksSnapshot()
        guard !works.isEmpty else { return nil }
        return SurfaceTerminationBarrier(
            groups: works.map(\.group),
            completionChecks: works.map(\.succeeded)
        )
    }

    public static func pendingHistoryDeleteBarrier() -> SurfaceTerminationBarrier? {
        TerminalHistoryCoordinator.pendingFinalDeleteBarrier()
    }

    /// Rehydrates metadata-only final-delete tombstones at process launch.
    /// The registry owns repository/ID state only; no Surface is retained.
    @discardableResult
    public static func replayPendingHistoryDeletes(
        repository: TerminalOutputRepository
    ) -> SurfaceTerminationBarrier? {
        TerminalHistoryCoordinator.replayPendingFinalDeletes(repository: repository)
    }

    /// Starts an unconditional history delete for wrappers that no longer own
    /// a TerminalSurface. The global registry keeps only repository/ID state so
    /// a failed cleanup remains retryable without retaining the closed wrapper.
    @discardableResult
    public static func scheduleOwnerlessHistoryDelete(
        repository: TerminalOutputRepository,
        surfaceID: String
    ) -> SurfaceTerminationBarrier {
        TerminalHistoryCoordinator.scheduleOwnerlessFinalDelete(
            repository: repository,
            surfaceID: surfaceID
        )
    }

    /// Clears a reusable stable-ID terminal without granting an old runtime an
    /// unconditional final-delete right over a future writer generation.
    @discardableResult
    public static func scheduleOwnerlessHistoryClearForReuse(
        repository: TerminalOutputRepository,
        surfaceID: String
    ) -> SurfaceTerminationBarrier {
        TerminalHistoryCoordinator.scheduleOwnerlessClearForReuse(
            repository: repository,
            surfaceID: surfaceID
        )
    }

    public private(set) var descriptor: SurfaceDescriptor
    public let view: NSView
    private let ghosttyView: GhosttyTerminalView
    private var masterFD: Int32 = -1
    private var masterFDLease: TerminalFileDescriptorLease?
    private var childPID: pid_t = -1
    private var childReapInFlightPID: pid_t?
    private var childReapForegroundGroup: TerminalPTYProcessRuntime.CapturedForegroundProcessGroup?
    private var lastCapturedForegroundGroup: TerminalPTYProcessRuntime.CapturedForegroundProcessGroup?
    private var processAlive = false
    private var exitStatus: Int32?
    private var terminationSignal: Int32?
    private var terminalDeadReason: String?
    private var didAppendProcessExitedBanner = false
    private var lastOutputAt: Date?
    private var inputPump: TerminalInputPump?
    private var readSource: DispatchSourceRead?
    private var applicationTerminationBarrier: SurfaceTerminationBarrier?
    private var runtimeRestartRequiredHistoryBarrier: SurfaceTerminationBarrier?
    private var runtimeDispositionBarrierFactoryForTesting:
        ((pid_t) -> SurfaceTerminationBarrier)?
    private let readerWillPublishHook = TerminalReaderWillPublishHook()
    private let readerMainHandoffHook = TerminalReaderMainHandoffHook()
    private let readerHandoffState = TerminalReaderHandoffState()
    private let childReapCompletionHook = TerminalReaderMainHandoffHook()
    private var processTreeSignalCountForTesting = 0
    private var publishesRuntimeHealth = true
    private var renderer = ANSIRenderer(
        rows: TerminalViewportGeometry.fallbackSize.rows,
        cols: TerminalViewportGeometry.fallbackSize.cols
    )
    private var terminalSize = TerminalViewportGeometry.fallbackSize
    private var savedSSHPassword: String?
    private var didSendSavedSSHPassword = false
    private var passwordPromptCount = 0
    private var awaitingSSHFirstOutput = false
    private var isVisible = false
    private let historyCoordinator: TerminalHistoryCoordinator
    private let outputBus: SurfaceOutputBus
    private var isClosing = false
    private var outputPartial = false
    private var outputPartialReason: String?
    private var outputPendingBytes = 0
    // Raw bytes received while the renderer was suppressed (isVisible=false).
    // Replayed into renderer.feed on didBecomeVisible so the ANSI snapshot is
    // complete even if the surface was never rendered while hidden.
    private var hiddenRendererBuffer = Data()
    private var hiddenRendererBufferOverflowed = false
    private var totalOutputBytes = 0
    private var outputBytesAtLastTelemetry = 0
    private var maxPTYReadBatchBytesObserved = 0
    private var maxPTYReadCallsObserved = 0
    private var lastOutputTelemetryAt = Date.distantPast
    private var readerAllowsRender = false
    /// Set while a deferred audit-#3 stuck-hidden self-heal is pending, so output
    /// arriving every few ms during the desync doesn't schedule (or log) it repeatedly.
    private var stuckHiddenHealScheduled = false
    private var isDrainingHiddenBacklog = false
    private var hiddenBacklogDrainGeneration = 0
    /// Absolute deadline after which the hidden-backlog drain stops re-arming and
    /// force-completes, so a continuous stream can't latch canRender false (#5).
    private var hiddenBacklogDrainDeadline: Date?
    private var focusRepairGeneration = 0
    private var busyStatePollActive = false
    private var busyStateProbeUntil = Date.distantPast
    private var lastPublishedBusyState = false
    private var didBeepForDeadInput = false
    // MARK: - readTextSnapshot cache
    // Tracks how many times TerminalSurface has mutated the ANSIRenderer (via
    // renderer.feed / renderer.resize). Used as the renderer-side key for the
    // readTextSnapshot cache so we do not have to reach into ANSIRenderer's
    // private contentVersion.
    private var rendererMutationCount: UInt64 = 0
    // MARK: - Lazy mirror-renderer feeding (PERF-136)
    // The ANSIRenderer (`renderer`) exists ONLY to produce the mirror snapshot
    // (readTextSnapshot / saveOutput). On the VISIBLE hot path we used to feed it
    // byte-by-byte on the main thread for every output chunk, in addition to
    // feeding the ghostty display — a full double-emulation that dominated CPU
    // during high-rate output (`yes`, build logs).
    //
    // Instead we now RECORD visible feed/resize operations into an ordered pending
    // buffer and replay them into `renderer` only when a snapshot is actually read
    // (ensureRendererCurrent). The renderer's state is observable ONLY via snapshot
    // reads, and every read flushes the buffer first, so the deferral is
    // unobservable: the replayed sequence is byte-identical to eager feeding BY
    // CONSTRUCTION (same feed/resize ops, same order). `rendererMutationCount`
    // still advances on every BUFFERED event so cached snapshots invalidate
    // correctly while pending work exists.
    enum PendingRendererEvent {
        case bytes(Data)
        case resize(rows: Int, cols: Int)
    }
    static let maxPendingRendererEvents = 4_096
    private var pendingRendererEvents: [PendingRendererEvent] = []
    private var pendingRendererByteCount = 0

    static func pendingRendererBufferExceeded(byteCount: Int, eventCount: Int) -> Bool {
        byteCount > maxHiddenRendererBufferBytes || eventCount > maxPendingRendererEvents
    }

    /// Replays recorded renderer events into `target` in order. This is the SAME
    /// code path the production flush (`ensureRendererCurrent`) uses, exposed as a
    /// pure static seam so the equivalence test drives identical logic.
    static func replay(_ events: [PendingRendererEvent], into target: ANSIRenderer) {
        for event in events {
            switch event {
            case .bytes(let data):
                target.feed(data)
            case .resize(let rows, let cols):
                target.resize(rows: rows, cols: cols)
            }
        }
    }

    /// Flushes all pending renderer events into `renderer`, then clears the buffer.
    /// Idempotent: a no-op when nothing is pending. MUST be called at the top of
    /// every renderer-read site so the snapshot reflects all deferred events.
    private func ensureRendererCurrent() {
        guard !pendingRendererEvents.isEmpty else { return }
        Self.replay(pendingRendererEvents, into: renderer)
        pendingRendererEvents.removeAll(keepingCapacity: true)
        pendingRendererByteCount = 0
    }
    // Cached result of readTextSnapshot(). Invalidated when either the renderer
    // mutation count or the ghostty viewport text changes (see snapshotCacheValid).
    private var cachedTextSnapshot: (rendererVersion: UInt64, viewportText: String?, stateSignature: String, value: TerminalTextSnapshot)?
    private var parkingWindow: NSWindow?
    private var parkingConstraints: [NSLayoutConstraint] = []
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
    /// Called after Ghostty accepts a new OSC terminal title.
    public var onTitleChange: ((String) -> Void)?
    private static let hiddenBacklogQuietDelay: TimeInterval = 0.25
    /// Absolute cap on how long the hidden-backlog drain may keep re-arming before it
    /// force-completes, even under a never-quiet stream (#5). Bounds the frozen frame.
    private static let hiddenBacklogMaxDrainWindow: TimeInterval = 1.0
    private static let busyStateProbeDuration: TimeInterval = 2.0
    private static let busyStatePollInterval: TimeInterval = 0.25
    private static let outputTelemetryByteInterval = 8 * 1024 * 1024
    private static let outputTelemetryTimeInterval: TimeInterval = 60
    private nonisolated static let maxPTYReadEventBytes = 256 * 1024
    private nonisolated static let maxPTYReadCallsPerEvent = 64
    // Maximum bytes buffered for hidden-renderer heal. Chosen large enough to
    // cover realistic hidden bursts (build output, long completions) while
    // bounding memory. Bytes beyond this cap are NOT fed to the renderer on
    // reveal; the snapshot will be partial (complete=false) but never OOM.
    private static let maxHiddenRendererBufferBytes = 4 * 1024 * 1024

    public var viewportSize: TerminalViewportSize {
        terminalSize
    }

    public var isBusy: Bool {
        let foregroundProcessGroup = foregroundProcessGroup()
        guard Self.isTerminalJobBusy(
            processAlive: processAlive,
            shellPID: childPID,
            foregroundProcessGroup: foregroundProcessGroup
        ), let capturedForegroundGroup = lastCapturedForegroundGroup else {
            return false
        }
        return capturedForegroundGroup.pgid == foregroundProcessGroup
            && capturedForegroundGroup.sessionID == childPID
    }

    var ownsTerminalFocusForTesting: Bool {
        view.window?.firstResponder === ghosttyView
    }

    private var historyOutstandingBytes: Int {
        historyCoordinator.outstandingBytes
    }

    private var historyWriteFailures: Int {
        historyCoordinator.writeFailures
    }

    var historyOutstandingBytesForTesting: Int {
        historyCoordinator.outstandingBytes
    }

    var ptyReadDiagnosticsForTesting: (maxBatchBytes: Int, maxReadCalls: Int) {
        (maxPTYReadBatchBytesObserved, maxPTYReadCallsObserved)
    }

    var foregroundProcessGroupForTesting: pid_t? {
        foregroundProcessGroup()
    }

    var capturedForegroundProcessGroupForTesting: TerminalPTYProcessRuntime.CapturedForegroundProcessGroup? {
        lastCapturedForegroundGroup
    }

    var historyReplayInFlightForTesting: Bool {
        historyCoordinator.replayInFlight
    }

    var historyPreparationStateForTesting: TerminalHistoryCoordinator.PreparationState {
        historyCoordinator.preparationStateForTesting
    }

    var historyLiveClearInFlightForTesting: Bool {
        historyCoordinator.liveClearInFlightForTesting
    }

    var historyWriterGenerationForTesting: String? {
        historyCoordinator.writerGenerationForTesting
    }

    var terminalDeadReasonForTesting: String? { terminalDeadReason }
    var inputPumpConfiguredForTesting: Bool { inputPump != nil }
    func drainInputPumpForTesting() { inputPump?.drain() }
    var readerConfiguredForTesting: Bool { readSource != nil }
    var childPIDForTesting: pid_t { childPID }
    var masterFDForTesting: Int32 { masterFD }
    var processTreeSignalCountForTestingValue: Int { processTreeSignalCountForTesting }

    var readerAllowsRenderForTesting: Bool {
        readerAllowsRender
    }

    /// Inject bytes on the live PTY reader path so tests can exercise hidden
    /// `hiddenRendererBuffer` / pending accounting without `forkpty` (sandbox).
    func injectReaderOutputForTesting(_ data: Data) {
        appendDataAsync(data, renderAllowedAtRead: readerAllowsRender)
    }

    func setReaderWillEnterMainHandoffForTesting(_ action: (@Sendable () -> Void)?) {
        readerMainHandoffHook.set(action)
    }

    func setReaderWillPublishForTesting(_ action: (@Sendable (Data) -> Void)?) {
        readerWillPublishHook.set(action)
    }

    func setBeforeLiveHistoryClearForTesting(_ action: (@Sendable () -> Void)?) {
        historyCoordinator.beforeLiveClearForTesting = action
    }

    func setChildReapCompletionForTesting(_ action: (@Sendable () -> Void)?) {
        childReapCompletionHook.set(action)
    }

    func beginChildReapForTesting(pid: pid_t, sendInitialHangup: Bool) {
        beginBoundedChildReap(
            pid: pid,
            foregroundPGID: nil,
            sendInitialHangup: sendInitialHangup
        )
    }

    func setRuntimeDispositionBarrierFactoryForTesting(
        _ factory: ((pid_t) -> SurfaceTerminationBarrier)?
    ) {
        runtimeDispositionBarrierFactoryForTesting = factory
    }

    var ghosttyScrollbackTextForTesting: String? {
        ghosttyView.readScrollbackText()
    }

    public convenience init(workspaceID: WorkspaceID, cwd: String, title: String = "terminal") throws {
        try self.init(workspaceID: workspaceID, title: title, launch: .shell(cwd: cwd))
    }

    nonisolated static func shouldYieldPTYReadEvent(
        bytesRead: Int,
        readCalls: Int,
        maxBytes: Int,
        maxReadCalls: Int
    ) -> Bool {
        bytesRead >= maxBytes || readCalls >= maxReadCalls
    }

    nonisolated static func shouldAcceptHistoryBacklog(
        queuedBytes: Int,
        incomingBytes: Int,
        maxQueuedBytes: Int
    ) -> Bool {
        TerminalHistoryCoordinator.shouldAcceptBacklog(
            queuedBytes: queuedBytes,
            incomingBytes: incomingBytes,
            maxQueuedBytes: maxQueuedBytes
        )
    }

    private nonisolated static func spawnPTY(
        cwd: String,
        launch: Launch,
        workspaceID: WorkspaceID,
        surfaceID: SurfaceID,
        suspendedBeforeExec: Bool = false
    ) -> (pid: pid_t, masterFD: Int32) {
        let parent = ProcessInfo.processInfo.environment
        let executable: String
        let arguments: [String]
        switch launch {
        case .shell:
            executable = TerminalStartupEnvironment.shellPath(from: parent)
            arguments = ["-" + (executable as NSString).lastPathComponent]
        case .ssh(let profile, _):
            executable = "/usr/bin/ssh"
            arguments = ["ssh"] + SSHCommandBuilder.sshArguments(for: profile)
        case .sshPlaceholder:
            executable = "/usr/bin/false"
            arguments = ["false"]
        }
        let environment = TerminalStartupEnvironment(
            parent: parent,
            workspaceID: workspaceID,
            surfaceID: surfaceID
        ).mergedEnvironment(parent: parent)
        return TerminalPTYProcessRuntime.spawn(
            cwd: cwd,
            executable: executable,
            arguments: arguments,
            environment: environment,
            suspendedBeforeExec: suspendedBeforeExec
        )
    }

    /// Spawns and configures the replacement PTY while the current terminal is
    /// still interactive. No reader/history/output path starts until the owner
    /// consumes this runtime after crossing the restart teardown boundary.
    public static func prepareShellRuntimeForRestart(
        workspaceID: WorkspaceID,
        cwd: String,
        surfaceID: SurfaceID,
        closeOnExecEnabler: ((Int32) -> Bool)? = nil,
        nonBlockingEnabler: ((Int32) -> Bool)? = nil,
        onFailureCleanup: ((pid_t, SurfaceTerminationBarrier) -> Void)? = nil
    ) -> TerminalPreparedPTYRuntime? {
        prepareRuntimeForReplacement(
            workspaceID: workspaceID,
            cwd: cwd,
            launch: .shell(cwd: cwd),
            surfaceID: surfaceID,
            closeOnExecEnabler: closeOnExecEnabler,
            nonBlockingEnabler: nonBlockingEnabler,
            onFailureCleanup: onFailureCleanup
        )
    }

    public static func prepareRuntimeForReplacement(
        workspaceID: WorkspaceID,
        cwd: String,
        launch: Launch,
        surfaceID: SurfaceID,
        closeOnExecEnabler: ((Int32) -> Bool)? = nil,
        nonBlockingEnabler: ((Int32) -> Bool)? = nil,
        onFailureCleanup: ((pid_t, SurfaceTerminationBarrier) -> Void)? = nil
    ) -> TerminalPreparedPTYRuntime? {
        let suspendedBeforeExec: Bool
        if case .sshPlaceholder = launch {
            // The immediate-exit fixture remains unsuspended so the production
            // pre-attach liveness gate keeps covering an exited prepared child.
            suspendedBeforeExec = false
        } else {
            suspendedBeforeExec = true
        }
        let spawn = spawnPTY(
            cwd: cwd,
            launch: launch,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            suspendedBeforeExec: suspendedBeforeExec
        )
        guard spawn.pid > 0, spawn.masterFD >= 0 else {
            let failureErrno = errno
            terminalLog.error("terminal.restart_prepare_spawn_failed surface=\(surfaceID.value.uuidString, privacy: .public) errno=\(failureErrno, privacy: .public)")
            return nil
        }

        let lease = TerminalFileDescriptorLease(fd: spawn.masterFD)
        let closeOnExecSucceeded =
            (closeOnExecEnabler ?? TerminalFileDescriptorFlags.enableCloseOnExec)(spawn.masterFD)
        let nonBlockingSucceeded = closeOnExecSucceeded
            && (nonBlockingEnabler ?? TerminalFileDescriptorFlags.enableNonBlocking)(spawn.masterFD)
        guard closeOnExecSucceeded, nonBlockingSucceeded else {
            let failureErrno = errno
            terminalLog.error("terminal.restart_prepare_flags_failed surface=\(surfaceID.value.uuidString, privacy: .public) pid=\(spawn.pid, privacy: .public) errno=\(failureErrno, privacy: .public)")
            let prepared = TerminalPreparedPTYRuntime(
                pid: spawn.pid,
                masterFD: spawn.masterFD,
                lease: lease,
                suspended: suspendedBeforeExec
            )
            if let cleanup = prepared.discard() {
                onFailureCleanup?(spawn.pid, cleanup)
            }
            return nil
        }
        return TerminalPreparedPTYRuntime(
            pid: spawn.pid,
            masterFD: spawn.masterFD,
            lease: lease,
            suspended: suspendedBeforeExec
        )
    }

    public init(
        workspaceID: WorkspaceID,
        title: String,
        launch: Launch,
        restoredSurfaceID: SurfaceID? = nil,
        assignedSurfaceID: SurfaceID? = nil,
        historyRepo: TerminalOutputRepository? = nil,
        settingsRepo: (any SettingsWriteRepository)? = nil,
        terminalFontSize: Double = TerminalFontSizeSetting.defaultSize,
        outputBus: SurfaceOutputBus = .shared,
        preservedDescriptor: SurfaceDescriptor? = nil,
        closeOnExecEnabler: ((Int32) -> Bool)? = nil,
        nonBlockingEnabler: ((Int32) -> Bool)? = nil,
        nonBlockingFailureBarrierFactory: ((pid_t) -> SurfaceTerminationBarrier)? = nil,
        preparedRuntime: TerminalPreparedPTYRuntime? = nil
    ) throws {
        self.outputBus = outputBus
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
        let generatedDescriptor = SurfaceDescriptor(
            id: restoredSurfaceID ?? assignedSurfaceID ?? SurfaceID(),
            type: type,
            title: title,
            iconName: type == .ssh ? "network" : "terminal",
            metadata: metadata
        )
        if let preservedDescriptor {
            precondition(
                preservedDescriptor.type == type,
                "a restarted terminal must preserve a descriptor of the same surface type"
            )
            self.descriptor = preservedDescriptor
        } else {
            self.descriptor = generatedDescriptor
        }
        self.historyCoordinator = TerminalHistoryCoordinator(
            repository: historyRepo,
            surfaceID: descriptor.id.value.uuidString,
            workspaceID: workspaceID.value.uuidString
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
        terminalView.fontZoomStore = settingsRepo
        terminalView.fontZoomWorkspaceID = workspaceID.value.uuidString
        terminalView.baseFontSize = TerminalFontSizeSetting.normalized(terminalFontSize)
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
        historyCoordinator.delegate = self
        let startsVisible = restoredSurfaceID == nil
        isVisible = startsVisible
        readerAllowsRender = startsVisible
        terminalView.setOcclusion(visible: startsVisible)
        historyCoordinator.prepare(restored: restoredSurfaceID != nil)

        terminalView.onInputData = { [weak self] data in
            guard let self else { return }
            let status = self.writeToPTY(data)
            if status != .accepted, !self.didBeepForDeadInput {
                self.didBeepForDeadInput = true
                NSSound.beep()
            }
        }
        terminalView.onTitleChange = { [weak self] title in
            guard let self, self.descriptor.title != title else { return }
            self.descriptor.title = title
            self.onTitleChange?(title)
        }
        // Audit #4: let the view distinguish a legitimate teardown from a stray close
        // of a still-visible instance. A deallocated owner reports "closing" (true).
        terminalView.ownerIsClosing = { [weak self] in self?.isClosing ?? true }
        // Forward paste-confirmation requests from the Ghostty view to any
        // app-level handler wired on this surface (e.g. AppCommandRouter).
        terminalView.onPasteNeedsConfirm = { [weak self] (text: String) in
            self?.confirmUnsafeTerminalInput(text)
        }
        terminalView.onPlainTextDragNeedsConfirm = { [weak self] text in
            self?.confirmUnsafeTerminalInput(text)
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
        replayPersistedHistoryIfNeeded()

        if case .sshPlaceholder = launch {
            appendString("[ssh disconnected]\nSelect a saved SSH host or add a new one to connect.\n")
            terminalDeadReason = "ssh_disconnected"
            publishRuntimeHealth()
            return
        }

        let pid: pid_t
        let amaster: Int32
        let masterFDLease: TerminalFileDescriptorLease
        let descriptorFlagsAlreadyConfigured: Bool
        let preparedRuntimeWasSuspended: Bool
        if let preparedRuntime {
            let prepared = preparedRuntime.takeOwnership()
            pid = prepared.pid
            amaster = prepared.masterFD
            masterFDLease = prepared.lease
            descriptorFlagsAlreadyConfigured = true
            preparedRuntimeWasSuspended = prepared.wasSuspended
        } else {
            let spawn = Self.spawnPTY(
                cwd: cwd,
                launch: launch,
                workspaceID: workspaceID,
                surfaceID: descriptor.id
            )
            pid = spawn.pid
            amaster = spawn.masterFD
            if pid < 0 {
                appendString("[forkpty failed: \(String(cString: strerror(errno)))]\n")
                terminalDeadReason = "fork_failed"
                terminalLog.error("terminal.spawn_failed surface=\(self.descriptor.id.value.uuidString, privacy: .public) errno=\(errno, privacy: .public)")
                publishRuntimeHealth()
                return
            }
            masterFDLease = TerminalFileDescriptorLease(fd: amaster)
            descriptorFlagsAlreadyConfigured = false
            preparedRuntimeWasSuspended = false
        }
        self.masterFD = amaster
        self.masterFDLease = masterFDLease
        self.childPID = pid
        self.childReapForegroundGroup = nil
        self.lastCapturedForegroundGroup = nil
        self.applicationTerminationBarrier = nil
        self.processAlive = true
        self.exitStatus = nil
        self.terminationSignal = nil
        self.terminalDeadReason = nil
        self.didAppendProcessExitedBanner = false
        self.lastOutputAt = Date()
        let closeOnExecSucceeded = descriptorFlagsAlreadyConfigured
            || (closeOnExecEnabler ?? TerminalFileDescriptorFlags.enableCloseOnExec)(amaster)
        let nonBlockingSucceeded = descriptorFlagsAlreadyConfigured
            || (closeOnExecSucceeded
                && (nonBlockingEnabler ?? TerminalFileDescriptorFlags.enableNonBlocking)(amaster))
        let preparedResumeSucceeded = !preparedRuntimeWasSuspended
            || TerminalPTYProcessRuntime.resumeOwnedLiveChild(pid: pid)
        if !closeOnExecSucceeded || !nonBlockingSucceeded || !preparedResumeSucceeded {
            let failure = String(cString: strerror(errno))
            let failureReason: String
            if !closeOnExecSucceeded {
                failureReason = "pty_cloexec_failed"
            } else if !nonBlockingSucceeded {
                failureReason = "pty_nonblocking_failed"
            } else {
                failureReason = "prepared_runtime_resume_failed"
            }
            terminalLog.error("terminal.flags_failed surface=\(self.descriptor.id.value.uuidString, privacy: .public) pid=\(pid, privacy: .public) reason=\(failureReason, privacy: .public) error=\(failure, privacy: .public)")
            masterFDLease.close()
            self.masterFD = -1
            self.masterFDLease = nil
            self.processAlive = false
            self.terminalDeadReason = failureReason
            let dispositionBarrier: SurfaceTerminationBarrier
            if let nonBlockingFailureBarrierFactory {
                dispositionBarrier = nonBlockingFailureBarrierFactory(pid)
            } else {
                let work = TerminalPTYProcessRuntime.beginApplicationTerminationDisposition(
                    pid: pid,
                    foregroundGroup: nil
                )
                dispositionBarrier = SurfaceTerminationBarrier(
                    groups: [work.group],
                    completionChecks: [work.succeeded]
                )
            }
            self.applicationTerminationBarrier = dispositionBarrier
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let succeeded = dispositionBarrier.wait(until: .distantFuture)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.childPID == pid else { return }
                    if succeeded {
                        self.childPID = -1
                        self.childReapInFlightPID = nil
                    } else {
                        self.terminalDeadReason = "process_reap_timeout"
                        terminalLog.error("terminal.reap_timeout surface=\(self.descriptor.id.value.uuidString, privacy: .public) pid=\(pid, privacy: .public) reason=nonblocking_setup_failed")
                    }
                    self.publishRuntimeHealth()
                }
            }
            appendString("[PTY descriptor setup failed; shell stopped]\r\n")
            publishRuntimeHealth()
            return
        }
        configureInputPump(lease: masterFDLease)
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
        // Preserve ordering vs pending visible bytes (PERF-136): if visible feed
        // events are queued, this resize must be applied AFTER them, otherwise the
        // already-received bytes would be reflowed at the wrong dimensions. Record
        // it in the same ordered buffer. When nothing is pending, apply now
        // (current behavior, safe). gh/PTY winsize stay immediate either way.
        if pendingRendererEvents.isEmpty {
            renderer.resize(rows: size.rows, cols: size.cols)
        } else {
            pendingRendererEvents.append(.resize(rows: size.rows, cols: size.cols))
            if Self.pendingRendererBufferExceeded(
                byteCount: pendingRendererByteCount,
                eventCount: pendingRendererEvents.count
            ) {
                ensureRendererCurrent()
            }
        }
        rendererMutationCount &+= 1
        outputBus.emitGeometry(descriptor.id, rows: size.rows, cols: size.cols)
        if sendToPTY, masterFD >= 0 {
            _ = rc2_set_winsize(masterFD, Int32(size.rows), Int32(size.cols))
        }
    }

    private func startReader() {
        let fd = masterFD
        guard let lease = masterFDLease else { return }
        let queue = DispatchQueue(
            label: "rc2.terminal.pty-reader.\(descriptor.id.value.uuidString)",
            qos: .userInitiated
        )
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource = src
        // The read source owns the fd. It is closed here — on the source's own
        // queue, after the final event handler returns — so the main thread never
        // closes masterFD out from under an in-flight background read() (data race
        // + closed-fd / fd-reuse hazard). Normal close/EOF only cancel; the
        // app-termination path may close the same lease synchronously because
        // reader and writer syscalls are serialized by its lock.
        src.setCancelHandler { lease.close() }
        let readerMainHandoffHook = self.readerMainHandoffHook
        let readerHandoffState = self.readerHandoffState
        let readerWillPublishHook = self.readerWillPublishHook
        var buf = [UInt8](repeating: 0, count: 4096)
        src.setEventHandler { [weak self] in
            guard let self, readerHandoffState.beginReadEvent() else { return }
            var output = Data()
            var shouldClose = false
            var readCalls = 0

            while true {
                let n = buf.withUnsafeMutableBytes { lease.read(into: $0) }
                if n > 0 {
                    output.append(contentsOf: buf[0..<Int(n)])
                    readCalls += 1
                    if Self.shouldYieldPTYReadEvent(
                        bytesRead: output.count,
                        readCalls: readCalls,
                        maxBytes: Self.maxPTYReadEventBytes,
                        maxReadCalls: Self.maxPTYReadCallsPerEvent
                    ) {
                        break
                    }
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

            readerWillPublishHook.fire(output)
            let batchID = readerHandoffState.publish(
                data: output,
                shouldClose: shouldClose,
                readCalls: readCalls
            )
            guard let batchID else { return }
            // A synchronous, bounded handoff is intentional backpressure: at
            // most one 256 KiB event per terminal can wait on the main actor.
            // The batch is first placed in an ownership mailbox so quit can
            // claim bytes already read before finalizing durable history.
            readerMainHandoffHook.fire()
            DispatchQueue.main.sync {
                guard let batch = readerHandoffState.claim(batchID) else { return }
                if !batch.data.isEmpty {
                    self.maxPTYReadBatchBytesObserved = max(
                        self.maxPTYReadBatchBytesObserved,
                        batch.data.count
                    )
                    self.maxPTYReadCallsObserved = max(
                        self.maxPTYReadCallsObserved,
                        batch.readCalls
                    )
                    self.appendDataAsync(
                        batch.data,
                        renderAllowedAtRead: self.readerAllowsRender
                    )
                }
                if batch.shouldClose {
                    self.handlePTYEOF()
                }
            }
        }
        src.resume()
    }

    private func handlePTYEOF() {
        terminalLog.info("terminal.pty_eof surface=\(self.descriptor.id.value.uuidString, privacy: .public) pid=\(self.childPID, privacy: .public)")
        let foregroundPGID = foregroundProcessGroup()
        readSource?.cancel()   // cancel handler closes the fd on the source's queue
        readSource = nil
        masterFD = -1
        let pid = childPID
        markTerminalDead(reason: "process_exited", exitStatus: nil, appendExitBanner: false)
        if pid > 0 {
            beginBoundedChildReap(
                pid: pid,
                foregroundPGID: foregroundPGID,
                sendInitialHangup: false
            )
        }
    }

    private func beginBoundedChildReap(
        pid: pid_t,
        foregroundPGID: pid_t?,
        sendInitialHangup: Bool
    ) {
        guard pid > 0 else { return }
        let foregroundGroup = resolvedForegroundGroupForReap(pid: pid, foregroundPGID: foregroundPGID)
        childReapForegroundGroup = foregroundGroup
        lastCapturedForegroundGroup = nil
        if childReapInFlightPID == pid {
            // The serial reaper already owns escalation. It may have consumed
            // waitpid while its MainActor completion is still queued; signalling
            // the stale numeric PID here can hit an unrelated reused process.
            return
        }
        childReapInFlightPID = pid
        if sendInitialHangup {
            processTreeSignalCountForTesting += 1
            TerminalPTYProcessRuntime.signalProcessTree(
                pid: pid,
                foregroundGroup: foregroundGroup,
                signal: SIGHUP
            )
        }
        TerminalPTYProcessRuntime.reapWithEscalation(
            pid: pid,
            foregroundGroup: foregroundGroup,
            initialHangupAlreadySent: sendInitialHangup
        ) { [weak self] result in
            self?.childReapCompletionHook.fire()
            DispatchQueue.main.async {
                guard let self, self.childReapInFlightPID == pid else { return }
                self.childReapInFlightPID = nil
                self.childReapForegroundGroup = nil
                guard self.childPID == pid else { return }
                if result.shellReaped {
                    self.childPID = -1
                }
                if result.timedOut {
                    self.terminalDeadReason = "process_reap_timeout"
                    terminalLog.error("terminal.reap_timeout surface=\(self.descriptor.id.value.uuidString, privacy: .public) pid=\(pid, privacy: .public) foregroundGroupRemaining=\(result.foregroundGroupRemaining, privacy: .public)")
                }
                if let status = result.status {
                    self.exitStatus = status
                    if (status & 0x7F) != 0 {
                        self.terminationSignal = status & 0x7F
                    }
                }
                self.appendProcessExitedBannerIfNeeded(rawStatus: result.status)
                self.publishRuntimeHealth()
            }
        }
    }

    private func resolvedForegroundGroupForReap(
        pid: pid_t,
        foregroundPGID: pid_t?
    ) -> TerminalPTYProcessRuntime.CapturedForegroundProcessGroup? {
        if let freshlyCaptured = TerminalPTYProcessRuntime.captureForegroundProcessGroup(
            pgid: foregroundPGID,
            shellPID: pid
        ) {
            return freshlyCaptured
        }
        if let activeReapGroup = childReapForegroundGroup,
           activeReapGroup.sessionID == pid,
           foregroundPGID == nil || foregroundPGID == activeReapGroup.pgid {
            return activeReapGroup
        }
        return lastCapturedForegroundGroup.flatMap { captured in
            captured.sessionID == pid && (foregroundPGID == nil || foregroundPGID == captured.pgid)
                ? captured
                : nil
        }
    }

    private func appendDataAsync(_ data: Data, renderAllowedAtRead: Bool) {
        guard !isClosing else { return }
        recordHistoryReplayLiveData(data)
        // Audit #3: if output is arriving while we believe the surface is hidden but
        // its view is demonstrably on a key, on-screen window, the visibility reconcile
        // desynced (a missed/incorrect setVisibleSurfaceIDs) and readerAllowsRender +
        // occlusion are latched OFF — nothing repaints (the freeze). Recovery normally
        // depends only on a future reconcile the user cannot trigger by scrolling or
        // typing. Fail loud and self-heal locally so the live terminal un-freezes.
        if !stuckHiddenHealScheduled,
           Self.shouldRunStuckHiddenHeal(
               isClosing: isClosing,
               isVisible: isVisible,
               viewDefinitelyOnScreen: ghosttyView.isDefinitelyOnScreen
           ) {
            // DEFER the heal to the next tick: this chunk must first land in the
            // hidden path (hiddenRendererBuffer + outputPendingBytes) consistently with
            // the render decision captured for it. Healing inline would flip visibility
            // mid-chunk and orphan these bytes out of the ANSIRenderer mirror (a gap in
            // ansiText) while leaving outputPendingBytes latched. didBecomeVisible() then
            // replays the now-complete buffer. The flag bounds this to once per episode.
            stuckHiddenHealScheduled = true
            terminalLog.error("terminal.stuck_hidden_recover surface=\(self.descriptor.id.value.uuidString, privacy: .public) — output arrived while logically hidden but the view is on a key on-screen window; self-healing (audit #3)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stuckHiddenHealScheduled = false
                guard Self.shouldRunStuckHiddenHeal(
                    isClosing: self.isClosing,
                    isVisible: self.isVisible,
                    viewDefinitelyOnScreen: self.ghosttyView.isDefinitelyOnScreen
                ) else { return }
                self.didBecomeVisible()
            }
        }
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
            // Defer the mirror-renderer feed (PERF-136): record the bytes instead
            // of emulating them now. rendererMutationCount must still advance so a
            // cached snapshot built before this chunk is invalidated. The replay on
            // the next snapshot read is byte-identical to feeding here.
            pendingRendererEvents.append(.bytes(data))
            pendingRendererByteCount += data.count
            rendererMutationCount &+= 1
            // Cap the pending buffer to bound memory during long visible bursts.
            // Unlike the hidden path we FORCE-FLUSH (never drop) so the visible
            // snapshot stays COMPLETE.
            if Self.pendingRendererBufferExceeded(
                byteCount: pendingRendererByteCount,
                eventCount: pendingRendererEvents.count
            ) {
                ensureRendererCurrent()
            }
        } else {
            // Surface is hidden: buffer bytes so the renderer can be healed on
            // reveal. Cap the buffer to avoid unbounded growth during long hidden
            // sessions; bytes beyond the cap are silently dropped (the snapshot
            // will remain complete=false, which is already correct behavior).
            if !hiddenRendererBufferOverflowed {
                let remaining = Self.maxHiddenRendererBufferBytes - hiddenRendererBuffer.count
                if remaining >= data.count {
                    hiddenRendererBuffer.append(data)
                } else if remaining > 0 {
                    hiddenRendererBuffer.append(data.prefix(remaining))
                    hiddenRendererBufferOverflowed = true
                } else {
                    hiddenRendererBufferOverflowed = true
                }
            }
        }
        if renderAllowedAtRead, renderDiagnostics().canRender {
            ghosttyView.processOutput(data)
        } else {
            outputPendingBytes += data.count
            // Process THIS chunk into the surface BEFORE the drain may force-complete
            // (#5): completeHiddenBacklogDrain refreshes, and refreshing before the
            // chunk is fed would paint a frame missing the latest bytes.
            ghosttyView.processOutput(data, render: false)
            continueHiddenBacklogDrainIfNeeded()
        }
        if ghosttyView.droppedOutputBytes > 0 {
            outputPartial = true
            if outputPartialReason == nil || outputPartialReason == "history_replay_failed" {
                outputPartialReason = "ghostty_buffer_cap"
            }
        }
        scheduleBusyStateRefresh()
    }

    private func appendString(_ raw: String) {
        guard let data = raw.data(using: .utf8) else { return }
        recordHistoryReplayLiveData(data)
        enqueueHistory(data)
        recordOutputTelemetry(bytes: data.count)
        // Route through the same ordered pending buffer (PERF-136) so an injected
        // string stays ordered relative to any pending visible output bytes.
        pendingRendererEvents.append(.bytes(data))
        pendingRendererByteCount += data.count
        rendererMutationCount &+= 1
        if Self.pendingRendererBufferExceeded(
            byteCount: pendingRendererByteCount,
            eventCount: pendingRendererEvents.count
        ) {
            ensureRendererCurrent()
        }
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
        TerminalHistoryCoordinator.assembleReplayPayload(from: chunkData)
    }

    private func replayPersistedHistoryIfNeeded() {
        historyCoordinator.replayIfNeeded()
    }

    private func recordHistoryReplayLiveData(_ data: Data) {
        historyCoordinator.recordLiveReplayData(
            data,
            maxBytes: Self.maxHiddenRendererBufferBytes
        )
    }

    var terminalHistoryIsClosing: Bool {
        isClosing
    }

    func terminalHistoryCoordinator(
        _ coordinator: TerminalHistoryCoordinator,
        didEncounter issue: TerminalHistoryCoordinator.Issue
    ) {
        switch issue {
        case .backlogCap(let outstandingBytes, let incomingBytes):
            outputPartial = true
            outputPartialReason = "history_backlog_cap"
            terminalLog.error("terminal.history_backlog_capped surface=\(self.descriptor.id.value.uuidString, privacy: .public) outstandingBytes=\(outstandingBytes, privacy: .public) incomingBytes=\(incomingBytes, privacy: .public)")
            publishRuntimeHealth()
        case .persistenceFailure:
            let partialStateChanged = !outputPartial || outputPartialReason == nil
            outputPartial = true
            if outputPartialReason == nil || outputPartialReason == "history_replay_failed" {
                outputPartialReason = "history_persistence_failed"
            }
            if partialStateChanged {
                publishRuntimeHealth()
            }
        case .persistenceRecovered:
            // A successful later append does not restore bytes lost by the
            // earlier failed append. The durable gap clears only with the
            // user's explicit clear/delete action.
            return
        case .retentionCap:
            let partialStateChanged = !outputPartial || outputPartialReason == nil
            outputPartial = true
            if outputPartialReason == nil || outputPartialReason == "history_replay_failed" {
                outputPartialReason = "history_retention_cap"
            }
            if partialStateChanged {
                publishRuntimeHealth()
            }
        case .retentionMaintenanceFailure:
            let partialStateChanged = !outputPartial || outputPartialReason == nil
            outputPartial = true
            if outputPartialReason == nil || outputPartialReason == "history_replay_failed" {
                outputPartialReason = "history_retention_maintenance_failed"
            }
            if partialStateChanged {
                publishRuntimeHealth()
            }
        case .retentionMaintenanceRecovered:
            guard outputPartialReason == "history_retention_maintenance_failed" else { return }
            outputPartial = false
            outputPartialReason = nil
            publishRuntimeHealth()
        case .replayReadFailure:
            let partialStateChanged = !outputPartial || outputPartialReason == nil
            outputPartial = true
            outputPartialReason = outputPartialReason ?? "history_replay_failed"
            if partialStateChanged {
                publishRuntimeHealth()
            }
        case .replayReadRecovered:
            guard outputPartialReason == "history_replay_failed" else { return }
            outputPartial = false
            outputPartialReason = nil
            publishRuntimeHealth()
        case .replayLiveCap:
            // Live bytes are already present in both renderers. A reset from the
            // capped replay buffer would erase the newest rendered tail.
            let partialStateChanged = !outputPartial || outputPartialReason == nil
            outputPartial = true
            if outputPartialReason == nil || outputPartialReason == "history_replay_failed" {
                outputPartialReason = "history_replay_live_cap"
            }
            if partialStateChanged {
                publishRuntimeHealth()
            }
        case .durablePartial(let reason):
            let partialStateChanged = !outputPartial || outputPartialReason == nil
            outputPartial = true
            if outputPartialReason == nil || outputPartialReason == "history_replay_failed" {
                outputPartialReason = reason
            }
            if partialStateChanged {
                publishRuntimeHealth()
            }
        case .liveClearCompleted(let outputIsPartial):
            if !outputIsPartial {
                outputPartial = false
                outputPartialReason = nil
            }
            cachedTextSnapshot = nil
            publishRuntimeHealth()
        case .liveClearFailed:
            outputPartial = true
            outputPartialReason = "history_clear_failed"
            cachedTextSnapshot = nil
            publishRuntimeHealth()
        case .staleWriterGeneration:
            outputPartial = true
            if outputPartialReason == nil || outputPartialReason == "history_replay_failed" {
                outputPartialReason = "history_writer_stale"
            }
            cachedTextSnapshot = nil
            publishRuntimeHealth()
        }
    }

    func terminalHistoryCoordinator(
        _ coordinator: TerminalHistoryCoordinator,
        didPrepareReplay canonical: Data
    ) {
        guard !canonical.isEmpty else { return }
        renderer = ANSIRenderer(rows: terminalSize.rows, cols: terminalSize.cols)
        renderer.feed(canonical)
        pendingRendererEvents.removeAll(keepingCapacity: true)
        pendingRendererByteCount = 0
        hiddenRendererBuffer = Data()
        hiddenRendererBufferOverflowed = false
        rendererMutationCount &+= 1
        cachedTextSnapshot = nil
        ghosttyView.resetSurfaceOutput(canonical)
    }

    public func appendSystemText(_ raw: String) {
        appendString(raw)
    }

    private func autoSubmitSavedSSHPasswordIfNeeded(from data: Data) {
        guard let raw = String(data: data, encoding: .utf8)?.lowercased(),
              raw.contains("password:") || raw.contains("passphrase") else { return }
        passwordPromptCount += 1
        if let notice = Self.autoSubmitNotice(promptCount: passwordPromptCount) {
            appendString("\r\n" + notice + "\r\n")
        }
        guard !didSendSavedSSHPassword,
              let savedSSHPassword,
              !savedSSHPassword.isEmpty else { return }
        didSendSavedSSHPassword = true
        _ = sendTextStatus(savedSSHPassword + "\n")
    }

    // Pure decision seam -- no state, no secrets.
    // promptCount 1 -> user sees that the app submitted their saved password (not typed by ghost).
    // promptCount 2 -> user sees the server rejected it and is asking again; the app will NOT
    //                  re-submit (didSendSavedSSHPassword guards that), so the prompt is live.
    // promptCount 0 or <0 -> nil (no notice).
    nonisolated static func autoSubmitNotice(promptCount: Int) -> String? {
        switch promptCount {
        case 1:
            return "[submitted your saved password automatically -- the app answered this prompt, not you]"
        case 2:
            return "[server is asking for the password again -- your saved password was rejected; type it manually]"
        default:
            return nil
        }
    }

    // Pure decision seam: decides what bytes (if any) to replay into the
    // renderer when a hidden surface becomes visible again.
    //
    // - buffer: bytes accumulated while hidden (may be empty or overflowed-truncated)
    // - overflowed: true when the buffer hit the cap; the renderer snapshot will
    //   still be partial even after the replay (caller must keep complete=false)
    //
    // Returns the data that MUST be fed to renderer.feed on reveal, or nil when
    // there is nothing to replay. This seam is nonisolated/static so it can be
    // unit-tested without AppKit or a live TerminalSurface instance.
    nonisolated static func hiddenRendererHealPlan(buffer: Data, overflowed: Bool) -> Data? {
        guard !buffer.isEmpty else { return nil }
        // Even when overflowed, replay whatever was buffered: partial is better
        // than nothing; the complete=false flag already signals the gap.
        return buffer
    }

    /// Pure detection seam (audit #3): a surface that believes it is hidden
    /// (`isVisible == false`) while its view is demonstrably on a key, on-screen
    /// window is a visibility-reconcile desync — output is arriving but
    /// readerAllowsRender/occlusion are latched off so nothing repaints (the freeze).
    /// `nonisolated static` so the desync condition is unit-testable without AppKit.
    nonisolated static func isLikelyStuckHidden(isVisible: Bool, viewDefinitelyOnScreen: Bool) -> Bool {
        !isVisible && viewDefinitelyOnScreen
    }

    /// Re-check used by the deferred stuck-hidden heal before it flips the surface
    /// visible. The view can legitimately disappear between scheduling and execution.
    nonisolated static func shouldRunStuckHiddenHeal(
        isClosing: Bool,
        isVisible: Bool,
        viewDefinitelyOnScreen: Bool
    ) -> Bool {
        !isClosing && isLikelyStuckHidden(isVisible: isVisible, viewDefinitelyOnScreen: viewDefinitelyOnScreen)
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

    private func configureInputPump(lease: TerminalFileDescriptorLease) {
        let pump = TerminalInputPump(writer: { data, offset in
            lease.write(data, offset: offset)
        })
        attachInputPumpCallbacks(pump)
        inputPump = pump
    }

    func installInputPumpForRuntimeHealthTests(_ pump: TerminalInputPump, processAlive: Bool = true) {
        self.processAlive = processAlive
        self.terminalDeadReason = nil
        self.exitStatus = nil
        self.terminationSignal = nil
        attachInputPumpCallbacks(pump)
        inputPump = pump
    }

    private func attachInputPumpCallbacks(_ pump: TerminalInputPump) {
        pump.onTerminalFailure = { [weak self] status in
            DispatchQueue.main.async {
                if let self {
                    terminalLog.error("terminal.input_failed surface=\(self.descriptor.id.value.uuidString, privacy: .public) status=\(status.rawValue, privacy: .public) pid=\(self.childPID, privacy: .public)")
                }
                self?.markTerminalDead(reason: status.rawValue, exitStatus: nil)
            }
        }
        pump.onInputStalled = { [weak self] unwritten in
            DispatchQueue.main.async {
                guard let self, !self.isClosing else { return }
                // RECOVERABLE: the child is not draining stdin. Keep the terminal
                // alive, but publish input_accepting=false until the accepted bytes
                // are retried and delivered.
                terminalLog.error("terminal.input_stalled surface=\(self.descriptor.id.value.uuidString, privacy: .public) unwrittenBytes=\(unwritten, privacy: .public) pid=\(self.childPID, privacy: .public)")
                self.publishRuntimeHealth()
            }
        }
        pump.onInputResumed = { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.isClosing else { return }
                terminalLog.info("terminal.input_resumed surface=\(self.descriptor.id.value.uuidString, privacy: .public) pid=\(self.childPID, privacy: .public)")
                self.didBeepForDeadInput = false
                self.publishRuntimeHealth()
            }
        }
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
            outputPartialReason: outputPartialReason,
            outputPendingBytes: outputPendingBytes,
            historyWriteFailures: historyWriteFailures,
            droppedOutputBytes: ghosttyView.droppedOutputBytes,
            rows: terminalSize.rows,
            cols: terminalSize.cols,
            renderDiagnostics: renderDiagnostics()
        )
    }

    /// Final ownership gate used immediately before a prepared replacement is
    /// registered under an existing surface ID. Boolean runtime state alone is
    /// insufficient because a child may have exited after forkpty succeeded.
    public func runtimeProcessIsOwnedAndAliveForRestartCommit() -> Bool {
        guard processAlive,
              childPID > 0,
              masterFD >= 0,
              terminalDeadReason == nil else { return false }
        return TerminalPTYProcessRuntime.ownsLiveChild(pid: childPID)
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
        guard group > 0 else { return nil }
        if group == childPID {
            lastCapturedForegroundGroup = nil
        } else if let captured = TerminalPTYProcessRuntime.captureForegroundProcessGroup(
            pgid: group,
            shellPID: childPID
        ) {
            lastCapturedForegroundGroup = captured
        }
        return group
    }

    public func readTextSnapshot() -> TerminalTextSnapshot {
        // Flush any deferred visible feed/resize events into `renderer` FIRST
        // (PERF-136), before the cache check, so rendererMutationCount and the
        // renderer's actual state agree for every read site below.
        ensureRendererCurrent()
        // Hidden PTY bytes land in `hiddenRendererBuffer`, not `renderer`/`pendingRendererEvents`.
        // Heal the mirror before any snapshot read so surface.read_text returns the
        // authoritative transcript while still hidden (release-soak aux markers),
        // not a blank Ghostty parked grid or an unfed ANSIRenderer.
        if !isVisible {
            applyHiddenRendererHealIfNeeded()
        }
        let diagnostics = renderDiagnostics()
        // F1: the cache key must also cover the volatile state the snapshot EMBEDS
        // (render-diagnostics, pending/partial/history-failure flags). rendererVersion
        // + viewportText alone miss a change such as canRender flipping or
        // outputPendingBytes moving with no renderer feed, so the cache could return a
        // snapshot whose embedded diagnostics are stale — masking live state as stable.
        // Fold those signals into a signature that is part of the validity check.
        let stateSignature = Self.snapshotStateSignature(
            outputPartial: outputPartial,
            outputPendingBytes: outputPendingBytes,
            historyWriteFailures: historyWriteFailures,
            diagnostics: diagnostics,
            outputPartialReason: outputPartialReason
        )
        if !isVisible {
            // Hidden surfaces: Ghostty may be parked/occluded with a blank multi-row
            // viewport even after pending drains. The healed ANSI renderer is the
            // authoritative transcript for surface.read_text / iOS mirrors.
            // The viewport key in this branch is always nil (we skip ghostty read).
            if let cached = cachedTextSnapshot,
               Self.snapshotCacheValid(
                   rendererVersion: rendererMutationCount,
                   cachedVersion: cached.rendererVersion,
                   viewportText: nil,
                   cachedViewportText: cached.viewportText,
                   stateSignature: stateSignature,
                   cachedStateSignature: cached.stateSignature
               ) {
                return cached.value
            }
            // Match the visible path: complete requires canRender. Hidden always
            // blocks render (logical_hidden), so complete stays false even after
            // the ANSI mirror is healed. Otherwise idle hidden reads (pending=0)
            // report complete=true with partial_reason=logical_hidden while the
            // wire maps partial=!complete — dishonest to surface.read_text.
            let complete = diagnostics.canRender && Self.readTextComplete(
                outputPartial: outputPartial,
                outputPendingBytes: outputPendingBytes,
                historyWriteFailures: historyWriteFailures
            )
            let partialReason = Self.readTextPartialReason(
                outputPartial: outputPartial,
                outputPendingBytes: outputPendingBytes,
                historyWriteFailures: historyWriteFailures,
                renderBlockedReason: diagnostics.blockedReason,
                outputPartialReason: outputPartialReason
            )
            var snap = TerminalTextSnapshot(
                text: renderer.snapshot().string,
                ansiText: renderer.ansiSnapshot(includeScrollback: true),
                complete: complete,
                source: "ansi_fallback",
                timestamp: Date(),
                partialReason: partialReason,
                pendingBytes: outputPendingBytes,
                rows: terminalSize.rows,
                cols: terminalSize.cols,
                renderDiagnostics: diagnostics
            )
            snap.ansiPalette = resolvedCustomPaletteHex()
            cachedTextSnapshot = (rendererMutationCount, nil, stateSignature, snap)
            return snap
        }
        // Read the ghostty viewport text first (cheap when there is no pending
        // output — just reads the existing rendered frame). We need the value
        // before the cache check because it is the viewport-side cache key.
        let currentViewportText = ghosttyView.readViewportText()
        if let cached = cachedTextSnapshot,
           Self.snapshotCacheValid(
               rendererVersion: rendererMutationCount,
               cachedVersion: cached.rendererVersion,
               viewportText: currentViewportText,
               cachedViewportText: cached.viewportText,
               stateSignature: stateSignature,
               cachedStateSignature: cached.stateSignature
           ) {
            return cached.value
        }
        var snap: TerminalTextSnapshot
        if let text = currentViewportText {
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
                renderBlockedReason: diagnostics.blockedReason,
                outputPartialReason: outputPartialReason
            )
            if Self.shouldPreferRendererSnapshotForReadText(viewportText: text, rendererText: rendererText) {
                snap = TerminalTextSnapshot(
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
            } else {
                snap = TerminalTextSnapshot(
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
        } else {
            snap = TerminalTextSnapshot(
                text: renderer.snapshot().string,
                ansiText: renderer.ansiSnapshot(includeScrollback: true),
                complete: false,
                source: "ansi_fallback",
                timestamp: Date(),
                partialReason: outputPartialReason ?? "ghostty_unavailable",
                pendingBytes: outputPendingBytes,
                rows: terminalSize.rows,
                cols: terminalSize.cols,
                renderDiagnostics: diagnostics
            )
        }
        snap.ansiPalette = resolvedCustomPaletteHex()
        cachedTextSnapshot = (rendererMutationCount, currentViewportText, stateSignature, snap)
        return snap
    }

    /// Resolve the active Ghostty theme's 16-entry ANSI palette as `#rrggbb`
    /// hex strings, or `nil` when the theme is the built-in default (so the
    /// snapshot omits `ansi_palette` and iOS uses its own default). Pure beyond
    /// the Ghostty config read.
    private func resolvedCustomPaletteHex() -> [String]? {
        ANSIPaletteMapper.customPaletteHex(from: GhosttyTerminalView.resolvedANSIThemeColors())
    }

    static func readTextComplete(outputPartial: Bool, outputPendingBytes: Int, historyWriteFailures: Int) -> Bool {
        !outputPartial && outputPendingBytes == 0 && historyWriteFailures == 0
    }

    /// Pure cache-validity decision for `readTextSnapshot()`.
    ///
    /// Returns `true` only when BOTH the renderer AND the ghostty viewport text
    /// are unchanged since the snapshot was last built, so the cached value can
    /// be returned without rebuilding.
    ///
    /// Design rationale:
    /// - `rendererVersion` tracks every `renderer.feed()` / `renderer.resize()`
    ///   call inside TerminalSurface, giving us a cheap per-mutation signal
    ///   without touching ANSIRenderer's private `contentVersion`.
    /// - `viewportText` is the full string returned by `ghosttyView.readViewportText()`
    ///   on the last build. Viewport text changes independently of the renderer
    ///   (e.g. Ghostty scrolls or repaints while the ANSIRenderer version is
    ///   unchanged), so a renderer-version-only key would return stale viewport
    ///   text. Storing the full string and checking equality is O(n) in text
    ///   length but is only paid on actual `readTextSnapshot()` calls — not on
    ///   every byte of output.
    /// - A `nil` viewportText means "ghostty returned nil on the last build"
    ///   (surface not ready / no live surface). Cache is valid only when the
    ///   current ghostty text is also nil — the moment ghostty becomes available
    ///   the viewport key diverges and the cache is rebuilt.
    ///
    /// Staleness guarantee: if either signal changes, this returns `false` and
    /// the caller must rebuild. It never returns `true` for a stale result.
    nonisolated static func snapshotCacheValid(
        rendererVersion: UInt64,
        cachedVersion: UInt64,
        viewportText: String?,
        cachedViewportText: String?,
        stateSignature: String,
        cachedStateSignature: String
    ) -> Bool {
        rendererVersion == cachedVersion
            && viewportText == cachedViewportText
            && stateSignature == cachedStateSignature
    }

    /// Compact signature of the volatile state that `readTextSnapshot()` embeds in a
    /// snapshot but that is NOT captured by `rendererVersion`/`viewportText`: the
    /// render-diagnostics outcome plus the pending/partial/history-failure flags.
    /// Folding it into the cache key (F1) means a diagnostics change (e.g. canRender
    /// flips, or `outputPendingBytes` moves with no renderer feed) correctly
    /// invalidates the cache instead of returning a snapshot with stale diagnostics.
    /// `nonisolated static` so it is pure and unit-testable.
    nonisolated static func snapshotStateSignature(
        outputPartial: Bool,
        outputPendingBytes: Int,
        historyWriteFailures: Int,
        diagnostics: TerminalRenderDiagnostics,
        outputPartialReason: String? = nil
    ) -> String {
        // Fold EVERY render-diagnostics field the snapshot embeds (not just
        // blockedReason/canRender) so a change in any of them — e.g. `parked` flipping
        // while a higher-priority blockedReason stays the same — still invalidates the
        // cache and the mirror never receives a snapshot with a stale diagnostics field.
        let d = diagnostics
        let diag = "\(d.logicalVisible ? 1 : 0)\(d.registryVisible ? 1 : 0)\(d.drainingHiddenBacklog ? 1 : 0)\(d.windowAttached ? 1 : 0)\(d.parked ? 1 : 0)\(d.hasUsableBounds ? 1 : 0)\(d.hiddenAncestor ? 1 : 0)"
        return "\(outputPartial)|\(outputPendingBytes)|\(historyWriteFailures)|\(outputPartialReason ?? "")|\(diag)|\(d.blockedReason ?? "")"
    }

    static func readTextPartialReason(
        outputPartial: Bool,
        outputPendingBytes: Int,
        historyWriteFailures: Int,
        renderBlockedReason: String? = nil,
        outputPartialReason: String? = nil
    ) -> String? {
        if let outputPartialReason { return outputPartialReason }
        if outputPartial { return "hidden_output_cap" }
        if outputPendingBytes > 0 { return "hidden_output_pending" }
        if historyWriteFailures > 0 { return "history_persistence_failed" }
        if let renderBlockedReason { return renderBlockedReason }
        return nil
    }

    /// The reason a history flush is requested.
    ///
    /// History disposition is always asynchronous. App termination and runtime
    /// replacement join its barrier against one caller-owned deadline.
    enum FlushReason: Equatable {
        /// The user closed a tab (or the surface is being torn down mid-session).
        /// A slow disk must not stall the main thread — flush asynchronously.
        case tabClose
        /// The app is about to terminate (applicationWillTerminate).
        /// Data must not be lost on quit — join the global history barrier.
        case appTermination
        /// A dead shell is being replaced behind the same stable surface ID.
        case runtimeRestart
    }

    /// Compatibility seam proving no close path performs a per-surface
    /// synchronous SQLite wait on the main actor.
    nonisolated static func flushShouldWait(reason: FlushReason) -> Bool {
        false
    }

    private func publishRuntimeHealth() {
        guard publishesRuntimeHealth else { return }
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
        terminalLog.info("terminal.output_health surface=\(self.descriptor.id.value.uuidString, privacy: .public) pid=\(self.childPID, privacy: .public) totalBytes=\(self.totalOutputBytes, privacy: .public) pendingBytes=\(self.outputPendingBytes, privacy: .public) droppedBytes=\(self.ghosttyView.droppedOutputBytes, privacy: .public) historyOutstandingBytes=\(self.historyOutstandingBytes, privacy: .public) historyFailures=\(self.historyWriteFailures, privacy: .public) maxReadBatchBytes=\(self.maxPTYReadBatchBytesObserved, privacy: .public) maxReadCalls=\(self.maxPTYReadCallsObserved, privacy: .public) canRender=\(diagnostics.canRender, privacy: .public) blocked=\(diagnostics.blockedReason ?? "none", privacy: .public)")
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

    private func markTerminalDead(
        reason: String,
        exitStatus: Int32?,
        appendExitBanner: Bool = true
    ) {
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
        if wasAlive, appendExitBanner {
            appendProcessExitedBannerIfNeeded(rawStatus: exitStatus)
        }
        publishRuntimeHealth()
    }

    private func appendProcessExitedBannerIfNeeded(rawStatus: Int32?) {
        guard !didAppendProcessExitedBanner, !isClosing else { return }
        didAppendProcessExitedBanner = true
        appendString("\r\n" + Self.processExitedBanner(rawStatus: rawStatus) + "\r\n")
        showRestartBannerIfEligible()
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
        // Prefer the ANSI mirror when Ghostty's viewport has collapsed to empty or a
        // single visible line (stale prompt / blank multi-row parked grid) while the
        // renderer still holds more visible transcript. Compare visible line counts —
        // not raw string length — so a blank 43-row grid of newlines cannot outrank a
        // shorter marker-bearing renderer snapshot (release-soak aux ready markers).
        let viewportVisible = visibleLineCount(viewportText)
        let rendererVisible = visibleLineCount(rendererText)
        guard viewportVisible <= 1 else { return false }
        guard rendererVisible > viewportVisible else { return false }
        return rendererText.contains(where: { $0.isNewline }) || viewportVisible == 0
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
        // Defensive (PERF-136): drain any deferred visible events before the hidden
        // heal feeds directly into `renderer`, so the heal bytes stay ordered after
        // them. didBecomeHidden already flushes, so this is normally a no-op.
        ensureRendererCurrent()
        // Heal the renderer BEFORE setting readerAllowsRender=true.
        // Once readerAllowsRender flips, appendDataAsync feeds live bytes
        // directly into renderer.feed; replaying the buffer first ensures
        // the renderer sees bytes in chronological order with no gap and no
        // double-feed (buffer is cleared here, live path is not yet active).
        // Same heal as readTextSnapshot uses while still hidden.
        applyHiddenRendererHealIfNeeded()
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

    /// Replays bytes buffered while `isVisible == false` into the ANSI mirror
    /// renderer and clears the buffer so a later reveal cannot double-feed.
    /// Called from `readTextSnapshot` (while still hidden) and `didBecomeVisible`.
    private func applyHiddenRendererHealIfNeeded() {
        let healBuffer = hiddenRendererBuffer
        let healOverflowed = hiddenRendererBufferOverflowed
        guard let replay = Self.hiddenRendererHealPlan(buffer: healBuffer, overflowed: healOverflowed) else {
            // Empty buffer: still clear a degenerate overflow latch if set.
            if healOverflowed {
                hiddenRendererBufferOverflowed = false
                outputPartial = true
                if outputPartialReason == nil || outputPartialReason == "history_replay_failed" {
                    outputPartialReason = "hidden_output_cap"
                }
            }
            return
        }
        hiddenRendererBuffer = Data()
        hiddenRendererBufferOverflowed = false
        renderer.feed(replay)
        rendererMutationCount &+= 1
        // Invalidate any snapshot built before this heal.
        cachedTextSnapshot = nil
        if healOverflowed {
            outputPartial = true
            if outputPartialReason == nil || outputPartialReason == "history_replay_failed" {
                outputPartialReason = "hidden_output_cap"
            }
        }
    }

    private func scheduleVisibleRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.isClosing else { return }
            self.ghosttyView.refreshSurfaceOnly()
        }
    }

    public func didBecomeHidden() {
        guard isVisible else { return }
        // Flush any deferred visible feed/resize events (PERF-136) into `renderer`
        // BEFORE switching to the hidden path. Otherwise bytes buffered during the
        // hidden period (hiddenRendererBuffer, fed directly into `renderer` on
        // reveal) would land ahead of these still-pending earlier visible bytes,
        // reordering the mirror stream.
        ensureRendererCurrent()
        isVisible = false
        readerAllowsRender = false
        stuckHiddenHealScheduled = false
        isDrainingHiddenBacklog = false
        hiddenBacklogDrainDeadline = nil
        // Clear any renderer buffer from a prior hidden session so bytes from
        // one hidden period do not bleed into the next.
        hiddenRendererBuffer = Data()
        hiddenRendererBufferOverflowed = false
        ghosttyView.setOcclusion(visible: false)
        scheduleParkingIfDetached()
    }

    private func beginHiddenBacklogDrain() {
        isDrainingHiddenBacklog = true
        hiddenBacklogDrainDeadline = Date().addingTimeInterval(Self.hiddenBacklogMaxDrainWindow)
        hiddenBacklogDrainGeneration &+= 1
        scheduleHiddenBacklogDrainCompletion(generation: hiddenBacklogDrainGeneration)
    }

    private func continueHiddenBacklogDrainIfNeeded() {
        guard isDrainingHiddenBacklog else { return }
        // #5: a continuous post-reveal stream (chunks closer together than the quiet
        // delay) used to RE-ARM the completion on every chunk, so isDrainingHiddenBacklog
        // never cleared and canRender stayed false for the whole burst — the
        // frozen-at-reveal-frame bug. Past the absolute deadline, stop re-arming and
        // force the drain to complete.
        guard Self.shouldRearmHiddenBacklogDrain(now: Date(), deadline: hiddenBacklogDrainDeadline) else {
            completeHiddenBacklogDrain()
            return
        }
        hiddenBacklogDrainGeneration &+= 1
        scheduleHiddenBacklogDrainCompletion(generation: hiddenBacklogDrainGeneration)
    }

    /// Pure seam (#5): whether the hidden-backlog drain may re-arm its quiet-delay
    /// completion, or has exceeded its absolute deadline and must force-complete.
    /// `nonisolated static` so the deadline logic is unit-testable without AppKit.
    nonisolated static func shouldRearmHiddenBacklogDrain(now: Date, deadline: Date?) -> Bool {
        guard let deadline else { return true }
        return now < deadline
    }

    private func scheduleHiddenBacklogDrainCompletion(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hiddenBacklogQuietDelay) { [weak self] in
            guard let self,
                  self.hiddenBacklogDrainGeneration == generation,
                  self.isVisible,
                  !self.isClosing else { return }
            self.completeHiddenBacklogDrain()
        }
    }

    private func completeHiddenBacklogDrain() {
        guard isDrainingHiddenBacklog else { return }
        isDrainingHiddenBacklog = false
        hiddenBacklogDrainDeadline = nil
        outputPendingBytes = 0
        ghosttyView.refreshSurfaceOnly()
        // F5: the drain just changed render/output state — publish runtime health now
        // so the UI/mirror reconcile instead of waiting for the next busy-state poll.
        publishRuntimeHealth()
    }

    public func close() {
        _ = close(deletePersistedHistory: false, removeOutputBusState: true, reason: .tabClose)
    }

    public func closeForApplicationTermination() -> SurfaceTerminationBarrier? {
        close(deletePersistedHistory: false, removeOutputBusState: true, reason: .appTermination)
    }

    /// Stops the old runtime without deleting its durable history or resetting
    /// its mirror cursor. The replacement may spawn only after this combined
    /// history + process barrier succeeds.
    public func closeForRuntimeRestart() -> SurfaceTerminationBarrier? {
        close(deletePersistedHistory: false, removeOutputBusState: false, reason: .runtimeRestart)
    }

    public func requiredHistoryBarrierForRuntimeRestart() -> SurfaceTerminationBarrier? {
        runtimeRestartRequiredHistoryBarrier
    }

    /// Non-destructive restart gate. A caller may time out and leave this
    /// runtime fully interactive while the serial history writer continues to
    /// drain. Only a successful gate authorizes PTY/Ghostty teardown.
    public func runtimeRestartHistoryPreflightBarrier() -> SurfaceTerminationBarrier {
        historyCoordinator.flushBarrier()
    }

    /// Continues ownership-safe cleanup after an irreversible restart close
    /// whose fast disposition could not prove completion. The replacement may
    /// still take over the stable surface ID; this old runtime keeps no UI role.
    @discardableResult
    public func continueCleanupAfterFailedRuntimeRestart() -> SurfaceTerminationBarrier? {
        let pid = childPID
        guard pid > 0 else { return nil }
        let work = TerminalPTYProcessRuntime.beginApplicationTerminationDisposition(
            pid: pid,
            foregroundGroup: childReapForegroundGroup
        )
        let barrier = SurfaceTerminationBarrier(
            groups: [work.group],
            completionChecks: [work.succeeded]
        )
        applicationTerminationBarrier = barrier
        childReapInFlightPID = pid
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let succeeded = barrier.wait(until: .distantFuture)
            self?.childReapCompletionHook.fire()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.childPID == pid else { return }
                self.childReapInFlightPID = nil
                self.childReapForegroundGroup = nil
                if succeeded {
                    self.childPID = -1
                } else {
                    self.terminalDeadReason = "process_reap_timeout"
                    terminalLog.error("terminal.reap_timeout surface=\(self.descriptor.id.value.uuidString, privacy: .public) pid=\(pid, privacy: .public) reason=runtime_restart_fallback")
                }
                self.publishRuntimeHealth()
            }
        }
        return barrier
    }

    public func markRuntimeRestartDispositionIncomplete() {
        outputPartial = true
        outputPartialReason = "runtime_restart_disposition_incomplete"
        publishRuntimeHealth()
    }

    public func markRuntimeRestartHistoryIncomplete() {
        outputPartial = true
        outputPartialReason = "runtime_restart_history_incomplete"
        publishRuntimeHealth()
    }

    public func markRuntimeRestartRecoveryExhausted() {
        outputPartial = true
        outputPartialReason = "runtime_restart_recovery_exhausted"
        publishRuntimeHealth()
    }

    public func refreshRestartActionForCurrentHealth() {
        if processAlive {
            removeRestartBanner()
        } else {
            showRestartBannerIfEligible()
        }
    }

    /// Stops a retired runtime from publishing stale dead health after another
    /// runtime commits behind the same stable surface ID.
    public func relinquishRuntimeHealthOwnershipForReplacement() {
        publishesRuntimeHealth = false
    }

    /// Tears down one runtime that is being replaced behind the same registered
    /// surface ID. The mirror cursor must survive so the next runtime continues
    /// with a strictly greater sequence instead of being rejected as stale by iOS.
    @discardableResult
    public func closePreservingOutputBusState(timeout: TimeInterval = 2) -> Bool {
        let barrier = close(
            deletePersistedHistory: false,
            removeOutputBusState: false,
            reason: .runtimeRestart
        )
        guard let barrier else { return true }
        return barrier.wait(until: .now() + max(0, timeout))
    }

    public func closeAndDeletePersistedHistory() {
        _ = close(deletePersistedHistory: true, removeOutputBusState: true, reason: .tabClose)
    }

    private func close(
        deletePersistedHistory: Bool,
        removeOutputBusState: Bool,
        reason: FlushReason
    ) -> SurfaceTerminationBarrier? {
        guard !isClosing else {
            if reason == .tabClose {
                publishesRuntimeHealth = false
            }
            if deletePersistedHistory {
                historyCoordinator.discardAndDeletePersistedHistory()
            }
            switch reason {
            case .appTermination, .runtimeRestart:
                return applicationTerminationBarrier
            case .tabClose:
                return nil
            }
        }
        isClosing = true
        let deferredHistoryState = TerminalDeferredTerminationState()
        let readerClosingSnapshot = readerHandoffState.beginClosing {
            if reason == .appTermination {
                deferredHistoryState.complete(success: true)
            } else {
                DispatchQueue.main.async { [weak self, deferredHistoryState] in
                    guard let self else {
                        deferredHistoryState.complete(success: false)
                        return
                    }
                    self.completeDeferredReaderClose(
                        state: deferredHistoryState,
                        deletePersistedHistory: deletePersistedHistory,
                        emitOutput: !removeOutputBusState
                    )
                }
            }
        }
        removeRestartBanner()
        closeParkingWindowIfNeeded()
        let foregroundPGID = foregroundProcessGroup()
        let pid = childPID
        let foregroundGroup = pid > 0
            ? resolvedForegroundGroupForReap(pid: pid, foregroundPGID: foregroundPGID)
            : nil
        childReapForegroundGroup = foregroundGroup
        lastCapturedForegroundGroup = nil
        inputPump?.stop(reason: .processExited)
        readSource?.cancel()
        readSource = nil
        if reason == .appTermination || reason == .runtimeRestart {
            // Reader and writer both use the lease lock, so app termination can
            // close the PTY synchronously without waiting for a reader that may
            // itself be blocked on the main-actor handoff.
            masterFDLease?.close()
        }
        appendClosingReaderBatches(
            readerClosingSnapshot.batches,
            emitOutput: !removeOutputBusState
        )
        let historyBarrier: SurfaceTerminationBarrier?
        if deletePersistedHistory {
            historyCoordinator.discardAndDeletePersistedHistory()
            if !readerClosingSnapshot.awaitsPublication {
                deferredHistoryState.complete(success: true)
            }
            historyBarrier = nil
        } else if readerClosingSnapshot.awaitsPublication {
            if reason == .appTermination {
                historyBarrier = deferredHistoryState.applicationTerminationBarrier {
                    [weak self] deadline in
                    guard let self else { return false }
                    return self.completeDeferredReaderCloseForApplicationTermination(
                        deadline: deadline
                    )
                }
            } else {
                historyBarrier = deferredHistoryState.barrier()
            }
        } else {
            deferredHistoryState.complete(success: true)
            historyBarrier = historyCoordinator.flushBarrier(
                finalizing: true,
                retryTimeout: 2
            )
        }
        if pid > 0 {
            processAlive = false
            terminalDeadReason = terminalDeadReason ?? "closed"
            terminalLog.info("terminal.close surface=\(self.descriptor.id.value.uuidString, privacy: .public) pid=\(pid, privacy: .public)")
            if reason == .tabClose {
                beginBoundedChildReap(
                    pid: pid,
                    foregroundPGID: foregroundPGID,
                    sendInitialHangup: true
                )
            }
        }
        // Normal close leaves fd disposal to the read-source cancel handler.
        // App termination already closed the lock-serialized lease above.
        masterFD = -1
        ghosttyView.closeSurface()
        if removeOutputBusState {
            outputBus.remove(surfaceId: descriptor.id)
        }
        publishRuntimeHealth()
        if reason == .tabClose {
            publishesRuntimeHealth = false
        }
        if reason == .appTermination || reason == .runtimeRestart {
            if reason == .runtimeRestart {
                runtimeRestartRequiredHistoryBarrier = historyBarrier
            }
            return runtimeDispositionBarrier(
                pid: pid,
                historyBarrier: historyBarrier
            )
        }
        return nil
    }

    private func appendClosingReaderBatches(
        _ batches: [TerminalReaderHandoffState.Batch],
        emitOutput: Bool
    ) {
        for batch in batches where !batch.data.isEmpty {
            maxPTYReadBatchBytesObserved = max(
                maxPTYReadBatchBytesObserved,
                batch.data.count
            )
            maxPTYReadCallsObserved = max(
                maxPTYReadCallsObserved,
                batch.readCalls
            )
            historyCoordinator.enqueue(batch.data)
            recordOutputTelemetry(bytes: batch.data.count)
            lastOutputAt = Date()
            descriptor.hasUnreadActivity = true
            if emitOutput {
                outputBus.emit(descriptor.id, batch.data)
            }
        }
    }

    private func completeDeferredReaderClose(
        state: TerminalDeferredTerminationState,
        deletePersistedHistory: Bool,
        emitOutput: Bool
    ) {
        let batches = readerHandoffState.drainPublished()
        guard !deletePersistedHistory else {
            state.complete(success: true)
            return
        }
        appendClosingReaderBatches(batches, emitOutput: emitOutput)
        let historyBarrier = historyCoordinator.flushBarrier(
            finalizing: true,
            retryTimeout: 2
        )
        DispatchQueue.global(qos: .utility).async {
            state.complete(success: historyBarrier.wait(until: .distantFuture))
        }
    }

    private func completeDeferredReaderCloseForApplicationTermination(
        deadline: DispatchTime
    ) -> Bool {
        appendClosingReaderBatches(
            readerHandoffState.drainPublished(),
            emitOutput: false
        )
        return historyCoordinator.flushBarrier(
            finalizing: true,
            retryTimeout: 2
        ).wait(until: deadline)
    }

    private func runtimeDispositionBarrier(
        pid: pid_t,
        historyBarrier: SurfaceTerminationBarrier?
    ) -> SurfaceTerminationBarrier? {
        var barriers: [SurfaceTerminationBarrier] = []
        if let applicationTerminationBarrier {
            barriers.append(applicationTerminationBarrier)
        }
        if let historyBarrier {
            barriers.append(historyBarrier)
        }
        if applicationTerminationBarrier == nil, pid > 0 {
            if let runtimeDispositionBarrierFactoryForTesting {
                barriers.append(runtimeDispositionBarrierFactoryForTesting(pid))
            } else {
                let work = TerminalPTYProcessRuntime.beginApplicationTerminationDisposition(
                    pid: pid,
                    foregroundGroup: childReapForegroundGroup
                )
                barriers.append(SurfaceTerminationBarrier(
                    groups: [work.group],
                    completionChecks: [work.succeeded]
                ))
            }
        }
        guard !barriers.isEmpty else { return nil }
        let barrier = SurfaceTerminationBarrier(combining: barriers)
        applicationTerminationBarrier = barrier
        return barrier
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
        // The production coordinator completes ready-state flushes on its serial
        // writer queue. Never pump AppKit here: nested RunLoop execution cannot
        // drain Swift MainActor tasks and permits unrelated UI reentrancy.
        _ = historyCoordinator.flushBarrier().wait(until: .now() + 2)
    }

    public func flushPersistedHistoryBarrier() -> SurfaceTerminationBarrier {
        historyCoordinator.flushBarrier()
    }

    public func flushPersistedHistoryAsync(timeout: TimeInterval = 2) async -> Bool {
        await historyCoordinator.flushBarrier().waitAsync(
            until: .now() + max(0, timeout)
        )
    }

    /// Drops pending history and deletes durable chunks under the surface ID.
    /// In-flight writer items drain first; delete runs last on the same queue so
    /// a blocked pre-clear insert cannot repopulate after clear_history.
    public func clearPersistedHistory() {
        historyCoordinator.clearPersistedHistory()
    }

    public func readPersistedHistory(
        beforeChunkID: Int64?,
        maxBytes: Int,
        timeout: TimeInterval = 2
    ) async throws -> TerminalOutputWindow {
        try await historyCoordinator.readPersistedWindow(
            beforeChunkID: beforeChunkID,
            maxBytes: maxBytes,
            timeout: timeout
        )
    }

    private func enqueueHistory(_ data: Data) {
        guard !isClosing else { return }
        historyCoordinator.enqueue(data)
    }

    /// Exports the full scrollback (including ANSI sequences when format is
    /// `.ansi`, or raw text when format is `.txt`) to `url`.
    /// The caller is responsible for presenting the NSSavePanel and providing
    /// the destination URL.
    public func saveOutput(format: TerminalExportFormat, to url: URL) throws {
        // Flush deferred renderer events (PERF-136) so the exported scrollback
        // reflects all output, not just what was eagerly fed.
        ensureRendererCurrent()
        let content: String
        switch format {
        case .ansi:
            content = renderer.ansiSnapshot(includeScrollback: true)
        case .txt:
            content = renderer.snapshot().string
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func confirmUnsafeTerminalInput(_ text: String) {
        let lineCount = PasteGuard.confirmationLineCount(for: text)
        let lineLabel = lineCount == 1 ? "1 line" : "\(lineCount) lines"
        let alert = NSAlert()
        alert.messageText = "Paste \(lineLabel) into the terminal?"
        alert.informativeText = "The pasted text spans multiple lines or contains control characters and will run immediately."
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        let onResponse: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let data = text.data(using: .utf8) else { return }
            _ = self?.writeToPTY(data)
        }
        if let window = ghosttyView.window {
            alert.beginSheetModal(for: window, completionHandler: onResponse)
        } else {
            onResponse(alert.runModal())
        }
    }

    public func snapshot() -> [String: String] {
        ["cwd": descriptor.metadata["cwd"] ?? "", "scrollback_chars": String(readText().count)]
    }
}
