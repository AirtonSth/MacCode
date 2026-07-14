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

    private enum State: Equatable {
        case open
        case terminalReserved
        case terminalQueued
        case terminalSent
        case closed
    }

    private let queue: DispatchQueue
    private let maxQueuedBytes: Int
    private let lock = NSLock()
    private var queuedBytes = 0
    private var state: State = .open
    private let applicationWriter: @Sendable (Data) -> Bool
    private let controlWriter: @Sendable (UInt8, Data) -> Bool
    private let writeFailureClosingData: Data
    private let onTerminal: @Sendable (String) -> Void
    private let didSendTerminal: @Sendable () -> Void
    private let acceptedSubmissionHook: @Sendable () -> Void
    private let terminationAttemptHook: @Sendable () -> Void

    init(
        label: String = "rc2.ws.outbound",
        maxQueuedBytes: Int = 1024 * 1024,
        applicationWriter: @escaping @Sendable (Data) -> Bool,
        controlWriter: @escaping @Sendable (UInt8, Data) -> Bool,
        writeFailureClosingData: Data,
        onTerminal: @escaping @Sendable (String) -> Void,
        didSendTerminal: @escaping @Sendable () -> Void,
        acceptedSubmissionHook: @escaping @Sendable () -> Void = {},
        terminationAttemptHook: @escaping @Sendable () -> Void = {}
    ) {
        self.queue = DispatchQueue(label: label)
        self.maxQueuedBytes = max(1, maxQueuedBytes)
        self.applicationWriter = applicationWriter
        self.controlWriter = controlWriter
        self.writeFailureClosingData = writeFailureClosingData
        self.onTerminal = onTerminal
        self.didSendTerminal = didSendTerminal
        self.acceptedSubmissionHook = acceptedSubmissionHook
        self.terminationAttemptHook = terminationAttemptHook
    }

    convenience init(
        label: String = "rc2.ws.outbound",
        maxQueuedBytes: Int = 1024 * 1024,
        writer: @escaping @Sendable (Data) -> Bool,
        onClose: @escaping @Sendable (String) -> Void
    ) {
        self.init(
            label: label,
            maxQueuedBytes: maxQueuedBytes,
            applicationWriter: writer,
            controlWriter: { _, _ in true },
            writeFailureClosingData: Data(),
            onTerminal: onClose,
            didSendTerminal: {}
        )
    }

    var queuedByteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return queuedBytes
    }

    func enqueue(_ data: Data) -> EnqueueResult {
        let result = enqueueApplication(data)
        if result == .queueFull {
            _ = terminate(errorData: nil, closingData: nil, reason: "queue_full")
        }
        return result
    }

    func enqueueApplication(_ data: Data) -> EnqueueResult {
        guard !data.isEmpty else { return .accepted }
        lock.lock()
        guard state == .open else {
            lock.unlock()
            return .closed
        }
        guard queuedBytes + data.count <= maxQueuedBytes else {
            state = .terminalReserved
            lock.unlock()
            return .queueFull
        }
        queuedBytes += data.count
        acceptedSubmissionHook()
        queue.async { [weak self] in self?.writeApplication(data) }
        lock.unlock()
        return .accepted
    }

    func enqueueControl(opcode: UInt8, data: Data) -> EnqueueResult {
        lock.lock()
        guard state == .open else {
            lock.unlock()
            return .closed
        }
        acceptedSubmissionHook()
        queue.async { [weak self] in self?.writeControl(opcode: opcode, data: data) }
        lock.unlock()
        return .accepted
    }

    @discardableResult
    func terminate(errorData: Data?, closingData: Data?, reason: String) -> Bool {
        terminationAttemptHook()
        lock.lock()
        guard state == .open || state == .terminalReserved else {
            lock.unlock()
            return false
        }
        state = .terminalQueued
        lock.unlock()

        onTerminal(reason)
        queue.async { [weak self] in
            guard let self, self.beginQueuedTerminalSend() else { return }
            if let errorData { _ = self.controlWriter(0x1, errorData) }
            if let closingData { _ = self.controlWriter(0x1, closingData) }
            _ = self.controlWriter(0x8, Data())
            self.didSendTerminal()
        }
        return true
    }

    func close() {
        lock.lock()
        if state == .open || state == .terminalReserved { state = .closed }
        lock.unlock()
    }

    func drain() {
        finish()
    }

    func finish() {
        queue.sync {}
    }

    private func writeApplication(_ data: Data) {
        guard shouldWriteQueuedItem() else {
            removeQueuedBytes(data.count)
            return
        }
        let succeeded = applicationWriter(data)
        removeQueuedBytes(data.count)
        if !succeeded { terminateImmediatelyAfterWriteFailure() }
    }

    private func writeControl(opcode: UInt8, data: Data) {
        guard shouldWriteQueuedItem() else { return }
        if !controlWriter(opcode, data) { terminateImmediatelyAfterWriteFailure() }
    }

    private func shouldWriteQueuedItem() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state != .terminalSent && state != .closed
    }

    private func beginQueuedTerminalSend() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == .terminalQueued else { return false }
        state = .terminalSent
        return true
    }

    private func removeQueuedBytes(_ count: Int) {
        lock.lock()
        queuedBytes = max(0, queuedBytes - count)
        lock.unlock()
    }

    private func terminateImmediatelyAfterWriteFailure() {
        lock.lock()
        guard state != .terminalSent && state != .closed else {
            lock.unlock()
            return
        }
        state = .terminalSent
        lock.unlock()
        onTerminal("write_failed")
        _ = controlWriter(0x1, writeFailureClosingData)
        _ = controlWriter(0x8, Data())
        didSendTerminal()
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
