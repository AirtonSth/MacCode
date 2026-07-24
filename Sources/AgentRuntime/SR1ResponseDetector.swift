import Foundation
import CoreModel

public struct SR1ClassifierDecision: Equatable, Sendable {
    public let isSR1: Bool
    public let confidence: Double

    public init(isSR1: Bool, confidence: Double) {
        self.isSR1 = isSR1
        self.confidence = confidence
    }

    fileprivate func isConfident(minimumConfidence: Double) -> Bool {
        confidence.isFinite && confidence >= minimumConfidence
    }
}

public typealias SR1ResponseClassifier = @Sendable (String) -> SR1ClassifierDecision?

public enum SR1ResponseDetector {
    // Single source of truth: see CoreModel.DistillSemanticPrefixes for why this
    // must not be re-typed per module.
    private static let semanticPrefixes = DistillSemanticPrefixes.set
    private static let variableKeyPattern = #"#[A-Za-z][0-9]+"#
    public static let classifierConfidenceThreshold = 0.82

    /// Longest bare `O:` line still treated as an R0 chat reply rather than a
    /// compressed dialect payload. See `isBareShortOutcomeLine`.
    static let bareOutcomeExemptionMaxLength = 120

    public static func parseSemanticLine(_ line: String) -> (prefix: Character, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first?.uppercased().first,
              semanticPrefixes.contains(first) else {
            return nil
        }

        let rest = trimmed.dropFirst()
        guard let delimiter = rest.first else { return nil }

        let content: String
        if delimiter == ":" || delimiter == "=" {
            content = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        } else if delimiter == " " || delimiter == "\t" {
            content = rest.trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }

        guard !content.isEmpty else { return nil }
        return (first, content)
    }

    public static func parseSemanticSegments(_ text: String) -> [(prefix: Character, content: String)] {
        text
            .split(whereSeparator: \.isNewline)
            .flatMap { parseSemanticSegmentsInLine(String($0)) }
    }

    public static func extractVariableAliases(_ text: String) -> [String: String] {
        var aliases: [String: String] = [:]
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        for line in lines {
            for (key, value) in keyValueAliases(in: line) {
                aliases[key] = value
            }
            for (key, value) in valueKeyAliases(in: line) {
                aliases[key] = value
            }
        }
        return aliases
    }

    public static func expandVariables(in text: String, from source: String) -> String {
        let aliases = extractVariableAliases(source)
        guard !aliases.isEmpty else { return text }

        var expanded = text
        for (key, value) in aliases.sorted(by: { $0.key.count > $1.key.count }) {
            expanded = replacingWholeVariableKey(key, with: value, in: expanded)
        }
        return expanded
    }

