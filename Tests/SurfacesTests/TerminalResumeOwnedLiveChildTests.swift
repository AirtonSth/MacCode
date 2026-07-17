import Darwin
import XCTest

@testable import Surfaces

final class TerminalResumeOwnedLiveChildTests: XCTestCase {
    func test_resumeRetriesUnavailablePostSignalStatusAndFailsClosed() throws {
        // WHY: WEXITED-only waitid reports a stopped owned child as alive with no
        // event. Without a fresh proc snapshot, that is not proof SIGCONT landed.
        try withSuspendedChild { pid in
            var processStatusReadCount = 0
            let startedAt = DispatchTime.now().uptimeNanoseconds

            let resumed = TerminalPTYProcessRuntime.resumeOwnedLiveChild(
                pid: pid,
                processStatusReader: { requestedPID in
                    XCTAssertEqual(requestedPID, pid)
                    processStatusReadCount += 1
                    if processStatusReadCount == 1 {
                        return .snapshot(
                            parentPID: UInt32(getpid()),
                            status: UInt32(SSTOP)
                        )
                    }
                    if processStatusReadCount == 2 {
                        XCTAssertTrue(
                            self.waitUntilRunning(pid),
                            "fixture must drain SIGCONT before injecting an ambiguous status read"
                        )
                    }
                    return .unavailable
                }
            )
            let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt

            XCTAssertFalse(
                resumed,
                "ambiguous WEXITED alive observations must not prove post-SIGCONT progress"
            )
            XCTAssertGreaterThan(
                processStatusReadCount,
                2,
                "unavailable post-signal status must retry until the existing deadline"
            )
            XCTAssertGreaterThanOrEqual(
                elapsed,
                900_000_000,
                "ambiguous status must not fail or succeed before the existing deadline"
            )
            XCTAssertLessThan(
                elapsed,
                2_000_000_000,
                "post-signal verification must not expand the existing one-second timeout"
            )
        }
    }

    func test_resumeSucceedsOnlyAfterFreshSameParentNonStoppedSnapshot() throws {
        // WHY: SIGCONT success is asynchronous. The resume contract needs a fresh
        // same-parent snapshot that has left SSTOP before ownership can transfer.
        try withSuspendedChild { pid in
            var processStatusReadCount = 0

            let resumed = TerminalPTYProcessRuntime.resumeOwnedLiveChild(
                pid: pid,
                processStatusReader: { requestedPID in
                    XCTAssertEqual(requestedPID, pid)
                    processStatusReadCount += 1
                    switch processStatusReadCount {
                    case 1, 2:
                        return .snapshot(
                            parentPID: UInt32(getpid()),
                            status: UInt32(SSTOP)
                        )
                    default:
                        return .snapshot(
                            parentPID: UInt32(getpid()),
                            status: UInt32(SRUN)
                        )
                    }
                }
            )

            XCTAssertTrue(resumed)
            XCTAssertEqual(
                processStatusReadCount,
                3,
                "resume must reuse the injected status reader after SIGCONT"
            )
        }
    }

    func test_resumeRejectsFreshWrongParentAndZombieSnapshots() throws {
        // WHY: either state means the numeric PID is not a resumable live child.
        // Returning success could attach a replacement terminal to stale ownership.
        let rejectedSnapshots: [TerminalPTYProcessRuntime.OwnedProcessStatusSnapshot] = [
            .snapshot(parentPID: UInt32(getpid()) + 1, status: UInt32(SRUN)),
            .snapshot(parentPID: UInt32(getpid()), status: UInt32(SZOMB)),
        ]

        for rejectedSnapshot in rejectedSnapshots {
            try withSuspendedChild { pid in
                var processStatusReadCount = 0

                let resumed = TerminalPTYProcessRuntime.resumeOwnedLiveChild(
                    pid: pid,
                    processStatusReader: { requestedPID in
                        XCTAssertEqual(requestedPID, pid)
                        processStatusReadCount += 1
                        if processStatusReadCount == 1 {
                            return .snapshot(
                                parentPID: UInt32(getpid()),
                                status: UInt32(SSTOP)
                            )
                        }
                        return rejectedSnapshot
                    }
                )

                XCTAssertFalse(resumed)
                XCTAssertEqual(
                    processStatusReadCount,
                    2,
                    "a definitive post-signal ownership or liveness failure must fail immediately"
                )
            }
        }
    }

    private func withSuspendedChild(_ body: (pid_t) throws -> Void) throws {
        let child = TerminalPTYProcessRuntime.spawn(
            cwd: NSTemporaryDirectory(),
            executable: "/bin/sleep",
            arguments: ["sleep", "30"],
            environment: ["PATH": "/usr/bin:/bin"],
            suspendedBeforeExec: true
        )
        guard child.pid > 0, child.masterFD >= 0 else {
            if child.masterFD >= 0 { Darwin.close(child.masterFD) }
            XCTFail("suspended PTY child fixture failed errno=\(errno)")
            return
        }
        defer {
            Darwin.close(child.masterFD)
            _ = Darwin.kill(child.pid, SIGKILL)
            var status: Int32 = 0
            while Darwin.waitpid(child.pid, &status, 0) < 0, errno == EINTR {}
        }

        try body(child.pid)
    }

    private func waitUntilRunning(_ pid: pid_t) -> Bool {
        waitForProcessStatus(pid) {
            $0 != UInt32(SSTOP) && $0 != UInt32(SZOMB)
        }
    }

    private func waitForProcessStatus(
        _ pid: pid_t,
        matching predicate: (UInt32) -> Bool
    ) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 100_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            var processInfo = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &processInfo, size) == size,
               processInfo.pbi_ppid == UInt32(getpid()),
               predicate(processInfo.pbi_status) {
                return true
            }
            usleep(500)
        }
        return false
    }
}
