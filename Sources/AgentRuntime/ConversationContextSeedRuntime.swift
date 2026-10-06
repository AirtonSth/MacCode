import Foundation
import CoreModel

/// Prepares the host-owned RCSEED1 document and the content-free slot receipts
/// that carry the prior conversation into a fresh provider session.
public struct ConversationContextSeedPreparer: Sendable {
    public init() {}

    public func prepare(
        snapshot: ConversationContextSnapshot,
        request: AgentRunRequest,
        destinationProviderThreadId: String
    ) -> PreparedConversationContextSeed? {
        guard let prepared = ConversationContextSeed.prepare(snapshot: snapshot) else {
            return nil
        }
        let receipts = snapshot.items.map { item in
            ConversationContextSeedReceipt(
                runId: request.runId.value.uuidString,
                destinationProviderThreadId: destinationProviderThreadId,
                snapshotDigest: snapshot.digest,
                sourceMessageId: item.messageId,
                role: item.role,
                ordinal: item.ordinal,
                provider: request.provider.rawValue,
                resolvedModel: request.model
            )
        }
        return PreparedConversationContextSeed(
            encoded: prepared.encoded,
            document: prepared.document,
            receipts: receipts
        )
    }
}

enum ConversationContextSeedApplication {
    static func applicationKey(
        runId: String,
        destinationProviderThreadId: String,
        snapshotDigest: String
    ) -> String {
        [runId, destinationProviderThreadId, snapshotDigest].joined(separator: "\u{1e}")
    }
}
