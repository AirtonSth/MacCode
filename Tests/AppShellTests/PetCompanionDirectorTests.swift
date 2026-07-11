import XCTest
@testable import AppShell

final class PetCompanionDirectorTests: XCTestCase {
    func test_ambientCueRequiresTrulyIdleVisibleAnimationAndAvoidsImmediateRepeat() {
        var director = PetCompanionDirector()
        let eligible = PetCompanionEligibility(
            baseState: .idle,
            attentionCount: 0,
            activeRunCount: 0,
            isVisible: true,
            animationsEnabled: true,
            reducedMotion: false,
            screenLocked: false
        )

        let first = director.nextAmbientCue(eligibility: eligible, preferredIndex: 0)
        let second = director.nextAmbientCue(eligibility: eligible, preferredIndex: 0)

        XCTAssertEqual(first?.returnState, .idle)
        XCTAssertNotEqual(first?.state, second?.state,
            "a companion should not repeat the same ambient behavior back-to-back")
        XCTAssertNil(director.nextAmbientCue(
            eligibility: PetCompanionEligibility(
                baseState: .waiting,
                attentionCount: 1,
                activeRunCount: 0,
                isVisible: true,
                animationsEnabled: true,
                reducedMotion: false,
                screenLocked: false
            ),
            preferredIndex: 1
        ))
    }

    func test_workCueRequiresActiveWorkAndCyclesMouseBugEngineerWithoutRepeat() {
        var director = PetCompanionDirector()
        let eligible = PetCompanionEligibility(
            baseState: .coding,
            attentionCount: 0,
            activeRunCount: 1,
            isVisible: true,
            animationsEnabled: true,
            reducedMotion: false,
            screenLocked: false
        )

        let first = director.nextWorkCue(eligibility: eligible, preferredIndex: 0)
        let second = director.nextWorkCue(eligibility: eligible, preferredIndex: 0)
        XCTAssertEqual(first?.state, .workingMouse)
        XCTAssertNotEqual(first?.state, second?.state)
        XCTAssertEqual(first?.returnState, .coding)
    }

    func test_notificationPounceOnlyOccursOnZeroToPositiveAndNeverOverridesBlockers() {
        var director = PetCompanionDirector()

        XCTAssertEqual(
            director.notificationCue(previousCount: 0, newCount: 3, baseState: .waiting),
            PetCompanionCue(state: .notificationPounce, returnState: .waiting)
        )
        XCTAssertNil(director.notificationCue(previousCount: 3, newCount: 4, baseState: .waiting))
        XCTAssertNil(director.notificationCue(previousCount: 0, newCount: 1, baseState: .approval))
        XCTAssertNil(director.notificationCue(previousCount: 0, newCount: 1, baseState: .question))
    }

    func test_everyThirdSuccessfulOutcomeUsesTreatCelebration() {
        var director = PetCompanionDirector()

        XCTAssertNil(director.successCue(returnState: .success))
        XCTAssertNil(director.successCue(returnState: .success))
        XCTAssertEqual(
            director.successCue(returnState: .success),
            PetCompanionCue(state: .celebrateTreat, returnState: .success)
        )
        XCTAssertNil(director.successCue(returnState: .success))
    }

    func test_careActionsMapToAuthoredReactionsAndReturnToExactBaseState() {
        let expected: [(PetCareAction, PetAnimationState)] = [
            (.feed, .eating),
            (.giveWater, .drinking),
            (.pet, .purring),
            (.play, .playing),
            (.cheerUp, .comfort),
        ]

        XCTAssertEqual(PetCareAction.allCases.map(\.title), [
            "Feed", "Give water", "Pet", "Play", "Cheer up"
        ])
        for (action, state) in expected {
            XCTAssertEqual(
                PetCompanionDirector.careCue(action: action, returnState: .reconnecting),
                PetCompanionCue(state: state, returnState: .reconnecting)
            )
        }
    }

    func test_directorDelayContractsStayInsideProductBounds() {
        XCTAssertEqual(PetCompanionDirector.ambientDelayRange, 35...75)
        XCTAssertEqual(PetCompanionDirector.workDelayRange, 25...50)
    }
}
