import Foundation

/// Compact `@sr2 v1` encoder for any natural-language user prompt.
/// Specialized Trello/Linear/command compilers win when they match; this
/// lane covers everything else so the provider never pays the full essay.
enum SR2OpenPromptCompiler {
    static func candidate(for source: String) -> String? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !SR2WirePolicy.hasSR2Banner(text) else { return nil }

        let ir = SR2SemanticIR.parse(text)
        let urls = unique(extractURLs(in: text))
        let skills = unique(extractSlashSkills(in: text)).filter { skill in
            skill.hasPrefix("/sam") || !urls.contains(where: { $0.contains(skill) })
        }
        let mentions = unique(extractAtMentions(in: text))
        let commands = unique(extractBacktickCommands(in: text))
        let windows = unique(extractTimeWindows(in: text))
        let emails = unique(captures(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, in: text))
        let paths = unique(captures(#"((?:/Users|/home)/[^\s]+)"#, in: text))
        let placeholders = unique(captures(#"(<[A-Za-z][A-Za-z0-9_-]*>)"#, in: text))
        let useAtoms = unique(
            (urls + skills + mentions + windows + emails + paths + placeholders + toolAnchors(in: ir.anchors, source: text))
                .filter(isUsefulUseAtom)
        )
        let goal = goalValue(ir: ir, excluding: Set(useAtoms.map { $0.lowercased() }))

        var fields: [(String, String)] = []
        if !goal.isEmpty { fields.append(("goal", goal)) }
        if !useAtoms.isEmpty { fields.append(("use", useAtoms.sorted().joined(separator: ","))) }
        if !commands.isEmpty {
            fields.append(("run", commands.joined(separator: ">")))
        }
        if ir.hasMandatoryConstraint {
            let must = ir.predicateBindings
                .filter { $0.modality == .must }
                .map(\.predicate)
                .filter { !$0.isEmpty }
                .sorted()
                .joined(separator: ",")
            if !must.isEmpty {
                fields.append(("must", must))
            }
        }
        if ir.hasProhibition || ir.prohibitsFileEdits || text.lowercased().contains("read only")
            || text.lowercased().contains("read-only") {
            let notValue: String
            if ir.prohibitsFileEdits {
                notValue = "file-edit"
            } else if text.lowercased().contains("read only") || text.lowercased().contains("read-only") {
                notValue = "modify"
            } else {
                let bound = ir.predicateBindings
                    .filter { $0.modality == .mustNot }
                    .map(\.predicate)
                    .filter { !$0.isEmpty }
                    .sorted()
                    .joined(separator: ",")
                notValue = bound.isEmpty ? "modify" : bound
            }
            fields.append(("not", notValue))
        }
        if ir.hasCompletionCondition {
            let done = ir.completionConcepts.isEmpty
                ? "goal"
                : ir.completionConcepts.sorted().joined(separator: "+")
            fields.append(("done", done))
        }
        if fields.isEmpty { return nil }

        var candidate = encode(fields)
        let missing = missingIdentity(in: text, candidate: candidate)
        if !missing.isEmpty {
            if let index = fields.firstIndex(where: { $0.0 == "use" }) {
                fields[index].1 += "," + missing.joined(separator: ",")
            } else {
                fields.append(("use", missing.joined(separator: ",")))
            }
            candidate = encode(fields)
        }
        return candidate
    }

    private static func encode(_ fields: [(String, String)]) -> String {
        ([SR2WirePolicy.optimizerMarkerLine] + fields.map { "\($0.0):\($0.1)" })
            .joined(separator: "\n")
    }

    private static let extraStops: Set<String> = [
        "eu", "voce", "você", "quero", "usando", "me", "my", "you", "your", "we",
        "our", "here", "this", "that", "with", "from", "have", "has", "been",
        "true", "any", "anything", "me", "if", "then", "only",
    ]

    private static let toolTokens: Set<String> = [
        "react", "vite", "typescript", "javascript", "html", "css", "chrome",
        "github", "gitlab", "trello", "playwright", "gh", "glab", "codex",
        "claude", "grok",
    ]

    private static func goalValue(ir: SR2SemanticIR, excluding: Set<String>) -> String {
        let concepts = SR2SemanticIR.semanticConcepts(in: ir.source)
            .filter { concept in
                let lower = concept.lowercased()
                return !excluding.contains(lower)
                    && !extraStops.contains(lower)
                    && !toolTokens.contains(lower)
                    && !lower.hasPrefix("http")
                    && !lower.hasPrefix("--")
                    && !lower.contains("github")
            }
            .sorted()
        guard !concepts.isEmpty else { return "" }
        let joiner = ir.requiresOrdering ? ">" : "+"
        let limited = Array(concepts.prefix(12))
        return limited.joined(separator: joiner)
    }

    private static func toolAnchors(in anchors: Set<String>, source: String) -> [String] {
        let fromAnchors = anchors.filter { anchor in
            if anchor.contains("://") || anchor.hasPrefix("/") { return true }
            let lower = anchor.lowercased()
            return toolTokens.contains(where: { lower.contains($0) })
        }
        let fromWords = SR2SemanticIR.semanticConcepts(in: source)
            .filter { toolTokens.contains($0.lowercased()) }
        return Array(fromAnchors) + Array(fromWords)
    }

    private static func extractURLs(in text: String) -> [String] {
        let markdown = captures(#"\[[^\]]+\]\((https?://[^)\s]+)\)"#, in: text)
        let bare = captures(#"https?://[^\s)>\]]+"#, in: text)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,);")) }
        return markdown + bare
    }

    private static func extractSlashSkills(in text: String) -> [String] {
        captures(#"(/[A-Za-z][A-Za-z0-9_-]*)"#, in: text)
    }

    private static func extractAtMentions(in text: String) -> [String] {
        var result: [String] = []
        var search = text.startIndex
        while let at = text[search...].firstIndex(of: "@") {
            let after = text.index(after: at)
            guard after < text.endIndex, text[after].isLetter else {
                search = after
                continue
            }
            var end = after
            while end < text.endIndex {
                let rest = text[end...]
                let folded = rest.lowercased()
                if text[end] == "@" || text[end] == "\n" || text[end] == "," { break }
                if folded.hasPrefix(" para ") || folded.hasPrefix(" to ") { break }
                end = text.index(after: end)
            }
            let mention = text[after..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !mention.isEmpty { result.append(mention) }
            search = end
        }
        return result
    }

    private static func extractTimeWindows(in text: String) -> [String] {
        captures(#"\b(\d+\s*(?:dias?|days?))\b"#, in: text)
    }

    private static func extractBacktickCommands(in text: String) -> [String] {
        captures(#"`([^`\n]{1,200})`"#, in: text)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            let index = match.numberOfRanges > 1 ? 1 : 0
            guard let matched = Range(match.range(at: index), in: text) else { return nil }
            return String(text[matched])
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let key = value.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(value)
        }
        return result
    }

    private static func missingIdentity(in source: String, candidate: String) -> [String] {
        var missing: [String] = []
        for literal in LiteralPreservation.pinnedLiterals(in: source) {
            let body = normalizePin(literal)
            if candidate.contains(literal) || candidate.contains(body) { continue }
            if body.hasPrefix("-") || body.hasPrefix("`") { continue }
            missing.append(body)
        }
        for anchor in SR2SemanticIR.parse(source).anchors {
            if candidate.localizedCaseInsensitiveContains(anchor) { continue }
            if anchor.hasPrefix("-") { continue }
            missing.append(anchor)
        }
        let users = captures(#"(?i)\buser:\s*([A-Za-z0-9_-]+)"#, in: source)
        for user in users where !candidate.localizedCaseInsensitiveContains(user) {
            missing.append(user)
        }
        return unique(missing.filter(isUsefulUseAtom))
    }

    private static func isUsefulUseAtom(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("-") || trimmed.hasPrefix("+") || trimmed.hasPrefix("`") {
            return false
        }
        if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") { return true }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return true }
        if trimmed.hasPrefix("/sam") { return true }
        if trimmed.hasPrefix("/Users") || trimmed.hasPrefix("/home") { return true }
        if trimmed.contains("@") { return true }
        if toolTokens.contains(trimmed.lowercased()) { return true }
        if trimmed.contains(" ") { return true }
        if trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
            return trimmed.count >= 3
        }
        return false
    }

    static func normalizePin(_ literal: String) -> String {
        var body = literal.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("-") || body.hasPrefix("+") {
            let rest = body.dropFirst().trimmingCharacters(in: .whitespaces)
            if let first = rest.first, first.isLetter || first == "`" || first == "/" || first == "<"
                || rest.hasPrefix("http") {
                body = rest
            }
        }
        if body.hasPrefix("`") && body.hasSuffix("`") && body.count >= 2 {
            body = String(body.dropFirst().dropLast())
        }
        return body
    }
}
