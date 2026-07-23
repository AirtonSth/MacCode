import Foundation
import CoreModel

/// Production bridge for task-18 queue coalesce / compaction / checkpoint. Default OFF.
public enum TokenSaverQueueCoalesceBridge {
    public static let defaultEnabled = TokenSaverQueueCoalesce.defaultEnabled

    public static func sharedRuntime(storeDirectory: URL? = nil) -> TokenSaverQueueCoalesceRuntime {
        if let dir = storeDirectory,
           let fileStore = try? TokenSaverQueueCoalesceRuntime.FileDurabilityStore(directory: dir) {
            return TokenSaverQueueCoalesceRuntime(store: fileStore)
        }
        return TokenSaverQueueCoalesceRuntime()
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
