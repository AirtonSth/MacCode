import Foundation
import CoreModel

/// Provider-neutral meaning extracted before choosing an SR2 spelling.
/// This is deliberately separate from encoding so future model-specific
/// vocabularies/tokenizers can change without changing semantic parsing.
public struct SR2SemanticIR: Sendable, Equatable {
    public let source: String
    public let requirements: [String]
    public let requirementConcepts: [Set<String>]
    public let anchors: Set<String>
    public let requiresOrdering: Bool
    public let hasCompletionCondition: Bool
    public let hasProhibition: Bool
    public let hasMandatoryConstraint: Bool
    public let hasConditionalConstraint: Bool
    public let hasAlternative: Bool

    public static func parse(_ source: String) -> SR2SemanticIR {
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()
        let requirements = normalized
            .components(separatedBy: CharacterSet(charactersIn: ".;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let requiresOrdering = containsAny(lower, [
            " after ", " before ", " then ", " once ", "only after", "until ",
            " depois ", " antes ", " apos ", " após ", " somente apos", " somente após", " ate ", " até "
        ]) || ["after ", "before ", "once ", "depois ", "antes ", "apos ", "após "]
            .contains(where: lower.hasPrefix)
        let hasConditionalConstraint = containsAny(lower, [
            " if ", "unless ", "only if", "provided that", "as long as",
            " caso ", " somente se", " apenas se", " desde que"
        ]) || ["if ", "unless ", "caso ", "desde que "].contains(where: lower.hasPrefix)
        return SR2SemanticIR(
            source: normalized,
            requirements: requirements,
            requirementConcepts: requirements.map(semanticConcepts),
            anchors: semanticAnchors(in: normalized),
            requiresOrdering: requiresOrdering,
            hasCompletionCondition: containsAny(lower, [
                "not complete until", "complete only", "completion requires", "done only",
                "não estará complet", "nao estara complet", "só estará complet", "so estara complet",
                "conclusão exige", "conclusao exige"
            ]),
            hasProhibition: containsAny(lower, [
                "must not", "do not", "never ", "forbidden", "prohibited",
                "não ", "nao ", "nunca ", "proib"
            ]),
            hasMandatoryConstraint: containsAny(lower, [
                "must ", "required", "mandatory", "every ", "all ",
                "deve ", "obrigat", "todos ", "todas "
            ]),
            hasConditionalConstraint: hasConditionalConstraint,
            hasAlternative: lower.contains(" or ") || lower.contains(" ou ")
        )
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains(where: text.contains)
    }

    private static func semanticAnchors(in text: String) -> Set<String> {
        let patterns = [
            #"/[A-Za-z][A-Za-z0-9_-]*"#,
            #"\b(?=[A-Za-z0-9_-]*\d)[A-Za-z0-9]+(?:[-_][A-Za-z0-9]+)+\b"#,
            #"\b(?:Trello|Playwright|Chrome|Computer Use|GitHub|GitLab|Railway|Codex|Claude|Grok|Gemini|gh|glab)\b"#
        ]
        var anchors = LiteralPreservation.pinnedLiterals(in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard let matched = Range(match.range, in: text) else { continue }
                anchors.insert(String(text[matched]))
            }
        }
        return anchors
    }

    /// Conservative behavior concepts used as a host-side loss detector.
    /// Grammar words are removed because modality/order/completion are checked
    /// structurally; domain words remain, so an SR2 candidate that silently
    /// drops an action such as `update docs` fails open to the source.
    static func semanticConcepts(in text: String) -> Set<String> {
        var normalized = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let phrases: [(String, String)] = [
            ("post-deployment testing", "retest"),
            ("post deployment testing", "retest"),
            ("teste pos-deploy", "retest"),
            ("testar apos deploy", "retest"),
            ("computer use", "computeruse")
        ]
        for (source, canonical) in phrases {
            normalized = normalized.replacingOccurrences(of: source, with: canonical)
        }
        let stopWords: Set<String> = [
            "a", "an", "the", "to", "of", "in", "on", "for", "from", "with", "and", "or",
            "as", "at", "by", "it", "this", "that", "these", "those", "be", "is", "are", "was",
            "were", "been", "being", "do", "does", "did", "will", "would", "can", "could", "should",
            "must", "may", "might", "please", "use", "using", "when", "while", "once", "after", "before",
            "then", "only", "until", "every", "all", "not", "no", "task", "skill", "succeed", "succeeds",
            "successful", "successfully", "complete", "completion", "required", "mandatory",
            "o", "a", "os", "as", "um", "uma", "de", "do", "da", "dos", "das", "em", "no", "na",
            "nos", "nas", "para", "por", "com", "e", "ou", "que", "se", "isso", "este", "esta", "usar",
            "use", "quando", "enquanto", "depois", "antes", "apos", "somente", "ate", "todos", "todas",
            "deve", "nao", "nunca", "tarefa", "habilidade", "concluir", "conclusao", "obrigatorio"
        ]
        let canonicalPrefixes: [(String, String)] = [
            ("verif", "verify"), ("valid", "verify"),
            ("test", "test"),
            ("deploy", "deploy"), ("implant", "deploy"),
            ("merg", "merge"),
            ("revis", "review"),
            ("implement", "implement"),
            ("corrig", "fix"), ("fix", "fix"),
            ("coment", "comment"), ("comment", "comment"),
            ("mov", "move"),
            ("aguard", "wait"), ("wait", "wait"),
            ("constru", "build"), ("build", "build"),
            ("preserv", "preserve"),
            ("credencial", "credential"), ("credential", "credential"),
            ("repos", "repo")
        ]
        let words = normalized.split { character in
            !(character.isLetter || character.isNumber || character == "-" || character == "_" || character == "/")
        }
        var concepts: Set<String> = []
        for wordSlice in words {
            let word = String(wordSlice)
            guard word.count >= 2, !stopWords.contains(word) else { continue }
            if let canonical = canonicalPrefixes.first(where: { word.hasPrefix($0.0) })?.1 {
                concepts.insert(canonical)
            } else {
                concepts.insert(word)
            }
        }
        return concepts
    }
}

