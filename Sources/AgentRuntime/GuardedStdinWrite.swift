import Foundation
import Darwin

// P1: Safe stdin writes (crash vector).
//
// FileHandle.write(_:) raises an uncatchable Objective-C exception when the
// underlying pipe has been closed (the child process died), which crashes the
// whole app. Writers must instead use a guarded path that (a) checks the
// process is alive and (b) performs a throwing write, converting EPIPE / closed
// file descriptor conditions into a typed sessionNotFound error.
//
// The classification logic is extracted here as a pure function so it can be
// unit tested without spawning processes or touching real pipes.

/// Outcome of classifying a single stdin write attempt.
enum StdinWriteClassification: Equatable {
    /// All bytes were written; nothing to do.
    case ok
    /// The peer is gone (process dead, EPIPE, or bad/closed fd). Callers should
    /// surface this as AgentProviderAdapterError.sessionNotFound rather than
    /// crashing.
    case sessionNotFound
    /// A different, non-fatal write failure (e.g. short write, EINTR/EAGAIN).
    /// Callers should retry the remaining bytes or surface a generic error.
    case error
}

enum GuardedStdinWriteError: Error, LocalizedError, Equatable {
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timedOut(let timeout):
            return "Provider stdin did not become writable within \(timeout)s."
        }
    }
}

enum GuardedStdinWrite {
    /// Classifies the result of a low-level write attempt.
    ///
    /// - Parameters:
    ///   - processAlive: whether the child process was observed to be running
    ///     immediately before the write. A dead process means the pipe is
    ///     closed and any write would raise SIGPIPE / EPIPE.
    ///   - bytesWritten: the return value of `write(2)` (or the count of bytes
    ///     accepted by `FileHandle.write(contentsOf:)`). Negative means the
    ///     syscall failed and `errnoValue` is meaningful.
    ///   - expected: the number of bytes the caller intended to write (> 0).
    ///   - errnoValue: `errno` captured immediately after a failed write
    ///     (`bytesWritten < 0`). Ignored when `bytesWritten >= 0`.
    /// - Returns: how the caller should treat this write.
    static func classify(processAlive: Bool,
                         bytesWritten: Int,
                         expected: Int,
                         errnoValue: Int32) -> StdinWriteClassification {
        // A dead process guarantees a closed pipe: never attempt the write.
        if !processAlive {
            return .sessionNotFound
        }
        if bytesWritten < 0 {
            switch errnoValue {
            case EPIPE, EBADF, ECONNRESET, ENOTCONN, ENXIO:
                // Peer closed / fd invalid: the session is gone.
                return .sessionNotFound
            default:
                // EINTR, EAGAIN, ENOSPC, etc. are transient/generic failures.
                return .error
            }
        }
        if bytesWritten < expected {
            // Short write: not fatal, but not complete either. Caller must
            // handle the remainder; treat as a generic error for now.
            return .error
        }
        return .ok
    }

    /// Performs a crash-safe write of `data` to `fileHandle`, which is the
    /// writing end of `process`'s stdin pipe.
    ///
    /// Uses the raw `write(2)` syscall (looping over short writes / EINTR)
    /// instead of `FileHandle.write(_:)`, which raises an uncatchable
    /// Objective-C exception on a closed pipe. On EPIPE / closed fd / dead
    /// process it throws `AgentProviderAdapterError.sessionNotFound(threadId)`.
    /// - Parameter notFound: factory for the typed "session is gone" error to
    ///   throw on EPIPE / closed fd / dead process. Adapters pass
    ///   `.sessionNotFound`; the Codex transport passes `.processExited`.
    static func write(_ data: Data,
                      to fileHandle: FileHandle,
                      process: Process,
                      timeout: TimeInterval = 5,
                      notFound: () -> Error) throws {
        let fd = fileHandle.fileDescriptor
        // `process.isRunning` can become false after the check but before the
        // syscall. Suppress SIGPIPE on this descriptor so that race becomes a
        // catchable EPIPE instead of terminating the host process.
        guard fcntl(fd, F_SETNOSIGPIPE, 1) != -1 else { throw notFound() }
        let originalFlags = fcntl(fd, F_GETFL)
        guard originalFlags != -1,
              fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) != -1 else {
            throw notFound()
        }
        defer { _ = fcntl(fd, F_SETFL, originalFlags) }

        let boundedTimeout = max(0, timeout)
        let deadline = Date().addingTimeInterval(boundedTimeout)
        var offset = 0
        while offset < data.count {
            guard process.isRunning else { throw notFound() }
            guard Date() < deadline else {
                throw GuardedStdinWriteError.timedOut(boundedTimeout)
            }
            let remainingCount = data.count - offset
            let written: Int = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.write(fd, base.advanced(by: offset), remainingCount)
            }
            let capturedErrno = errno
            let classification = classify(processAlive: process.isRunning,
                                          bytesWritten: written,
                                          expected: remainingCount,
                                          errnoValue: capturedErrno)
            switch classification {
            case .ok:
                return
            case .sessionNotFound:
                throw notFound()
            case .error:
                if written < 0 {
                    if capturedErrno == EINTR { continue }
                    if capturedErrno == EAGAIN || capturedErrno == EWOULDBLOCK {
                        try waitUntilWritable(
                            fd: fd,
                            deadline: deadline,
                            timeout: boundedTimeout,
                            notFound: notFound
                        )
                        continue
                    }
                    throw notFound()
                }
                // A nonblocking pipe can accept a prefix. Continue from the
                // exact byte offset without copying the remaining payload.
                offset += written
            }
        }
    }

    private static func waitUntilWritable(
        fd: Int32,
        deadline: Date,
        timeout: TimeInterval,
        notFound: () -> Error
    ) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw GuardedStdinWriteError.timedOut(timeout) }
            let milliseconds = Int32(min(Double(Int32.max), ceil(remaining * 1_000)))
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let result = Darwin.poll(&descriptor, 1, max(1, milliseconds))
            if result > 0 {
                let terminalEvents = Int16(POLLERR | POLLHUP | POLLNVAL)
                if descriptor.revents & terminalEvents != 0 { throw notFound() }
                if descriptor.revents & Int16(POLLOUT) != 0 { return }
                continue
            }
            if result == 0 { throw GuardedStdinWriteError.timedOut(timeout) }
            if errno == EINTR { continue }
            throw notFound()
        }
    }
}
