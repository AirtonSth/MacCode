import Foundation

/// HC-1: bridge live surface output (terminal PTY chunks, etc.) from the
/// `Surfaces` module to the network event bus without inverting the
/// module dependency graph. `Surfaces` and `AppShell` both see
/// `CoreModel`; `AppShell` wires `sink` to publish on `EventBus`.
public final class SurfaceOutputBus: @unchecked Sendable {
    public static let shared = SurfaceOutputBus()

    private let queue: DispatchQueue
    private let flushDelay: TimeInterval
    private let maxBatchBytes: Int
    private var sinkStorage: ((_ surfaceId: SurfaceID, _ seq: Int, _ chunk: Data) -> Void)?
    private var pending: [SurfaceID: Data] = [:]
    private var surfaceSeq: [SurfaceID: Int] = [:]
    private var flushScheduled = false
    private let queueKey = DispatchSpecificKey<Void>()

    init(
        queue: DispatchQueue = DispatchQueue(label: "RemoteCode.SurfaceOutputBus"),
        flushDelay: TimeInterval = 0.02,
        maxBatchBytes: Int = 64 * 1024
    ) {
        self.queue = queue
        self.flushDelay = max(0, flushDelay)
        self.maxBatchBytes = max(1, maxBatchBytes)
        self.queue.setSpecific(key: queueKey, value: ())
    }

    /// Set by AppShell to forward to the network event bus.
    public var sink: ((_ surfaceId: SurfaceID, _ seq: Int, _ chunk: Data) -> Void)? {
        get { queue.sync { sinkStorage } }
        set {
            queue.async {
                self.sinkStorage = newValue
            }
        }
    }

    public func currentSequence(_ surfaceId: SurfaceID) -> Int {
        queue.sync { surfaceSeq[surfaceId] ?? 0 }
    }

    public func emit(_ surfaceId: SurfaceID, _ chunk: Data) {
        guard !chunk.isEmpty else { return }
        queue.async {
            var buffered = self.pending[surfaceId] ?? Data()
            buffered.append(chunk)
            self.pending[surfaceId] = buffered

            if buffered.count >= self.maxBatchBytes {
                self.flush(surfaceId)
            } else {
                self.scheduleFlush()
            }
        }
    }

    public func flushNow(_ surfaceId: SurfaceID) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            flush(surfaceId)
        } else {
            queue.sync {
                flush(surfaceId)
            }
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + flushDelay) { [weak self] in
            self?.flushAll()
        }
    }

    private func flushAll() {
        flushScheduled = false
        for surfaceId in Array(pending.keys) {
            flush(surfaceId)
        }
    }

    private func flush(_ surfaceId: SurfaceID) {
        guard let chunk = pending.removeValue(forKey: surfaceId), !chunk.isEmpty else { return }
        let seq = (surfaceSeq[surfaceId] ?? 0) + 1
        surfaceSeq[surfaceId] = seq
        sinkStorage?(surfaceId, seq, chunk)
    }
}
