import Foundation

/// I8.1: embedding-cosine first-stage faithfulness filter (necessary, NOT sufficient).
///
/// Runs BEFORE/alongside the deterministic `FaithfulnessGate`: if the compressed
/// output drifts too far from the original in embedding space (cosine < threshold),
/// reject toward the original. The cosine function is injected so the lane stays
/// pure and testable; production passes `MLXEmbeddingBackend.cosine`. Fail-open:
/// if the encoder is unavailable or errors, the gate ACCEPTS and defers entirely
/// to the deterministic gate — it never escalates and never blocks on the model.
public struct SemanticSimilarityGate: Sendable {
    public typealias CosineFn = @Sendable (_ a: String, _ b: String) async throws -> Double

    public let cosine: CosineFn
    /// Plan default (I8.1): reject below 0.92.
    public let threshold: Double

    public init(threshold: Double = 0.92, cosine: @escaping CosineFn) {
        self.threshold = threshold
        self.cosine = cosine
    }

    public func validate(original: String, compressed: String) async -> FaithfulnessGate.Result {
        if compressed == original { return .accepted }
        do {
            let sim = try await cosine(original, compressed)
            if sim >= threshold { return .accepted }
            return .rejected(String(format: "low embedding similarity %.3f < %.2f", sim, threshold))
        } catch {
            // Fail-open: encoder unavailable → deterministic gate is authoritative.
            return .accepted
        }
    }

    /// Combined gate: deterministic gate is authoritative (literal + reverse coverage),
    /// cosine is an additional reject-only layer. Both must accept.
    public func validateCombined(original: String, compressed: String) async -> FaithfulnessGate.Result {
        let deterministic = FaithfulnessGate.validate(original: original, compressed: compressed)
        guard deterministic.accepted else { return deterministic }
        return await validate(original: original, compressed: compressed)
    }
}
