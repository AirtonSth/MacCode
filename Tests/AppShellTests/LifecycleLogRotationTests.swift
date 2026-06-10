import XCTest
@testable import AppShell

/// Tests for lifecycle.log size-capped rotation.
///
/// All helpers under test (shouldRotate, rotationPlan, LogRotationPlan) are
/// pure functions with no I/O - no @MainActor needed.
final class LifecycleLogRotationTests: XCTestCase {

    // MARK: - shouldRotate

    func test_shouldRotate_returnsFalse_whenSizeBelowCap() {
        XCTAssertFalse(
            shouldRotate(size: 1_999_999, cap: 2_000_000),
            "log must NOT rotate when it is still under the size cap - premature rotation discards recent forensic data"
        )
    }

    func test_shouldRotate_returnsTrue_whenSizeEqualsCap() {
        XCTAssertTrue(
            shouldRotate(size: 2_000_000, cap: 2_000_000),
            "log must rotate when it reaches the cap - equality is the trigger boundary so the file never grows unbounded"
        )
    }

    func test_shouldRotate_returnsTrue_whenSizeExceedsCap() {
        XCTAssertTrue(
            shouldRotate(size: 3_000_000, cap: 2_000_000),
            "log must rotate when it exceeds the cap - without rotation the log grows forever and exhausts disk space"
        )
    }

    func test_shouldRotate_returnsFalse_whenCapIsZero() {
        // cap == 0 is the disabled sentinel. A zero cap must never trigger
        // rotation regardless of file size, so callers can opt out cleanly.
        XCTAssertFalse(
            shouldRotate(size: 999_999_999, cap: 0),
            "rotation must be disabled when cap is 0 - callers use 0 to opt out without changing call sites"
        )
    }

    func test_shouldRotate_returnsFalse_whenSizeIsZero() {
        XCTAssertFalse(
            shouldRotate(size: 0, cap: 2_000_000),
            "an empty file must not trigger rotation - rotating an empty file wastes I/O and destroys the backup"
        )
    }

    // MARK: - rotationPlan

    func test_rotationPlan_sourceIsOriginalLogURL() {
        let log = URL(fileURLWithPath: "/tmp/diagnostics/lifecycle.log")
        let plan = rotationPlan(for: log)
        XCTAssertEqual(
            plan.source, log,
            "the rotation plan source must be the live log file - any other value would rename the wrong file"
        )
    }

    func test_rotationPlan_backupHasDotOneSuffix() {
        let log = URL(fileURLWithPath: "/tmp/diagnostics/lifecycle.log")
        let plan = rotationPlan(for: log)
        XCTAssertEqual(
            plan.backup.lastPathComponent, "lifecycle.log.1",
            "the backup name must be lifecycle.log.1 so the rotation scheme is deterministic and bounded to one extra file"
        )
    }

    func test_rotationPlan_backupIsInSameDirectory() {
        let log = URL(fileURLWithPath: "/some/dir/lifecycle.log")
        let plan = rotationPlan(for: log)
        XCTAssertEqual(
            plan.backup.deletingLastPathComponent().path,
            log.deletingLastPathComponent().path,
            "the backup must reside in the same directory as the live log - cross-directory moves can fail across volumes"
        )
    }

    func test_rotationPlan_sourceAndBackupAreDifferent() {
        let log = URL(fileURLWithPath: "/tmp/diagnostics/lifecycle.log")
        let plan = rotationPlan(for: log)
        XCTAssertNotEqual(
            plan.source, plan.backup,
            "source and backup must differ - renaming a file onto itself is a no-op and would silently discard the backup"
        )
    }

    // MARK: - AppLifecycleRecorder integration (I/O path)

    private func makeRecorder(cap: Int) -> (AppLifecycleRecorder, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RC2Rotation-" + UUID().uuidString, isDirectory: true)
        return (AppLifecycleRecorder(directory: dir, rotationCapBytes: cap), dir)
    }

    func test_recorder_rotatesWhenLogExceedsCap() throws {
        // Cap is tiny (1 byte) so the very first record triggers rotation on
        // the next append.
        let (recorder, dir) = makeRecorder(cap: 1)
        let logURL = dir.appendingPathComponent("lifecycle.log")
        let backupURL = dir.appendingPathComponent("lifecycle.log.1")

        recorder.record("first_event")
        // After the first record the file exceeds 1 byte. The next append
        // checks size, sees cap exceeded, and rotates before writing.
        recorder.record("second_event_triggers_rotation")

        // The backup must now exist: rotation moved the first log to .1.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: backupURL.path),
            "lifecycle.log.1 must exist after rotation - without it forensic data from the previous rotation window is permanently lost"
        )

        // The live log must also exist (second record written to fresh file).
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: logURL.path),
            "lifecycle.log must still exist after rotation so subsequent records are captured"
        )

        // The backup holds the first event; the live log holds the second.
        let backup = try String(contentsOf: backupURL, encoding: .utf8)
        let live = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(backup.contains("first_event"), "backup must retain data from the rotated window")
        XCTAssertTrue(live.contains("second_event"), "live log must hold data written after rotation")
    }

    func test_recorder_doesNotRotate_whenUnderCap() throws {
        // Cap large enough that no rotation fires for a few short records.
        let (recorder, dir) = makeRecorder(cap: AppLifecycleRecorder.defaultRotationCapBytes)
        let backupURL = dir.appendingPathComponent("lifecycle.log.1")

        recorder.record("event_one")
        recorder.record("event_two")

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: backupURL.path),
            "lifecycle.log.1 must NOT exist when the log has not reached the rotation cap - premature rotation discards forensic data"
        )
    }
}
