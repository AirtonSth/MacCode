import XCTest
import Darwin
@testable import Surfaces

/// GhosttyKit's embedded Sentry/Breakpad takes over the task exception ports and
/// SIGABRT, then turns a native crash into a silent `_exit(exception_type)`: the
/// app "closes by itself" with no `.ips` report (pid 60220 exited with exit(1)
/// after 9.7 h and left nothing to diagnose). Restoring the snapshot taken
/// before Ghostty starts must hand every crash handler back to macOS.
final class NativeCrashHandlerSnapshotTests: XCTestCase {
    func testRestoreUndoesAReporterThatTookOverExceptionPortsAndSIGABRT() throws {
        let before = NativeCrashHandlerSnapshot.capture()
        defer { before.restore() }

        // What Breakpad does: its own port for the crash exceptions, its own SIGABRT handler.
        var port = mach_port_t()
        XCTAssertEqual(mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port), KERN_SUCCESS)
        defer { mach_port_destruct(mach_task_self_, port, -1, 0) }
        XCTAssertEqual(
            mach_port_insert_right(mach_task_self_, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)),
            KERN_SUCCESS
        )
        XCTAssertEqual(
            task_set_exception_ports(
                mach_task_self_, exception_mask_t(EXC_MASK_BAD_ACCESS | EXC_MASK_BREAKPOINT),
                port, EXCEPTION_DEFAULT, THREAD_STATE_NONE
            ),
            KERN_SUCCESS
        )
        var reporter = sigaction()
        reporter.__sigaction_u.__sa_handler = { _ in }
        XCTAssertEqual(sigaction(SIGABRT, &reporter, nil), 0)

        let taken = NativeCrashHandlerSnapshot.capture()
        XCTAssertNotEqual(taken.exceptionPorts, before.exceptionPorts, "the snapshot must see a replaced exception port")
        XCTAssertNotEqual(taken.signals, before.signals, "the snapshot must see a replaced SIGABRT handler")

        before.restore()

        let after = NativeCrashHandlerSnapshot.capture()
        XCTAssertEqual(after, before, "the host's crash handlers must be back exactly as they were")
        XCTAssertFalse(after.exceptionPorts.contains { $0.port == port }, "the reporter's port must not survive")
    }

    /// The real GhosttyKit: proves its init replaces the crash handlers (the
    /// premise of the fix) and that the runtime puts them back.
    @MainActor
    func testGhosttyInitReplacesCrashHandlersAndTheRuntimeRestoresThem() throws {
        guard ProcessInfo.processInfo.environment["RC2_ENABLE_GHOSTTY_IN_TESTS"] == "1" else {
            throw XCTSkip("run with RC2_ENABLE_GHOSTTY_IN_TESTS=1 to initialize the real GhosttyKit")
        }
        _ = GhosttyTerminalView.resolvedANSIThemeColors()

        let report = try XCTUnwrap(GhosttyCrashHandlerGuard.lastReport, "the runtime must initialize through the guard")
        XCTAssertTrue(report.changedDuringInit, "GhosttyKit's crash reporter was expected to install handlers")
        XCTAssertTrue(report.restored, "the host's crash handlers must be restored after Ghostty starts")
    }
}
