import Foundation
import Darwin

/// Drains bytes already buffered in a provider pipe without waiting forever
/// for descendants that inherited the write descriptor. The read descriptor is
/// always closed at EOF or at the deadline so crash teardown is bounded.
enum BoundedPipeDrain {
    static let defaultTimeout: TimeInterval = 0.25

    static func readRemaining(
        from handle: FileHandle,
        timeout: TimeInterval = defaultTimeout
    ) -> Data {
        let fd = handle.fileDescriptor
        defer { try? handle.close() }

        let originalFlags = fcntl(fd, F_GETFL)
        guard originalFlags != -1,
              fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) != -1 else {
            return Data()
        }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)

        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                result.append(contentsOf: buffer.prefix(count))
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
            // until read(2) returns EOF.
        }
    }
}
