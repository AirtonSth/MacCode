import Foundation

/// Phased connection dual-track flags (plan-connection S-009 inventory).
/// Host-local UserDefaults — not remote config.
///
/// Defaults (when key is unset):
/// - `wake_phase_a` **on** — material silent wakes for Phase A kinds
/// - `wake_published_kinds` **on** — real host-published attention kinds (request/question/error/notification)
/// - `transport_keepalive_exp` **on** — longer HTTP keep-alive for 3G RRC
/// - `wake_phase_b_git`, `wake_outbox`, `selective_catchup` **off** until canary
/// Explicit UserDefaults writes still override (kill switch = set false).
public enum ConnectionFeatureFlags {
    public static let wakePhaseAKey = "connection.flag.wake_phase_a"
    public static let wakePublishedKindsKey = "connection.flag.wake_published_kinds"
    public static let wakePhaseBGitKey = "connection.flag.wake_phase_b_git"
    public static let wakeOutboxKey = "connection.flag.wake_outbox"
    public static let selectiveCatchUpKey = "connection.flag.selective_catchup"
    public static let transportKeepaliveExpKey = "connection.flag.transport_keepalive_exp"

    /// Read a flag: missing key → `defaultOn`; explicit bool wins (including false kill).
    public static func flagValue(key: String, defaultOn: Bool, defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultOn }
        return defaults.bool(forKey: key)
    }

    public static var wakePhaseAEnabled: Bool {
        get { flagValue(key: wakePhaseAKey, defaultOn: true) }
        set { UserDefaults.standard.set(newValue, forKey: wakePhaseAKey) }
    }

    /// Kill switch for the widened allowlist of kinds the host actually publishes
    /// (agent.request.opened, agent.user_input.requested, agent.run.error,
    /// notification.created). Default on; set false to fall back to core lifecycle only.
    public static var wakePublishedKindsEnabled: Bool {
        get { flagValue(key: wakePublishedKindsKey, defaultOn: true) }
        set { UserDefaults.standard.set(newValue, forKey: wakePublishedKindsKey) }
    }

    public static var wakePhaseBGitEnabled: Bool {
        get { flagValue(key: wakePhaseBGitKey, defaultOn: false) }
        set { UserDefaults.standard.set(newValue, forKey: wakePhaseBGitKey) }
    }

    public static var wakeOutboxEnabled: Bool {
        get { flagValue(key: wakeOutboxKey, defaultOn: false) }
        set { UserDefaults.standard.set(newValue, forKey: wakeOutboxKey) }
    }

    public static var selectiveCatchUpEnabled: Bool {
        get { flagValue(key: selectiveCatchUpKey, defaultOn: false) }
        set { UserDefaults.standard.set(newValue, forKey: selectiveCatchUpKey) }
    }

    public static var transportKeepaliveExperimentEnabled: Bool {
        get { flagValue(key: transportKeepaliveExpKey, defaultOn: true) }
        set { UserDefaults.standard.set(newValue, forKey: transportKeepaliveExpKey) }
    }

    /// Inventory for runbooks / retirement tracking.
    public static func inventory() -> [(key: String, enabled: Bool, owner: String, kill: String)] {
        [
            (wakePhaseAKey, wakePhaseAEnabled, "connection", "silent_429_rate or reconnect/min spike"),
            (wakePublishedKindsKey, wakePublishedKindsEnabled, "connection", "attention wake flood / false positive push"),
            (wakePhaseBGitKey, wakePhaseBGitEnabled, "connection", "git wake flood"),
            (wakeOutboxKey, wakeOutboxEnabled, "connection", "outbox backlog / 429 storm"),
            (selectiveCatchUpKey, selectiveCatchUpEnabled, "connection", "watermark stuck / partial catch-up fail"),
            (transportKeepaliveExpKey, transportKeepaliveExperimentEnabled, "connection", "RPC flap regression"),
        ]
    }
}
