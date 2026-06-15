import Foundation

public struct TokenSaverApprovedModel: Codable, Sendable, Equatable {
    public let id: String
    public let url: String
    public let runtime: String
    public let minimumMemoryBytes: UInt64

    public init(id: String, url: String, runtime: String, minimumMemoryBytes: UInt64) {
        self.id = id
        self.url = url
        self.runtime = runtime
        self.minimumMemoryBytes = minimumMemoryBytes
    }

    public var apiPayloadURL: URL {
        URL(string: "https://huggingface.co/api/models/\(id)")!
    }
}

public enum TokenSaverApprovedModels {
    public static let distill17B = TokenSaverApprovedModel(
        id: "samuelfaj/distill-1.7B-4bit-MLX",
        url: "https://huggingface.co/samuelfaj/distill-1.7B-4bit-MLX",
        runtime: "mlx",
        minimumMemoryBytes: 0
    )

    /// Gemma 3n (`gemma4` / `Gemma4ForConditionalGeneration`). DELIBERATELY EXCLUDED from
    /// `all`: the vendored mlx-swift-lm cannot load this architecture (it throws
    /// `mismatchedSize`/`keyNotFound` on the per-layer projection weights at load time), so
    /// the sidecar silently fell back to the deterministic runtime — the "distill model"
    /// technique never ran and Token Saver under-counted. Re-add to `all` only once
    /// mlx-swift-lm gains Gemma 3n support AND a live load+generate test passes. Kept as a
    /// constant for tests and future re-enable. NOTE: an already-downloaded E4B copy is not
    /// auto-deleted on migration to 1.7B (model revisions are never GC'd here); a user who
    /// wants the disk back uses the existing "Delete model" action in the Token Saver UI.
    public static let distillE4B = TokenSaverApprovedModel(
        id: "samuelfaj/distill-E4B-it-4-bit-MLX",
        url: "https://huggingface.co/samuelfaj/distill-E4B-it-4-bit-MLX",
        runtime: "mlx",
        minimumMemoryBytes: 16 * 1_024 * 1_024 * 1_024
    )

    /// Only models the current runtime can ACTUALLY load belong here. `selected()` and
    /// `approved()` both derive from this list, so an excluded model is never auto-selected
    /// and an installed copy of it reports "not approved" → the app migrates to a model that
    /// works (1.7B / qwen3, verified to load + generate).
    public static let all: [TokenSaverApprovedModel] = [
        distill17B,
    ]

    public static let fallbackModel = distill17B
    public static let defaultModel = selected()

    public static func selected(totalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> TokenSaverApprovedModel {
        all
            .filter { totalMemoryBytes >= $0.minimumMemoryBytes }
            .max { $0.minimumMemoryBytes < $1.minimumMemoryBytes }
            ?? fallbackModel
    }

    public static func approved(id: String, url: String, runtime: String) -> TokenSaverApprovedModel? {
        all.first { $0.id == id && $0.url == url && $0.runtime == runtime }
    }
}
