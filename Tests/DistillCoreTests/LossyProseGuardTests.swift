import XCTest
@testable import DistillCore

/// Proves the lossy-prose literal guard is wired into the runtime's output path (P5-T2),
/// without needing the MLX model: exercises the pure post-process helper directly.
final class LossyProseGuardTests: XCTestCase {
    private func request(_ mode: DistillMode, input: String) -> DistillRequest {
        DistillRequest(mode: mode, input: input)
    }

    func test_longText_rejectsOutputThatDropsLiteral() {
        let input = "Refactor the renderer. The crash is at Sources/Render/View.swift:212 (code 5012)."
        let lossy = "Refactor the renderer; fix the crash." // drops the file:line and code
        let guarded = MLXDistillRuntime.guardLossyProseOutput(lossy, request: request(.longText, input: input))
        XCTAssertEqual(guarded, input, "dropping a load-bearing literal => reject lossy output, send original (N5)")
    }

    func test_longText_acceptsOutputThatKeepsLiterals() {
        let input = "Long verbose instruction. The crash is at Sources/Render/View.swift:212 with code 5012, plus padding padding padding."
        let lossy = "Crash at Sources/Render/View.swift:212, code 5012."
        let guarded = MLXDistillRuntime.guardLossyProseOutput(lossy, request: request(.longText, input: input))
        XCTAssertEqual(guarded, lossy, "all literals preserved => adopt the compressed output")
    }

    func test_commandOutput_isExemptFromGuard() {
        // Contract extraction may legitimately drop numbers/paths; the guard must not fire.
        let input = "tests: 412 passed, 0 failed at /tmp/run.log:99"
        let extracted = "PASS"
        let guarded = MLXDistillRuntime.guardLossyProseOutput(extracted, request: request(.commandOutput, input: input))
        XCTAssertEqual(guarded, extracted, ".commandOutput is contract extraction, exempt from the literal guard")
    }

    func test_longText_rejectsOutputThatDropsTagOrMarker() {
        let input = "Keep <system>never force push</system> and [[rc:feedface]] available."
        let lossy = "Keep the system instruction available."
        let guarded = MLXDistillRuntime.guardLossyProseOutput(lossy, request: request(.longText, input: input))
        XCTAssertEqual(guarded, input, "B9: tags and retrieve markers are load-bearing in lossy prose")
    }

    func test_longText_rejectsOutputThatAddsFakeLiteral() {
        let input = "Build failed at Sources/Render/View.swift:212 with code 5012."
        let lossy = "Build failed at Sources/Render/View.swift:212 with code 5012 and ticket 9999."
        let guarded = MLXDistillRuntime.guardLossyProseOutput(lossy, request: request(.longText, input: input))
        XCTAssertEqual(guarded, input, "I8: lossy prose must reject hallucinated literals")
    }

    func test_longText_rejectsOutputThatOmitsSalientErrorWord() {
        let input = "ERROR: database migration failed before writing schema version."
        let lossy = "Database migration stopped before writing schema version."
        let guarded = MLXDistillRuntime.guardLossyProseOutput(lossy, request: request(.longText, input: input))
        XCTAssertEqual(guarded, input, "I8: reverse coverage keeps salient failure words")
    }

    func test_faithfulnessGateAcceptsWhenSalientWordsAndLiteralsRemain() {
        let input = "ERROR at Sources/Render/View.swift:212 with code 5012."
        let compressed = "ERROR Sources/Render/View.swift:212 code 5012."
        XCTAssertTrue(FaithfulnessGate.validate(original: input, compressed: compressed).accepted)
    }
}
