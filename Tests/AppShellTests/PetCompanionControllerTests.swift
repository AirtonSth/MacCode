import XCTest
@testable import AppShell
import AgentRuntime
import CoreModel
import Persistence
import SocketServer

@MainActor
final class PetCompanionControllerTests: XCTestCase {
    func test_careActionPlaysAuthoredReactionThenReturnsThroughReducer() async throws {
        let controller = try makeController(prefix: "Care")
        defer { controller.stop() }
        controller.start()

        controller.windowControllerForTests.onCareAction?(.pet)
        XCTAssertEqual(controller.modelForTests.animationState, .purring)
        XCTAssertEqual(controller.lastScheduledTransientMillisecondsForTests, 100,
            "short injected durations stay exact for deterministic controller tests")

        try await waitForState(.idle, controller: controller)
    }

    func test_controllerSchedulesTheLoopAlignedDurationInsteadOfTheRawRandomValue() throws {
        let controller = try makeController(
            prefix: "LoopAlignedDuration",
            extendedReactionDurationProvider: { 9_000 }
        )
        defer { controller.stop() }
        controller.start()

        controller.windowControllerForTests.onCareAction?(.feed)

        XCTAssertEqual(controller.modelForTests.animationState, .eating)
        XCTAssertEqual(controller.lastScheduledTransientMillisecondsForTests, 8_167,
            "production wiring must end eating on its neutral loop seam instead of mid-bite")
    }

    func test_careActionUsesStaticFrameAndExpiresUnderReduceMotionOrPause() async throws {
        for policy in [
            (animationsEnabled: true, reduceMotion: true),
            (animationsEnabled: false, reduceMotion: false),
        ] {
            let controller = try makeController(
                prefix: "StaticCare",
                animationsEnabled: policy.animationsEnabled,
                reduceMotion: policy.reduceMotion
            )
            controller.start()

            controller.windowControllerForTests.onCareAction?(.feed)

            XCTAssertEqual(controller.modelForTests.animationState, .eating)
            XCTAssertFalse(controller.animationTimerIsRunningForTests,
                "explicit care should render canonically without violating the selected motion policy")
            try await waitForState(.idle, controller: controller)
            controller.stop()
        }
    }

    func test_screenLockCancelsDragWithoutResurrectingPickedUpOnUnlock() throws {
        let controller = try makeController(prefix: "DragScreenLock")
        defer { controller.stop() }
        controller.start()

        controller.windowControllerForTests.beginDragForTests()
        XCTAssertEqual(controller.modelForTests.animationState, .pickedUp)
        XCTAssertEqual(controller.windowControllerForTests.dragLifecycleForTests?.active, true)

        controller.handleSystemScreenLockChanged(true)
        XCTAssertEqual(controller.modelForTests.animationState, .sleeping)
        XCTAssertEqual(controller.windowControllerForTests.dragLifecycleForTests?.active, false)
        XCTAssertEqual(controller.windowControllerForTests.dragLifecycleForTests?.monitoring, false)
        XCTAssertEqual(controller.windowControllerForTests.dragLifecycleForTests?.cursorPushed, false)

        controller.handleSystemScreenLockChanged(false)
        XCTAssertNotEqual(controller.modelForTests.animationState, .pickedUp)
    }

    func test_stopDuringActiveDragCannotRearmCancelledControllerTasks() throws {
        let controller = try makeController(prefix: "StopDuringDrag")
        controller.start()
        controller.windowControllerForTests.beginDragForTests()

        controller.stop()

        XCTAssertFalse(controller.hasScheduledTasksForTests,
            "stopping from pickedUp must not rearm idle or companion work")
    }

    func test_ambientReactionUsesInjectedDurationThenReturnsToIdle() async throws {
        var delayRequestCount = 0
        let controller = try makeController(
            prefix: "AmbientDuration",
            extendedReactionDurationProvider: { 120 },
            companionDelayProvider: { _ in
                delayRequestCount += 1
                return delayRequestCount == 1 ? 0 : 60
            }
        )
        defer { controller.stop() }
        controller.start()

        try await waitForState(in: [
            .idleBall, .idleScratch, .idleGroom, .idleStretch,
            .idleBox, .idleButterfly, .eating, .idleYawn,
        ], controller: controller)
        try await waitForState(.idle, controller: controller)
    }

