import XCTest
@testable import AppShell
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

        try await waitForState(.idle, controller: controller)
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

    func test_newReadyItemPouncesOnceThenReturnsToWaitingBadgeState() async throws {
        let (controller, context) = try makeControllerWithContext(prefix: "Pounce")
        defer { controller.stop() }
        controller.start()

        try NotificationRepository(db: context.db).insert(AppNotification(
            id: "new-ready-item",
            title: "safe test notification",
            category: PetNotificationCategory.providerUpdateFailed.rawValue
        ))
        EventBus.shared.publish(kind: "notification.created", payload: .object([:]))

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
        reduceMotion: Bool = false
    ) throws -> PetController {
        try makeControllerWithContext(
            prefix: prefix,
            animationsEnabled: animationsEnabled,
            reduceMotion: reduceMotion
        ).controller
    }

    private func makeControllerWithContext(
        prefix: String,
        animationsEnabled: Bool = true,
        reduceMotion: Bool = false
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
                extendedReactionDurationProvider: { 100 }
            ),
            context
        )
    }

    private func publishCompletedRun(_ runID: String) {
        EventBus.shared.publish(kind: "agent.run.started", payload: .object([
            "run_id": .string(runID),
        ]))
        EventBus.shared.publish(kind: "agent.run.finished", payload: .object([
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
}
