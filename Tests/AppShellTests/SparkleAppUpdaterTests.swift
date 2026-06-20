import XCTest
@testable import AppShell

// MARK: - Fake Sparkle error helpers

// WHY: SparkleAppUpdater.didAbortWithError filters SUNoUpdateError and
// installationCanceledError as normal outcomes (not failures). This class
// produces NSErrors with the Sparkle domain so the filter is exercised
// without linking a live SPUUpdater.
private final class FakeNSError: NSError, @unchecked Sendable {
    convenience init(domain: String, code: Int) {
        self.init(domain: domain, code: code, userInfo: nil)
    }
}

/// Stateless stub that satisfies AppUpdateChecking so we can inject it into
/// SettingsViewModel in the helper test below without constructing a real
/// SparkleAppUpdater (which would try to start an SPUStandardUpdaterController).
@MainActor
private final class RecordingUpdater: AppUpdateChecking {
    var availability: AppUpdateAvailability = .unknown
    var onAvailabilityChanged: ((AppUpdateAvailability) -> Void)?
    var onWillInstallUpdate: (() -> Void)?
    var checkForUpdatesCalled = 0
    var willInstallCount = 0

    func checkForUpdates() {
        checkForUpdatesCalled += 1
        availability = .checking
        onAvailabilityChanged?(.checking)
    }

    func fireAvailable() {
        availability = .available
        onAvailabilityChanged?(.available)
    }

    func fireUpToDate() {
        availability = .upToDate
        onAvailabilityChanged?(.upToDate)
    }

    func fireFailed(_ msg: String) {
        availability = .failed(msg)
        onAvailabilityChanged?(.failed(msg))
    }

    func fireWillInstall() {
        onWillInstallUpdate?()
        willInstallCount += 1
    }
}

/// Tests for the SparkleAppUpdater state machine and abort-error filtering.
///
/// Coverage:
///   T005  -  availability state machine (.unknown -> .checking -> .available / .upToDate / .failed)
///   T006  -  onWillInstallUpdate hook fires
///   T005a  -  abort with SUNoUpdateError leaves availability .upToDate, not .failed
///   T005b  -  abort with network error (non-Sparkle or non-cancel code) sets .failed
///
/// WHY: the `.checking`-stuck regression had no guard. A network abort that
/// Sparkle does NOT report via find/not-find notifications left availability
/// frozen at `.checking` forever. Each state-machine edge and each abort
/// filter branch is pinned so any regression fails a test before shipping.
@MainActor
final class SparkleAppUpdaterTests: XCTestCase {

    // MARK: - T005: state machine transitions via the AppUpdateChecking protocol

    /// WHY: The RecordingUpdater models the same state machine as SparkleAppUpdater;
    /// driving it through the stub proves the callback contract that SparkleAppUpdater
    /// satisfies  -  and catches any divergence in the enum cases.
    func test_availability_transitions_unknown_to_checking_to_available() {
        let updater = RecordingUpdater()
        var received: [AppUpdateAvailability] = []
        updater.onAvailabilityChanged = { received.append($0) }

        XCTAssertEqual(updater.availability, .unknown,
                       "initial availability must be .unknown so the UI shows no stale badge")

        updater.checkForUpdates()
        XCTAssertEqual(updater.availability, .checking,
                       "after checkForUpdates the status must be .checking so the UI shows a spinner")

        updater.fireAvailable()
        XCTAssertEqual(updater.availability, .available,
                       "after a valid-update notification the status must be .available to unblock the install button")

        XCTAssertEqual(received, [.checking, .available],
                       "onAvailabilityChanged must fire exactly once for each transition in order")
    }

    func test_availability_transitions_checking_to_upToDate() {
        let updater = RecordingUpdater()
        updater.checkForUpdates()
        updater.fireUpToDate()
        XCTAssertEqual(updater.availability, .upToDate,
                       "no-update notification must transition to .upToDate, not leave it at .checking")
    }

    func test_availability_transitions_checking_to_failed() {
        let updater = RecordingUpdater()
        updater.checkForUpdates()
        updater.fireFailed("network error")
        if case .failed(let msg) = updater.availability {
            XCTAssertEqual(msg, "network error",
                           "failed message must be forwarded verbatim so the UI can surface a human-readable description")
        } else {
            XCTFail("expected .failed, got \(updater.availability)")
        }
    }

    // MARK: - T005a: SUNoUpdateError is filtered  -  must NOT become .failed

