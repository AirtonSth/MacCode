import Foundation

// MARK: - HTTP/WebSocket vs QUIC prototype comparison report
//
// Pure offline report seam for Phase 5 open item
// "Comparar protocolo atual otimizado contra protótipo QUIC".
//
// Isolation rules:
// - Accepts **externally collected** duration samples or already-bounded
//   count/total/max aggregates only. Performs no network I/O, opens no sockets,
//   and does not construct `NWProtocolQUIC.Options` or live connections.
// - Does **not** claim interoperability, performance gain, TLS bypass, or live
//   production support. Status codes describe evidence completeness only —
//   never a transport winner or SLO pass/fail.
// - Does **not** wire into DirectHTTPServer, UnixSocketServer, /v1/health, or
//   any production schema. Existing HTTP/WebSocket transport is unchanged.
// - Secret-free: count/total/max/percentile milliseconds only (no hosts, tokens, payloads).

/// Low-cardinality path label for one side of an external comparison.
///
/// Labels identify which externally collected series a sample belongs to.
/// They are not transport selection flags and do not enable QUIC in production.
public enum ProtocolComparisonPath: String, Sendable, Equatable, CaseIterable, Codable {
    /// Production-optimized HTTP (reliable) + WebSocket (realtime) path.
    case currentHTTPWebSocket = "current_http_websocket"
    /// Default-off QUIC/HTTP-3 prototype evaluation path (no live support claim).
    case quicPrototype = "quic_prototype"
}

/// One externally collected duration sample for a labelled path.
///
/// Callers own collection (bench harness, logs, offline capture). This type
/// never performs measurement itself.
public struct ProtocolPathDurationSample: Sendable, Equatable {
    public let path: ProtocolComparisonPath
    /// Observed duration in milliseconds. Non-finite / negative values are
    /// clamped when folded into aggregates.
    public let durationMilliseconds: Double

    public init(path: ProtocolComparisonPath, durationMilliseconds: Double) {
        self.path = path
        self.durationMilliseconds = durationMilliseconds
    }
}

/// Bounded count/total/max duration aggregate matching the secret-free shape
/// used by macOS connection/queue metrics (`OutboundQueueWaitLaneMetrics`),
/// plus optional nearest-rank tail percentiles when raw samples are folded.
///
/// A missing mean means no successful sample was collected for that path.
/// Percentile fields are 0 when no samples were folded (safe Codable default
/// for aggregate-only construction and legacy JSON payloads).
///
/// ## Nearest-rank percentile semantics
///
/// For a non-empty multiset of sanitized durations sorted ascending with
/// count `n`, the p-th percentile is the value at **1-based** rank
/// `ceil(p / 100 * n)` (nearest-rank method). Empty sample sets yield `0`.
/// Sanitization matches count/total/max: non-finite → 0, negative → 0.
public struct ProtocolPathDurationAggregate: Sendable, Equatable, Codable {
    public private(set) var count: UInt64
    public private(set) var totalMilliseconds: Double
    public private(set) var maxMilliseconds: Double
    /// Nearest-rank p50 duration in milliseconds (0 when no samples folded).
    public private(set) var p50Milliseconds: Double
    /// Nearest-rank p95 duration in milliseconds (0 when no samples folded).
    public private(set) var p95Milliseconds: Double
    /// Nearest-rank p99 duration in milliseconds (0 when no samples folded).
    public private(set) var p99Milliseconds: Double

    public static let zero = ProtocolPathDurationAggregate(
        count: 0,
        totalMilliseconds: 0,
        maxMilliseconds: 0
    )

    public var meanMilliseconds: Double? {
        guard count > 0 else { return nil }
        return totalMilliseconds / Double(count)
    }

    public init(
        count: UInt64,
        totalMilliseconds: Double,
        maxMilliseconds: Double,
        p50Milliseconds: Double = 0,
        p95Milliseconds: Double = 0,
        p99Milliseconds: Double = 0
    ) {
        let finiteTotal = totalMilliseconds.isFinite ? max(0, totalMilliseconds) : 0
        let finiteMax = maxMilliseconds.isFinite ? max(0, maxMilliseconds) : 0
        let finiteP50 = p50Milliseconds.isFinite ? max(0, p50Milliseconds) : 0
        let finiteP95 = p95Milliseconds.isFinite ? max(0, p95Milliseconds) : 0
        let finiteP99 = p99Milliseconds.isFinite ? max(0, p99Milliseconds) : 0
        self.count = count
        self.totalMilliseconds = finiteTotal
        self.maxMilliseconds = finiteMax
        self.p50Milliseconds = finiteP50
        self.p95Milliseconds = finiteP95
        self.p99Milliseconds = finiteP99
    }

