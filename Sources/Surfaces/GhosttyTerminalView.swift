import AppKit
import CoreModel
import Darwin
import DesignSystemKit
import GhosttyKit
import Persistence
import QuartzCore

private final class RemoteCodeGhosttyIOContext {
    weak var view: GhosttyTerminalView?
}

final class GhosttySurfaceSlot {
    enum State: Equatable {
        case empty
        case creating(UInt64)
        case live(UInt64)
        case closing(UInt64)
        case closed(UInt64)
    }

    private(set) var state: State = .empty
    private(set) var generation: UInt64 = 0
    private var surface: ghostty_surface_t?

    var isLive: Bool {
        guard case .live = state else { return false }
        return surface != nil
    }

    func beginCreate() -> UInt64? {
        guard surface == nil else { return nil }
        switch state {
        case .creating, .closing:
            return nil
        case .empty, .live, .closed:
            generation &+= 1
            state = .creating(generation)
            return generation
        }
    }

    func install(_ newSurface: ghostty_surface_t, generation expectedGeneration: UInt64) -> Bool {
        guard case .creating(let activeGeneration) = state,
              activeGeneration == expectedGeneration else { return false }
        surface = newSurface
        state = .live(expectedGeneration)
        return true
    }

    func cancelCreate(generation expectedGeneration: UInt64) {
        guard case .creating(let activeGeneration) = state,
              activeGeneration == expectedGeneration else { return }
        state = .closed(expectedGeneration)
    }

    func liveSurface() -> ghostty_surface_t? {
        guard case .live = state else { return nil }
        return surface
    }

    func removeForClose() -> ghostty_surface_t? {
        guard let current = surface else {
            state = .closed(generation)
            return nil
        }
        surface = nil
        state = .closing(generation)
        return current
    }

    func markClosed() {
        state = .closed(generation)
    }
}

private func ghosttyTerminalIOWriteCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<CChar>?,
    _ length: UInt
) {
    guard let userdata, let bytes, length > 0 else { return }
    let context = Unmanaged<RemoteCodeGhosttyIOContext>.fromOpaque(userdata).takeUnretainedValue()
    let data = Data(bytes: bytes, count: Int(length))
    DispatchQueue.main.async { [weak context] in
        context?.view?.writeInputData(data)
    }
}

private func ghosttyRuntimeReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    return false
}

// MARK: - Action effect mapper

/// Classifies a raw string token from a Ghostty open-url action into the
/// appropriate host action. Pure value type: nonisolated, no AppKit imports.
///
/// Rules:
/// - `http://` or `https://` → `.url`  (open in default browser)
/// - `file://` → `.filePath` (extract POSIX path, route to FilePreview)
/// - Starts with `/` → `.filePath`     (absolute POSIX path, route to FilePreview)
/// - Anything else → `.none`
///
/// Relative paths (e.g. `./foo`) are intentionally `.none`: Ghostty resolves
/// paths against the terminal cwd before firing `GHOSTTY_ACTION_OPEN_URL`, so
/// a relative-path token is not a genuine Ghostty-generated file reference.
enum TerminalLinkClassifier {
    enum Result {
        case url(URL)
        case filePath(String)
        case none
    }

    nonisolated static func classify(_ raw: String) -> Result {
        guard !raw.isEmpty else { return .none }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            guard let url = URL(string: raw) else { return .none }
            return .url(url)
        }
        if raw.hasPrefix("file://") {
            guard let url = URL(string: raw),
                  let path = url.path.isEmpty ? nil : Optional(url.path) else { return .none }
            return .filePath(path)
        }
        if raw.hasPrefix("/") {
            return .filePath(raw)
        }
        return .none
    }
}

/// The side-effect a Ghostty surface action should produce in the host app.
/// Pure value type: no @MainActor, no AppKit imports needed to construct it.
enum GhosttyActionEffect {
    /// OSC 2 / escape-set title — update the tab label.
    case setTitle(String)
    /// CSS cursor name from the terminal program — update the system cursor shape.
    case mouseShape(ghostty_action_mouse_shape_e)
    /// Cmd+click on a http/https URL — open in the default browser.
    case openURL(URL)
    /// Cmd+click on an absolute file path or file:// URL — route to FilePreview.
    case openFilePath(String)
}

/// Pure mapper from a raw Ghostty action struct to an optional host effect.
/// `nonisolated` so it can be called from the runtime action_cb off main.
/// Returns `nil` for actions the host does not need to handle.
enum GhosttyActionMapper {
    nonisolated static func map(_ action: ghostty_action_s) -> GhosttyActionEffect? {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE:
            let title = action.action.set_title.title.map { String(cString: $0) } ?? ""
            return .setTitle(title)
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            return .mouseShape(action.action.mouse_shape)
        case GHOSTTY_ACTION_OPEN_URL:
            guard let ptr = action.action.open_url.url else { return nil }
            let raw = String(cString: ptr)
            switch TerminalLinkClassifier.classify(raw) {
            case .url(let url):
                return .openURL(url)
            case .filePath(let path):
                return .openFilePath(path)
            case .none:
                return nil
            }
        default:
            return nil
        }
    }
}

/// Pure search/match layer for the terminal find bar (Cmd+F). Operates on a
/// plain-text snapshot of the terminal scrollback (read via GHOSTTY_POINT_SCREEN)
/// so the logic is testable without a live Ghostty surface or window server.
/// GhosttyKit exposes no `set_selection`/`scroll_to_point` API to embedders, so
/// the find bar drives match *location + navigation* over this snapshot (match
/// count and a current index that wraps); it cannot paint an in-terminal
/// highlight. Keeping the matching here keeps that boundary explicit and tested.
enum TerminalScrollbackSearch {
    /// All match ranges of `query` in `text`, case-insensitive, in document
    /// order, non-overlapping. Empty query returns no matches.
    static func matchRanges(in text: String, query: String) -> [Range<String.Index>] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let found = text.range(of: query, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            ranges.append(found)
            // Advance by at least one character so overlapping/zero-width cases
            // cannot loop forever; `found.lowerBound < found.upperBound` always
            // holds for a non-empty query, so we move past the start of the match.
            searchStart = found.upperBound > found.lowerBound ? found.upperBound : text.index(after: found.lowerBound)
        }
        return ranges
    }

    /// Next match index for prev/next navigation. `current == nil` means no match
    /// is selected yet: forward starts at 0, backward starts at the last match.
    /// With `wrap` true, stepping past either end wraps around. Returns nil when
    /// there are no matches.
    static func nextIndex(current: Int?, count: Int, forward: Bool, wrap: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return forward ? 0 : count - 1 }
        let candidate = forward ? current + 1 : current - 1
        if candidate < 0 {
            return wrap ? count - 1 : 0
        }
        if candidate >= count {
            return wrap ? 0 : count - 1
        }
        return candidate
    }
}

/// Per-workspace font zoom persistence helper.
///
/// Zoom is tracked as an integer step delta where each step equals 1 pt
/// (matching Ghostty's `increase_font_size:1` / `decrease_font_size:1`
/// binding actions). Storing the delta — rather than an absolute pt size —
/// avoids needing to know the user's configured base font size at restore
/// time: the app simply replays the same number of zoom steps.
///
/// All members are `nonisolated` so this can be tested without @MainActor.
enum FontZoomLevel {
    /// Inclusive lower bound on stored steps (20-pt reduction is an extreme
    /// floor; below this text becomes invisible on any sane base font size).
    static let minSteps: Int = -20
    /// Inclusive upper bound on stored steps (40-pt increase is generous;
    /// above this the font grid no longer fits usable terminal content).
    static let maxSteps: Int = 40

    /// Clamp `steps` to the safe `[minSteps, maxSteps]` range.
    nonisolated static func clamp(_ steps: Int) -> Int {
        min(maxSteps, max(minSteps, steps))
    }

    /// Serialize a (pre-clamped) step delta to a KV-storable string.
    nonisolated static func serialize(_ steps: Int) -> String {
        String(clamp(steps))
    }

    /// Deserialize a KV string back to a clamped step delta.
    /// Returns `nil` when the string is empty or non-numeric — the caller
    /// should treat `nil` as \"no stored zoom\" (delta 0).
    nonisolated static func deserialize(_ raw: String) -> Int? {
        guard !raw.isEmpty, let parsed = Int(raw) else { return nil }
        return clamp(parsed)
    }
}

/// Pure helper that formats a human-readable scrollback position label.
///
/// Rules (matches common terminal conventions):
/// - `offset == 0` (at bottom, no lines above viewport): returns "Bottom"
/// - `offset >= total` (at top, cannot scroll further): returns "Top"
/// - Otherwise: "\(offset) lines from bottom" or, when total > 0, the percent
///   distance from the bottom expressed as 0-100%.
///
/// `offset` = lines scrolled above the bottom (0 = bottom).
/// `total`  = total scrollback line count (> 0 for a meaningful percent).
/// Both must be >= 0; negative inputs are treated as 0.
enum ScrollbackPositionLabel {
    /// Returns a display string for the current scrollback position.
    /// Pure: nonisolated, no AppKit.
    nonisolated static func label(offset: Int, total: Int) -> String {
        let safeOffset = max(0, offset)
        let safeTotal  = max(0, total)
        if safeOffset == 0 { return "Bottom" }
        if safeTotal > 0, safeOffset >= safeTotal { return "Top" }
        if safeTotal > 0 {
            let pct = Int(Double(safeOffset) / Double(safeTotal) * 100.0)
            let clamped = min(100, max(1, pct))
            return "\(clamped)% from bottom"
        }
        return "\(safeOffset) lines from bottom"
    }
}

