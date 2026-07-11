import AppKit
import CoreGraphics
import CryptoKit
import Persistence
import SwiftUI

private final class PetPopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct PetDragInteraction {
    static let threshold: CGFloat = 4

    private var mouseDownLocation: CGPoint?
    private var windowOriginAtMouseDown: CGPoint?
    private(set) var didDrag = false

    mutating func begin(mouseLocation: CGPoint, windowOrigin: CGPoint?) {
        mouseDownLocation = mouseLocation
        windowOriginAtMouseDown = windowOrigin
        didDrag = false
    }

    mutating func draggedWindowOrigin(to current: CGPoint) -> CGPoint? {
        guard let down = mouseDownLocation,
              let origin = windowOriginAtMouseDown else { return nil }
        let delta = CGSize(width: current.x - down.x, height: current.y - down.y)
        if !didDrag, hypot(delta.width, delta.height) >= Self.threshold {
            didDrag = true
        }
        guard didDrag else { return nil }
        return CGPoint(x: origin.x + delta.width, y: origin.y + delta.height)
    }

    mutating func finish() -> Bool {
        let wasDrag = didDrag
        mouseDownLocation = nil
        windowOriginAtMouseDown = nil
        didDrag = false
        return wasDrag
    }
}

struct PetSpriteAlphaMask {
    let width: Int
    let height: Int
    private let alpha: [UInt8]

