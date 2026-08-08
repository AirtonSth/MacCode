import Foundation
import CryptoKit

/// I9.1: real-embedding near-duplicate NOMINATION for the block deduper.
///
/// Embeds each substantial block (>= minBlockChars) ONCE, caches the L2-normalized
/// vector by content-hash, and nominates a pair when cosine >= 0.95. Nomination only
/// NAMES a candidate — `DistillBlockDeduper`'s deterministic string diff still DECIDES
/// whether the collapse is safe (I9.2), so a loose embedding match can never cause an
/// unsafe merge. Fully real-model; fail-open (embed error → exact-only fallback).
public enum EmbeddingNearDuplicateNominator {
    /// Build a synchronous nominator backed by precomputed real embeddings.
    /// Returns `nil` if embedding fails or there are <2 substantial blocks (caller
    /// then falls back to exact-only dedup).
    public static func make(
        forBlocksIn text: String,
        embed: @Sendable ([String]) async throws -> [[Float]],
        threshold: Double = 0.95,
        minBlockChars: Int = 400
    ) async -> DistillBlockDeduper.NearDuplicateNominator? {
        let blocks = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= minBlockChars }
        // Unique by content-hash so each distinct block is embedded once (I9.1 cache).
        var order: [String] = []
        var seen = Set<String>()
        for b in blocks where !seen.contains(b) { seen.insert(b); order.append(b) }
        guard order.count >= 2 else { return nil }

        let vectors: [[Float]]
        do { vectors = try await embed(order) } catch { return nil }
        guard vectors.count == order.count else { return nil }

        var vectorByBlock: [String: [Float]] = [:]
        for (b, v) in zip(order, vectors) { vectorByBlock[b] = v }
        let frozen = vectorByBlock

        return { first, second in
            let a = first.trimmingCharacters(in: .whitespacesAndNewlines)
            let b = second.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let va = frozen[a], let vb = frozen[b] else { return false }
            return MLXEmbeddingBackend.dot(va, vb) >= threshold
        }
    }

    static func contentHash(_ s: String) -> String {
        DistillSHA256.hex(s)
    }
}
