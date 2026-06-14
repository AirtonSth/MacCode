import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Real BERT-family embedding inference for the encoder lane (D3 / I3 / C3).
///
/// Wraps `MLXEmbedders` (vendored via mlx-swift-lm) to run an actual encoder on
/// Apple Silicon — no deterministic stand-in. Produces L2-normalized sentence
/// embeddings used by the cosine / near-dup / query-rerank / cross-turn lanes
/// and by embedding-prototype zero-shot classification (intent, subtype, SR1).
///
/// The model is downloaded once from Hugging Face (pinned commit SHA in the
/// manifest) and cached on disk; weights load lazily on first use. Everything is
/// fail-open at the call sites: if loading or inference throws, the encoder lane
/// counts a failure and falls back to deterministic/verbatim — it never escalates
/// to the MLX LLM (C6).
public actor MLXEmbeddingBackend {
    public enum BackendError: Error { case unsupportedModel(String) }

    private let manifest: TokenSaverEncoderManifest
    private let configuration: ModelConfiguration
    private var container: EmbedderModelContainer?
    /// V5: keyed (content-hash, model-id, chunker-version) vector cache.
    private let cache = EmbeddingCache()
    private static let chunkerVersion = "embed-v1"

    public init(manifest: TokenSaverEncoderManifest = TokenSaverApprovedEncoderManifests.defaultEmbedder) throws {
        guard manifest.isApprovedForTokenSaver,
              let config = Self.embedderConfiguration(forID: manifest.id) else {
            throw BackendError.unsupportedModel(manifest.id)
        }
        self.manifest = manifest
        self.configuration = config
    }

    /// Map an approved manifest id to a concrete MLXEmbedders configuration.
    /// Only models MLXEmbedders can actually run (BERT / NomicBERT arch) are mapped.
    static func embedderConfiguration(forID id: String) -> ModelConfiguration? {
        switch id {
        case "BAAI/bge-small-en-v1.5": return EmbedderRegistry.bge_small
        case "TaylorAI/bge-micro-v2": return EmbedderRegistry.bge_micro
        case "sentence-transformers/all-MiniLM-L6-v2": return EmbedderRegistry.minilm_l6
        case "BAAI/bge-base-en-v1.5": return EmbedderRegistry.bge_base
        case "nomic-ai/nomic-embed-text-v1.5": return EmbedderRegistry.nomic_text_v1_5
        default: return nil
        }
    }

    private func loadedContainer() async throws -> EmbedderModelContainer {
        if let container { return container }
        let loaded = try await EmbedderModelFactory.shared.loadContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: configuration
        )
        container = loaded
        return loaded
    }

    /// I3.3: pay cold start (download + Metal JIT + first allocation) up front.
    public func warmup() async throws {
        _ = try await embed(["warmup"])
    }

    /// I3.3: drop the bounded Metal buffer cache on drain.
    public func reclaimIdleMemory() {
        MLX.Memory.clearCache()
    }

    /// Embed a batch of texts into L2-normalized vectors, consulting the V5 cache so
    /// repeated text (same model + chunker) is embedded only once.
    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var results = [[Float]?](repeating: nil, count: texts.count)
        var missIndices: [Int] = []
        var missTexts: [String] = []
        for (i, text) in texts.enumerated() {
            let key = EmbeddingCache.key(text: text, modelID: manifest.id, chunkerVersion: Self.chunkerVersion)
            if let cached = await cache.get(key) {
                results[i] = cached
            } else {
                missIndices.append(i)
                missTexts.append(text)
            }
        }
        if !missTexts.isEmpty {
            let embedded = try await rawEmbed(missTexts)
            for (j, i) in missIndices.enumerated() where j < embedded.count {
                results[i] = embedded[j]
                let key = EmbeddingCache.key(text: texts[i], modelID: manifest.id, chunkerVersion: Self.chunkerVersion)
                await cache.put(key, embedded[j])
            }
        }
        return results.map { $0 ?? [] }
    }

    /// Real MLX inference for a batch (cache-miss path).
    private func rawEmbed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let container = try await loadedContainer()
        let maxLen = manifest.maxSeqLen
        return await container.perform { (ctx: EmbedderModelContext) -> [[Float]] in
            let model = ctx.model
            let tokenizer = ctx.tokenizer
            let pooling = ctx.pooling
            let pad = tokenizer.eosTokenId ?? 0
            let encoded = texts.map { text -> [Int] in
                var ids = tokenizer.encode(text: text, addSpecialTokens: true)
                if ids.count > maxLen { ids = Array(ids.prefix(maxLen)) }
                return ids
            }
            let width = encoded.reduce(into: 1) { $0 = max($0, $1.count) }
            let padded = stacked(
                encoded.map { ids in
                    MLXArray(ids + Array(repeating: pad, count: width - ids.count))
                })
            let mask = (padded .!= pad)
            let tokenTypes = MLXArray.zeros(like: padded)
            let pooled = pooling(
                model(padded, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask),
                mask: mask, normalize: true, applyLayerNorm: false
            )
            pooled.eval()
            return pooled.map { $0.asArray(Float.self) }
        }
    }

    /// Cosine similarity of two texts (vectors are already L2-normalized → dot product).
    public func cosine(_ a: String, _ b: String) async throws -> Double {
        let vectors = try await embed([a, b])
        guard vectors.count == 2 else { return 0 }
        return Self.dot(vectors[0], vectors[1])
    }

    /// A `ScoreFn` for `EncoderLane`: cosine(query, text) in [0, 1]-ish.
    public nonisolated func scoreFn() -> EncoderLane.ScoreFn {
        { [self] query, text in try await self.cosine(query, text) }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return 0 }
        var acc: Double = 0
        for i in a.indices { acc += Double(a[i]) * Double(b[i]) }
        return acc
    }
}
