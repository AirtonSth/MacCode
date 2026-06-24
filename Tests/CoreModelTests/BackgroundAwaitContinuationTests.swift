import XCTest
@testable import CoreModel

/// Encodes the contract for detecting an autonomous run that stalled while
/// awaiting a background job, and the bounded auto-continue decision.
///
/// WHY: a full-access run that spawns a background process (e.g. a Playwright
/// demo recording) and then ends its turn saying "Standing by for the demo
/// recording to complete." is marked `.completed` even though the task is not
/// done and nothing resumes the agent. The host must (a) recognise that stall and
/// (b) auto-nudge the agent to finish — but only for autonomous runs, only when
/// the agent really is waiting, and only a bounded number of times.
final class BackgroundAwaitContinuationTests: XCTestCase {

    // MARK: - Detector: real stall messages from the reported 114-min session.

    func test_detectsRealAwaitingBackgroundMessages() {
        // These are the verbatim trailing assistant messages from the session that
        // stalled. Each must be recognised as "waiting on a background job", or the
        // run will be silently marked completed while unfinished.
        let stalls = [
            "Standing by for the demo recording to complete.",
            "Awaiting the background completion notification.",
            "Demo recording in progress (rebuild + record). Awaiting completion notification.",
            "Build is underway (Vite rebuild). Awaiting the background completion notification.",
            "I'll await the demo recording (Vite rebuild → preview → record). Standing by for completion."
        ]
        for message in stalls {
            XCTAssertTrue(BackgroundAwaitContinuation.isAwaitingBackgroundWork(message),
                          "must detect a background-await stall: \(message)")
        }
    }

    // MARK: - Detector: the reported Claude-provider stall family.

    func test_detectsClaudeFutureTenseWaitOnAsyncJob() {
        // Verbatim (and close-variant) trailing messages from the reported Claude
        // full-access run that sat at "completed" instead of finishing: the agent
        // ended its turn saying it would *wait* (future tense, first person) on a
        // background job — a deploy poller that "notifies me" — before continuing.
        // The original detector only knew present-tense "waiting/standing by" + the
        // demo-recording vocabulary, so these slipped through and nothing auto-nudged
        // the agent to resume.
        let stalls = [
            "I'll wait for the deploy poller to complete (it notifies me), then run the summer-gate Chrome verification across multiple accounts.",
            "I'll wait for the deploy poller to complete (it notifies me), then run the Chrome verification for both flows.",
            "I'll wait for the background build to finish, then run the tests.",
            "I'm waiting for the deploy job to complete; it notifies me when it's done."
        ]
        for message in stalls {
            XCTAssertTrue(BackgroundAwaitContinuation.isAwaitingBackgroundWork(message),
                          "must detect a Claude future-tense background-await stall: \(message)")
        }
    }

    func test_doesNotAutoNudgeWhenWaitingOnTheUser() {
        // Precision guard: broadening to first-person "I'll wait" must NOT make the
        // detector fire when the agent is genuinely DONE and parked on the *human*
        // (a review, a confirmation, a copy decision). Auto-nudging these in
        // full-access mode would push the agent to act without the approval it is
        // waiting for — a worse failure than the stall this feature fixes. The
        // distinction is the absence of an agent-owned background-job noun:
        // "notify the team" (an action the agent will take) is not "it notifies me"
        // (a job signalling the agent), and a bare "...to complete the rollout" is
        // not a background job.
        let userWaits = [
            "I'll wait for you to confirm the copy before I notify the team.",
            "All set. I'll wait for your review before I run the migration to complete the rollout.",
            "Done. The PR is up; I'll wait for CI to go green and the merge to finish on your end."
        ]
        for message in userWaits {
            XCTAssertFalse(BackgroundAwaitContinuation.isAwaitingBackgroundWork(message),
                           "must NOT treat a wait-on-the-user as a background-await stall: \(message)")
        }
    }

    func test_doesNotTreatNormalFinalAnswersAsBackgroundAwait() {
        // None of these should trip the detector: a real completed answer must not
        // be auto-nudged. This is the intent that matters — the detector must key
        // on "awaiting a background job", not merely mention the word "background"
        // or end with "standing by".
        let nonStalls = [
            "All checks passed and the build is green.",
            "I ran the tests in the background earlier; everything passes.",
            "Done. The deploy is complete and verified.",
            "Standing by for your next instruction.",            // waiting on the USER, not a job
            "The recording studio booking is confirmed for Tuesday.", // 'recording' but no awaiting
            "",
            "   "
        ]
        for message in nonStalls {
            XCTAssertFalse(BackgroundAwaitContinuation.isAwaitingBackgroundWork(message),
                           "must NOT treat a normal answer as a background-await stall: \(message)")
        }
        XCTAssertFalse(BackgroundAwaitContinuation.isAwaitingBackgroundWork(nil),
                       "nil final message must not be a stall")
    }

    // MARK: - Detector: the deterministic self-declared marker (phrase-independent).