    init?(image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let data = bytes.baseAddress,
                  let context = CGContext(
                      data: data,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                          | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        self.width = width
        self.height = height
        self.alpha = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
    }

    func isOpaque(x: Int, y: Int, threshold: UInt8 = 8) -> Bool {
        guard (0..<width).contains(x), (0..<height).contains(y) else { return false }
        return alpha[y * width + x] > threshold
    }
}

enum PetAccessibilityIdentifier {
    static func row(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum PetAttentionVisualStatus: Equatable {
    case completed
    case failed
    case interrupted
    case needsAttention

    static func resolve(_ kind: PetAttentionItemKind) -> PetAttentionVisualStatus {
        switch kind {
        case .callback:
            return .needsAttention
        case .agentOutcome(let outcome):
            switch outcome {
            case .completed: return .completed
            case .failed: return .failed
            case .interrupted: return .interrupted
            }
        case .notification(let category):
            switch category {
            case .gitFailed, .projectScriptFailed, .sshTransferFailed, .providerUpdateFailed:
                return .failed
            case .sshUnexpectedDisconnect, .fileConflict, .serverListenerFailed:
                return .needsAttention
            case .gitCompleted, .projectScriptCompleted, .sshTransferCompleted:
                return .completed
            }
        }
    }

    var systemImage: String {
        switch self {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .interrupted: return "exclamationmark.triangle.fill"
        case .needsAttention: return "exclamationmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .completed: return .teal
        case .failed: return .red
        case .interrupted, .needsAttention: return .orange
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        case .needsAttention: return "Needs attention"
        }
    }
}

enum PetPopoverSizing {
    static let preferredWidth: CGFloat = 360
    static let minimumHeight: CGFloat = 178
    static let maximumHeight: CGFloat = 520
    static let screenMargin: CGFloat = 12

    static func contentWidth(visibleFrame: CGRect) -> CGFloat {
        min(preferredWidth, max(0, visibleFrame.width - screenMargin * 2))
    }

    static func resolve(fittingSize: CGSize, visibleFrame: CGRect) -> CGSize {
        let width = contentWidth(visibleFrame: visibleFrame)
        let maximumScreenHeight = max(0, visibleFrame.height - screenMargin * 2)
        let requestedHeight = max(minimumHeight, fittingSize.height)
        return CGSize(
            width: width,
            height: min(maximumHeight, maximumScreenHeight, requestedHeight)
        )
    }
}

enum PetScreenGeometry {
    static func petPlacementFrame(screenFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        let topEdge = min(screenFrame.maxY, max(screenFrame.minY, visibleFrame.maxY))
        return CGRect(
            x: screenFrame.minX,
            y: screenFrame.minY,
            width: screenFrame.width,
            height: topEdge - screenFrame.minY
        )
    }

    static func largestPositiveIntersectionIndex(
        frame: CGRect,
        screenFrames: [CGRect]
    ) -> Int? {
        screenFrames.enumerated()
            .map { (index: $0.offset, area: $0.element.intersection(frame).area) }
            .filter { $0.area > 0 }
            .max { lhs, rhs in lhs.area < rhs.area }?
            .index
    }
}

final class PetSpriteHostingView<Content: View>: NSHostingView<Content> {
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onDragEnded: ((CGRect) -> Void)?
    var imageProvider: (() -> CGImage?)?
    var badgeVisibleProvider: (() -> Bool)?
    var accessibilityValueProvider: (() -> String)?

    private var dragInteraction = PetDragInteraction()
    private var alphaMaskImage: CGImage?
    private var alphaMask: PetSpriteAlphaMask?
    private(set) var alphaMaskBuildCountForTests = 0

    var didDrag: Bool { dragInteraction.didDrag }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isOpaque(at: point) ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        dragInteraction.begin(
            mouseLocation: NSEvent.mouseLocation,
            windowOrigin: window?.frame.origin
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragInteraction.draggedWindowOrigin(to: NSEvent.mouseLocation),
              let window else { return }
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        let wasDrag = dragInteraction.finish()
        if wasDrag, let frame = window?.frame {
            onDragEnded?(frame)
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }

    func isOpaque(at point: CGPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        if badgeVisibleProvider?() == true {
            let badgeRect = CGRect(x: bounds.maxX - 34, y: bounds.maxY - 34, width: 34, height: 34)
            if badgeRect.contains(point) { return true }
        }
        guard let image = imageProvider?() else { return true }
        if alphaMaskImage !== image {
            alphaMaskImage = image
            alphaMask = PetSpriteAlphaMask(image: image)
            alphaMaskBuildCountForTests += 1
        }
        guard let alphaMask else { return true }
        let x = min(image.width - 1, max(0, Int(point.x / max(1, bounds.width) * CGFloat(image.width))))
        let y = min(image.height - 1, max(0, Int(point.y / max(1, bounds.height) * CGFloat(image.height))))
        return alphaMask.isOpaque(x: x, y: y)
    }

    override func accessibilityValue() -> Any? {
        accessibilityValueProvider?() ?? super.accessibilityValue()
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .button
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }
}

private struct PetSpriteView: View {
    @ObservedObject var model: PetViewModel
    let onActivate: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = model.currentImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .accessibilityHidden(true)
            } else {
                Color.clear
            }

            if let badge = model.badgeText {
                Text(badge)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, badge == "99+" ? 6 : 7)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(Circle().fill(Color.red))
                    .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .accessibilityIdentifier("pet.badge")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Remote Code pet")
        .accessibilityValue(model.accessibilityValue)
        .accessibilityHint("Opens Remote Code pet status")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onActivate() }
        .accessibilityIdentifier("pet.status")
    }
}

private struct PetAttentionPopoverView: View {
    @ObservedObject var model: PetViewModel
    let onOpen: (PetAttentionItem) -> Void
    let onMarkAll: () -> Void
    let onOpenApp: () -> Void
    let onClose: () -> Void
    let contentWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ready for you")
                        .font(.title2.weight(.semibold))
                    Text(model.accessibilityValue)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close")
                .accessibilityIdentifier("pet.close")
            }
            .padding(18)

            Divider()