    public static func isSingleSemanticLine(_ text: String, allowSpaceDelimitedOutcome: Bool = false) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline),
              let parsed = parseSemanticLine(trimmed) else {
            return false
        }
        if parsed.prefix != "O" {
            return true
        }
        return allowSpaceDelimitedOutcome || isDelimitedSemanticLine(trimmed)
    }

    public static func isSR1(
        _ text: String,
        classifier: SR1ResponseClassifier? = nil,
        confidenceThreshold: Double = classifierConfidenceThreshold
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else { return false }

        if let decision = classifier?(trimmed),
           decision.isConfident(minimumConfidence: confidenceThreshold) {
            return decision.isSR1
        }

        return heuristicIsSR1(trimmed)
    }

    private static func heuristicIsSR1(_ trimmed: String) -> Bool {
        let lines = trimmed
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return false }

        let lower = trimmed.lowercased()
        let hasExplicitMarker = lower.hasPrefix("sr1") ||
            lower.contains("\nsr1") ||
            lower.hasPrefix("dict:") ||
            lower.contains("\ndict:")
        let inlineSegments = parseSemanticSegments(trimmed)
        if hasExplicitMarker, inlineSegments.count >= 1 {
            return true
        }
        if inlineSegments.count >= 2, startsWithSemanticMarker(trimmed) {
            return true
        }
        // R0 exemption: a lone short `O:` line is the dialect's own chat-reply
        // shape, not a compressed payload. Must come before the single-line and
        // all-lines-semantic branches below, both of which would otherwise
        // classify it as SR1.
        if lines.count == 1, isBareShortOutcomeLine(trimmed) {
            return false
        }
        if lines.count == 1, isSingleSemanticLine(trimmed) {
            return true
        }

        var semanticLineCount = 0
        var delimitedSemanticLineCount = 0
        var dictionaryLineCount = 0
        var semanticPrefixesSeen = Set<Character>()
        for line in lines.prefix(30) {
            if let parsed = parseSemanticLine(line) {
                semanticLineCount += 1
                semanticPrefixesSeen.insert(parsed.prefix)
                if isDelimitedSemanticLine(line) {
                    delimitedSemanticLineCount += 1
                }
            }
            if isDictionaryLine(line) {
                dictionaryLineCount += 1
            }
        }

        if semanticLineCount == lines.count,
           delimitedSemanticLineCount > 0 || lines.count > 1 {
            return true
        }
        if hasExplicitMarker, dictionaryLineCount >= 1 { return true }
        if hasExplicitMarker, semanticLineCount >= 1 { return true }
        if dictionaryLineCount >= 2, semanticLineCount >= 1 { return true }
        return semanticLineCount >= 3 &&
            (delimitedSemanticLineCount > 0 || semanticPrefixesSeen.count >= 2)
    }

    /// A lone, short, colon-delimited `O:` line is the dialect's own R0 chat reply
    /// (the spec's own example is `O: bem, obrigado — pronto pro próximo`), not a
    /// compressed dialect payload.
    ///
    /// WHY this exemption exists: classifying that shape as SR1 costs a full extra
    /// local-model humanization round trip plus a permanent "translated from
    /// compressed output" badge on the cheapest replies in the product — the exact
    /// replies Token Saver is supposed to make cheapest — and it trains the user to
    /// ignore the badge that exists to flag genuine leaks.
    ///
    /// Deliberately narrow so a real payload is never exempted: one semantic
    /// segment only (so `O: x. P: y.` stays SR1), prefix must be `O` (an
    /// outcome-only line carries no ops fields needing expansion), colon or equals
    /// delimited (a space-delimited lone outcome already returns false today),
    /// bounded length, and no `#`-variable alias, which would still need `Dict:`
    /// expansion to be readable by a human.
    static func isBareShortOutcomeLine(_ trimmed: String) -> Bool {
        guard !trimmed.contains(where: \.isNewline),
              trimmed.count <= bareOutcomeExemptionMaxLength,
              isDelimitedSemanticLine(trimmed),
              let parsed = parseSemanticLine(trimmed),
              parsed.prefix == "O",
              parseSemanticSegmentsInLine(trimmed).count <= 1,
              trimmed.range(of: variableKeyPattern, options: .regularExpression) == nil else {
            return false
        }
        return true
    }

    private static func parseSemanticSegmentsInLine(_ rawLine: String) -> [(prefix: Character, content: String)] {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return [] }
        let markerRanges = semanticMarkerRanges(in: line)
        guard markerRanges.count >= 2 else {
            return parseSemanticLine(line).map { [$0] } ?? []
        }

        var segments: [(prefix: Character, content: String)] = []
        for index in markerRanges.indices {
            let marker = markerRanges[index]
            let contentStart = line.index(after: marker.range.lowerBound)
            let delimiter = line[contentStart]
            let segmentStart = (delimiter == ":" || delimiter == "=")
                ? line.index(after: contentStart)
                : contentStart
            let segmentEnd = index + 1 < markerRanges.count
                ? markerRanges[index + 1].range.lowerBound
                : line.endIndex
            let content = line[segmentStart..<segmentEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !content.isEmpty {
                segments.append((marker.prefix, content))
            }
        }
        return segments
    }

    private static func semanticMarkerRanges(in line: String) -> [(prefix: Character, range: Range<String.Index>)] {
        var result: [(Character, Range<String.Index>)] = []
        var index = line.startIndex
        while index < line.endIndex {
            let next = line.index(after: index)
            defer { index = next }
            let prefix = line[index].uppercased().first ?? "\0"
            guard semanticPrefixes.contains(prefix),
                  next < line.endIndex,
                  isSemanticDelimiter(line[next]),
                  isSemanticBoundary(before: index, in: line) else {
                continue
            }
            result.append((prefix, index..<next))
        }
        return result
    }

    private static func isSemanticDelimiter(_ character: Character) -> Bool {
        character == ":" || character == "=" || character == " " || character == "\t"
    }

    private static func isSemanticBoundary(before index: String.Index, in line: String) -> Bool {
        if index == line.startIndex { return true }
        var cursor = line.index(before: index)
        while cursor > line.startIndex, line[cursor].isWhitespace {
            cursor = line.index(before: cursor)
        }
        let previous = line[cursor]
        return previous == "." || previous == ";" || previous == "!" || previous == "?"
    }

    private static func startsWithSemanticMarker(_ text: String) -> Bool {
        guard let line = text
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else {
            return false
        }
        return semanticMarkerRanges(in: line).first?.range.lowerBound == line.startIndex
    }

    private static func isDelimitedSemanticLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first?.uppercased().first,
              semanticPrefixes.contains(first) else {
            return false
        }
        let rest = trimmed.dropFirst()
        guard let delimiter = rest.first else { return false }
        return delimiter == ":" || delimiter == "="
    }

    private static func isDictionaryLine(_ line: String) -> Bool {
        let lower = line.trimmingCharacters(in: .whitespaces).lowercased()
        guard lower.count >= 3 else { return false }
        return lower == "dict:" ||
            lower.hasPrefix("dict:") ||
            lower == "dict" ||
            lower.hasPrefix("s=state") ||
            lower.hasPrefix("c=context") ||
            lower.hasPrefix("d=action") ||
            lower.hasPrefix("r=risk") ||
            lower.hasPrefix("o=outcome") ||
            lower.hasPrefix("n=no-go") ||
            lower.hasPrefix("p=proof")
    }

    private static func keyValueAliases(in line: String) -> [(String, String)] {
        let pattern = #"(#[A-Za-z][0-9]+)\s*=\s*([^;\n]+?)(?=(?:\s+#[A-Za-z][0-9]+\s*=)|$)"#
        return regexMatches(pattern: pattern, in: line).compactMap { result in
            guard result.numberOfRanges >= 3,
                  let keyRange = Range(result.range(at: 1), in: line),
                  let valueRange = Range(result.range(at: 2), in: line),
                  let value = cleanedVariableValue(String(line[valueRange])) else {
                return nil
            }
            return (String(line[keyRange]), value)
        }
    }

    private static func valueKeyAliases(in line: String) -> [(String, String)] {
        let pattern = #"(^|[.;]\s+)([^#=;\n]{2,100}?)\s*=\s*(#[A-Za-z][0-9]+)(?=\s|[.;,]|$)"#
        return regexMatches(pattern: pattern, in: line).compactMap { result in
            guard result.numberOfRanges >= 4,
                  let valueRange = Range(result.range(at: 2), in: line),
                  let keyRange = Range(result.range(at: 3), in: line),
                  let value = cleanedVariableValue(String(line[valueRange])) else {
                return nil
            }
            return (String(line[keyRange]), value)
        }
    }

    private static func cleanedVariableValue(_ raw: String) -> String? {
        var value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.localizedCaseInsensitiveContains("dict:") ||
            value.range(of: DistillSemanticPrefixes.aliasDeclarationPattern, options: .regularExpression) != nil {
            return nil
        }
        let segments = parseSemanticSegments(value)
        if segments.count == 1 {
            value = segments[0].content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
        }
        guard !value.isEmpty,
              value.range(of: variableKeyPattern, options: .regularExpression) == nil else {
            return nil
        }
        return value
    }

    private static func replacingWholeVariableKey(_ key: String, with value: String, in text: String) -> String {
        let pattern = #"(?<![A-Za-z0-9_])"# + NSRegularExpression.escapedPattern(for: key) + #"(?![A-Za-z0-9_])"#
        var output = text
        for result in regexMatches(pattern: pattern, in: output).reversed() {
            guard let range = Range(result.range, in: output) else { continue }
            output.replaceSubrange(range, with: value)
        }
        return output
    }

    private static func regexMatches(pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
    }
}
