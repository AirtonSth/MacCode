import Foundation

public enum FaithfulnessGate {
    public struct Result: Equatable, Sendable {
        public let accepted: Bool
        public let reason: String?

        public static let accepted = Result(accepted: true, reason: nil)
        public static func rejected(_ reason: String) -> Result {
            Result(accepted: false, reason: reason)
        }
    }

    private static let salientWords: Set<String> = [
        "error", "fatal", "warn", "warning", "fail", "failed", "panic",
        "exception", "traceback", "must", "never", "only", "not"
    ]

    public static func validate(original: String, compressed: String) -> Result {
        if compressed == original { return .accepted }

        for literal in LiteralPreservation.pinnedLiterals(in: compressed)
            where !original.contains(literal) {
            if literal.hasPrefix("[[rc:") || compressed.contains("[[rc:\(literal)]]") {
                continue
            }
            if isSalientLinePin(literal) {
                continue
            }
            return .rejected("hallucinated literal: \(literal)")
        }

        let compressedLower = compressed.lowercased()
        for line in original.split(whereSeparator: \.isNewline).map(String.init) {
            let words = salientWords(in: line)
            guard !words.isEmpty else { continue }
            if words.allSatisfy({ !compressedLower.contains($0) }) {
                return .rejected("missing salient word: \(words.sorted().first ?? "")")
            }
        }

        return .accepted
    }

    private static func salientWords(in line: String) -> Set<String> {
        let lower = line.lowercased()
        var result = Set<String>()
        for word in salientWords where lower.range(of: #"\b\#(word)\b"#, options: .regularExpression) != nil {
            result.insert(word)
        }
        return result
    }

    private static func isSalientLinePin(_ literal: String) -> Bool {
        literal.contains(" ") && !salientWords(in: literal).isEmpty
    }
}
