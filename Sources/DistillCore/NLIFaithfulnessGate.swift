import Foundation

/// I8.2: NLI reject-only faithfulness gate (SummaC pattern). The compressed output's
/// key claims must be ENTAILED by the source; a contradiction or low entailment rejects
/// toward the original. The entailment scorer is injected (real backend =
/// `MLXBertClassifierBackend.entailment`), so the gate stays pure + testable and FAIL-OPEN:
/// if the model is unavailable or errors, the gate accepts and defers to the deterministic
/// faithfulness stack (it never blocks on the model, never escalates).
public struct NLIFaithfulnessGate: Sendable {
    public typealias EntailFn = @Sendable (_ premise: String, _ hypothesis: String) async throws -> (entail: Float, contradict: Float)

    public let entail: EntailFn
    public let minEntailment: Float
    public let maxContradiction: Float

    public init(minEntailment: Float = 0.50, maxContradiction: Float = 0.30, entail: @escaping EntailFn) {
        self.minEntailment = minEntailment
        self.maxContradiction = maxContradiction
        self.entail = entail
    }

    /// Validate each non-trivial claim line of `compressed` against the `original` source.
    /// Rejects on the first contradicted / unentailed claim.
    public func validate(original: String, compressed: String) async -> FaithfulnessGate.Result {
        if compressed == original { return .accepted }
        let claims = compressed
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 12 }   // skip trivial fragments
        for claim in claims {
            do {
                let v = try await entail(original, claim)
                if v.contradict > maxContradiction {
                    return .rejected(String(format: "nli_contradiction %.2f: %@", v.contradict, claim))
                }
                if v.entail < minEntailment {
                    return .rejected(String(format: "nli_low_entailment %.2f: %@", v.entail, claim))
                }
            } catch {
                return .accepted   // fail-open: defer to the deterministic stack
            }
        }
        return .accepted
    }
}

/// I8.4: NER booster for the anti-hallucination check — UNION-only. Named entities that
/// appear in the compressed output must also appear in the original (a fabricated person /
/// org / location is a hallucination). The entity extractor is injected (real backend =
/// `MLXBertClassifierBackend.entities`). UNION-only: NER only ADDS rejections; it never
/// removes a deterministic pin, and a model error is fail-open.
public struct NERHallucinationBooster: Sendable {
    public typealias EntitiesFn = @Sendable (_ text: String) async throws -> [String]
    public let entities: EntitiesFn
    public init(entities: @escaping EntitiesFn) { self.entities = entities }

    /// Returns the first hallucinated entity (present in output, absent from original), or nil.
    public func hallucinatedEntity(original: String, compressed: String) async -> String? {
        guard compressed != original else { return nil }
        do {
            let outputEntities = try await entities(compressed)
            for e in outputEntities where !e.isEmpty && !original.localizedCaseInsensitiveContains(e) {
                return e
            }
            return nil
        } catch {
            return nil   // fail-open
        }
    }
}
