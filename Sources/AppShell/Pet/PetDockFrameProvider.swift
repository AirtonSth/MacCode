import AppKit
import ApplicationServices
import CoreGraphics

/// Reads the Dock's actual occupied strip without requiring Accessibility
/// permission. The Dock advertises a full-display window to Core Graphics, but
/// AppKit's public window hit-test API respects that window's interactive shelf
/// shape, so sampling across the reserved edge reveals the live footprint.
enum PetDockFrameProvider {
    static func frame(for screen: NSScreen) -> CGRect? {
        guard hasReservedDockEdge(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        ) else {
            return nil
        }
        if let frame = hitTestFrame(for: screen) {
            return frame
        }
        // Keep AX as a best-effort fallback for unusual Dock/window-server
        // configurations. The normal path above does not require AX trust.
        return accessibilityFrame(for: screen)
    }

    private static func hasReservedDockEdge(
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> Bool {
        visibleFrame.minX - screenFrame.minX > 1
            || screenFrame.maxX - visibleFrame.maxX > 1
            || visibleFrame.minY - screenFrame.minY > 1
    }

    private static let dockVisualTolerance: CGFloat = 12
    // Eight-point probes bound the synchronous lookup while remaining far
    // narrower than the smallest Dock tile.
    private static let sampleStep: CGFloat = 8

    private static func hitTestFrame(for screen: NSScreen) -> CGRect? {
        guard let dock = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).first else {
            return nil
        }
        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let dockWindowNumbers = Set(windowInfo.compactMap { info -> Int? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                    == dock.processIdentifier,
                  let number = info[kCGWindowNumber as String] as? NSNumber else {
                return nil
            }
            return number.intValue
        })
        guard !dockWindowNumbers.isEmpty else { return nil }

        return hitTestFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            dockWindowNumbers: dockWindowNumbers,
            windowNumberAtPoint: { point in
                NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
            }
        )
    }

    /// Testable geometry core for the permission-free Dock lookup.
    static func hitTestFrame(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        dockWindowNumbers: Set<Int>,
        windowNumberAtPoint: (CGPoint) -> Int
    ) -> CGRect? {
        guard screenFrame.width > 0,
              screenFrame.height > 0,
              !dockWindowNumbers.isEmpty else {
            return nil
        }

        let leftInset = max(0, visibleFrame.minX - screenFrame.minX)
        let rightInset = max(0, screenFrame.maxX - visibleFrame.maxX)
        let bottomInset = max(0, visibleFrame.minY - screenFrame.minY)
        let edgeInsets: [(Edge, CGFloat)] = [
            (.left, leftInset),
            (.right, rightInset),
            (.bottom, bottomInset)
        ]
        guard let (edge, inset) = edgeInsets.max(by: { $0.1 < $1.1 }),
              inset > 1 else {
            // An auto-hidden Dock does not reserve an occupied strip. In that
            // state visibleFrame already reaches the physical edge.
            return nil
        }

        func isDock(_ point: CGPoint) -> Bool {
            dockWindowNumbers.contains(windowNumberAtPoint(point))
        }

        let occupied: ClosedRange<CGFloat>?
        switch edge {
        case .bottom:
            occupied = sampledOccupiedRange(
                crossCoordinates: sampleCrossCoordinates(
                    start: screenFrame.minY,
                    inset: inset
                ),
                scanRange: screenFrame.minX...screenFrame.maxX,
                point: { along, cross in CGPoint(x: along, y: cross) },
                isDock: isDock
            )
            guard let occupied else { return nil }
            let minX = max(screenFrame.minX, occupied.lowerBound - dockVisualTolerance)
            let maxX = min(screenFrame.maxX, occupied.upperBound + dockVisualTolerance)
            return CGRect(
                x: minX,
                y: screenFrame.minY,
                width: max(0, maxX - minX),
                height: min(screenFrame.height, inset + dockVisualTolerance)
            )
        case .left:
            occupied = sampledOccupiedRange(
                crossCoordinates: sampleCrossCoordinates(
                    start: screenFrame.minX,
                    inset: inset
                ),
                scanRange: screenFrame.minY...screenFrame.maxY,
                point: { along, cross in CGPoint(x: cross, y: along) },
                isDock: isDock
            )
            guard let occupied else { return nil }
            let minY = max(screenFrame.minY, occupied.lowerBound - dockVisualTolerance)
            let maxY = min(screenFrame.maxY, occupied.upperBound + dockVisualTolerance)
            return CGRect(
                x: screenFrame.minX,
                y: minY,
                width: min(screenFrame.width, inset + dockVisualTolerance),
                height: max(0, maxY - minY)
            )
        case .right:
            occupied = sampledOccupiedRange(
                crossCoordinates: sampleCrossCoordinates(
                    start: screenFrame.maxX - inset,
                    inset: inset
                ),
                scanRange: screenFrame.minY...screenFrame.maxY,
                point: { along, cross in CGPoint(x: cross, y: along) },
                isDock: isDock
            )
            guard let occupied else { return nil }
            let minY = max(screenFrame.minY, occupied.lowerBound - dockVisualTolerance)
            let maxY = min(screenFrame.maxY, occupied.upperBound + dockVisualTolerance)
            let width = min(screenFrame.width, inset + dockVisualTolerance)
            return CGRect(
                x: screenFrame.maxX - width,
                y: minY,
                width: width,
                height: max(0, maxY - minY)
            )
        }
    }

    private enum Edge {
        case left
        case right
        case bottom
    }

    private static func sampleCrossCoordinates(start: CGFloat, inset: CGFloat) -> [CGFloat] {
        // The shelf is widest through its middle. Quarter-depth probes are
        // fallbacks for transient/rounded hit regions.
        [0.5, 0.25, 0.75].map { start + inset * $0 }
    }

    private static func sampledOccupiedRange(
        crossCoordinates: [CGFloat],
        scanRange: ClosedRange<CGFloat>,
        point: (CGFloat, CGFloat) -> CGPoint,
        isDock: (CGPoint) -> Bool
    ) -> ClosedRange<CGFloat>? {
        for cross in crossCoordinates {
            if let range = occupiedRange(
                scanRange: scanRange,
                isDock: { isDock(point($0, cross)) }
            ) {
                return range
            }
        }
        return nil
    }

    private static func occupiedRange(
        scanRange: ClosedRange<CGFloat>,
        isDock: (CGFloat) -> Bool
    ) -> ClosedRange<CGFloat>? {
        let start = scanRange.lowerBound
        // CGRect.maxX/maxY is an exclusive/shared display boundary. Keep the
        // hit test inside this screen so an adjacent display's Dock cannot be
        // attributed to this one.
        let end = scanRange.upperBound.nextDown
        guard end > start else { return nil }

        var firstHit: CGFloat?
        var lastHit: CGFloat?
        var value = start
        while value <= end {
            if isDock(value) {
                firstHit = firstHit ?? value
                lastHit = value
            }
            value += sampleStep
        }
        if isDock(end) {
            firstHit = firstHit ?? end
            lastHit = end
        }
        guard let firstHit, let lastHit else { return nil }

        let lower = transition(
            nonHit: max(start, firstHit - sampleStep),
            hit: firstHit,
            isDock: isDock
        )
        let upper = transition(
            nonHit: min(end, lastHit + sampleStep),
            hit: lastHit,
            isDock: isDock
        )
        return min(lower, upper)...max(lower, upper)
    }

    /// Refines a hit/non-hit boundary to sub-point precision. When the sampled
    /// endpoint is also a hit (the Dock reaches the display edge), preserve it.
    private static func transition(
        nonHit: CGFloat,
        hit: CGFloat,
        isDock: (CGFloat) -> Bool
    ) -> CGFloat {
        guard !isDock(nonHit), nonHit != hit else { return hit }
        var outside = nonHit
        var inside = hit
        for _ in 0..<4 {
            let midpoint = (outside + inside) / 2
            if isDock(midpoint) {
                inside = midpoint
            } else {
                outside = midpoint
            }
        }
        return inside
    }

    private static func accessibilityFrame(for screen: NSScreen) -> CGRect? {
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

        let frame = appKitFrame(
            quartzFrame: quartzFrame,
            quartzDisplayFrame: quartzDisplayFrame,
            appKitScreenFrame: screen.frame
        )
        let clipped = frame.intersection(screen.frame)
        return clipped.area > 0 ? clipped : nil
    }

    static func appKitFrame(
        quartzFrame: CGRect,
        quartzDisplayFrame: CGRect,
        appKitScreenFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: appKitScreenFrame.minX + quartzFrame.minX - quartzDisplayFrame.minX,
            y: appKitScreenFrame.maxY
                - (quartzFrame.minY - quartzDisplayFrame.minY)
                - quartzFrame.height,
            width: quartzFrame.width,
            height: quartzFrame.height
        )
    }
}

private extension CGRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}
