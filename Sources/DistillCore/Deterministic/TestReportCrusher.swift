import Foundation

public enum TestReportCrusher {
    public static func looksLikeTestReport(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        return pytestSummary(in: lines) != nil && lines.contains(where: isPytestPassedLine)
    }

    public static func crush(_ input: String, handle: String?) -> String? {
        guard let handle, !handle.isEmpty else { return nil }
        let lines = input.components(separatedBy: "\n")
        guard let summary = pytestSummary(in: lines) else { return nil }

        let passedLines = lines.filter(isPytestPassedLine)
        guard passedLines.count == summary.passed else { return nil }

        let failureLines = lines.filter(isFailureLine)
        guard failureLines.count >= summary.failed else { return nil }

        var out: [String] = []
        out.append("pytest: \(passedLines.count) passing-test lines elided [[rc:\(handle)]]")
        out.append(contentsOf: failureLines)
        out.append(summary.line)

        let output = out.joined(separator: "\n")
        // PERF: never-inflate via O(1) utf8.count (not Character.count grapheme walk).
        return output.utf8.count < input.utf8.count ? output : nil
    }

    private static func pytestSummary(in lines: [String]) -> (line: String, failed: Int, passed: Int)? {
        for line in lines.reversed() {
            let lower = line.lowercased()
            guard lower.contains(" passed"), lower.contains("=") else { continue }
            let passed = firstInt(in: lower, before: "passed")
            let failed = firstInt(in: lower, before: "failed") ?? 0
            if let passed {
                return (line, failed, passed)
            }
        }
        return nil
    }

    private static func firstInt(in text: String, before word: String) -> Int? {
        let pattern = #"([0-9]+)\s+"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#
        guard let match = regex(pattern, in: text).first,
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[range])
    }

    private static func isPytestPassedLine(_ line: String) -> Bool {
        line.range(of: #"::[^\s]+.*\bPASSED\b"#, options: .regularExpression) != nil
    }

    private static func isFailureLine(_ line: String) -> Bool {
        line.range(of: #"::[^\s]+.*\b(FAILED|ERROR)\b"#, options: .regularExpression) != nil
    }

    private static func regex(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
    }
}
