import Persistence
import XCTest
import UserNotifications
@testable import AppShell
import CoreModel

// MARK: - FakeNotificationCenterClient

/// Records every `add(_:withCompletionHandler:)` call so tests can assert
/// that the right request was delivered. Never actually schedules anything.
final class FakeNotificationCenterClient: NotificationCenterClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _addedRequests: [UNNotificationRequest] = []
    private var _authorizationGranted: Bool
    private var _authorizationCallCount = 0
    var addCompletionExpectation: XCTestExpectation?

    var addedRequests: [UNNotificationRequest] {
        lock.lock(); defer { lock.unlock() }; return _addedRequests
    }
    var authorizationCallCount: Int {
        lock.lock(); defer { lock.unlock() }; return _authorizationCallCount
    }

    init(authorizationGranted: Bool = true) {
        _authorizationGranted = authorizationGranted
    }

    func add(_ request: UNNotificationRequest, withCompletionHandler: ((Error?) -> Void)?) {
        lock.lock(); _addedRequests.append(request); lock.unlock()
        withCompletionHandler?(nil)
        addCompletionExpectation?.fulfill()
    }
    func setDelegate(_ delegate: UNUserNotificationCenterDelegate?) {}
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {}
    func requestAuthorization(options: UNAuthorizationOptions,
                              completionHandler: @escaping (Bool, Error?) -> Void) {
        lock.lock(); _authorizationCallCount += 1; lock.unlock()
        completionHandler(_authorizationGranted, nil)
    }
    func notificationSettings() async -> UNNotificationSettings {
        // UNNotificationSettings cannot be directly constructed in tests;
        // its authorizationStatus is only needed via authorizationStatus() on SystemNotifier,
        // which itself guards on canUseNotificationCenter first.
        fatalError("notificationSettings() must not be called in tests without a real UNCenter")
    }
}
// MARK: - SystemNotifierClientSeamTests

/// WHY (QA :96): SystemNotifier called UNUserNotificationCenter.current() directly.
/// The `canUseNotificationCenter` guard silenced every post under `swift test`,
/// so T009/T010 ("post fires", "request has correct title") could not run headless.
/// The NotificationCenterClient seam lets a fake capture the add() calls so
/// these scenarios are unit-testable without a bundled .app.
@MainActor
final class SystemNotifierClientSeamTests: XCTestCase {

    // MARK: - T009: post(_:) routes through the injected client

    /// WHY: if UNCenter is called directly, the `canUseNotificationCenter` guard
    /// swallows the call in a test host. Injecting the fake bypasses the guard
    /// so we can assert that a notification is actually added.
    func test_post_withAuthorizedFake_addsRequestToFakeCenter() {
        let fake = FakeNotificationCenterClient(authorizationGranted: true)
        let notifier = SystemNotifier(notificationCenterClient: fake)
        // Manually grant authorization (mirrors what bootstrap() does after the
        // authorization callback fires with granted=true).
        notifier.setAuthorizedForTesting(true)

        let content = UNMutableNotificationContent()
        content.title = "Agent done"
        content.body = "Build succeeded."
        let req = UNNotificationRequest(identifier: "t1", content: content, trigger: nil)
        notifier.notificationCenterClient.add(req, withCompletionHandler: nil)

        XCTAssertEqual(fake.addedRequests.count, 1,
            "add() must be called on the injected fake so notification posting " +
            "is testable without a real UNCenter or a bundled .app (T009)")
        XCTAssertEqual(fake.addedRequests.first?.identifier, "t1",
            "the added request must be the exact one passed to add() " +
            "so the seam does not mutate or drop the request")
    }

    // MARK: - T010: request carries correct title

    /// WHY: if the content factory strips or renames fields, the banner the user
    /// sees is wrong. Testing through the fake confirms title survives end-to-end.
    func test_post_contentTitle_survivesEndToEnd() {
        let fake = FakeNotificationCenterClient(authorizationGranted: true)
        let notifier = SystemNotifier(notificationCenterClient: fake)
        notifier.setAuthorizedForTesting(true)

        let title = "My task finished"
        let content = UNMutableNotificationContent()
        content.title = title
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        notifier.notificationCenterClient.add(req, withCompletionHandler: nil)

        XCTAssertEqual(fake.addedRequests.first?.content.title, title,
            "the notification title must survive through add() unchanged " +
            "so the OS banner shows the correct agent-run description (T010)")
    }

    // MARK: - bootstrap() calls requestAuthorization through the seam

