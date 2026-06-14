import Foundation

public struct TokenSaverEncoderManifest: Codable, Sendable, Equatable {
    public let id: String
    public let url: String
    public let revision: String
    public let runtime: String
    public let role: String
    public let license: String
    public let maxSeqLen: Int
    public let chunkPolicy: String

    public init(
        id: String,
        url: String,
        revision: String,
        runtime: String,
        role: String,
        license: String,
        maxSeqLen: Int,
        chunkPolicy: String
    ) {
        self.id = id
        self.url = url
        self.revision = revision
        self.runtime = runtime
        self.role = role
        self.license = license
        self.maxSeqLen = max(1, maxSeqLen)
        self.chunkPolicy = chunkPolicy
    }

    /// Structural license hard-gate (I3.2 / V2): only permissive licenses ship.
    /// CC-BY-NC / OpenRAIL / any "-nc" variant is rejected before download.
    public static let approvedLicenses: Set<String> = ["apache-2.0", "mit", "bsd-3-clause"]

    /// V4: encoder quantization gate. fp16 / int8 (W8A16 on the ANE) ship freely;
    /// palettized int4 degrades embeddings more than LLMs, so it is allowed ONLY with
    /// an explicit approved-offline-eval flag. Anything else (e.g. int2) is rejected.
    public static func isApprovedQuantization(_ quant: String, offlineEvalApproved: Bool = false) -> Bool {
        switch quant.lowercased() {
        case "fp16", "float16", "int8", "w8a16": return true
        case "int4", "q4", "palettized-int4": return offlineEvalApproved
        default: return false
        }
    }

    public var hasImmutableRevision: Bool {
        revision.count == 40 && revision.allSatisfy { $0.isHexDigit }
    }

    public var isApprovedForTokenSaver: Bool {
        Self.approvedLicenses.contains(license.lowercased()) &&
            ["swift-embeddings", "mlx-embedders", "coreml"].contains(runtime) &&
            ["embedder", "reranker", "colbert-ranker", "classifier"].contains(role) &&
            !id.isEmpty &&
            !url.isEmpty &&
            !revision.isEmpty
    }

    public var isApprovedForDownload: Bool {
        isApprovedForTokenSaver && hasImmutableRevision
    }
}

public enum TokenSaverApprovedEncoderManifests {
    public static let answerAIColBERTSmall = TokenSaverEncoderManifest(
        id: "answerdotai/answerai-colbert-small-v1",
        url: "https://huggingface.co/answerdotai/answerai-colbert-small-v1",
        revision: "pin-required-before-download",
        runtime: "swift-embeddings",
        role: "colbert-ranker",
        license: "Apache-2.0",
        maxSeqLen: 512,
        chunkPolicy: "line-or-paragraph"
    )

    public static let modernBERTEmbed = TokenSaverEncoderManifest(
        id: "nomic-ai/modernbert-embed-base",
        url: "https://huggingface.co/nomic-ai/modernbert-embed-base",
        revision: "pin-required-before-download",
        runtime: "swift-embeddings",
        role: "embedder",
        license: "Apache-2.0",
        maxSeqLen: 8192,
        chunkPolicy: "paragraph"
    )

    /// Primary embedder actually wired to MLXEmbedders inference (BERT arch,
    /// MIT, pinned SHA). Used for cosine / near-dup / query-rerank / cross-turn
    /// and embedding-prototype zero-shot. ~130 MB.
    public static let bgeSmallEN = TokenSaverEncoderManifest(
        id: "BAAI/bge-small-en-v1.5",
        url: "https://huggingface.co/BAAI/bge-small-en-v1.5",
        revision: "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a",
        runtime: "mlx-embedders",
        role: "embedder",
        license: "MIT",
        maxSeqLen: 512,
        chunkPolicy: "line-or-paragraph"
    )

    /// Tiny embedder (~70 MB) -- fast path / CI live-inference proof.
    public static let bgeMicro = TokenSaverEncoderManifest(
        id: "TaylorAI/bge-micro-v2",
        url: "https://huggingface.co/TaylorAI/bge-micro-v2",
        revision: "3edf6d7de0faa426b09780416fe61009f26ae589",
        runtime: "mlx-embedders",
        role: "embedder",
        license: "MIT",
        maxSeqLen: 512,
        chunkPolicy: "line-or-paragraph"
    )

    /// MiniLM embedder (Apache-2.0, pinned) -- alternate backend.
    public static let miniLML6 = TokenSaverEncoderManifest(
        id: "sentence-transformers/all-MiniLM-L6-v2",
        url: "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2",
        revision: "1110a243fdf4706b3f48f1d95db1a4f5529b4d41",
        runtime: "mlx-embedders",
        role: "embedder",
        license: "Apache-2.0",
        maxSeqLen: 512,
        chunkPolicy: "line-or-paragraph"
    )

    public static let all: [TokenSaverEncoderManifest] = [
        answerAIColBERTSmall,
        modernBERTEmbed,
        bgeSmallEN,
        bgeMicro,
        miniLML6
    ]

    /// The default embedder backend the service runs (real MLX inference).
    public static let defaultEmbedder = bgeSmallEN
}

public struct TokenSaverRequiredModel: Codable, Sendable, Equatable {
    public let id: String
    public let url: String
    public let revision: String
    public let runtime: String
    public let role: String

    public init(id: String, url: String, revision: String, runtime: String, role: String) {
        self.id = id
        self.url = url
        self.revision = revision
        self.runtime = runtime
        self.role = role
    }

    public init(encoder: TokenSaverEncoderManifest) {
        self.init(
            id: encoder.id,
            url: encoder.url,
            revision: encoder.revision,
            runtime: encoder.runtime,
            role: encoder.role
        )
    }

    public var apiPayloadURL: URL {
        URL(string: "https://huggingface.co/api/models/\(id)/revision/\(revision)")!
    }

    public var hasImmutableRevision: Bool {
        revision.count == 40 && revision.allSatisfy { $0.isHexDigit }
    }
}

public enum TokenSaverRequiredModels {
    public static let defaultEmbedder = TokenSaverRequiredModel(
        encoder: TokenSaverApprovedEncoderManifests.defaultEmbedder
    )

    public static let mnliBert = TokenSaverRequiredModel(
        id: "yoshitomo-matsubara/bert-base-uncased-mnli",
        url: "https://huggingface.co/yoshitomo-matsubara/bert-base-uncased-mnli",
        revision: "0b3878cddf63e50996099c1cd7a3c2bd0aa141dd",
        runtime: "mlx-bert-classifier",
        role: "nli-classifier"
    )

    public static let nerBert = TokenSaverRequiredModel(
        id: "dslim/bert-base-NER",
        url: "https://huggingface.co/dslim/bert-base-NER",
        revision: "d1a3e8f13f8c3566299d95fcfc9a8d2382a9affc",
        runtime: "mlx-bert-classifier",
        role: "ner-classifier"
    )

    public static let llmLingua2Bert = TokenSaverRequiredModel(
        id: "microsoft/llmlingua-2-bert-base-multilingual-cased-meetingbank",
        url: "https://huggingface.co/microsoft/llmlingua-2-bert-base-multilingual-cased-meetingbank",
        revision: "5f0c82792b7ea14c6484e015b6a072009496b7f2",
        runtime: "mlx-bert-classifier",
        role: "llmlingua2-token-classifier"
    )

    public static let activationBundle: [TokenSaverRequiredModel] = [
        defaultEmbedder,
        mnliBert,
        nerBert,
        llmLingua2Bert
    ]
}
