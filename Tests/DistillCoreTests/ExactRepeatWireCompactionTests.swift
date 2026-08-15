import XCTest
import CoreModel
@testable import DistillCore

final class ExactRepeatWireCompactionTests: XCTestCase {
    private let naturalLanguageBlock = "Before cleanup, inspect the disposable workspace without tools; keep /tmp/rcw1-test/fixture.txt unchanged; then report only observed evidence."

    private func expectedWire(_ block: String, count: Int) throws -> String {
        try RCWireProtocol.addingRequestRecords(
            [.init(kind: .context, value: "Human repeated G verbatim \(count) times.")],
            to: RCWireProtocol.serializeRequestText(block)
        )
    }

    func test_threeOrMoreExactConsecutiveBlocksCompactDeterministically() throws {
        let input = Array(repeating: naturalLanguageBlock, count: 6).joined(separator: " ")
        let request = DistillRequest(mode: .wireEncode, input: input)

        let output = try XCTUnwrap(MLXDistillRuntime.deterministicExactRepeatWireOutput(for: request))
        let expected = try expectedWire(naturalLanguageBlock, count: 6)

        XCTAssertEqual(output, expected)
        XCTAssertTrue(RCWireProtocol.preservesProtectedSemantics(original: input, wire: output))
        XCTAssertTrue(RCWireProtocol.preservesRequestMeaning(original: input, wire: output))
        XCTAssertNil(LiteralPreservation.guarded(original: input, compressed: output).droppedLiteral)
        XCTAssertLessThan(output.utf8.count, input.utf8.count)
    }

    func test_modelUnavailableFallbackStillUsesDeterministicRepeatRoute() async throws {
        let input = Array(repeating: naturalLanguageBlock, count: 6).joined(separator: " ")
        let result = try await LocalDistillRuntime().distillStaged(
            DistillRequest(mode: .wireEncode, input: input)
        )

        XCTAssertEqual(result.stage, .deterministic)
        XCTAssertEqual(result.output, try expectedWire(naturalLanguageBlock, count: 6))
    }

    func test_nonRepeatedLocalWireRequestReturnsExactHumanVerbatim() async throws {
        let input = "Inspect the disposable workspace without tools and report only observed evidence."
        let result = try await LocalDistillRuntime().distillStaged(
            DistillRequest(mode: .wireEncode, input: input)
        )

        XCTAssertEqual(result.stage, .verbatim)
        XCTAssertEqual(result.output, input)
        XCTAssertFalse(RCWireProtocol.isWire(result.output))
    }

    func test_exactRepeatedMultisentenceBlockCompactsAsOneOrderedBlock() throws {
        let block = "Inspect the isolated workspace without tools. Then verify cleanup before reporting success."
        let input = Array(repeating: block, count: 4).joined(separator: "\n\n")

        let output = try XCTUnwrap(MLXDistillRuntime.deterministicExactRepeatWireOutput(
            for: DistillRequest(mode: .wireEncode, input: input)
        ))

        XCTAssertEqual(output, try expectedWire(block, count: 4))
        XCTAssertTrue(RCWireProtocol.preservesRequestMeaning(original: input, wire: output))
    }

    func test_byteIdenticalBlocksWithTheirOwnTrailingWhitespaceStillCompact() throws {
        let blockWithTrailingSpace = "Keep the disposable workspace isolated, repeatable, and safe. "
        let input = Array(repeating: blockWithTrailingSpace, count: 6).joined(separator: " ")

        let output = try XCTUnwrap(MLXDistillRuntime.deterministicExactRepeatWireOutput(
            for: DistillRequest(mode: .wireEncode, input: input)
        ))

        XCTAssertEqual(
            output,
            try expectedWire(blockWithTrailingSpace, count: 6)
        )
    }

    func test_directlyConcatenatedBlocksPreserveTheirExactCount() throws {
        let block = "Keep the disposable workspace isolated, repeatable, and safe. "
        let input = String(repeating: block, count: 6)

        let output = try XCTUnwrap(MLXDistillRuntime.deterministicExactRepeatWireOutput(
            for: DistillRequest(mode: .wireEncode, input: input)
        ))

        XCTAssertEqual(output, try expectedWire(block, count: 6))
        XCTAssertTrue(RCWireProtocol.preservesRequestMeaning(original: input, wire: output))
    }

    func test_nonIdempotentRepeatedImperativeCarriesMultiplicity() throws {
        let block = "Increment the disposable test counter exactly once and append the resulting value to the audit log."
        let input = Array(repeating: block, count: 3).joined(separator: " ")

        let output = try XCTUnwrap(MLXDistillRuntime.deterministicExactRepeatWireOutput(
            for: DistillRequest(mode: .wireEncode, input: input)
        ))
        let records = try XCTUnwrap(RCWireProtocol.parse(output).first?.records)

        XCTAssertEqual(records.first(where: { $0.kind == .goal })?.value, block)
        XCTAssertEqual(
            records.first(where: { $0.kind == .context })?.value,
            "Human repeated G verbatim 3 times."
        )
        XCTAssertTrue(RCWireProtocol.preservesRequestMeaning(original: input, wire: output))
    }

    func test_twoCopiesRemainHumanBecauseIntentionalEmphasisIsAmbiguous() {
        let input = Array(repeating: naturalLanguageBlock, count: 2).joined(separator: " ")

        XCTAssertNil(MLXDistillRuntime.deterministicExactRepeatWireOutput(
            for: DistillRequest(mode: .wireEncode, input: input)
        ))
    }

    func test_nearDuplicateAndNonNaturalLanguageInputsFailOpen() {
        let changed = naturalLanguageBlock.replacingOccurrences(of: "observed", with: "verified")
        let nearDuplicate = [naturalLanguageBlock, naturalLanguageBlock, changed].joined(separator: " ")
        let repeatedCode = Array(repeating: "```sh\nprintf 'safe'\n```", count: 4).joined(separator: "\n\n")

        for input in [nearDuplicate, repeatedCode] {
            XCTAssertNil(MLXDistillRuntime.deterministicExactRepeatWireOutput(
                for: DistillRequest(mode: .wireEncode, input: input)
            ))
        }
    }

    func test_reported704BytePromptHasNoExactRepeatAndFailsOpen() {
        let input = [
            "Explain in one short human-readable sentence why a disposable local workspace improves software testing.",
            "Emphasize that isolation keeps experiments separate from valuable work, repeatability makes the same scenario reproducible, safety limits the damage from risky operations, cleanup removes temporary state, and these properties increase confidence in the result.",
            "Do not use tools and do not change files.",
            "The answer should be concise, readable, and intended for a human.",
            "A disposable workspace is temporary by design, so experiments can be repeated and discarded without contaminating unrelated projects.",
            "Summarize these ideas without omitting isolation, repeatability, safety, cleanup, or confidence."
        ].joined(separator: " ")
        XCTAssertEqual(input.utf8.count, 704)

        XCTAssertNil(MLXDistillRuntime.deterministicExactRepeatWireOutput(
            for: DistillRequest(mode: .wireEncode, input: input)
        ))
    }

    func test_otherModesNeverUseRequestCompaction() {
        let input = Array(repeating: naturalLanguageBlock, count: 6).joined(separator: " ")

        XCTAssertNil(MLXDistillRuntime.deterministicExactRepeatWireOutput(
            for: DistillRequest(mode: .longText, input: input)
        ))
    }
}
