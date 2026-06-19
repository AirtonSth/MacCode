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
