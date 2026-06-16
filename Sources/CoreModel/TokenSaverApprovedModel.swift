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

    /// Gemma 4 (`gemma4` / `Gemma4ForConditionalGeneration`), the preferred distill model. The
    /// vendored mlx-swift-lm 3.31.3 `gemma4` port cannot load this fully-quantized, KV-shared
    /// checkpoint on its own (it threw `keyNotFound`/`mismatchedSize` at load); `MLXDistillRuntime`
    /// installs the patched `RCGemma4ModelOverride` (DistillCore) before loading, which IS verified
    /// to load + generate (see `DistillE4BModelLoadTests` / `DistillE4BRawGenerationProbe`). The
    /// 16 GB floor keeps it off machines that cannot hold it; those fall back to `distill17B`.
    public static let distillE4B = TokenSaverApprovedModel(
        id: "samuelfaj/distill-E4B-it-4-bit-MLX",
        url: "https://huggingface.co/samuelfaj/distill-E4B-it-4-bit-MLX",
        runtime: "mlx",
        minimumMemoryBytes: 16 * 1_024 * 1_024 * 1_024
    )

    /// Only models the current runtime can ACTUALLY load belong here. `selected()` and
    /// `approved()` both derive from this list. `selected()` picks the highest-floor model the
    /// machine can hold, so a ≥16 GB machine gets the E4B model and smaller machines fall back to
    /// the qwen3 1.7B model — both verified to load + generate.
    public static let all: [TokenSaverApprovedModel] = [
        distill17B,
        distillE4B,
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
