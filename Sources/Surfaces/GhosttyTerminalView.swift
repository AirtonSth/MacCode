import AppKit
import CoreModel
import Darwin
import DesignSystemKit
import GhosttyKit
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
        runtimeConfig.action_cb = { _, _, _ in
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

    private let surfaceSlot = GhosttySurfaceSlot()
    private let ioContext = RemoteCodeGhosttyIOContext()
    private var pendingOutput = Data()
    private var outputFlushScheduled = false
    private var lastPixelSize = NSSize(width: 0, height: 0)
    private var lastScale = NSSize(width: 0, height: 0)
    private var renderGeneration = 0
    private var visibleInUI = true
    private var dropHighlightLayer: CALayer?
    /// Count of bytes discarded from the front of `pendingOutput` on overflow
    /// while truly unrenderable (no live surface). Should stay 0 in normal
    /// operation; exposed via runtime health so tests/telemetry catch the drop
    /// path being hit (QA-006, guards PERF-009).
    private(set) var droppedOutputBytes = 0

    private static let immediateOutputFlushBytes = 64 * 1024
    private static let maxPendingOutputBytes = 1024 * 1024
    private static let outputFlushDelay: TimeInterval = 0.02

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let surface = surfaceSlot.removeForClose() {
            ghostty_surface_free(surface)
        }
        surfaceSlot.markClosed()
    }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    // Expose the live viewport text as the accessibility value so XCUITest /
    // VoiceOver can read what the terminal currently shows (QA-001).
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityValue() -> Any? { readViewportText() }

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
        registerForDraggedTypes(DroppedFilePaths.pasteboardTypes)
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
    }

    /// Rendering is gated off while the window is off screen (see `isRenderable`),
    /// so when it returns to screen we must redraw the current state — otherwise
    /// the terminal would show a stale frame until the next output or focus event.
    private func observeWindowOcclusion(_ window: NSWindow?) {
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowOcclusionDidChange),
            name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    @objc private func windowOcclusionDidChange() {
        guard isRenderable else { return }
        refreshSurfaceOnly()
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
        renderGeneration &+= 1
        if let surface = surfaceSlot.removeForClose() {
            ghostty_surface_free(surface)
        }
        surfaceSlot.markClosed()
        pendingOutput.removeAll(keepingCapacity: false)
    }

    func resetSurfaceOutput(_ data: Data) {
        closeSurface()
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
        ghostty_surface_render_now(surface)
        ghostty_surface_refresh(surface)
    }

    func writeInputData(_ data: Data) {
        onInputData?(data)
    }

    func forceRefresh() {
        guard isRenderable else { return }
        ensureSurface()
        updateGhosttySize(force: true)
        flushPendingOutput()
        if let surface = surfaceSlot.liveSurface() {
            ghostty_surface_render_now(surface)
            ghostty_surface_refresh(surface)
        }
    }

    func refreshSurfaceOnly() {
        guard isRenderable else { return }
        ensureSurface()
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
        guard let surface = surfaceSlot.liveSurface() else { return }
        ghostty_surface_set_occlusion(surface, visible)
    }

    func readViewportText() -> String? {
        readText(pointTag: GHOSTTY_POINT_VIEWPORT)
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
        updateGhosttySize(force: true)
        updateFocus()
        flushPendingOutput(to: created, render: isRenderable)
        if visibleInUI {
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

    private static var nativeRendererEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        guard env["RC2_ENABLE_GHOSTTY_IN_TESTS"] != "1" else { return true }
        return env["XCTestConfigurationFilePath"] == nil
    }

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
        if visibleInUI {
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
            default:
                break
            }
        }
        if TerminalKeyboardInput.shouldUseTextInput(for: event) {
            if let text = TerminalKeyboardInput.literalShellText(for: event) {
                sendText(text, to: surface)
                return
            }
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

    private func performBindingAction(_ action: String) {
        guard let surface = surfaceForInput() else { return }
        action.withCString { ptr in
            _ = ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
        }
        if isRenderable {
            ghostty_surface_render_now(surface)
            ghostty_surface_refresh(surface)
        }
    }

    // Cmd-+/Cmd--/Cmd-0 zoom: drive Ghostty's font-size action, then re-derive
    // and re-emit the grid size so the PTY winsize follows the new cell metrics
    // (UX-008).
    private func changeFontSize(_ action: String) {
        performBindingAction(action)
        updateGhosttySize(force: true)
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
        ghostty_surface_render_now(surface)
        ghostty_surface_refresh(surface)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepts = DroppedFilePaths.canReadFileDrop(from: sender.draggingPasteboard)
        setDropHighlight(accepts)
        return accepts ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return DroppedFilePaths.canReadFileDrop(from: sender.draggingPasteboard) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropHighlight(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setDropHighlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropHighlight(false)
        let paths = DroppedFilePaths.paths(from: sender.draggingPasteboard)
        guard !paths.isEmpty else { return false }
        guard let data = DroppedFilePaths.terminalInputText(for: paths).data(using: .utf8) else { return false }
        writeInputData(data)
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
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
    }

    private func pasteText(to surface: ghostty_surface_t) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        sendText(text, to: surface)
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
