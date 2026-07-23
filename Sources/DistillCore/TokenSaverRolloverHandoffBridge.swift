import Foundation
import CoreModel

/// Production bridge for task-19 rollover / handoff / lossy. Default OFF.
/// When `storeDirectory` is provided, durable construction must succeed (no silent memory fallback).
public enum TokenSaverRolloverHandoffBridge {
    public static let defaultEnabled = TokenSaverRolloverHandoff.defaultEnabled

    public static func sharedRuntime(
        boundUserID: String,
        storeDirectory: URL,
        encryptedStore: TokenSaverEncryptedStore,
        scope: TokenSaverEncryptedStore.Scope
    ) -> TokenSaverRolloverHandoffRuntime? {
        let originals = TokenSaverEncryptedOriginalStore(store: encryptedStore, scope: scope)
        guard let fileStore = try? TokenSaverRolloverHandoffRuntime.FileDurabilityStore(
            directory: storeDirectory,
            originalStore: originals
        ) else { return nil }
        return TokenSaverRolloverHandoffRuntime(
            boundUserID: boundUserID,
            bindingDigest: scope.digest,
            store: fileStore
        )
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
