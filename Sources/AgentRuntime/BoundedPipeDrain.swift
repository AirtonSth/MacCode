import Foundation
import Darwin

/// Drains bytes already buffered in a provider pipe without waiting forever
/// for descendants that inherited the write descriptor. The read descriptor is
/// always closed at EOF or at the deadline so crash teardown is bounded.
///
/// When `maxBytes` is set, only the first N bytes are retained; remaining
/// pipe data is still drained (discarded) so a verbose child cannot block.
enum BoundedPipeDrain {
    static let defaultTimeout: TimeInterval = 0.25
    /// Retention cap for provider stdout teardown. Remaining pipe bytes are
    /// still drained (discarded) so a verbose child cannot block.
    static let defaultStdoutMaxBytes = 2 * 1_024 * 1_024
    /// Retention cap for provider stderr teardown.
    static let defaultStderrMaxBytes = 1 * 1_024 * 1_024

    static func readRemaining(
        from handle: FileHandle,
        timeout: TimeInterval = defaultTimeout,
        maxBytes: Int = defaultStdoutMaxBytes
    ) -> Data {
        let fd = handle.fileDescriptor
        defer { try? handle.close() }

        let originalFlags = fcntl(fd, F_GETFL)
        guard originalFlags != -1,
              fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) != -1 else {
            return Data()
        }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        let cap = max(0, maxBytes)
        var result = Data()
        if cap > 0 && cap < Int.max {
            result.reserveCapacity(min(cap, 64 * 1024))
        }
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)

        while true {
            // Absolute deadline checked on every loop (including after successful reads)
            // so a continuously writing descendant cannot allocate forever.
            guard Date() < deadline else { return result }

            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                if result.count < cap {
                    let room = cap - result.count
                    if count <= room {
                        result.append(contentsOf: buffer.prefix(count))
                    } else {
                        result.append(contentsOf: buffer.prefix(room))
                        // Keep draining (discard) past the cap.
                    }
                }
                continue
            }
            if count == 0 { return result }
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { return result }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return result }
            let milliseconds = Int32(min(Double(Int32.max), ceil(remaining * 1_000)))
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&descriptor, 1, max(1, milliseconds))
            if pollResult == 0 { return result }
            if pollResult < 0 {
                if errno == EINTR { continue }
                return result
            }
            if descriptor.revents & Int16(POLLNVAL) != 0 { return result }
            // POLLHUP may still have buffered bytes. Loop once more and read
            // until read(2) returns EOF or deadline.
        }
    }
}

/// Tells a pipe drain when to give up waiting for EOF: once the root process
/// has exited, drain only for `BoundedPipeDrain.defaultTimeout` more, so a
/// descendant that kept the write end cannot pin the reading thread.
final class PipeDrainControl: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: Date?

    func finishRoot() {
        lock.lock()
        deadline = Date().addingTimeInterval(BoundedPipeDrain.defaultTimeout)
        lock.unlock()
    }

    var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return deadline.map { Date() >= $0 } ?? false
    }
}
