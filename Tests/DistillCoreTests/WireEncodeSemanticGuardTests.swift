import XCTest
import CoreModel
@testable import DistillCore

final class WireEncodeSemanticGuardTests: XCTestCase {
    private let original = "Explain in one short human-readable sentence why a disposable local workspace improves software testing. Emphasize that isolation keeps experiments separate from valuable work, repeatability makes the same scenario reproducible, safety limits the damage from risky operations, cleanup removes temporary state, and these properties increase confidence in the result. Do not use tools and do not change files. The answer should be concise, readable, and intended for a human. A disposable workspace is temporary by design, so experiments can be repeated and discarded without contaminating unrelated projects. Summarize these ideas without omitting isolation, repeatability, safety, cleanup, or confidence."

    private let compact = "One short human-readable sentence: a disposable temporary local software-testing workspace gives experiments isolation from valuable work; repeatability reproduces scenarios and permits discard without contaminating unrelated projects; safety limits risky-operation damage; cleanup removes temporary state, increasing confidence; use no tools and change no files."

    private func wire(_ brief: String) throws -> String {
        try RCWireProtocol.serialize(.init(
            direction: .request,
            sequence: 1,
            records: [.init(kind: .goal, value: brief)]
        ))
    }

    func test_wireEncodeRejectsEvenPlausibleParaphraseWithoutReconstruction() throws {
        let candidate = try wire(compact)
        let request = DistillRequest(mode: .wireEncode, input: original)
        XCTAssertEqual(
            MLXDistillRuntime.guardLossyProseOutput(candidate, request: request),
            original
        )
    }

    func test_wireEncodeRejectsSemanticInversionToHumanInput() throws {
        let inverted = try wire(compact.replacingOccurrences(
            of: "use no tools and change no files",
            with: "use tools and change files"
        ))
        let request = DistillRequest(mode: .wireEncode, input: original)
        XCTAssertEqual(
            MLXDistillRuntime.guardLossyProseOutput(inverted, request: request),
            original,
            "a rejected model candidate must fail open to Human, never verbose RCW1"
        )
    }

    func test_wireEncodeRejectsObservedModelSummaryThatDropsConstraintsAndRelations() throws {
        let observedModelBrief = "Isolation, repeatability, safety, cleanup enhance confidence by keeping experiments separate from valuable work."
        let request = DistillRequest(mode: .wireEncode, input: original)
        XCTAssertEqual(
            MLXDistillRuntime.guardLossyProseOutput(try wire(observedModelBrief), request: request),
            original,
            "the real E4B output omits format, operational constraints, and three causal relationships"
        )
    }

    func test_wireEncodeRejectsLosslessRCW1FallbackToHumanInput() throws {
        let verboseFallback = try RCWireProtocol.serializeRequestText(original)
        let request = DistillRequest(mode: .wireEncode, input: original)
        XCTAssertEqual(
            MLXDistillRuntime.guardLossyProseOutput(verboseFallback, request: request),
            original,
            "framing Human verbatim is not semantic compression"
        )
    }
}
