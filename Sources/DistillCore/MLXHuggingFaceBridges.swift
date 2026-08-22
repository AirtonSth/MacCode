import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// Concrete Hugging Face hub + tokenizer bridges for MLXLMCommon.
///
/// Replaces `#hubDownloader()` / `#huggingFaceTokenizerLoader()` /
/// `#adaptHuggingFaceTokenizer(...)` freestanding macros from MLXHuggingFace.
/// Those macros expand via `MLXHuggingFaceMacros` compiler plugins, which on
/// some Swift toolchains (observed: Swift 6.3.3 / Xcode 26.x) fail with
/// "failed to receive result from plugin" and block `scripts/run-app.sh`.
///
/// Behavior matches the macro expansions in mlx-swift-lm's
/// `HuggingFaceIntegrationMacros.swift` (HubClient downloadSnapshot +
/// AutoTokenizer.from(modelFolder:) + Tokenizer protocol adaptor).
enum MLXHuggingFaceBridges {
    /// Same object `#hubDownloader()` would produce.
    static func hubDownloader(_ hub: HubClient = HubClient()) -> any MLXLMCommon.Downloader {
        HubBridge(hub)
    }

    /// Same object `#huggingFaceTokenizerLoader()` would produce.
    static func tokenizerLoader() -> any MLXLMCommon.TokenizerLoader {
        TransformersLoader()
    }

    /// Same object `#adaptHuggingFaceTokenizer(upstream)` would produce.
    static func adaptTokenizer(_ upstream: any Tokenizers.Tokenizer) -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream)
    }

    /// Guard against swift-transformers' `fallbackTokenizerConfig`, which calls
    /// SPM `Bundle.module`: its generated accessor only checks the .app root and
    /// a hardcoded builder `.build` path, then fatalErrors — uncatchable — in
    /// packaged apps, because `swift-transformers_Hub.bundle` cannot ship there
    /// (codesign rejects the bare SPM bundle at the app root and inside
    /// Contents/MacOS; probed 2026-07-22). The fallback fires when
    /// `tokenizer_config.json` is absent or lacks `tokenizer_class` — the
    /// signature of a partial or corrupted model download — so both RemoteCode
    /// and RemoteCodeDistillService would abort instead of reporting an error.
    /// Rejecting those directories here is strictly safer than upstream: no
    /// tokenizer can load successfully from them in a packaged app anyway.
    static func validateTokenizerConfigCannotReachBundleModuleFallback(
        in directory: URL,
        fileManager: FileManager = .default
    ) throws {
        let configURL = directory.appendingPathComponent("tokenizer_config.json")
        guard fileManager.fileExists(atPath: configURL.path) else {
            throw TokenizerConfigValidationError.missingTokenizerConfig(configURL.path)
        }
        let object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: configURL, options: .mappedIfSafe))) as? [String: Any]
        guard let object, object["tokenizer_class"] is String else {
            throw TokenizerConfigValidationError.missingTokenizerClass(configURL.path)
        }
    }
}

/// Catchable replacement for the process abort described on
/// `validateTokenizerConfigCannotReachBundleModuleFallback(in:fileManager:)`.
enum TokenizerConfigValidationError: Error, LocalizedError, Equatable {
    case missingTokenizerConfig(String)
    case missingTokenizerClass(String)

    var errorDescription: String? {
        switch self {
        case .missingTokenizerConfig(let path):
            return "Model tokenizer configuration is missing at \(path). Re-download the model."
        case .missingTokenizerClass(let path):
            return "Model tokenizer configuration at \(path) has no tokenizer_class. Re-download the model."
        }
    }
}

// MARK: - Hub

private struct HubBridge: MLXLMCommon.Downloader {
    private let upstream: HubClient

    init(_ upstream: HubClient) {
        self.upstream = upstream
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = HuggingFace.Repo.ID(rawValue: id) else {
            throw HuggingFaceDownloaderError.invalidRepositoryID(id)
        }
        let revision = revision ?? "main"
        return try await upstream.downloadSnapshot(
            of: repoID,
            revision: revision,
            matching: patterns,
            progressHandler: { @MainActor progress in
                progressHandler(progress)
            }
        )
    }
}

// MARK: - Tokenizer loader

private struct TransformersLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        try MLXHuggingFaceBridges.validateTokenizerConfigCannotReachBundleModuleFallback(in: directory)
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return MLXHuggingFaceBridges.adaptTokenizer(upstream)
    }
}

// MARK: - Tokenizer adaptor

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
