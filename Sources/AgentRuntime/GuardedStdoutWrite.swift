import Foundation
import Darwin

/// Crash-safe stdout writes for wrapper paths (plan-final W1 / CommandWrapRunner).
///
/// `FileHandle.write(_:)` raises an uncatchable Objective-C exception when the
/// consumer closes the pipe. Use raw `write(2)` with `F_SETNOSIGPIPE` instead.
/// EPIPE is a normal downstream close, not a crash.
public enum GuardedStdoutWriteResult: Equatable, Sendable {
    case wroteAll
    case wrotePartial(Int)
    case peerClosed
    case error(errno: Int32)
}

public enum GuardedStdoutWrite {
    /// Classifies a single write(2) attempt against stdout.
    public static func classify(bytesWritten: Int, expected: Int, errnoValue: Int32) -> GuardedStdoutWriteResult {
        if bytesWritten < 0 {
            switch errnoValue {
            case EPIPE, EBADF, ECONNRESET, ENOTCONN, ENXIO:
                return .peerClosed
            default:
                return .error(errno: errnoValue)
            }
        }
        if bytesWritten < expected {
            return .wrotePartial(bytesWritten)
        }
        return .wroteAll
    }

    /// Writes all of `data` to `fd` (typically STDOUT_FILENO). Returns false if
    /// the peer closed early (EPIPE); true if all bytes were delivered.
    @discardableResult
    public static func writeAll(_ data: Data, to fd: Int32 = STDOUT_FILENO) -> Bool {
        guard !data.isEmpty else { return true }
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        var offset = 0
        while offset < data.count {
            let remaining = data.count - offset
            let written: Int = data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.write(fd, base.advanced(by: offset), remaining)
            }
            let capturedErrno = errno
            switch classify(bytesWritten: written, expected: remaining, errnoValue: capturedErrno) {
            case .wroteAll:
                return true
            case .wrotePartial(let n):
                offset += n
            case .peerClosed:
                return false
            case .error(let err):
                if err == EINTR { continue }
                return false
            }
        }
        return true
    }

    /// Returns `value` only after every byte reaches the downstream consumer.
    /// Callers use this to suppress delivery-dependent ledger work after EPIPE.
    public static func deliveredValue<Value>(
        _ value: Value?,
        afterWriting data: Data,
        to fd: Int32 = STDOUT_FILENO
    ) -> Value? {
        writeAll(data, to: fd) ? value : nil
    }
}
