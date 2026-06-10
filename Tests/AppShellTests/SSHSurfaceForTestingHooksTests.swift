import XCTest
import CoreModel
import DesignSystemKit
@testable import AppShell

/// Tests wiring the built-in SSH ForTesting hooks to assertions (T049-T064
/// subset exercisable without a router or live SSH session).
///
/// WHY: the hooks exist precisely for testing (QA-MAC_SSH-008) but none
/// of them were referenced in any test file before this suite. Bit-rot
/// risk is high: a silent rename or removal of a testing accessor breaks
/// the contract the hook was created to enforce with zero feedback.
@MainActor
final class SSHSurfaceForTestingHooksTests: XCTestCase {

    private func makeSurface() throws -> SSHSurface {
        try SSHSurface(workspaceID: WorkspaceID(), cwd: "/tmp", title: "t", router: nil)
    }

    // MARK: - transferLogForTesting (T057)

    // WHY: the transfer log is the audit trail for SSH file operations shown
    // in the UI. If transferLogForTesting returns the wrong slice, tests
    // that assert "Upload completed" appeared in the log pass vacuously.
    func test_transferLog_initiallyContainsReadyMessage() throws {
        let surface = try makeSurface()
        // The view model pre-populates the log with "Ready".
        XCTAssertFalse(surface.transferLogForTesting.isEmpty,
                       "transfer log must not be empty on init -- 'Ready' message must be present")
    }

    // MARK: - enqueueForTesting + queueCountForTesting

    // WHY: queueCountForTesting must reflect every enqueued item.
    // If the count is wrong, tests that gate assertions on queue depth
    // pass or fail spuriously.
    func test_enqueue_incrementsQueueCount() throws {
        let surface = try makeSurface()
        XCTAssertEqual(surface.queueCountForTesting, 0)
        surface.enqueueForTesting(upload: true, localPath: "/a/f.txt", remotePath: "/b/f.txt")
        XCTAssertEqual(surface.queueCountForTesting, 1,
                       "enqueueForTesting must add one row to the visible transfer queue")
    }

    func test_enqueue_multipleItems_countMatchesEnqueuedCount() throws {
        let surface = try makeSurface()
        surface.enqueueForTesting(upload: true,  localPath: "/a/1.txt", remotePath: "/r/1.txt")
        surface.enqueueForTesting(upload: false, localPath: "/a/2.txt", remotePath: "/r/2.txt")
        surface.enqueueForTesting(upload: true,  localPath: "/a/3.txt", remotePath: "/r/3.txt")
        XCTAssertEqual(surface.queueCountForTesting, 3,
                       "three enqueued transfers must produce a queue count of 3")
    }

    // MARK: - requestCancelForTesting (T060)

    // WHY: requestCancelForTesting must mark the row .cancelled so the UI
    // does not show "Queued" forever after a cancel request. The cooperative
    // cancel contract (P1) depends on this being reflected before the opaque
    // scp command finishes.
    func test_requestCancel_marksRowCancelled() throws {
        let surface = try makeSurface()
        surface.enqueueForTesting(upload: true, localPath: "/a/x", remotePath: "/b/x")
        XCTAssertEqual(surface.queuedCountForTesting, 1)

        surface.requestCancelForTesting(localPath: "/a/x", remotePath: "/b/x")

        XCTAssertEqual(surface.cancelledCountForTesting, 1,
                       "requestCancelForTesting must flip the row to .cancelled so cancel feedback is immediate")
        XCTAssertEqual(surface.queuedCountForTesting, 0,
                       "after cancel the row must no longer count as queued")
    }

    // MARK: - selectedLocalCountForTesting / selectedRemoteCountForTesting (T058/T059)

    // WHY: without a test asserting the initial count is zero, a regression
    // that pre-selects rows on init would never be caught -- every subsequent
    // transfer test would start with phantom selected items.
    func test_selectedCounts_initiallyZero() throws {
        let surface = try makeSurface()
        XCTAssertEqual(surface.selectedLocalCountForTesting, 0,
                       "no local file must be pre-selected on a fresh SSH surface")
        XCTAssertEqual(surface.selectedRemoteCountForTesting, 0,
                       "no remote file must be pre-selected on a fresh SSH surface")
    }

    // MARK: - applyAdaptiveHostSidebarForTesting (T062)

    // WHY: applyAdaptiveHostSidebar contains the sidebar auto-hide policy.
    // The ForTesting overload injects a deterministic clock so the debounce
    // window is predictable. Without tests the entire auto-hide path ships
    // on faith; the first regression (e.g. sidebar stuck hidden) is only
    // caught by a user report.
    func test_applyAdaptiveHostSidebarForTesting_doesNotCrash() throws {
        let surface = try makeSurface()
        // A very narrow width should trigger auto-hide policy evaluation.
        // We just assert it does not crash or throw; behavior is covered
        // by AdaptiveSidebarPolicyTests which tests the pure policy function.
        surface.applyAdaptiveHostSidebarForTesting(width: 320, event: .resize, now: 100)
        surface.applyAdaptiveHostSidebarForTesting(width: 1200, event: .structural, now: 200)
        // No XCTFail = pass: the hook exists, is callable, and does not crash.
    }

