import Foundation
import Darwin

/// Pure write-loop helper for the rc2 CLI.
///
/// WHY: a single Darwin.write(fd, buf, count) call is not guaranteed to write
/// all bytes - it returns the number actually written, which may be less than
/// requested (short write).  Ignoring the return value truncates large payloads
/// (e.g. long send-text bodies).  This helper retries until all bytes are sent
/// or a hard error occurs.
public enum RC2CLIWriteLoop {

    /// Result of a write-loop attempt.
    public struct WriteResult: Equatable {
        /// Total bytes written across all iterations. Always <= total.
        public let bytesWritten: Int
        /// Total bytes requested.
        public let total: Int
        /// Whether all bytes were written successfully.
        public var success: Bool { bytesWritten == total }

        public init(bytesWritten: Int, total: Int) {
            self.bytesWritten = bytesWritten
            self.total = total
        }
    }

    /// Write all bytes in `data` to `fd`, looping on short writes.
    ///
    /// - Parameters:
    ///   - fd:   An open file descriptor.
    ///   - data: Bytes to write.
    ///   - writeFn: Injected write function; defaults to Darwin.write so that
    ///              tests can substitute a controlled implementation.
    /// - Returns: A `WriteResult` describing total written vs total requested.
    public static func writeAll(
        fd: Int32,
        data: Data,
        writeFn: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
    ) -> WriteResult {
        let total = data.count
        guard total > 0 else { return WriteResult(bytesWritten: 0, total: 0) }
        var written = 0
        let result = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else { return 0 }
            while written < total {
                let n = writeFn(fd, base.advanced(by: written), total - written)
                if n <= 0 { break }
                written += n
            }
            return written
        }
        return WriteResult(bytesWritten: result, total: total)
    }
}