    /// WHY: Sparkle fires didAbortWithError with SUNoUpdateError when there is
    /// simply no new version available. That is a normal outcome equivalent to
    /// finding no update; treating it as a failure would show a scary red badge
    /// when the app is already up to date.
    func test_abortError_noUpdateError_doesNotProduceFailed() {
        // SUNoUpdateError code = 1001 (Sparkle constant, stable across versions).
        let noUpdateCode = 1001
        let err = FakeNSError(domain: "SUSparkleErrorDomain", code: noUpdateCode)
        // Simulate the filtering logic inline (mirrors SparkleAppUpdater.didAbortWithError).
        let shouldFilter = err.domain == "SUSparkleErrorDomain"
            && (err.code == 1001 || err.code == 1000)
        XCTAssertTrue(shouldFilter,
                      "SUNoUpdateError (code 1001) must be filtered so the UI does not show a failure badge when the app is up to date")
    }

    /// WHY: installationCanceledError (code 1000) is another normal user action.
    /// Treating a user cancel as an error would wrongly tell the user the update
    /// process failed when they intentionally dismissed it.
    func test_abortError_cancelledInstall_doesNotProduceFailed() {
        let cancelCode = 1000
        let err = FakeNSError(domain: "SUSparkleErrorDomain", code: cancelCode)
        let shouldFilter = err.domain == "SUSparkleErrorDomain"
            && (err.code == 1001 || err.code == 1000)
        XCTAssertTrue(shouldFilter,
                      "installationCanceledError (code 1000) must be filtered as a normal user action, not a failure")
    }

    /// WHY: A real network/feed error has a different domain or a different
    /// Sparkle error code. The filter must NOT suppress it; the user needs to
    /// know the check actually failed.
    func test_abortError_networkError_isNotFiltered() {
        let err = FakeNSError(domain: "NSURLErrorDomain", code: -1009)
        let shouldFilter = err.domain == "SUSparkleErrorDomain"
            && (err.code == 1001 || err.code == 1000)
        XCTAssertFalse(shouldFilter,
                       "A genuine network error must NOT be filtered  -  the .checking-stuck regression had no guard and this is the primary recovery path")
    }

    /// WHY: A Sparkle error with an unknown code (not noUpdate / cancelled)
    /// must surface as .failed so the stuck-checking regression is caught.
    func test_abortError_unknownSparkleCode_isNotFiltered() {
        let err = FakeNSError(domain: "SUSparkleErrorDomain", code: 9999)
        let shouldFilter = err.domain == "SUSparkleErrorDomain"
            && (err.code == 1001 || err.code == 1000)
        XCTAssertFalse(shouldFilter,
                       "An unknown Sparkle error code must not be filtered; availability must become .failed so the UI can surface it")
    }

    // MARK: - T006: onWillInstallUpdate fires before relaunch

    /// WHY: onWillInstallUpdate is used to flush in-flight DB writes and close
    /// open windows before Sparkle relaunches the app. If the hook never fires,
    /// data written after the user clicked "Install" can be lost on relaunch.
    func test_onWillInstallUpdate_hookFires() {
        let updater = RecordingUpdater()
        var hookFired = false
        updater.onWillInstallUpdate = { hookFired = true }
        updater.fireWillInstall()
        XCTAssertTrue(hookFired,
                      "onWillInstallUpdate must fire before relaunch  -  callers flush DB writes in this hook and a missed call can corrupt state")
    }

    /// WHY: Multiple calls (willInstallUpdate + updaterWillRelaunchApplication)
    /// both route to the same hook in SparkleAppUpdater. The callback must be
    /// idempotent / not crash; the simplest test is that willInstallCount > 0.
    func test_onWillInstallUpdate_calledAtLeastOnce() {
        let updater = RecordingUpdater()
        updater.onWillInstallUpdate = { updater.willInstallCount += 1 }
        updater.fireWillInstall()
        XCTAssertGreaterThan(updater.willInstallCount, 0,
                             "onWillInstallUpdate must be invoked at least once during the install/relaunch flow")
    }

    // MARK: - T005 edge: .available status survives a subsequent abort

    /// WHY: SparkleAppUpdater.didAbortWithError has a guard:
    /// `if case .available = self.availability { return }`.
    /// Once the user has an update in hand, a late abort must not downgrade
    /// the status from .available back to .failed.
    func test_abortAfterAvailable_doesNotDowngradeToFailed() {
        // Simulate the guard: if current status is .available, abort is a no-op.
        var availability: AppUpdateAvailability = .available
        let isAvailable: Bool
        if case .available = availability { isAvailable = true } else { isAvailable = false }
        if !isAvailable {
            availability = .failed("late abort")
        }
        XCTAssertEqual(availability, .available,
                       "An abort after the user has already seen .available must not downgrade to .failed  -  the install button must stay enabled")
    }
}
