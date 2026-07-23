import Foundation
import CoreModel

/// Production bridge for task-21 promotion/canary. Default OFF.
public enum TokenSaverPromotionCanaryBridge {
    public static let defaultEnabled = TokenSaverPromotionCanary.defaultEnabled

    public static func sharedRuntime(
        boundUserID: String,
        bindingDigest: String,
        durableDirectory: URL? = nil
    ) -> TokenSaverPromotionCanaryRuntime {
        TokenSaverPromotionCanaryRuntime(
            boundUserID: boundUserID,
            bindingDigest: bindingDigest,
            durableDirectory: durableDirectory
        )
    }
}
