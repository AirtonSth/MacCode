import Foundation

/// Phased connection dual-track flags (plan-connection S-009 inventory).
/// Default **off** until S-008 gates pass. Host-local UserDefaults — not remote config.
public enum ConnectionFeatureFlags {
    public static let wakePhaseAKey = "connection.flag.wake_phase_a"
    public static let wakePhaseBGitKey = "connection.flag.wake_phase_b_git"
    public static let wakeOutboxKey = "connection.flag.wake_outbox"
    public static let selectiveCatchUpKey = "connection.flag.selective_catchup"
    public static let transportKeepaliveExpKey = "connection.flag.transport_keepalive_exp"

    public static var wakePhaseAEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: wakePhaseAKey) }
        set { UserDefaults.standard.set(newValue, forKey: wakePhaseAKey) }
    }

    public static var wakePhaseBGitEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: wakePhaseBGitKey) }
        set { UserDefaults.standard.set(newValue, forKey: wakePhaseBGitKey) }
    }

    public static var wakeOutboxEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: wakeOutboxKey) }
        set { UserDefaults.standard.set(newValue, forKey: wakeOutboxKey) }
    }

    public static var selectiveCatchUpEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: selectiveCatchUpKey) }
        set { UserDefaults.standard.set(newValue, forKey: selectiveCatchUpKey) }
    }

    public static var transportKeepaliveExperimentEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: transportKeepaliveExpKey) }
        set { UserDefaults.standard.set(newValue, forKey: transportKeepaliveExpKey) }
    }

    /// Inventory for runbooks / retirement tracking.
    public static func inventory() -> [(key: String, enabled: Bool, owner: String, kill: String)] {
        [
            (wakePhaseAKey, wakePhaseAEnabled, "connection", "silent_429_rate or reconnect/min spike"),
            (wakePhaseBGitKey, wakePhaseBGitEnabled, "connection", "git wake flood"),
            (wakeOutboxKey, wakeOutboxEnabled, "connection", "outbox backlog / 429 storm"),
            (selectiveCatchUpKey, selectiveCatchUpEnabled, "connection", "watermark stuck / partial catch-up fail"),
            (transportKeepaliveExpKey, transportKeepaliveExperimentEnabled, "connection", "RPC flap regression"),
        ]
    }
}
