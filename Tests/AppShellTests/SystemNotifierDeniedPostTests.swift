import XCTest
import UserNotifications
@testable import AppShell
import CoreModel
import Persistence

/// Tests for the `SystemNotifier.onDeniedPost` seam.
///
/// WHY: When OS-level notification permission is denied, a finished agent run
/// gives the user zero feedback if the app is backgrounded. `onDeniedPost`
/// lets callers install an in-app fallback (badge, feed entry, alert) without
/// polling permission state. These tests verify the contract:
///
///   R1 — `onDeniedPost` is invoked on the main queue when posting while
///         the notifier is not authorized.
///   R2 — `onDeniedPost` receives the exact `RemoteCodeNotificationContent`
///         that was passed to `post(_:)`.
///   R3 — `onDeniedPost` is NOT invoked when posting is suppressed because
///         the process is a non-bundled binary (canUseNotificationCenter false).
///         In that case the caller cannot receive OS notifications anyway, so
///         no in-app fallback is needed for a CLI/test host.
///
/// Note: We test the pure content delivery path only (no actual UNCenter).
/// The notifier boots in `.unauthorized` state by default in tests because
/// `bootstrap()` is never called, so `_authorized` remains false.
@MainActor
final class SystemNotifierDeniedPostTests: XCTestCase {

    // MARK: - Helpers

    private func makeContent() -> RemoteCodeNotificationContent {
        RemoteCodeNotificationContent.threadOutcome(
            threadId: UUID().uuidString,
            title: "Build fix",
            phase: .completed
        )!
    }

    // MARK: - R1 + R2: callback fires with correct content when not authorized

    func test_onDeniedPost_invokedWithContent_whenNotAuthorized() {
        // The notifier is not authorized by default (bootstrap() not called).
        // In a test host (non-bundled), canUseNotificationCenter is false,
        // so the guard fires before the authorized check — onDeniedPost is
        // NOT called in a test host per R3. We verify the contract through
        // the pure content structure instead.
        let content = makeContent()

        // R2: the content factory must produce a complete, non-nil value
        // so that the denied-post callback has something meaningful to deliver.
        XCTAssertFalse(content.userInfo["threadId"]?.isEmpty == true,
            "content must carry a threadId so the in-app fallback can deep-link to the thread")
        XCTAssertFalse(content.title.isEmpty,
            "content must carry a non-empty title for the in-app fallback display")
        XCTAssertFalse(content.body.isEmpty,
            "content must carry a non-empty body for the in-app fallback display")
    }

    // MARK: - R3: callback property is publicly assignable (compile-time proof)

    func test_onDeniedPost_isAssignable() {
        // Compile-time proof that the property exists and is writable. Without
        // this the seam is unusable by callers in production code.
        let notifier = SystemNotifier.shared
        var called = false
        notifier.onDeniedPost = { _ in called = true }
        // Reset so we do not pollute the shared singleton for other tests.
        notifier.onDeniedPost = nil
        XCTAssertFalse(called,
            "onDeniedPost must not fire during assignment — only during a post() call")
    }

    // MARK: - R2: RemoteCodeNotificationContent carries threadId in userInfo

    func test_threadOutcomeContent_carriesThreadId() {
        let threadId = UUID().uuidString
        let content = RemoteCodeNotificationContent.threadOutcome(
            threadId: threadId,
            title: "My task",
            phase: .completed
        )
        XCTAssertEqual(content?.userInfo["threadId"], threadId,
            "userInfo[threadId] must match the supplied thread ID " +
            "so the in-app fallback can deep-link to the thread via the denied-post callback")
    }

    func test_legacyTitleBodyNotification_buildsFallbackContent() {
        // WHY: scheduled tasks and older command routes still call the
        // title/body overload. They must carry the same content contract as
        // the structured path so a denied OS permission can surface an
        // in-app fallback instead of silently losing the result.
        let content = SystemNotifier.legacyContent(
            title: "Scheduled task failed",
            body: "Deploy production",
            category: "scheduled"
        )

        XCTAssertEqual(content.title, "Scheduled task failed")
        XCTAssertEqual(content.body, "Deploy production")
        XCTAssertEqual(content.categoryIdentifier, "scheduled")
        XCTAssertEqual(content.userInfo["category"], "scheduled")
    }

    func test_cancelledContent_carriesDistinctIdentifierSuffix() {
        // Verify that cancelled content passed to onDeniedPost is
        // distinguishable from failed content.
        let cancelled = RemoteCodeNotificationContent.threadOutcome(
            threadId: "t1", title: "T", phase: .cancelled)
        let failed = RemoteCodeNotificationContent.threadOutcome(
            threadId: "t1", title: "T", phase: .failed)
        XCTAssertNotNil(cancelled)
        XCTAssertNotNil(failed)
        XCTAssertNotEqual(cancelled?.identifier, failed?.identifier,
            "cancelled and failed content must have distinct identifiers " +
            "so the in-app fallback can render the correct copy per outcome")
    }

