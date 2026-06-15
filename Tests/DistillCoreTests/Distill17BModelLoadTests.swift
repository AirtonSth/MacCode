import DistillCore
import Foundation
import XCTest

/// Empirical gate for the 1.7B model swap: prove `samuelfaj/distill-1.7B-4bit-MLX`
/// (qwen3 arch) actually LOADS in MLXDistillRuntime and GENERATES — unlike the E4B
/// (gemma4) model, which fails to load with the vendored mlx-swift-lm.
///
///   REMOTE_CODE_TOKEN_SAVER_17B_DIR=<model dir> \
///     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///     swift test --filter Distill17BModelLoadTests
final class Distill17BModelLoadTests: XCTestCase {
    func test_17BModelLoadsAndGenerates() async throws {
        guard let dir = ProcessInfo.processInfo.environment["REMOTE_CODE_TOKEN_SAVER_17B_DIR"], !dir.isEmpty else {
            throw XCTSkip("Set REMOTE_CODE_TOKEN_SAVER_17B_DIR to the installed 1.7B model directory.")
        }
        let modelDirectory = URL(fileURLWithPath: dir, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("config.json").path),
                      "model dir must contain config.json")

        // The load itself is the gate: E4B throws mismatchedSize/keyNotFound here.
        let runtime = try await MLXDistillRuntime(modelDirectory: modelDirectory)
        try await runtime.warmup()

        let scheduler = DistillScheduler(runtime: runtime, maxConcurrentRequests: 1, resultCacheTTLSeconds: 0)
        let input = """
        RemoteCode Token Saver compresses long agent output locally on macOS.
        It must preserve exact commands, errors, file paths, and pass criteria.
        The local distill model rewrites verbose prose into compact /distill form.
        """
        let response = try await scheduler.submit(DistillRequest(
            mode: .longText, priority: .interactive, input: input, maxOutputCharacters: 600
        ))

        XCTAssertFalse(response.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "the 1.7B model must produce non-empty output")
        XCTAssertEqual(response.routeStage, .llmMLX,
                       "WHY: a long prose prompt that the deterministic router can't compress must reach the loaded MLX model — proving the LLM technique actually runs")
        XCTAssertLessThanOrEqual(response.output.count, 600)
        print("DISTILL-17B routeStage=\(String(describing: response.routeStage)) in=\(response.inputTokens) out=\(response.outputTokens) output=\(response.output)")
    }
}
