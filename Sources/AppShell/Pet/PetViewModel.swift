import AppKit
import Persistence
import SwiftUI

@MainActor
public final class PetViewModel: ObservableObject {
    @Published public private(set) var animationState: PetAnimationState = .idle
    @Published public private(set) var currentImage: NSImage?
    @Published public private(set) var items: [PetAttentionItem] = []
    @Published public private(set) var count = 0
    @Published public private(set) var settings: AppSettings
    @Published public var routeError: String?

    private(set) var currentFrame: PetAtlasFrame?

    public init(settings: AppSettings) {
        self.settings = settings
    }

    public var badgeText: String? {
        PetAttentionCountFormatter.badgeText(
            count: count,
            isEnabled: settings.petReadyCounterEnabled
        )
    }

    public var accessibilityValue: String {
        PetAttentionCountFormatter.accessibilityValue(count: count)
    }

    public var needsYouItems: [PetAttentionItem] {
        items.filter { $0.kind.needsUserAction }
    }

    public var completedItems: [PetAttentionItem] {
        items.filter { !$0.kind.needsUserAction }
    }

    public func setAnimationState(_ state: PetAnimationState) {
        animationState = state
    }

    func setFrame(_ frame: PetAtlasFrame) {
        currentFrame = frame
        currentImage = NSImage(
            cgImage: frame.displayImage,
            size: NSSize(width: frame.displayImage.width, height: frame.displayImage.height)
        )
    }

    public func apply(snapshot: PetAttentionSnapshot) {
        items = snapshot.items
        count = snapshot.count
    }

    public func apply(settings: AppSettings) {
        self.settings = settings
    }
}
