import XCTest
@testable import DistillCore
@testable import CoreModel

final class SR2OptimizerTests: XCTestCase {
    private let original = """
    Use the Trello skill and /sam-task. After Playwright verification succeeds, merge with gh.
    The task is not complete until deployment and post-deployment testing succeed.
    """

    private let faithful = """
    @sr2 v1
    tools:Trello|Playwright|gh
    flow:/sam-task>Playwright:verify>gh:merge>deploy>retest
    done:flow
    not:stop-before-done
    o:cont
    """

    func testSemanticIRSeparatesRequirementsOrderingAndCompletionBeforeEncoding() {
        let ir = SR2SemanticIR.parse(original)

        XCTAssertTrue(ir.requiresOrdering)
        XCTAssertTrue(ir.hasCompletionCondition)
        XCTAssertFalse(ir.hasProhibition,
                       "'not complete until' is a completion gate, not a general prohibition")
        XCTAssertTrue(ir.anchors.contains("/sam-task"))
        XCTAssertTrue(ir.anchors.contains("Trello"))
        XCTAssertTrue(ir.anchors.contains("Playwright"))
    }

    func testOptimizerAcceptsCheaperBehaviorallyCoveredSR2Candidate() {
        let decision = SR2Optimizer.optimize(original: original, candidates: [faithful])

        XCTAssertTrue(decision.accepted, decision.rejectionReason ?? "")
        XCTAssertEqual(decision.output, faithful)
        XCTAssertLessThan(decision.optimizedTokens, decision.originalTokens)
        XCTAssertEqual(decision.semanticCoverage, 1)
    }

    func testOptimizerRejectsCandidateThatLosesOrderingOrCompletionGate() {
        let lossy = """
        @sr2 v1
        tools:Trello|Playwright|gh
        must:/sam-task+Playwright:verify+gh:merge+deploy+retest
        o:cont
        """
        let decision = SR2Optimizer.optimize(original: original, candidates: [lossy])

        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.output, original)
        XCTAssertTrue(decision.rejectionReason?.contains("ordering") == true
            || decision.rejectionReason?.contains("completion") == true)
    }

    func testOptimizerRejectsCandidateThatDropsASeparateRequiredAction() {
        let source = "Review the controller. Update docs. Run tests."
        let lossy = """
        @sr2 v1
        flow:review:controller>test
        o:cont
        """

        let decision = SR2Optimizer.optimize(original: source, candidates: [lossy])

        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.output, source)
        XCTAssertTrue(decision.rejectionReason?.contains("docs") == true,
                      decision.rejectionReason ?? "")
    }

    func testOptimizerRejectsLostConditionAndAlternative() {
        let conditional = "If verification passes, deploy using Chrome or Computer Use."
        let noConditionOrAlternative = """
        @sr2 v1
        tools:Chrome
        must:verify+deploy+ComputerUse
        o:cont
        """

        let decision = SR2Optimizer.optimize(
            original: conditional,
            candidates: [noConditionOrAlternative]
        )

        XCTAssertFalse(decision.accepted)
        XCTAssertTrue(
            decision.rejectionReason?.contains("conditional") == true
                || decision.rejectionReason?.contains("alternative") == true,
            decision.rejectionReason ?? ""
        )
    }

    func testOptimizerUsesTargetTokenizerInsteadOfCharacterCount() {
        let visuallyShort = faithful.replacingOccurrences(of: "Playwright", with: "⚙︎")
        let decision = SR2Optimizer.optimize(
            original: original,
            candidates: [visuallyShort],
            targetTokenizer: "test-expensive-symbols",
            tokenCount: { text in text.contains("⚙︎") ? 10_000 : text.split(separator: " ").count }
        )

        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.output, original)
    }

    func testOptimizerAcceptsSemanticV1WithoutArtificialOutcome() {
        let source = "After verifying, merge main. The task is complete only after deployment succeeds."
        let candidate = """
        @sr2 v1
        flow:verify>merge:main>deploy
        done:deploy
        """
        let decision = SR2Optimizer.optimize(
            original: source,
            candidates: [candidate],
            tokenCount: { $0 == source ? 100 : 20 }
        )

        XCTAssertTrue(decision.accepted, decision.rejectionReason ?? "")
        XCTAssertEqual(decision.output, candidate)
    }

    func testDistillLongTextPromptDefinesSemanticCompilerContract() {
        let instructions = MLXDistillRuntime.systemInstructions(for: .longText)
        XCTAssertTrue(instructions.contains("semantic compiler"), instructions)
        XCTAssertTrue(instructions.contains("Semantic IR"), instructions)
        XCTAssertTrue(instructions.contains("actual token count"), instructions)
        XCTAssertTrue(instructions.contains("ordering"), instructions)
        XCTAssertTrue(instructions.contains("completion"), instructions)
        XCTAssertTrue(instructions.contains("@sr2 v1"), instructions)
    }
}
