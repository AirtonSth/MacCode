import XCTest
@testable import CoreModel

final class RCWireSemanticFidelityTests: XCTestCase {
    private let reportedPrompt = "Explain in one short human-readable sentence why a disposable local workspace improves software testing. Emphasize that isolation keeps experiments separate from valuable work, repeatability makes the same scenario reproducible, safety limits the damage from risky operations, cleanup removes temporary state, and these properties increase confidence in the result. Do not use tools and do not change files. The answer should be concise, readable, and intended for a human. A disposable workspace is temporary by design, so experiments can be repeated and discarded without contaminating unrelated projects. Summarize these ideas without omitting isolation, repeatability, safety, cleanup, or confidence."

    private let compactBrief = "One short human-readable sentence: a disposable temporary local software-testing workspace gives experiments isolation from valuable work; repeatability reproduces scenarios and permits discard without contaminating unrelated projects; safety limits risky-operation damage; cleanup removes temporary state, increasing confidence; use no tools and change no files."

    private func wire(_ brief: String, repetitionCount: Int? = nil) throws -> String {
        var records = [RCWireRecord(kind: .goal, value: brief)]
        if let repetitionCount {
            records.append(.init(
                kind: .context,
                value: RCWireProtocol.exactGoalRepetitionContext(count: repetitionCount)
            ))
        }
        return try RCWireProtocol.serialize(.init(
            direction: .request,
            sequence: 1,
            records: records
        ))
    }

    func test_compactParaphraseIsRejectedWithoutByteExactReconstruction() throws {
        XCTAssertFalse(
            RCWireProtocol.preservesRequestMeaning(
                original: reportedPrompt,
                wire: try wire(compactBrief)
            ),
            "a plausible paraphrase is not proof of byte-exact intent preservation"
        )
    }

    func test_exactHumanGoalIsReconstructableButNotClaimedAsCompression() throws {
        let exact = try wire(reportedPrompt)
        XCTAssertTrue(RCWireProtocol.preservesRequestMeaning(original: reportedPrompt, wire: exact))
        XCTAssertGreaterThan(exact.utf8.count, reportedPrompt.utf8.count)
    }

    func test_removingAnyRepeatedFacetRejectsTheBrief() throws {
        let facets = [
            "isolation": "gives experiments isolation from valuable work; ",
            "repeatability": "repeatability reproduces scenarios and permits discard without contaminating unrelated projects; ",
            "safety": "safety limits risky-operation damage; ",
            "cleanup": "cleanup removes temporary state, ",
            "confidence": "increasing confidence; ",
        ]
        for (facet, encodedFacet) in facets {
            let incomplete = compactBrief.replacingOccurrences(of: encodedFacet, with: "")
            XCTAssertFalse(
                RCWireProtocol.preservesRequestMeaning(
                    original: reportedPrompt,
                    wire: try wire(incomplete)
                ),
                "dropping the \(facet) facet must fail closed"
            )
        }
    }

    func test_removingFormatOrOperationalConstraintRejectsTheBrief() throws {
        let incompleteBriefs = [
            compactBrief.replacingOccurrences(of: "One ", with: ""),
            compactBrief.replacingOccurrences(of: "human-readable ", with: ""),
            compactBrief.replacingOccurrences(of: "no tools and ", with: ""),
            compactBrief.replacingOccurrences(of: "change no files", with: ""),
        ]
        for incomplete in incompleteBriefs {
            XCTAssertFalse(
                RCWireProtocol.preservesRequestMeaning(
                    original: reportedPrompt,
                    wire: try wire(incomplete)
                ),
                "format and safety constraints are atomic, not optional prose"
            )
        }
    }

    func test_keywordInventoryCannotStandInForRelationships() throws {
        let inventory = "One short human-readable sentence; disposable temporary local software-testing workspace; isolation; repeatability; safety; cleanup; confidence; experiments repeat and discard without contaminating unrelated projects; no tools; no file changes."
        XCTAssertFalse(
            RCWireProtocol.preservesRequestMeaning(original: reportedPrompt, wire: try wire(inventory)),
            "facet names and constraints without their source relationships must fail closed"
        )
    }

