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

    func test_syntheticPromptsAreRecognizedAndUserTextIsNot() {
        // WHY: host nudges are machine input; a user typing the same words is not a nudge.
        XCTAssertTrue(IncompleteTurnContinuation.isSyntheticPrompt(BackgroundAwaitContinuation.continuationPrompt))
        for reason in [IncompleteTurnContinuationReason.workflowHandoff, .uncalledToolInvocation, .backgroundAwait] {
            XCTAssertTrue(IncompleteTurnContinuation.isSyntheticPrompt("  \(IncompleteTurnContinuation.prompt(for: reason))\n"))
        }
        XCTAssertFalse(IncompleteTurnContinuation.isSyntheticPrompt("Check the deploy."))
        XCTAssertFalse(IncompleteTurnContinuation.isSyntheticPrompt(""))
    }

    func test_trueBackgroundAwait_stillClassifiesAsBackground() {
        let stall = "Standing by for the demo recording to complete."
        XCTAssertEqual(IncompleteTurnContinuation.classify(stall), .backgroundAwait)
        XCTAssertEqual(
            IncompleteTurnContinuation.prompt(for: .backgroundAwait),
            BackgroundAwaitContinuation.continuationPrompt
        )
    }

    func test_uncalledToolMarkup_classifiesAsUncalledToolInvocation() {
        // Exact mangled incident payload (fact 2): turn ended by printing a tool
        // invocation as text. After sanitize, the durable marker remains so
        // classify still raises the incomplete-turn reason (not silent completed).
        let mangled = """
        <ScheduleWakeup>
        <parameter name="delaySeconds">10</parameter>
        <parameter name="reason">Waiting for sam-plan skill to complete execution</parameter>
        <parameter name="prompt">/sam-task https://linear.app/empathmsp/issue/DEV-3983</parameter>
        </invoke>
        """
        XCTAssertEqual(
            IncompleteTurnContinuation.classify(mangled),
            .uncalledToolInvocation,
            "raw mangled tool markup must classify as incomplete (pre-sanitize path)"
        )
        let sanitized = AssistantToolMarkupSanitizer.sanitize(mangled)
        XCTAssertEqual(
            IncompleteTurnContinuation.classify(sanitized),
            .uncalledToolInvocation,
            "post-sanitize durable marker must still raise uncalledToolInvocation"
        )
        XCTAssertTrue(IncompleteTurnContinuation.isIncompleteTurn(sanitized))
        XCTAssertEqual(
            IncompleteTurnContinuation.prompt(for: .uncalledToolInvocation),
            IncompleteTurnContinuation.uncalledToolContinuationPrompt
        )
        XCTAssertNotEqual(
            IncompleteTurnContinuation.prompt(for: .uncalledToolInvocation),
            BackgroundAwaitContinuation.continuationPrompt,
            "uncalled-tool recovery must not send the BashOutput/background prompt"
        )
        XCTAssertEqual(
            IncompleteTurnContinuation.delay(for: .uncalledToolInvocation, backgroundDelay: 45),
            0,
            "no external job to wait on — resume immediately after terminal cleanup"
        )
        XCTAssertEqual(
            IncompleteTurnContinuation.shouldAutoContinue(
                status: .completed,
                finalMessage: sanitized,
                isAutonomous: true,
                priorAutoContinuations: 0
            ),
            .uncalledToolInvocation
        )
    }

    func test_uncalledTool_doesNotWinOverWorkflowHandoff() {
        // Load-bearing order: a phase handoff that also carries the uncalled-tool
        // marker must still get the workflow prompt (same spirit as misused
        // [[RC_AWAITING]] on Phase 1).
        let hybrid = """
        **Next: Phase 3 — Review**

        \(AssistantToolMarkupSanitizer.uncalledToolMarker)
        """
        XCTAssertEqual(
            IncompleteTurnContinuation.classify(hybrid),
            .workflowHandoff,
            "workflow handoff must outrank uncalled-tool signal"
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
