import Foundation

/// Material wake taxonomy for Mac→iOS APNs (plan-connection S-001 / T-002).
/// Stream-only kinds must never become push. Phase B/C only behind flags.
public enum MaterialWakeClass: String, Sendable, Equatable, CaseIterable {
    /// Visible alert + silent catch-up wake (critical user attention).
    case criticalAlertAndSilent = "critical_alert+silent"
    /// Silent catch-up only (state change without banner requirement).
    case silent = "silent"
    /// Silent with force (bypass coalesce) — e.g. host boot/identity rebaseline.
    case silentForce = "silent_force"
    /// Alert only (security).
    case criticalAlert = "critical_alert"
    /// Phase B: silent or alert depending on product path.
    case silentOrAlert = "silent_or_alert"
    /// Never push — live stream / heartbeat only.
    case streamOnly = "stream_only"
}

/// Frozen kind → wake class map (plan A-003 default). Expansions only via phase flags.
public enum MaterialWakeTaxonomy: Sendable {
    /// Phase A kinds that may emit silent catch-up when flag `wake_phase_a` is on.
    public static let phaseAKinds: Set<String> = [
        "agent.run.started",
        "agent.run.completed",
        "agent.run.failed",
        "agent.run.cancelled",
        "agent.attention",
        "agent.approval",
        "agent.question",
        "host.boot_epoch",
        "host.identity",
        "device.revoke",
        "session.unauthorized",
    ]

    public static func classification(forEventKind kind: String) -> MaterialWakeClass {
        switch kind {
        case "agent.run.started",
             "agent.run.completed",
             "agent.run.failed",
             "agent.attention",
             "agent.approval",
             "agent.question":
            return .criticalAlertAndSilent
        case "agent.run.cancelled":
            return .silent
        case "host.boot_epoch", "host.identity":
            return .silentForce
        case "device.revoke", "session.unauthorized":
            return .criticalAlert
        case "git.commit", "git.push", "git.conflict", "git.checkout", "git.branch_created":
            return .silentOrAlert // Phase B
        case "settings.updated":
            return .silent // Phase C digest
        case let k where k.hasPrefix("surface.output")
            || k.hasPrefix("agent.item.delta")
            || k.hasPrefix("heartbeat")
            || k == "events.ping"
            || k == "events.pong":
            return .streamOnly
        default:
            // Unknown kinds default to stream_only — never auto-push (fail closed on flood).
            return .streamOnly
        }
    }

    /// Whether this class may emit a silent catch-up under Phase A rollout.
    public static func phaseAAllowsSilent(_ class: MaterialWakeClass) -> Bool {
        switch `class` {
        case .criticalAlertAndSilent, .silent, .silentForce:
            return true
        case .criticalAlert, .silentOrAlert, .streamOnly:
            return false
        }
    }

    public static func shouldForceSilent(_ class: MaterialWakeClass) -> Bool {
        `class` == .silentForce
    }
}