    func test_eligibleRefreshDoesNotRestartTheCompanionCountdown() async throws {
        var requestedRanges: [ClosedRange<Int>] = []
        let controller = try makeController(
            prefix: "StableCountdown",
            companionDelayProvider: { range in
                requestedRanges.append(range)
                return 60
            }
        )
        defer { controller.stop() }
        controller.start()
        XCTAssertEqual(requestedRanges, [35...55])

        NotificationCenter.default.post(name: .petSettingsDidChange, object: nil)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(requestedRanges, [35...55],
            "an eligible refresh must not postpone the one-minute companion deadline")
    }

    func test_ineligibleRefreshCancelsCountdownAndRearmsAfterMotionReturns() async throws {
        var requestedRanges: [ClosedRange<Int>] = []
        var durationRequestCount = 0
        let (controller, context) = try makeControllerWithContext(
            prefix: "CountdownCancellation",
            extendedReactionDurationProvider: {
                durationRequestCount += 1
                return 120
            },
            companionDelayProvider: { range in
                requestedRanges.append(range)
                return requestedRanges.count == 1 ? 1 : range.upperBound
            }
        )
        defer { controller.stop() }
        controller.start()
        XCTAssertEqual(requestedRanges, [35...55])

        SettingsStore(db: context.db).update { $0.petAnimationsEnabled = false }
        NotificationCenter.default.post(name: .petSettingsDidChange, object: nil)
        try await Task.sleep(nanoseconds: 50_000_000)

        SettingsStore(db: context.db).update { $0.petAnimationsEnabled = true }
        NotificationCenter.default.post(name: .petSettingsDidChange, object: nil)
        try await Task.sleep(nanoseconds: 1_200_000_000)

        XCTAssertEqual(requestedRanges, [35...55, 35...55],
            "losing eligibility must cancel the old deadline so re-enabling motion can arm a fresh one")
        XCTAssertEqual(durationRequestCount, 0,
            "the cancelled deadline must not survive as a ghost reaction after motion is re-enabled")
    }

    func test_activeWorkUsesTheCompanionDelayAndDurationProviders() async throws {
        var requestedRanges: [ClosedRange<Int>] = []
        var durationRequestCount = 0
        let controller = try makeController(
            prefix: "WorkTiming",
            extendedReactionDurationProvider: {
                durationRequestCount += 1
                return 120
            },
            companionDelayProvider: { range in
                requestedRanges.append(range)
                return requestedRanges.count == 1 ? 1 : range.upperBound
            }
        )
        defer { controller.stop() }
        controller.start()

        let runUUID = UUID()
        let threadUUID = UUID()
        EventBus.shared.publish(kind: .agentRunStarted, payload: .object([
            "run_id": .string(runUUID.uuidString),
        ]))
        // Host projection is authoritative; mirror production start order.
        controller.applyActiveRunProjectionForTests(ActiveRunProjection(runs: [
            ActiveRunProjection.Run(
                threadId: AgentThreadID(threadUUID),
                runId: AgentRunID(runUUID)
            ),
        ]))
        try await waitForState(in: [
            .workingMouse, .workingBug, .workingEngineer,
        ], controller: controller)
        try await waitForState(.coding, controller: controller)

        XCTAssertEqual(requestedRanges.first, 35...55)
        XCTAssertEqual(durationRequestCount, 1,
            "work reactions must use the same randomized 6–12 second provider as ambient and Care")
    }

    func test_emptyHostProjectionClearsEventBusGhostCodingPose() async throws {
        let controller = try makeController(prefix: "GhostClear")
        defer { controller.stop() }
        controller.start()

        let runUUID = UUID()
        EventBus.shared.publish(kind: .agentRunStarted, payload: .object([
            "run_id": .string(runUUID.uuidString),
        ]))
        try await waitForState(.coding, controller: controller)

        // Missed finish on the bus; host Active section is empty.
        controller.applyActiveRunProjectionForTests(ActiveRunProjection(runs: []))
        try await waitForState(.idle, controller: controller)
        XCTAssertFalse(
            PetEventReducer.isWorkPose(controller.modelForTests.animationState),
            "empty host projection must clear ghost work pose"
        )
    }

