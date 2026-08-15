import Foundation
import CoreModel
import AgentRuntime

/// Modeled local host payload + ABI for one arm. This is not a complete
/// provider transport: JSON/role/CLI framing is unproven and omitted.
/// Counts derived from these bytes are local modeled context, never billing.
public struct TokenSaverProviderVisibleEnvelope: Sendable, Equatable {
    public let payload: String
    public let abi: String
    public let effectiveEnvelope: String

    public init(payload: String, abi: String, effectiveEnvelope: String) {
        self.payload = payload
        self.abi = abi
        self.effectiveEnvelope = effectiveEnvelope
    }
}

/// Provider/model-bound projection of the host payload+ABI the selector ranks.
/// Returns nil when those host-owned bytes cannot be proven.
public enum TokenSaverProviderVisibleEnvelopeProjector {
    public static func project(
        format: TokenSaverBestOfThreeSelector.Format,
        payload: String,
        request: TokenSaverOutboundSelectionRequest
    ) -> TokenSaverProviderVisibleEnvelope? {
        guard format != .caveman else { return nil }
        guard !payload.isEmpty else { return nil }
        let abi = AgentSkillInstaller.tokenSaverProviderPrompt(
            "",
            environment: request.environment(for: format)
        )
        if abi.isEmpty {
            guard format == .human else { return nil }
            return TokenSaverProviderVisibleEnvelope(
                payload: payload,
                abi: "",
                effectiveEnvelope: payload
            )
        }
        guard !abi.contains(payload), !payload.contains(abi) else { return nil }
        let envelope = abi + "\n" + payload
        guard occursExactlyOnce(payload, in: envelope),
              occursExactlyOnce(abi, in: envelope) else {
            return nil
        }
        return TokenSaverProviderVisibleEnvelope(
            payload: payload,
            abi: abi,
            effectiveEnvelope: envelope
        )
    }

    private static func occursExactlyOnce(_ needle: String, in text: String) -> Bool {
        guard !needle.isEmpty, let first = text.range(of: needle) else { return false }
        return text[first.upperBound...].range(of: needle) == nil
    }
}
