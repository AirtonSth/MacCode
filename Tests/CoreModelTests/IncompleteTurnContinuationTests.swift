import XCTest
@testable import CoreModel

/// Contract for incomplete-turn recovery: multi-phase workflow handoffs and
/// background-await stalls, with workflow precedence over a misused marker.
///
/// WHY: full-access sam-work threads were marked green "completed" after Phase 2
/// ("Next: Phase 3 — Review") while the user task was still open; Phase 1 also
/// misused [[RC_AWAITING]] on a handoff and got the wrong BashOutput nudge.
final class IncompleteTurnContinuationTests: XCTestCase {

    // Verbatim finals from thread 4E3163DC (elephant /sam-work incident).
    private let phase1HandoffWithMisusedMarker = """
    Phase 1: **IMPLEMENT** — COMPLETE. Changes committed and pushed to DEV-3781.

    Summary:
    - ✓ CORS: Disabled permissive origin for REST v2 (`origin: false`)
    - ✓ FE REST clients: Switched to relative `/api` path
    - ✓ Tests: Updated and passing
    - ✓ Check: turbo run check passes

    Proceeding to Phase 2: **REFINE** — stress-test the implementation strategy.

    [[RC_AWAITING]]
    """

    private let phase2HandoffNoMarker = """
    Read-only integrity confirmed (submodule dirty state expected from Phase 1 edits; refinement task itself unmodified files).

    ---

    **PHASE 2 RESULT: HIGH_CONFIDENCE**

    **Summary:**
    - ✓ All code changes factually verified
    - ✓ TypeScript/lint/test checks passing
    - ⏳ Browser behavior deferred to Phase 7 (Playwright)

    **Next: Phase 3 — Review**
    """

    func test_incidentPhase1_classifiesAsWorkflowDespiteMisusedMarker() {
        // Load-bearing: marker-first background detection would mis-route this to
        // the BashOutput prompt. Workflow must win so the host nudges "continue
        // multi-phase workflow" instead of "check the background shell".
        XCTAssertEqual(
            IncompleteTurnContinuation.classify(phase1HandoffWithMisusedMarker),
            .workflowHandoff,
            "phase handoff + misused [[RC_AWAITING]] must classify as workflow, not background"
        )
        XCTAssertEqual(
            IncompleteTurnContinuation.prompt(for: .workflowHandoff),
            IncompleteTurnContinuation.workflowContinuationPrompt
        )
        XCTAssertNotEqual(
            IncompleteTurnContinuation.prompt(for: .workflowHandoff),
            BackgroundAwaitContinuation.continuationPrompt
        )
    }

    func test_incidentPhase2_classifiesAsWorkflowWithoutMarker() {
        XCTAssertEqual(
            IncompleteTurnContinuation.classify(phase2HandoffNoMarker),
            .workflowHandoff,
            "verbatim Phase 2 'Next: Phase 3' must not sit as green completed"
        )
        XCTAssertTrue(IncompleteTurnContinuation.isIncompleteTurn(phase2HandoffNoMarker))
    }

    func test_trueBackgroundAwait_stillClassifiesAsBackground() {
        let stall = "Standing by for the demo recording to complete."
        XCTAssertEqual(IncompleteTurnContinuation.classify(stall), .backgroundAwait)
        XCTAssertEqual(
            IncompleteTurnContinuation.prompt(for: .backgroundAwait),
            BackgroundAwaitContinuation.continuationPrompt
        )
    }

    func test_markerOnlyNovelBackground_classifiesAsBackground() {
        let novel = "\(BackgroundAwaitContinuation.awaitingMarker)\nHolding here until the canary bake finishes."
        XCTAssertEqual(IncompleteTurnContinuation.classify(novel), .backgroundAwait)
    }

    func test_genuineFinal_isNotIncomplete() {
        let done = "All four steps are done; the build is green and the PR is open."
        XCTAssertNil(IncompleteTurnContinuation.classify(done))
        XCTAssertFalse(IncompleteTurnContinuation.isIncompleteTurn(done))
        XCTAssertFalse(IncompleteTurnContinuation.isIncompleteTurn(nil))
    }

    func test_optionalRoadmap_doesNotAutoNudge() {
        // Precision: documenting future phases for the user must not start another
        // full-access run.
        let roadmap = """
        Implementation is complete and the PR is open.

        Optional next steps if you want them later:
        - Next: Phase 3 would add Playwright coverage
        - Phase 4 could polish copy
        """
        XCTAssertNil(
            IncompleteTurnContinuation.classify(roadmap),
            "optional roadmap with 'if you want' must not classify as incomplete turn"
        )
    }