    func test_oneCandidateClauseCannotSatisfyManyIndependentSourceRelationships() throws {
        let bag = "One short human-readable sentence: disposable temporary local software-testing workspace improve isolation keep experiments separate valuable work repeatability make same scenario reproducible safety limit damage risky operations cleanup remove temporary state increase confidence discard without contaminating unrelated projects; use no tools and change no files."
        XCTAssertFalse(
            RCWireProtocol.preservesRequestMeaning(original: reportedPrompt, wire: try wire(bag)),
            "one lexical bag cannot be reused as proof for many independent source relationships"
        )
    }

    func test_exactlyRepeatedSourceRelationshipsRequireTheirTruthfulCount() throws {
        let unit = "Before cleanup, inspect the disposable workspace without tools; keep the workspace isolated from valuable work; then report only observed evidence."
        let original = Array(repeating: unit, count: 3).joined(separator: " ")

        XCTAssertTrue(
            RCWireProtocol.preservesRequestMeaning(
                original: original,
                wire: try wire(unit, repetitionCount: 3)
            ),
            "one verbatim G plus its exact repetition count preserves the complete Human instruction"
        )
        XCTAssertFalse(
            RCWireProtocol.preservesRequestMeaning(original: original, wire: try wire(unit)),
            "collapsing repeated instructions without their multiplicity loses emphasis or action count"
        )
        for wrongCount in [2, 4] {
            XCTAssertFalse(
                RCWireProtocol.preservesRequestMeaning(
                    original: original,
                    wire: try wire(unit, repetitionCount: wrongCount)
                ),
                "an invented repetition count must fail closed"
            )
        }
    }

    func test_facetsCannotBePairedWithEachOthersRelationships() throws {
        let scrambled = "One short human-readable sentence: a disposable temporary local software-testing workspace. Isolation makes the same scenario reproducible; repeatability limits risky-operation damage; safety removes temporary state; cleanup keeps experiments separate from valuable work; all increase confidence. Experiments repeat and discard without contaminating unrelated projects; use no tools and change no files."
        XCTAssertFalse(
            RCWireProtocol.preservesRequestMeaning(original: reportedPrompt, wire: try wire(scrambled)),
            "a facet must stay attached to its own action and object, not merely coexist with every keyword"
        )
    }

    func test_negationOrderAndApprovalInversionsReject() throws {
        let original = "Do not deploy before approval. Never delete files without permission."
        XCTAssertFalse(
            RCWireProtocol.preservesRequestMeaning(
                original: original,
                wire: try wire("no deploy before approval; no file deletion without permission")
            ),
            "semantic equivalence without byte reconstruction must fail closed"
        )
        for inverted in [
            "deploy before approval; no file deletion without permission",
            "no deploy after approval; no file deletion without permission",
            "no deploy before approval; delete files without permission",
        ] {
            XCTAssertFalse(
                RCWireProtocol.preservesRequestMeaning(original: original, wire: try wire(inverted)),
                "polarity, order, and approval relationships must not reverse"
            )
        }
    }

    func test_orderCueMustStayInTheClauseWhoseDirectionItControls() throws {
        let original = "Do not deploy before approval. Inspect files before testing."
        let misplaced = "Do not deploy after approval. Inspect files before testing."
        XCTAssertFalse(
            RCWireProtocol.preservesRequestMeaning(original: original, wire: try wire(misplaced)),
            "a valid 'before' elsewhere cannot mask reversing deploy-before-approval"
        )
    }

    func test_negationMustStayBoundToItsOriginalActionAndObject() throws {
        let original = "Do not delete files. Do not deploy releases."
        let displaced = "Delete files. Do not delete logs. Do not deploy releases."
        XCTAssertFalse(
            RCWireProtocol.preservesRequestMeaning(original: original, wire: try wire(displaced)),
            "an unrelated negative delete clause cannot preserve the permission boundary on files"
        )
    }
}