            if model.items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Nothing needs attention", systemImage: "checkmark.circle")
                        .font(.body.weight(.medium))
                    Button("Open Remote Code") { onOpenApp() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("pet.openRemoteCode")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        attentionSection("Needs you", items: Array(model.needsYouItems.prefix(50)))
                        attentionSection("Completed", items: Array(model.completedItems.prefix(50)))
                    }
                }
                .frame(maxHeight: 390)

                Divider()
                HStack {
                    if model.items.count > 50 {
                        Button("Open Activity") { onOpenApp() }
                            .buttonStyle(.plain)
                    }
                    Spacer()
                    Button("Mark all viewed") { onMarkAll() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier("pet.markAllViewed")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }

            if let routeError = model.routeError {
                Text(routeError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("pet.routeError")
            }
        }
        .frame(width: contentWidth)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.14), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pet.popover")
        .onExitCommand { onClose() }
    }

    @ViewBuilder
    private func attentionSection(_ title: String, items: [PetAttentionItem]) -> some View {
        if !items.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 6)
            ForEach(items) { item in
                let status = PetAttentionVisualStatus.resolve(item.kind)
                HStack(spacing: 12) {
                    Image(systemName: status.systemImage)
                        .foregroundStyle(status.color)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if let detail = item.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Button(item.kind.needsUserAction ? "Review" : "Open") { onOpen(item) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("pet.row.\(PetAccessibilityIdentifier.row(item.id)).open")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .frame(minHeight: 52)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(status.accessibilityLabel), \(item.title)")
                .accessibilityIdentifier("pet.row.\(PetAccessibilityIdentifier.row(item.id))")
            }
        }
    }
}

@MainActor
public final class PetWindowController: NSObject {
    public var onOpenItem: ((PetAttentionItem) -> Void)?
    public var onMarkAllViewed: (() -> Void)?
    public var onOpenRemoteCode: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onHidePet: (() -> Void)?
    public var onToggleAnimations: (() -> Void)?
    public var onAdoptFreePosition: (() -> Void)?
    public var onInteraction: (() -> Void)?

    private let model: PetViewModel
    private let placementStore: PetPlacementStore
    private var petPanel: NSPanel?
    private var spriteView: PetSpriteHostingView<PetSpriteView>?
    private var popoverPanel: PetPopoverPanel?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var popoverLocalMonitor: Any?
    private var popoverGlobalMonitor: Any?
    private weak var keyWindowBeforePopover: NSWindow?
    private var pendingGlobalMousePoint: CGPoint?
    private var globalMouseMoveTask: Task<Void, Never>?
    private(set) var globalMouseMoveProcessCountForTests = 0
    private(set) var lastProcessedGlobalMousePointForTests: CGPoint?
    var keyWindowProviderForTests: (() -> NSWindow?)?

    public init(model: PetViewModel, placementStore: PetPlacementStore) {
        self.model = model
        self.placementStore = placementStore
        super.init()
    }

    public var isVisible: Bool { petPanel?.isVisible == true }
    public var isPopoverVisible: Bool { popoverPanel?.isVisible == true }
    var petPanelForTests: NSPanel? { petPanel }
    var popoverPanelForTests: NSPanel? { popoverPanel }
    var spriteAccessibilityViewForTests: NSView? { spriteView }

    public func show() {
        ensurePetPanel()
        applySettings(model.settings)
        petPanel?.orderFrontRegardless()
        installMouseMonitors()
    }

    public func hide() {
        closePopover()
        petPanel?.orderOut(nil)
        removeMouseMonitors()
    }

    public func stop() {
        hide()
        petPanel?.close()
        popoverPanel?.close()
        petPanel = nil
        popoverPanel = nil
        spriteView = nil
    }

    public func applySettings(_ settings: AppSettings) {
        guard settings.petEnabled else {
            hide()
            return
        }
        ensurePetPanel()
        let size = petSize(scale: settings.petSize)
        if let panel = petPanel {
            panel.setContentSize(size)
            panel.setFrame(resolvePetFrame(size: size, settings: settings), display: true)
        }
        if !isVisible {
            petPanel?.orderFrontRegardless()
            installMouseMonitors()
        }
        if isPopoverVisible { positionPopover() }
    }

    public func resetPosition() {
        placementStore.reset()
        applySettings(model.settings)
    }

