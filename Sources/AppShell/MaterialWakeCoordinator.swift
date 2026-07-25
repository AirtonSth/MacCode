import Foundation
import os
import SocketServer

/// S-005a: expand silent catch-up emission for Phase A material kinds.
/// Subscribes to EventBus; never pushes stream_only kinds. Gated by `wake_phase_a`
/// (default **on**; kill via UserDefaults false).
public final class MaterialWakeCoordinator: @unchecked Sendable {
    public static let shared = MaterialWakeCoordinator()
    private static let log = Logger(subsystem: "io.remotecode.app", category: "material-wake")

    private let lock = NSLock()
    private var subscriptionToken: UUID?
    private weak var bridge: PrivateNotificationBridge?
    private var bootEpochProvider: (() -> String?)?
    private var watermarkProvider: (() -> String?)?

    private init() {}

    /// - Parameters:
    ///   - bootEpochProvider: host boot epoch for silent_catchup.v1 (S-006).
    ///   - watermarkProvider: monotonic event bus seq string for `rc2_wm`.
    public func start(
        bridge: PrivateNotificationBridge,
        bootEpochProvider: @escaping () -> String? = { nil },
        watermarkProvider: @escaping () -> String? = { String(EventBus.shared.currentSeq) }
    ) {
        lock.lock()
        self.bridge = bridge
        self.bootEpochProvider = bootEpochProvider
        self.watermarkProvider = watermarkProvider
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
        bootEpochProvider = nil
        watermarkProvider = nil
        lock.unlock()
    }

    /// Pure seam: build v1 payload for a material event (tests assert fields).
    public static func makeSilentPayload(
        eventSeq: Int64,
        reason: String,
        bootEpoch: String?,
        watermark: String?
    ) -> SilentCatchUpV1 {
        SilentCatchUpV1(
            catchUp: true,
            watermark: watermark ?? String(eventSeq),
            sinceSeq: String(eventSeq),
            bootEpoch: bootEpoch,
            reason: reason
        )
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
        let bootEpoch = bootEpochProvider?()
        let watermark = watermarkProvider?()
        lock.unlock()
        guard let bridge else { return }
        let payload = Self.makeSilentPayload(
            eventSeq: event.seq,
            reason: decision.reason,
            bootEpoch: bootEpoch,
            watermark: watermark
        )
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
