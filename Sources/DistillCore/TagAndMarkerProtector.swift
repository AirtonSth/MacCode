import Foundation

public struct ProtectedTagPayload: Sendable, Equatable {
    public let text: String
    public let replacements: [String: String]

    public var isEmpty: Bool { replacements.isEmpty }

    public func restore(in output: String) -> String {
        var restored = output
        for (placeholder, literal) in replacements {
            restored = restored.replacingOccurrences(of: placeholder, with: literal)
        }
        return restored
    }
}

public enum TagAndMarkerProtector {
    private static let patterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"\[\[rc:[0-9a-fA-F]+\]\]"#),
        try! NSRegularExpression(pattern: #"</?[A-Za-z][A-Za-z0-9:_-]*(?:\s+[^<>]*?)?>"#)
    ]

    public static func protect(_ text: String) -> ProtectedTagPayload {
        var matches: [(range: Range<String.Index>, literal: String)] = []
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for regex in patterns {
            for match in regex.matches(in: text, range: nsRange) {
                guard let range = Range(match.range, in: text) else { continue }
                if matches.contains(where: { overlaps($0.range, range) }) { continue }
                matches.append((range, String(text[range])))
            }
        }

        let ordered = matches.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var replacements: [String: String] = [:]
        var protected = text
        for (index, match) in ordered.enumerated().reversed() {
            let placeholder = "__RC_PROTECTED_\(index)__"
            replacements[placeholder] = match.literal
            protected.replaceSubrange(match.range, with: placeholder)
        }
        return ProtectedTagPayload(text: protected, replacements: replacements)
    }

    private static func overlaps(_ lhs: Range<String.Index>, _ rhs: Range<String.Index>) -> Bool {
        lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound
    }
}
