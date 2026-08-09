import AppKit
import ApplicationServices
import CoreGraphics

/// Reads the Dock's actual occupied strip from the live Dock process when
/// Accessibility metadata is available. `CGWindowListCopyWindowInfo` exposes
/// a full-display Dock window, not the shelf bounds, so the AX list is the
/// useful geometry source here.
enum PetDockFrameProvider {
    static func frame(for screen: NSScreen) -> CGRect? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.dock"
              ).first else {
            return nil
        }

        let application = AXUIElementCreateApplication(dock.processIdentifier)
        guard let children = attribute(
            kAXChildrenAttribute as CFString,
            from: application
        ) as? [AXUIElement] else {
            return nil
        }

        let dockFrames = children
            .flatMap { dockLists(in: $0, depth: 0) }
            .compactMap { child -> CGRect? in
                guard let quartzFrame = axFrame(of: child) else { return nil }
                return appKitFrame(quartzFrame, on: screen)
            }
        guard !dockFrames.isEmpty else { return nil }

        guard let clipped = dockFrames.max(by: { lhs, rhs in
            lhs.intersection(screen.frame).area < rhs.intersection(screen.frame).area
        })?.intersection(screen.frame),
        clipped.area > 0 else {
            return nil
        }
        let expanded = clipped
            .insetBy(dx: -dockVisualTolerance, dy: -dockVisualTolerance)
            .intersection(screen.frame)
        return expanded.area > 0 ? expanded : nil
    }

    private static let dockVisualTolerance: CGFloat = 8

    private static func dockLists(
        in element: AXUIElement,
        depth: Int
    ) -> [AXUIElement] {
        if let role = attribute(kAXRoleAttribute as CFString, from: element) as? String,
           role == (kAXListRole as String) {
            return [element]
        }
        guard depth < 4,
              let children = attribute(kAXChildrenAttribute as CFString, from: element)
                as? [AXUIElement] else {
            return []
        }
        return children.flatMap { dockLists(in: $0, depth: depth + 1) }
    }

    private static func attribute(
        _ key: CFString,
        from element: AXUIElement
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &value) == .success else {
            return nil
        }
        return value
    }

    private static func axFrame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(kAXPositionAttribute as CFString, from: element),
              let sizeValue = attribute(kAXSizeAttribute as CFString, from: element) else {
            return nil
        }
        guard CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        let position = positionValue as! AXValue
        let size = sizeValue as! AXValue
        guard AXValueGetType(position) == .cgPoint,
              AXValueGetType(size) == .cgSize else {
            return nil
        }

        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &dimensions),
              point.x.isFinite,
              point.y.isFinite,
              dimensions.width.isFinite,
              dimensions.height.isFinite,
              dimensions.width > 0,
              dimensions.height > 0 else {
            return nil
        }
        return CGRect(origin: point, size: dimensions)
    }

    /// AX uses Quartz's top-left display coordinates. Convert through the
    /// matching CG display bounds instead of assuming every display shares the
    /// primary display's origin or vertical offset.
    private static func appKitFrame(
        _ quartzFrame: CGRect,
        on screen: NSScreen
    ) -> CGRect? {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[screenNumberKey] as? NSNumber else {
            return nil
        }
        let quartzDisplayFrame = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        guard quartzDisplayFrame.intersection(quartzFrame).area > 0 else {
            return nil
        }

        let frame = CGRect(
            x: screen.frame.minX + quartzFrame.minX - quartzDisplayFrame.minX,
            y: screen.frame.minY
                + quartzDisplayFrame.maxY
                - (quartzFrame.minY - quartzDisplayFrame.minY)
                - quartzFrame.height,
            width: quartzFrame.width,
            height: quartzFrame.height
        )
        let clipped = frame.intersection(screen.frame)
        return clipped.area > 0 ? clipped : nil
    }
}

private extension CGRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}
