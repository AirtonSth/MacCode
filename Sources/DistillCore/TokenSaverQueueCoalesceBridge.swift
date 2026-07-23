import Foundation
import CoreModel

/// Production bridge for task-18 queue coalesce / compaction / checkpoint. Default OFF.
public enum TokenSaverQueueCoalesceBridge {
    public static let defaultEnabled = TokenSaverQueueCoalesce.defaultEnabled

    public static func sharedRuntime(
        storeDirectory: URL,
        encryptedStore: TokenSaverEncryptedStore,
        scope: TokenSaverEncryptedStore.Scope
    ) -> TokenSaverQueueCoalesceRuntime? {
        let originals = TokenSaverEncryptedOriginalStore(store: encryptedStore, scope: scope)
        guard let fileStore = try? TokenSaverQueueCoalesceRuntime.FileDurabilityStore(
            directory: storeDirectory,
            originalStore: originals
        ) else { return nil }
        return TokenSaverQueueCoalesceRuntime(store: fileStore)
    }

    public static func observeCoalesce(
        _ runtime: TokenSaverQueueCoalesceRuntime,
        intents: [TokenSaverQueueCoalesceRuntime.QueuedIntent]
    ) -> TokenSaverQueueCoalesceRuntime.CoalesceDecision {
        runtime.coalescePreview(intents).decision
    }

    public static func observeCheckpoint(
        _ runtime: TokenSaverQueueCoalesceRuntime,
        receipts: [TokenSaverQueueCoalesceRuntime.HostReceipt],
        pendingMutation: Bool,
        pendingApproval: Bool
    ) -> TokenSaverQueueCoalesceRuntime.Checkpoint? {
        runtime.buildCheckpoint(
            receipts: receipts,
            narrativeFromMLX: nil,
            pendingMutation: pendingMutation,
            pendingApproval: pendingApproval
        )
    }
}
