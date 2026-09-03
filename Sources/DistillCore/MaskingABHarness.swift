import Foundation

/// I5.8 / M10: A/B evaluation harness for stale-read masking on a fixed agentic
/// corpus. Compares a baseline arm (no masking) against a masked arm over paired
/// tasks and decides whether masking may stay on: solve-rate must be NON-INFERIOR
/// (within a margin) and the turn-count and retrieval-rate regressions must stay
/// under their caps. Pure value logic so it runs as a deterministic CI gate; the
/// "fixed corpus" is supplied by the caller (absent corpus is a caller-side XCTFail,
/// never a silent skip).
public struct MaskingABHarness: Sendable {
    public struct Arm: Sendable, Equatable {
        public let solved: [Bool]      // per-task solve outcome
        public let turnCounts: [Int]   // per-task turns taken
        public let retrieves: [Int]    // per-task rc_retrieve round-trips
        public init(solved: [Bool], turnCounts: [Int], retrieves: [Int]) {
            self.solved = solved; self.turnCounts = turnCounts; self.retrieves = retrieves
        }
        // Single pass: count solved without a filter intermediate.
        var solveRate: Double { solved.isEmpty ? 0 : Double(solved.reduce(0) { $0 + ($1 ? 1 : 0) }) / Double(solved.count) }
        var avgTurns: Double { turnCounts.isEmpty ? 0 : Double(turnCounts.reduce(0,+)) / Double(turnCounts.count) }
        var avgRetrieves: Double { retrieves.isEmpty ? 0 : Double(retrieves.reduce(0,+)) / Double(retrieves.count) }
    }

    public struct Decision: Sendable, Equatable {
        public let keepMaskingOn: Bool
        public let solveRateBaseline: Double
        public let solveRateMasked: Double
        public let turnCountDelta: Double
        public let retrieveRateDelta: Double
        public let reason: String
    }

    /// - nonInferiorityMargin: max allowed solve-rate drop (e.g. 0.02).
    /// - turnCountDeltaCap: max allowed increase in avg turns (e.g. 0.5).
    /// - retrieveRateDeltaCap: max allowed increase in avg retrieves (e.g. 0.5).
    public static func evaluate(
        baseline: Arm,
        masked: Arm,
        nonInferiorityMargin: Double = 0.02,
        turnCountDeltaCap: Double = 0.5,
        retrieveRateDeltaCap: Double = 0.5
    ) -> Decision {
        let dropped = baseline.solveRate - masked.solveRate
        let turnDelta = masked.avgTurns - baseline.avgTurns
        let retrieveDelta = masked.avgRetrieves - baseline.avgRetrieves

        var keep = true
        var reason = "non_inferior_within_caps"
        if dropped > nonInferiorityMargin {
            keep = false; reason = "solve_rate_inferior"
        } else if turnDelta > turnCountDeltaCap {
            keep = false; reason = "turn_count_regression"
        } else if retrieveDelta > retrieveRateDeltaCap {
            keep = false; reason = "retrieve_rate_regression"
        }
        return Decision(
            keepMaskingOn: keep,
            solveRateBaseline: baseline.solveRate,
            solveRateMasked: masked.solveRate,
            turnCountDelta: turnDelta,
            retrieveRateDelta: retrieveDelta,
            reason: reason
        )
    }
}
