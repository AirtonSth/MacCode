import Foundation

public struct PetNormalizedPosition: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = Self.clampedUnit(x)
        self.y = Self.clampedUnit(y)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            x: try container.decode(Double.self, forKey: .x),
            y: try container.decode(Double.self, forKey: .y)
        )
    }

    private static func clampedUnit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

public enum PetPlacement {
    public static func clamped(
        frame: CGRect,
        to visibleFrame: CGRect,
        margin: CGFloat = 0
    ) -> CGRect {
        let safe = safeFrame(visibleFrame, margin: margin)
        let size = CGSize(
            width: min(max(0, frame.width), safe.width),
            height: min(max(0, frame.height), safe.height)
        )
        let maxX = safe.maxX - size.width
        let maxY = safe.maxY - size.height
        let origin = CGPoint(
            x: min(max(frame.minX, safe.minX), maxX),
            y: min(max(frame.minY, safe.minY), maxY)
        )
        return CGRect(origin: origin, size: size)
    }

    public static func normalizedPosition(
        for frame: CGRect,
        in visibleFrame: CGRect,
        margin: CGFloat = 0
    ) -> PetNormalizedPosition {
        let safe = safeFrame(visibleFrame, margin: margin)
        let clampedFrame = clamped(frame: frame, to: visibleFrame, margin: margin)
        let horizontalTravel = max(0, safe.width - clampedFrame.width)
        let verticalTravel = max(0, safe.height - clampedFrame.height)
        let x = horizontalTravel > 0 ? (clampedFrame.minX - safe.minX) / horizontalTravel : 0
        let y = verticalTravel > 0 ? (clampedFrame.minY - safe.minY) / verticalTravel : 0
        return PetNormalizedPosition(x: Double(x), y: Double(y))
    }

    public static func frame(
        size requestedSize: CGSize,
        normalizedPosition: PetNormalizedPosition,
        in visibleFrame: CGRect,
        margin: CGFloat = 0
    ) -> CGRect {
        let safe = safeFrame(visibleFrame, margin: margin)
        let size = CGSize(
            width: min(max(0, requestedSize.width), safe.width),
            height: min(max(0, requestedSize.height), safe.height)
        )
        let horizontalTravel = max(0, safe.width - size.width)
        let verticalTravel = max(0, safe.height - size.height)
        return CGRect(
            x: safe.minX + horizontalTravel * CGFloat(normalizedPosition.x),
            y: safe.minY + verticalTravel * CGFloat(normalizedPosition.y),
            width: size.width,
            height: size.height
        )
    }

    fileprivate static func safeFrame(_ visibleFrame: CGRect, margin: CGFloat) -> CGRect {
        let margin = max(0, margin)
        let horizontalMargin = min(margin, max(0, visibleFrame.width / 2))
        let verticalMargin = min(margin, max(0, visibleFrame.height / 2))
        return CGRect(
            x: visibleFrame.minX + horizontalMargin,
            y: visibleFrame.minY + verticalMargin,
            width: max(0, visibleFrame.width - horizontalMargin * 2),
            height: max(0, visibleFrame.height - verticalMargin * 2)
        )
    }
}

public enum PetPopoverVerticalOrientation: Sendable, Equatable {
    case above
    case below
}

public enum PetPopoverHorizontalOrientation: Sendable, Equatable {
    case leading
    case trailing
}

public struct PetPopoverOrientation: Sendable, Equatable {
    public let vertical: PetPopoverVerticalOrientation
    public let horizontal: PetPopoverHorizontalOrientation

    public init(
        vertical: PetPopoverVerticalOrientation,
        horizontal: PetPopoverHorizontalOrientation
    ) {
        self.vertical = vertical
        self.horizontal = horizontal
    }
}

public struct PetPopoverPlacementResult: Sendable, Equatable {
    public let frame: CGRect
    public let orientation: PetPopoverOrientation

    public init(frame: CGRect, orientation: PetPopoverOrientation) {
        self.frame = frame
        self.orientation = orientation
    }
}

public enum PetPopoverPlacement {
    public static func resolve(
        anchorFrame: CGRect,
        requestedSize: CGSize,
        visibleFrame: CGRect,
        margin: CGFloat = 12,
        spacing: CGFloat = 8
    ) -> PetPopoverPlacementResult {
        let safe = PetPlacement.safeFrame(visibleFrame, margin: margin)
        let size = CGSize(
            width: min(max(0, requestedSize.width), safe.width),
            height: min(max(0, requestedSize.height), safe.height)
        )

        let availableAbove = safe.maxY - anchorFrame.maxY - spacing
        let availableBelow = anchorFrame.minY - safe.minY - spacing
        let vertical: PetPopoverVerticalOrientation = availableAbove >= availableBelow ? .above : .below

        let availableLeading = safe.maxX - anchorFrame.minX
        let availableTrailing = anchorFrame.maxX - safe.minX
        let horizontal: PetPopoverHorizontalOrientation = availableLeading >= availableTrailing ? .leading : .trailing

        let candidateX = horizontal == .leading
            ? anchorFrame.minX
            : anchorFrame.maxX - size.width
        let candidateY = vertical == .above
            ? anchorFrame.maxY + spacing
            : anchorFrame.minY - spacing - size.height
        let candidate = CGRect(origin: CGPoint(x: candidateX, y: candidateY), size: size)
        let clamped = PetPlacement.clamped(frame: candidate, to: visibleFrame, margin: margin)
        return PetPopoverPlacementResult(
            frame: clamped,
            orientation: PetPopoverOrientation(vertical: vertical, horizontal: horizontal)
        )
    }
}
