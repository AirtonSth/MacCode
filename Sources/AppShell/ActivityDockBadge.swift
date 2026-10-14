import AppKit
import os

/// Red Dock-icon badge carrying the global needs-you count: the same number
/// and "99+" cap as the pet's dot. Fed by the shared activity projection the
/// sidebar keeps refreshing, so it does not depend on the pet being enabled.
@MainActor
final class ActivityDockBadge {
    private let projection: PetActivityCountsProjection
    private let apply: (String?) -> Void
    private var observer: UUID?
    private var appliedLabel: String??
    private static let log = Logger(subsystem: "io.remotecode.app", category: "dock")

    init(
        projection: PetActivityCountsProjection = .shared,
        apply: @escaping (String?) -> Void = { NSApp.dockTile.badgeLabel = $0 }
    ) {
        self.projection = projection
        self.apply = apply
    }

    /// Nil hides the badge: nothing needs the user, or the counts are unknown.
    static func label(for counts: PetActivityCounts) -> String? {
        guard counts.isAvailable else { return nil }
        return PetAttentionCountFormatter.badgeText(count: counts.needsYou)
    }

    func start() {
        guard observer == nil else { return }
        observer = projection.observe { [weak self] global, _ in
            self?.update(global)
        }
    }

    func stop() {
        if let observer { projection.removeObserver(observer) }
        observer = nil
        update(.zero)
    }

    private func update(_ counts: PetActivityCounts) {
        let label = Self.label(for: counts)
        // The Dock redraws on every write; skip the ones that change nothing.
        guard appliedLabel != .some(label) else { return }
        appliedLabel = .some(label)
        apply(label)
        Self.log.info("dock.badge label=\(label ?? "none", privacy: .public)")
    }
}
