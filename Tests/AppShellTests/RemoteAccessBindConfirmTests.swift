import XCTest
@testable import AppShell
import CoreModel
import Persistence

/// Tests for the remote-access bind-confirmation seam (todo-ux/macos-app.md:162).
///
/// WHY: setRemoteAccess() previously wrote the preference and posted a notification
/// with no bind confirmation before returning. If configureDirectAccess() failed
/// to start the HTTP listener, remoteAccessEnabled stayed true while nothing was
/// listening -- the toggle showed "on" with no connections accepted.
///
/// The fix adds:
///   1. RemoteAccessStatus enum + pure remoteAccessStatus() decision function.
///   2. SettingsViewModel observes serverStartupFailureNotification: on bind failure
///      it reverts remoteAccessEnabled to false, rolls back the stored preference,
///      and sets remoteAccessBindFailedReason so the UI can surface the error.
///
/// These tests pin the pure decision seam and the VM revert behaviour so any
/// regression that re-introduces the optimistic "always on" path fails loudly.

// MARK: - Pure seam: RemoteAccessStatus.remoteAccessStatus()

final class RemoteAccessStatusTests: XCTestCase {

    // MARK: on + bound => .on

    /// WHY: when the user toggles on and the listener binds, the status must be
    /// .on. Any other result would hide a working listener from the UI.
    func test_status_requestedOn_bound_isOn() {
        let status = RemoteAccessStatus.remoteAccessStatus(
            requestedOn: true,
            listenerBound: true
        )
        XCTAssertEqual(status, .on,
            "requestedOn=true + listenerBound=true must yield .on: " +
            "the listener is accepting connections and the toggle should reflect that")
    }

    // MARK: on + not bound => .bindFailed

    /// WHY: when the user toggles on but the listener fails to bind (port taken,
    /// permission error, etc.) the status must be .bindFailed. Returning .on here
    /// is the exact bug being fixed -- the toggle shows active while nothing listens.
    func test_status_requestedOn_notBound_isBindFailed() {
        let status = RemoteAccessStatus.remoteAccessStatus(
            requestedOn: true,
            listenerBound: false,
            failureReason: "Address already in use"
        )
        if case .bindFailed(let reason) = status {
            XCTAssertEqual(reason, "Address already in use",
                "bindFailed must carry the exact failure reason so the UI can show actionable copy")
        } else {
            XCTFail("expected .bindFailed but got \(status) -- the toggle would show 'on' " +
                    "while nothing is listening")
        }
    }

    /// WHY: bind failure with an empty reason string must still produce .bindFailed,
    /// not silently degrade to .on. The reason string is display copy, not a gate.
    func test_status_requestedOn_notBound_emptyReason_isBindFailed() {
        let status = RemoteAccessStatus.remoteAccessStatus(
            requestedOn: true,
            listenerBound: false
        )
        if case .bindFailed = status {
            // pass
        } else {
            XCTFail("empty failureReason must not change .bindFailed to .on")
        }
    }

    // MARK: off => .off regardless of bound state

    /// WHY: when the user turns remote access off, the listener is intentionally
    /// not started (loopback-only mode). The status must be .off regardless of
    /// listenerBound, which is undefined in the off path.
    func test_status_requestedOff_isOff_whenBound() {
        let status = RemoteAccessStatus.remoteAccessStatus(
            requestedOn: false,
            listenerBound: true
        )
        XCTAssertEqual(status, .off,
            "requestedOn=false must yield .off even if listenerBound=true: " +
            "the 'off' path is loopback-only and does not expose remote connections")
    }

    func test_status_requestedOff_isOff_whenNotBound() {
        let status = RemoteAccessStatus.remoteAccessStatus(
            requestedOn: false,
            listenerBound: false
        )
        XCTAssertEqual(status, .off,
            "requestedOn=false + listenerBound=false must yield .off: " +
            "the listener was intentionally not started, not failed")
    }

    // MARK: Equatable

    /// WHY: .bindFailed(reason:) must compare equal to itself so tests and UI
    /// conditional logic (if status == .on) work without switch exhaustion.
    func test_status_equatable_onEqualsOn() {
        XCTAssertEqual(RemoteAccessStatus.on, RemoteAccessStatus.on)
    }

