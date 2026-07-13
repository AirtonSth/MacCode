import Foundation
import Darwin

/// Serializes complete WebSocket frames for one TCP connection.
///
/// Application frames are written by `WebSocketOutboundQueue`, while pong and
/// close frames are produced by the receive loop. Both paths share this writer
/// so bytes from two frames can never interleave on the socket.
final class WebSocketConnectionWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let writeFrame: @Sendable (UInt8, Data) -> Bool

    init(writeFrame: @escaping @Sendable (UInt8, Data) -> Bool) {
        self.writeFrame = writeFrame
    }

    func send(opcode: UInt8, data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return writeFrame(opcode, data)
    }
}

final class WebSocketOutboundQueue: @unchecked Sendable {
    enum EnqueueResult: Equatable {
        case accepted
        case queueFull
        case closed
    }

    private let queue: DispatchQueue
    private let maxQueuedBytes: Int
    private let lock = NSLock()
    private var queuedBytes = 0
    private var closed = false
    private let writer: @Sendable (Data) -> Bool
    private let onClose: @Sendable (String) -> Void

    init(
        label: String = "rc2.ws.outbound",
        maxQueuedBytes: Int = 1024 * 1024,
        writer: @escaping @Sendable (Data) -> Bool,
        onClose: @escaping @Sendable (String) -> Void
    ) {
        self.queue = DispatchQueue(label: label)
        self.maxQueuedBytes = max(1, maxQueuedBytes)
        self.writer = writer
        self.onClose = onClose
    }

    var queuedByteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return queuedBytes
    }

    func enqueue(_ data: Data) -> EnqueueResult {
        guard !data.isEmpty else { return .accepted }
        lock.lock()
        if closed {
            lock.unlock()
            return .closed
        }
        guard queuedBytes + data.count <= maxQueuedBytes else {
            closed = true
            lock.unlock()
            onClose("queue_full")
            return .queueFull
        }
        queuedBytes += data.count
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let ok = self.writer(data)
            self.lock.lock()
            self.queuedBytes = max(0, self.queuedBytes - data.count)
            if !ok { self.closed = true }
            self.lock.unlock()
            if !ok {
                self.onClose("write_failed")
            }
        }
        return .accepted
    }

    func drain() {
        queue.sync {}
    }
}

final class LockedSubscriberID: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: UUID?

    var value: UUID? {
        get {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock(); storage = newValue; lock.unlock()
        }
    }
}
