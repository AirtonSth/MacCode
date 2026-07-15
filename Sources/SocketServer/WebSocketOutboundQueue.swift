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
    // Pending frames are buffered here so the serial drain can prioritize
    // control frames (pong/ping/close) over queued application data. A pong
    // stuck behind up to 1 MiB of event frames on a slow uplink would miss the
    // client's pong deadline and kill a healthy connection. Each enqueue still
    // dispatches exactly one drain token; only the pick order changes.
    private var pendingApplicationFrames: [Data] = []
    private var pendingControlFrames: [(opcode: UInt8, data: Data)] = []
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
        pendingApplicationFrames.append(data)
        acceptedSubmissionHook()
        queue.async { [weak self] in self?.writeNextPendingFrame() }
        lock.unlock()
        return .accepted
    }

    func enqueueControl(opcode: UInt8, data: Data) -> EnqueueResult {
        lock.lock()
        guard state == .open else {
            lock.unlock()
            return .closed
        }
        pendingControlFrames.append((opcode: opcode, data: data))
        acceptedSubmissionHook()
        queue.async { [weak self] in self?.writeNextPendingFrame() }
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

    /// Runs once per enqueued frame on the serial queue. Control frames are
    /// drained before pending application frames; an application frame whose
    /// write already started is never preempted (RFC 6455 frames must not
    /// interleave), so a pong waits only for the frame in progress.
    private func writeNextPendingFrame() {
        lock.lock()
        if !pendingControlFrames.isEmpty {
            let control = pendingControlFrames.removeFirst()
            lock.unlock()
            writeControl(opcode: control.opcode, data: control.data)
            return
        }
        guard !pendingApplicationFrames.isEmpty else {
            lock.unlock()
            return
        }
        let data = pendingApplicationFrames.removeFirst()
        lock.unlock()
        writeApplication(data)
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

enum ConnectionSequenceRecordResult: Equatable {
    case advanced
    case bufferedForSnapshot
    case coveredBySnapshot
    case gap(expected: Int64, received: Int64)
}

enum ConnectionSnapshotAdoptionResult: Equatable {
    case adopted(sequence: Int64)
    case gap(expected: Int64, received: Int64)
}

final class ConnectionSequenceWatermark: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: Int64
    private var snapshotCoveredThrough: Int64 = 0
    private var snapshotInFlight = false
    private var pendingSequences = Set<Int64>()

    init(initialSequence: Int64) {
        self.sequence = max(0, initialSequence)
    }

    var value: Int64 {
        lock.lock(); defer { lock.unlock() }
        return sequence
    }

    func beginSnapshot() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !snapshotInFlight else { return false }
        snapshotInFlight = true
        pendingSequences.removeAll(keepingCapacity: true)
        return true
    }

    /// Re-anchors the gap expectation when replay expiry re-anchors the
    /// delivery cursor to the live head. Advance-only, so a snapshot adopted
    /// concurrently (or live events recorded meanwhile) is never rolled back.
    func reanchorForExpiredReplay(sequence next: Int64) {
        lock.lock()
        if next > sequence {
            sequence = next
            drainPendingLocked()
        }
        lock.unlock()
    }

    func recordEnqueuedEvent(sequence next: Int64) -> ConnectionSequenceRecordResult {
        lock.lock(); defer { lock.unlock() }
        if next == sequence + 1 {
            sequence = next
            drainPendingLocked()
            return .advanced
        }
        if next <= snapshotCoveredThrough {
            return .coveredBySnapshot
        }
        if snapshotInFlight, next > sequence + 1 {
            pendingSequences.insert(next)
            return .bufferedForSnapshot
        }
        return .gap(expected: sequence + 1, received: next)
    }

    /// Accounts for a seq the connection's negotiated filter dropped: the
    /// event was never sent, so the gap expectation must advance past it
    /// without a frame. A filtered seq can be recorded ahead of an earlier
    /// kept event still crossing the batcher, so out-of-order seqs are
    /// buffered and drained once the kept event advances the watermark. A
    /// hole the filter cannot account for is left for the next enqueued
    /// event to report as a gap.
    func recordFilteredEvent(sequence next: Int64) {
        lock.lock()
        if next == sequence + 1 {
            sequence = next
            drainPendingLocked()
        } else if next > sequence, next > snapshotCoveredThrough {
            pendingSequences.insert(next)
        }
        lock.unlock()
    }

    func adoptSnapshot(sequence next: Int64) -> ConnectionSnapshotAdoptionResult {
        lock.lock(); defer { lock.unlock() }
        guard snapshotInFlight else {
            return .gap(expected: sequence + 1, received: next)
        }
        var candidateSequence = max(sequence, next)
        var remaining = pendingSequences.filter { $0 > candidateSequence }
        while remaining.remove(candidateSequence + 1) != nil {
            candidateSequence += 1
        }
        snapshotInFlight = false
        if let received = remaining.min() {
            pendingSequences.removeAll(keepingCapacity: true)
            return .gap(expected: candidateSequence + 1, received: received)
        }
        sequence = candidateSequence
        snapshotCoveredThrough = max(snapshotCoveredThrough, next)
        pendingSequences.removeAll(keepingCapacity: true)
        return .adopted(sequence: sequence)
    }

    func cancelSnapshot() {
        lock.lock()
        snapshotInFlight = false
        pendingSequences.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func drainPendingLocked() {
        while pendingSequences.remove(sequence + 1) != nil {
            sequence += 1
        }
    }
}

final class ActiveWebSocketConnectionRegistry: @unchecked Sendable {
    private struct Entry {
        let ownerFingerprint: String
        let watermark: ConnectionSequenceWatermark
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func insert(
        _ connectionID: String,
        ownerFingerprint: String,
        watermark: ConnectionSequenceWatermark
    ) {
        lock.lock()
        entries[connectionID] = Entry(ownerFingerprint: ownerFingerprint, watermark: watermark)
        lock.unlock()
    }

    func watermark(
        for connectionID: String,
        ownerFingerprint: String
    ) -> ConnectionSequenceWatermark? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[connectionID],
              entry.ownerFingerprint == ownerFingerprint else {
            return nil
        }
        return entry.watermark
    }

    func remove(_ connectionID: String) {
        lock.lock(); entries.removeValue(forKey: connectionID); lock.unlock()
    }
}
