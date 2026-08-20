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
    /// 16 GiB machines stay on `distill17B`; only hosts with more than 16 GiB default to E4B.
    public static let distillE4B = TokenSaverApprovedModel(
        id: "samuelfaj/distill-E4B-it-4-bit-MLX",
        url: "https://huggingface.co/samuelfaj/distill-E4B-it-4-bit-MLX",
        runtime: "mlx",
        minimumMemoryBytes: 16 * 1_024 * 1_024 * 1_024
    )

    /// Only models the current runtime can ACTUALLY load belong here. `selected()` and
    /// `approved()` both derive from this list. RAM default: ≤16 GiB → 1.7B, >16 GiB → E4B.
    public static let all: [TokenSaverApprovedModel] = [
        distill17B,
        distillE4B,
    ]

    public static let fallbackModel = distill17B
    public static let defaultModel = selected()

    public static func selected(totalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> TokenSaverApprovedModel {
        if totalMemoryBytes > distillE4B.minimumMemoryBytes {
            return distillE4B
        }
        return distill17B
    }

    public static func approved(id: String, url: String, runtime: String) -> TokenSaverApprovedModel? {
        all.first { $0.id == id && $0.url == url && $0.runtime == runtime }
    }

    /// Local model implied by a Settings source. API is not a local model.
    public static func resolveLocal(
        source: TokenSaverModelSource,
        totalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> TokenSaverApprovedModel {
        switch source {
        case .automatic:
            return selected(totalMemoryBytes: totalMemoryBytes)
        case .distill17b:
            return distill17B
        case .distillE4B:
            return distillE4B
        case .openaiCompat:
            return selected(totalMemoryBytes: totalMemoryBytes)
        }
    }
}

/// User-visible Token Saver generate source. `automatic` follows RAM.
public enum TokenSaverModelSource: String, Codable, Sendable, Equatable, CaseIterable {
    case automatic
    case distill17b
    case distillE4B
    case openaiCompat
}

/// Where Distill generate should run after resolving Settings + RAM.
public enum TokenSaverGenerateTarget: Sendable, Equatable {
    case local(TokenSaverApprovedModel)
    case openaiCompatible(baseURL: URL, model: String, token: String)

    public static func resolve(
        source: TokenSaverModelSource,
        apiBaseURL: String,
        apiModel: String,
        apiToken: String,
        totalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> TokenSaverGenerateTarget {
        if source == .openaiCompat,
           let url = Self.parseAPIBaseURL(apiBaseURL) {
            let model = apiModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return .openaiCompatible(
                baseURL: url,
                model: model.isEmpty ? TokenSaverApprovedModels.distill17B.id : model,
                token: apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return .local(TokenSaverApprovedModels.resolveLocal(source: source, totalMemoryBytes: totalMemoryBytes))
    }

    public static func parseAPIBaseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return url
    }
}