    func test_marker_detectsStallRegardlessOfPhrasing() {
        // The whole point of the marker: it makes detection work for ANY phrasing,
        // including ones no phrase list covers. This message uses vocabulary the
        // heuristic lists deliberately do not match — only the marker makes it fire.
        let novel = "Holding here until the canary bake finishes and the gate flips."
        XCTAssertFalse(BackgroundAwaitContinuation.isAwaitingBackgroundWork(novel),
                       "control: without the marker, novel phrasing is (correctly) beyond the heuristic backstop")
        XCTAssertTrue(BackgroundAwaitContinuation.isAwaitingBackgroundWork("\(BackgroundAwaitContinuation.awaitingMarker)\n\(novel)"),
                      "with the self-declared marker, the same novel phrasing must be detected deterministically")
        // Case-insensitive, and detected even when not at the very start.
        XCTAssertTrue(BackgroundAwaitContinuation.isAwaitingBackgroundWork("Done with step 1.\n\(BackgroundAwaitContinuation.awaitingMarker.lowercased()) waiting on the worker."),
                      "marker detection must be case-insensitive and position-independent")
    }

    func test_strippingAwaitingMarker_removesMarkerButKeepsTheText() {
        let raw = "\(BackgroundAwaitContinuation.awaitingMarker)\nI'll wait for the deploy poller to complete."
        let shown = BackgroundAwaitContinuation.strippingAwaitingMarker(raw)
        XCTAssertFalse(shown.contains(BackgroundAwaitContinuation.awaitingMarker),
                       "the internal marker must never survive into user-facing text")
        XCTAssertEqual(shown, "I'll wait for the deploy poller to complete.",
                       "stripping the marker must preserve the real message and tidy the leading blank line")
        // A message with no marker is returned unchanged.
        XCTAssertEqual(BackgroundAwaitContinuation.strippingAwaitingMarker("All done; build is green."),
                       "All done; build is green.")
    }

    func test_strippingAwaitingMarker_noOpPreservesNonMarkerProseVerbatim() {
        // Intent of the no-op guard: `strippingAwaitingMarker` runs on EVERY rendered
        // assistant message, so a message without the marker must pass through
        // byte-for-byte — it must NOT reflow trailing whitespace or collapse the blank
        // lines that markdown rendering depends on. Without the guard, normal prose
        // would be silently rewritten.
        let prose = "Line one.   \n\n\nLine two with trailing space.   "
        XCTAssertEqual(BackgroundAwaitContinuation.strippingAwaitingMarker(prose), prose,
                       "non-marker prose must pass through unchanged (no whitespace/newline reflow)")
    }

    func test_systemPromptDirective_namesTheExactMarker() {
        // Injection and detection must stay in lockstep: the rule we inject must ask
        // for the exact token the detector keys on, or recovery silently breaks.
        XCTAssertTrue(BackgroundAwaitContinuation.systemPromptDirective.contains(BackgroundAwaitContinuation.awaitingMarker),
                      "the injected directive must reference the exact marker the detector matches")
    }

    // MARK: - Decision: bounded, autonomous-only, completed-only.

    func test_autoContinuesOnlyForCompletedAutonomousStallUnderBound() {
        let stall = "Standing by for the demo recording to complete."

        XCTAssertTrue(BackgroundAwaitContinuation.shouldAutoContinue(
            status: .completed, finalMessage: stall, isAutonomous: true, priorAutoContinuations: 0),
            "a completed full-access stall under the bound must auto-continue")

        XCTAssertFalse(BackgroundAwaitContinuation.shouldAutoContinue(
            status: .completed, finalMessage: stall, isAutonomous: false, priorAutoContinuations: 0),
            "a supervised run must never auto-continue — the user drives it manually")

        XCTAssertFalse(BackgroundAwaitContinuation.shouldAutoContinue(
            status: .completed, finalMessage: "All done. Build is green.", isAutonomous: true, priorAutoContinuations: 0),
            "a genuinely-finished answer must not auto-continue")

        XCTAssertFalse(BackgroundAwaitContinuation.shouldAutoContinue(
            status: .failed, finalMessage: stall, isAutonomous: true, priorAutoContinuations: 0),
            "a failed/cancelled run must not auto-continue")
    }

    func test_autoContinueStopsAtTheBound() {
        let stall = "Awaiting the background completion notification."
        let max = BackgroundAwaitContinuation.maxAutoContinuations

        XCTAssertTrue(BackgroundAwaitContinuation.shouldAutoContinue(
            status: .completed, finalMessage: stall, isAutonomous: true, priorAutoContinuations: max - 1),
            "the last allowed attempt (prior == max - 1) must still fire")

        XCTAssertFalse(BackgroundAwaitContinuation.shouldAutoContinue(
            status: .completed, finalMessage: stall, isAutonomous: true, priorAutoContinuations: max),
            "once the bound is reached the host must stop auto-nudging and leave it flagged")
    }
}
