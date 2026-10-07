import Foundation
import Darwin

/// Single-instance guard for one App Support directory (S-F8).
///
/// A second process that opens the same App Support shares the database,
/// diagnostics and run marker, so it flags a live run as unclean and adds
/// SQLite writer contention. The lock is a non-blocking exclusive `flock` on
/// `<AppSupport>/.instance.lock`; the kernel drops it when the holder exits or
/// crashes, so it never goes stale. The fd is `O_CLOEXEC` so provider and
/// terminal children cannot keep the lock alive after the app dies.
public final class AppInstanceLock {
    public enum Outcome {
        /// This process owns the App Support directory until it exits.
        case acquired(AppInstanceLock)
        /// Another live process holds the lock. `holderPID` is read from the
        /// lock file when the holder wrote it.
        case heldByOther(holderPID: pid_t?)
        /// The lock file could not be opened or locked for another reason.
        /// Callers fail open: refusing to launch on an I/O error is worse than
        /// the contention the lock prevents.
        case unavailable(errno: Int32)
    }

    public static let fileName = ".instance.lock"

    private let fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        close(fd)
    }

    public static func acquire(directory: URL, pid: pid_t = getpid()) -> Outcome {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(fileName).path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return .unavailable(errno: errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            let holder = code == EWOULDBLOCK ? readHolderPID(fd: fd) : nil
            close(fd)
            return code == EWOULDBLOCK ? .heldByOther(holderPID: holder) : .unavailable(errno: code)
        }
        let line = "pid=\(pid)\n"
        _ = ftruncate(fd, 0)
        _ = line.withCString { pwrite(fd, $0, strlen($0), 0) }
        return .acquired(AppInstanceLock(fd: fd))
    }

    private static func readHolderPID(fd: Int32) -> pid_t? {
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        let text = String(decoding: buffer[0..<count], as: UTF8.self)
        guard let range = text.range(of: "pid=") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return pid_t(digits)
    }
}
