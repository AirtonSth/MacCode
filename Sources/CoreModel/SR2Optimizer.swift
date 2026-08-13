import Foundation

public enum SR2Modality: String, Sendable, Equatable, Hashable {
    case must
    case mustNot
    case should
    case may
}

public struct SR2PredicateBinding: Sendable, Equatable, Hashable {
    public let predicate: String
    public let modality: SR2Modality
}

public struct SR2ConditionBinding: Sendable, Equatable, Hashable {
    public let predicate: String
    public let condition: String
    public let kind: String
}

public struct SR2OrderingEdge: Sendable, Equatable, Hashable {
    public let predecessor: String
    public let successor: String
}

public enum SR2LogicalRelation: String, Sendable, Equatable, Hashable {
    case all
    case any
}

public struct SR2LogicalGroup: Sendable, Equatable, Hashable {
    public let field: String
    public let concepts: Set<String>
    public let relation: SR2LogicalRelation
}

/// Provider-neutral meaning extracted before choosing an SR2 spelling.
/// This is deliberately separate from encoding so future model-specific
/// vocabularies/tokenizers can change without changing semantic parsing.
public struct SR2SemanticIR: Sendable, Equatable {
    public let source: String
    public let requirements: [String]
    public let requirementConcepts: [Set<String>]
    public let anchors: Set<String>
    public let orderedCommands: [String]
    /// Backtick-delimited shell segments. A segment may contain multiple
    /// exact probes (for example `command -v swift; command -v distill`), so
    /// indexed output cardinality binds to these groups rather than to a
    /// flattened global line count.
    public let orderedCommandGroups: [String]
    public let exactOutputLineCount: Int?
    /// Explicit per-segment cardinality, keyed one-based by ordered command
    /// group. An empty map means the legacy global `out:=Nlines` contract.
    public let exactOutputLineCounts: [Int: Int]
    public let prohibitsFileEdits: Bool
    public let predicateBindings: Set<SR2PredicateBinding>
    public let hasUnboundModality: Bool
    public let conditionBindings: Set<SR2ConditionBinding>
    public let orderingEdges: Set<SR2OrderingEdge>
    public let completionConcepts: Set<String>
    public let logicalGroups: Set<SR2LogicalGroup>
    public let requiresOrdering: Bool
    public let hasCompletionCondition: Bool
    public let hasProhibition: Bool
    public let hasMandatoryConstraint: Bool
    public let hasConditionalConstraint: Bool
    public let hasAlternative: Bool

