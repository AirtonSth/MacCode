import Foundation
import CryptoKit

/// I4.3: skip-set for inputs that are KNOWN not to compress, so the scheduler can skip
/// the expensive runtime entirely. To honour the plan's hard rule that transient errors
/// (429/deadline/queueFull) must NEVER enter the skip-set, this records ONLY *deterministic*
/// rejections: an input the pure content router returns nil for AND whose size is below a
/// gain floor. Those outcomes never depend on the model or on load, so skipping them is
/// always safe. (The "model-rejected" subset is deliberately excluded — it can't be told
/// apart from a transient fail-open at this layer.)
public struct DeterministicSkipSet: Sendable {
    private var entries: [String: Int] = [:]   // inputSHA -> turnRecorded (logical clock)
    private let ttlTurns: Int

    public init(ttlTurns: Int = 60) { self.ttlTurns = max(1, ttlTurns) }

    public static func key(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Record a DETERMINISTIC non-compressible verdict. `routerReturnedNil` must be the
    /// pure router's outcome; `belowGainFloor` a deterministic size check.
    public mutating func recordIfDeterministic(input: String, routerReturnedNil: Bool, belowGainFloor: Bool, now: Int) {
        guard routerReturnedNil, belowGainFloor else { return }
        entries[Self.key(input)] = now
    }

    /// Transient errors must never poison the skip-set — this is an explicit no-op so the
    /// intent is documented and testable.
    public mutating func recordTransientError(input: String) { /* intentionally ignored (I4.3) */ }

    public func shouldSkip(input: String, now: Int) -> Bool {
        guard let recorded = entries[Self.key(input)] else { return false }
        return now - recorded < ttlTurns
    }

    public var count: Int { entries.count }
}

/// I4.7 (phase 2): yield predictor with SKIP-ONLY authority. It may recommend skipping a
/// low-yield compression, but it can NEVER force a compression nor loosen any gate. Cheap
/// (static features only). An epsilon exploration rate keeps the labels unbiased.
public enum YieldPredictor {
    public enum Recommendation: String, Sendable, Equatable { case attempt, skipLowYield }

    /// `explore` is the caller-supplied exploration draw (true ~epsilon of the time) so the
    /// predictor stays pure/deterministic and testable.
    public static func recommend(
        inputChars: Int,
        isStructured: Bool,
        priorAcceptRate: Double,
        minChars: Int = 256,
        explore: Bool = false
    ) -> Recommendation {
        if explore { return .attempt }                 // epsilon exploration → always attempt
        if inputChars < minChars { return .skipLowYield }
        if !isStructured && priorAcceptRate < 0.05 { return .skipLowYield }
        return .attempt
    }
}
