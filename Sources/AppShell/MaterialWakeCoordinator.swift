import Foundation
import os
import SocketServer

/// S-005a: expand silent catch-up emission for Phase A material kinds.
/// Subscribes to EventBus; never pushes stream_only kinds. Behind `wake_phase_a` flag (default off).
public final class MaterialWakeCoordinator: @unchecked Sendable {
    public static let shared = MaterialWakeCoordinator()
    private static let log = Logger(subsystem: "io.remotecode.app", category: "material-wake")

    private let lock = NSLock()
    private var subscriptionToken: UUID?
    private weak var bridge: PrivateNotificationBridge?

    private init() {}

    public func start(bridge: PrivateNotificationBridge) {
        lock.lock()
        self.bridge = bridge
        if subscriptionToken == nil {
            subscriptionToken = EventBus.shared.subscribe(since: nil) { [weak self] event in
                self?.handle(event: event)
            }
        }
        lock.unlock()
        Self.log.info("MaterialWakeCoordinator started")
    }

    public func stop() {
        lock.lock()
        if let token = subscriptionToken {
            EventBus.shared.unsubscribe(token)
            subscriptionToken = nil
        }
        bridge = nil
        lock.unlock()
    }

    /// Pure seam for tests: should this event produce a silent wake under current flags?
    public static func shouldSilentWake(
        kind: String,
        wakePhaseA: Bool,
        wakePhaseBGit: Bool
    ) -> (allowed: Bool, force: Bool, reason: String) {
        let classification = MaterialWakeTaxonomy.classification(forEventKind: kind)
        switch classification {
        case .streamOnly:
            return (false, false, "stream_only")
        case .criticalAlert:
            // Alert path remains the primary UX; silent optional only via Phase A list.
            return (false, false, "critical_alert_only")
        case .silentOrAlert:
            guard wakePhaseBGit else { return (false, false, "phase_b_off") }
            return (true, false, "phase_b_git")
        case .criticalAlertAndSilent, .silent, .silentForce:
            guard wakePhaseA else { return (false, false, "phase_a_off") }
            guard MaterialWakeTaxonomy.phaseAAllowsSilent(classification) else {
                return (false, false, "not_phase_a_silent")
            }
            let force = MaterialWakeTaxonomy.shouldForceSilent(classification)
            return (true, force, kind)
        }
    }

    private func handle(event: EventBus.Event) {
        // Event shape: check existing EventBus Event type
        let kind = eventKind(event)
        let decision = Self.shouldSilentWake(
            kind: kind,
            wakePhaseA: ConnectionFeatureFlags.wakePhaseAEnabled,
            wakePhaseBGit: ConnectionFeatureFlags.wakePhaseBGitEnabled
        )
        guard decision.allowed else { return }
        lock.lock()
        let bridge = self.bridge
        lock.unlock()
        guard let bridge else { return }
        let payload = SilentCatchUpV1(reason: decision.reason)
        let force = decision.force
        Task {
            await bridge.deliverSilentCatchUp(
                hostHint: kind,
                force: force,
                payload: payload
            )
        }
    }

    private func eventKind(_ event: EventBus.Event) -> String {
        // Prefer `.kind` if available; fall back via Mirror
        return event.kind
    }
}
