import XCTest
@testable import AppShell

/// Tests for InsomniaPollDecider.pollDecision — the pure decision helper that
/// drives the async root-domain sleep-disabled verification loop.
///
/// WHY: the helper replaces a Thread.sleep spin-poll on the main actor.
/// Correctness requires:
///   - unsatisfied + within timeout  => keepPolling (loop continues)
///   - satisfied at any time         => done        (loop exits immediately)
///   - unsatisfied + past timeout    => timedOut    (loop exits with failure)
/// A regression in any branch would re-introduce either a stall or a missed
/// verification, so each branch is asserted independently.
final class InsomniaPollDeciderTests: XCTestCase {

    // MARK: keepPolling

    func test_keepPolling_whenUnsatisfied_andElapsedBelowTimeout() {
        // elapsed=0.5, timeout=2, satisfied=false => still within window, not done
        let result = InsomniaPollDecider.pollDecision(elapsed: 0.5, timeout: 2, satisfied: false)
        XCTAssertEqual(result, .keepPolling,
                       "poll must continue while unsatisfied and time remains — exiting early would report a false negative")
    }

    func test_keepPolling_whenUnsatisfied_atJustUnderTimeout() {
        // elapsed exactly below the boundary should still keep polling
        let result = InsomniaPollDecider.pollDecision(elapsed: 1.999, timeout: 2, satisfied: false)
        XCTAssertEqual(result, .keepPolling,
                       "poll must not time out before elapsed reaches the timeout boundary")
    }

    // MARK: done

    func test_done_whenSatisfied_wellBeforeTimeout() {
        // satisfied early — no need to wait out the remaining time
        let result = InsomniaPollDecider.pollDecision(elapsed: 0.1, timeout: 2, satisfied: true)
        XCTAssertEqual(result, .done,
                       "a satisfied condition must short-circuit the poll immediately — spinning further wastes time")
    }

    func test_done_whenSatisfied_exactlyAtTimeout() {
        // satisfied takes priority even when elapsed == timeout
        let result = InsomniaPollDecider.pollDecision(elapsed: 2.0, timeout: 2, satisfied: true)
        XCTAssertEqual(result, .done,
                       "satisfied must win over timedOut when both conditions hold — the verification succeeded")
    }

    func test_done_whenSatisfied_pastTimeout() {
        // satisfied past deadline still succeeds (system caught up late but correctly)
        let result = InsomniaPollDecider.pollDecision(elapsed: 5, timeout: 2, satisfied: true)
        XCTAssertEqual(result, .done,
                       "a late-arriving satisfied result must still be treated as done, not as a timeout")
    }

    // MARK: timedOut

    func test_timedOut_whenUnsatisfied_exactlyAtTimeout() {
        // elapsed == timeout, not satisfied => declare failure
        let result = InsomniaPollDecider.pollDecision(elapsed: 2.0, timeout: 2, satisfied: false)
        XCTAssertEqual(result, .timedOut,
                       "when elapsed reaches the timeout and the condition is still false the loop must exit with timedOut so the caller can log and give up")
    }

    func test_timedOut_whenUnsatisfied_pastTimeout() {
        // elapsed well past timeout — must not keep polling indefinitely
        let result = InsomniaPollDecider.pollDecision(elapsed: 10, timeout: 2, satisfied: false)
        XCTAssertEqual(result, .timedOut,
                       "elapsed far past the deadline must still produce timedOut — the loop must not spin forever on a missed notification")
    }
}
