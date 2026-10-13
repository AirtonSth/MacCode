import AppKit
import Persistence
import SwiftUI

@MainActor
public final class PetViewModel: ObservableObject {
    @Published public private(set) var animationState: PetAnimationState = .idle
    @Published public private(set) var currentImage: NSImage?
    @Published public private(set) var items: [PetAttentionItem] = []
    @Published public private(set) var count = 0
    @Published public private(set) var activeThreads: [PetActiveThreadItem] = []
    @Published public private(set) var activeThreadCount = 0
    @Published private(set) var activityCounts = PetActivityCounts.zero
    @Published public private(set) var settings: AppSettings
    @Published public var routeError: String?

    private(set) var currentFrame: PetAtlasFrame?

    public init(settings: AppSettings) {
        self.settings = settings
    }

    /// Single external indicator, gated by the existing ready-counter preference.
    public var badgeText: String? {
        guard activityCounts.isAvailable else { return nil }
        return PetAttentionCountFormatter.badgeText(
            count: activityCounts.needsYou,
            isEnabled: settings.petReadyCounterEnabled
        )
    }

    /// Blue badge: unique active agent threads. Not gated by the ready-counter setting.
    public var activeBadgeText: String? {
        PetActiveThreadCountFormatter.badgeText(count: activeThreadCount)
    }

    public var accessibilityValue: String {
        guard activityCounts.isAvailable else { return "Activity status unavailable" }
        let running = activityCounts.running == 1 ? "1 running" : "\(activityCounts.running) running"
        let needsYou = PetAttentionCountFormatter.accessibilityValue(count: activityCounts.needsYou)
        return "Activity: \(running), \(needsYou)"
    }

    public var isPopoverEmpty: Bool {
        items.isEmpty && activeThreads.isEmpty
    }

    public func setAnimationState(_ state: PetAnimationState) {
        animationState = state
    }

    func setFrame(_ frame: PetAtlasFrame) {
        currentFrame = frame
        currentImage = frame.appKitImage
    }

    public func apply(snapshot: PetAttentionSnapshot) {
        items = snapshot.items
        count = snapshot.count
    }

    public func apply(activeThreads: [PetActiveThreadItem]) {
        self.activeThreads = activeThreads
        activeThreadCount = activeThreads.count
    }

    func apply(activityCounts: PetActivityCounts) {
        self.activityCounts = activityCounts
    }

    public func apply(settings: AppSettings) {
        self.settings = settings
    }
}
