import AppKit
import CoreModel
import Darwin
import DesignSystemKit
import GhosttyKit
import QuartzCore

private final class RemoteCodeGhosttyIOContext {
    weak var view: GhosttyTerminalView?
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
    private var tickScheduled = false

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
        runtimeConfig.action_cb = { _, _, _ in
            return true
        }
        runtimeConfig.read_clipboard_cb = unsafeBitCast(
            ghosttyRuntimeReadClipboardCallback as @convention(c) (
                UnsafeMutableRawPointer?,
                ghostty_clipboard_e,
                UnsafeMutableRawPointer?
            ) -> Bool,
            to: ghostty_runtime_read_clipboard_cb.self
        )
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
        let bundledGhosttyURL = Bundle.module.resourceURL?.appendingPathComponent("ghostty")
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

    private func appendEnvPathIfMissing(_ key: String, path: String, defaultValue: String? = nil) {
        guard !path.isEmpty else { return }
        let current = getenv(key).map { String(cString: $0) } ?? defaultValue ?? ""
        let parts = current.split(separator: ":").map(String.init)
        guard !parts.contains(path) else { return }
        let next = current.isEmpty ? path : "\(path):\(current)"
        setenv(key, next, 1)
    }

    private func scheduleTick() {
        guard !tickScheduled else { return }
        tickScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tickScheduled = false
            if let app = self.app {
                ghostty_app_tick(app)
            }
        }
    }

    func diagnosticsSummary() -> String {
        guard let config else { return "config=nil" }
        return diagnosticsSummary(for: config)
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

    private var surface: ghostty_surface_t?
    private let ioContext = RemoteCodeGhosttyIOContext()
    private var pendingOutput = Data()
    private var lastPixelSize = NSSize(width: 0, height: 0)
    private var lastScale = NSSize(width: 0, height: 0)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func makeBackingLayer() -> CALayer {
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
        registerForDraggedTypes(DroppedFilePaths.pasteboardTypes)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ensureSurface()
        updateGhosttySize(force: true)
        updateFocus()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGhosttySize(force: true)
    }

    override func layout() {
        super.layout()
        updateGhosttySize(force: false)
    }

    func closeSurface() {
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
    }

    func processOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let surface else {
            pendingOutput.append(data)
            return
        }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            ghostty_surface_process_output(
                surface,
                base.assumingMemoryBound(to: CChar.self),
                UInt(raw.count)
            )
        }
        ghostty_surface_render_now(surface)
        ghostty_surface_refresh(surface)
    }

    func writeInputData(_ data: Data) {
        onInputData?(data)
    }

    func forceRefresh() {
        ensureSurface()
        updateGhosttySize(force: true)
        if let surface {
            ghostty_surface_render_now(surface)
            ghostty_surface_refresh(surface)
        }
    }

    private func ensureSurface() {
        guard surface == nil else { return }
        guard window != nil else { return }
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard let app = RemoteCodeGhosttyRuntime.shared.app else { return }

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

        surface = created
        if let displayID = window?.screen?.displayID ?? NSScreen.main?.displayID, displayID != 0 {
            ghostty_surface_set_display_id(created, displayID)
        }
        updateGhosttySize(force: true)
        updateFocus()
        if !pendingOutput.isEmpty {
            let replay = pendingOutput
            pendingOutput.removeAll(keepingCapacity: true)
            processOutput(replay)
        }
        ghostty_surface_refresh(created)
    }

    private func updateFocus() {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, window?.firstResponder === self)
    }

    @discardableResult
    private func updateGhosttySize(force: Bool) -> Bool {
        ensureSurface()
        guard let surface else { return false }
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
        ghostty_surface_refresh(surface)
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
            default:
                break
            }
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

    override func insertText(_ insertString: Any) {
        let text: String?
        if let string = insertString as? String {
            text = string
        } else if let attributed = insertString as? NSAttributedString {
            text = attributed.string
        } else {
            text = nil
        }
        guard let surface = surfaceForInput(), let text else { return }
        sendText(text, to: surface)
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
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
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
        ghostty_surface_render_now(surface)
        ghostty_surface_refresh(surface)
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
        guard let data = DroppedFilePaths.terminalInputText(for: paths).data(using: .utf8) else { return false }
        writeInputData(data)
        return true
    }

    private func surfaceForInput() -> ghostty_surface_t? {
        ensureSurface()
        return surface
    }

    private func sendText(_ text: String, to surface: ghostty_surface_t) {
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
    }

    private func pasteText(to surface: ghostty_surface_t) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        sendText(text, to: surface)
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