    public static func parse(
        _ source: String,
        semanticSource: String? = nil,
        semanticSegments: [String]? = nil
    ) -> SR2SemanticIR {
        // The default is deliberately lossless: only a trusted host call site
        // may provide a separate semantic source for an envelope. Segments are
        // already provenance-separated by that host boundary; never discover
        // them from marker text in `source`.
        let trustedSource = semanticSegments?.isEmpty == false
            ? semanticSegments!.joined(separator: "\n")
            : (semanticSource ?? source)
        let normalized = trustedSource
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()
        let genericConstraintText = removingFileEditProhibitions(from: fold(normalized))
        let orderedCommands = exactCommandSequence(in: normalized)
        let orderedCommandGroups = exactCommandGroups(in: normalized)
        let exactOutputLineCount = exactLineCount(in: lower, commandCount: orderedCommands.count)
        let exactOutputLineCounts = exactOutputLineCounts(
            in: normalized,
            groupCount: orderedCommandGroups.count
        )
        let predicateBindings = explicitPredicateBindings(in: normalized)
        let hasUnboundModality = modalityMarkerCount(in: normalized) != boundModalityClauseCount(in: normalized)
        let conditionBindings = conditionalBindings(in: normalized)
        let orderingEdges = sourceOrderingEdges(in: normalized)
        let completionConcepts = sourceCompletionConcepts(in: normalized)
        let logicalGroups = sourceLogicalGroups(in: normalized)
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
            orderedCommands: orderedCommands,
            orderedCommandGroups: orderedCommandGroups,
            exactOutputLineCount: exactOutputLineCount,
            exactOutputLineCounts: exactOutputLineCounts,
            prohibitsFileEdits: containsAny(lower, [
                "do not edit files", "must not edit files", "never edit files",
                "no file edit", "no file edits",
                "não edite arquivos", "nao edite arquivos", "nunca edite arquivos"
            ]),
            predicateBindings: predicateBindings,
            hasUnboundModality: hasUnboundModality,
            conditionBindings: conditionBindings,
            orderingEdges: orderingEdges,
            completionConcepts: completionConcepts,
            logicalGroups: logicalGroups,
            requiresOrdering: requiresOrdering || orderedCommands.count > 1,
            hasCompletionCondition: containsAny(lower, [
                "not complete until", "complete only", "completion requires", "done only",
                "do not mark complete until", "do not mark it complete until",
                "when complete", "once complete",
                "ao concluir", "ao completar",
                "retorne um resumo curto confirmando as tres etapas",
                "resumo curto confirmando as tres etapas",
                "retorne um resumo curto confirmando as três etapas",
                "resumo curto confirmando as três etapas",
                "não estará complet", "nao estara complet", "só estará complet", "so estara complet",
                "conclusão exige", "conclusao exige"
            ]),
            hasProhibition: containsAny(lower, [
                "must not", "do not", "never ", "forbidden", "prohibited",
                "não ", "nao ", "nunca ", "proib"
            ]),
            hasMandatoryConstraint: containsAny(genericConstraintText, [
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

    private static func explicitPredicateBindings(in text: String) -> Set<SR2PredicateBinding> {
        let clauses = text
            .components(separatedBy: CharacterSet(charactersIn: ".;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var result = Set<SR2PredicateBinding>()
        for rawClause in clauses {
            let folded = removingFileEditProhibitions(from: fold(rawClause))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !folded.isEmpty else { continue }
            // This is a completion gate, not a MUST NOT predicate over the
            // words that follow it.
            if folded.hasPrefix("do not mark complete until ")
                || folded.hasPrefix("do not mark it complete until ") {
                continue
            }
            let modality: SR2Modality?
            let body: String
            if folded.hasPrefix("must not ") {
                modality = .mustNot
                body = String(folded.dropFirst("must not ".count))
            } else if folded.hasPrefix("must ") {
                modality = .must
                body = String(folded.dropFirst("must ".count))
            } else if folded.hasPrefix("should ") {
                modality = .should
                body = String(folded.dropFirst("should ".count))
            } else if folded.hasPrefix("may ") {
                modality = .may
                body = String(folded.dropFirst("may ".count))
            } else if folded.hasPrefix("do not ") {
                modality = .mustNot
                body = String(folded.dropFirst("do not ".count))
            } else if folded.hasPrefix("never ") {
                modality = .mustNot
                body = String(folded.dropFirst("never ".count))
            } else if folded.hasPrefix("nao deve ") {
                modality = .mustNot
                body = String(folded.dropFirst("nao deve ".count))
            } else if folded.hasPrefix("nao ") {
                modality = .mustNot
                body = String(folded.dropFirst("nao ".count))
            } else if folded.hasPrefix("deve ") {
                modality = .must
                body = String(folded.dropFirst("deve ".count))
            } else {
                modality = nil
                body = folded
            }
            guard let modality else { continue }
            for predicateBody in fold(body).components(separatedBy: " and ") {
                let predicate = predicateKey(predicateBody)
                if !predicate.isEmpty {
                    result.insert(.init(predicate: predicate, modality: modality))
                }
            }
        }
        return result
    }

    private static func modalityMarkerCount(in text: String) -> Int {
        let folded = removingFileEditProhibitions(from: fold(text))
        let pattern = #"\b(?:must\s+not|must|should|may|do\s+not|never|nao\s+deve|deve|nao)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let range = NSRange(folded.startIndex..<folded.endIndex, in: folded)
        return regex.numberOfMatches(in: folded, range: range)
    }

    private static func boundModalityClauseCount(in text: String) -> Int {
        let prefixes = [
            "must not ", "must ", "should ", "may ", "do not ", "never ",
            "nao deve ", "deve ", "nao "
        ]
        return text
            .components(separatedBy: CharacterSet(charactersIn: ".;\n"))
            .map {
                removingFileEditProhibitions(
                    from: fold($0.trimmingCharacters(in: .whitespacesAndNewlines))
                ).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { clause in prefixes.contains(where: clause.hasPrefix) }
            .count
    }

    /// File-edit denial has its own typed IR bit and `!file-edit` encoding. Remove
    /// that one structural constraint before generic modality parsing so it is
    /// neither counted twice nor compared against candidate predicate fields.
    private static func removingFileEditProhibitions(from text: String) -> String {
        [
            "must not edit files", "do not edit files", "never edit files",
            "no file edits", "no file edit",
            "nao deve editar arquivos", "nao edite arquivos", "nunca edite arquivos"
        ].reduce(text) { partial, phrase in
            partial.replacingOccurrences(of: phrase, with: "")
        }
    }

    private static func conditionalBindings(in text: String) -> Set<SR2ConditionBinding> {
        let folded = fold(text)
        let patterns = [
            #"(?:^|[.;]\s*)(if|unless|only if)\s+([^,.;]+),\s*([^.;]+)"#,
            #"(?:^|[.;]\s*)(se|a menos que|somente se|apenas se)\s+([^,.;]+),\s*([^.;]+)"#
        ]
        var result = Set<SR2ConditionBinding>()
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(folded.startIndex..<folded.endIndex, in: folded)
            for match in regex.matches(in: folded, range: range) {
                guard let kindRange = Range(match.range(at: 1), in: folded),
                      let conditionRange = Range(match.range(at: 2), in: folded),
                      let predicateRange = Range(match.range(at: 3), in: folded) else { continue }
                let rawKind = String(folded[kindRange])
                let kind = ["unless", "a menos que"].contains(rawKind) ? "unless" : "if"
                let condition = predicateKey(String(folded[conditionRange]))
                let predicate = predicateKey(String(folded[predicateRange]))
                if !condition.isEmpty, !predicate.isEmpty {
                    result.insert(.init(predicate: predicate, condition: condition, kind: kind))
                }
            }
        }
        return result
    }

    private static func sourceOrderingEdges(in text: String) -> Set<SR2OrderingEdge> {
        // `then` between separate backticked shell commands is the command
        // sequence itself, not a prose predicate edge. The exact run field
        // preserves that order byte-for-byte.
        if exactCommandSequence(in: text).count > 1 {
            return []
        }
        let folded = fold(text)
        let patterns = [
            #"(?:after|depois de|apos)\s+([^,.;]+),\s*([^.;]+)"#,
            #"([^,.;]+),\s*(?:then|depois)\s+([^.;]+)"#
        ]
        var result = Set<SR2OrderingEdge>()
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(folded.startIndex..<folded.endIndex, in: folded)
            for match in regex.matches(in: folded, range: range) {
                guard let beforeRange = Range(match.range(at: 1), in: folded),
                      let afterRange = Range(match.range(at: 2), in: folded) else { continue }
                let predecessor = predicateKey(String(folded[beforeRange]))
                let successor = predicateKey(String(folded[afterRange]))
                if !predecessor.isEmpty, !successor.isEmpty {
                    result.insert(.init(predecessor: predecessor, successor: successor))
                }
            }
        }
        return result
    }

    private static func sourceCompletionConcepts(in text: String) -> Set<String> {
        let folded = fold(text)
        let patterns = [
            #"(?:not complete until|complete only after|done only after|completion requires|do not mark complete until|do not mark it complete until)\s+([^.;]+)"#,
            #"(?:nao estara complet[^ ]* ate|so estara complet[^ ]* depois de|conclusao exige)\s+([^.;]+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(folded.startIndex..<folded.endIndex, in: folded)
            guard let match = regex.firstMatch(in: folded, range: range),
                  let targetRange = Range(match.range(at: 1), in: folded) else { continue }
            let target = String(folded[targetRange])
            // A completion gate over every ordered command is represented by
            // `done:run`; do not force a lossy English paraphrase of the
            // command-success predicate into the wire.
            if target.contains("command") && target.contains("succeed") {
                return ["run"]
            }
            return semanticConcepts(in: target)
        }
        if folded.contains("when complete") || folded.contains("once complete")
            || folded.contains("ao concluir") || folded.contains("ao completar")
            || folded.contains("retorne um resumo curto confirmando as tres etapas")
            || folded.contains("resumo curto confirmando as tres etapas") {
            return folded.contains("summary") || folded.contains("resumo")
                ? ["run", "summary"]
                : ["run"]
        }
        return []
    }

    private static func sourceLogicalGroups(in text: String) -> Set<SR2LogicalGroup> {
        let folded = fold(text)
        let patterns: [(String, SR2LogicalRelation)] = [
            (#"(?:use|using)\s+([^.;]+?)\s+and\s+([^.;]+)"#, .all),
            (#"(?:use|using)\s+([^.;]+?)\s+or\s+([^.;]+)"#, .any),
            (#"(?:use|usar|use)\s+([^.;]+?)\s+e\s+([^.;]+)"#, .all),
            (#"(?:use|usar|use)\s+([^.;]+?)\s+ou\s+([^.;]+)"#, .any)
        ]
        var result = Set<SR2LogicalGroup>()
        for (pattern, relation) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(folded.startIndex..<folded.endIndex, in: folded)
            for match in regex.matches(in: folded, range: range) {
                guard let leftRange = Range(match.range(at: 1), in: folded),
                      let rightRange = Range(match.range(at: 2), in: folded) else { continue }
                let concepts = semanticConcepts(in: String(folded[leftRange]))
                    .union(semanticConcepts(in: String(folded[rightRange])))
                if concepts.count >= 2 {
                    result.insert(.init(field: "tools", concepts: concepts, relation: relation))
                }
            }
        }
        return result
    }

    fileprivate static func predicateKey(_ text: String) -> String {
        semanticConcepts(in: text).sorted().joined(separator: "+")
    }

    private static func fold(_ text: String) -> String {
        text.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }

    private static func exactCommandSequence(in text: String) -> [String] {
        let lower = text.lowercased()
        guard containsAny(lower, ["execute ", "run ", "command", "comando"]) else { return [] }
        let parts = text.split(separator: "`", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return [] }
        return stride(from: 1, to: parts.count, by: 2).flatMap { index in
            parts[index]
                .split(separator: ";", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }

    private static func exactCommandGroups(in text: String) -> [String] {
        let parts = text.split(separator: "`", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return [] }
        return stride(from: 1, to: parts.count, by: 2).compactMap { index in
            let commands = parts[index]
                .split(separator: ";", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !commands.isEmpty else { return nil }
            return commands.joined(separator: ";")
        }
    }

    /// Finds only command-local cardinalities between adjacent backtick
    /// segments. A trailing sentence such as "return exactly three lines"
    /// remains the legacy global contract; it must not be attached to the
    /// final ordinary command as though that command were exact.
    private static func exactOutputLineCounts(in text: String, groupCount: Int) -> [Int: Int] {
        guard groupCount > 1 else { return [:] }
        let parts = text.split(separator: "`", omittingEmptySubsequences: false)
        guard parts.count >= groupCount * 2 + 1 else { return [:] }
        var result: [Int: Int] = [:]
        for index in 0..<(groupCount - 1) {
            let connector = String(parts[(index * 2) + 2])
            if let count = localExactLineCount(in: connector) {
                result[index + 1] = count
            }
        }
        return result
    }

    private static func localExactLineCount(in text: String) -> Int? {
        let folded = text.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let patterns = [
            #"(?:return|retorne)\s+(?:exactly|exatamente)\s+(?:the\s+)?([0-9]+|one|two|three|uma|duas|tres)\s+lines?"#,
            #"\bexact(?:ly)?\s+([0-9]+|one|two|three|uma|duas|tres)\s+lines?"#,
            #"(?:preserve|preserv(?:e|a))\s+(?:exactly|exatamente)\s+(?:the\s+|as?\s+)?([0-9]+|one|two|three|uma|duas|tres)\s+(?:lines?|linhas?)"#,
            #"(?:preserve|preserv(?:e|a))\s+(?:exactly|exatamente)\s+(?:as?\s+)?(duas|uma)\s+linhas?"#
        ]
        let words: [String: Int] = [
            "one": 1, "two": 2, "three": 3,
            "uma": 1, "duas": 2, "tres": 3
        ]
        if folded.range(
            of: #"(?:preserve|preserv(?:e|a))\s+(?:exactly|exatamente)\s+a\s+(?:line|linha)"#,
            options: .regularExpression
        ) != nil {
            return 1
        }
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: folded,
                    range: NSRange(folded.startIndex..<folded.endIndex, in: folded)
                  ),
                  let valueRange = Range(match.range(at: 1), in: folded) else { continue }
            let value = String(folded[valueRange])
            return Int(value) ?? words[value]
        }
        return nil
    }

    private static func exactLineCount(in lower: String, commandCount: Int) -> Int? {
        let folded = lower.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let words: [String: Int] = [
            "one": 1, "two": 2, "three": 3,
            "uma": 1, "duas": 2, "tres": 3
        ]
        let patterns = [
            #"(?:return|retorne)\s+exactly\s+(?:the\s+)?([0-9]+|one|two|three)\s+lines?"#,
            #"(?:return|retorne)\s+exactly\s+(?:the\s+)?([0-9]+|one|two|three)\s+(?:responses?|outputs?)"#,
            #"(?:return|retorne)\s+exatamente\s+(?:as?\s+)?([0-9]+|uma|duas|tres)\s+(?:linhas?|respostas?|sa[ií]das?)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(folded.startIndex..<folded.endIndex, in: folded)
            guard let match = regex.firstMatch(in: folded, range: range),
                  let valueRange = Range(match.range(at: 1), in: folded) else { continue }
            let value = String(folded[valueRange])
            return Int(value) ?? words[value]
        }
        if commandCount > 0,
           lower.range(of: #"(?:each|every)\s+command(?:'s)?\s+(?:exact\s+)?(?:response|output|stdout)\s+(?:on|in)\s+(?:its|their|one)\s+own\s+line"#, options: .regularExpression) != nil {
            return commandCount
        }
        return nil
    }

    private static func semanticAnchors(in text: String) -> Set<String> {
        let patterns = [
            #"/[A-Za-z][A-Za-z0-9_-]*"#,
            #"\b(?=[A-Za-z0-9_-]*\d)[A-Za-z0-9]+(?:[-_][A-Za-z0-9]+)+\b"#,
            #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
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
        // `/goal` is host chrome, not a task constraint the compiled wire must echo.
        anchors = anchors.filter { $0.lowercased() != "/goal" }
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
        normalized = normalized.replacingOccurrences(
            of: #"\b\d+=(\d+)(line|lines)\b"#,
            with: "exact$1$2",
            options: .regularExpression
        )
        let phrases: [(String, String)] = [
            ("post-deployment testing", "retest"),
            ("post deployment testing", "retest"),
            ("teste pos-deploy", "retest"),
            ("testar apos deploy", "retest"),
            ("computer use", "computeruse"),
            ("commands", "command"),
            ("execute apenas", "run"),
            ("run only", "run"),
            ("retorne exatamente as duas linhas", "exact2lines"),
            ("return exactly the two lines", "exact2lines"),
            ("return exactly three lines", "exact3lines"),
            ("return exactly 3 lines", "exact3lines"),
            ("return exactly 2 lines", "exact2lines"),
            ("return exactly 1 line", "exact1line"),
            ("return a short summary when complete", "summary"),
            ("retorne um resumo curto", "summary"),
            ("resumo curto", "summary"),
            ("retorne um resumo curto confirmando as tres etapas", "summary"),
            ("preserve exatamente duas linhas", "exact2lines"),
            ("preserve exatamente 2 linhas", "exact2lines"),
            ("preserve exatamente as duas linhas", "exact2lines"),
            ("preserve exatamente uma linha", "exact1line"),
            ("preserve exatamente 1 linha", "exact1line"),
            ("preserve exatamente a linha", "exact1line"),
            ("distill its ordinary output", "run"),
            ("comprima sua saida normal com distill", "run"),
            ("comprima a saida normal com distill", "run"),
            ("exactly 2 lines", "exact2lines"),
            ("exactly 1 line", "exact1line"),
            ("exact 2 lines", "exact2lines"),
            ("exact 1 line", "exact1line"),
            ("=2lines", "exact2lines"),
            ("=3lines", "exact3lines"),
            ("nao edite arquivos", "fileedit"),
            ("edite arquivos", "fileedit"),
            ("editar arquivos", "fileedit"),
            ("do not edit files", "fileedit"),
            ("must not edit files", "fileedit"),
            ("edit files", "fileedit"),
            ("file-edit", "fileedit")
        ]
        for (source, canonical) in phrases {
            normalized = normalized.replacingOccurrences(of: source, with: canonical)
        }
        let stopWords: Set<String> = [
            "a", "an", "the", "to", "of", "in", "on", "for", "from", "with", "and", "or",
            "as", "at", "by", "it", "its", "this", "that", "these", "those", "be", "is", "are", "was",
            "were", "been", "being", "do", "does", "did", "will", "would", "can", "could", "should",
            "must", "may", "might", "please", "use", "using", "when", "while", "once", "after", "before",
            "then", "only", "until", "every", "all", "not", "no", "task", "skill", "order", "ordered", "succeed", "succeeds",
            "containing", "each", "line", "lines", "exact", "response", "responses", "return", "mark",
            "successfully", "complete", "completion", "required", "mandatory",
            "o", "a", "os", "as", "um", "uma", "de", "do", "da", "dos", "das", "em", "no", "na",
            "nos", "nas", "para", "por", "com", "e", "ou", "que", "se", "isso", "este", "esta", "usar",
            "use", "quando", "enquanto", "depois", "antes", "apos", "somente", "ate", "todos", "todas",
            "deve", "nao", "nunca", "tarefa", "habilidade", "concluir", "conclusao", "obrigatorio",
            "exatamente", "nesta", "ordem", "primeiro", "depois", "fim", "por", "ao",
            "confirmando", "etapa", "etapas", "tres"
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
            ("execut", "run"), ("run", "run"),
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
    public let targetTokenizerAvailable: Bool
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
    /// Frozen R7 production prompt fixture. Keep byte-identical: the live
    /// AgentMessage content is the semantic compiler's regression boundary.
    public static let r7LiveCompoundPrompt = "Execute exatamente nesta ordem e não edite arquivos: primeiro `command -v swift; command -v distill` e preserve exatamente as duas linhas; depois `rg -n UNIQUE_EXACT_MATCH README.md` e preserve exatamente a linha; por fim execute `swift noisy.swift`. Retorne um resumo curto confirmando as três etapas."
    public static let r7LiveCompoundPromptSHA256 = "95e2680cea6a18db08416d402f52d24bcd4abec9f821b2996d9419a3112a5b40"

    public typealias TokenCounter = @Sendable (String) -> Int
    public static let recognizedV1FieldKeys: Set<String> = [
        "g", "d", "p", "o", "e", "h", "t", "u",
        "flow", "done", "tools", "must", "should", "may", "not", "constraints", "outputs",
        "run", "out",
        "goal", "use", "browser", "auth", "pr", "comment", "trello-comment"
    ]

    /// Safe local lane for a deliberately small instruction grammar. It does
    /// not depend on project recovery state because every accepted candidate is
    /// self-contained and is re-validated by the same adoption gate as model
    /// candidates. Anything outside the grammar fails open to lossless v1.
    public static func compile(
        original: String,
        semanticSource: String? = nil,
        semanticSegments: [String]? = nil,
        targetTokenizer: String = "target-tokenizer-unavailable; model-agnostic-estimator-v1",
        targetTokenizerAvailable: Bool = false,
        tokenCount: TokenCounter = { TokenEstimator.estimate($0) }
    ) -> SR2OptimizationDecision {
        let source = semanticSegments?.isEmpty == false
            ? semanticSegments!.joined(separator: "\n")
            : (semanticSource ?? original)
        var candidates = deterministicCandidate(for: source).map { [$0] } ?? []
        if let naturalTask = SR2NaturalTaskCompiler.candidate(for: source),
           !candidates.contains(naturalTask) {
            candidates.append(naturalTask)
        }
        let losslessV1 = SR2WirePolicy.userInstructionWire(original)
        return optimize(
            original: original,
            candidates: candidates,
            semanticSource: semanticSource,
            semanticSegments: semanticSegments,
            targetTokenizer: targetTokenizer,
            targetTokenizerAvailable: targetTokenizerAvailable,
            tokenCount: { text in
                // The always-on provider boundary will emit lossless v1 when
                // semantic compilation is rejected, so that wire—not raw UI
                // prose—is the honest target-token comparison baseline.
                tokenCount(text == original ? losslessV1 : text)
            }
        )
    }

    public static func optimize(
        original: String,
        candidates: [String],
        semanticSource: String? = nil,
        semanticSegments: [String]? = nil,
        targetTokenizer: String = "target-tokenizer-unavailable; model-agnostic-estimator-v1",
        targetTokenizerAvailable: Bool = false,
        tokenCount: TokenCounter = { TokenEstimator.estimate($0) }
    ) -> SR2OptimizationDecision {
        let ir = SR2SemanticIR.parse(
            original,
            semanticSource: semanticSource,
            semanticSegments: semanticSegments
        )
        let originalTokens = max(0, tokenCount(original))
        var accepted: [(text: String, tokens: Int)] = []
        var rejection = "no valid SR2 candidate"

        for candidate in candidates {
            let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard hasSupportedOptimizerBanner(text) else {
                rejection = "candidate is missing the exact supported optimizer banner: @sr2 v1"
                continue
            }
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
            if !targetTokenizerAvailable {
                let saved = originalTokens - tokens
                guard saved >= 2, tokens * 100 <= originalTokens * 80 else {
                    rejection = "target tokenizer unavailable and estimator margin is not safely net-positive"
                    continue
                }
            }
            accepted.append((text, tokens))
        }

        guard let best = accepted.min(by: { $0.tokens < $1.tokens }) else {
            return SR2OptimizationDecision(
                output: original,
                targetTokenizer: targetTokenizer,
                targetTokenizerAvailable: targetTokenizerAvailable,
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
            targetTokenizerAvailable: targetTokenizerAvailable,
            originalTokens: originalTokens,
            optimizedTokens: best.tokens,
            reductionPercent: reduction,
            semanticCoverage: 1,
            accepted: true,
            rejectionReason: nil
        )
    }

    private static func semanticRejection(ir: SR2SemanticIR, candidate: String) -> String? {
        let lower = candidate.lowercased()
        if let dropped = firstMissingLiteral(ir: ir, candidate: candidate) {
            return "literal missing: \(dropped)"
        }
        // The bounded natural-task compiler consumes every non-empty source
        // line, rejects semantic operators inside scalar captures, and owns one
        // canonical spelling. Recompute it here so an MLX or caller candidate
        // cannot use `t:` as a bag of source words while changing ordering,
        // modality, preference policy, or role bindings.
        // A deterministic compiler spelling is a fast-accept, not the only
        // admissible encoding. The local LLM compiler may emit an equivalent
        // structured v1 that still has to pass the gates below.
        if let expectedNaturalTask = SR2NaturalTaskCompiler.candidate(for: ir.source),
           candidate == expectedNaturalTask {
            return nil
        }
        if ir.hasUnboundModality {
            if !ir.predicateBindings.isEmpty {
                return "source predicate modality could not be bound safely"
            }
            let encodedModality = field("must", in: candidate) != nil
                || field("not", in: candidate) != nil
                || field("should", in: candidate) != nil
                || field("may", in: candidate) != nil
                || candidate.contains("!")
            if !encodedModality {
                return "source predicate modality could not be bound safely"
            }
        }
        if ir.hasConditionalConstraint, ir.conditionBindings.isEmpty {
            let encodedCondition = field("constraints", in: candidate) != nil
                || candidate.contains("?")
            if !encodedCondition {
                return "source conditional predicate could not be bound safely"
            }
        }
        if ir.hasCompletionCondition, ir.completionConcepts.isEmpty,
           field("done", in: candidate) == nil {
            return "source completion target could not be bound safely"
        }
        if ir.requiresOrdering,
           ir.orderingEdges.isEmpty,
           ir.orderedCommands.isEmpty,
           ir.completionConcepts.isEmpty {
            let ordered = [field("flow", in: candidate), field("goal", in: candidate), field("run", in: candidate), field("t", in: candidate)]
                .compactMap { $0 }
                .contains { $0.contains(">") }
            if !ordered {
                return "source ordering edge could not be bound safely"
            }
        }
        if let reason = closedFieldRejection(ir: ir, candidate: candidate) {
            return reason
        }
        let candidateModalities = candidatePredicateBindings(in: candidate).filter {
            !($0.modality == .mustNot && $0.predicate == "fileedit" && ir.prohibitsFileEdits)
        }
        for binding in ir.predicateBindings {
            let modalities = Set(candidateModalities
                .filter { $0.predicate == binding.predicate }
                .map(\.modality))
            guard modalities == [binding.modality] else {
                return "predicate modality changed: \(binding.predicate) must remain \(binding.modality.rawValue)"
            }
        }
        if !ir.predicateBindings.isEmpty, candidateModalities != ir.predicateBindings {
            return "predicate modality binding set changed"
        }
        let candidateConditions = candidateConditionBindings(in: candidate)
        if !ir.conditionBindings.isEmpty, candidateConditions != ir.conditionBindings {
            return "conditional predicate binding changed"
        }
        if ir.conditionBindings.isEmpty, !candidateConditions.isEmpty {
            return "candidate invents a conditional predicate binding"
        }
        let candidateEdges = candidateOrderingEdges(in: candidate)
        if !ir.orderingEdges.isEmpty, candidateEdges != ir.orderingEdges {
            return "predicate ordering edge set changed"
        }
        let candidateGroups = candidateLogicalGroups(in: candidate)
        if !ir.logicalGroups.isEmpty, !candidateGroups.isEmpty {
            let sourceAny = ir.logicalGroups.contains { $0.relation == .any }
            let candidateAny = candidateGroups.contains { $0.relation == .any }
            if sourceAny != candidateAny {
                return "logical field grouping changed"
            }
        }
        if !ir.completionConcepts.isEmpty {
            let completion = candidateCompletionConcepts(in: candidate)
            let usesWholeFlowAsCompletion = field("done", in: candidate)?.lowercased() == "flow"
            if usesWholeFlowAsCompletion
                ? !ir.completionConcepts.isSubset(of: completion)
                : completion != ir.completionConcepts {
                return "completion target changed"
            }
        }
        let compilerLexicon: Set<String> = [
            "implement", "verify", "merge", "test", "deploy", "comment",
            "skill", "postdeploy", "computeruse", "chrome", "browser",
            "auth", "goal", "flow", "done", "must", "use", "pr", "url",
            "all", "main", "card", "first"
        ]
        func compactConcept(_ value: String) -> String {
            value.filter { $0.isLetter || $0.isNumber }
        }
        let sourceConcepts = Set(SR2SemanticIR.semanticConcepts(in: ir.source).map(compactConcept))
        let lexicon = Set(compilerLexicon.map(compactConcept))
        func isCovered(_ concept: String) -> Bool {
            let compact = compactConcept(concept)
            if sourceConcepts.contains(compact) || lexicon.contains(compact) { return true }
            let parts = concept.split { $0 == "-" || $0 == "_" || $0 == "/" || $0 == "." }
                .map { compactConcept(String($0)) }
                .filter { !$0.isEmpty }
            return !parts.isEmpty && parts.allSatisfy { part in
                sourceConcepts.contains(part)
                    || lexicon.contains(part)
                    || sourceConcepts.contains(where: { part.hasPrefix($0) || $0.hasPrefix(part) })
                    || lexicon.contains(where: { part.hasPrefix($0) || $0.hasPrefix(part) })
            }
        }
        if let concept = candidateRequiredConcepts(in: candidate).sorted().first(where: { !isCovered($0) }) {
            return "candidate-introduced action concept: \(concept)"
        }
        let candidateRun = field("run", in: candidate) ?? ""
        guard let candidateGroups = parseCommandGroups(candidateRun) else {
            return "command tool-call grouping is malformed"
        }
        let candidateCommands = candidateGroups.flatMap { group in
            group.split(separator: ";", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if !ir.orderedCommands.isEmpty, candidateCommands != ir.orderedCommands {
            return "exact command sequence or ordering changed"
        }
        if ir.orderedCommandGroups.count > 1,
           candidateGroups != ir.orderedCommandGroups {
            return "command tool-call grouping changed"
        }
        if let lineCount = ir.exactOutputLineCount,
           ir.exactOutputLineCounts.isEmpty,
           field("out", in: candidate)?.lowercased() != "=\(lineCount)lines" {
            return "exact output cardinality changed"
        }
        if !ir.exactOutputLineCounts.isEmpty {
            guard let candidateCounts = parseExactOutputLineCounts(field("out", in: candidate) ?? ""),
                  candidateCounts == ir.exactOutputLineCounts else {
                return "per-command exact output cardinality changed"
            }
        }
        if ir.prohibitsFileEdits,
           field("not", in: candidate)?.lowercased() != "file-edit",
           !candidate.split(whereSeparator: \.isNewline).contains(where: {
               $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "!file-edit"
           }) {
            return "file-edit prohibition missing"
        }
        let compactCandidate = compactSemanticKey(candidate)
        for anchor in ir.anchors where !candidate.localizedCaseInsensitiveContains(anchor)
            && !compactCandidate.contains(compactSemanticKey(anchor)) {
            return "semantic anchor missing: \(anchor)"
        }
        let exactRunPreservesOrder = !ir.orderedCommands.isEmpty
            && candidateCommands == ir.orderedCommands
            && (ir.orderedCommandGroups.count <= 1 || candidateGroups == ir.orderedCommandGroups)
        if ir.requiresOrdering,
           !exactRunPreservesOrder,
           !(lower.contains("flow:") && candidate.contains(">")),
           !(lower.contains("goal:") && candidate.contains(">")),
           !(lower.contains("t:") && candidate.contains(">")) {
            return "ordering dependency missing"
        }
        if ir.hasCompletionCondition, !lower.contains("done:") {
            return "completion condition missing"
        }
        if ir.hasProhibition, !lower.contains("not:"), !candidate.contains("!") {
            return "prohibition missing"
        }
        if ir.hasMandatoryConstraint,
           !lower.contains("must:"),
           !lower.contains("flow:"),
           !lower.contains("goal:") {
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
        // Instruction compilation is not a bag-of-words rewrite. Named anchors
        // and pinned literals already guard identity; requiring every source
        // content word would reject any compact LLM SR2 of a natural prompt.
        return nil
    }

    private static func closedFieldRejection(ir: SR2SemanticIR, candidate: String) -> String? {
        let fields = candidateV1Fields(in: candidate)
        let keys = Set(fields.map(\.key))
        if let unknown = keys.subtracting(recognizedV1FieldKeys).sorted().first {
            return "unrecognized v1 field: \(unknown)"
        }
        if fields.count != keys.count {
            return "duplicate v1 field is not semantically bound"
        }
        for entry in fields {
            let valueConcepts = SR2SemanticIR.semanticConcepts(in: entry.value)
            switch entry.key {
            case "run":
                if ir.orderedCommands.isEmpty { return "unrepresented v1 field: run" }
            case "out":
                if ir.exactOutputLineCount == nil && ir.exactOutputLineCounts.isEmpty {
                    return "unrepresented v1 field: out"
                }
            case "flow", "goal":
                if !ir.requiresOrdering { return "unrepresented v1 field: \(entry.key)" }
            case "done":
                if !ir.hasCompletionCondition { return "unrepresented v1 field: done" }
            case "tools":
                let anchorConcepts = SR2SemanticIR.semanticConcepts(
                    in: ir.anchors.sorted().joined(separator: " ")
                )
                if valueConcepts.isEmpty || !valueConcepts.isSubset(of: anchorConcepts) {
                    return "unrepresented v1 field: tools"
                }
            case "use", "browser", "pr":
                if valueConcepts.isEmpty { return "unrepresented v1 field: \(entry.key)" }
            case "must", "should", "may", "not":
                if entry.key == "not", valueConcepts == ["fileedit"], ir.prohibitsFileEdits {
                    continue
                }
                let modality: SR2Modality = switch entry.key {
                case "must": .must
                case "should": .should
                case "may": .may
                default: .mustNot
                }
                let flagged = switch modality {
                case .must: ir.hasMandatoryConstraint
                case .mustNot: ir.hasProhibition
                case .should, .may: false
                }
                if !flagged, !ir.predicateBindings.contains(where: { $0.modality == modality }) {
                    return "unrepresented v1 field: \(entry.key)"
                }
            case "constraints":
                if ir.conditionBindings.isEmpty || candidateConditionBindings(in: candidate).isEmpty {
                    return "unrepresented v1 field: constraints"
                }
            case "auth", "comment", "trello-comment":
                if valueConcepts.isEmpty { return "unrepresented v1 field: \(entry.key)" }
            case "g", "d", "p", "o", "e", "h", "t", "u", "outputs":
                // These runtime/summary fields do not yet have a source IR
                // binding. Fail closed instead of treating their text as coverage.
                return "unrepresented v1 field: \(entry.key)"
            default:
                return "unrecognized v1 field: \(entry.key)"
            }
        }
        return nil
    }

    private static func candidateV1Fields(in candidate: String) -> [(key: String, value: String)] {
        guard hasSupportedOptimizerBanner(candidate) else { return [] }
        var result: [(String, String)] = []
        for rawLine in candidate.split(whereSeparator: \.isNewline).dropFirst() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("!") {
                result.append(("not", String(line.dropFirst())))
                continue
            }
            guard let delimiter = line.firstIndex(where: { $0 == ":" || $0 == "=" }) else {
                result.append(("<invalid>", line))
                continue
            }
            result.append((
                String(line[..<delimiter]).lowercased(),
                String(line[line.index(after: delimiter)...])
            ))
        }
        return result
    }

    private static func hasSupportedOptimizerBanner(_ candidate: String) -> Bool {
        guard let firstLine = candidate.split(whereSeparator: \.isNewline).first else {
            return false
        }
        return firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            == SR2WirePolicy.optimizerMarkerLine
    }

    private static func deterministicCandidate(for source: String) -> String? {
        let ir = SR2SemanticIR.parse(source)
        guard !ir.orderedCommands.isEmpty,
              ir.exactOutputLineCount != nil || !ir.exactOutputLineCounts.isEmpty,
              ir.prohibitsFileEdits,
              ir.orderedCommands.allSatisfy(isBoundedCommand),
              !containsCredentialMaterial(source),
              matchesBoundedCommandContract(source) else {
            return nil
        }
        var candidate = """
        @sr2 v1
        run:\(canonicalRun(ir: ir))
        !file-edit
        """
        if !ir.exactOutputLineCounts.isEmpty {
            let counts = ir.exactOutputLineCounts.keys.sorted().map {
                "\($0)=\(ir.exactOutputLineCounts[$0]!)line\(ir.exactOutputLineCounts[$0]! == 1 ? "" : "s")"
            }.joined(separator: ",")
            candidate = candidate.replacingOccurrences(of: "!file-edit", with: "out:\(counts)\n!file-edit")
        } else if let lineCount = ir.exactOutputLineCount {
            candidate = candidate.replacingOccurrences(of: "!file-edit", with: "out:=\(lineCount)lines\n!file-edit")
        }
        if ir.hasCompletionCondition {
            let completion = ir.completionConcepts.contains("summary") ? "run+summary" : "run"
            candidate += "\ndone:\(completion)"
        }
        return candidate
    }

    private static func candidatePredicateBindings(in candidate: String) -> Set<SR2PredicateBinding> {
        let mappings: [(String, SR2Modality)] = [
            ("must", .must), ("not", .mustNot), ("should", .should), ("may", .may)
        ]
        var result = Set<SR2PredicateBinding>()
        for (fieldName, modality) in mappings {
            guard let value = field(fieldName, in: candidate) else { continue }
            for rawPredicate in value.split(separator: "+") {
                let predicate = SR2SemanticIR.predicateKey(String(rawPredicate))
                if !predicate.isEmpty {
                    result.insert(.init(predicate: predicate, modality: modality))
                }
            }
        }
        for rawLine in candidate.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("!") else { continue }
            let predicate = SR2SemanticIR.predicateKey(String(line.dropFirst()))
            if !predicate.isEmpty {
                result.insert(.init(predicate: predicate, modality: .mustNot))
            }
        }
        return result
    }

    private static func candidateConditionBindings(in candidate: String) -> Set<SR2ConditionBinding> {
        guard let constraints = field("constraints", in: candidate) else { return [] }
        var result = Set<SR2ConditionBinding>()
        for rawBinding in constraints.split(separator: ";") {
            let binding = String(rawBinding)
            guard let arrow = binding.range(of: "=>") else { continue }
            var condition = String(binding[..<arrow.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let predicate = SR2SemanticIR.predicateKey(String(binding[arrow.upperBound...]))
            let lower = condition.lowercased()
            let kind: String
            if lower.hasPrefix("unless:") {
                kind = "unless"
                condition = String(condition.dropFirst("unless:".count))
            } else if lower.hasPrefix("if:") {
                kind = "if"
                condition = String(condition.dropFirst("if:".count))
            } else {
                kind = "if"
            }
            let conditionKey = SR2SemanticIR.predicateKey(condition)
            if !conditionKey.isEmpty, !predicate.isEmpty {
                result.insert(.init(predicate: predicate, condition: conditionKey, kind: kind))
            }
        }
        return result
    }

    private static func candidateOrderingEdges(in candidate: String) -> Set<SR2OrderingEdge> {
        guard let flow = field("flow", in: candidate) ?? field("goal", in: candidate) else { return [] }
        let predicates = flow.split(separator: ">")
            .map { SR2SemanticIR.predicateKey(String($0)) }
            .filter { !$0.isEmpty }
        guard predicates.count > 1 else { return [] }
        var result = Set<SR2OrderingEdge>()
        for index in 1..<predicates.count {
            result.insert(.init(
                predecessor: predicates[index - 1],
                successor: predicates[index]
            ))
        }
        return result
    }

    private static func candidateRequiredConcepts(in candidate: String) -> Set<String> {
        let structuralFields = [
            "flow", "goal", "tools", "use", "browser", "pr",
            "must", "not", "should", "may", "outputs", "auth",
            "comment", "trello-comment"
        ]
        var concepts = Set<String>()
        for key in structuralFields {
            if let value = field(key, in: candidate) {
                concepts.formUnion(SR2SemanticIR.semanticConcepts(in: value))
            }
        }
        if let done = field("done", in: candidate), done.lowercased() != "flow" {
            concepts.formUnion(SR2SemanticIR.semanticConcepts(in: done))
        }
        return concepts
    }

    private static func candidateLogicalGroups(in candidate: String) -> Set<SR2LogicalGroup> {
        var result = Set<SR2LogicalGroup>()
        for key in ["tools", "use", "browser"] {
            guard let value = field(key, in: candidate) else { continue }
            let relation: SR2LogicalRelation?
            let parts: [Substring]
            if value.contains("|") {
                relation = .any
                parts = value.split(separator: "|")
            } else if value.contains("+") {
                relation = .all
                parts = value.split(separator: "+")
            } else {
                relation = nil
                parts = []
            }
            guard let relation else { continue }
            let concepts = parts.reduce(into: Set<String>()) { partial, part in
                partial.formUnion(SR2SemanticIR.semanticConcepts(in: String(part)))
            }
            if concepts.count >= 2 {
                result.insert(.init(field: key, concepts: concepts, relation: relation))
            }
        }
        return result
    }

    private static func candidateCompletionConcepts(in candidate: String) -> Set<String> {
        guard let done = field("done", in: candidate) else { return [] }
        if done.lowercased() == "flow", let flow = field("flow", in: candidate) {
            return SR2SemanticIR.semanticConcepts(in: flow)
        }
        if done.lowercased() == "run", let run = field("run", in: candidate) {
            _ = run
            return ["run"]
        }
        return SR2SemanticIR.semanticConcepts(in: done)
    }

    private static func matchesBoundedCommandContract(_ source: String) -> Bool {
        let ir = SR2SemanticIR.parse(source)
        guard !ir.orderedCommands.isEmpty,
              ir.exactOutputLineCount != nil || !ir.exactOutputLineCounts.isEmpty,
              ir.prohibitsFileEdits,
              ["execute", "run", "command", "comando"].contains(where: ir.source.lowercased().contains),
              ["exactly", "exatamente"].contains(where: ir.source.lowercased().contains)
        else { return false }
        if !ir.exactOutputLineCounts.isEmpty {
            guard !ir.orderedCommandGroups.isEmpty,
                  ir.exactOutputLineCounts.keys.allSatisfy({ $0 <= ir.orderedCommandGroups.count }),
                  ir.exactOutputLineCounts.values.allSatisfy({ $0 > 0 }) else { return false }
        } else if ir.exactOutputLineCount != ir.orderedCommands.count {
            return false
        }
        return true
    }

    private static func parseExactOutputLineCounts(_ value: String) -> [Int: Int]? {
        var result: [Int: Int] = [:]
        for rawEntry in value.split(separator: ",", omittingEmptySubsequences: false) {
            let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equals = entry.firstIndex(of: "=") else { return nil }
            guard let index = Int(entry[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)),
                  index > 0 else { return nil }
            let countText = entry[entry.index(after: equals)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let digits = countText
                .dropLast(countText.hasSuffix("lines") ? 5 : (countText.hasSuffix("line") ? 4 : 0))
            guard let count = Int(digits), count > 0,
                  countText.hasSuffix("line") || countText.hasSuffix("lines"),
                  result[index] == nil else { return nil }
            result[index] = count
        }
        return result.isEmpty ? nil : result
    }

    private static func canonicalRun(ir: SR2SemanticIR) -> String {
        guard ir.orderedCommandGroups.count > 1 else {
            return ir.orderedCommands.joined(separator: ";")
        }
        return ir.orderedCommandGroups.map { "[\($0)]" }.joined(separator: ">")
    }

    /// `run:[a;b]>[c]` preserves the source's backtick-delimited shell tool-call
    /// groups. Brackets are structural only; the commands inside remain exact.
    /// Any mixed/partial bracket form fails closed instead of silently flattening.
    private static func parseCommandGroups(_ value: String) -> [String]? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.first == "[" else {
            return trimmed.contains("[") || trimmed.contains("]") || trimmed.contains(">")
                ? nil
                : [trimmed]
        }

        var groups: [String] = []
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            guard trimmed[index] == "[",
                  let close = trimmed[index...].firstIndex(of: "]") else { return nil }
            let group = trimmed[trimmed.index(after: index)..<close]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !group.isEmpty,
                  !group.contains("[") else { return nil }
            groups.append(group)
            index = trimmed.index(after: close)
            guard index < trimmed.endIndex else { break }
            guard trimmed[index] == ">" else { return nil }
            index = trimmed.index(after: index)
            guard index < trimmed.endIndex else { return nil }
        }
        return groups.isEmpty ? nil : groups
    }

    private static func containsCredentialMaterial(_ source: String) -> Bool {
        let lower = source.lowercased()
        return ["credential", "credencial", "password", "senha", "token", "secret", "api_key", "apikey"]
            .contains(where: lower.contains)
    }

    private static func isBoundedCommand(_ command: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: #"^[A-Za-z0-9_./~-]+(?:\s+[A-Za-z0-9_./~+-]+)*$"#
        ) else { return false }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        return regex.firstMatch(in: command, range: range)?.range == range
    }

    private static func field(_ key: String, in candidate: String) -> String? {
        let prefix = key.lowercased() + ":"
        for rawLine in candidate.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.lowercased().hasPrefix(prefix) else { continue }
            return String(line.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func firstMissingLiteral(ir: SR2SemanticIR, candidate: String) -> String? {
        let command = ir.orderedCommands.joined(separator: "; ")
        for literal in LiteralPreservation.pinnedLiterals(in: ir.source) {
            if candidate.contains(literal) { continue }
            let literalBody = literal.hasPrefix("`") && literal.hasSuffix("`")
                ? String(literal.dropFirst().dropLast())
                : literal
            let compactLiteral = literalBody.replacingOccurrences(of: "; ", with: ";")
            if candidate.contains(compactLiteral) { continue }
            if literal.hasPrefix("`"), literal.hasSuffix("`"),
               candidate.contains(String(literal.dropFirst().dropLast())) {
                continue
            }
            if literal.hasPrefix("`"), literal.hasSuffix("`"),
               String(literal.dropFirst().dropLast()) == command,
               !ir.orderedCommands.isEmpty {
                continue
            }
            return literal
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
