import Foundation
import Persistence

public struct CommandReceiptLatencySnapshot: Sendable, Equatable {
    public let count: UInt64
    public let totalMilliseconds: Double
    public let maxMilliseconds: Double
}

public struct CommandReceiptMetricsSnapshot: Sendable, Equatable {
    public let claimsTotal: UInt64
    public let newClaimsTotal: UInt64
    public let claimFailuresTotal: UInt64
    public let duplicatesInProgressTotal: UInt64
    public let duplicatesCommittedTotal: UInt64
    public let duplicatesUnknownTotal: UInt64
    public let rejectedClaimsTotal: UInt64
    public let unknownOutcomesTotal: UInt64
    public let finalizationSuccessesTotal: UInt64
    public let finalizationFailuresTotal: UInt64
    public let claimLatency: CommandReceiptLatencySnapshot
    public let finalizationLatency: CommandReceiptLatencySnapshot
}

/// Process-local, aggregate-only receipt telemetry. It intentionally never
/// stores method names, request IDs, owners, hashes, params, or results.
public final class CommandReceiptMetrics: @unchecked Sendable {
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

        var snapshot: CommandReceiptLatencySnapshot {
            CommandReceiptLatencySnapshot(
                count: count,
                totalMilliseconds: totalMilliseconds,
                maxMilliseconds: maxMilliseconds
            )
        }
    }

    private struct Storage {
        var claimsTotal: UInt64 = 0
        var newClaimsTotal: UInt64 = 0
        var claimFailuresTotal: UInt64 = 0
        var duplicatesInProgressTotal: UInt64 = 0
        var duplicatesCommittedTotal: UInt64 = 0
        var duplicatesUnknownTotal: UInt64 = 0
        var rejectedClaimsTotal: UInt64 = 0
        var unknownOutcomesTotal: UInt64 = 0
        var finalizationSuccessesTotal: UInt64 = 0
        var finalizationFailuresTotal: UInt64 = 0
        var claimLatency = Latency()
        var finalizationLatency = Latency()
    }

    private let lock = NSLock()
    private var storage = Storage()

    public init() {}

    public func recordClaim(_ result: CommandReceiptClaimResult, latencyMilliseconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        storage.claimsTotal += 1
        storage.claimLatency.record(latencyMilliseconds)
        switch result {
        case .claimed:
            storage.newClaimsTotal += 1
        case .inProgress:
            storage.duplicatesInProgressTotal += 1
        case .committed:
            storage.duplicatesCommittedTotal += 1
        case .unknown:
            storage.duplicatesUnknownTotal += 1
        case .ownerMismatch, .requestMismatch, .legacyUnverifiable:
            storage.rejectedClaimsTotal += 1
        }
    }

    public func recordClaimFailure(latencyMilliseconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        storage.claimsTotal += 1
        storage.claimFailuresTotal += 1
        storage.claimLatency.record(latencyMilliseconds)
    }

    public func recordUnknownOutcome() {
        lock.lock()
        storage.unknownOutcomesTotal += 1
        lock.unlock()
    }

    public func recordFinalization(success: Bool, latencyMilliseconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        if success {
            storage.finalizationSuccessesTotal += 1
        } else {
            storage.finalizationFailuresTotal += 1
        }
        storage.finalizationLatency.record(latencyMilliseconds)
    }

    public func snapshot() -> CommandReceiptMetricsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return CommandReceiptMetricsSnapshot(
            claimsTotal: storage.claimsTotal,
            newClaimsTotal: storage.newClaimsTotal,
            claimFailuresTotal: storage.claimFailuresTotal,
            duplicatesInProgressTotal: storage.duplicatesInProgressTotal,
            duplicatesCommittedTotal: storage.duplicatesCommittedTotal,
            duplicatesUnknownTotal: storage.duplicatesUnknownTotal,
            rejectedClaimsTotal: storage.rejectedClaimsTotal,
            unknownOutcomesTotal: storage.unknownOutcomesTotal,
            finalizationSuccessesTotal: storage.finalizationSuccessesTotal,
            finalizationFailuresTotal: storage.finalizationFailuresTotal,
            claimLatency: storage.claimLatency.snapshot,
            finalizationLatency: storage.finalizationLatency.snapshot
        )
    }
}
