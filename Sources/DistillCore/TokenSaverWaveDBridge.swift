import Foundation
import CoreModel

/// Production bridge for task-20 Wave D. Default OFF.
public enum TokenSaverWaveDBridge {
    public static let defaultEnabled = TokenSaverWaveDFamilies.defaultEnabled

    public static func sharedRuntime(boundUserID: String, bindingDigest: String) -> TokenSaverWaveDRuntime {
        TokenSaverWaveDRuntime(boundUserID: boundUserID, bindingDigest: bindingDigest)
    }
}