    func test_newReadyItemPouncesOnceThenReturnsToWaitingBadgeState() async throws {
        let (controller, context) = try makeControllerWithContext(prefix: "Pounce")
        defer { controller.stop() }
        controller.start()

        try NotificationRepository(db: context.db).insert(AppNotification(
            id: "new-ready-item",
            title: "safe test notification",
            category: PetNotificationCategory.providerUpdateFailed.rawValue
        ))
        EventBus.shared.publish(kind: .notificationCreated, payload: .object([:]))

        try await waitForState(.notificationPounce, controller: controller)
        XCTAssertEqual(controller.modelForTests.count, 1)
        try await waitForState(.waiting, controller: controller)
    }

    func test_preexistingReadyItemPouncesAfterStartupRuntimeIsLoaded() async throws {
        let (controller, context) = try makeControllerWithContext(prefix: "StartupPounce")
        defer { controller.stop() }
        try NotificationRepository(db: context.db).insert(AppNotification(
            id: "startup-ready-item",
            title: "safe startup notification",
            category: PetNotificationCategory.providerUpdateFailed.rawValue
        ))

        controller.start()

        XCTAssertEqual(controller.modelForTests.count, 1)
        XCTAssertEqual(controller.modelForTests.animationState, .notificationPounce,
            "hydration must defer the 0-to-positive pounce until the atlas runtime exists")
        try await waitForState(.waiting, controller: controller)
    }

    func test_everyThirdUniqueSuccessUsesTreatAndDuplicateTerminalDoesNotCount() async throws {
        let controller = try makeController(prefix: "Treat")
        defer { controller.stop() }
        controller.start()

        let runIDs = (0..<3).map { _ in UUID().uuidString }
        publishCompletedRun(runIDs[0])
        publishCompletedRun(runIDs[0])
        publishCompletedRun(runIDs[1])
        try await waitForState(.success, controller: controller)
        XCTAssertNotEqual(controller.modelForTests.animationState, .celebrateTreat)

        publishCompletedRun(runIDs[2])
        try await waitForState(.celebrateTreat, controller: controller)
    }

    private func makeController(
        prefix: String,
        animationsEnabled: Bool = true,
        reduceMotion: Bool = false,
        extendedReactionDurationProvider: @escaping () -> Int64 = { 100 },
        companionDelayProvider: @escaping (ClosedRange<Int>) -> Int = { _ in 60 }
    ) throws -> PetController {
        try makeControllerWithContext(
            prefix: prefix,
            animationsEnabled: animationsEnabled,
            reduceMotion: reduceMotion,
            extendedReactionDurationProvider: extendedReactionDurationProvider,
            companionDelayProvider: companionDelayProvider
        ).controller
    }

    private func makeControllerWithContext(
        prefix: String,
        animationsEnabled: Bool = true,
        reduceMotion: Bool = false,
        extendedReactionDurationProvider: @escaping () -> Int64 = { 100 },
        companionDelayProvider: @escaping (ClosedRange<Int>) -> Int = { _ in 60 }
    ) throws -> (controller: PetController, context: AppContext) {
        let directory = NSTemporaryDirectory() + "RC2PetCompanion\(prefix)-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(
            petEnabled: true,
            petAnimationsEnabled: animationsEnabled,
            petReduceMotion: reduceMotion
        ))
        return (
            try PetController(
                context: context,
                router: router,
                openSettings: { _ in false },
                extendedReactionDurationProvider: extendedReactionDurationProvider,
                companionDelayProvider: companionDelayProvider
            ),
            context
        )
    }

    private func publishCompletedRun(_ runID: String) {
        EventBus.shared.publish(kind: .agentRunStarted, payload: .object([
            "run_id": .string(runID),
        ]))
        EventBus.shared.publish(kind: .agentRunFinished, payload: .object([
            "run_id": .string(runID),
            "status": .string("completed"),
        ]))
    }

    private func waitForState(
        _ expected: PetAnimationState,
        controller: PetController
    ) async throws {
        for _ in 0..<120 {
            if controller.modelForTests.animationState == expected { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail(
            "expected \(expected.rawValue), got \(controller.modelForTests.animationState.rawValue)"
        )
    }

    private func waitForState(
        in expected: Set<PetAnimationState>,
        controller: PetController
    ) async throws {
        for _ in 0..<120 {
            if expected.contains(controller.modelForTests.animationState) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail(
            "expected one of \(expected.map(\.rawValue).sorted()), got "
                + controller.modelForTests.animationState.rawValue
        )
    }
}
