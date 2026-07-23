import Foundation
import CoreModel

/// Production bridge for task-19 rollover / handoff / lossy. Default OFF.
/// When `storeDirectory` is provided, durable construction must succeed (no silent memory fallback).
public enum TokenSaverRolloverHandoffBridge {
    public static let defaultEnabled = TokenSaverRolloverHandoff.defaultEnabled

    public static func sharedRuntime(
        boundUserID: String,
        storeDirectory: URL? = nil
    ) -> TokenSaverRolloverHandoffRuntime? {
        if let dir = storeDirectory {
            guard let fileStore = try? TokenSaverRolloverHandoffRuntime.FileDurabilityStore(directory: dir) else {
                return nil
            }
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
