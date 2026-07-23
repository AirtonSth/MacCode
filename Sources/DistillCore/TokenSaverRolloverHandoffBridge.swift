import Foundation
import CoreModel

/// Production bridge for task-19 rollover / handoff / lossy. Default OFF.
/// Hosts construct a user-bound runtime and optionally a durable directory for relaunch.
public enum TokenSaverRolloverHandoffBridge {
    public static let defaultEnabled = TokenSaverRolloverHandoff.defaultEnabled

    public static func sharedRuntime(
        boundUserID: String,
        storeDirectory: URL? = nil
    ) -> TokenSaverRolloverHandoffRuntime {
        if let dir = storeDirectory,
           let fileStore = try? TokenSaverRolloverHandoffRuntime.FileDurabilityStore(directory: dir) {
            return TokenSaverRolloverHandoffRuntime(boundUserID: boundUserID, store: fileStore)
        }
        return TokenSaverRolloverHandoffRuntime(boundUserID: boundUserID)
    }

    public static func observeFork(
        _ runtime: TokenSaverRolloverHandoffRuntime,
        parentHead: String,
        kind: TokenSaverRolloverHandoffRuntime.ForkKind,
        requestingUserID: String
    ) -> TokenSaverRolloverHandoffRuntime.Branch? {
        runtime.fork(
            op: .init(parentHead: parentHead, kind: kind),
            requestingUserID: requestingUserID
        )
    }
}
