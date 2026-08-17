import XCTest
import CoreModel
@testable import DistillCore

final class DistillPromptTests: XCTestCase {
    func test_runtimeUsesDistillPromptAsSingleSource() {
        for mode in [DistillMode.commandOutput, .longText, .watchSummary, .wireEncode, .naturalLanguage] {
            XCTAssertEqual(
                MLXDistillRuntime.systemInstructions(for: mode),
                DistillPrompt.systemInstructions(for: mode),
                "WHY: a private copy of the compression prompt would silently ignore the Grok-corpus rewrite"
            )
        }
        let request = DistillRequest(mode: .longText, input: "hello path Sources/App.swift:12 code 5004")
        XCTAssertEqual(
            MLXDistillRuntime.prompt(for: request),
            DistillPrompt.userPrompt(for: request)
        )
        XCTAssertFalse(
            DistillPrompt.userPrompt(for: request).contains("OUTPUT:"),
            "WHY: the old longText suffix made models echo OUTPUT: and waste adopted tokens"
        )
    }

    func test_commandAndLongTextPromptsCarryDensityMarkerAndLiteralPin() {
        let command = DistillPrompt.systemInstructions(for: .commandOutput)
        let longText = DistillPrompt.systemInstructions(for: .longText)
        XCTAssertTrue(command.contains(DistillPrompt.densityMarker))
        XCTAssertTrue(longText.contains(DistillPrompt.densityMarker))
        XCTAssertTrue(command.contains("file:line"))
        XCTAssertTrue(longText.contains("file:line"))
        XCTAssertTrue(command.contains("Do not paraphrase"))
        XCTAssertTrue(longText.contains("Do not paraphrase"))
        XCTAssertTrue(command.contains("Never drop a path, file:line, number, ID, hash, command, or error token"))
        XCTAssertTrue(longText.contains("Never drop a path, file:line, number, ID, hash, command, or error token"))
    }

    func test_n5RejectsDroppedFileLineAsFailOpen() {
        let original = "ERROR test case 4 failed at Sources/App/File4.swift:204 with code 5004."
        let dropped = "ERROR test case 4 failed with a server code."
        let guarded = LiteralPreservation.guarded(original: original, compressed: dropped)
        XCTAssertEqual(guarded.output, original, "WHY: a rewrite that drops file:line must not be adopted")
        XCTAssertNotNil(guarded.droppedLiteral)
        XCTAssertTrue(
            (guarded.droppedLiteral ?? "").contains("File4.swift") || (guarded.droppedLiteral ?? "").contains("5004"),
            "WHY: the dropped pin must be a load-bearing path or code, got \(String(describing: guarded.droppedLiteral))"
        )

        let request = DistillRequest(mode: .longText, input: original)
        let n5 = MLXDistillRuntime.guardLossyProseOutput(dropped, request: request)
        XCTAssertEqual(n5, original, "WHY: longText N5 must fail-open to the original when a pinned literal is gone")
    }

    func test_commandOutputToolPathFailsOpenWhenRewriteDropsFileLine() {
        let body = (1...40).map { "padding line \($0) of a Read/Bash-sized tool payload" }.joined(separator: "\n")
        let original = """
        \(body)
        ERROR test case 4 failed at Sources/App/File4.swift:204 with code 5004.
        \(body)
        """
        XCTAssertGreaterThan(original.utf8.count, 2_048)
        let policy = ToolOutputCompressionPolicy()
        let decision = policy.decision(toolName: "Read", output: original)
        XCTAssertTrue(decision.shouldCompress)
        XCTAssertEqual(decision.mode, .commandOutput)

        let request = DistillRequest(
            mode: decision.mode,
            input: original,
            question: decision.contractQuestion
        )
        let dropped = "Read failed with a server error."
        let served = DistillAdopt.servedOutput(modelOutput: dropped, request: request)
        XCTAssertEqual(
            served,
            original,
            "WHY: a Read/Bash-sized commandOutput rewrite that drops file:line must not be served to Grok"
        )
        XCTAssertNotEqual(served, dropped)
    }

