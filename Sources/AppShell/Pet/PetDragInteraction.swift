import CoreGraphics

enum PetDragUpdate: Equatable {
    case pending
    case began
    case dragging
}

enum PetScruffAnchor {
    static let normalized = CGPoint(x: 0.5, y: 0.82)

    static func offset(in size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width * normalized.x,
            y: size.height * normalized.y
        )
    }
}

struct PetDragInteraction {
    static let threshold: CGFloat = 4
    private static let scruffTransitionFactor: CGFloat = 0.35

    private var mouseDownLocation: CGPoint?
    private var currentGrabOffset: CGPoint?
    private(set) var didDrag = false

    mutating func begin(mouseLocation: CGPoint) {
        mouseDownLocation = mouseLocation
        currentGrabOffset = nil
        didDrag = false
    }

    mutating func update(to current: CGPoint) -> PetDragUpdate {
        guard let down = mouseDownLocation else { return .pending }
        let delta = CGSize(width: current.x - down.x, height: current.y - down.y)
        if !didDrag, hypot(delta.width, delta.height) >= Self.threshold {
            didDrag = true
            return .began
        }
        return didDrag ? .dragging : .pending
    }

    mutating func beginScruffTransition(
        cursorLocation: CGPoint,
        windowOrigin: CGPoint
    ) {
        guard didDrag else { return }
        currentGrabOffset = CGPoint(
            x: cursorLocation.x - windowOrigin.x,
            y: cursorLocation.y - windowOrigin.y
        )
    }

    mutating func anchoredWindowOrigin(
        cursorLocation: CGPoint,
        targetGrabOffset: CGPoint
    ) -> CGPoint? {
        guard didDrag, let currentGrabOffset else { return nil }
        let easedOffset = CGPoint(
            x: currentGrabOffset.x
                + (targetGrabOffset.x - currentGrabOffset.x) * Self.scruffTransitionFactor,
            y: currentGrabOffset.y
                + (targetGrabOffset.y - currentGrabOffset.y) * Self.scruffTransitionFactor
        )
        self.currentGrabOffset = easedOffset
        return CGPoint(
            x: cursorLocation.x - easedOffset.x,
            y: cursorLocation.y - easedOffset.y
        )
    }

    mutating func finish() -> Bool {
        let wasDrag = didDrag
        mouseDownLocation = nil
        currentGrabOffset = nil
        didDrag = false
        return wasDrag
    }
}
