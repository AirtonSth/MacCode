import CoreModel
import XCTest
@testable import AppShell

final class PetCompanionReducerTests: XCTestCase {
    func test_workCueReturnsToCurrentWorkAndCannotOverrideLaterBlocker() {
        var reducer = PetEventReducer(coalescingWindowMilliseconds: 0)
        _ = reducer.reduce(.agentRunStarted(runID: "run-1"), atMilliseconds: 0)

        let reaction = reducer.reduce(
            .companionCue(PetCompanionCue(
                state: .workingMouse,
                returnState: .coding,
                durationMilliseconds: 12_000
            )),
            atMilliseconds: 1
        )
        XCTAssertEqual(reaction.state, .workingMouse)
        XCTAssertEqual(reaction.transientTimerDirective, .schedule(milliseconds: 12_000))

        XCTAssertEqual(
            reducer.reduce(.approvalOpened(requestID: "approval-1"), atMilliseconds: 2).state,
            .approval,
            "a companion reaction must never outrank a user blocker"
        )
        XCTAssertEqual(reducer.reduce(.transientExpired, atMilliseconds: 1_201).state, .approval)
        XCTAssertEqual(
            reducer.reduce(.approvalResolved(requestID: "approval-1"), atMilliseconds: 1_202).state,
            .coding,
            "expiry must derive the exact active work state instead of forcing idle"
        )
    }

    func test_careAndNotificationCuesReturnToTheirExactBaseStates() {
        var reducer = PetEventReducer(coalescingWindowMilliseconds: 0)

        let care = reducer.reduce(
            .companionCue(PetCompanionDirector.careCue(action: .pet, returnState: .idle)),
            atMilliseconds: 0
        )
        XCTAssertEqual(care.state, .purring)
        XCTAssertEqual(care.transientTimerDirective, .schedule(milliseconds: 9_000))
        XCTAssertEqual(reducer.reduce(.transientExpired, atMilliseconds: 1_200).state, .idle)

        XCTAssertEqual(
            reducer.reduce(
                .attentionHydrated(PetAttentionHydration(count: 2)),
                atMilliseconds: 1_201
            ).state,
            .waiting
        )
        XCTAssertEqual(
            reducer.reduce(
                .companionCue(PetCompanionCue(state: .notificationPounce, returnState: .waiting)),
                atMilliseconds: 1_202
            ).state,
            .notificationPounce
        )
        XCTAssertEqual(reducer.reduce(.transientExpired, atMilliseconds: 2_402).state, .waiting)
    }

    func test_staleOrNonCompanionCueIsRejectedWithoutStartingTimer() {
        var reducer = PetEventReducer(coalescingWindowMilliseconds: 0)
        _ = reducer.reduce(.agentRunStarted(runID: "run-1"), atMilliseconds: 0)
        _ = reducer.reduce(
            .agentItemStarted(itemID: "item-1", type: .commandExecution),
            atMilliseconds: 1
        )
        XCTAssertEqual(reducer.state, .terminal)

        let current = reducer.reduce(
            .companionCue(PetCompanionCue(state: .workingBug, returnState: .terminal)),
            atMilliseconds: 2
        )
        XCTAssertEqual(current.state, .workingBug,
            "work variants must outrank every eligible base-work animation")
        XCTAssertEqual(reducer.reduce(.transientExpired, atMilliseconds: 1_202).state, .terminal)

        // Work variants may rebind across coding↔terminal (scheduled 35–55s earlier).
        let rebound = reducer.reduce(
            .companionCue(PetCompanionCue(state: .workingBug, returnState: .coding)),
            atMilliseconds: 1_203
        )
        XCTAssertEqual(rebound.state, .workingBug,
                       "stale returnState must not drop work poses while still in a work base")
        XCTAssertEqual(reducer.reduce(.transientExpired, atMilliseconds: 2_403).state, .terminal)

        let invalid = reducer.reduce(
            .companionCue(PetCompanionCue(state: .approval, returnState: .terminal)),
            atMilliseconds: 2_404
        )
        XCTAssertEqual(invalid.state, .terminal)
        XCTAssertNil(invalid.transientTimerDirective)
    }

    func test_activeCompanionCueCancelsImmediatelyWhenUnderlyingWorkStateChanges() {
        var reducer = PetEventReducer(coalescingWindowMilliseconds: 0)
        _ = reducer.reduce(.agentRunStarted(runID: "run-1"), atMilliseconds: 0)
        XCTAssertEqual(
            reducer.reduce(
                .companionCue(PetCompanionCue(state: .workingMouse, returnState: .coding)),
                atMilliseconds: 1
            ).state,
            .workingMouse
        )

        let changed = reducer.reduce(
            .agentItemStarted(itemID: "terminal-1", type: .commandExecution),
            atMilliseconds: 2
        )

        XCTAssertEqual(changed.state, .terminal,
            "a real work-state change must interrupt a decorative cue immediately")
        XCTAssertEqual(changed.transientTimerDirective, .cancel)
    }

