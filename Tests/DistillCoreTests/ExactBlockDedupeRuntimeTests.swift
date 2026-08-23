import XCTest
@testable import DistillCore

final class ExactBlockDedupeRuntimeTests: XCTestCase {
    private struct MustNotRunRuntime: DistillRuntime {
        private struct UnexpectedCall: Error {}

        func distill(_ request: DistillRequest) async throws -> String {
            throw UnexpectedCall()
        }

        func distillStaged(_ request: DistillRequest) async throws -> DistillStageResult {
            throw UnexpectedCall()
        }
    }

    func test_commandOutputCollapsesOnlySecondByteExactLargeBlock() throws {
        let repeated = "PASS checkout completed\n" + String(repeating: "artifact checksum remains stable ", count: 16)
        let input = "Build summary.\n\n\(repeated)\n\nUnique deployment note.\n\n\(repeated)\n\nDone."
        let request = DistillRequest(
            mode: .commandOutput,
            input: input,
            question: "Summarize the build without losing status evidence.",
            maxOutputCharacters: 4_000
        )

        let output = try XCTUnwrap(ExactBlockDedupeTransform.commandOutput(for: request))

        XCTAssertEqual(output.components(separatedBy: repeated).count - 1, 1,
                       "the first byte-exact occurrence remains inline for provider reasoning")
        XCTAssertTrue(output.contains("⟪identical to the first byte-identical block above⟫"),
                      "the duplicate becomes a model-readable reference to retained evidence")
        XCTAssertLessThan(output.utf8.count, input.utf8.count)
        XCTAssertEqual(
            input.utf8.count - output.utf8.count,
            repeated.utf8.count - "⟪identical to the first byte-identical block above⟫".utf8.count
        )
    }

    func test_exactAPIHandlesMixedParagraphSizesAndTwoDuplicateFamilies() {
        let firstFamily = "FIRST FAMILY\n" + String(repeating: "alpha evidence remains byte exact ", count: 15)
        let secondFamily = "SECOND FAMILY\n" + String(repeating: "beta evidence remains byte exact ", count: 15)
        let pointer = "⟪identical to the first byte-identical block above⟫"
        let input = [
            "short preface",
            firstFamily,
            "short separator",
            secondFamily,
            firstFamily,
            "short conclusion",
            secondFamily
        ].joined(separator: "\n\n")

        let result = DistillBlockDeduper.dedupeExact(input)

        XCTAssertEqual(result.dedupedBlocks, 2)
        XCTAssertEqual(result.nearDedupedBlocks, 0)
        XCTAssertEqual(result.output.components(separatedBy: firstFamily).count - 1, 1)
        XCTAssertEqual(result.output.components(separatedBy: secondFamily).count - 1, 1)
        XCTAssertEqual(result.output.components(separatedBy: pointer).count - 1, 2)
        XCTAssertTrue(result.output.contains("short preface\n\n\(firstFamily)\n\nshort separator"),
                      "short paragraphs remain byte-for-byte in their original order")
        XCTAssertEqual(
            input.utf8.count - result.output.utf8.count,
            firstFamily.utf8.count + secondFamily.utf8.count - (2 * pointer.utf8.count)
        )
    }

    func test_exactAPIRejectsUnicodeCanonicalEquivalenceThatIsNotByteIdentical() {
        let precomposed = String(repeating: "caf\u{00E9} ", count: 90)
        let decomposed = String(repeating: "cafe\u{0301} ", count: 90)
        XCTAssertEqual(precomposed, decomposed, "Swift String equality is canonical, so this guards the byte-exact contract")
        XCTAssertNotEqual(Array(precomposed.utf8), Array(decomposed.utf8))
        let input = "\(precomposed)\n\n\(decomposed)"

        let result = DistillBlockDeduper.dedupeExact(input)

        XCTAssertEqual(result.output, input)
        XCTAssertEqual(result.dedupedBlocks, 0)
        XCTAssertEqual(result.nearDedupedBlocks, 0)
    }

