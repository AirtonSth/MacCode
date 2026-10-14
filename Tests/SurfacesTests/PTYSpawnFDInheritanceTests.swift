import XCTest
import Darwin
@testable import Surfaces

/// WHY: a forkpty child used to keep every app descriptor that was not
/// close-on-exec at spawn time. Foundation `Pipe()` descriptors are not, so a
/// terminal shell restored while a git probe was running kept that probe's
/// stdout/stderr write ends for its whole life: the app's reader never saw
/// EOF (live: 4 threads parked in read() for 14 h), and every command typed in
/// the terminal inherited app pipes and the lifecycle log. Terminals and the
/// Claude /usage probe share this spawn path, so both are covered here.
final class PTYSpawnFDInheritanceTests: XCTestCase {
    func test_ptyChild_keepsNoAppPipe_soAnAppPipeReaderStillGetsEOF() throws {
        try assertChildHoldsNoAppPipe(suspendedBeforeExec: false)
    }

    func test_suspendedPtyChild_keepsNoAppPipe_soAnAppPipeReaderStillGetsEOF() throws {
        // Terminals that hand the child to Ghostty use the stop-before-exec path.
        try assertChildHoldsNoAppPipe(suspendedBeforeExec: true)
    }

    private func assertChildHoldsNoAppPipe(suspendedBeforeExec: Bool) throws {
        // Open in the parent before the spawn, exactly like a git probe racing
        // a terminal restore.
        let pipe = Pipe()
        let child = TerminalPTYProcessRuntime.spawn(
            cwd: NSTemporaryDirectory(),
            executable: "/bin/sleep",
            arguments: ["sleep", "30"],
            environment: ["PATH": "/usr/bin:/bin"],
            suspendedBeforeExec: suspendedBeforeExec
        )
        XCTAssertGreaterThan(child.pid, 0)
        defer {
            Darwin.close(child.masterFD)
            _ = Darwin.kill(child.pid, SIGKILL)
            var status: Int32 = 0
            _ = Darwin.waitpid(child.pid, &status, 0)
        }
        if suspendedBeforeExec {
            XCTAssertEqual(Darwin.kill(child.pid, SIGCONT), 0)
        }
        XCTAssertTrue(waitForExec(of: child.pid, path: "/bin/sleep", timeout: 2), "child never exec'd")

        let inheritedPipes = pipeDescriptorCount(of: child.pid)
        NSLog("[perf-proof] pty child suspended=%d inherited_pipe_fds=%d", suspendedBeforeExec ? 1 : 0, inheritedPipes)
        XCTAssertEqual(inheritedPipes, 0, "the PTY child must not hold any app pipe")

        // The parent drops its write end (Process does this after launch).
        // With no copy left in the child, the reader must see EOF at once.
        try pipe.fileHandleForWriting.close()
        XCTAssertTrue(
            readsEOF(pipe.fileHandleForReading.fileDescriptor, within: 1),
            "an app pipe reader must not wait for a terminal shell to exit"
        )
    }

    private func waitForExec(of pid: pid_t, path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        while Date() < deadline {
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer) == path {
                return true
            }
            usleep(5_000)
        }
        return false
    }

    private func pipeDescriptorCount(of pid: pid_t) -> Int {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return -1 }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 8)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard filled > 0 else { return -1 }
        return fds.prefix(Int(filled) / stride).filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_PIPE) }.count
    }

    private func readsEOF(_ fd: Int32, within timeout: TimeInterval) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        guard flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else { return false }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&descriptor, 1, Int32(timeout * 1_000)) > 0 else { return false }
        var byte: UInt8 = 0
        return Darwin.read(fd, &byte, 1) == 0
    }
}