/// Maps a keyboard event (keyCode + modifiers) to the Ghostty binding-action
/// string for scrollback navigation, or nil if the event is not a scroll shortcut.
///
/// Handled bindings:
///   Shift+Page Up   -> "scroll_page_up"
///   Shift+Page Down -> "scroll_page_down"
///   Cmd+Home        -> "scroll_to_top"
///   Cmd+End         -> "scroll_to_bottom"
///
/// Pure: nonisolated static, no AppKit import dependency beyond NSEvent types.
/// Tested without a live surface or window server.
enum ScrollbackKeyAction {
    // macOS virtual key codes for navigation keys (hardware-independent).
    private static let keyCodePageUp:   UInt16 = 116
    private static let keyCodePageDown: UInt16 = 121
    private static let keyCodeHome:     UInt16 = 115
    private static let keyCodeEnd:      UInt16 = 119

    /// Returns the Ghostty binding-action string, or nil if not a scroll shortcut.
    nonisolated static func action(for keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        let device = modifiers.intersection(.deviceIndependentFlagsMask)
        switch keyCode {
        case keyCodePageUp   where device == .shift:  return "scroll_page_up"
        case keyCodePageDown where device == .shift:  return "scroll_page_down"
        case keyCodeHome     where device == .command: return "scroll_to_top"
        case keyCodeEnd      where device == .command: return "scroll_to_bottom"
        default: return nil
        }
    }
}

enum GhosttyTerminalKeyInput {
    static func text(for event: NSEvent) -> String? {
        guard let text = event.characters, !text.isEmpty else { return nil }
        if text.count == 1, let scalar = text.unicodeScalars.first {
            if isControlCharacter(scalar) {
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control) {
                    return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
                        ?? event.charactersIgnoringModifiers
                }
                return nil
            }
            if isPrivateUseArea(scalar) {
                return nil
            }
        }
        return text
    }

    static func unshiftedCodepoint(from event: NSEvent) -> UInt32 {
        guard let text = event.characters(byApplyingModifiers: [])
                ?? event.charactersIgnoringModifiers
                ?? event.characters,
              let scalar = text.unicodeScalars.first else {
            return 0
        }
        return scalar.value
    }

    private static func isControlCharacter(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }

    private static func isPrivateUseArea(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 0xF700 && scalar.value <= 0xF8FF
    }
}

private final class RemoteCodeGhosttyRuntime {
    static let shared = RemoteCodeGhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private let tickCoalescer = TerminalTickCoalescer()

    private init() {
        initialize()
    }

    deinit {
        if let app {
            ghostty_app_free(app)
        }
        if let config {
            ghostty_config_free(config)
        }
    }

    private func initialize() {
        configureGhosttyEnvironment()
        unsetenv("NO_COLOR")

        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard result == GHOSTTY_SUCCESS else {
            NSLog("RemoteCode Ghostty init failed: %d", result)
            return
        }

        guard let primaryConfig = makeConfig(loadUserFiles: true) else {
            NSLog("RemoteCode Ghostty config allocation failed")
            return
        }

        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = true
        runtimeConfig.wakeup_cb = { _ in
            RemoteCodeGhosttyRuntime.shared.scheduleTick()
        }
        runtimeConfig.action_cb = { _, target, action in
            // Resolve the view from the surface's userdata. The view is retained
            // by the window hierarchy for its lifetime; the unretained cast is safe
            // because surfaceClosed prevents action delivery after free.
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let ud = ghostty_surface_userdata(target.target.surface),
                  let effect = GhosttyActionMapper.map(action) else {
                return true
            }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(ud).takeUnretainedValue()
            DispatchQueue.main.async {
                view.applyActionEffect(effect)
            }
            return true
        }
        runtimeConfig.read_clipboard_cb = ghosttyRuntimeReadClipboardCallback
        runtimeConfig.write_clipboard_cb = { _, _, content, length, _ in
            guard let content, length > 0 else { return }
            let items = UnsafeBufferPointer(start: content, count: Int(length))
            var fallback: String?
            for item in items {
                guard let data = item.data else { continue }
                let value = String(cString: data)
                if let mime = item.mime.map({ String(cString: $0) }),
                   mime.hasPrefix("text/plain") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    return
                }
                if fallback == nil {
                    fallback = value
                }
            }
            if let fallback {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fallback, forType: .string)
            }
        }
        runtimeConfig.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtimeConfig.close_surface_cb = { _, _ in }

        if let app = ghostty_app_new(&runtimeConfig, primaryConfig) {
            self.app = app
            self.config = primaryConfig
            return
        }

        NSLog("RemoteCode Ghostty app allocation failed with user config: %@", diagnosticsSummary(for: primaryConfig))
        ghostty_config_free(primaryConfig)

        guard let fallbackConfig = makeConfig(loadUserFiles: false) else {
            NSLog("RemoteCode Ghostty fallback config allocation failed")
            return
        }
        guard let fallbackApp = ghostty_app_new(&runtimeConfig, fallbackConfig) else {
            NSLog("RemoteCode Ghostty fallback app allocation failed")
            ghostty_config_free(fallbackConfig)
            return
        }

        self.app = fallbackApp
        self.config = fallbackConfig
    }

    private func makeConfig(loadUserFiles: Bool) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        if loadUserFiles {
            ghostty_config_load_default_files(config)
            ghostty_config_load_recursive_files(config)
        }
        loadInlineConfig(
            """
            macos-background-from-layer = true
            macos-titlebar-proxy-icon = hidden
            shell-integration = none
            scrollback-limit = 2000000
            window-padding-x = 0
            window-padding-y = 0
            keybind = super+d=unbind
            keybind = super+shift+d=unbind
            keybind = super+w=unbind
            keybind = super+alt+w=unbind
            keybind = super+shift+w=unbind
            """,
            into: config,
            prefix: "remote-code"
        )
        ghostty_config_finalize(config)
        return config
    }

    private func loadInlineConfig(_ text: String, into config: ghostty_config_t, prefix: String) {
        text.withCString { ptr in
            prefix.withCString { prefixPtr in
                ghostty_config_load_string(config, ptr, UInt(strlen(ptr)), prefixPtr)
            }
        }
    }

    private func configureGhosttyEnvironment() {
        let fileManager = FileManager.default
        let bundledGhosttyURL = Self.bundledGhosttyResourcesURL(fileManager: fileManager)
        let ghosttyAppResources = "/Applications/Ghostty.app/Contents/Resources/ghostty"

        if getenv("GHOSTTY_RESOURCES_DIR") == nil {
            if let bundledGhosttyURL,
               fileManager.fileExists(atPath: bundledGhosttyURL.appendingPathComponent("themes").path) {
                setenv("GHOSTTY_RESOURCES_DIR", bundledGhosttyURL.path, 1)
            } else if fileManager.fileExists(atPath: ghosttyAppResources) {
                setenv("GHOSTTY_RESOURCES_DIR", ghosttyAppResources, 1)
            }
        }

        if let resourcesDir = getenv("GHOSTTY_RESOURCES_DIR").map({ String(cString: $0) }) {
            let resourcesURL = URL(fileURLWithPath: resourcesDir)
            appendEnvPathIfMissing(
                "XDG_DATA_DIRS",
                path: resourcesURL.deletingLastPathComponent().path,
                defaultValue: "/usr/local/share:/usr/share"
            )
            setenv("TERMINFO", resourcesURL.appendingPathComponent("terminfo").path, 0)
        }

        if getenv("TERM") == nil {
            setenv("TERM", "xterm-256color", 1)
        }
        if getenv("COLORTERM") == nil {
            setenv("COLORTERM", "truecolor", 1)
        }
        if getenv("TERM_PROGRAM") == nil {
            setenv("TERM_PROGRAM", "ghostty", 1)
        }
    }

    private static func bundledGhosttyResourcesURL(fileManager: FileManager) -> URL? {
        let candidates: [URL] = [
            Bundle.main.resourceURL?
                .appendingPathComponent("RemoteCode_Surfaces.bundle")
                .appendingPathComponent("ghostty"),
            Bundle.main.bundleURL
                .appendingPathComponent("RemoteCode_Surfaces.bundle")
                .appendingPathComponent("ghostty"),
            URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
                .appendingPathComponent("RemoteCode_Surfaces.bundle")
                .appendingPathComponent("ghostty")
        ].compactMap { $0 }

        return candidates.first { url in
            fileManager.fileExists(atPath: url.appendingPathComponent("themes").path)
        }
    }

    private func appendEnvPathIfMissing(_ key: String, path: String, defaultValue: String? = nil) {
        guard !path.isEmpty else { return }
        let current = getenv(key).map { String(cString: $0) } ?? defaultValue ?? ""
        let parts = current.split(separator: ":").map(String.init)
        guard !parts.contains(path) else { return }
        let next = current.isEmpty ? path : "\(path):\(current)"
        setenv(key, next, 1)
    }

    private func scheduleTick() {
        guard tickCoalescer.trySchedule() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tickCoalescer.complete()
            if let app = self.app {
                ghostty_app_tick(app)
            }
        }
    }

    func diagnosticsSummary() -> String {
        guard let config else { return "config=nil" }
        return diagnosticsSummary(for: config)
    }

    /// Read the resolved ANSI palette (indices 0-15) from the active Ghostty
    /// config and return it as an `ANSIThemeColors`.
    ///
    /// Uses `ghostty_config_get` with key `"palette"` to obtain the full 256-entry
    /// palette struct, then extracts only indices 0-15 (the SGR color range that
    /// `ANSIRenderer` uses). Returns `nil` when no config is loaded.
    ///
    /// WHY: `ANSIRenderer` is initialised with `themeColors: ANSIThemeColors?`.
    /// Without this extraction the renderer always falls back to its hardcoded
    /// defaults, producing a different visual palette than the Ghostty-rendered
    /// Mac surface — causing color drift in the iOS mirror.
    func resolvedANSIThemeColors() -> ANSIThemeColors? {
        guard let config else { return nil }
        var palette = ghostty_config_palette_s()
        let key = "palette"
        guard ghostty_config_get(config, &palette, key, UInt(key.lengthOfBytes(using: .utf8))) else {
            return nil
        }
        // ghostty_config_palette_s.colors is a C fixed-size array [256] which Swift
        // imports as a tuple. Access it safely via raw pointer to avoid Swift's
        // tuple-index limitations.
        let entries: [(index: Int, r: UInt8, g: UInt8, b: UInt8)] = withUnsafeBytes(of: palette.colors) { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: ghostty_config_color_s.self)
            return (0..<16).map { i in
                let c = base[i]
                return (index: i, r: c.r, g: c.g, b: c.b)
            }
        }
        return ANSIRenderer.ansiThemeColors(from: entries)
    }

    private func diagnosticsSummary(for config: ghostty_config_t) -> String {
        let count = Int(ghostty_config_diagnostics_count(config))
        guard count > 0 else { return "diagnostics=0" }
        var parts: [String] = []
        for index in 0..<min(count, 5) {
            let diagnostic = ghostty_config_get_diagnostic(config, UInt32(index))
            let message = diagnostic.message.map { String(cString: $0) } ?? "(null)"
            parts.append("[\(index)] \(message)")
        }
        return "diagnostics=\(count) " + parts.joined(separator: " ")
    }
}

