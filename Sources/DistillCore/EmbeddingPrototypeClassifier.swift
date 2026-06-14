import Foundation

/// Real-model zero-shot classification by embedding-prototype nearest-neighbour
/// (D3 / I7 / I10.5 / F14). Each label carries a few prototype strings; a text is
/// classified by cosine to the nearest prototype, argmax over labels, with a
/// confidence floor and a top-vs-second margin. Below either bar it ABSTAINS
/// (returns nil) so the caller falls through to the deterministic/keyword path —
/// the encoder only ADDS decisions, never forces one (fail-open, C6).
///
/// Prototype vectors are embedded once at build time; only the query text is
/// embedded per call. Uses the same real BERT backend as the rest of the lane.
public struct EmbeddingPrototypeClassifier: Sendable {
    public struct Verdict: Sendable, Equatable {
        public let label: String
        public let confidence: Double   // cosine to nearest prototype of the winning label
        public let margin: Double       // winning confidence minus runner-up label confidence
    }

    private let prototypes: [LabelVectors]
    private let embed: @Sendable ([String]) async throws -> [[Float]]
    private let minConfidence: Double
    private let minMargin: Double

    private struct LabelVectors: Sendable {
        let label: String
        let vectors: [[Float]]
    }

    public static func make(
        labelPrototypes: [String: [String]],
        minConfidence: Double = 0.45,
        minMargin: Double = 0.04,
        embed: @escaping @Sendable ([String]) async throws -> [[Float]]
    ) async throws -> EmbeddingPrototypeClassifier {
        var built: [LabelVectors] = []
        for (label, examples) in labelPrototypes.sorted(by: { $0.key < $1.key }) {
            let nonEmpty = examples.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !nonEmpty.isEmpty else { continue }
            let vectors = try await embed(nonEmpty)
            built.append(LabelVectors(label: label, vectors: vectors))
        }
        return EmbeddingPrototypeClassifier(
            prototypes: built, embed: embed,
            minConfidence: minConfidence, minMargin: minMargin)
    }

    private init(
        prototypes: [LabelVectors],
        embed: @escaping @Sendable ([String]) async throws -> [[Float]],
        minConfidence: Double,
        minMargin: Double
    ) {
        self.prototypes = prototypes
        self.embed = embed
        self.minConfidence = minConfidence
        self.minMargin = minMargin
    }

    /// Returns the winning label, or nil to abstain (fall through). Fail-open on error.
    public func classify(_ text: String) async -> Verdict? {
        guard !prototypes.isEmpty else { return nil }
        let queryVector: [Float]
        do {
            let vectors = try await embed([text])
            guard let first = vectors.first else { return nil }
            queryVector = first
        } catch {
            return nil
        }

        var scored: [(label: String, confidence: Double)] = []
        for lv in prototypes {
            var best = -Double.infinity
            for v in lv.vectors {
                best = max(best, MLXEmbeddingBackend.dot(queryVector, v))
            }
            scored.append((lv.label, best))
        }
        scored.sort { $0.confidence > $1.confidence }
        guard let top = scored.first else { return nil }
        let runnerUp = scored.count > 1 ? scored[1].confidence : -Double.infinity
        let margin = top.confidence - (runnerUp.isFinite ? runnerUp : 0)
        guard top.confidence >= minConfidence, margin >= minMargin else { return nil }
        return Verdict(label: top.label, confidence: top.confidence, margin: margin)
    }
}
