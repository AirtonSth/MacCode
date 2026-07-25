import XCTest
@testable import AppShell

@MainActor
final class DirectAccessLifecycleSupervisorTests: XCTestCase {
    func test_bindFailure_neverPublishesBonjour() {
        var publishes = 0
        let supervisor = DirectAccessLifecycleSupervisor(
            startServer: { _ in throw TestError.bindFailed },
            stopServer: {},
            publishBonjour: { publishes += 1 },
            stopBonjour: {}
        )

        XCTAssertThrowsError(try supervisor.configure(remoteEnabled: true))
        XCTAssertEqual(publishes, 0,
                       "Bonjour must not advertise a port that failed to bind")
    }

    func test_sleepWake_restart_isIdempotent() throws {
        var starts = 0
        var stops = 0
        var publishes = 0
        var unpublishes = 0
        let supervisor = DirectAccessLifecycleSupervisor(
            startServer: { _ in starts += 1 },
            stopServer: { stops += 1 },
            publishBonjour: { publishes += 1 },
            stopBonjour: { unpublishes += 1 }
        )

        try supervisor.configure(remoteEnabled: true)
        supervisor.suspend()
        supervisor.suspend()
        try supervisor.resume(remoteEnabled: true)
        try supervisor.resume(remoteEnabled: true)

        XCTAssertEqual(starts, 2, "initial bind plus one wake bind must occur")
        XCTAssertEqual(stops, 1, "duplicate sleep notifications must not stop twice")
        XCTAssertEqual(publishes, 2, "Bonjour must publish once per successful bind")
        XCTAssertEqual(unpublishes, 1, "duplicate sleep notifications must not unpublish twice")
    }

    func test_bindFailure_retriesWithInjectedScheduler_andPublishesOnlyAfterSuccess() {
        var starts = 0
        var publishes = 0
        var scheduled: [@MainActor () -> Void] = []
        var delays: [TimeInterval] = []
        let supervisor = DirectAccessLifecycleSupervisor(
            startServer: { _ in
                starts += 1
                if starts == 1 { throw TestError.bindFailed }
            },
            stopServer: {},
            publishBonjour: { publishes += 1 },
            stopBonjour: {},
            retryDelays: [0.25, 0.5],
            scheduleRetry: { delay, action in
                delays.append(delay)
                scheduled.append(action)
                return {}
            }
        )

        XCTAssertThrowsError(try supervisor.configure(remoteEnabled: true))
        XCTAssertEqual(publishes, 0, "failed bind must remain undiscoverable")
        XCTAssertEqual(delays, [0.25])

        scheduled.removeFirst()()

        XCTAssertEqual(starts, 2)
        XCTAssertEqual(publishes, 1, "Bonjour must publish only after the retry binds successfully")
        XCTAssertEqual(delays, [0.25], "successful retry must stop the backoff chain")
    }

    /// WHY: the default scheduler hops DispatchWorkItem → Task; a cancel that
    /// lands between those hops cannot stop the already-created Task. Without
    /// a generation guard the stale retry runs start(remoteEnabled: true)
    /// AFTER the user toggled remote access off — binding 0.0.0.0 and
    /// publishing Bonjour while Settings shows OFF. The injected scheduler
    /// here returns a no-op cancellation to model exactly that lost cancel:
    /// the action still fires and must no-op on its own.
    func test_staleRetryAfterLostCancel_doesNotStartServer() throws {
        var shouldFail = true
        var starts = 0
        var publishes = 0
        var scheduled: [@MainActor () -> Void] = []
        let supervisor = DirectAccessLifecycleSupervisor(
            startServer: { _ in
                starts += 1
                if shouldFail { throw TestError.bindFailed }
            },
            stopServer: {},
            publishBonjour: { publishes += 1 },
            stopBonjour: {},
            retryDelays: [0.25],
            scheduleRetry: { _, action in
                scheduled.append(action)
                return {}   // cancellation is LOST (work item already executed)
            }
        )

        XCTAssertThrowsError(try supervisor.configure(remoteEnabled: true))
        XCTAssertEqual(scheduled.count, 1, "failed bind must arm one retry")

        // User toggles remote access OFF before the armed retry fires.
        shouldFail = false
        try supervisor.configure(remoteEnabled: false)
        let startsAfterToggleOff = starts

        // The stale retry's action still runs (its cancel was lost).
        scheduled.removeFirst()()

        XCTAssertEqual(starts, startsAfterToggleOff,
                       "a stale retry must no-op after a newer configure — not bind 0.0.0.0 behind an OFF toggle")
        XCTAssertEqual(publishes, 0,
                       "Bonjour must never be published by a retry the user's toggle-off superseded")
    }

