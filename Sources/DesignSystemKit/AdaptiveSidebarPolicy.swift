import Foundation
import CoreGraphics

public enum AdaptiveSidebarIntent: String, Sendable {
    case auto
    case forcedVisible
    case forcedHidden
}

public enum AdaptiveSidebarLayoutEvent: Sendable {
    case structural
    case resize
}

public struct AdaptiveSidebarDecision: Equatable, Sendable {
    public let isVisible: Bool
    public let didChangeAutomatically: Bool

    public init(isVisible: Bool, didChangeAutomatically: Bool) {
        self.isVisible = isVisible
        self.didChangeAutomatically = didChangeAutomatically
    }
}

public enum AdaptiveSidebarPolicy {
    public static let defaultHysteresis: CGFloat = 120
    public static let defaultCooldown: TimeInterval = 2

    public static func nextVisibility(
        availableExtent: CGFloat,
        contentMinimumExtent: CGFloat,
        sidebarExtent: CGFloat,
        currentVisible: Bool,
        intent: AdaptiveSidebarIntent,
        event: AdaptiveSidebarLayoutEvent,
        now: TimeInterval,
        lastAutomaticChange: TimeInterval?,
        hysteresis: CGFloat = defaultHysteresis,
        cooldown: TimeInterval = defaultCooldown,
        forcedVisibleHardMinimumRatio: CGFloat = 0.72
    ) -> AdaptiveSidebarDecision {
        switch intent {
        case .forcedHidden:
            return AdaptiveSidebarDecision(isVisible: false, didChangeAutomatically: currentVisible)
        case .forcedVisible:
            let hardMinimum = contentMinimumExtent * forcedVisibleHardMinimumRatio
            let canPreserveManualShow = availableExtent - sidebarExtent >= hardMinimum
            return AdaptiveSidebarDecision(isVisible: canPreserveManualShow, didChangeAutomatically: currentVisible != canPreserveManualShow)
        case .auto:
            break
        }

        let elapsed = lastAutomaticChange.map { now - $0 } ?? .greatestFiniteMagnitude
        let canChange = event == .structural || elapsed >= cooldown

        if currentVisible {
            let contentExtentAfterSidebar = availableExtent - sidebarExtent
            guard contentExtentAfterSidebar < contentMinimumExtent, canChange else {
                return AdaptiveSidebarDecision(isVisible: true, didChangeAutomatically: false)
            }
            return AdaptiveSidebarDecision(isVisible: false, didChangeAutomatically: true)
        }

        let contentExtentAfterShowingSidebar = availableExtent - sidebarExtent
        guard contentExtentAfterShowingSidebar >= contentMinimumExtent + hysteresis, canChange else {
            return AdaptiveSidebarDecision(isVisible: false, didChangeAutomatically: false)
        }
        return AdaptiveSidebarDecision(isVisible: true, didChangeAutomatically: true)
    }
}
