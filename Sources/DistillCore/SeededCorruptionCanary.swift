import Foundation

/// M8: seeded-corruption canaries. We deliberately corrupt a known-good summary
/// (flip a negation, delete an error line, invent a path, drop a count) and assert
/// the faithfulness gates REJECT it. This measures omission-recall / false-accept
/// of the gate without ever exposing a raw reject-rate as a quality metric (the
/// plan forbids that). Pure + deterministic so it runs as a CI canary.
public enum SeededCorruption: String, Sendable, CaseIterable {
    case negationFlip          // "not enabled" -> "enabled"
    case removedErrorLine      // delete a line containing ERROR/FAIL
    case fakePath              // inject a path that is absent from the original
    case droppedLargeNumber    // delete a 4+ digit count/id

    /// Apply the corruption to `original`, returning the corrupted text or nil if the
    /// original has no surface to corrupt this way (so the canary is skipped, not faked).
    public func apply(to original: String) -> String? {
        var lines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        switch self {
        case .negationFlip:
            for i in lines.indices {
                if let r = lines[i].range(of: #"\bnot \b"#, options: [.regularExpression, .caseInsensitive]) {
                    lines[i].removeSubrange(r)
                    return lines.joined(separator: "\n")
                }
                if let r = lines[i].range(of: #"\bnever\b"#, options: [.regularExpression, .caseInsensitive]) {
                    lines[i].replaceSubrange(r, with: "always")
                    return lines.joined(separator: "\n")
                }
            }
            return nil
        case .removedErrorLine:
            if let idx = lines.firstIndex(where: { $0.range(of: #"\b(error|fail(ed)?|fatal|panic)\b"#, options: [.regularExpression, .caseInsensitive]) != nil }) {
                lines.remove(at: idx)
                return lines.joined(separator: "\n")
            }
            return nil
        case .fakePath:
            return original + "\nsee /etc/nonexistent/injected/path.conf for details"
        case .droppedLargeNumber:
            for i in lines.indices {
                if let r = lines[i].range(of: #"\b\d{4,}\b"#, options: .regularExpression) {
                    lines[i].removeSubrange(r)
                    return lines.joined(separator: "\n")
                }
            }
            return nil
        }
    }
}

public struct SeededCorruptionCanaryReport: Sendable, Equatable {
    public let applicable: Int
    public let caught: Int
    /// Fraction of applicable corruptions the gate rejected. 1.0 = perfect omission-recall.
    public var omissionRecall: Double { applicable == 0 ? 1 : Double(caught) / Double(applicable) }
}

public enum SeededCorruptionCanary {
    /// Run every corruption that applies to `original` through `gate` and report how many
    /// were caught (rejected). `gate(original, corrupted) -> accepted`.
    public static func run(
        original: String,
        gate: (_ original: String, _ corrupted: String) -> Bool
    ) -> SeededCorruptionCanaryReport {
        var applicable = 0
        var caught = 0
        for corruption in SeededCorruption.allCases {
            guard let corrupted = corruption.apply(to: original), corrupted != original else { continue }
            applicable += 1
            if gate(original, corrupted) == false { caught += 1 } // rejected == caught
        }
        return SeededCorruptionCanaryReport(applicable: applicable, caught: caught)
    }
}
