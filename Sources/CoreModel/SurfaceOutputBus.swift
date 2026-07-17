import Foundation

/// HC-1: bridge live surface output (terminal PTY chunks, etc.) from the
/// `Surfaces` module to the network event bus without inverting the
/// module dependency graph. `Surfaces` and `AppShell` both see
/// `CoreModel`; `AppShell` wires `sink` to publish on `EventBus`.
public final class SurfaceOutputBus: @unchecked Sendable {
    public struct OutputFrame: Sendable, Equatable {
        public let surfaceID: SurfaceID
        public let sequence: Int
        public let data: Data
        public let rows: Int?
        public let cols: Int?

        public init(
            surfaceID: SurfaceID,
            sequence: Int,
            data: Data,
            rows: Int? = nil,
            cols: Int? = nil
        ) {
            self.surfaceID = surfaceID
            self.sequence = sequence
            self.data = data
            self.rows = rows
            self.cols = cols
        }
    }

    private struct Geometry: Equatable {
        let rows: Int
        let cols: Int
    }

    private struct PendingFrame {
        var data = Data()
        var geometry: Geometry?
    }

    public static let shared = SurfaceOutputBus()

    private let queue: DispatchQueue
    private let flushDelay: TimeInterval
    private let maxBatchBytes: Int
    private var sinkStorage: ((OutputFrame) -> Void)?
    private var pending: [SurfaceID: PendingFrame] = [:]
    private var surfaceSeq: [SurfaceID: Int] = [:]
    private var lastGeometry: [SurfaceID: Geometry] = [:]
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
    public var sink: ((OutputFrame) -> Void)? {
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

    public func emit(
        _ surfaceID: SurfaceID,
        _ chunk: Data,
        rows: Int? = nil,
        cols: Int? = nil
    ) {
        guard !chunk.isEmpty else { return }
        queue.async {
            var frame = self.pending[surfaceID] ?? PendingFrame()
            frame.data.append(chunk)
            if let geometry = Self.geometry(rows: rows, cols: cols) {
                frame.geometry = geometry
            }
            self.pending[surfaceID] = frame

            if frame.data.count >= self.maxBatchBytes {
                self.flush(surfaceID)
            } else {
                self.scheduleFlush()
            }
        }
    }

    /// Emit terminal geometry even when the PTY is idle. Repeated layout
    /// callbacks with unchanged dimensions are coalesced.
    public func emitGeometry(_ surfaceID: SurfaceID, rows: Int, cols: Int) {
        guard let geometry = Self.geometry(rows: rows, cols: cols) else { return }
        queue.async {
            let effectiveGeometry = self.pending[surfaceID]?.geometry
                ?? self.lastGeometry[surfaceID]
            guard effectiveGeometry != geometry else { return }

            var frame = self.pending[surfaceID] ?? PendingFrame()
            frame.geometry = geometry
            self.pending[surfaceID] = frame
            self.scheduleFlush()
        }
    }

    /// Remove all buffered state for a closed surface, preventing unbounded
    /// growth from terminal churn. This is a delivery barrier: after it returns,
    /// no active sink can still be publishing output for the surface.
    /// Idempotent: removing an absent id is a no-op.
    public func remove(surfaceId: SurfaceID) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            removeState(surfaceId: surfaceId)
        } else {
            queue.sync {
                removeState(surfaceId: surfaceId)
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

    private func removeState(surfaceId: SurfaceID) {
        pending.removeValue(forKey: surfaceId)
        surfaceSeq.removeValue(forKey: surfaceId)
        lastGeometry.removeValue(forKey: surfaceId)
    }

    private func flushAll() {
        flushScheduled = false
        for surfaceId in Array(pending.keys) {
            flush(surfaceId)
        }
    }

    private func flush(_ surfaceId: SurfaceID) {
        guard let pendingFrame = pending.removeValue(forKey: surfaceId) else { return }

        let geometryChanged = pendingFrame.geometry.map { $0 != lastGeometry[surfaceId] } ?? false
        guard !pendingFrame.data.isEmpty || geometryChanged else { return }

        let deliveryGeometry = pendingFrame.geometry ?? lastGeometry[surfaceId]
        if let geometry = pendingFrame.geometry {
            lastGeometry[surfaceId] = geometry
        }
        let seq = (surfaceSeq[surfaceId] ?? 0) + 1
        surfaceSeq[surfaceId] = seq
        sinkStorage?(
            OutputFrame(
                surfaceID: surfaceId,
                sequence: seq,
                data: pendingFrame.data,
                rows: deliveryGeometry?.rows,
                cols: deliveryGeometry?.cols
            )
        )
    }

    private static func geometry(rows: Int?, cols: Int?) -> Geometry? {
        guard let rows, let cols, rows > 0, cols > 0 else { return nil }
        return Geometry(rows: rows, cols: cols)
    }
}
