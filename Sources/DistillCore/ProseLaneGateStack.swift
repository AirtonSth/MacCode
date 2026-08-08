import Foundation

/// I12.7: the four stacked gates the lossy prose-pruning lane must pass, all
/// reject-toward-original, applied in order. The lane refuses to run at all without a
/// reversible handle (so any elision is recoverable). This composes the existing
/// deterministic gates; the NLI gate (I8.2) plugs in as the optional 2nd-stage and
/// defaults to the deterministic reverse-coverage in `FaithfulnessGate` when absent.
public enum ProseLaneGateStack {
    public struct Verdict: Sendable, Equatable {
        public let accepted: Bool
        public let output: String      // compressed if accepted, else original
        public let reason: String
    }

    /// - minGainRatio: gate 3 — never inflate, require a real win (default 0.10).
    /// - netPositiveBilled: gate 4 — billed-dollar net-positivity must hold.
    public static func evaluate(
        original: String,
        compressed: String,
        handle: String?,
        minGainRatio: Double = 0.10,
        netPositiveBilled: Bool = true
    ) -> Verdict {
        // Precondition: no handle → refuse to run (elision must be recoverable).
        guard let handle, !handle.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Verdict(accepted: false, output: original, reason: "no_reversible_handle")
        }
        // Gate 1: LiteralPreservation (+ NER pins, when present) verbatim.
        let literal = LiteralPreservation.guarded(original: original, compressed: compressed)
        if literal.droppedLiteral != nil {
            return Verdict(accepted: false, output: original, reason: "literal_dropped:\(literal.droppedLiteral!)")
        }
        // Gate 2: faithfulness (NLI + reverse coverage; deterministic reverse-coverage default).
        let faithful = FaithfulnessGate.validate(original: original, compressed: compressed)
        if !faithful.accepted {
            return Verdict(accepted: false, output: original, reason: faithful.reason ?? "unfaithful")
        }
        // Gate 3: minGainRatio + never-inflate.
        // PERF: O(1) utf8.count (not Character.count grapheme walk); matches
        // DistillContentRouter.meetsGain and byte-oriented Token Saver savings.
        let originalBytes = original.utf8.count
        let compressedBytes = compressed.utf8.count
        guard originalBytes > 0, compressedBytes < originalBytes else {
            return Verdict(accepted: false, output: original, reason: "no_gain")
        }
        let reduction = 1.0 - Double(compressedBytes) / Double(originalBytes)
        if reduction < minGainRatio {
            return Verdict(accepted: false, output: original, reason: "below_min_gain")
        }
        // Gate 4: net-positivity in billed dollars.
        guard netPositiveBilled else {
            return Verdict(accepted: false, output: original, reason: "net_negative")
        }
        return Verdict(accepted: true, output: compressed, reason: "accepted")
    }
}