    func test_dragPoseOwnsRenderingThenRestoresTheLatestSemanticState() {
        var reducer = PetEventReducer(coalescingWindowMilliseconds: 0)
        _ = reducer.reduce(.agentRunStarted(runID: "run-1"), atMilliseconds: 0)
        XCTAssertEqual(reducer.state, .coding)

        _ = reducer.reduce(
            .companionCue(PetCompanionCue(
                state: .workingMouse,
                returnState: .coding,
                durationMilliseconds: 9_000
            )),
            atMilliseconds: 1
        )
        XCTAssertEqual(reducer.state, .workingMouse)

        let pickedUp = reducer.reduce(.petDragBegan, atMilliseconds: 2)
        XCTAssertEqual(pickedUp.state, .pickedUp)
        XCTAssertEqual(pickedUp.transientTimerDirective, .cancel,
            "direct manipulation must cancel decorative reactions before the drag pose starts")

        XCTAssertEqual(
            reducer.reduce(.approvalOpened(requestID: "approval-1"), atMilliseconds: 3).state,
            .pickedUp,
            "semantic updates received while dragging must stay hidden without being lost"
        )
        XCTAssertEqual(
            reducer.reduce(.petDragEnded, atMilliseconds: 4).state,
            .approval,
            "drop must reveal the latest reducer-owned state, not the stale pre-drag pose"
        )
    }

    func test_dragPreservesPersistentAndTimedOperationalFeedback() {
        var reducer = PetEventReducer(coalescingWindowMilliseconds: 0)

        XCTAssertEqual(reducer.reduce(.git(.started), atMilliseconds: 0).state, .gitReview)
        XCTAssertEqual(reducer.reduce(.petDragBegan, atMilliseconds: 1).state, .pickedUp)
        XCTAssertEqual(
            reducer.reduce(.projectScript(.started), atMilliseconds: 2).state,
            .pickedUp
        )
        XCTAssertEqual(reducer.reduce(.petDragEnded, atMilliseconds: 3).state, .terminal,
            "drop must reveal an operation that started while the cat was being dragged")

        XCTAssertEqual(reducer.reduce(.git(.succeeded), atMilliseconds: 4).state, .success)
        XCTAssertEqual(reducer.reduce(.petDragBegan, atMilliseconds: 5).state, .pickedUp)
        XCTAssertEqual(reducer.reduce(.petDragEnded, atMilliseconds: 6).state, .success,
            "drag must not erase timed success feedback that already owned the Pet")

        _ = reducer.reduce(.agentRunStarted(runID: "run-1"), atMilliseconds: 7)
        _ = reducer.reduce(.petDragBegan, atMilliseconds: 8)
        let failed = reducer.reduce(
            .agentRunFinished(runID: "run-1", status: .failed),
            atMilliseconds: 9
        )
        XCTAssertEqual(failed.state, .pickedUp)
        XCTAssertEqual(failed.transientTimerDirective, .schedule(milliseconds: 1_200))
        XCTAssertEqual(reducer.reduce(.petDragEnded, atMilliseconds: 10).state, .failed,
            "failure received during drag must be visible immediately after drop")
    }

    func test_screenLockCannotLeaveTheReducerStuckInPickedUpAfterWake() {
        var reducer = PetEventReducer(coalescingWindowMilliseconds: 0)
        XCTAssertEqual(reducer.reduce(.petDragBegan, atMilliseconds: 0).state, .pickedUp)

        XCTAssertEqual(
            reducer.reduce(.screenLockChanged(isLocked: true), atMilliseconds: 1).state,
            .sleeping
        )
        XCTAssertFalse(reducer.isBeingDragged)
        XCTAssertEqual(
            reducer.reduce(.screenLockChanged(isLocked: false), atMilliseconds: 2).state,
            .idle,
            "unlock must not resurrect a drag that ended without a mouse-up event"
        )
    }

    func test_companionCueCannotReplaceFailureOrInterruptionFeedback() {
        for terminalStatus in [AgentRunStatus.failed, .interrupted] {
            var reducer = PetEventReducer(coalescingWindowMilliseconds: 0)
            _ = reducer.reduce(.agentRunStarted(runID: "run-1"), atMilliseconds: 0)
            let terminal = reducer.reduce(
                .agentRunFinished(runID: "run-1", status: terminalStatus),
                atMilliseconds: 1
            )

            let rejected = reducer.reduce(
                .companionCue(PetCompanionDirector.careCue(
                    action: .play,
                    returnState: .idle,
                    durationMilliseconds: 9_000
                )),
                atMilliseconds: 2
            )

            XCTAssertEqual(rejected.state, terminal.state,
                "a decorative Care reaction must not erase terminal feedback")
            XCTAssertNil(rejected.transientTimerDirective)
        }
    }
}
