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
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        let sha = pin.sha256.lowercased()
        return !pin.approvedVersion.isEmpty
            && pin.approvedVersion != "unpinned-pending-canary"
            && sha.count == 64
            && sha.unicodeScalars.allSatisfy { hex.contains($0) }
            && !pin.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !pin.bomNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Active rebuild must be cancellable before watchers stop.
    public static func mayStopWatchers(rebuildInFlight: Bool, rebuildCancelled: Bool) -> Bool {
        if rebuildInFlight { return rebuildCancelled }
        return true
    }

    /// Bound process pipe capture. Prefer over unbounded `readDataToEndOfFile`.
    /// Retains only the first `maxBytes` while continuing to drain the pipe so a
    /// verbose child cannot block on a full pipe until timeout.
    public static func boundedRead(handle: FileHandle, maxBytes: Int) -> Data {
        let limit = max(0, maxBytes)
        var collected = Data()
        if limit > 0 {
            collected.reserveCapacity(min(limit, 64 * 1024))
        }
        while true {
            let want = limit == 0 ? 64 * 1024 : min(64 * 1024, max(1, limit - collected.count + 64 * 1024))
            let chunk = handle.readData(ofLength: want)
            if chunk.isEmpty { break }
            if collected.count < limit {
                let room = limit - collected.count
                if chunk.count <= room {
                    collected.append(chunk)
                } else {
                    collected.append(chunk.prefix(room))
                    // Keep draining remainder of this chunk and subsequent data.
                }
            }
            // When already at cap, discard further bytes (drain only).
        }
        return collected
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
