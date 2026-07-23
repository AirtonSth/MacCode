import Foundation

/// Wave B provider_cache_guard + tool_schema_deferral (task-14). Default OFF.
public enum TokenSaverCacheGuard {
    public static let taskID = "task-14"
    public static let defaultEnabled = false

    /// Live-zone only: candidate must not rewrite system prefix.
    public static func liveZoneOnly(systemBytes: Data, liveBytes: Data, candidate: Data) -> Bool {
        if systemBytes.isEmpty { return true }
        guard candidate.count >= systemBytes.count else { return false }
        return candidate.prefix(systemBytes.count) == systemBytes
    }

    public static func netCacheCostRegression(beforeHitRate: Double, afterHitRate: Double) -> Bool {
        afterHitRate + 1e-9 < beforeHitRate
    }

    public static func shouldEnableToolDeferral(hasCapability: Bool, catalogCount: Int, threshold: Int) -> Bool {
        defaultEnabled && hasCapability && catalogCount > threshold
    }

    public static func coreToolsPresent(tools: [String], core: [String]) -> Bool {
        Set(core).isSubset(of: Set(tools))
    }

    /// Admission: deny when system prefix rewritten or net cache regression.
    public static func admit(
        systemBytes: Data,
        liveBytes: Data,
        candidate: Data,
        beforeHitRate: Double,
        afterHitRate: Double
    ) -> Bool {
        guard defaultEnabled else { return false }
        guard liveZoneOnly(systemBytes: systemBytes, liveBytes: liveBytes, candidate: candidate) else { return false }
        guard !netCacheCostRegression(beforeHitRate: beforeHitRate, afterHitRate: afterHitRate) else { return false }
        return true
    }
}
