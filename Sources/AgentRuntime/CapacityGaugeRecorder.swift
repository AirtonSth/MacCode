import Foundation

/// Content-free gauge snapshot for signpost-style capacity instrumentation (S1).
public struct CapacityGaugeSnapshot: Sendable, Codable, Equatable {
    public var acceptToPrepareMs: Double?
    public var prepareToSpawnMs: Double?
    public var ingressBytesThread: Int64
    public var ingressBytesGlobal: Int64
    public var durableCursor: Int64?
    public var lockWaitMs: Double?
    public var dbWaitMs: Double?
    public var subscriberQueueDepth: Int
    public var batcherPendingBytes: Int64
    public var batcherPendingCount: Int
    public var outboundQueueBytes: Int64
    public var eventToVisiblePaintMs: Double?
    public var stopDispatchMs: Double?
    public var dagLongestNoProgressMs: Double?
    public var appRSSKB: Int64?
    public var providerTreeRSSKB: Int64?
    public var sidecarRSSKB: Int64?
    public var openDescriptors: Int?
    public var ownershipCoverageFraction: Double?

    public init(
        acceptToPrepareMs: Double? = nil,
        prepareToSpawnMs: Double? = nil,
        ingressBytesThread: Int64 = 0,
        ingressBytesGlobal: Int64 = 0,
        durableCursor: Int64? = nil,
        lockWaitMs: Double? = nil,
        dbWaitMs: Double? = nil,
        subscriberQueueDepth: Int = 0,
        batcherPendingBytes: Int64 = 0,
        batcherPendingCount: Int = 0,
        outboundQueueBytes: Int64 = 0,
        eventToVisiblePaintMs: Double? = nil,
        stopDispatchMs: Double? = nil,
        dagLongestNoProgressMs: Double? = nil,
        appRSSKB: Int64? = nil,
        providerTreeRSSKB: Int64? = nil,
        sidecarRSSKB: Int64? = nil,
        openDescriptors: Int? = nil,
        ownershipCoverageFraction: Double? = nil
    ) {
        self.acceptToPrepareMs = acceptToPrepareMs
        self.prepareToSpawnMs = prepareToSpawnMs
        self.ingressBytesThread = ingressBytesThread
        self.ingressBytesGlobal = ingressBytesGlobal
        self.durableCursor = durableCursor
        self.lockWaitMs = lockWaitMs
        self.dbWaitMs = dbWaitMs
        self.subscriberQueueDepth = subscriberQueueDepth
        self.batcherPendingBytes = batcherPendingBytes
        self.batcherPendingCount = batcherPendingCount
        self.outboundQueueBytes = outboundQueueBytes
        self.eventToVisiblePaintMs = eventToVisiblePaintMs
        self.stopDispatchMs = stopDispatchMs
        self.dagLongestNoProgressMs = dagLongestNoProgressMs
        self.appRSSKB = appRSSKB
        self.providerTreeRSSKB = providerTreeRSSKB
        self.sidecarRSSKB = sidecarRSSKB
        self.openDescriptors = openDescriptors
        self.ownershipCoverageFraction = ownershipCoverageFraction
    }
}

/// Process-wide content-free capacity gauges. Production accept→spawn and
/// heartbeat paths record here for qualification (S1).
public final class CapacityGaugeRecorder: @unchecked Sendable {
    public static let shared = CapacityGaugeRecorder()
    private let lock = NSLock()
    private var snapshot = CapacityGaugeSnapshot()
    private var acceptStartedAt: [String: Date] = [:]
    private var prepareStartedAt: [String: Date] = [:]

    public func current() -> CapacityGaugeSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    public func noteAcceptStarted(threadKey: String, at date: Date = Date()) {
        lock.lock()
        acceptStartedAt[threadKey] = date
        prepareStartedAt.removeValue(forKey: threadKey)
        lock.unlock()
    }

    public func notePrepareStarted(threadKey: String, at date: Date = Date()) {
        lock.lock()
        prepareStartedAt[threadKey] = date
        if let start = acceptStartedAt[threadKey] {
            snapshot.acceptToPrepareMs = date.timeIntervalSince(start) * 1000
        }
        lock.unlock()
    }

    public func noteSpawned(threadKey: String, at date: Date = Date()) {
        lock.lock()
        let acceptAt = acceptStartedAt.removeValue(forKey: threadKey)
        let prepareAt = prepareStartedAt.removeValue(forKey: threadKey) ?? acceptAt
        if let acceptAt {
            let acceptToPrepare = (prepareAt ?? date).timeIntervalSince(acceptAt) * 1000
            snapshot.acceptToPrepareMs = acceptToPrepare
            if let prepareAt {
                snapshot.prepareToSpawnMs = max(0, date.timeIntervalSince(prepareAt) * 1000)
            } else {
                snapshot.prepareToSpawnMs = max(0, date.timeIntervalSince(acceptAt) * 1000 - acceptToPrepare)
            }
        }
        lock.unlock()
    }

    public func noteTerminalized(threadKey: String) {
        lock.lock()
        acceptStartedAt.removeValue(forKey: threadKey)
        prepareStartedAt.removeValue(forKey: threadKey)
        lock.unlock()
    }

    public func noteStopDispatch(ms: Double) {
        lock.lock(); snapshot.stopDispatchMs = ms; lock.unlock()
    }

    public func noteRSS(appKB: Int64?, providerKB: Int64?, sidecarKB: Int64?) {
        lock.lock()
        snapshot.appRSSKB = appKB
        snapshot.providerTreeRSSKB = providerKB
        snapshot.sidecarRSSKB = sidecarKB
        lock.unlock()
    }

    public func noteOwnershipCoverage(fraction: Double?) {
        lock.lock(); snapshot.ownershipCoverageFraction = fraction; lock.unlock()
    }

    public func noteIngress(threadBytes: Int64 = 0, globalBytes: Int64 = 0) {
        lock.lock()
        snapshot.ingressBytesThread += threadBytes
        snapshot.ingressBytesGlobal += globalBytes
        lock.unlock()
    }

    public func noteBatcher(pendingBytes: Int64, pendingCount: Int) {
        lock.lock()
        snapshot.batcherPendingBytes = pendingBytes
        snapshot.batcherPendingCount = pendingCount
        lock.unlock()
    }
}