    /// Build from an existing outbound-queue wait lane aggregate without
    /// inventing new metric dimensions. Percentiles default to 0 because the
    /// lane shape only carries count/total/max (no sample series).
    public init(lane: OutboundQueueWaitLaneMetrics) {
        self.init(
            count: lane.count,
            totalMilliseconds: lane.totalMilliseconds,
            maxMilliseconds: lane.maxMilliseconds
        )
    }

    /// Fold externally supplied samples into a single bounded aggregate,
    /// including deterministic nearest-rank p50/p95/p99 on the sanitized series.
    public static func folding(_ samples: [Double]) -> ProtocolPathDurationAggregate {
        var count: UInt64 = 0
        var totalMilliseconds: Double = 0
        var maxMilliseconds: Double = 0
        var bounded: [Double] = []
        bounded.reserveCapacity(samples.count)
        for sample in samples {
            let value = Self.sanitize(sample)
            bounded.append(value)
            count &+= 1
            totalMilliseconds += value
            maxMilliseconds = max(maxMilliseconds, value)
        }
        let sorted = bounded.sorted()
        return ProtocolPathDurationAggregate(
            count: count,
            totalMilliseconds: totalMilliseconds,
            maxMilliseconds: maxMilliseconds,
            p50Milliseconds: nearestRankPercentile(sortedAscending: sorted, percentile: 50),
            p95Milliseconds: nearestRankPercentile(sortedAscending: sorted, percentile: 95),
            p99Milliseconds: nearestRankPercentile(sortedAscending: sorted, percentile: 99)
        )
    }

    /// Nearest-rank: 1-based rank = `ceil(p/100 * n)`; empty → 0.
    public static func nearestRankPercentile(
        sortedAscending: [Double],
        percentile: Double
    ) -> Double {
        let n = sortedAscending.count
        guard n > 0 else { return 0 }
        // Clamp percentile into a usable band; callers pass 50/95/99.
        let p = percentile.isFinite ? min(100, max(0, percentile)) : 0
        if p == 0 { return sortedAscending[0] }
        let rank = Int((p / 100.0 * Double(n)).rounded(.up))
        let index = min(n, max(1, rank)) - 1
        return sortedAscending[index]
    }

    private static func sanitize(_ durationMilliseconds: Double) -> Double {
        if durationMilliseconds.isFinite {
            return max(0, durationMilliseconds)
        }
        return 0
    }

    private enum CodingKeys: String, CodingKey {
        case count
        case totalMilliseconds = "total_milliseconds"
        case maxMilliseconds = "max_milliseconds"
        case p50Milliseconds = "p50_milliseconds"
        case p95Milliseconds = "p95_milliseconds"
        case p99Milliseconds = "p99_milliseconds"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let count = try container.decode(UInt64.self, forKey: .count)
        let totalMilliseconds = try container.decode(Double.self, forKey: .totalMilliseconds)
        let maxMilliseconds = try container.decode(Double.self, forKey: .maxMilliseconds)
        // Additive fields: legacy payloads without percentiles decode as 0.
        let p50Milliseconds = try container.decodeIfPresent(Double.self, forKey: .p50Milliseconds) ?? 0
        let p95Milliseconds = try container.decodeIfPresent(Double.self, forKey: .p95Milliseconds) ?? 0
        let p99Milliseconds = try container.decodeIfPresent(Double.self, forKey: .p99Milliseconds) ?? 0
        self.init(
            count: count,
            totalMilliseconds: totalMilliseconds,
            maxMilliseconds: maxMilliseconds,
            p50Milliseconds: p50Milliseconds,
            p95Milliseconds: p95Milliseconds,
            p99Milliseconds: p99Milliseconds
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(count, forKey: .count)
        try container.encode(totalMilliseconds, forKey: .totalMilliseconds)
        try container.encode(maxMilliseconds, forKey: .maxMilliseconds)
        try container.encode(p50Milliseconds, forKey: .p50Milliseconds)
        try container.encode(p95Milliseconds, forKey: .p95Milliseconds)
        try container.encode(p99Milliseconds, forKey: .p99Milliseconds)
    }
}

/// Completeness of externally supplied evidence — not a performance verdict.
public enum ProtocolComparisonEvidenceStatus: String, Sendable, Equatable, Codable {
    /// Neither path has samples/aggregates with count > 0.
    case incompleteMissingBoth = "incomplete_missing_both_paths"
    /// Current HTTP/WebSocket side has no samples.
    case incompleteMissingCurrent = "incomplete_missing_current_http_websocket"
    /// QUIC prototype side has no samples.
    case incompleteMissingPrototype = "incomplete_missing_quic_prototype"
    /// Both sides have at least one sample. Side-by-side aggregates only;
    /// does **not** declare a winner, gain, or production readiness.
    case sideBySideAggregatesOnly = "side_by_side_aggregates_only"
}

/// Additive pure report comparing externally collected HTTP/WebSocket samples
/// against externally collected QUIC prototype samples.
///
/// Always carries fixed non-claim codes so the report cannot be misread as
/// interoperability proof, a performance win, TLS bypass, or live support.
public struct HTTP3PrototypeComparisonReport: Sendable, Equatable, Codable {
    public let currentHTTPWebSocket: ProtocolPathDurationAggregate
    public let quicPrototype: ProtocolPathDurationAggregate
    public let evidenceStatus: ProtocolComparisonEvidenceStatus
    /// Stable fixed codes asserting what this report does **not** claim.
    public let nonClaims: [String]

