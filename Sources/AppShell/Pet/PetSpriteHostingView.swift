import AppKit
import CoreGraphics
import SwiftUI

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

final class PetSpriteHostingView<Content: View>: NSHostingView<Content> {
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onDragStateChanged: ((Bool) -> Void)?
    var onDragEnded: ((CGRect) -> Void)?
    var imageProvider: (() -> CGImage?)?
    /// Top-right red attention dot hit region.
    var attentionBadgeVisibleProvider: (() -> Bool)?
    /// Top-left blue running dot hit region.
    var activeBadgeVisibleProvider: (() -> Bool)?
    /// Back-compat alias used by older call sites/tests.
    var badgeVisibleProvider: (() -> Bool)? {
        get { attentionBadgeVisibleProvider }
        set { attentionBadgeVisibleProvider = newValue }
    }
    var accessibilityValueProvider: (() -> String)?

    private var dragInteraction = PetDragInteraction()
    private var reportedDragState = false
    private var suppressNextMouseUpClick = false
    private var cursorWasPushed = false
    private var localMouseUpMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var alphaMaskImage: CGImage?
    private var alphaMask: PetSpriteAlphaMask?
    private(set) var alphaMaskBuildCountForTests = 0

    var didDrag: Bool { dragInteraction.didDrag }
    var dragLifecycleForTests: (active: Bool, monitoring: Bool, cursorPushed: Bool) {
        (
            reportedDragState,
            localMouseUpMonitor != nil || globalMouseUpMonitor != nil,
            cursorWasPushed
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isOpaque(at: point) ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        cancelActiveDrag()
        suppressNextMouseUpClick = false
        dragInteraction.begin(mouseLocation: NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        let cursorLocation = NSEvent.mouseLocation
        switch dragInteraction.update(to: cursorLocation) {
        case .pending:
            return
        case .began:
            beginActiveDrag()
            guard let window else {
                cancelActiveDrag()
                return
            }
            dragInteraction.beginScruffTransition(
                cursorLocation: cursorLocation,
                windowOrigin: window.frame.origin
            )
        case .dragging:
            break
        }
        guard let window,
              let origin = dragInteraction.anchoredWindowOrigin(
                  cursorLocation: cursorLocation,
                  targetGrabOffset: PetScruffAnchor.offset(in: window.frame.size)
              ) else { return }
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        routeMouseUp()
    }

    func routeMouseUpForTests() {
        routeMouseUp()
    }

    func fallbackMouseUpForTests() {
        handleFallbackMouseUp()
    }

    private func routeMouseUp() {
        if suppressNextMouseUpClick {
            suppressNextMouseUpClick = false
            return
        }
        if !completeActiveDrag(asDrop: true) {
            onClick?()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        cancelActiveDrag()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cancelActiveDrag()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }

    func isOpaque(at point: CGPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        if attentionBadgeVisibleProvider?() == true {
            let badgeRect = CGRect(x: bounds.maxX - 34, y: bounds.maxY - 34, width: 34, height: 34)
            if badgeRect.contains(point) { return true }
        }
        if activeBadgeVisibleProvider?() == true {
            let badgeRect = CGRect(x: bounds.minX, y: bounds.maxY - 34, width: 34, height: 34)
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

    func cancelActiveDrag() {
        let wasActive = dragInteraction.didDrag || reportedDragState
        _ = completeActiveDrag(asDrop: false)
        if wasActive {
            suppressNextMouseUpClick = true
        }
    }

    func beginActiveDragForTests() {
        dragInteraction.begin(mouseLocation: .zero)
        guard dragInteraction.update(to: CGPoint(x: PetDragInteraction.threshold, y: 0)) == .began else {
            return
        }
        beginActiveDrag()
    }

    func completeActiveDragForTests(asDrop: Bool) {
        _ = completeActiveDrag(asDrop: asDrop)
    }

    @discardableResult
    private func completeActiveDrag(asDrop: Bool) -> Bool {
        let wasDrag = dragInteraction.finish()
        if wasDrag || reportedDragState {
            endActiveDrag(notifyDrop: asDrop && wasDrag)
        } else {
            stopDragMonitoring()
        }
        return wasDrag
    }

    private func beginActiveDrag() {
        guard !reportedDragState else { return }
        reportedDragState = true
        if !cursorWasPushed {
            NSCursor.closedHand.push()
            cursorWasPushed = true
        }
        installMouseUpFallback()
        onDragStateChanged?(true)
    }

    private func endActiveDrag(notifyDrop: Bool) {
        stopDragMonitoring()
        if reportedDragState {
            reportedDragState = false
            onDragStateChanged?(false)
        }
        if notifyDrop, let frame = window?.frame {
            onDragEnded?(frame)
        }
    }

    private func installMouseUpFallback() {
        guard localMouseUpMonitor == nil, globalMouseUpMonitor == nil else { return }
        localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) {
            [weak self] event in
            DispatchQueue.main.async { [weak self] in
                self?.handleFallbackMouseUp()
            }
            return event
        }
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) {
            [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.handleFallbackMouseUp()
            }
        }
    }

    private func handleFallbackMouseUp() {
        _ = completeActiveDrag(asDrop: true)
    }

    private func stopDragMonitoring() {
        if let localMouseUpMonitor { NSEvent.removeMonitor(localMouseUpMonitor) }
        if let globalMouseUpMonitor { NSEvent.removeMonitor(globalMouseUpMonitor) }
        localMouseUpMonitor = nil
        globalMouseUpMonitor = nil
        if cursorWasPushed {
            NSCursor.pop()
            cursorWasPushed = false
        }
    }
}
