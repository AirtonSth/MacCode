import Foundation
import Darwin
import os

private let boundedFileLockLog = Logger(
    subsystem: "io.remotecode.persistence",
    category: "file-lock"
)

/// Cross-process advisory locks taken with a deadline instead of an unbounded
/// `F_SETLKW` / `flock(LOCK_EX)` wait. A stuck or suspended peer (a Distill
/// sidecar, a second app instance) can otherwise hold the caller forever.
///
/// The uncontended path is one non-blocking attempt, exactly like before. Under
/// contention the attempt is retried with a short backoff until the deadline;
/// on timeout a `file_lock.timeout` fault is logged and the caller decides
/// whether to proceed unlocked (fail open) or throw.
public enum BoundedFileLock {
    public enum Style: String, Sendable {
        /// `fcntl(F_SETLK)` whole-file write lock.
        case posixRecord
        /// `flock(LOCK_EX)`.
        case flock
    }

    /// What the caller does after a timeout. Only reported in telemetry.
    public enum TimeoutAction: String, Sendable {
        case failOpen = "fail_open"
        case fail
    }

    public enum Outcome: Equatable, Sendable {
        case acquired
        case timedOut(waitedMilliseconds: Int)
        case failed(errno: Int32)
    }

    public static let defaultTimeout: TimeInterval = 2

    public static func acquireExclusive(
        descriptor: Int32,
        style: Style,
        label: String,
        onTimeout: TimeoutAction,
        timeout: TimeInterval = defaultTimeout
    ) -> Outcome {
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start + UInt64(max(0, timeout) * 1_000_000_000)
        var backoffMicroseconds: UInt64 = 1_000
        while true {
            if tryLock(descriptor: descriptor, style: style) { return .acquired }
            let code = errno
            if code == EINTR { continue }
            // fcntl reports a held lock as EAGAIN or EACCES; flock as EWOULDBLOCK.
            guard code == EAGAIN || code == EWOULDBLOCK || code == EACCES else {
                return .failed(errno: code)
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                let waited = Int((now - start) / 1_000_000)
                boundedFileLockLog.fault(
                    "file_lock.timeout label=\(label, privacy: .public) style=\(style.rawValue, privacy: .public) waitedMs=\(waited, privacy: .public) action=\(onTimeout.rawValue, privacy: .public)"
                )
                return .timedOut(waitedMilliseconds: waited)
            }
            let remainingMicroseconds = (deadline - now) / 1_000
            usleep(useconds_t(min(backoffMicroseconds, remainingMicroseconds)))
            backoffMicroseconds = min(backoffMicroseconds * 2, 50_000)
        }
    }

    public static func unlock(descriptor: Int32, style: Style) {
        switch style {
        case .posixRecord:
            var fileLock = wholeFileLock(type: F_UNLCK)
            _ = Darwin.fcntl(descriptor, F_SETLK, &fileLock)
        case .flock:
            _ = flock(descriptor, LOCK_UN)
        }
    }

    private static func tryLock(descriptor: Int32, style: Style) -> Bool {
        switch style {
        case .posixRecord:
            var fileLock = wholeFileLock(type: F_WRLCK)
            return Darwin.fcntl(descriptor, F_SETLK, &fileLock) != -1
        case .flock:
            return flock(descriptor, LOCK_EX | LOCK_NB) == 0
        }
    }

    private static func wholeFileLock(type: Int32) -> Darwin.flock {
        var fileLock = Darwin.flock()
        fileLock.l_start = 0
        fileLock.l_len = 0
        fileLock.l_pid = 0
        fileLock.l_type = Int16(type)
        fileLock.l_whence = Int16(SEEK_SET)
        return fileLock
    }
}
