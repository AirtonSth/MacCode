import Foundation

/// Graphify dependency hardening contract (S9 / T-003).
///
/// Graphify remains gated by `tokenSaverEnabled && graphifyEnabled` at call sites
/// via `AppSettings.isGraphifyRuntimeActive`. This type freezes pin/BOM/bounds.

public struct GraphifyRuntimePin: Sendable, Equatable, Codable {
    public var approvedVersion: String
    public var sha256: String
    public var license: String
    public var bomNote: String

    public init(
        approvedVersion: String,
        sha256: String,
        license: String = "see upstream BOM",
        bomNote: String = "external runtime dependency; not vendored"
    ) {
        self.approvedVersion = approvedVersion
        self.sha256 = sha256
        self.license = license
        self.bomNote = bomNote
    }
}

public enum GraphifyRuntimeHardening {
    /// Placeholder pin — operators must replace with measured CLI checksum before
    /// claiming a physical tier. Empty sha means "not yet physically pinned".
    public static let defaultPin = GraphifyRuntimePin(
        approvedVersion: "unpinned-pending-canary",
        sha256: "",
        license: "external",
        bomNote: "Pin after physical canary; do not invent checksums."
    )

    public static let maxStdoutCaptureBytes = 4 * 1024 * 1024
    public static let maxStderrCaptureBytes = 1 * 1024 * 1024
    public static let maxArtifactBytes = 512 * 1024 * 1024

    public static func isPinComplete(_ pin: GraphifyRuntimePin = defaultPin) -> Bool {
        !pin.approvedVersion.isEmpty
            && pin.approvedVersion != "unpinned-pending-canary"
            && pin.sha256.count == 64
    }

    /// Active rebuild must be cancellable before watchers stop.
    public static func mayStopWatchers(rebuildInFlight: Bool, rebuildCancelled: Bool) -> Bool {
        if rebuildInFlight { return rebuildCancelled }
        return true
    }
}

/// Token Saver fairness metrics without enabling work when disabled (S9).
public struct TokenSaverFairnessSample: Sendable, Equatable {
    public var queueAgeMs: Double?
    public var timeoutMs: Double?
    public var failOpenReason: String?
    public var tokenSaverEnabled: Bool
    public var graphifyRuntimeActive: Bool

    public init(
        queueAgeMs: Double? = nil,
        timeoutMs: Double? = nil,
        failOpenReason: String? = nil,
        tokenSaverEnabled: Bool,
        graphifyRuntimeActive: Bool
    ) {
        self.queueAgeMs = queueAgeMs
        self.timeoutMs = timeoutMs
        self.failOpenReason = failOpenReason
        self.tokenSaverEnabled = tokenSaverEnabled
        self.graphifyRuntimeActive = graphifyRuntimeActive
    }

    /// Graphify metrics must never claim activity when Token Saver is off.
    public var isGateConsistent: Bool {
        if !tokenSaverEnabled { return graphifyRuntimeActive == false }
        return true
    }
}