public struct SR2OptimizationDecision: Sendable, Equatable {
    public let output: String
    public let targetTokenizer: String
    public let originalTokens: Int
    public let optimizedTokens: Int
    public let reductionPercent: Double
    public let semanticCoverage: Double
    public let accepted: Bool
    public let rejectionReason: String?
}

/// Token-aware candidate selector. Candidate generation may evolve (MLX today,
/// provider-specific vocabularies later); this gate always owns adoption.
public enum SR2Optimizer {
    public typealias TokenCounter = @Sendable (String) -> Int

    public static func optimize(
        original: String,
        candidates: [String],
        targetTokenizer: String = "model-agnostic-estimator-v1",
        tokenCount: TokenCounter = { TokenEstimator.estimate($0) }
    ) -> SR2OptimizationDecision {
        let ir = SR2SemanticIR.parse(original)
        let originalTokens = max(0, tokenCount(original))
        var accepted: [(text: String, tokens: Int)] = []
        var rejection = "no valid SR2 candidate"

        for candidate in candidates {
            let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard SR2WirePolicy.isSR2(text) else {
                rejection = "candidate is not valid SR2"
                continue
            }
            if let reason = semanticRejection(ir: ir, candidate: text) {
                rejection = reason
                continue
            }
            let tokens = max(0, tokenCount(text))
            guard tokens < originalTokens else {
                rejection = "candidate does not reduce actual target-tokenizer tokens"
                continue
            }
            accepted.append((text, tokens))
        }

        guard let best = accepted.min(by: { $0.tokens < $1.tokens }) else {
            return SR2OptimizationDecision(
                output: original,
                targetTokenizer: targetTokenizer,
                originalTokens: originalTokens,
                optimizedTokens: originalTokens,
                reductionPercent: 0,
                semanticCoverage: 0,
                accepted: false,
                rejectionReason: rejection
            )
        }
        let reduction = originalTokens > 0
            ? (Double(originalTokens - best.tokens) / Double(originalTokens)) * 100
            : 0
        return SR2OptimizationDecision(
            output: best.text,
            targetTokenizer: targetTokenizer,
            originalTokens: originalTokens,
            optimizedTokens: best.tokens,
            reductionPercent: reduction,
            semanticCoverage: 1,
            accepted: true,
            rejectionReason: nil
        )
    }

    private static func semanticRejection(ir: SR2SemanticIR, candidate: String) -> String? {
        let compactCandidate = compactSemanticKey(candidate)
        for anchor in ir.anchors where !candidate.localizedCaseInsensitiveContains(anchor)
            && !compactCandidate.contains(compactSemanticKey(anchor)) {
            return "semantic anchor missing: \(anchor)"
        }
        let lower = candidate.lowercased()
        if ir.requiresOrdering, !(lower.contains("flow:") && candidate.contains(">")) {
            return "ordering dependency missing"
        }
        if ir.hasCompletionCondition, !lower.contains("done:") {
            return "completion condition missing"
        }
        if ir.hasProhibition, !lower.contains("not:") {
            return "prohibition missing"
        }
        if ir.hasMandatoryConstraint,
           !lower.contains("must:"),
           !lower.contains("flow:") {
            return "mandatory constraint missing"
        }
        if ir.hasConditionalConstraint,
           !lower.contains("constraints:"),
           !lower.contains("flow:") {
            return "conditional constraint missing"
        }
        if ir.hasAlternative, !candidate.contains("|") {
            return "alternative semantics missing"
        }
        let candidateConcepts = SR2SemanticIR.semanticConcepts(in: candidate)
        for (index, concepts) in ir.requirementConcepts.enumerated() {
            let missing = concepts.subtracting(candidateConcepts)
            if let concept = missing.sorted().first {
                return "requirement \(index + 1) concept missing: \(concept)"
            }
        }
        let literalResult = LiteralPreservation.guarded(original: ir.source, compressed: candidate)
        if let dropped = literalResult.droppedLiteral {
            return "literal missing: \(dropped)"
        }
        return nil
    }

    private static func compactSemanticKey(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}
