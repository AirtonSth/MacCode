import XCTest
@testable import AppShell
@testable import CoreModel

/// Tests for the pure outcomeNotificationParts helper and threadOutcome factory.
///
/// WHY: Cancelled runs had identical notification copy to failed runs, so users
/// could not distinguish a manual stop from a crash. threadIdentifier was unset,
/// causing notification bursts to scatter across Notification Center instead of
/// stacking per-thread.
final class RunOutcomeNotificationCopyTests: XCTestCase {

    // MARK: - outcomeNotificationParts (pure helper)

    func testCancelledOutcomeHasDistinctTitle() {
        let parts = RemoteCodeNotificationContent.outcomeNotificationParts(
            threadId: "t1",
            displayTitle: "Build fix",
            phase: .cancelled
        )
        XCTAssertEqual(parts?.title, "Thread cancelled",
                       "cancelled runs must use distinct title so users know they stopped the run, not that it crashed")
    }

    func testCancelledOutcomeHasDistinctBody() {
        let parts = RemoteCodeNotificationContent.outcomeNotificationParts(
            threadId: "t1",
            displayTitle: "Build fix",
            phase: .cancelled
        )
        XCTAssertEqual(parts?.body, "Build fix was stopped before finishing.",
                       "cancelled body must explain the run was stopped, not that an error occurred")
    }

    func testCancelledOutcomeBodyInterpolatesDisplayTitle() {
        let parts = RemoteCodeNotificationContent.outcomeNotificationParts(
            threadId: "t2",
            displayTitle: "My Task",
            phase: .cancelled
        )
        XCTAssertTrue(parts?.body.contains("My Task") == true,
                      "cancelled body must contain the thread display title")
    }

    func testFailedOutcomeBodyDescribesError() {
        let parts = RemoteCodeNotificationContent.outcomeNotificationParts(
            threadId: "t1",
            displayTitle: "Build fix",
            phase: .failed
        )
        XCTAssertEqual(parts?.body, "Build fix ended with an error.",
                       "failed body must describe an error, distinct from a manual stop")
    }

    func testFinishedOutcomeBodyDescribesReady() {
        let parts = RemoteCodeNotificationContent.outcomeNotificationParts(
            threadId: "t1",
            displayTitle: "Build fix",
            phase: .completed
        )
        XCTAssertEqual(parts?.body, "Build fix response is ready.",
                       "completed body must say response is ready, not an error or stop message")
    }

    func testAllThreeTerminalOutcomesHaveDistinctCopy() {
        let finished = RemoteCodeNotificationContent.outcomeNotificationParts(
            threadId: "t", displayTitle: "T", phase: .completed)
        let failed = RemoteCodeNotificationContent.outcomeNotificationParts(
            threadId: "t", displayTitle: "T", phase: .failed)
        let cancelled = RemoteCodeNotificationContent.outcomeNotificationParts(
            threadId: "t", displayTitle: "T", phase: .cancelled)

        XCTAssertNotNil(finished)
        XCTAssertNotNil(failed)
        XCTAssertNotNil(cancelled)

        let titles = Set([finished!.title, failed!.title, cancelled!.title])
        XCTAssertEqual(titles.count, 3,
                       "finished/failed/cancelled must have three distinct titles so users can read the outcome without opening the app")

        let bodies = Set([finished!.body, failed!.body, cancelled!.body])
        XCTAssertEqual(bodies.count, 3,
                       "finished/failed/cancelled must have three distinct body strings")
    }

    func testPendingAndRunningProduceNil() {
        XCTAssertNil(RemoteCodeNotificationContent.outcomeNotificationParts(
            threadId: "t", displayTitle: "T", phase: .pending),
                     "pending is not a terminal outcome; no notification should fire")
        XCTAssertNil(RemoteCodeNotificationContent.outcomeNotificationParts(
            threadId: "t", displayTitle: "T", phase: .running),
                     "running is not a terminal outcome; no notification should fire")
    }

    // MARK: - threadIdentifier grouping

    func testCancelledOutcomeThreadIdentifierEqualsThreadId() {
        let parts = RemoteCodeNotificationContent.outcomeNotificationParts(
            threadId: "thread-99",
            displayTitle: "T",
            phase: .cancelled
        )
        XCTAssertEqual(parts?.threadIdentifier, "thread-99",
                       "threadIdentifier must equal the threadId so Notification Center stacks all outcome notifications for the same thread")
    }