@MainActor
final class GhosttyTerminalView: NSView {
    var onInputData: ((Data) -> Void)?
    var onTerminalSizeChange: ((TerminalViewportSize) -> Void)?
    /// Called on the main thread when the terminal program changes its title (OSC 2).
    var onTitleChange: ((String) -> Void)?
    /// Called on the main thread when the user Cmd+clicks an absolute file path
    /// (or file:// URL) in the terminal. The owning surface routes this to
    /// FilePreview / Diff. When nil, file-path Cmd+clicks are silently ignored.
    var onCmdClickFilePath: ((String) -> Void)?

    /// Called when a plain-text drag payload requires user confirmation before
    /// being sent to the PTY (same semantics as `TerminalTextView.onPasteNeedsConfirm`:
    /// multi-line or control-character content). The receiver should present a
    /// confirmation sheet and, on approval, call `writeInputData` with the
    /// UTF-8-encoded string. When nil, the text is sent without confirmation.
    var onPlainTextDragNeedsConfirm: ((String) -> Void)?

    /// Called when a Cmd+V paste payload requires user confirmation before
    /// being sent to the PTY (multi-line or control-character content).
    /// The receiver should present a confirmation sheet and, on approval, call
    /// `writeInputData` with the UTF-8-encoded string. When nil, the text is
    /// sent without confirmation (same fall-through as the drag path).
    var onPasteNeedsConfirm: ((String) -> Void)?

    /// Injected by the owning TerminalSurface to persist font zoom per workspace.
    /// When nil, zoom changes are session-only (not persisted).
    var fontZoomStore: (any SettingsWriteRepository)?
    /// KV key suffix that scopes zoom persistence to the workspace.
    /// Set to the workspace UUID string before the surface is first shown.
    var fontZoomWorkspaceID: String?

    private let surfaceSlot = GhosttySurfaceSlot()
    private let ioContext = RemoteCodeGhosttyIOContext()
    /// Retained reference that pins ioContext for the Ghostty IO-thread lifetime.
    /// Set once in setup(), released in deinit after ghostty_surface_free returns
    /// so the raw userdata pointer passed to Ghostty can never dangle.
    private var ioContextRetain: Unmanaged<RemoteCodeGhosttyIOContext>?
    /// True while the IO-context retain is held; false after deinit releases it.
    /// Exposed for lifecycle tests only — do not use in production code paths.
    var ioContextIsPinned: Bool { ioContextRetain != nil }
    private var pendingOutput = Data()
    private var outputFlushScheduled = false
    private var lastPixelSize = NSSize(width: 0, height: 0)
    private var lastScale = NSSize(width: 0, height: 0)
    private var renderGeneration = 0
    private var visibleInUI = true
    /// Accumulated font zoom step delta for this surface (1 step = 1 pt).
    /// Persisted to and restored from the KV settings store keyed by workspace.
    private var zoomDelta: Int = 0
    /// Latched true by closeSurface() so a queued AppKit pass (layout/backing/move)
    /// cannot resurrect a freed surface via ensureSurface() on a view that is being
    /// torn down — that would bind a fresh ghostty surface (renderer + IO threads)
    /// to a dying view (use-after-free). Cleared only by the explicit reuse path
    /// resetSurfaceOutput().
    private var surfaceClosed = false
    private var dropHighlightLayer: CALayer?
    private var mouseTrackingArea: NSTrackingArea?
    /// In-progress IME composition (marked text). Empty when not composing.
    private var markedText = ""
    /// Count of bytes discarded from the front of `pendingOutput` on overflow
    /// while truly unrenderable (no live surface). Should stay 0 in normal
    /// operation; exposed via runtime health so tests/telemetry catch the drop
    /// path being hit (QA-006, guards PERF-009).
    internal(set) var droppedOutputBytes = 0

    /// Find-in-scrollback (Cmd+F) overlay state. The bar is lazily built on first
    /// open. `findMatchCount`/`findCurrentMatch` are the navigation cursor over
    /// the last computed match set; they have no effect on rendering because
    /// GhosttyKit exposes no selection-set/scroll-to API (see
    /// `TerminalScrollbackSearch`).
    private var findBar: NSView?
    private var findField: NSTextField?
    private var findCountLabel: NSTextField?
    private var findMatchCount = 0
    private var findCurrentMatch: Int?

    /// Scrollback position indicator overlay (bottom-right corner). Lazily created
    /// on first `updateScrollbackPosition` call. Hidden when at the bottom.
    private var scrollbackIndicator: NSTextField?

    /// The most recent OSC 2 / SET_TITLE value received from the running program.
    /// Used to form the VoiceOver accessibility label "Terminal — <title>".
    /// Empty string means no title has been set yet; the label falls back to "Terminal".
    private var currentTitle: String = ""

    /// Transient font-zoom HUD overlay (bottom-left corner). Lazily created on
    /// first zoom action and auto-hidden after a brief delay.
    private var fontZoomHUD: NSTextField?
    /// Generation counter so only the most-recent zoom action dismisses the HUD.
    private var fontZoomHUDGeneration = 0

    /// Timestamp of the last VoiceOver `valueChanged` notification. Used to
    /// coalesce rapid-output notifications so VO is not spammed every 20ms.
    private var lastVOValueChangedAt: TimeInterval = 0
    /// Minimum interval between VoiceOver `valueChanged` notifications (seconds).
    private static let voValueChangedInterval: TimeInterval = 0.5

    private static let immediateOutputFlushBytes = 64 * 1024
    private static let maxPendingOutputBytes = 1024 * 1024
    private static let outputFlushDelay: TimeInterval = 0.02

    // MARK: - Theme palette seam

