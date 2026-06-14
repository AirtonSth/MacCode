import Foundation

public extension TokenSaverEncoderManifest {
    /// I3.6: scorer / reranker / nli / colbert roles must NEVER head-truncate (an error
    /// line at the EOF must still be scored), so a chunk-policy is mandatory for them.
    var forbidsHeadTruncation: Bool {
        ["reranker", "colbert-ranker", "classifier", "scorer", "nli"].contains(role)
    }

    var hasChunkPolicy: Bool { !chunkPolicy.trimmingCharacters(in: .whitespaces).isEmpty }

    /// A manifest is structurally usable only if its role's chunk-policy requirement is met.
    var chunkPolicySatisfied: Bool { !forbidsHeadTruncation || hasChunkPolicy }
}

/// V10: encoder RAM budget. The ModernBERT trunk is SHARED across heads (routing /
/// PASS-FAIL / keep-drop / NER), so the total budget is ~350–450 MB; the worst-case
/// M1 8GB host caps a single encoder at ≤150M params int8. Classification heads run on
/// the ANE (zero contention with the MLX GPU).
public enum EncoderBudgetPolicy {
    public static let maxParamsMillions8GB = 150
    public static let sharedTrunkBudgetMB = 450

    public static func withinHostBudget(paramsMillions: Int, hostRAMGB: Int) -> Bool {
        // The 8GB cap is the tightest; larger hosts allow proportionally more.
        let cap = hostRAMGB <= 8 ? maxParamsMillions8GB : maxParamsMillions8GB * (hostRAMGB / 8)
        return paramsMillions <= cap
    }

    /// Total shared-trunk + heads must fit the budget (int8/fp16 only — V4).
    public static func sharedTrunkFits(totalMB: Int, quantization: String) -> Bool {
        TokenSaverEncoderManifest.isApprovedQuantization(quantization) && totalMB <= sharedTrunkBudgetMB
    }
}

/// I3.4: the encoder install is OPTIONAL. The launch gate keys ONLY on the LLM manifest;
/// an absent encoder yields a `disabled` ready state, NEVER a `.requireModel` failure.
public enum EncoderInstallPolicy {
    public enum ReadyState: String, Sendable, Equatable { case enabled, disabled }

    /// Never throws / never requires. Absent encoder → disabled (service still ready).
    public static func readyState(encoderInstalled: Bool) -> ReadyState {
        encoderInstalled ? .enabled : .disabled
    }

    /// The launch planner must NOT make the encoder a hard requirement.
    public static var isHardLaunchRequirement: Bool { false }
}

/// I3.9: adversarial parity harness. Before a converted encoder ships it must match the
/// reference per artifact type (logs/code/ANSI/unicode/empty), share a tokenizer, and
/// not collapse to a constant label (the DeBERTa export hazard). Pure scoring logic; the
/// caller supplies reference-vs-converted scores from real runs / a fixture corpus.
public enum EncoderParityHarness {
    public struct ArtifactCase: Sendable, Equatable {
        public let kind: String          // "log8k" | "code" | "ansi" | "unicode" | "empty"
        public let referenceScore: Double
        public let convertedScore: Double
        public init(kind: String, referenceScore: Double, convertedScore: Double) {
            self.kind = kind; self.referenceScore = referenceScore; self.convertedScore = convertedScore
        }
    }

    public struct Verdict: Sendable, Equatable {
        public let shipsModel: Bool
        public let reason: String
        public let maxAbsDelta: Double
    }

    public static let requiredKinds: Set<String> = ["log8k", "code", "ansi", "unicode", "empty"]

    public static func evaluate(
        cases: [ArtifactCase],
        tokenizerEquivalent: Bool,
        tolerance: Double = 1e-3
    ) -> Verdict {
        guard tokenizerEquivalent else {
            return Verdict(shipsModel: false, reason: "tokenizer_mismatch", maxAbsDelta: .infinity)
        }
        // Every required artifact kind must be exercised (no silent coverage gap).
        let covered = Set(cases.map(\.kind))
        guard requiredKinds.isSubset(of: covered) else {
            return Verdict(shipsModel: false, reason: "artifact_coverage_gap", maxAbsDelta: .infinity)
        }
        // Output-variance: converted outputs must not be a constant label.
        let convertedValues = Set(cases.map { ($0.convertedScore * 1e6).rounded() })
        if convertedValues.count <= 1 {
            return Verdict(shipsModel: false, reason: "constant_label_output_variance", maxAbsDelta: 0)
        }
        let maxDelta = cases.map { abs($0.referenceScore - $0.convertedScore) }.max() ?? 0
        if maxDelta > tolerance {
            return Verdict(shipsModel: false, reason: "parity_delta_exceeds_tolerance", maxAbsDelta: maxDelta)
        }
        return Verdict(shipsModel: true, reason: "parity_ok", maxAbsDelta: maxDelta)
    }
}