    func testFinishedOutcomeThreadIdentifierEqualsThreadId() {
        let parts = RemoteCodeNotificationContent.outcomeNotificationParts(
            threadId: "thread-42",
            displayTitle: "T",
            phase: .completed
        )
        XCTAssertEqual(parts?.threadIdentifier, "thread-42",
                       "threadIdentifier must equal the threadId for finished runs")
    }

    func testFailedOutcomeThreadIdentifierEqualsThreadId() {
        let parts = RemoteCodeNotificationContent.outcomeNotificationParts(
            threadId: "thread-7",
            displayTitle: "T",
            phase: .failed
        )
        XCTAssertEqual(parts?.threadIdentifier, "thread-7",
                       "threadIdentifier must equal the threadId for failed runs")
    }

    // MARK: - threadOutcome factory integration

    func testThreadOutcomeCancelledContent() {
        let content = RemoteCodeNotificationContent.threadOutcome(
            threadId: "t1",
            title: "Refactor",
            phase: .cancelled
        )
        XCTAssertEqual(content?.title, "Thread cancelled")
        XCTAssertEqual(content?.body, "Refactor was stopped before finishing.")
        XCTAssertEqual(content?.identifier, "thread.t1.cancelled",
                       "identifier must include 'cancelled' suffix so the notification replaces correctly in Notification Center")
        XCTAssertEqual(content?.threadIdentifier, "t1",
                       "threadIdentifier must be set so all outcome notifications for t1 stack in one group")
        XCTAssertEqual(content?.userInfo["outcome"], "cancelled")
        XCTAssertEqual(content?.userInfo["threadId"], "t1")
    }

    func testThreadOutcomeFailedContentUnchanged() {
        // Existing contract: failed copy must remain distinct from cancelled.
        let content = RemoteCodeNotificationContent.threadOutcome(
            threadId: "t2",
            title: "Build",
            phase: .failed
        )
        XCTAssertEqual(content?.title, "Thread failed")
        XCTAssertEqual(content?.identifier, "thread.t2.failed")
        XCTAssertEqual(content?.threadIdentifier, "t2")
        XCTAssertEqual(content?.userInfo["outcome"], "failed")
    }

    func testThreadOutcomeCompletedContentUnchanged() {
        // Regression: completed copy must not be changed by this task.
        let content = RemoteCodeNotificationContent.threadOutcome(
            threadId: "t3",
            title: "Build fix",
            phase: .completed
        )
        XCTAssertEqual(content?.title, "Thread finished")
        XCTAssertEqual(content?.body, "Build fix response is ready.")
        XCTAssertEqual(content?.identifier, "thread.t3.completed")
        XCTAssertEqual(content?.threadIdentifier, "t3")
    }

    func testThreadOutcomeFallbackTitleWhenNil() {
        let content = RemoteCodeNotificationContent.threadOutcome(
            threadId: "t4",
            title: nil,
            phase: .cancelled
        )
        XCTAssertEqual(content?.body, "Thread was stopped before finishing.",
                       "nil thread title must fall back to 'Thread' in the body")
    }

    func testThreadOutcomeFallbackTitleWhenBlank() {
        let content = RemoteCodeNotificationContent.threadOutcome(
            threadId: "t5",
            title: "   ",
            phase: .cancelled
        )
        XCTAssertEqual(content?.body, "Thread was stopped before finishing.",
                       "blank thread title must fall back to 'Thread' in the body")
    }

    func testInterruptedMapsToFailedCopy() {
        // interrupted = provider crash/OOM; semantically an error, not a user stop.
        let content = RemoteCodeNotificationContent.threadOutcome(
            threadId: "t6",
            title: "T",
            phase: .interrupted
        )
        XCTAssertEqual(content?.title, "Thread failed",
                       "interrupted (provider crash) maps to failed copy, not cancelled, because the user did not stop it")
        XCTAssertEqual(content?.userInfo["outcome"], "failed")
    }

    // MARK: - Main-agent / subagent push policy

    func testNestedWorkerReceiptIsDetected() {
        // WHY: subagents must never produce Agent App push banners.
        XCTAssertTrue(
            RemoteCodeNotificationContent.AgentAppPushPolicy.isNestedWorker(
                parentReceiptId: UUID(),
                nodeId: "root"
            )
        )
        XCTAssertTrue(
            RemoteCodeNotificationContent.AgentAppPushPolicy.isNestedWorker(
                parentReceiptId: nil,
                nodeId: "worker-1"
            )
        )
        XCTAssertFalse(
            RemoteCodeNotificationContent.AgentAppPushPolicy.isNestedWorker(
                parentReceiptId: nil,
                nodeId: "root"
            )
        )
        XCTAssertFalse(
            RemoteCodeNotificationContent.AgentAppPushPolicy.isNestedWorker(
                parentReceiptId: nil,
                nodeId: nil
            )
        )
    }