    /// Return the 16-entry ANSI palette resolved from the active Ghostty theme
    /// config, or `nil` when no config is loaded (e.g. Ghostty failed to init).
    ///
    /// Callers (e.g. `TerminalSurface`) pass the result to
    /// `ANSIRenderer(themeColors:)` so the mirror ANSI snapshot uses the same
    /// colors the Mac Ghostty surface renders — eliminating cross-device color drift.
    ///
    /// WHY: `TerminalSurface` creates its `ANSIRenderer` without `themeColors`,
    /// so snapshot ANSI always uses the hardcoded default palette regardless of
    /// the user's configured Ghostty theme. This accessor exposes the resolved
    /// palette so `TerminalSurface` (or any other caller) can pass it at init time.
    static func resolvedANSIThemeColors() -> ANSIThemeColors? {
        RemoteCodeGhosttyRuntime.shared.resolvedANSIThemeColors()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // Pull the raw C pointer out of the slot now (while self is still valid).
        // removeForClose() zeroes surfaceSlot.surface, so the pointer can only
        // come out of here once -- no double-free is possible.
        let surfaceToFree: ghostty_surface_t? = surfaceSlot.removeForClose()
        surfaceSlot.markClosed()
        // Capture ioContextRetain for release after ghostty_surface_free returns.
        // Ghostty's IO thread may call io_write_cb at any time up to and including
        // during ghostty_surface_free; releasing before the free completes would
        // leave a dangling userdata pointer on the IO thread (use-after-free).
        let pinnedContext = ioContextRetain
        // ghostty_surface_free must be called on the main thread.
        // Capture only the value-type pointer; never capture self in a deinit closure.
        if let ptr = surfaceToFree {
            if Thread.isMainThread {
                ghostty_surface_free(ptr)
                // Safe to release now: ghostty_surface_free has returned, so
                // Ghostty will not dereference io_write_userdata again.
                pinnedContext?.release()
            } else {
                DispatchQueue.main.async {
                    ghostty_surface_free(ptr)
                    // Same guarantee: release only after free completes.
                    pinnedContext?.release()
                }
            }
        } else {
            // No surface was ever created (or it was already freed by closeSurface).
            // Ghostty has no live reference to io_write_userdata, so release is safe.
            pinnedContext?.release()
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    // Expose the live viewport text as the accessibility value so XCUITest /
    // VoiceOver can read what the terminal currently shows (QA-001).
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityValue() -> Any? { readViewportText() }
    /// "Terminal — <title>" when an OSC title is set, otherwise "Terminal".
    /// VoiceOver reads this on focus so users know which tab they landed on.
    override func accessibilityLabel() -> String? {
        currentTitle.isEmpty ? "Terminal" : "Terminal \u{2014} \(currentTitle)"
    }

    override func makeBackingLayer() -> CALayer {
        guard Self.nativeRendererEnabled else { return CALayer() }
        let metalLayer = CAMetalLayer()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = false
        return metalLayer
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true
        ioContext.view = self
        // Ghostty's IO thread may invoke io_write_cb (which dereferences this
        // ioContext via its raw userdata pointer) at any time, including around
        // surface free / view dealloc with no quiescence guarantee. Pin the tiny
        // context until ghostty_surface_free returns so that pointer can never
        // dangle into freed memory (use-after-free on a ghostty thread). The weak
        // `view` inside it goes nil on dealloc, so the callback safely no-ops.
        // The retained ref is released in deinit after ghostty_surface_free returns.
        ioContextRetain = Unmanaged.passRetained(ioContext)
        // Accept both file-URL drops (paths) and plain-text drops (literal text).
        // Plain .string is added here so dragging a selection from another app or
        // from a text editor inserts the text into the terminal rather than being
        // silently rejected.
        registerForDraggedTypes(DroppedFilePaths.pasteboardTypes + [.string])
    }

    /// AppKit calls this *before* our `window` actually changes. A terminal moved
    /// to a split pane or a new window is transiently windowless during the AppKit
    /// reparent (the workspace rebuild removes the subtree from its window before
    /// re-adding it): the CAMetalLayer loses its drawable while Ghostty's renderer
    /// (an internal display link) keeps running. Drawing into a windowless layer
    /// starves `nextDrawable` — the terminal "stops updating", and the held GPU
    /// drawable can stall the WindowServer (whole-system freeze). Suspend Ghostty's
    /// renderer here, *before* the window is torn away; `syncOcclusion()` re-enables
    /// it once the view is reattached to an on-screen window. Mirrors cmux, which
    /// sets occlusion off before reparenting a surface.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil, let surface = surfaceSlot.liveSurface() else { return }
        ghostty_surface_set_occlusion(surface, false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            renderGeneration &+= 1
        }
        observeWindowOcclusion(window)
        ensureSurface()
        updateGhosttySize(force: true)
        updateFocus()
        // Re-evaluate whether Ghostty may render now that the window changed: on
        // reattach to an on-screen window this resumes the renderer; on detach it
        // keeps it suspended (complements viewWillMove).
        syncOcclusion()
    }

    /// Observe per-window notifications. Occlusion: rendering is gated off while
    /// the window is off screen (see `isRenderable`), so on return to screen we
    /// redraw the current state (else a stale frame shows). Screen change: the
    /// surface's display id must follow the window across monitors, otherwise
    /// Ghostty renders against the wrong display's refresh/color profile.
    private func observeWindowOcclusion(_ window: NSWindow?) {
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        guard let window else { return }
        center.addObserver(self, selector: #selector(windowOcclusionDidChange),
                           name: NSWindow.didChangeOcclusionStateNotification, object: window)
        center.addObserver(self, selector: #selector(windowDidChangeScreen),
                           name: NSWindow.didChangeScreenNotification, object: window)
    }

    @objc private func windowOcclusionDidChange() {
        // The window went on/off screen — fold that into Ghostty's occlusion so
        // its renderer suspends off screen and resumes on screen. This is also the
        // event that re-enables rendering after a move into a *new* window, once
        // that window is ordered front.
        syncOcclusion()
        guard isRenderable else { return }
        refreshSurfaceOnly()
    }

    @objc private func windowDidChangeScreen() {
        guard let surface = surfaceSlot.liveSurface(),
              let displayID = window?.screen?.displayID, displayID != 0 else { return }
        ghostty_surface_set_display_id(surface, displayID)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGhosttySize(force: true)
    }

    override func layout() {
        super.layout()
        updateGhosttySize(force: false)
        repositionScrollbackIndicator()
    }

    // Without a .mouseMoved tracking area, AppKit never delivers mouseMoved:, so
    // bare hover-motion reporting (DECSET 1003) never reaches TUIs (vim/htop/etc.).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        mouseTrackingArea = area
    }

    func closeSurface() {
        renderGeneration &+= 1
        surfaceClosed = true
        if let surface = surfaceSlot.removeForClose() {
            ghostty_surface_free(surface)
        }
        surfaceSlot.markClosed()
        pendingOutput.removeAll(keepingCapacity: false)
    }

    func resetSurfaceOutput(_ data: Data) {
        closeSurface()
        // Intentional re-creation: allow ensureSurface() to build a fresh surface.
        surfaceClosed = false
        processOutput(data)
    }

    func processOutput(_ data: Data, render: Bool = true) {
        guard !data.isEmpty else { return }
        if !render {
            if let surface = surfaceSlot.liveSurface() {
                processOutputImmediately(data, to: surface, render: false)
            }
            return
        }
        guard isRenderable else { return }
        appendPendingOutput(data)
        guard let surface = surfaceSlot.liveSurface() else {
            return
        }
        if pendingOutput.count >= Self.immediateOutputFlushBytes {
            flushPendingOutput(to: surface, render: true)
        } else {
            scheduleOutputFlush()
        }
    }

    private func appendPendingOutput(_ data: Data) {
        pendingOutput.append(data)
        guard pendingOutput.count > Self.maxPendingOutputBytes else { return }
        // Never drop from the front while a live surface exists: that splits ANSI
        // escape sequences mid-stream and garbles rendering (PERF-009). Flush the
        // backlog synchronously to the live surface (Ghostty owns scrollback)
        // instead of discarding bytes.
        if let surface = surfaceSlot.liveSurface() {
            flushPendingOutput(to: surface, render: isRenderable)
            return
        }
        // No surface to flush to yet (truly unrenderable): bound memory as a last
        // resort by discarding the oldest bytes.
        let dropped = pendingOutput.count - Self.maxPendingOutputBytes
        droppedOutputBytes += dropped
        pendingOutput.removeFirst(dropped)
    }

