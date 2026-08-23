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
    @Published public private(set) var settings: AppSettings
    @Published public var routeError: String?

    private(set) var currentFrame: PetAtlasFrame?

    public init(settings: AppSettings) {
        self.settings = settings
    }

    /// Red badge: attention/ready items. Gated by petReadyCounterEnabled.
    public var badgeText: String? {
        PetAttentionCountFormatter.badgeText(
            count: count,
            isEnabled: settings.petReadyCounterEnabled
        )
    }

    /// Blue badge: unique active agent threads. Not gated by the ready-counter setting.
    public var activeBadgeText: String? {
        PetActiveThreadCountFormatter.badgeText(count: activeThreadCount)
    }

    public var accessibilityValue: String {
        PetActiveThreadCountFormatter.combinedAccessibilityValue(
            activeCount: activeThreadCount,
            attentionCount: count
        )
    }

    public var needsYouItems: [PetAttentionItem] {
        items.filter { $0.kind.needsUserAction }
    }

    public var completedItems: [PetAttentionItem] {
        items.filter { !$0.kind.needsUserAction }
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

    public func apply(settings: AppSettings) {
        self.settings = settings
    }
}