    public func screensDidChange() {
        applySettings(model.settings)
    }

    public func togglePopover() {
        isPopoverVisible ? closePopover() : openPopover()
    }

    func openPopoverForTests() { openPopover() }

    public func closePopover(restoringPreviousKeyWindow: Bool = true) {
        let windowToRestore = restoringPreviousKeyWindow ? keyWindowBeforePopover : nil
        popoverPanel?.orderOut(nil)
        removePopoverMonitors()
        petPanel?.orderFrontRegardless()
        keyWindowBeforePopover = nil
        if let windowToRestore,
           windowToRestore !== popoverPanel,
           windowToRestore.isVisible,
           windowToRestore.canBecomeKey {
            windowToRestore.makeKeyAndOrderFront(nil)
        }
    }

    private func ensurePetPanel() {
        guard petPanel == nil else { return }
        let size = petSize(scale: model.settings.petSize)
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("pet.window")
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let activate: () -> Void = { [weak self] in self?.activatePet() }
        let hosting = PetSpriteHostingView(rootView: PetSpriteView(
            model: model,
            onActivate: activate
        ))
        hosting.identifier = NSUserInterfaceItemIdentifier("pet.window")
        hosting.setAccessibilityElement(true)
        hosting.setAccessibilityRole(.button)
        hosting.setAccessibilityLabel("Remote Code pet")
        hosting.setAccessibilityHelp("Open Remote Code pet status")
        hosting.setAccessibilityIdentifier("pet.status")
        hosting.onClick = activate
        hosting.onRightClick = { [weak self, weak hosting] event in
            guard let self, let hosting else { return }
            self.onInteraction?()
            self.showContextMenu(event: event, in: hosting)
        }
        hosting.onDragEnded = { [weak self] frame in
            self?.onInteraction?()
            self?.finishDrag(frame: frame)
        }
        hosting.imageProvider = { [weak self] in self?.model.currentFrame?.displayImage }
        hosting.badgeVisibleProvider = { [weak self] in self?.model.badgeText != nil }
        hosting.accessibilityValueProvider = { [weak self] in
            self?.model.accessibilityValue ?? "Pet status unavailable"
        }
        panel.contentView = hosting
        self.petPanel = panel
        self.spriteView = hosting
    }

    private func openPopover() {
        ensurePetPanel()
        let panel: PetPopoverPanel
        if let existing = popoverPanel {
            panel = existing
        } else {
            panel = PetPopoverPanel(
                contentRect: CGRect(x: 0, y: 0, width: 360, height: 220),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.identifier = NSUserInterfaceItemIdentifier("pet.popover")
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isExcludedFromWindowsMenu = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            popoverPanel = panel
        }

        if !panel.isVisible, let keyWindow = currentKeyWindow(), keyWindow !== panel {
            keyWindowBeforePopover = keyWindow
        }

        let visibleFrame = popoverTargetScreen()?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: PetPopoverSizing.preferredWidth + 24, height: 544)
        let contentWidth = PetPopoverSizing.contentWidth(visibleFrame: visibleFrame)
        let hosting = NSHostingView(rootView: PetAttentionPopoverView(
            model: model,
            onOpen: { [weak self] in self?.onOpenItem?($0) },
            onMarkAll: { [weak self] in self?.onMarkAllViewed?() },
            onOpenApp: { [weak self] in self?.onOpenRemoteCode?() },
            onClose: { [weak self] in self?.closePopover() },
            contentWidth: contentWidth
        ))
        hosting.setAccessibilityIdentifier("pet.popover")
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        panel.setContentSize(PetPopoverSizing.resolve(
            fittingSize: hosting.fittingSize,
            visibleFrame: visibleFrame
        ))
        positionPopover()
        panel.makeKeyAndOrderFront(nil)
        installPopoverMonitors()
    }

