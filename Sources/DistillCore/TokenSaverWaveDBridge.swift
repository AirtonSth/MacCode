import Foundation
import CoreModel

/// Production bridge for task-20 Wave D. Default OFF.
/// Durable directory required for structure store-before-loss.
public enum TokenSaverWaveDBridge {
    public static let defaultEnabled = TokenSaverWaveDFamilies.defaultEnabled

    public static func sharedRuntime(
        boundUserID: String,
        bindingDigest: String,
        durableDirectory: URL
    ) -> TokenSaverWaveDRuntime {
        TokenSaverWaveDRuntime(
            boundUserID: boundUserID,
            bindingDigest: bindingDigest,
            durableDirectory: durableDirectory
        )
    }
}
