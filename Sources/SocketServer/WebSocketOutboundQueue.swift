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

/// FIFO storage with O(1) head advancement and occasional amortized compaction.
/// Dequeued slots are cleared immediately so frame payloads are released even
/// before the backing array is compacted.
struct WebSocketFrameFIFO<Element> {
    struct Diagnostics: Equatable {
        let queuedCount: Int
        let storageCount: Int
        let headIndex: Int
        let compactionCount: Int
    }

    private static var compactionThreshold: Int { 1_024 }

    private var storage: [Element?] = []
    private var headIndex = 0
    private var compactionCount = 0

    var diagnostics: Diagnostics {
        Diagnostics(
            queuedCount: storage.count - headIndex,
            storageCount: storage.count,
            headIndex: headIndex,
            compactionCount: compactionCount
        )
    }

    mutating func append(_ element: Element) {
        storage.append(element)
    }

    mutating func popFirst() -> Element? {
        guard headIndex < storage.count,
              let element = storage[headIndex] else {
            return nil
        }
        storage[headIndex] = nil
        headIndex += 1
        compactIfNeeded()
        return element
    }

    private mutating func compactIfNeeded() {
        if headIndex == storage.count {
            storage.removeAll(keepingCapacity: true)
            headIndex = 0
            compactionCount += 1
        } else if headIndex >= Self.compactionThreshold,
                  headIndex >= storage.count - headIndex {
            storage.removeFirst(headIndex)
            headIndex = 0
            compactionCount += 1
        }
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
    private let maxQueuedFrames: Int
    private let lock = NSLock()
    private var queuedBytes = 0
    private var queuedFrames = 0
    private var state: State = .open
    // Pending frames are buffered here so the serial drain can prioritize
    // control frames (pong/ping/close) over queued application data. A pong
    // stuck behind up to 1 MiB of event frames on a slow uplink would miss the
    // client's pong deadline and kill a healthy connection. Each enqueue still
    // dispatches exactly one drain token; only the pick order changes.
    private var pendingApplicationFrames = WebSocketFrameFIFO<Data>()
    private var pendingControlFrames = WebSocketFrameFIFO<(opcode: UInt8, data: Data)>()
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
        maxQueuedFrames: Int = 4_096,
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
        self.maxQueuedFrames = max(1, maxQueuedFrames)
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
        maxQueuedFrames: Int = 4_096,
        writer: @escaping @Sendable (Data) -> Bool,
        onClose: @escaping @Sendable (String) -> Void
    ) {
        self.init(
            label: label,
            maxQueuedBytes: maxQueuedBytes,
            maxQueuedFrames: maxQueuedFrames,
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

    var queuedFrameCountForTests: Int {
        lock.lock(); defer { lock.unlock() }
        return queuedFrames
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
        guard queuedFrames < maxQueuedFrames,
              data.count <= maxQueuedBytes - queuedBytes else {
            state = .terminalReserved
            lock.unlock()
            return .queueFull
        }
        queuedBytes += data.count
        queuedFrames += 1
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
        guard queuedFrames < maxQueuedFrames,
              data.count <= maxQueuedBytes - queuedBytes else {
            state = .terminalReserved
            lock.unlock()
            _ = terminate(errorData: nil, closingData: nil, reason: "queue_full")
            return .queueFull
        }
        queuedBytes += data.count
        queuedFrames += 1
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
        if let control = pendingControlFrames.popFirst() {
            lock.unlock()
            writeControl(opcode: control.opcode, data: control.data)
            return
        }
        guard let data = pendingApplicationFrames.popFirst() else {
            lock.unlock()
            return
        }
        lock.unlock()
        writeApplication(data)
    }

    private func writeApplication(_ data: Data) {
        guard shouldWriteQueuedItem() else {
            removeQueuedItem(byteCount: data.count)
            return
        }
        let succeeded = applicationWriter(data)
        removeQueuedItem(byteCount: data.count)
        if !succeeded { terminateImmediatelyAfterWriteFailure() }
    }

    private func writeControl(opcode: UInt8, data: Data) {
        guard shouldWriteQueuedItem() else {
            removeQueuedItem(byteCount: data.count)
            return
        }
        let succeeded = controlWriter(opcode, data)
        removeQueuedItem(byteCount: data.count)
        if !succeeded { terminateImmediatelyAfterWriteFailure() }
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

    private func removeQueuedItem(byteCount: Int) {
        lock.lock()
        queuedBytes = max(0, queuedBytes - byteCount)
        queuedFrames = max(0, queuedFrames - 1)
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
    /// Kept events recorded out of order while a snapshot is in flight. Kept
    /// events cross one serial batcher in seq order, so a hole below a member
    /// of this set proves a genuinely lost event.
    private var pendingSequences = Set<Int64>()
    /// Filter-dropped seqs recorded ahead of the kept event below them. These
    /// are recorded synchronously on the EventBus delivery queue while kept
    /// events add batcher latency, so a hole below a member of this set only
    /// means a kept event still in flight — never a lost event.
    private var filteredPendingSequences = Set<Int64>()

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
        // Kept seqs only buffer while a snapshot is in flight and every exit
        // path clears them, so this starts the lifecycle from a clean set.
        // filteredPendingSequences intentionally survives: a filter hole is a
        // fact about the live stream, not the snapshot lifecycle. Clearing it
        // would lose the account of a never-sent seq, and the first kept
        // event after the hole would re-report it as a gap.
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
            filteredPendingSequences.insert(next)
        }
        lock.unlock()
    }

    func adoptSnapshot(sequence next: Int64) -> ConnectionSnapshotAdoptionResult {
        lock.lock(); defer { lock.unlock() }
        guard snapshotInFlight else {
            return .gap(expected: sequence + 1, received: next)
        }
        var candidateSequence = max(sequence, next)
        var remainingKept = pendingSequences.filter { $0 > candidateSequence }
        var remainingFiltered = filteredPendingSequences.filter { $0 > candidateSequence }
        while remainingKept.remove(candidateSequence + 1) != nil
            || remainingFiltered.remove(candidateSequence + 1) != nil {
            candidateSequence += 1
        }
        snapshotInFlight = false
        if let received = remainingKept.min() {
            pendingSequences.removeAll(keepingCapacity: true)
            filteredPendingSequences.removeAll(keepingCapacity: true)
            return .gap(expected: candidateSequence + 1, received: received)
        }
        sequence = candidateSequence
        snapshotCoveredThrough = max(snapshotCoveredThrough, next)
        pendingSequences.removeAll(keepingCapacity: true)
        // Remaining filtered seqs above the adopted head are NOT a gap: the
        // hole below them is a kept event still crossing the batcher, and its
        // recordEnqueuedEvent will drain them. They must be retained, or that
        // kept event would re-report the filter hole as a gap.
        filteredPendingSequences = remainingFiltered
        return .adopted(sequence: sequence)
    }

    func cancelSnapshot() {
        lock.lock()
        snapshotInFlight = false
        // Kept seqs buffered for the abandoned snapshot are dropped: without
        // an adopted snapshot the hole below them stays uncovered, and the
        // next kept event fails loud as a gap.
        // filteredPendingSequences survives: it accounts for seqs that were
        // never sent, independent of any snapshot; dropping it would turn the
        // filter hole into a spurious gap once the in-flight kept event lands.
        pendingSequences.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func drainPendingLocked() {
        while pendingSequences.remove(sequence + 1) != nil
            || filteredPendingSequences.remove(sequence + 1) != nil {
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
