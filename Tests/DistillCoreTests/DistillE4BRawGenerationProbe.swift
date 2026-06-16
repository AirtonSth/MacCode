@testable import DistillCore
import Foundation
import XCTest

/// Coherence probe for the patched gemma4 port: loads the E4B checkpoint via `MLXDistillRuntime`
/// and generates on clear prompts using the raw test seam (no distill faithfulness/literal
/// guards). Proves the `RCGemma4ModelOverride` produces COHERENT text rather than
/// loading-but-emitting-garbage. Disabled unless the model dir is set.
///
///   REMOTE_CODE_TOKEN_SAVER_E4B_DIR=<model dir> \
///     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///     swift test --filter DistillE4BRawGenerationProbe
final class DistillE4BRawGenerationProbe: XCTestCase {
    func test_E4BGeneratesCoherentText() async throws {
        guard let dir = ProcessInfo.processInfo.environment["REMOTE_CODE_TOKEN_SAVER_E4B_DIR"], !dir.isEmpty else {
            throw XCTSkip("Set REMOTE_CODE_TOKEN_SAVER_E4B_DIR to the installed E4B model directory.")
        }
        let runtime = try await MLXDistillRuntime(modelDirectory: URL(fileURLWithPath: dir, isDirectory: true))

        let cases: [(prompt: String, mustContain: String)] = [
            ("What is the capital of France? Answer with a single word.", "paris"),
            ("Translate to French: good morning.", "bonjour"),
        ]
        for testCase in cases {
            let output = try await runtime.generateRawForTesting(
                instructions: "You are a helpful, concise assistant.",
                prompt: testCase.prompt,
                maxTokens: 48
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            print("PROBE prompt=\(testCase.prompt)\nPROBE output=\(output)\n---")

            XCTAssertFalse(output.isEmpty, "model must produce non-empty output for: \(testCase.prompt)")
            XCTAssertFalse(output.unicodeScalars.contains("\u{FFFD}"),
                           "output must not contain replacement characters (broken decode)")
            let letters = output.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            XCTAssertGreaterThan(letters, 1,
                                 "WHY: a working model emits real words; a numerically broken port emits junk")
            XCTAssertTrue(output.lowercased().contains(testCase.mustContain),
                          "WHY: a correctly-ported gemma4 must answer '\(testCase.mustContain)' to '\(testCase.prompt)'; got '\(output)'")
        }
    }
}
