import Foundation

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
                      notFound: () -> Error) throws {
        let fd = fileHandle.fileDescriptor
        var remaining = data
        while !remaining.isEmpty {
            let total = remaining.count
            let written: Int = remaining.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Foundation.write(fd, base, total)
            }
            let capturedErrno = errno
            let classification = classify(processAlive: process.isRunning,
                                          bytesWritten: written,
                                          expected: total,
                                          errnoValue: capturedErrno)
            switch classification {
            case .ok:
                return
            case .sessionNotFound:
                throw notFound()
            case .error:
                if written < 0 {
                    if capturedErrno == EINTR { continue }
                    // Non-EINTR negative write on a (blocking) stdin pipe: treat
                    // as a gone session rather than risking a busy loop.
                    throw notFound()
                }
                // Short write: drop the bytes we managed to send and loop.
                remaining.removeFirst(written)
            }
        }
    }
}