    func test_status_equatable_offEqualsOff() {
        XCTAssertEqual(RemoteAccessStatus.off, RemoteAccessStatus.off)
    }

    func test_status_equatable_bindFailedSameReason() {
        XCTAssertEqual(
            RemoteAccessStatus.bindFailed(reason: "EADDRINUSE"),
            RemoteAccessStatus.bindFailed(reason: "EADDRINUSE")
        )
    }

    func test_status_equatable_bindFailedDifferentReason() {
        XCTAssertNotEqual(
            RemoteAccessStatus.bindFailed(reason: "EADDRINUSE"),
            RemoteAccessStatus.bindFailed(reason: "EPERM")
        )
    }

    func test_status_equatable_onNotEqualBindFailed() {
        XCTAssertNotEqual(
            RemoteAccessStatus.on,
            RemoteAccessStatus.bindFailed(reason: "")
        )
    }

    func test_status_equatable_onNotEqualOff() {
        XCTAssertNotEqual(RemoteAccessStatus.on, RemoteAccessStatus.off)
    }
}

// MARK: - VM bind-failure revert (SettingsViewModel)

@MainActor
final class RemoteAccessBindConfirmVMTests: XCTestCase {

    private func makeVM() throws -> SettingsViewModel {
        let dir = NSTemporaryDirectory() + "RC2BindConfirm-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        return SettingsViewModel(context: ctx)
    }

    // MARK: setRemoteAccess clears bind-fail state

    /// WHY: toggling remote access on must clear remoteAccessBindFailedReason
    /// from a previous failure so the UI does not show a stale error alongside
    /// a fresh toggle attempt.
    func test_setRemoteAccess_on_clearsBindFailedReason() throws {
        let vm = try makeVM()
        // Manually inject a previous failure state.
        vm.remoteAccessBindFailedReason = "Address already in use"

        vm.setRemoteAccess(true)

        XCTAssertNil(vm.remoteAccessBindFailedReason,
            "setRemoteAccess(true) must clear remoteAccessBindFailedReason so a new " +
            "toggle attempt does not show a stale error from a prior failure")
    }

    func test_setRemoteAccess_off_clearsBindFailedReason() throws {
        let vm = try makeVM()
        vm.remoteAccessBindFailedReason = "EPERM"

        vm.setRemoteAccess(false)

        XCTAssertNil(vm.remoteAccessBindFailedReason,
            "setRemoteAccess(false) must also clear a stale bind-failed reason")
    }

    // MARK: serverStartupFailureNotification reverts the toggle

    /// WHY: this is the core regression guard. When AppDelegate posts
    /// serverStartupFailureNotification after a bind failure triggered by a
    /// remote-access toggle, SettingsViewModel must revert remoteAccessEnabled to
    /// false and set remoteAccessBindFailedReason. Without the revert the toggle
    /// shows "on" while nothing is listening -- the original bug.
    ///
    /// Test strategy: arm _pendingRemoteAccessToggle directly (it is internal for
    /// this reason) to avoid the async-clear race that would occur if we called
    /// setRemoteAccess(true) and then posted the notification separately. In
    /// production, AppDelegate posts serverStartupFailureNotification synchronously
    /// inside the rc2RemoteAccessSettingChanged handler, which means the failure
    /// observer block is queued BEFORE the deferred async clear -- test cannot
    /// replicate that ordering without the real AppDelegate. Arming the flag
    /// directly is the deterministic equivalent.
    func test_serverStartupFailureNotification_afterToggleOn_revertsToggle() throws {
        let vm = try makeVM()
        // Set up: toggle is visually on, preference stored as "1".
        vm.remoteAccessEnabled = true
        try vm.settingsRepo.set("remote_access_enabled", "1")
        // Arm the pending flag -- signals that this failure is from the current toggle.
        vm._pendingRemoteAccessToggle = true

        // Post the failure notification (simulating AppDelegate.recordServerStartupFailure).
        NotificationCenter.default.post(
            name: AppDelegate.serverStartupFailureNotification,
            object: nil
        )

        // The VM's observer (queue: .main) schedules the block on the main queue.
        // The block then schedules a Task { @MainActor }. Wait for both hops.
        let exp = expectation(description: "observer Task completes")
        DispatchQueue.main.async {
            // After the observer block runs (first hop), wait for the Task (second hop).
            DispatchQueue.main.async { exp.fulfill() }
        }
        waitForExpectations(timeout: 1)

        XCTAssertFalse(vm.remoteAccessEnabled,
            "after serverStartupFailureNotification, remoteAccessEnabled must be " +
            "false: showing 'on' while nothing is listening is the original bug (todo-ux:162)")
        XCTAssertNotNil(vm.remoteAccessBindFailedReason,
            "after a bind failure, remoteAccessBindFailedReason must be non-nil so " +
            "the UI can show an error instead of silently leaving a broken toggle")
    }

