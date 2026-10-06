import CryptoKit
import Foundation
import CoreModel
import Persistence

/// Prepares a host-owned RCSEED1 document and content-free slot receipts that
/// carry the prior conversation into a fresh provider session. Not Token Saver:
/// only the Human format is produced. The CoreModel types keep their historical
/// names until they move.
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
                // Single uppercased header shared by both fields (rawValues are
                // fixed lowercase, so one copy yields identical ABI text).
                let header = format == .human ? "" : "\(format.rawValue.uppercased()) ABI"
                return TokenSaverContextSeedBuilder.ProjectedEnvelope(
                    payload: payload,
                    abi: header,
                    effectiveEnvelope: format == .human ? payload : "\(header)\n\(payload)"
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

enum TokenSaverContextSeedApplication {
    static func applicationKey(
        runId: String,
        destinationProviderThreadId: String,
        snapshotDigest: String
    ) -> String {
        [runId, destinationProviderThreadId, snapshotDigest].joined(separator: "\u{1e}")
    }
}

private let hexAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

private func sha256Hex(_ text: String) -> String {
    let digest = SHA256.hash(data: Data(text.utf8))
    // PERF: nibble table avoids 32 String(format:) calls; same lowercase hex.
    var out: [UInt8] = []
    out.reserveCapacity(64)
    for b in digest {
        out.append(hexAlphabet[Int(b >> 4)])
        out.append(hexAlphabet[Int(b & 0x0F)])
    }
    return String(bytes: out, encoding: .utf8) ?? ""
}
