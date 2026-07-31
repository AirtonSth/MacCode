import Foundation

/// Lossy but recoverable command-output routing for Token Saver.
///
/// Callers MUST store the original under `handle` (store-before-loss) before using the
/// result. This is the missing live path for stack/test/source/diff/HTML crushers that
/// `EncoderFirstRuntime` skips because it only runs `.losslessOnly`.
public enum CommandOutputLossyRouter {
    /// Content types that need element-dropping + a reversible handle to win meaningfully.
    public static let lossyCandidateTypes: Set<DistillContentType> = [
        .stackTrace,
        .testReport,
        .sourceCode,
        .diff,
        .html,
        .buildOutput,
    ]

    /// True when classification suggests a lossy crusher may help (cheap pre-check before store).
    public static func isLossyCandidate(_ input: String) -> Bool {
        let type = DistillContentRouter().classify(input)
        return lossyCandidateTypes.contains(type)
    }

    /// Route with element-dropping crushers. Returns nil when no worthwhile reduction.
    public static func routeIfBeneficial(
        input: String,
        handle: String,
        query: String? = nil,
        minGainRatio: Double = 0.10
    ) -> DistillRouteResult? {
        let trimmedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHandle.isEmpty else { return nil }
        let options = DistillRouterOptions(
            allowElementDropping: true,
            minGainRatio: minGainRatio,
            reversibleHandle: trimmedHandle,
            allowLossyProsePruning: false,
            query: query
        )
        return DistillContentRouter().route(input, options: options)
    }
}

/// Multimodal / binary-ish tool payloads that text Distill must not rewrite.
public enum ToolOutputMultimodalGuard {
    /// Detect image payloads (Claude content blocks, raw JPEG/PNG base64 prefixes).
    public static func looksLikeImagePayload(_ text: String) -> Bool {
        if text.utf8.count < 64 { return false }
        if text.contains(#""type": "image""#) || text.contains(#""type":"image""#) {
            return true
        }
        // Common base64 signatures for JPEG / PNG when embedded in tool JSON or raw.
        if text.contains("/9j/") || text.contains("iVBOR") {
            return true
        }
        if text.contains("data:image/") {
            return true
        }
        return false
    }
}
