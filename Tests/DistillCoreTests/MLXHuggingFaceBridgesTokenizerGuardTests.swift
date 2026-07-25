import XCTest
@testable import DistillCore

/// WHY: swift-transformers' `fallbackTokenizerConfig` calls SPM `Bundle.module`,
/// which fatalErrors (uncatchable) in packaged apps because the Hub resource
/// bundle cannot ship where its generated accessor looks (app root — codesign
/// rejects it). The fallback fires for model directories whose
/// tokenizer_config.json is absent or lacks tokenizer_class (partial/corrupt
/// downloads). The bridge must reject those directories with a catchable,
/// actionable error before entering the library.
final class MLXHuggingFaceBridgesTokenizerGuardTests: XCTestCase {

    func test_missingTokenizerConfig_throwsCatchableError() throws {
        let dir = try makeModelDirectory(tokenizerConfig: nil)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(
            try MLXHuggingFaceBridges.validateTokenizerConfigCannotReachBundleModuleFallback(in: dir)
        ) { error in
            guard case .missingTokenizerConfig = error as? TokenizerConfigValidationError else {
                return XCTFail("expected missingTokenizerConfig, got \(error)")
            }
        }
    }

    func test_tokenizerConfigWithoutTokenizerClass_throwsCatchableError() throws {
        let dir = try makeModelDirectory(tokenizerConfig: #"{"bos_token": "<s>"}"#)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(
            try MLXHuggingFaceBridges.validateTokenizerConfigCannotReachBundleModuleFallback(in: dir)
        ) { error in
            guard case .missingTokenizerClass = error as? TokenizerConfigValidationError else {
                return XCTFail("expected missingTokenizerClass, got \(error)")
            }
        }
    }

    func test_malformedTokenizerConfig_throwsCatchableError() throws {
        let dir = try makeModelDirectory(tokenizerConfig: "not json {")
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(
            try MLXHuggingFaceBridges.validateTokenizerConfigCannotReachBundleModuleFallback(in: dir)
        )
    }

    func test_wellFormedTokenizerConfig_passes() throws {
        let dir = try makeModelDirectory(
            tokenizerConfig: #"{"tokenizer_class": "Qwen2Tokenizer", "bos_token": "<s>"}"#
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNoThrow(
            try MLXHuggingFaceBridges.validateTokenizerConfigCannotReachBundleModuleFallback(in: dir)
        )
    }

    private func makeModelDirectory(tokenizerConfig: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc2-tokenizer-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let tokenizerConfig {
            try Data(tokenizerConfig.utf8).write(to: dir.appendingPathComponent("tokenizer_config.json"))
        }
        return dir
    }
}