    /// Fixed non-claim codes always attached to every report.
    public static let fixedNonClaims: [String] = [
        "no_interoperability_claim",
        "no_performance_gain_claim",
        "no_tls_bypass_claim",
        "no_live_support_claim",
    ]

    private enum CodingKeys: String, CodingKey {
        case currentHTTPWebSocket = "current_http_websocket"
        case quicPrototype = "quic_prototype"
        case evidenceStatus = "evidence_status"
        case nonClaims = "non_claims"
    }

    public init(
        currentHTTPWebSocket: ProtocolPathDurationAggregate,
        quicPrototype: ProtocolPathDurationAggregate
    ) {
        self.currentHTTPWebSocket = currentHTTPWebSocket
        self.quicPrototype = quicPrototype
        self.evidenceStatus = Self.status(
            currentCount: currentHTTPWebSocket.count,
            prototypeCount: quicPrototype.count
        )
        self.nonClaims = Self.fixedNonClaims
    }

    /// Deterministic UTF-8 JSON for offline comparison tooling.
    /// Sorted keys; secret-free aggregates and fixed non-claim codes only.
    public func exportJSON() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data(#"{}"#.utf8)
    }

    public func exportJSONString() -> String {
        String(data: exportJSON(), encoding: .utf8) ?? "{}"
    }

    private static func status(
        currentCount: UInt64,
        prototypeCount: UInt64
    ) -> ProtocolComparisonEvidenceStatus {
        switch (currentCount > 0, prototypeCount > 0) {
        case (false, false):
            return .incompleteMissingBoth
        case (false, true):
            return .incompleteMissingCurrent
        case (true, false):
            return .incompleteMissingPrototype
        case (true, true):
            return .sideBySideAggregatesOnly
        }
    }
}

/// Public pure entry point for the Phase 5 comparison report seam.
public enum HTTP3PrototypeComparison {
    /// Build a report from two already-bounded path aggregates.
    ///
    /// Typical inputs: process health `OutboundQueueWaitLaneMetrics` for the
    /// current path, and offline harness aggregates for the prototype path.
    public static func report(
        currentHTTPWebSocket: ProtocolPathDurationAggregate,
        quicPrototype: ProtocolPathDurationAggregate
    ) -> HTTP3PrototypeComparisonReport {
        HTTP3PrototypeComparisonReport(
            currentHTTPWebSocket: currentHTTPWebSocket,
            quicPrototype: quicPrototype
        )
    }

    /// Convenience: fold existing queue-wait lane metrics for the current path
    /// against an externally supplied prototype aggregate.
    public static func report(
        currentLane: OutboundQueueWaitLaneMetrics,
        quicPrototype: ProtocolPathDurationAggregate
    ) -> HTTP3PrototypeComparisonReport {
        report(
            currentHTTPWebSocket: ProtocolPathDurationAggregate(lane: currentLane),
            quicPrototype: quicPrototype
        )
    }

    /// Fold mixed external samples by path label into a side-by-side report
    /// with nearest-rank p50/p95/p99 on each path's sanitized series.
    public static func report(
        samples: [ProtocolPathDurationSample]
    ) -> HTTP3PrototypeComparisonReport {
        var currentSamples: [Double] = []
        var prototypeSamples: [Double] = []
        for sample in samples {
            switch sample.path {
            case .currentHTTPWebSocket:
                currentSamples.append(sample.durationMilliseconds)
            case .quicPrototype:
                prototypeSamples.append(sample.durationMilliseconds)
            }
        }
        return report(
            currentHTTPWebSocket: ProtocolPathDurationAggregate.folding(currentSamples),
            quicPrototype: ProtocolPathDurationAggregate.folding(prototypeSamples)
        )
    }
}
