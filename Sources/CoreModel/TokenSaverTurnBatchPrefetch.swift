import Foundation

/// Wave C agent_turn_batch + local_discovery_prefetch (task-17). Default OFF.
/// Policy façade; host runtimes: `TokenSaverTurnBatchRuntime`, `TokenSaverDiscoveryPrefetchRuntime`.
public enum TokenSaverTurnBatchPrefetch {
    public static let taskID = "task-17"
    public static let defaultEnabled = false

    public static func batchMayContinue(
        unknownOutputAffectsDownstream: Bool,
        mutationApproved: Bool,
        isMutation: Bool,
        live: Bool = defaultEnabled
    ) -> Bool {
        guard live else { return false }
        if unknownOutputAffectsDownstream { return false }
        if isMutation && !mutationApproved { return false }
        return true
    }

    public static func prefetchAllowed(
        readOnly: Bool,
        noNetwork: Bool,
        inWorkspace: Bool,
        live: Bool = defaultEnabled
    ) -> Bool {
        live && readOnly && noNetwork && inWorkspace
    }

    public static func mlxMayMutate() -> Bool { false }

    /// Confirmed savings only via trusted MeasuredSavingsReceipt + binding match.
    /// Gated by `live` (defaults to defaultEnabled=false) so OFF never credits tokens.
    public static func unusedPrefetchSavings(
        used: Bool,
        receipt: TokenSaverRecoveryProjections.MeasuredSavingsReceipt?,
        creditBindingDigest: String,
        live: Bool = defaultEnabled
    ) -> Int64 {
        guard live else { return 0 }
        return TokenSaverRecoveryProjections.prefetchConfirmedSavings(
            used: used,
            receipt: receipt,
            creditBindingDigest: creditBindingDigest
        )
    }
}
