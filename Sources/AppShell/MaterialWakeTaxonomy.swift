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

/// Coalesce bucket identity for silent catch-up. Separate classes so a
/// run-progress wake cannot swallow an attention wake in the same 30s window.
public enum MaterialWakeCoalesceClass: String, Sendable, Equatable, CaseIterable {
    /// Approval / question / error — highest non-force priority.
    case attention = "attention"
    /// Run started/completed lifecycle (progress, not blocking UI).
    case runProgress = "run_progress"
    /// In-app notification created.
    case notification = "notification"
    /// Host boot/identity rebaseline (force path).
    case boot = "boot"
    /// F5: Tailcat endpoint digest changed; never produced by an EventBus kind.
    case tailcat = "tailcat"
    /// Phase B git material kinds.
    case git = "git"
    /// Fallback bucket for unclassified silent reasons.
    case other = "other"
}

/// F5: at most `capacity` delivered silent wakes per rolling hour per
/// device; a lower class is refused earlier, so attention always has a slot.
public enum MaterialWakeBudget: Sendable {
    public static let windowSeconds: TimeInterval = 60 * 60
    public static let capacity = 3

    /// The class is admitted while `used` is below this.
    public static func limit(for coalesceClass: MaterialWakeCoalesceClass) -> Int {
        // No `default`: a new class must not compile until it has a limit.
        switch coalesceClass {
        case .attention:
            return capacity
        case .tailcat, .boot, .notification:
            return 2
        case .runProgress, .git, .other:
            return 1
        }
    }

    /// Delivery times still inside the window: `now - windowSeconds < t <= now`.
    /// A time later than `now` (the wall clock was set back) is dropped too.
    public static func sentInWindow(_ sent: [TimeInterval], now: Date) -> [TimeInterval] {
        let end = now.timeIntervalSince1970
        return sent.filter { $0 > end - windowSeconds && $0 <= end }
    }

    /// `used` = delivered sends in the window plus sends in flight.
    public static func admits(_ coalesceClass: MaterialWakeCoalesceClass, used: Int) -> Bool {
        used < limit(for: coalesceClass)
    }
}

/// Frozen kind → wake class map (plan A-003 default). Expansions only via phase flags.
public enum MaterialWakeTaxonomy: Sendable {
    /// Core Phase A lifecycle kinds that already have producers under `wake_phase_a`.
    /// Note: `agent.run.started` is intentionally excluded — Agent App visible
    /// push is only for terminal outcomes / user-action requests (main agent).
    public static let phaseACoreKinds: Set<String> = [
        "agent.run.completed",
        "agent.run.failed",
        "host.boot_epoch",
        "device.revoke",
    ]

    /// Kinds the host actually publishes for user-facing attention states.
    /// Gated by `wake_published_kinds` (default on; kill switch = false).
    /// Replaces the former phantom allowlist (agent.approval / agent.question /
    /// agent.attention / agent.run.cancelled / host.identity / session.unauthorized)
    /// which had zero publishers and therefore never woke a phone.
    public static let publishedAttentionKinds: Set<String> = [
        "agent.request.opened",
        "agent.user_input.requested",
        "agent.run.error",
        "notification.created",
    ]

    /// Union used by tests / inventory: core + published attention kinds.
    public static let phaseAKinds: Set<String> = phaseACoreKinds.union(publishedAttentionKinds)

    public static func classification(forEventKind kind: String) -> MaterialWakeClass {
        switch kind {
        case "agent.run.completed",
             "agent.run.failed",
             "agent.request.opened",
             "agent.user_input.requested",
             "agent.run.error":
            return .criticalAlertAndSilent
        // Mid-run start is not a user-facing push trigger (finish / action only).
        case "agent.run.started":
            return .streamOnly
        case "notification.created":
            return .silent
        case "host.boot_epoch":
            return .silentForce
        case "device.revoke":
            return .criticalAlert
        case "git.commit", "git.push", "git.checkout", "git.branch_created":
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
            // Includes retired phantom names (agent.approval, agent.question, …).
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

    /// Map event kind → coalesce class so attention is never bucket-shared with run progress.
    public static func coalesceClass(forEventKind kind: String) -> MaterialWakeCoalesceClass {
        switch kind {
        case "agent.request.opened",
             "agent.user_input.requested",
             "agent.run.error",
             "agent.run.failed":
            return .attention
        case "agent.run.completed":
            return .runProgress
        case "agent.run.started":
            return .other
        case "notification.created":
            return .notification
        case "host.boot_epoch":
            return .boot
        case "git.commit", "git.push", "git.checkout", "git.branch_created":
            return .git
        default:
            return .other
        }
    }

    /// Opaque `rc2_reason` token for silent_catchup.v1 (sanitized downstream).
    public static func silentReason(forEventKind kind: String) -> String {
        // Keep reason = kind so iOS / metrics can attribute wakes; contract
        // sanitizer maps dots to underscores and caps length.
        kind
    }
}
