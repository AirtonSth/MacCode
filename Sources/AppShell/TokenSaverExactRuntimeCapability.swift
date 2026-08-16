import CryptoKit
import Foundation
import CoreModel
import AgentRuntime
import Persistence

/// Immutable host bundle that can admit the typed request selector. Default
/// production construction leaves this unset.
public struct TokenSaverExactRuntimeCapability: Sendable {
    public let target: TokenSaverBestOfThreeSelector.Target
    public let counter: TokenSaverBestOfThreeSelector.Counter
    public let count: @Sendable (String) async throws -> Int
    public let projectEnvelope: @Sendable (
        TokenSaverBestOfThreeSelector.Format,
        String,
        TokenSaverOutboundSelectionRequest
    ) -> TokenSaverProviderVisibleEnvelope?

    /// Only exact-local or exact-resolved-model quality can be installed.
    /// Estimated/unknown and incomplete or mismatched Target fields fail closed.
    public static func admitted(
        provider: String,
        resolvedModel: String,
        counterID: String,
        counterRevision: String,
        encoding: String,
        quality: TokenSaverBestOfThreeSelector.CounterQuality,
        count: @escaping @Sendable (String) async throws -> Int,
        projectEnvelope: @escaping @Sendable (
            TokenSaverBestOfThreeSelector.Format,
            String,
            TokenSaverOutboundSelectionRequest
        ) -> TokenSaverProviderVisibleEnvelope? = TokenSaverProviderVisibleEnvelopeProjector.project
    ) -> TokenSaverExactRuntimeCapability? {
        switch quality {
        case .estimated, .unknown:
            return nil
        case .exactLocalTokenizer, .exactResolvedModelTokenizer:
            break
        }
        let fields = [provider, resolvedModel, counterID, counterRevision, encoding]
        guard fields.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }
        let target = TokenSaverBestOfThreeSelector.Target(
            provider: provider,
            resolvedModel: resolvedModel,
            counterID: counterID,
            counterRevision: counterRevision,
            encoding: encoding
        )
        let counter = TokenSaverBestOfThreeSelector.Counter(
            id: counterID,
            revision: counterRevision,
            encoding: encoding,
            provider: provider,
            resolvedModel: resolvedModel,
            quality: quality
        )
        return TokenSaverExactRuntimeCapability(
            target: target,
            counter: counter,
            count: count,
            projectEnvelope: projectEnvelope
        )
    }

    package var counterCapability: TokenSaverBestOfThreeSelector.CounterCapability {
        TokenSaverBestOfThreeSelector.CounterCapability(counter: counter, count: count)
    }
}

/// Host-side RCW1 recovery that is not yet semantically finalized.
/// Distill transport to the host may already record delivered/sent_unknown.
/// Host semantic finalization/ack happens only for the selected winner;
/// losers are scrubbed.
struct TokenSaverProvisionalRCW1Recovery: Sendable {
    let payload: String
    let handle: String
    let scope: TokenSaverPersistentScope
    let stage: TokenSaverSemanticRecoveryMember
    let fullOriginal: TokenSaverSemanticRecoveryMember?

    var members: [TokenSaverSemanticRecoveryMember] {
        if let fullOriginal {
            return [stage, fullOriginal]
        }
        return [stage]
    }
}

enum TokenSaverExactRuntimeSupport {
    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Disabled RCS1 is ineligible through known failed gates, including
    /// generation. The selector must not treat that as a global candidate error.
    static func disabledRCS1Candidate(
        sourceSHA256: String
    ) -> TokenSaverBestOfThreeSelector.Candidate {
        disabledCandidate(
            format: .rcs1,
            sourceSHA256: sourceSHA256,
            payload: "RCS1_RUNTIME_UNAVAILABLE",
            abi: "RCS1_ABI_UNAVAILABLE",
            producerID: TokenSaverRequestSelectionReceipt.rcs1UnavailableProducerID,
            generation: .failed
        )
    }

    static func disabledRCW1Candidate(
        sourceSHA256: String
    ) -> TokenSaverBestOfThreeSelector.Candidate {
        disabledCandidate(
            format: .rcw1,
            sourceSHA256: sourceSHA256,
            payload: "RCW1_RUNTIME_UNAVAILABLE",
            abi: "RCW1_ABI_UNAVAILABLE",
            producerID: "remotecode-rcw1"
        )
    }

    private static func disabledCandidate(
        format: TokenSaverBestOfThreeSelector.Format,
        sourceSHA256: String,
        payload: String,
        abi: String,
        producerID: String,
        generation: TokenSaverBestOfThreeSelector.GateStatus = .passed
    ) -> TokenSaverBestOfThreeSelector.Candidate {
        TokenSaverBestOfThreeSelector.Candidate(
            format: format,
            sourceSHA256: sourceSHA256,
            payload: payload,
            abi: abi,
            effectiveEnvelope: "\(abi)\n\(payload)",
            handle: nil,
            producerID: producerID,
            producerRevision: "unavailable",
            abiRevision: "unavailable",
            generation: generation,
            structural: .failed,
            semantic: .failed,
            recovery: .failed
        )
    }
}