    func test_delegatedNextPhaseWithoutNumber_doesNotMatch() {
        let delegated = """
        Task complete; the next phase: rollout belongs to ops.
        """
        XCTAssertNil(
            IncompleteTurnContinuation.classify(delegated),
            "unnumbered delegated 'next phase' must not auto-nudge"
        )
    }

    func test_overallDoneWithRetrospectivePhase_doesNotMatch() {
        let done = """
        All phases complete. Workflow complete.

        Retrospective: Next: Phase 3 was the review we already finished.
        """
        XCTAssertNil(
            IncompleteTurnContinuation.classify(done),
            "overall-done language must suppress phase handoff detection"
        )
    }

    func test_userCheckpoint_doesNotMatch() {
        let userWait = """
        Phase 2 refine is done.

        Next: Phase 3 — Review when you're ready; I will wait for your go-ahead.
        """
        XCTAssertNil(
            IncompleteTurnContinuation.classify(userWait),
            "user-gated phase handoff must not auto-nudge"
        )
    }

    func test_phaseResultAlone_withoutNextTransition_isNotHandoff() {
        let onlyResult = """
        **PHASE 2 RESULT: HIGH_CONFIDENCE**

        All material loopholes closed. Strategy is executable.
        """
        XCTAssertFalse(
            IncompleteWorkflowContinuation.isIncompleteWorkflowHandoff(onlyResult),
            "bare PHASE N RESULT without Next/Proceeding must not fire"
        )
    }

    func test_autoContinueGates() {
        XCTAssertEqual(
            IncompleteTurnContinuation.shouldAutoContinue(
                status: .completed,
                finalMessage: phase2HandoffNoMarker,
                isAutonomous: true,
                priorAutoContinuations: 0
            ),
            .workflowHandoff
        )
        XCTAssertNil(
            IncompleteTurnContinuation.shouldAutoContinue(
                status: .completed,
                finalMessage: phase2HandoffNoMarker,
                isAutonomous: false,
                priorAutoContinuations: 0
            ),
            "supervised must never auto-continue"
        )
        XCTAssertEqual(
            IncompleteTurnContinuation.shouldAutoContinue(
                status: .completed,
                finalMessage: phase2HandoffNoMarker,
                isAutonomous: true,
                priorAutoContinuations: IncompleteTurnContinuation.maxWorkflowAutoContinuations - 1
            ),
            .workflowHandoff,
            "workflow handoffs allow more auto-nudges than background stalls (sam-work phases)"
        )
        XCTAssertNil(
            IncompleteTurnContinuation.shouldAutoContinue(
                status: .completed,
                finalMessage: phase2HandoffNoMarker,
                isAutonomous: true,
                priorAutoContinuations: IncompleteTurnContinuation.maxWorkflowAutoContinuations
            )
        )
        XCTAssertNil(
            IncompleteTurnContinuation.shouldAutoContinue(
                status: .completed,
                finalMessage: "Standing by for the demo recording to complete.",
                isAutonomous: true,
                priorAutoContinuations: IncompleteTurnContinuation.maxBackgroundAutoContinuations
            ),
            "background bound stays at 5"
        )
        XCTAssertNil(
            IncompleteTurnContinuation.shouldAutoContinue(
                status: .failed,
                finalMessage: phase2HandoffNoMarker,
                isAutonomous: true,
                priorAutoContinuations: 0
            )
        )
    }

    func test_delayIsZeroForWorkflow_backgroundUsesConfigured() {
        XCTAssertEqual(
            IncompleteTurnContinuation.delay(for: .workflowHandoff, backgroundDelay: 45),
            0
        )
        XCTAssertEqual(
            IncompleteTurnContinuation.delay(for: .backgroundAwait, backgroundDelay: 45),
            45
        )
    }

    func test_systemPromptForbidsMarkerOnPhaseHandoffs() {
        let directive = BackgroundAwaitContinuation.systemPromptDirective
        XCTAssertTrue(directive.contains(BackgroundAwaitContinuation.awaitingMarker))
        XCTAssertTrue(
            directive.lowercased().contains("phase"),
            "directive must explicitly forbid marker use on multi-phase handoffs"
        )
    }
}