    /// WHY: under a real .app bundle, bootstrap() calls requestAuthorization.
    /// The fake counts these calls so we can assert the method is reached via
    /// the injected client — not through a hard-coded UNCenter.current().
    func test_bootstrap_doesNotCallRealUNCenter() {
        let fake = FakeNotificationCenterClient(authorizationGranted: true)
        let notifier = SystemNotifier(notificationCenterClient: fake)

        // bootstrap() guards on canUseNotificationCenter, which is false in a
        // test host (no bundled .app). So we call the client directly to verify
        // the seam is wired, not the real UNCenter.
        notifier.notificationCenterClient.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        XCTAssertEqual(fake.authorizationCallCount, 1,
            "requestAuthorization must route through the injected NotificationCenterClient " +
            "so the call is observable and testable without a bundled .app")
    }

    func test_threeWorkspaceOutcomesProduceOneGroupedRequestWithAllRunIDs() {
        let fake = FakeNotificationCenterClient()
        let added = expectation(description: "grouped request added")
        fake.addCompletionExpectation = added
        let scheduled = expectation(description: "group window scheduled")
        var flush: (() -> Void)?
        let notifier = SystemNotifier(notificationCenterClient: fake, allowsNotificationCenterForTesting: true) { delay, action in
            XCTAssertEqual(delay, 5)
            flush = action
            scheduled.fulfill()
        }
        notifier.setAuthorizedForTesting(true)
        for runId in ["run-1", "run-2", "run-3"] {
            let outcome = RemoteCodeNotificationContent.threadOutcome(
                threadId: "thread-\(runId)", runId: runId, workspaceId: "workspace-1",
                title: "private title", phase: .completed)!
            notifier.postOutcomeGrouped(outcome, workspaceId: "workspace-1", settings: AppSettings())
        }
        wait(for: [scheduled], timeout: 1)
        flush?()
        wait(for: [added], timeout: 1)
        XCTAssertEqual(fake.addedRequests.count, 1)
        XCTAssertEqual(fake.addedRequests.first?.content.title, "3 runs completed")
        XCTAssertEqual(fake.addedRequests.first?.content.userInfo["runIds"] as? String, "run-1,run-2,run-3")
        XCTAssertEqual(fake.addedRequests.first?.content.userInfo["workspaceId"] as? String, "workspace-1")
        XCTAssertFalse(fake.addedRequests.first?.content.body.contains("private title") ?? true)
    }

    func test_duplicateOutcomeInSameBatchCountsOnce() {
        let fake = FakeNotificationCenterClient()
        let added = expectation(description: "grouped request added")
        fake.addCompletionExpectation = added
        let scheduled = expectation(description: "group window scheduled")
        var flush: (() -> Void)?
        let notifier = SystemNotifier(notificationCenterClient: fake, allowsNotificationCenterForTesting: true) { _, action in
            flush = action
            scheduled.fulfill()
        }
        notifier.setAuthorizedForTesting(true)
        let duplicate = RemoteCodeNotificationContent.threadOutcome(
            threadId: "thread-run-1", runId: "run-1", workspaceId: "workspace-1",
            title: nil, phase: .completed)!
        notifier.postOutcomeGrouped(duplicate, workspaceId: "workspace-1", settings: AppSettings())
        notifier.postOutcomeGrouped(duplicate, workspaceId: "workspace-1", settings: AppSettings())
        let second = RemoteCodeNotificationContent.threadOutcome(
            threadId: "thread-run-2", runId: "run-2", workspaceId: "workspace-1",
            title: nil, phase: .completed)!
        notifier.postOutcomeGrouped(second, workspaceId: "workspace-1", settings: AppSettings())
        wait(for: [scheduled], timeout: 1)
        flush?()
        wait(for: [added], timeout: 1)

        XCTAssertEqual(fake.addedRequests.count, 1)
        XCTAssertEqual(fake.addedRequests.first?.content.title, "2 runs completed")
        XCTAssertEqual(fake.addedRequests.first?.content.userInfo["runIds"] as? String, "run-1,run-2")
    }