    func test_bashContractFailLineThatDropsFileLineIsNotExtractiveAndFailsOpen() {
        let body = (1...40).map { "padding line \($0) of a Bash-sized tool payload" }.joined(separator: "\n")
        let original = """
        \(body)
        FAIL Tests/test_billing.py:88 — assert 500 == 404 at Sources/App/File4.swift:204
        \(body)
        """
        XCTAssertGreaterThan(original.utf8.count, 2_048)
        let policy = ToolOutputCompressionPolicy()
        let decision = policy.decision(
            toolName: "Bash",
            output: original,
            toolArgumentsSummary: "command=swift test"
        )
        XCTAssertTrue(decision.shouldCompress)
        XCTAssertTrue(
            decision.contractQuestion.contains("failing"),
            "WHY: the shipped Bash contract says 'failing test names'; that must not skip N5"
        )
        XCTAssertFalse(
            MLXDistillRuntime.questionHasWholeWord(decision.contractQuestion, "fail"),
            "WHY: 'failing' is not the whole word 'fail'"
        )

        let request = DistillRequest(
            mode: .commandOutput,
            input: original,
            question: decision.contractQuestion
        )
        let dropped = "FAIL Tests/test_billing.py — expected 404, got 500"
        XCTAssertFalse(
            MLXDistillRuntime.isExtractiveCommandAnswer(dropped, request: request),
            "WHY: a Bash compress contract is not a PASS/FAIL extractive ask"
        )
        let served = DistillAdopt.servedOutput(modelOutput: dropped, request: request)
        XCTAssertEqual(
            served,
            original,
            "WHY: FAIL-prefixed rewrite that drops file:line must not be served on the Bash tool path"
        )
    }

    func test_n5AdoptsLiteralPreservingShorterRewrite() {
        let original = """
        ERROR test case 4 failed at Sources/App/File4.swift:204 with code 5004.
        Extra debug context repeated repeated repeated repeated repeated.
        """
        let compressed = "ERROR test case 4 failed at Sources/App/File4.swift:204 with code 5004."
        let guarded = LiteralPreservation.guarded(original: original, compressed: compressed)
        XCTAssertNil(guarded.droppedLiteral)
        XCTAssertEqual(guarded.output, compressed)
        XCTAssertTrue(FaithfulnessGate.validate(original: original, compressed: compressed).accepted)
        XCTAssertLessThan(TokenEstimator.estimate(compressed), TokenEstimator.estimate(original))
    }

    func test_exactOutputToolsStayUncompressed() {
        XCTAssertTrue(CommandWrapPolicy.isExactOutputCommand("rg"))
        XCTAssertTrue(CommandWrapPolicy.isExactOutputCommand("grep"))
        XCTAssertTrue(CommandWrapPolicy.isExactOutputCommand("/usr/bin/cat"))
        XCTAssertFalse(CommandWrapPolicy.isExactOutputCommand("swift"))

        let policy = ToolOutputCompressionPolicy()
        let skipped = policy.decision(
            toolName: "Bash",
            output: String(repeating: "match line should stay raw\n", count: 80),
            toolArgumentsSummary: "command=rg -n fail Sources"
        )
        XCTAssertFalse(skipped.shouldCompress)
        XCTAssertEqual(skipped.skipReason, .exactOutputShell)
    }

    func test_toolContractQuestionKeepsFileReadAndAddsDensityMarker() {
        let policy = ToolOutputCompressionPolicy()
        let read = policy.decision(
            toolName: "Read",
            output: String(repeating: "func load() {}\n", count: 80)
        )
        XCTAssertTrue(read.shouldCompress)
        XCTAssertTrue(read.contractQuestion.localizedCaseInsensitiveContains("file read"))
        XCTAssertTrue(read.contractQuestion.contains(DistillPrompt.densityMarker))
    }
}
