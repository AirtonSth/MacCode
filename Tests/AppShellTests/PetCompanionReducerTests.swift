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
                durationMilliseconds: 30_000
            )),
            atMilliseconds: 1
        )
        XCTAssertEqual(reaction.state, .workingMouse)
        XCTAssertEqual(reaction.transientTimerDirective, .schedule(milliseconds: 30_000))

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
        XCTAssertEqual(care.transientTimerDirective, .schedule(milliseconds: 35_000))
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

        let stale = reducer.reduce(
            .companionCue(PetCompanionCue(state: .workingBug, returnState: .coding)),
            atMilliseconds: 1_203
        )
        XCTAssertEqual(stale.state, .terminal)
        XCTAssertNil(stale.transientTimerDirective)

        let invalid = reducer.reduce(
            .companionCue(PetCompanionCue(state: .approval, returnState: .terminal)),
            atMilliseconds: 1_204
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
}
