import Foundation

/// I3.5 / I3.8 / I6.9 / I9.8 / I10.9: shadow-mode + harm-proxy harness.
///
/// In shadow mode a lane computes what it WOULD prune/elide but does not apply it —
/// the live output is byte-identical to baseline (proved separately by flag-off
/// parity, M12). This evaluator records those shadow decisions and the primary harm
/// proxy: a span that was pruned-in-shadow but later hit by `rc_retrieve` or a
/// re-request would have been a real loss if applied. Flag-on downstream is gated on
/// this MISS-RATE (not on accept-rate), per the plan. It also counts failure-
/// suppression events (a FAIL/ERROR line present in the original but absent from a
/// lane's shadow output) — the hard gate for any lossy crusher.
public actor ShadowEvaluator {
    private var shadowPrunedSpanIDs: Set<String> = []
    private var shadowPrunedByLane: [String: Int] = [:]
    private var harmHitSpanIDs: Set<String> = []
    private var failureSuppressionByLane: [String: Int] = [:]
    private var nominateCount = 0
    private var disposeCount = 0

    public init() {}

    /// A lane decided (in shadow) it would prune these spans. Not applied.
    public func recordShadowPrune(lane: String, spanIDs: [String]) {
        shadowPrunedByLane[lane, default: 0] += spanIDs.count
        for id in spanIDs { shadowPrunedSpanIDs.insert(id) }
    }

    /// A previously shadow-pruned span was later retrieved / re-requested → harm signal.
    public func recordRetrieve(spanID: String) {
        if shadowPrunedSpanIDs.contains(spanID) { harmHitSpanIDs.insert(spanID) }
    }

    /// I9.8: dedup nominate/dispose accounting for the shadow ledger.
    public func recordNominate() { nominateCount += 1 }
    public func recordDispose() { disposeCount += 1 }

    /// I10.9: a FAIL/ERROR line in the original vanished from a lane's shadow output.
    /// This must be ZERO before any lossy crusher goes default-on.
    public func recordFailureSuppression(lane: String) {
        failureSuppressionByLane[lane, default: 0] += 1
    }

    public var shadowPrunedCount: Int { shadowPrunedSpanIDs.count }
    public var harmHitCount: Int { harmHitSpanIDs.count }
    public var nominateDispose: (nominate: Int, dispose: Int) { (nominateCount, disposeCount) }
    public func failureSuppressionEvents(lane: String) -> Int { failureSuppressionByLane[lane] ?? 0 }
    public var totalFailureSuppressionEvents: Int { failureSuppressionByLane.values.reduce(0, +) }

    /// I3.8: harm-proxy miss-rate = shadow-pruned spans later retrieved / shadow-pruned.
    public var missRate: Double {
        shadowPrunedSpanIDs.isEmpty ? 0 : Double(harmHitSpanIDs.count) / Double(shadowPrunedSpanIDs.count)
    }

    /// Flag-on is recommended only when the harm miss-rate is below threshold AND no
    /// lane suppressed a failure line (I3.8 / I10.9). Accept-rate is NOT used.
    public func flagOnRecommended(maxMissRate: Double = 0.01) -> Bool {
        missRate <= maxMissRate && totalFailureSuppressionEvents == 0
    }

    /// Detect failure-suppression deterministically: lines matching FAIL/ERROR/✕/"not ok"
    /// present in `original` but absent from `shadowOutput`.
    public static func suppressesFailure(original: String, shadowOutput: String) -> Bool {
        let pattern = #"(?i)\b(fail|failed|failure|error|panic|✕|not ok)\b"#
        let outLines = Set(shadowOutput.split(whereSeparator: \.isNewline).map(String.init))
        for line in original.split(whereSeparator: \.isNewline).map(String.init) {
            guard line.range(of: pattern, options: .regularExpression) != nil else { continue }
            if !outLines.contains(line) && !shadowOutput.contains(line) { return true }
        }
        return false
    }
}