    func test_reconfigure_cancelsPendingRetry() throws {
        var shouldFail = true
        var cancellations = 0
        let supervisor = DirectAccessLifecycleSupervisor(
            startServer: { _ in
                if shouldFail { throw TestError.bindFailed }
            },
            stopServer: {},
            publishBonjour: {},
            stopBonjour: {},
            retryDelays: [1],
            scheduleRetry: { _, _ in
                return { cancellations += 1 }
            }
        )

        XCTAssertThrowsError(try supervisor.configure(remoteEnabled: true))
        shouldFail = false
        XCTAssertNoThrow(try supervisor.configure(remoteEnabled: true))
        XCTAssertEqual(cancellations, 1,
                       "reconfigure must cancel stale retry work before starting a new listener")
    }

    func test_retryBackoff_stopsAtConfiguredBoundWithoutAdvertising() {
        var starts = 0
        var publishes = 0
        var delays: [TimeInterval] = []
        var scheduled: [@MainActor () -> Void] = []
        let supervisor = DirectAccessLifecycleSupervisor(
            startServer: { _ in
                starts += 1
                throw TestError.bindFailed
            },
            stopServer: {},
            publishBonjour: { publishes += 1 },
            stopBonjour: {},
            retryDelays: [0.25, 0.5],
            scheduleRetry: { delay, action in
                delays.append(delay)
                scheduled.append(action)
                return {}
            }
        )

        XCTAssertThrowsError(try supervisor.configure(remoteEnabled: true))
        scheduled.removeFirst()()
        scheduled.removeFirst()()

        XCTAssertEqual(starts, 3, "initial bind plus exactly two retries must run")
        XCTAssertEqual(delays, [0.25, 0.5], "retry schedule must stop at its configured bound")
        XCTAssertTrue(scheduled.isEmpty)
        XCTAssertEqual(publishes, 0, "repeated bind failures must never advertise Bonjour")
    }

    func test_productionModeContinuesAtCappedDelayUntilListenerRecovers() {
        var starts = 0
        var delays: [TimeInterval] = []
        var scheduled: [@MainActor () -> Void] = []
        let supervisor = DirectAccessLifecycleSupervisor(
            startServer: { _ in
                starts += 1
                throw TestError.bindFailed
            },
            stopServer: {},
            publishBonjour: {},
            stopBonjour: {},
            retryDelays: [0.25, 0.5],
            continueRetryingAfterDelays: true,
            scheduleRetry: { delay, action in
                delays.append(delay)
                scheduled.append(action)
                return {}
            }
        )

        XCTAssertThrowsError(try supervisor.configure(remoteEnabled: true))
        scheduled.removeFirst()()
        scheduled.removeFirst()()
        scheduled.removeFirst()()

        XCTAssertEqual(starts, 4, "listener recovery must keep retrying while remote access remains enabled")
        XCTAssertEqual(delays, [0.25, 0.5, 0.5, 0.5], "retry cadence must be capped instead of growing without bound")
    }

    func test_suspendAndShutdown_cancelPendingRetry() {
        var suspendCancellations = 0
        let suspended = DirectAccessLifecycleSupervisor(
            startServer: { _ in throw TestError.bindFailed },
            stopServer: {},
            publishBonjour: {},
            stopBonjour: {},
            retryDelays: [1],
            scheduleRetry: { _, _ in { suspendCancellations += 1 } }
        )
        XCTAssertThrowsError(try suspended.configure(remoteEnabled: true))
        suspended.suspend()
        XCTAssertEqual(suspendCancellations, 1)

        var shutdownCancellations = 0
        let shutdown = DirectAccessLifecycleSupervisor(
            startServer: { _ in throw TestError.bindFailed },
            stopServer: {},
            publishBonjour: {},
            stopBonjour: {},
            retryDelays: [1],
            scheduleRetry: { _, _ in { shutdownCancellations += 1 } }
        )
        XCTAssertThrowsError(try shutdown.configure(remoteEnabled: true))
        shutdown.shutdown()
        XCTAssertEqual(shutdownCancellations, 1)
    }

    private enum TestError: Error {
        case bindFailed
    }
}