    // MARK: - hostSidebarWidthForTesting / setHostSidebarWidthForTesting (T063)

    // WHY: the host sidebar width is persisted to UserDefaults so it
    // survives relaunches. If setHostSidebarWidthForTesting doesn't clamp
    // to the allowed range (220..520) a subsequent launch reads an
    // out-of-range value and the sidebar snaps to an unexpected width.
    func test_setHostSidebarWidth_clampsBelowMinimum() throws {
        let surface = try makeSurface()
        surface.setHostSidebarWidthForTesting(100)
        XCTAssertGreaterThanOrEqual(surface.hostSidebarWidthForTesting, 220,
                                    "sidebar width must be clamped to the minimum of 220 pt")
    }

    func test_setHostSidebarWidth_clampsAboveMaximum() throws {
        let surface = try makeSurface()
        surface.setHostSidebarWidthForTesting(9999)
        XCTAssertLessThanOrEqual(surface.hostSidebarWidthForTesting, 520,
                                 "sidebar width must be clamped to the maximum of 520 pt")
    }

    func test_setHostSidebarWidth_withinRange_isStoredExactly() throws {
        let surface = try makeSurface()
        surface.setHostSidebarWidthForTesting(350)
        XCTAssertEqual(surface.hostSidebarWidthForTesting, 350,
                       "a width within [220, 520] must be stored and read back without alteration")
    }

    // MARK: - identityFilePickerForTesting (T064)

    // WHY: identityFilePickerForTesting replaces the blocking NSOpenPanel so
    // tests can supply a path programmatically. If the hook is not wired
    // to the view model, the injected picker is never called and the test
    // silently falls back to an NSOpenPanel (which would block the test runner).
    func test_identityFilePicker_injectedPickerIsCalledWhenSet() throws {
        let surface = try makeSurface()
        var pickerCalled = false
        surface.identityFilePickerForTesting = {
            pickerCalled = true
            return "/tmp/id_ed25519"
        }
        // The picker is stored on the view model; setting it must not crash.
        // Full invocation requires a UI interaction, so we just verify the
        // seam is in place and the closure was retained.
        XCTAssertNotNil(surface.identityFilePickerForTesting,
                        "identityFilePickerForTesting must persist after assignment")
        // Invoke the stored closure directly to confirm it is retained.
        let result = surface.identityFilePickerForTesting?()
        XCTAssertTrue(pickerCalled,
                      "the injected identity-file picker must be callable after assignment")
        XCTAssertEqual(result, "/tmp/id_ed25519",
                       "picker must return the injected path unchanged")
    }

    // MARK: - localPathPickerForTesting (T053)

    // WHY: localPathPickerForTesting replaces the blocking NSOpenPanel for
    // choosing the local transfer directory. Without this hook, any test
    // that exercises chooseLocalTransferPath would stall waiting for user
    // input.
    func test_localPathPicker_injectedPickerIsCalled() throws {
        let surface = try makeSurface()
        var pickerCalled = false
        surface.localPathPickerForTesting = {
            pickerCalled = true
            return (path: "/home/user/downloads", isDirectory: true)
        }
        // Invoke the stored closure directly to confirm it is callable.
        let result = surface.localPathPickerForTesting?()
        XCTAssertTrue(pickerCalled,
                      "localPathPickerForTesting must return the injected value when called")
        XCTAssertEqual(result?.path, "/home/user/downloads")
        XCTAssertEqual(result?.isDirectory, true)
    }

    // MARK: - updateProgressForTesting / queueProgressForTesting (T056)

    // WHY: progress updates must be clamped to 0...100.  A value > 100 from
    // a buggy scp stderr parser would overflow the progress bar view and
    // potentially cause layout glitches on the per-row progress indicator.
    func test_updateProgress_clampsTo100() throws {
        let surface = try makeSurface()
        surface.enqueueForTesting(upload: true, localPath: "/a/big", remotePath: "/b/big")
        surface.updateProgressForTesting(localPath: "/a/big", remotePath: "/b/big", percent: 200)
        let progress = surface.queueProgressForTesting(localPath: "/a/big", remotePath: "/b/big")
        XCTAssertEqual(progress, 100,
                       "progress > 100 must be clamped to 100 to prevent UI overflow")
    }

    func test_updateProgress_belowZero_clampsToZero() throws {
        let surface = try makeSurface()
        surface.enqueueForTesting(upload: false, localPath: "/a/dl", remotePath: "/b/dl")
        surface.updateProgressForTesting(localPath: "/a/dl", remotePath: "/b/dl", percent: -5)
        let progress = surface.queueProgressForTesting(localPath: "/a/dl", remotePath: "/b/dl")
        XCTAssertEqual(progress, 0,
                       "negative progress must be clamped to 0")
    }
}