    private func positionPopover() {
        guard let anchor = petPanel?.frame,
              let panel = popoverPanel,
              let screen = popoverTargetScreen() else { return }
        let placement = PetPopoverPlacement.resolve(
            anchorFrame: anchor,
            requestedSize: panel.frame.size,
            visibleFrame: screen.visibleFrame
        )
        panel.setFrame(placement.frame, display: true)
    }

    private func finishDrag(frame: CGRect) {
        guard let panel = petPanel,
              let screen = screen(containing: frame) ?? fallbackScreen() else { return }
        let placementFrame = petPlacementFrame(for: screen)
        let clamped = PetPlacement.clamped(frame: frame, to: placementFrame)
        panel.setFrame(clamped, display: true)
        placementStore.save(PetStoredPlacement(
            displayID: displayID(for: screen),
            position: PetPlacement.normalizedPosition(for: clamped, in: placementFrame)
        ))
        onAdoptFreePosition?()
        if isPopoverVisible { positionPopover() }
    }

    private func resolvePetFrame(size: CGSize, settings: AppSettings) -> CGRect {
        let stored = placementStore.load()
        let existingScreen = petPanel?.isVisible == true
            ? petPanel.flatMap { screen(containing: $0.frame) }
            : nil
        let targetScreen = stored.flatMap { stored in
            NSScreen.screens.first { displayID(for: $0) == stored.displayID }
        } ?? existingScreen
            ?? fallbackScreen()
        guard let targetScreen else { return CGRect(origin: .zero, size: size) }

        let normalized: PetNormalizedPosition
        switch settings.petPosition {
        case "bottomLeft": normalized = PetNormalizedPosition(x: 0, y: 0)
        case "free": normalized = stored?.position ?? PetNormalizedPosition(x: 1, y: 0)
        default: normalized = PetNormalizedPosition(x: 1, y: 0)
        }
        return PetPlacement.frame(
            size: size,
            normalizedPosition: normalized,
            in: petPlacementFrame(for: targetScreen)
        )
    }

    func animationFrameDidChange() {
        guard let panel = petPanel else { return }
        let size = petSize(scale: model.settings.petSize)
        guard abs(panel.frame.width - size.width) > 0.01
                || abs(panel.frame.height - size.height) > 0.01 else { return }

        let targetScreen = screen(containing: panel.frame) ?? fallbackScreen()
        let normalized = targetScreen.map {
            PetPlacement.normalizedPosition(for: panel.frame, in: petPlacementFrame(for: $0))
        }
        panel.setContentSize(size)
        if let targetScreen, let normalized {
            panel.setFrame(
                PetPlacement.frame(
                    size: size,
                    normalizedPosition: normalized,
                    in: petPlacementFrame(for: targetScreen)
                ),
                display: true
            )
        } else {
            panel.setFrame(resolvePetFrame(size: size, settings: model.settings), display: true)
        }
        if isPopoverVisible { positionPopover() }
    }

    private func petSize(scale: Double) -> CGSize {
        let scale = CGFloat([0.75, 1, 1.25, 1.5].contains(scale) ? scale : 1)
        guard let image = model.currentFrame?.displayImage else {
            return CGSize(width: 118 * scale, height: 128 * scale)
        }
        let sourcePixelScale = CGFloat(118.0 / 192.0)
        return CGSize(
            width: (CGFloat(image.width) * sourcePixelScale * scale).rounded(),
            height: (CGFloat(image.height) * sourcePixelScale * scale).rounded()
        )
    }

    private func screen(containing frame: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard let index = PetScreenGeometry.largestPositiveIntersectionIndex(
            frame: frame,
            screenFrames: screens.map(\.frame)
        ) else { return nil }
        return screens[index]
    }

    private func petPlacementFrame(for screen: NSScreen) -> CGRect {
        PetScreenGeometry.petPlacementFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
    }

    private func popoverTargetScreen() -> NSScreen? {
        guard let anchor = petPanel?.frame else { return fallbackScreen() }
        return screen(containing: anchor) ?? fallbackScreen()
    }

