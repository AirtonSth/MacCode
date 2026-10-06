import XCTest
import CoreModel
import Persistence
import AgentRuntime
@testable import AppShell

/// WHY: live `.accountUsage` is delivered on the provider parse queue
/// (`remotecode.codex-app-server.parse` → coordinator →
/// `AppContext.recordAccountUsage`). A synchronous
/// `NotificationCenter.post` waits for OperationQueue observers (UI reloads
/// registered with `queue: .main`) via `-[NSOperation waitUntilFinished]`.
/// That blocks the parse path while main/mirror work waits on locks held by
/// the same event chain — observed as a multi-minute hang. These tests fail
/// if account-usage recording reintroduces a synchronous observer wait, and
/// prove delivery still reaches MainActor-safe observers asynchronously.
@MainActor
final class AccountUsageNotificationTests: XCTestCase {

    /// Regression for the parse-queue hang: a slow OperationQueue observer must
    /// not keep `recordAccountUsage` from returning.
    func test_accountUsageRecording_doesNotSynchronouslyWaitForNotificationObservers() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2AccountUsageNotifyAsync-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)

        let thread = AgentThread(title: "account-usage-async", provider: .codex, model: "m")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "m",
            status: .running,
            startedAt: Date()
        )
        try context.runRepo.upsert(run)

        // Mirror the hang mechanism: NotificationCenter waits for OperationQueue
        // observers. A short observer delay proves wait vs schedule without
        // making the suite slow.
        let observerWorkDuration: TimeInterval = 0.5
        let blockingQueue = OperationQueue()
        blockingQueue.name = "test.rc2.account-usage.blocking-observer"
        blockingQueue.maxConcurrentOperationCount = 1

        let delivered = expectation(description: "usage-changed eventually delivered")
        // `.rc2AccountUsageChanged` is posted with `object: nil`, so throttled
        // posts from AppContexts built by earlier tests in the same process can
        // also reach this observer. Extra deliveries must not abort the run.
        delivered.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(
            forName: .rc2AccountUsageChanged,
            object: nil,
            queue: blockingQueue
        ) { _ in
            Thread.sleep(forTimeInterval: observerWorkDuration)
            delivered.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            blockingQueue.cancelAllOperations()
        }

        let started = Date()
        context.coordinator.onAssistantEvent?(
            .accountUsage(AssistantAccountUsage(
                provider: .codex,
                weeklyUsedPercent: 42,
                weeklyWindowDurationMinutes: 10_080
            )),
            thread.id,
            run.id
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            elapsed,
            observerWorkDuration * 0.5,
            "recordAccountUsage must return without waiting for NotificationCenter observers; elapsed=\(elapsed)s (sync post would wait ~\(observerWorkDuration)s)"
        )

        let stored = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory)
            .load()
            .providers
            .first { $0.provider == .codex }
        XCTAssertEqual(
            stored?.weeklyUsedPercent,
            42,
            "SQLite account-usage write must still complete before the recording path returns"
        )

        // Notification semantics preserved: observers still receive the event.
        await fulfillment(of: [delivered], timeout: 3.0)
    }

    /// WHY: Sidebar / AgentAppSurface observe with `queue: .main`. Delivery must
    /// be scheduled onto MainActor work (not run inline on the recording call
    /// stack). When already on main, a synchronous post invokes main-queue
    /// observers before `post` returns — that is exactly the path that
    /// `waitUntilFinished` takes against main ops when the poster is off-main
    /// (provider parse). Asserting "not yet delivered on return" + later
    /// main-thread delivery fails if the sync post is reintroduced.
    func test_accountUsageNotification_isNotDeliveredSynchronously_andLandsOnMain() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2AccountUsageNotifyMain-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)

        let thread = AgentThread(title: "account-usage-main", provider: .claude, model: "m")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "m",
            status: .running,
            startedAt: Date()
        )
        try context.runRepo.upsert(run)

        let delivered = expectation(description: "usage-changed delivered on main")
        // The notification is global (`object: nil`): throttled posts from
        // AppContexts created by earlier tests can arrive after this one.
        // Tolerate them instead of aborting on over-fulfill.
        delivered.assertForOverFulfill = false
        var observerCallCount = 0
        var observedIsMainThread = false

        let observer = NotificationCenter.default.addObserver(
            forName: .rc2AccountUsageChanged,
            object: nil,
            queue: .main
        ) { _ in
            observerCallCount += 1
            observedIsMainThread = Thread.isMainThread
            delivered.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        context.coordinator.onAssistantEvent?(
            .accountUsage(AssistantAccountUsage(
                provider: .claude,
                weeklyUsedPercent: 57,
                weeklyWindowDurationMinutes: 10_080
            )),
            thread.id,
            run.id
        )

        XCTAssertEqual(
            observerCallCount,
            0,
            "usage-changed must not run inline inside recordAccountUsage (sync post would invoke queue:.main observers before return on MainActor)"
        )

        await fulfillment(of: [delivered], timeout: 3.0)

        // At least one delivery; stray posts from other contexts in the same
        // process can add more, and every one of them runs on main.
        XCTAssertGreaterThanOrEqual(observerCallCount, 1)
        XCTAssertTrue(
            observedIsMainThread,
            "rc2AccountUsageChanged UI observers must run on the main thread, not a provider parse queue"
        )
    }
}