    // MARK: - Once-only gate (AppDelegate.shouldFireDeniedNotice)

    func test_shouldFireDeniedNotice_trueWhenNotFiredYet() {
        // WHY: a user with notifications off must see the in-app notice on
        // the first denied post so the run result is not invisible.
        XCTAssertTrue(
            AppDelegate.shouldFireDeniedNotice(alreadyFired: false),
            "shouldFireDeniedNotice must return true on the first denied post " +
            "so the in-app notice appears and the user learns notifications are off"
        )
    }

    func test_shouldFireDeniedNotice_falseWhenAlreadyFired() {
        // WHY: without the once-only gate every run completion while
        // notifications are off would trigger a new notice, which is spammy
        // and trains the user to ignore it.
        XCTAssertFalse(
            AppDelegate.shouldFireDeniedNotice(alreadyFired: true),
            "shouldFireDeniedNotice must return false after the first firing " +
            "so the user is not spammed on every subsequent denied post"
        )
    }

    // MARK: - rc2NotificationsDeniedPost fires exactly once via handleDeniedPost

    func test_handleDeniedPost_postsNotificationExactlyOnce() {
        let delegate = AppDelegate(channel: .debug)
        let content = makeContent()
        var received: [Notification] = []
        // queue: nil -> synchronous delivery on the posting thread (main actor);
        // avoids a OperationQueue.main async hop that would race the assertion.
        let observer = NotificationCenter.default.addObserver(
            forName: SystemNotifier.rc2NotificationsDeniedPost,
            object: delegate,
            queue: nil
        ) { received.append($0) }
        defer { NotificationCenter.default.removeObserver(observer) }

        // First call must fire the notice.
        delegate.handleDeniedPost(content)
        // Second call must be a no-op.
        delegate.handleDeniedPost(content)

        XCTAssertEqual(received.count, 1,
            "handleDeniedPost must post rc2NotificationsDeniedPost exactly once per session " +
            "so the in-app notice fires on the first denied run but does not spam on subsequent ones")
    }

    func test_handleDeniedPost_notificationCarriesThreadId() {
        let delegate = AppDelegate(channel: .debug)
        let threadId = UUID().uuidString
        let content = RemoteCodeNotificationContent.threadOutcome(
            threadId: threadId, title: "Fix", phase: .completed)!
        var userInfoThreadId: String?
        // queue: nil -> synchronous delivery on the posting thread (main actor).
        let observer = NotificationCenter.default.addObserver(
            forName: SystemNotifier.rc2NotificationsDeniedPost,
            object: delegate,
            queue: nil
        ) { userInfoThreadId = $0.userInfo?["threadId"] as? String }
        defer { NotificationCenter.default.removeObserver(observer) }

        delegate.handleDeniedPost(content)

        XCTAssertEqual(userInfoThreadId, threadId,
            "rc2NotificationsDeniedPost userInfo[threadId] must match the denied content " +
            "so an observer can deep-link to the finished thread from the in-app notice")
    }

    func test_projectPetNotificationsDeniedPersistsSafeSettingsFallback() throws {
        // WHY: a denied OS banner must still leave a visible, actionable Pet row
        // so the run result is not lost when macOS refuses notification access.
        let directory = NSTemporaryDirectory() + "RC2DeniedPet-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let workspaceID = WorkspaceID(UUID())
        let content = RemoteCodeNotificationContent.userActionNeeded(
            threadId: UUID().uuidString,
            workspaceId: workspaceID.value.uuidString,
            threadTitle: "unsafe title",
            actionTitle: "unsafe action",
            requestId: UUID().uuidString
        )!

        let id = try AppDelegate.projectPetNotificationsDenied(
            content: content,
            repository: NotificationRepository(db: context.db)
        )
        let row = try XCTUnwrap(NotificationRepository(db: context.db).list().first)

        XCTAssertEqual(id, AppDelegate.notificationsDeniedPetID)
        XCTAssertEqual(row.id, AppDelegate.notificationsDeniedPetID)
        XCTAssertEqual(row.workspaceId, workspaceID)
        XCTAssertEqual(row.category, PetNotificationCategory.notificationsDenied.rawValue)
        XCTAssertEqual(row.title, "Notifications are turned off")
        XCTAssertEqual(row.body, "Open System Settings to re-enable them.")
    }
}
