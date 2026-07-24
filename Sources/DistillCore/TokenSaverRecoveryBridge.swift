import Foundation
import CoreModel

/// Production bridge for recovery projections (task-16). Default OFF.
public enum TokenSaverRecoveryBridge {
    public static func observeRetrieve(
        handle: String,
        bytes: Data,
        original: Data,
        revoked: Bool = false
    ) -> Bool {
        TokenSaverRecoveryProjections.admitRetrieve(
            bytes: bytes, original: original, handle: handle, revoked: revoked
        )
    }

    public static func observeSearch(queryScope: String, resultScope: String) -> Bool {
        TokenSaverRecoveryProjections.admitSearch(
            queryScopeDigest: queryScope, resultScopeDigest: resultScope
        )
    }

    public static func observePrefetch(
        used: Bool,
        receipt: TokenSaverRecoveryProjections.MeasuredSavingsReceipt?,
        creditBindingDigest: String
    ) -> Int64 {
        TokenSaverRecoveryProjections.admitPrefetchSavings(
            used: used, receipt: receipt, creditBindingDigest: creditBindingDigest
        )
    }
}