    func testThreadOutcomeSuppressedForNestedWorkers() {
        XCTAssertNil(
            RemoteCodeNotificationContent.threadOutcome(
                threadId: "child",
                title: "subagent work",
                phase: .completed,
                isNestedWorker: true
            ),
            "nested/subagent finish must not create a push notification"
        )
        XCTAssertNotNil(
            RemoteCodeNotificationContent.threadOutcome(
                threadId: "main",
                title: "parent work",
                phase: .completed,
                isNestedWorker: false
            ),
            "main agent finish must still notify"
        )
    }

    func testUserActionPushMainOnly() {
        XCTAssertNil(
            RemoteCodeNotificationContent.userActionNeeded(
                threadId: "child",
                threadTitle: "worker",
                actionTitle: "Approve: Run command",
                requestId: "r1",
                isNestedWorker: true
            ),
            "subagent approval must not push"
        )
        let content = RemoteCodeNotificationContent.userActionNeeded(
            threadId: "main",
            workspaceId: "ws-1",
            threadTitle: "ship labels",
            actionTitle: "Approve: Run command",
            requestId: "r2",
            isNestedWorker: false
        )
        XCTAssertEqual(content?.title, "Approve: Run command")
        XCTAssertEqual(content?.userInfo["threadId"], "main")
        XCTAssertEqual(content?.userInfo["workspaceId"], "ws-1")
        XCTAssertEqual(content?.userInfo["outcome"], "attention")
        XCTAssertTrue(content?.body.contains("ship labels") == true)
    }

    func testRunningPhaseNeverNotifiesEvenForMainAgent() {
        XCTAssertFalse(
            RemoteCodeNotificationContent.AgentAppPushPolicy.shouldNotifyThreadOutcome(
                phase: .running,
                isNestedWorker: false
            )
        )
        XCTAssertNil(
            RemoteCodeNotificationContent.threadOutcome(
                threadId: "t",
                title: "live",
                phase: .running,
                isNestedWorker: false
            )
        )
    }

    // MARK: - Finish banner vs Live Activity redundancy

    func testRemoteFinishAlertSuppressedWhenLiveActivityChannelArmed() {
        // WHY: Lock Screen already shows terminal LA state — a second
        // "Thread finished" banner is noise. Attention is a different path.
        // Cancelled still banners: LA soft-maps stop toward "ready".
        XCTAssertFalse(
            RemoteCodeNotificationContent.AgentAppPushPolicy.shouldDeliverRemoteFinishAlert(
                phase: .completed,
                liveActivityUpdateChannelArmed: true
            )
        )
        XCTAssertFalse(
            RemoteCodeNotificationContent.AgentAppPushPolicy.shouldDeliverRemoteFinishAlert(
                phase: .failed,
                liveActivityUpdateChannelArmed: true
            )
        )
        XCTAssertTrue(
            RemoteCodeNotificationContent.AgentAppPushPolicy.shouldDeliverRemoteFinishAlert(
                phase: .cancelled,
                liveActivityUpdateChannelArmed: true
            ),
            "cancelled must still remote-banner even when LA is armed"
        )
        XCTAssertTrue(
            RemoteCodeNotificationContent.AgentAppPushPolicy.shouldDeliverRemoteFinishAlert(
                phase: .completed,
                liveActivityUpdateChannelArmed: false
            )
        )
        // Attention policy is independent of LA arming.
        XCTAssertTrue(
            RemoteCodeNotificationContent.AgentAppPushPolicy.shouldNotifyUserAction(
                isNestedWorker: false
            )
        )
    }

    func testLiveActivityChannelArmedOnlyFromActivityUpdateToken() {
        // WHY: legacy push-to-start / liveActivityToken latches for the life of
        // the install and must NOT arm finish-banner suppression alone.
        XCTAssertFalse(
            RemoteCodeNotificationContent.AgentAppPushPolicy.isLiveActivityUpdateChannelArmed(
                activityUpdateTokens: []
            )
        )
        XCTAssertFalse(
            RemoteCodeNotificationContent.AgentAppPushPolicy.isLiveActivityUpdateChannelArmed(
                activityUpdateTokens: ["", "  "]
            )
        )
        XCTAssertTrue(
            RemoteCodeNotificationContent.AgentAppPushPolicy.isLiveActivityUpdateChannelArmed(
                activityUpdateTokens: ["activity-update-token"]
            )
        )
    }
}
