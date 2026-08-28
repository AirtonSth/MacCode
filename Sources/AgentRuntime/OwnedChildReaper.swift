import Foundation
import Darwin

/// Guarantees terminal waitpid for an owned child (plan-final W1 PTY zombies).
public enum OwnedChildReaper {
    public enum Outcome: Equatable, Sendable {
        case alreadyReaped
        case reaped(exitStatus: Int32)
        case timedOutStillRunning
    }

    /// Poll without blocking. Returns exit status when reaped; nil if still running.
    public static func poll(pid: pid_t) -> Int32? {
        guard pid > 0 else { return 0 }
        var status: Int32 = 0
        let rc = waitpid(pid, &status, WNOHANG)
        if rc == pid { return status }
        if rc < 0, errno == ECHILD { return 0 }
        return nil
    }

    /// Sends TERM, then KILL, then waitpid so the child cannot remain `<defunct>`.
    ///
    /// `waitForZombie` defaults on so callers that own the child drain the
    /// zombie. Usage-refresher PTY probes pass `false`: a child stuck in
    /// uninterruptible sleep must not pin an overlapping refresh forever
    /// (freeze-class: two concurrent `waitpid(0)` on Claude `/usage`).
    @discardableResult
    public static func terminateAndReap(
        pid: pid_t,
        termGrace: TimeInterval = 0.8,
        killGrace: TimeInterval = 0.4,
        waitForZombie: Bool = true
    ) -> Outcome {
        guard pid > 0 else { return .alreadyReaped }

        if let status = poll(pid: pid) {
            return .reaped(exitStatus: status)
        }

        Darwin.kill(pid, SIGTERM)
        if let status = waitUntil(pid: pid, deadline: Date().addingTimeInterval(max(0, termGrace))) {
            return .reaped(exitStatus: status)
        }

        Darwin.kill(pid, SIGKILL)
        if let status = waitUntil(pid: pid, deadline: Date().addingTimeInterval(max(0, killGrace))) {
            return .reaped(exitStatus: status)
        }

        guard waitForZombie else { return .timedOutStillRunning }

        // Final blocking wait — zombies exist only until waitpid.
        var status: Int32 = 0
        let rc = waitpid(pid, &status, 0)
        if rc == pid {
            return .reaped(exitStatus: status)
        }
        if rc < 0, errno == ECHILD {
            return .alreadyReaped
        }
        return .timedOutStillRunning
    }

    private static func waitUntil(pid: pid_t, deadline: Date) -> Int32? {
        while Date() < deadline {
            if let status = poll(pid: pid) {
                return status
            }
            usleep(50_000)
        }
        return poll(pid: pid)
    }
}
