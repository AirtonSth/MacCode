import DistillCore
import Foundation
import XCTest

/// Empirical gate for the E4B model swap: prove `samuelfaj/distill-E4B-it-4-bit-MLX`
/// (gemma4 / `Gemma4ForConditionalGeneration`) actually LOADS in `MLXDistillRuntime` and
/// GENERATES. This is the live load+generate proof the `TokenSaverApprovedModels.distillE4B`
/// re-enable was gated on. The vendored mlx-swift-lm 3.31.3 `gemma4` port cannot load this
/// fully-quantized, KV-shared checkpoint, so `MLXDistillRuntime` installs the patched
/// `RCGemma4ModelOverride` (see `Gemma4ModelOverride.swift`) before loading.
///
///   REMOTE_CODE_TOKEN_SAVER_E4B_DIR=<model dir> \
///     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///     swift test --filter DistillE4BModelLoadTests
final class DistillE4BModelLoadTests: XCTestCase {
    func test_E4BModelLoadsAndGenerates() async throws {
        guard let dir = ProcessInfo.processInfo.environment["REMOTE_CODE_TOKEN_SAVER_E4B_DIR"], !dir.isEmpty else {
            throw XCTSkip("Set REMOTE_CODE_TOKEN_SAVER_E4B_DIR to the installed E4B model directory.")
        }
        let modelDirectory = URL(fileURLWithPath: dir, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("config.json").path),
                      "model dir must contain config.json")

        // The load itself is the gate: the historical failure was mismatchedSize/keyNotFound here.
        let runtime = try await MLXDistillRuntime(modelDirectory: modelDirectory)
        try await runtime.warmup()

        let scheduler = DistillScheduler(runtime: runtime, maxConcurrentRequests: 1, resultCacheTTLSeconds: 0)
        let input = """
        RemoteCode Token Saver compresses long agent output locally on macOS.
        It must preserve exact commands, errors, file paths, and pass criteria.
        The local model rewrites verbose prose into concise plain language.
        """
        let response = try await scheduler.submit(DistillRequest(
            mode: .longText, priority: .interactive, input: input, maxOutputCharacters: 600
        ))

        XCTAssertFalse(response.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "the E4B model must produce non-empty output")
        XCTAssertEqual(response.routeStage, .llmMLX,
                       "WHY: a long prose prompt that the deterministic router can't compress must reach the loaded MLX model — proving the gemma4 LLM technique actually runs")
        XCTAssertLessThanOrEqual(response.output.count, 600)
        print("DISTILL-E4B routeStage=\(String(describing: response.routeStage)) in=\(response.inputTokens) out=\(response.outputTokens) output=\(response.output)")
    }
}