    private func scheduleOutputFlush() {
        guard !outputFlushScheduled else { return }
        outputFlushScheduled = true
        let generation = renderGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.outputFlushDelay) { [weak self] in
            guard let self, generation == self.renderGeneration else { return }
            self.flushPendingOutput()
        }
    }

    private func flushPendingOutput() {
        outputFlushScheduled = false
        guard isRenderable else { return }
        ensureSurface()
        guard let surface = surfaceSlot.liveSurface() else { return }
        flushPendingOutput(to: surface, render: true)
    }

    private func flushPendingOutput(to surface: ghostty_surface_t, render: Bool) {
        guard !pendingOutput.isEmpty else { return }
        let output = pendingOutput
        pendingOutput.removeAll(keepingCapacity: true)
        processOutputImmediately(output, to: surface, render: render)
    }

    private func processOutputImmediately(_ output: Data, to surface: ghostty_surface_t, render: Bool) {
        output.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            ghostty_surface_process_output(
                surface,
                base.assumingMemoryBound(to: CChar.self),
                UInt(raw.count)
            )
        }
        guard render, isRenderable else { return }
        // Do NOT render synchronously on the main thread. ghostty_surface_render_now
        // makes the main thread a second renderer running concurrently with Ghostty's
        // own renderer thread and its cf_release thread, which races the CoreText
        // shaper's deferred-CFRelease pool (use-after-free, EXC_BAD_ACCESS in
        // cf_release_thread). Only post an async refresh so Ghostty's single
        // renderer thread draws.
        ghostty_surface_refresh(surface)
        // Notify VoiceOver that the terminal content changed so screen readers
        // can re-read the viewport. Coalesced to avoid spamming VO on rapid output.
        postVOValueChangedIfNeeded()
    }

    private func postVOValueChangedIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastVOValueChangedAt >= Self.voValueChangedInterval else { return }
        lastVOValueChangedAt = now
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    /// Apply an effect produced by the Ghostty runtime action callback.
    /// Called on the main thread (dispatched from action_cb).
    func applyActionEffect(_ effect: GhosttyActionEffect) {
        switch effect {
        case .setTitle(let title):
            currentTitle = title
            onTitleChange?(title)
        case .mouseShape(let shape):
            NSCursor.pop()
            if let cursor = Self.cursor(for: shape) {
                cursor.push()
            }
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .openFilePath(let path):
            if let handler = onCmdClickFilePath {
                handler(path)
            } else {
                // Fallback: open in the default app (e.g. Xcode for .swift files)
                // when no in-app routing is configured.
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
    }

    /// Map a Ghostty mouse-shape enum value to the closest AppKit NSCursor.
    /// Returns nil for the default cursor (pop-only, no push).
    nonisolated static func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor? {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT:
            return nil
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_TEXT:
            return .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
            return .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            return .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB, GHOSTTY_MOUSE_SHAPE_GRABBING:
            return .closedHand
        case GHOSTTY_MOUSE_SHAPE_MOVE:
            return .openHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP:
            return .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_COPY:
            return .dragCopy
        case GHOSTTY_MOUSE_SHAPE_ALIAS:
            return .dragLink
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE,
             GHOSTTY_MOUSE_SHAPE_E_RESIZE, GHOSTTY_MOUSE_SHAPE_W_RESIZE:
            return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE,
             GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE:
            return .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_WAIT, GHOSTTY_MOUSE_SHAPE_PROGRESS:
            return .arrow
        default:
            return .arrow
        }
    }

    func writeInputData(_ data: Data) {
        onInputData?(data)
    }

    func forceRefresh() {
        guard isRenderable else { return }
        ensureSurface()
        // Renderable again (e.g. reattached to an on-screen window after a move) —
        // make sure Ghostty's renderer is resumed before we ask it to draw.
        syncOcclusion()
        updateGhosttySize(force: true)
        flushPendingOutput()
        if let surface = surfaceSlot.liveSurface() {
            // Async refresh only — never render on the main thread (see processOutputImmediately).
            ghostty_surface_refresh(surface)
        }
    }

    func refreshSurfaceOnly() {
        guard isRenderable else { return }
        ensureSurface()
        // Resume the renderer on reattach/relayout while renderable. This is the
        // reliable resume path after a move to a new window (driven by the
        // container's layout/window-change), independent of occlusion notifications.
        syncOcclusion()
        let refreshedByResize = updateGhosttySize(force: true)
        guard !refreshedByResize else { return }
        if let surface = surfaceSlot.liveSurface() {
            ghostty_surface_refresh(surface)
        }
    }

    func setOcclusion(visible: Bool) {
        visibleInUI = visible
        if !visible {
            renderGeneration &+= 1
            pendingOutput.removeAll(keepingCapacity: false)
        }
        // Drive Ghostty's occlusion from the *full* render gate, not raw tab
        // visibility: a selected tab whose window is off screen or mid-move must
        // still keep the renderer suspended. The next on-screen event resumes it.
        syncOcclusion()
    }

    /// Single source of truth for Ghostty's occlusion: the renderer may run only
    /// when the surface is actually renderable (selected tab AND an on-screen,
    /// sized, non-minimized window). Suspending it whenever that is false is what
    /// stops it from drawing into a windowless/off-screen CAMetalLayer
    /// (`nextDrawable` starvation → freeze, or an AGX trap). Cheap, idempotent,
    /// main-thread-only flag set.
    private func syncOcclusion() {
        guard let surface = surfaceSlot.liveSurface() else { return }
        ghostty_surface_set_occlusion(surface, isRenderable)
    }

    func readViewportText() -> String? {
        readText(pointTag: GHOSTTY_POINT_VIEWPORT)
    }

    /// Full terminal screen text including scrollback (GHOSTTY_POINT_SCREEN),
    /// used as the snapshot the find bar searches over.
    func readScrollbackText() -> String? {
        readText(pointTag: GHOSTTY_POINT_SCREEN)
    }

    private func readText(pointTag: ghostty_point_tag_e) -> String? {
        ensureSurface()
        guard let surface = surfaceSlot.liveSurface() else { return nil }
        // Only force a synchronous render when there is actually pending output
        // to apply; flushing it already renders the fresh frame. With nothing
        // pending, read the existing frame's text directly to avoid a redundant
        // GPU/main-thread render on every mirror poll (PERF-005).
        if pendingOutput.isEmpty == false {
            flushPendingOutput(to: surface, render: isRenderable)
        }

        let topLeft = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text, text.text_len > 0 else { return "" }
        return String(decoding: Data(bytes: ptr, count: Int(text.text_len)), as: UTF8.self)
    }

    private func ensureSurface() {
        guard Self.nativeRendererEnabled else { return }
        guard !surfaceClosed else { return }
        guard surfaceSlot.liveSurface() == nil else { return }
        guard window != nil else { return }
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard let app = RemoteCodeGhosttyRuntime.shared.app else { return }
        guard Self.hasActiveDisplay() else { return }
        guard let displayID = window?.screen?.displayID ?? NSScreen.main?.displayID,
              displayID != 0 else { return }
        guard let generation = surfaceSlot.beginCreate() else { return }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
        config.font_size = 0
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        config.io_mode = GHOSTTY_SURFACE_IO_MANUAL
        config.io_write_cb = ghosttyTerminalIOWriteCallback
        config.io_write_userdata = Unmanaged.passUnretained(ioContext).toOpaque()

        guard let created = ghostty_surface_new(app, &config) else {
            surfaceSlot.cancelCreate(generation: generation)
            #if DEBUG
            NSLog(
                "RemoteCode Ghostty surface allocation failed bounds=%@ window=%d layer=%d %@",
                NSStringFromRect(bounds),
                window == nil ? 0 : 1,
                layer == nil ? 0 : 1,
                RemoteCodeGhosttyRuntime.shared.diagnosticsSummary()
            )
            #endif
            return
        }

        guard surfaceSlot.install(created, generation: generation) else {
            ghostty_surface_free(created)
            return
        }
        ghostty_surface_set_display_id(created, displayID)
        // Restore persisted zoom before the first size update so the grid
        // dimensions reported to the PTY already reflect the correct cell size.
        // Guard: if zoomDelta is already non-zero (e.g. this surface was
        // restarted via resetSurfaceOutput and the in-memory delta is still
        // set), skip the store read to avoid a double-apply.
        if zoomDelta == 0 {
            restoreZoomDelta()
        } else {
            let bindingAction = zoomDelta > 0
                ? "increase_font_size:\(zoomDelta)"
                : "decrease_font_size:\(-zoomDelta)"
            performBindingAction(bindingAction)
        }
        updateGhosttySize(force: true)
        updateFocus()
        flushPendingOutput(to: created, render: isRenderable)
        // A freshly created surface inherits the current render gate: only run its
        // renderer (and ask for a first frame) when actually on screen — not merely
        // when the tab is selected (the window may be off screen / not yet ordered
        // front during a move).
        syncOcclusion()
        if isRenderable {
            ghostty_surface_refresh(created)
        }
    }

    private var isRenderable: Bool {
        Self.canRender(
            visibleInUI: visibleInUI,
            isHidden: isHidden,
            hasNonEmptyBounds: bounds.width > 0 && bounds.height > 0,
            windowPresent: window != nil,
            windowVisible: window?.isVisible ?? false,
            windowMiniaturized: window?.isMiniaturized ?? false,
            windowOnScreen: window?.occlusionState.contains(.visible) ?? false
        )
    }

    /// Whether it is safe to render the Metal surface. A minimized or ordered-out
    /// window keeps a non-nil `window`, but its CAMetalLayer has no valid
    /// drawable; rendering into it (`render_now`) dereferences a freed
    /// framebuffer texture and traps inside the GPU driver (EXC_BREAKPOINT in AGX
    /// `renderCommandEncoderWithDescriptor:`), which Ghostty's embedded crash
    /// reporter turns into a silent `_exit`. `occlusionState` is the signal
    /// AppKit guarantees for "the window's content is actually on screen". Pure
    /// so the off-screen invariant can be tested without a window server.
    nonisolated static func canRender(
        visibleInUI: Bool,
        isHidden: Bool,
        hasNonEmptyBounds: Bool,
        windowPresent: Bool,
        windowVisible: Bool,
        windowMiniaturized: Bool,
        windowOnScreen: Bool
    ) -> Bool {
        guard visibleInUI, !isHidden, hasNonEmptyBounds, windowPresent else { return false }
        return windowVisible && !windowMiniaturized && windowOnScreen
    }

    private static func hasActiveDisplay() -> Bool {
        var count: UInt32 = 0
        return CGGetActiveDisplayList(0, nil, &count) == .success && count > 0
    }

    private static let nativeRendererEnabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        guard env["RC2_ENABLE_GHOSTTY_IN_TESTS"] != "1" else { return true }
        guard env["XCTestConfigurationFilePath"] == nil else { return false }
        return ProcessInfo.processInfo.processName != "xctest"
    }()

    private func updateFocus() {
        guard let surface = surfaceSlot.liveSurface() else { return }
        ghostty_surface_set_focus(surface, window?.firstResponder === self)
    }

    @discardableResult
    private func updateGhosttySize(force: Bool) -> Bool {
        ensureSurface()
        guard let surface = surfaceSlot.liveSurface() else { return false }
        guard bounds.width > 0, bounds.height > 0 else { return false }

        let backing = convertToBacking(NSRect(origin: .zero, size: bounds.size)).size
        guard backing.width > 0, backing.height > 0 else { return false }

        let pixelWidth = max(UInt32(1), UInt32(floor(backing.width)))
        let pixelHeight = max(UInt32(1), UInt32(floor(backing.height)))
        let xScale = Double(backing.width / bounds.width)
        let yScale = Double(backing.height / bounds.height)
        let nextPixelSize = NSSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        let nextScale = NSSize(width: xScale, height: yScale)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.drawableSize = nextPixelSize
            metalLayer.contentsScale = CGFloat(max(xScale, yScale))
        }
        CATransaction.commit()

        guard force || nextPixelSize != lastPixelSize || nextScale != lastScale else { return false }
        lastPixelSize = nextPixelSize
        lastScale = nextScale

        ghostty_surface_set_content_scale(surface, xScale, yScale)
        ghostty_surface_set_size(surface, pixelWidth, pixelHeight)
        let size = ghostty_surface_size(surface)
        let rows = max(1, Int(size.rows))
        let cols = max(1, Int(size.columns))
        onTerminalSizeChange?(TerminalViewportSize(rows: rows, cols: cols))
        // Gate the post-resize redraw on the *full* render gate, not raw tab
        // visibility. `viewDidMoveToWindow` calls this with `force: true` even when
        // the view is transiently windowless mid-move; refreshing then would drive
        // Ghostty into a windowless drawable and freeze (this was the bug).
        if isRenderable {
            ghostty_surface_refresh(surface)
        }
        return true
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        updateFocus()
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        updateFocus()
        return ok
    }

    override func keyDown(with event: NSEvent) {
        guard let surface = surfaceForInput() else { return }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "c":
                copySelection(from: surface)
                return
            case "v":
                pasteText(to: surface)
                return
            case "+", "=": // Cmd-+ (and bare Cmd-= without shift) → zoom in
                changeFontSize("increase_font_size:1")
                return
            case "-", "_": // Cmd-- → zoom out
                changeFontSize("decrease_font_size:1")
                return
            case "0": // Cmd-0 → reset zoom
                changeFontSize("reset_font_size")
                return
            case "f": // Cmd-F → find in scrollback
                openFindBar()
                return
            default:
                break
            }
        }
        // Esc closes the find bar when it is open, before the keystroke reaches
        // the terminal program.
        if findBar?.isHidden == false, event.keyCode == 53 {
            closeFindBar()
            return
        }
        // Scrollback keyboard navigation: Shift+PgUp/PgDn, Cmd+Home/End.
        // Intercepted before the Ghostty key path so these bindings work
        // regardless of whether the running program handles PgUp/PgDn.
        if let scrollAction = ScrollbackKeyAction.action(for: event.keyCode, modifiers: event.modifierFlags) {
            performBindingAction(scrollAction)
            return
        }
        if TerminalKeyboardInput.shouldUseTextInput(for: event) {
            // Route printable input through AppKit's text-input system so the
            // active keyboard layout owns composition. Dead keys (´ ` ^ ~ ¨ on
            // ABNT2 / US-International / Portuguese etc.) compose accented glyphs
            // — ~ then a → ã, ' then e → é — via our NSTextInputClient
            // (setMarkedText → ghostty_surface_preedit, then insertText commits
            // the composed text). Non-dead-key layouts commit the literal char
            // directly (~/`/'/" on a plain US layout), exactly like Terminal.app.
            //
            // We deliberately do NOT short-circuit ~/`/'/" to literal bytes here:
            // that older workaround (added before this view had NSTextInputClient
            // conformance) force-translated every dead key to its spacing glyph,
            // so ã/õ/á/é never composed — the user saw "~a" instead of "ã".
            interpretKeyEvents([event])
            return
        }
        var key = ghosttyKeyEvent(for: event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
        if let text = textForEvent(event) {
            text.withCString { ptr in
                key.text = ptr
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            key.text = nil
            _ = ghostty_surface_key(surface, key)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface = surfaceForInput() else { return }
        var key = ghosttyKeyEvent(for: event, action: GHOSTTY_ACTION_RELEASE)
        key.text = nil
        _ = ghostty_surface_key(surface, key)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // When the foreground app is reporting mouse events (TUIs like vim/htop),
        // forward the right button so it reaches the program. Otherwise let
        // AppKit present the context menu from `menu(for:)` (UX-007).
        if isMouseCaptured {
            sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard isMouseCaptured else { return }
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // No AppKit menu while the program owns the mouse; the right button was
        // already forwarded in `rightMouseDown` (UX-007).
        guard !isMouseCaptured else { return nil }
        return makeContextMenu()
    }

    private var isMouseCaptured: Bool {
        guard let surface = surfaceSlot.liveSurface() else { return false }
        return ghostty_surface_mouse_captured(surface)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let hasSelection = surfaceSlot.liveSurface().map { ghostty_surface_has_selection($0) } ?? false
        let hasClipboardText = (NSPasteboard.general.string(forType: .string)?.isEmpty == false)

        let copy = menu.addItem(withTitle: "Copy", action: #selector(contextCopy(_:)), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = hasSelection
        copy.setAccessibilityIdentifier("surface.terminal.menu.copy")

        let copyAll = menu.addItem(withTitle: "Copy All", action: #selector(contextCopyAll(_:)), keyEquivalent: "")
        copyAll.target = self
        copyAll.setAccessibilityIdentifier("surface.terminal.menu.copyAll")

        let paste = menu.addItem(withTitle: "Paste", action: #selector(contextPaste(_:)), keyEquivalent: "")
        paste.target = self
        paste.isEnabled = hasClipboardText
        paste.setAccessibilityIdentifier("surface.terminal.menu.paste")

        menu.addItem(.separator())

        let selectAll = menu.addItem(withTitle: "Select All", action: #selector(contextSelectAll(_:)), keyEquivalent: "")
        selectAll.target = self
        selectAll.setAccessibilityIdentifier("surface.terminal.menu.selectAll")

        let jumpToBottom = menu.addItem(withTitle: "Jump to Bottom", action: #selector(contextJumpToBottom(_:)), keyEquivalent: "")
        jumpToBottom.target = self
        jumpToBottom.setAccessibilityIdentifier("surface.terminal.menu.jumpToBottom")

        let clear = menu.addItem(withTitle: "Clear", action: #selector(contextClear(_:)), keyEquivalent: "")
        clear.target = self
        clear.setAccessibilityIdentifier("surface.terminal.menu.clear")

        return menu
    }

    @objc private func contextCopy(_ sender: Any?) {
        guard let surface = surfaceSlot.liveSurface() else { return }
        copySelection(from: surface)
    }

    @objc private func contextCopyAll(_ sender: Any?) {
        guard let text = readViewportText(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func contextPaste(_ sender: Any?) {
        guard let surface = surfaceForInput() else { return }
        pasteText(to: surface)
    }

    @objc private func contextSelectAll(_ sender: Any?) {
        performBindingAction("select_all")
    }

    @objc private func contextJumpToBottom(_ sender: Any?) {
        performBindingAction("scroll_to_bottom")
    }

    @objc private func contextClear(_ sender: Any?) {
        performBindingAction("clear_screen")
    }

    // MARK: - Scrollback position indicator

    /// Update the scrollback position indicator. Call whenever the scroll
    /// position changes (driven by the owning TerminalSurface).
    /// `offset` = lines scrolled above the bottom (0 = at bottom).
    /// `total`  = total scrollback line count available.
    func updateScrollbackPosition(offset: Int, total: Int) {
        let text = ScrollbackPositionLabel.label(offset: offset, total: total)
        let atBottom = offset <= 0
        if atBottom {
            scrollbackIndicator?.isHidden = true
            return
        }
        let label = scrollbackIndicator ?? makeScrollbackIndicator()
        scrollbackIndicator = label
        label.stringValue = text
        label.isHidden = false
        label.sizeToFit()
        repositionScrollbackIndicator()
    }

    private func makeScrollbackIndicator() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = DS.NS.textSecondary
        label.backgroundColor = DS.NS.surface.withAlphaComponent(0.85)
        label.drawsBackground = true
        label.isBordered = false
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityIdentifier("terminal.scrollback-indicator")
        label.setAccessibilityLabel("Scrollback position")
        addSubview(label)
        return label
    }

    private func repositionScrollbackIndicator() {
        guard let label = scrollbackIndicator else { return }
        let size = label.fittingSize
        let margin: CGFloat = 8
        label.frame = NSRect(
            x: bounds.maxX - size.width - margin,
            y: margin,
            width: size.width + 8,
            height: size.height + 2
        )
    }

    private func performBindingAction(_ action: String) {
        guard let surface = surfaceForInput() else { return }
        action.withCString { ptr in
            _ = ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
        }
        if isRenderable {
            // Async refresh only — never render on the main thread (see processOutputImmediately).
            ghostty_surface_refresh(surface)
        }
    }

    // Cmd-+/Cmd--/Cmd-0 zoom: drive Ghostty's font-size action, then re-derive
    // and re-emit the grid size so the PTY winsize follows the new cell metrics
    // (UX-008). The delta is also persisted so the zoom survives restart.
    private func changeFontSize(_ action: String) {
        performBindingAction(action)
        updateGhosttySize(force: true)
        updateZoomDelta(for: action)
        showFontZoomHUD()
    }

    /// Update `zoomDelta` to reflect the zoom action and persist to the KV store.
    private func updateZoomDelta(for action: String) {
        if action.hasPrefix("increase_font_size:"),
           let n = Int(action.dropFirst("increase_font_size:".count)) {
            zoomDelta = FontZoomLevel.clamp(zoomDelta + n)
        } else if action.hasPrefix("decrease_font_size:"),
                  let n = Int(action.dropFirst("decrease_font_size:".count)) {
            zoomDelta = FontZoomLevel.clamp(zoomDelta - n)
        } else if action == "reset_font_size" {
            zoomDelta = 0
        }
        persistZoomDelta()
    }

    private func persistZoomDelta() {
        guard let store = fontZoomStore,
              let wsID = fontZoomWorkspaceID else { return }
        let key = "terminal.font_zoom.\(wsID)"
        try? store.set(key, FontZoomLevel.serialize(zoomDelta))
    }

    private func restoreZoomDelta() {
        guard let store = fontZoomStore,
              let wsID = fontZoomWorkspaceID else { return }
        let key = "terminal.font_zoom.\(wsID)"
        // `try? store.get(key)` produces `String??`; flatten with nil-coalescing.
        let rawOptional: String?? = try? store.get(key)
        guard let raw = rawOptional ?? nil,
              let stored = FontZoomLevel.deserialize(raw),
              stored != 0 else { return }
        zoomDelta = stored
        // Replay the stored delta as binding actions so Ghostty's internal
        // font-size state matches; do NOT call changeFontSize which would
        // re-persist and call updateGhosttySize prematurely (ensureSurface
        // already calls updateGhosttySize after this).
        let bindingAction: String
        if stored > 0 {
            bindingAction = "increase_font_size:\(stored)"
        } else {
            bindingAction = "decrease_font_size:\(-stored)"
        }
        performBindingAction(bindingAction)
    }

    // MARK: - Find in scrollback (Cmd+F)

    private func openFindBar() {
        let bar = findBar ?? makeFindBar()
        findBar = bar
        bar.isHidden = false
        if let field = findField {
            window?.makeFirstResponder(field)
        }
        recomputeFindMatches(forward: true, advance: false)
    }

    private func closeFindBar() {
        findBar?.isHidden = true
        findMatchCount = 0
        findCurrentMatch = nil
        window?.makeFirstResponder(self)
    }

    private func makeFindBar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = DS.NS.surface.cgColor
        bar.layer?.cornerRadius = 6
        bar.setAccessibilityIdentifier("terminal.find-bar")
        bar.translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField()
        field.placeholderString = "Find in terminal"
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.target = self
        field.action = #selector(findFieldChanged(_:))
        field.setAccessibilityIdentifier("terminal.find-field")
        field.setAccessibilityLabel("Find in terminal")
        field.translatesAutoresizingMaskIntoConstraints = false
        findField = field

        let count = NSTextField(labelWithString: "")
        count.textColor = DS.NS.textSecondary
        count.font = NSFont.systemFont(ofSize: 11)
        count.setAccessibilityIdentifier("terminal.find-count")
        count.translatesAutoresizingMaskIntoConstraints = false
        findCountLabel = count

        let prev = makeFindButton("chevron.up", help: "Previous match",
                                  axID: "terminal.find-prev", action: #selector(findPrev(_:)))
        let next = makeFindButton("chevron.down", help: "Next match",
                                  axID: "terminal.find-next", action: #selector(findNext(_:)))
        let close = makeFindButton("xmark", help: "Close find",
                                   axID: "terminal.find-close", action: #selector(findClose(_:)))

        let stack = NSStackView(views: [field, count, prev, next, close])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            field.widthAnchor.constraint(equalToConstant: 180)
        ])
        return bar
    }

    private func makeFindButton(_ glyph: String, help: String, axID: String, action: Selector) -> NSButton {
        let b = NSButton()
        b.isBordered = false
        b.bezelStyle = .inline
        b.image = NSImage(systemSymbolName: glyph, accessibilityDescription: help)
        b.contentTintColor = DS.NS.textSecondary
        b.imageScaling = .scaleProportionallyDown
        b.toolTip = help
        b.target = self
        b.action = action
        b.setAccessibilityIdentifier(axID)
        b.setAccessibilityLabel(help)
        return b
    }

    @objc private func findFieldChanged(_ sender: Any?) {
        recomputeFindMatches(forward: true, advance: false)
    }

    @objc private func findNext(_ sender: Any?) {
        recomputeFindMatches(forward: true, advance: true)
    }

    @objc private func findPrev(_ sender: Any?) {
        recomputeFindMatches(forward: false, advance: true)
    }

    @objc private func findClose(_ sender: Any?) {
        closeFindBar()
    }

    /// Recompute matches for the current query against the live scrollback
    /// snapshot, optionally advancing the navigation cursor, and refresh the
    /// count label. No visible terminal highlight/scroll is possible because
    /// GhosttyKit exposes no selection-set/scroll-to API to embedders.
    private func recomputeFindMatches(forward: Bool, advance: Bool) {
        let query = findField?.stringValue ?? ""
        let snapshot = readScrollbackText() ?? ""
        let ranges = TerminalScrollbackSearch.matchRanges(in: snapshot, query: query)
        findMatchCount = ranges.count
        if findMatchCount == 0 {
            findCurrentMatch = nil
        } else if advance {
            findCurrentMatch = TerminalScrollbackSearch.nextIndex(
                current: findCurrentMatch, count: findMatchCount, forward: forward, wrap: true)
        } else if findCurrentMatch == nil || (findCurrentMatch ?? 0) >= findMatchCount {
            findCurrentMatch = 0
        }
        updateFindCountLabel()
    }

    private func updateFindCountLabel() {
        guard let label = findCountLabel else { return }
        if (findField?.stringValue ?? "").isEmpty {
            label.stringValue = ""
        } else if findMatchCount == 0 {
            label.stringValue = "0/0"
        } else {
            label.stringValue = "\((findCurrentMatch ?? 0) + 1)/\(findMatchCount)"
        }
    }

    // MARK: - Font zoom HUD

    /// Show a brief bottom-left overlay indicating the current zoom level, then
    /// auto-hide it after a short delay. "Base" means delta == 0 (no zoom).
    private func showFontZoomHUD() {
        let text = Self.fontZoomHUDText(for: zoomDelta)
        let label = fontZoomHUD ?? makeFontZoomHUD()
        fontZoomHUD = label
        label.stringValue = text
        label.isHidden = false
        label.sizeToFit()
        repositionFontZoomHUD()
        fontZoomHUDGeneration &+= 1
        let gen = fontZoomHUDGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.fontZoomHUDGeneration == gen else { return }
            self.fontZoomHUD?.isHidden = true
        }
    }

    /// Human-readable HUD text for a zoom delta. Pure, nonisolated for tests.
    nonisolated static func fontZoomHUDText(for delta: Int) -> String {
        if delta == 0 { return "Font: Base" }
        return delta > 0 ? "Font: +\(delta)pt" : "Font: \(delta)pt"
    }

    private func makeFontZoomHUD() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = DS.NS.textSecondary
        label.backgroundColor = DS.NS.surface.withAlphaComponent(0.85)
        label.drawsBackground = true
        label.isBordered = false
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityIdentifier("terminal.font-zoom-hud")
        label.setAccessibilityLabel("Font zoom level")
        addSubview(label)
        return label
    }

    private func repositionFontZoomHUD() {
        guard let label = fontZoomHUD else { return }
        let size = label.fittingSize
        let margin: CGFloat = 8
        label.frame = NSRect(
            x: margin,
            y: margin,
            width: size.width + 8,
            height: size.height + 2
        )
    }

    override func otherMouseDown(with event: NSEvent) {
        // Middle-click pastes the current terminal selection (X11/iTerm style)
        // when the program isn't reporting mouse events; otherwise forward the
        // middle button to the program (UX-012).
        if event.buttonNumber == 2, !isMouseCaptured,
           let surface = surfaceForInput(), ghostty_surface_has_selection(surface) {
            window?.makeFirstResponder(self)
            pasteSelection(from: surface)
            return
        }
        super.otherMouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = surfaceForInput() else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        var mods: Int32 = 0
        if event.hasPreciseScrollingDeltas {
            x *= 2
            y *= 2
            mods |= 0b0000_0001
        }
        mods |= mouseMomentum(from: event) << 1
        ghostty_surface_mouse_scroll(surface, x, y, ghostty_input_scroll_mods_t(mods))
        // Async refresh only — never render on the main thread (see processOutputImmediately).
        ghostty_surface_refresh(surface)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepts = Self.canAcceptDrag(from: sender.draggingPasteboard)
        setDropHighlight(accepts)
        return accepts ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return Self.canAcceptDrag(from: sender.draggingPasteboard) ? .copy : []
    }

    /// Returns `true` when `pasteboard` carries either a file-URL drop or a
    /// plain-text string that the terminal can accept. Pure helper so the drag
    /// acceptance predicate is not duplicated across `draggingEntered` and
    /// `draggingUpdated`.
    nonisolated static func canAcceptDrag(from pasteboard: NSPasteboard) -> Bool {
        if DroppedFilePaths.canReadFileDrop(from: pasteboard) { return true }
        return pasteboard.availableType(from: [.string]) != nil
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropHighlight(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setDropHighlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlight(false)

        // File-URL drop: convert to shell-escaped paths and send immediately
        // (same as before; file drops have always been accepted without guard).
        let paths = DroppedFilePaths.paths(from: sender.draggingPasteboard)
        if !paths.isEmpty {
            guard let data = DroppedFilePaths.terminalInputText(for: paths).data(using: .utf8) else { return false }
            writeInputData(data)
            return true
        }

        // Plain-text drop: resolve the string from the pasteboard and apply the
        // same PasteGuard semantics used for keyboard paste (Cmd+V) so a
        // multi-line or control-character string dragged from another app does
        // not silently execute shell commands.
        guard let text = TerminalDragPayload.plainText(from: sender.draggingPasteboard),
              !text.isEmpty else { return false }

        if let safe = TerminalDragPayload.safeTextToSend(text) {
            // Single-line, no control characters: send immediately.
            guard let data = safe.data(using: .utf8) else { return false }
            writeInputData(data)
        } else {
            // Multi-line or control characters: route through the confirm
            // callback so the owning surface can present a confirmation sheet.
            // Fall back to sending directly when no callback is wired (e.g.
            // unit-test stubs that do not need the confirm flow).
            if let confirm = onPlainTextDragNeedsConfirm {
                confirm(text)
            } else {
                guard let data = text.data(using: .utf8) else { return false }
                writeInputData(data)
            }
        }
        return true
    }

    // Visual drop target: a highlighted border while a file drag is over the
    // terminal so users can tell the path will be pasted on release (UX-010).
    private func setDropHighlight(_ active: Bool) {
        if active {
            let layer = dropHighlightLayer ?? makeDropHighlightLayer()
            dropHighlightLayer = layer
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.frame = bounds
            self.layer?.addSublayer(layer)
            CATransaction.commit()
        } else {
            dropHighlightLayer?.removeFromSuperlayer()
        }
    }

    private func makeDropHighlightLayer() -> CALayer {
        let layer = CALayer()
        layer.borderWidth = 2
        layer.borderColor = NSColor.controlAccentColor.cgColor
        layer.cornerRadius = 2
        layer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        return layer
    }

    private func surfaceForInput() -> ghostty_surface_t? {
        ensureSurface()
        return surfaceSlot.liveSurface()
    }

    private func sendText(_ text: String, to surface: ghostty_surface_t) {
        // Use the true UTF-8 byte length, not strlen — strlen stops at the first
        // embedded NUL, truncating pasted/bracketed content that contains \0.
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            base.withMemoryRebound(to: CChar.self, capacity: buf.count) { ptr in
                ghostty_surface_text(surface, ptr, UInt(buf.count))
            }
        }
    }

    private func pasteText(to surface: ghostty_surface_t) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        switch PasteGuard.classify(text) {
        case .safe:
            sendText(text, to: surface)
        case .needsConfirm:
            if let confirm = onPasteNeedsConfirm {
                confirm(text)
            } else {
                // No confirmation handler wired (e.g. unit tests / preview): send
                // directly as a safe fall-through, matching TerminalTextView behaviour.
                sendText(text, to: surface)
            }
        }
    }

    private func pasteSelection(from surface: ghostty_surface_t) {
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let raw = text.text, text.text_len > 0 else { return }
        let value = String(decoding: Data(bytes: raw, count: Int(text.text_len)), as: UTF8.self)
        guard !value.isEmpty else { return }
        sendText(value, to: surface)
    }

    private func copySelection(from surface: ghostty_surface_t) {
        guard ghostty_surface_has_selection(surface) else { return }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let raw = text.text, text.text_len > 0 else { return }
        let data = Data(bytes: raw, count: Int(text.text_len))
        guard let value = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func ghosttyKeyEvent(for event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = mods(from: event.modifierFlags)
        key.consumed_mods = consumedMods(from: event.modifierFlags)
        key.unshifted_codepoint = unshiftedCodepoint(from: event)
        key.composing = false
        return key
    }

    private func textForEvent(_ event: NSEvent) -> String? {
        GhosttyTerminalKeyInput.text(for: event)
    }

    private func unshiftedCodepoint(from event: NSEvent) -> UInt32 {
        GhosttyTerminalKeyInput.unshiftedCodepoint(from: event)
    }

    private func mods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    private func consumedMods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    private func sendMousePosition(_ event: NSEvent) {
        guard let surface = surfaceForInput() else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, mods(from: event.modifierFlags))
    }

    private func sendMouseButton(
        _ event: NSEvent,
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e
    ) {
        guard let surface = surfaceForInput() else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, mods(from: event.modifierFlags))
        _ = ghostty_surface_mouse_button(surface, state, button, mods(from: event.modifierFlags))
    }

    private func mouseMomentum(from event: NSEvent) -> Int32 {
        switch event.momentumPhase {
        case .began:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
        case .stationary:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue)
        case .changed:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
        case .ended:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
        case .cancelled:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
        case .mayBegin:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
        default:
            return Int32(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
        }
    }
}

private extension NSScreen {
    var displayID: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }
}

// IME / dead-key / CJK composition. Without NSTextInputClient conformance,
// interpretKeyEvents (called from keyDown) cannot drive marked-text composition,
// so multi-stage input (Pinyin, Kana, dead keys) was broken. The cmux GhosttyKit
// fork exposes ghostty_surface_preedit so the engine can render the in-progress
// composition; committed text flows through the existing typed-text path.
extension GhosttyTerminalView: NSTextInputClient {
    nonisolated static func plainString(from any: Any) -> String? {
        if let s = any as? String { return s }
        if let a = any as? NSAttributedString { return a.string }
        return nil
    }

    /// Pure NSTextInputClient preedit transitions, extracted so the IME / dead-key
    /// composition contract is unit-testable without a live Ghostty surface.
    /// `.setMarked` shows the in-progress composition; `.insert` and `.unmark` BOTH
    /// clear it. The `.insert` clear is the dead-key fix: committing a character
    /// (e.g. ~ then a -> a, ' then e -> e) must drop the in-progress preedit before
    /// the character is sent, never leave the dead key rendered.
    enum IMEPreeditInput { case setMarked(Any), insert, unmark }
    nonisolated static func nextPreedit(for input: IMEPreeditInput) -> String {
        switch input {
        case .setMarked(let s): return plainString(from: s) ?? ""
        case .insert, .unmark: return ""
        }
    }

    nonisolated static func markedRange(forPreedit text: String) -> NSRange {
        text.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: (text as NSString).length)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        setPreedit(Self.nextPreedit(for: .insert))
        guard let text = Self.plainString(from: string), !text.isEmpty,
              let surface = surfaceForInput() else { return }
        sendText(text, to: surface)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        setPreedit(Self.nextPreedit(for: .setMarked(string)))
    }

    func unmarkText() {
        setPreedit(Self.nextPreedit(for: .unmark))
    }

    /// Push the marked (composing) text to Ghostty so it renders the preedit
    /// overlay. Empty string clears it. Keeps `markedText` in sync for AppKit.
    private func setPreedit(_ text: String) {
        markedText = text
        guard let surface = surfaceForInput() else { return }
        let bytes = Array(text.utf8)
        if bytes.isEmpty {
            ghostty_surface_preedit(surface, nil, 0)
            return
        }
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            base.withMemoryRebound(to: CChar.self, capacity: buf.count) { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(buf.count))
            }
        }
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func markedRange() -> NSRange { Self.markedRange(forPreedit: markedText) }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Anchor the IME candidate window to the view; ghostty does not expose a
        // per-glyph caret rect to embedders, so use the view rect in screen space.
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }
}