    /// WHY: the failed configure armed a supervisor retry that captured
    /// remoteEnabled=true. Reverting only the stored preference leaves that
    /// retry live — 1-7s later it can bind 0.0.0.0 and publish Bonjour while
    /// the toggle says OFF. The revert must re-post rc2RemoteAccessSettingChanged
    /// so AppDelegate reconfigures the supervisor to the reverted setting and
    /// cancels the armed retry.
    func test_serverStartupFailureRevert_reconfiguresSupervisorViaSettingChanged() throws {
        let vm = try makeVM()
        vm.remoteAccessEnabled = true
        try vm.settingsRepo.set("remote_access_enabled", "1")
        vm._pendingRemoteAccessToggle = true

        var settingChangedPosts = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .rc2RemoteAccessSettingChanged, object: nil, queue: .main
        ) { _ in settingChangedPosts += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        NotificationCenter.default.post(
            name: AppDelegate.serverStartupFailureNotification,
            object: nil
        )

        let exp = expectation(description: "observer Task completes")
        DispatchQueue.main.async { DispatchQueue.main.async { exp.fulfill() } }
        waitForExpectations(timeout: 1)

        XCTAssertEqual(settingChangedPosts, 1,
            "the bind-failure revert must post rc2RemoteAccessSettingChanged exactly once " +
            "so the supervisor is reconfigured to OFF and its armed remoteEnabled=true retry is cancelled")
        XCTAssertEqual(try vm.settingsRepo.get("remote_access_enabled"), "0",
            "the reconfigure must read the already-reverted stored setting")
    }

    // MARK: reload reads real stored preference

    /// WHY: reload() reads the stored preference. After a bind failure the stored
    /// preference is rolled back to "0". A subsequent reload must reflect "0"
    /// (false), not the in-flight optimistic value.
    func test_reload_afterBindFailureRollback_readsOffFromStore() throws {
        let vm = try makeVM()
        // Simulate the rollback: store "0" then call reload.
        try vm.settingsRepo.set("remote_access_enabled", "0")
        vm.reload()

        XCTAssertFalse(vm.remoteAccessEnabled,
            "after storing '0' (the bind-failure rollback), reload must set " +
            "remoteAccessEnabled=false: the stored value is the source of truth")
    }

    // MARK: unarmed pending flag: failure notification ignored

    /// WHY: a serverStartupFailureNotification that arrives when _pendingRemoteAccessToggle
    /// is false (e.g., a failure from a different component, or a stale failure from
    /// app launch before any toggle was attempted) must NOT set remoteAccessBindFailedReason.
    /// Only failures that belong to the current toggle attempt should be surfaced on
    /// the toggle row.
    func test_serverStartupFailureNotification_withoutPendingToggle_doesNotSetBindFailedReason() throws {
        let vm = try makeVM()
        // _pendingRemoteAccessToggle starts as false (no toggle in progress).
        XCTAssertFalse(vm._pendingRemoteAccessToggle)

        // Post a failure notification unrelated to any toggle.
        NotificationCenter.default.post(
            name: AppDelegate.serverStartupFailureNotification,
            object: nil
        )

        // Give the main queue two cycles (observer block + Task).
        let exp = expectation(description: "main queue settled")
        DispatchQueue.main.async {
            DispatchQueue.main.async { exp.fulfill() }
        }
        waitForExpectations(timeout: 1)

        XCTAssertNil(vm.remoteAccessBindFailedReason,
            "a serverStartupFailureNotification with no pending toggle must not set " +
            "remoteAccessBindFailedReason: unrelated failures must not corrupt the toggle UI")
        XCTAssertFalse(vm.remoteAccessEnabled,
            "remoteAccessEnabled must remain false (it was never toggled on in this test)")
    }
}