    private func fallbackScreen() -> NSScreen? {
        currentKeyWindow()?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func currentKeyWindow() -> NSWindow? {
        keyWindowProviderForTests?() ?? NSApp.keyWindow
    }

    private func displayID(for screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.stringValue ?? screen.localizedName
    }

    private func installMouseMonitors() {
        guard localMouseMonitor == nil, globalMouseMonitor == nil else { return }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updateMousePassThrough(at: NSEvent.mouseLocation)
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.enqueueGlobalMouseMove(at: point) }
        }
    }

    private func removeMouseMonitors() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
        pendingGlobalMousePoint = nil
        globalMouseMoveTask?.cancel()
        globalMouseMoveTask = nil
        petPanel?.ignoresMouseEvents = false
    }

    func enqueueGlobalMouseMoveForTests(_ point: CGPoint) {
        enqueueGlobalMouseMove(at: point)
    }

    private func enqueueGlobalMouseMove(at point: CGPoint) {
        pendingGlobalMousePoint = point
        guard globalMouseMoveTask == nil else { return }
        globalMouseMoveTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            guard !Task.isCancelled else {
                self.globalMouseMoveTask = nil
                return
            }
            guard let latest = self.pendingGlobalMousePoint else {
                self.globalMouseMoveTask = nil
                return
            }
            self.pendingGlobalMousePoint = nil
            self.globalMouseMoveTask = nil
            self.lastProcessedGlobalMousePointForTests = latest
            self.globalMouseMoveProcessCountForTests += 1
            self.updateMousePassThrough(at: latest)
        }
    }

    private func updateMousePassThrough(at screenPoint: CGPoint) {
        guard let panel = petPanel, panel.isVisible, let spriteView else { return }
        guard panel.frame.contains(screenPoint), !spriteView.didDrag else {
            panel.ignoresMouseEvents = false
            return
        }
        let windowPoint = panel.convertPoint(fromScreen: screenPoint)
        let localPoint = spriteView.convert(windowPoint, from: nil)
        panel.ignoresMouseEvents = !spriteView.isOpaque(at: localPoint)
    }

    private func installPopoverMonitors() {
        removePopoverMonitors()
        popoverLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.dismissPopoverIfOutside(NSEvent.mouseLocation)
            return event
        }
        popoverGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.dismissPopoverIfOutside(point) }
        }
    }

    private func removePopoverMonitors() {
        if let popoverLocalMonitor { NSEvent.removeMonitor(popoverLocalMonitor) }
        if let popoverGlobalMonitor { NSEvent.removeMonitor(popoverGlobalMonitor) }
        popoverLocalMonitor = nil
        popoverGlobalMonitor = nil
    }

    private func dismissPopoverIfOutside(_ point: CGPoint) {
        guard popoverPanel?.frame.contains(point) != true,
              petPanel?.frame.contains(point) != true else { return }
        closePopover()
    }

    private func activatePet() {
        onInteraction?()
        togglePopover()
    }

    private func showContextMenu(event: NSEvent, in view: NSView) {
        let menu = NSMenu(title: "Remote Code Pet")
        menu.addItem(menuItem("Open Remote Code", #selector(contextOpenRemoteCode)))
        menu.addItem(menuItem("Open ready items", #selector(contextOpenReadyItems)))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            model.settings.petAnimationsEnabled ? "Pause animations" : "Resume animations",
            #selector(contextToggleAnimations)
        ))
        menu.addItem(menuItem("Settings…", #selector(contextOpenSettings)))
        menu.addItem(menuItem("Hide pet", #selector(contextHidePet)))
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func contextOpenRemoteCode() { onOpenRemoteCode?() }
    @objc private func contextOpenReadyItems() { openPopover() }
    @objc private func contextToggleAnimations() { onToggleAnimations?() }
    @objc private func contextOpenSettings() { onOpenSettings?() }
    @objc private func contextHidePet() { onHidePet?() }
}

private extension CGRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}
