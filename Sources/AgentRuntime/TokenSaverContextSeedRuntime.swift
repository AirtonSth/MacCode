import CryptoKit
import Foundation
import CoreModel
import Persistence

/// Prepares a host-owned RCSEED1 document and content-free slot receipts.
public protocol TokenSaverContextSeedPreparing: Sendable {
    func prepare(
        snapshot: TokenSaverCanonicalConversationSnapshot,
        request: AgentRunRequest,
        destinationProviderThreadId: String
    ) async -> TokenSaverPreparedContextSeed?
}

/// Human-only fallback when no exact counter is installed. Never invents RCW1.
public struct TokenSaverHumanContextSeedPreparer: TokenSaverContextSeedPreparing {
    public init() {}

    public func prepare(
        snapshot: TokenSaverCanonicalConversationSnapshot,
        request: AgentRunRequest,
        destinationProviderThreadId: String
    ) async -> TokenSaverPreparedContextSeed? {
        let target = TokenSaverBestOfThreeSelector.Target(
            provider: request.provider.rawValue,
            resolvedModel: request.model,
            counterID: "unavailable",
            counterRevision: "unavailable",
            encoding: "unavailable"
        )
        guard let prepared = await TokenSaverContextSeedBuilder.prepare(
            snapshot: snapshot,
            target: target,
            counter: nil,
            project: { format, payload in
                TokenSaverContextSeedBuilder.ProjectedEnvelope(
                    payload: payload,
                    abi: format == .human ? "" : "\(format.rawValue.uppercased()) ABI",
                    effectiveEnvelope: format == .human ? payload : "\(format.rawValue.uppercased()) ABI\n\(payload)"
                )
            }
        ) else {
            return nil
        }
        var receipts: [TokenSaverContextSelectionReceipt.Record] = []
        for item in snapshot.items {
            if item.role == .user {
                receipts.append(TokenSaverContextSelectionReceipt.humanUserSlot(
                    runId: request.runId.value.uuidString,
                    destinationProviderThreadId: destinationProviderThreadId,
                    snapshotDigest: snapshot.digest,
                    sourceMessageId: item.messageId,
                    ordinal: item.ordinal,
                    provider: request.provider.rawValue,
                    resolvedModel: request.model
                ))
                continue
            }
            let decision = prepared.decisions.first { $0.sourceSHA256 == sha256Hex(item.canonicalText) }
                ?? prepared.decisions.first
            if let decision {
                receipts.append(TokenSaverContextSelectionReceipt.project(
                    decision: decision,
                    runId: request.runId.value.uuidString,
                    destinationProviderThreadId: destinationProviderThreadId,
                    snapshotDigest: snapshot.digest,
                    sourceMessageId: item.messageId,
                    role: .assistant,
                    ordinal: item.ordinal,
                    provider: request.provider.rawValue,
                    resolvedModel: request.model
                ))
            }
        }
        guard receipts.count == snapshot.items.count else { return nil }
        return TokenSaverPreparedContextSeed(
            encoded: prepared.encoded,
            document: prepared.seed,
            receipts: receipts
        )
    }
}

public struct TokenSaverExactContextSeedPreparer: TokenSaverContextSeedPreparing {
    private let target: TokenSaverBestOfThreeSelector.Target
    private let counter: TokenSaverBestOfThreeSelector.CounterCapability
    private let project: @Sendable (
        TokenSaverBestOfThreeSelector.Format,
        String
    ) -> TokenSaverContextSeedBuilder.ProjectedEnvelope?

    package init(
        target: TokenSaverBestOfThreeSelector.Target,
        counter: TokenSaverBestOfThreeSelector.CounterCapability,
        project: @escaping @Sendable (
            TokenSaverBestOfThreeSelector.Format,
            String
        ) -> TokenSaverContextSeedBuilder.ProjectedEnvelope?
    ) {
        self.target = target
        self.counter = counter
        self.project = project
    }

    public func prepare(
        snapshot: TokenSaverCanonicalConversationSnapshot,
        request: AgentRunRequest,
        destinationProviderThreadId: String
    ) async -> TokenSaverPreparedContextSeed? {
        let requestTarget = TokenSaverBestOfThreeSelector.Target(
            provider: request.provider.rawValue,
            resolvedModel: request.model,
            counterID: target.counterID,
            counterRevision: target.counterRevision,
            encoding: target.encoding
        )
        guard let prepared = await TokenSaverContextSeedBuilder.prepare(
            snapshot: snapshot,
            target: requestTarget,
            counter: requestTarget == target ? counter : nil,
            project: project
        ) else {
            return nil
        }
        var receipts: [TokenSaverContextSelectionReceipt.Record] = []
        var decisionIndex = 0
        for item in snapshot.items {
            if item.role == .user {
                receipts.append(TokenSaverContextSelectionReceipt.humanUserSlot(
                    runId: request.runId.value.uuidString,
                    destinationProviderThreadId: destinationProviderThreadId,
                    snapshotDigest: snapshot.digest,
                    sourceMessageId: item.messageId,
                    ordinal: item.ordinal,
                    provider: request.provider.rawValue,
                    resolvedModel: request.model
                ))
                continue
            }
            guard decisionIndex < prepared.decisions.count else { return nil }
            receipts.append(TokenSaverContextSelectionReceipt.project(
                decision: prepared.decisions[decisionIndex],
                runId: request.runId.value.uuidString,
                destinationProviderThreadId: destinationProviderThreadId,
                snapshotDigest: snapshot.digest,
                sourceMessageId: item.messageId,
                role: .assistant,
                ordinal: item.ordinal,
                provider: request.provider.rawValue,
                resolvedModel: request.model
            ))
            decisionIndex += 1
        }
        guard receipts.count == snapshot.items.count else { return nil }
        return TokenSaverPreparedContextSeed(
            encoded: prepared.encoded,
            document: prepared.seed,
            receipts: receipts
        )
    }
}

enum TokenSaverContextSeedApplication {
    static func applicationKey(
        runId: String,
        destinationProviderThreadId: String,
        snapshotDigest: String
    ) -> String {
        [runId, destinationProviderThreadId, snapshotDigest].joined(separator: "\u{1e}")
    }
}

private func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}