    func test_commandOutputLeavesWhitespaceDifferentLargeBlocksUntouched() {
        let block = String(repeating: "load-bearing indentation ", count: 20)
        let input = "\(block)\n\n \(block)"
        let request = DistillRequest(mode: .commandOutput, input: input, maxOutputCharacters: 4_000)

        XCTAssertNil(ExactBlockDedupeTransform.commandOutput(for: request),
                     "leading whitespace is data and must prevent an exact match")
    }

    func test_commandOutputLeavesNewlineEncodingDriftUntouched() {
        let tail = String(repeating: "same visible lines remain load bearing ", count: 14)
        let input = "line one\nline two\n\(tail)\n\nline one\r\nline two\r\n\(tail)"
        let request = DistillRequest(mode: .commandOutput, input: input, maxOutputCharacters: 4_000)

        XCTAssertNil(ExactBlockDedupeTransform.commandOutput(for: request),
                     "LF and CRLF blocks are visibly similar but not byte-identical")
    }

    func test_commandOutputDoesNotActivateExistingVolatileNearDuplicatePath() {
        let tail = String(repeating: " stable diagnostic evidence", count: 22)
        let first = "2026-08-23T10:20:30Z pid=1234\(tail)"
        let second = "2026-08-23T10:20:31Z pid=5678\(tail)"
        let input = "\(first)\n\n\(second)"
        let request = DistillRequest(mode: .commandOutput, input: input, maxOutputCharacters: 4_000)

        XCTAssertNil(ExactBlockDedupeTransform.commandOutput(for: request),
                     "exact-only production routing must not normalize timestamps or PIDs")
    }

    func test_commandOutputPreservesPASSFAILSemanticFlip() {
        let tail = String(repeating: " identical surrounding test evidence", count: 18)
        let input = "PASS checkout suite\(tail)\n\nFAIL checkout suite\(tail)"
        let request = DistillRequest(mode: .commandOutput, input: input, maxOutputCharacters: 4_000)

        XCTAssertNil(ExactBlockDedupeTransform.commandOutput(for: request))
    }

    func test_commandOutputLeavesShortDuplicatesUntouched() {
        let input = "PASS concise proof\n\nPASS concise proof"
        let request = DistillRequest(mode: .commandOutput, input: input, maxOutputCharacters: 4_000)

        XCTAssertNil(ExactBlockDedupeTransform.commandOutput(for: request))
    }

    func test_exactAPIFailsOpenWhenPointerWouldNotSaveBytes() {
        let input = "x\n\nx"

        let result = DistillBlockDeduper.dedupeExact(input, minBlockBytes: 0)

        XCTAssertEqual(result.output, input)
        XCTAssertEqual(result.dedupedBlocks, 0)
    }

    func test_transformSkipsWrongModeAndCandidateOverCharacterBudget() {
        let repeated = String(repeating: "large repeated evidence ", count: 24)
        let input = "\(repeated)\n\n\(repeated)"

        XCTAssertNil(ExactBlockDedupeTransform.commandOutput(for: DistillRequest(
            mode: .longText,
            input: input,
            maxOutputCharacters: 4_000
        )))
        XCTAssertNil(ExactBlockDedupeTransform.commandOutput(for: DistillRequest(
            mode: .commandOutput,
            input: input,
            maxOutputCharacters: 100
        )))
    }

    func test_sharedEncoderRuntimeShortCircuitsWrappedModelAndAttributesDeterministicStage() async throws {
        let repeated = "exact shared-runtime evidence\n" + String(repeating: "byte-identical provider context ", count: 16)
        let input = "Preface.\n\n\(repeated)\n\nMiddle.\n\n\(repeated)\n\nDone."
        let runtime = EncoderFirstRuntime(wrapping: MustNotRunRuntime(), encoderLane: nil)

        let result = try await runtime.distillStaged(DistillRequest(
            mode: .commandOutput,
            input: input,
            maxOutputCharacters: 4_000
        ))

        XCTAssertEqual(result.stage, .deterministic)
        XCTAssertTrue(result.output.contains("⟪identical to the first byte-identical block above⟫"))
        XCTAssertLessThan(result.output.utf8.count, input.utf8.count)
    }
}
