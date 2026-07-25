import Foundation
import CoreModel

/// Production bridge for task-21 promotion/canary. Default OFF.
/// Durable directory is required (store-before-loss across relaunch).
public enum TokenSaverPromotionCanaryBridge {
    public static let defaultEnabled = TokenSaverPromotionCanary.defaultEnabled

    public static func sharedRuntime(
        boundUserID: String,
        bindingDigest: String,
        encryptedStore: TokenSaverEncryptedStore,
        scope: TokenSaverEncryptedStore.Scope
    ) -> TokenSaverPromotionCanaryRuntime {
        let originals = TokenSaverEncryptedOriginalStore(store: encryptedStore, scope: scope)
        return TokenSaverPromotionCanaryRuntime(
            boundUserID: boundUserID,
            bindingDigest: bindingDigest,
            originalStore: originals
        )
    }
}