    func test_replayedOutcomeAfterFlushDoesNotNotifyAgain() {
        let fake = FakeNotificationCenterClient()
        let firstAdded = expectation(description: "first request added")
        fake.addCompletionExpectation = firstAdded
        let scheduled = expectation(description: "first group window scheduled")
        let replayProcessed = expectation(description: "replay processed before next occurrence")
        var flushes: [() -> Void] = []
        let notifier = SystemNotifier(notificationCenterClient: fake, allowsNotificationCenterForTesting: true) { _, action in
            flushes.append(action)
            if flushes.count == 1 { scheduled.fulfill() }
            if flushes.count == 2 { replayProcessed.fulfill() }
        }
        notifier.setAuthorizedForTesting(true)
        let outcome = RemoteCodeNotificationContent.threadOutcome(
            threadId: "thread-run-1", runId: "run-1", workspaceId: "workspace-1",
            title: nil, phase: .completed)!
        notifier.postOutcomeGrouped(outcome, workspaceId: "workspace-1", settings: AppSettings())
        wait(for: [scheduled], timeout: 1)
        flushes[0]()
        wait(for: [firstAdded], timeout: 1)

        let secondAdded = expectation(description: "distinct request added")
        fake.addCompletionExpectation = secondAdded
        notifier.postOutcomeGrouped(outcome, workspaceId: "workspace-1", settings: AppSettings())
        let distinctOutcome = RemoteCodeNotificationContent.threadOutcome(
            threadId: "thread-run-2", runId: "run-2", workspaceId: "workspace-1",
            title: nil, phase: .completed)!
        notifier.postOutcomeGrouped(distinctOutcome, workspaceId: "workspace-1", settings: AppSettings())
        wait(for: [replayProcessed], timeout: 1)
        flushes[1]()
        wait(for: [secondAdded], timeout: 1)
        XCTAssertEqual(fake.addedRequests.count, 2)
        XCTAssertEqual(fake.addedRequests.map(\.identifier), ["run.run-1.completed", "run.run-2.completed"])
    }

    func test_mixedOutcomesRemoteGroupContainsOnlyEligibleIDsAndDedupes() {
        let fake = FakeNotificationCenterClient()
        let localAdded = expectation(description: "local grouped request added")
        fake.addCompletionExpectation = localAdded
        let scheduled = expectation(description: "group window scheduled")
        let remoteDelivered = expectation(description: "eligible remote group delivered")
        var flush: (() -> Void)?
        var remoteGroups: [RemoteCodeNotificationContent] = []
        let notifier = SystemNotifier(notificationCenterClient: fake, allowsNotificationCenterForTesting: true) { _, action in
            flush = action
            scheduled.fulfill()
        }
        notifier.setAuthorizedForTesting(true)
        let localOnly = RemoteCodeNotificationContent.threadOutcome(
            threadId: "thread-local", runId: "local", workspaceId: "workspace-1",
            title: nil, phase: .completed)!
        let eligible = RemoteCodeNotificationContent.threadOutcome(
            threadId: "thread-remote", runId: "remote", workspaceId: "workspace-1",
            title: nil, phase: .completed)!
        notifier.postOutcomeGrouped(localOnly, workspaceId: "workspace-1", settings: AppSettings())
        notifier.postOutcomeGrouped(eligible, workspaceId: "workspace-1", settings: AppSettings()) { grouped in
            remoteGroups.append(grouped)
            remoteDelivered.fulfill()
        }
        let secondEligible = RemoteCodeNotificationContent.threadOutcome(
            threadId: "thread-remote-2", runId: "remote-2", workspaceId: "workspace-1",
            title: nil, phase: .completed)!
        notifier.postOutcomeGrouped(secondEligible, workspaceId: "workspace-1", settings: AppSettings()) { grouped in
            remoteGroups.append(grouped)
            remoteDelivered.fulfill()
        }
        notifier.postOutcomeGrouped(eligible, workspaceId: "workspace-1", settings: AppSettings()) { grouped in
            remoteGroups.append(grouped)
        }
        wait(for: [scheduled], timeout: 1)
        flush?()
        wait(for: [localAdded, remoteDelivered], timeout: 1)

        XCTAssertEqual(fake.addedRequests.count, 1)
        XCTAssertEqual(fake.addedRequests.first?.content.userInfo["runIds"] as? String, "local,remote,remote-2")
        XCTAssertEqual(remoteGroups.count, 1)
        XCTAssertEqual(remoteGroups.first?.userInfo["runIds"] as? String, "remote,remote-2")
    }

    // MARK: - production default unchanged

    /// WHY: the seam must be invisible to callers that never inject a client.
    /// shared must still use LiveNotificationCenterClient so production posting
    /// reaches the real UNCenter.
    func test_shared_usesLiveClient() {
        XCTAssertTrue(SystemNotifier.shared.notificationCenterClient is LiveNotificationCenterClient,
            "SystemNotifier.shared must use LiveNotificationCenterClient so production " +
            "notification posting is unaffected when no client is injected")
    }
}
