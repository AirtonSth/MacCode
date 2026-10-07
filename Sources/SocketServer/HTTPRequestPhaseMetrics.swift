import Foundation

/// Secret-free latency aggregate for one HTTP/RPC phase lane.
///
/// Intentionally stores only count/total/max milliseconds — never methods,
/// owners, connection IDs, peer addresses, tokens, or payloads.
public struct HTTPRequestPhaseLaneSnapshot: Sendable, Equatable {
    public let count: UInt64
    public let totalMilliseconds: Double
    public let maxMilliseconds: Double

    public static let zero = HTTPRequestPhaseLaneSnapshot(
        count: 0,
        totalMilliseconds: 0,
        maxMilliseconds: 0
    )
}

/// Process-local aggregates for request-phase timing and terminal outcomes.
///
/// Used by `/v1/health` so operators can see whether pressure is in admit,
/// snapshot read, encode, or write — without exposing request content.
public struct HTTPRequestPhaseMetricsSnapshot: Sendable, Equatable {
    /// Bearer → principal resolution in the HTTP auth gate.
    public var auth: HTTPRequestPhaseLaneSnapshot = .zero
    public let admit: HTTPRequestPhaseLaneSnapshot
    public let snapshotRead: HTTPRequestPhaseLaneSnapshot
    public let snapshotEncode: HTTPRequestPhaseLaneSnapshot
    public let responseWrite: HTTPRequestPhaseLaneSnapshot
    public let cancelledTotal: UInt64
    public let timedOutTotal: UInt64
    public let fenceRetryTotal: UInt64
    public let fenceExhaustedTotal: UInt64
    public let writeAbortedTotal: UInt64
    /// `sync.snapshot` callers that joined a read already in flight.
    public var joinedTotal: UInt64 = 0
    /// Snapshot reads that succeeded although an idempotent state event
    /// (`EventBus.snapshotFenceIdempotentKinds`) crossed the read.
    public var fenceToleratedTotal: UInt64 = 0

    public static let zero = HTTPRequestPhaseMetricsSnapshot(
        admit: .zero,
        snapshotRead: .zero,
        snapshotEncode: .zero,
        responseWrite: .zero,
        cancelledTotal: 0,
        timedOutTotal: 0,
        fenceRetryTotal: 0,
        fenceExhaustedTotal: 0,
        writeAbortedTotal: 0
    )
}

/// Secret-free phase metrics for DirectHTTPServer request handling.
public final class HTTPRequestPhaseMetrics: @unchecked Sendable {
    public enum Phase: String, Sendable {
        case auth
        case admit
        case snapshotRead
        case snapshotEncode
        case responseWrite
    }

    private struct Latency {
        var count: UInt64 = 0
        var totalMilliseconds: Double = 0
        var maxMilliseconds: Double = 0

        mutating func record(_ milliseconds: Double) {
            let bounded = max(0, milliseconds)
            count += 1
            totalMilliseconds += bounded
            maxMilliseconds = max(maxMilliseconds, bounded)
        }

        var snapshot: HTTPRequestPhaseLaneSnapshot {
            HTTPRequestPhaseLaneSnapshot(
                count: count,
                totalMilliseconds: totalMilliseconds,
                maxMilliseconds: maxMilliseconds
            )
        }
    }

    private struct Storage {
        var auth = Latency()
        var admit = Latency()
        var snapshotRead = Latency()
        var snapshotEncode = Latency()
        var responseWrite = Latency()
        var cancelledTotal: UInt64 = 0
        var timedOutTotal: UInt64 = 0
        var fenceRetryTotal: UInt64 = 0
        var fenceExhaustedTotal: UInt64 = 0
        var writeAbortedTotal: UInt64 = 0
        var joinedTotal: UInt64 = 0
        var fenceToleratedTotal: UInt64 = 0
    }

    private let lock = NSLock()
    private var storage = Storage()

    public init() {}

    public func record(_ phase: Phase, latencyMilliseconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        switch phase {
        case .auth: storage.auth.record(latencyMilliseconds)
        case .admit: storage.admit.record(latencyMilliseconds)
        case .snapshotRead: storage.snapshotRead.record(latencyMilliseconds)
        case .snapshotEncode: storage.snapshotEncode.record(latencyMilliseconds)
        case .responseWrite: storage.responseWrite.record(latencyMilliseconds)
        }
    }

    public func recordCancelled() {
        lock.lock()
        storage.cancelledTotal += 1
        lock.unlock()
    }

    public func recordTimedOut() {
        lock.lock()
        storage.timedOutTotal += 1
        lock.unlock()
    }

    public func recordFenceRetry() {
        lock.lock()
        storage.fenceRetryTotal += 1
        lock.unlock()
    }

    public func recordFenceExhausted() {
        lock.lock()
        storage.fenceExhaustedTotal += 1
        lock.unlock()
    }

    public func recordJoined() {
        lock.lock()
        storage.joinedTotal += 1
        lock.unlock()
    }

    public func recordFenceTolerated() {
        lock.lock()
        storage.fenceToleratedTotal += 1
        lock.unlock()
    }

    public func recordWriteAborted() {
        lock.lock()
        storage.writeAbortedTotal += 1
        lock.unlock()
    }

    public func snapshot() -> HTTPRequestPhaseMetricsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = HTTPRequestPhaseMetricsSnapshot(
            auth: storage.auth.snapshot,
            admit: storage.admit.snapshot,
            snapshotRead: storage.snapshotRead.snapshot,
            snapshotEncode: storage.snapshotEncode.snapshot,
            responseWrite: storage.responseWrite.snapshot,
            cancelledTotal: storage.cancelledTotal,
            timedOutTotal: storage.timedOutTotal,
            fenceRetryTotal: storage.fenceRetryTotal,
            fenceExhaustedTotal: storage.fenceExhaustedTotal,
            writeAbortedTotal: storage.writeAbortedTotal
        )
        snapshot.joinedTotal = storage.joinedTotal
        snapshot.fenceToleratedTotal = storage.fenceToleratedTotal
        return snapshot
    }

    /// Continuous-clock helper shared by HTTPServer / Dispatcher paths.
    public static func elapsedMilliseconds(since start: UInt64) -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= start else { return 0 }
        return Double(now - start) / 1_000_000
    }
}
