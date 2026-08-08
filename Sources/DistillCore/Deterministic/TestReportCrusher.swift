import Foundation

public enum TestReportCrusher {
    // PERF: compile once — looksLike/crush filter every line of multi-KB pytest
    // dumps; range(of:options:.regularExpression) recompiled per line.
    private static let pytestPassedLineRegex = try! NSRegularExpression(
        pattern: #"::[^\s]+.*\bPASSED\b"#
    )
    private static let pytestFailureLineRegex = try! NSRegularExpression(
        pattern: #"::[^\s]+.*\b(FAILED|ERROR)\b"#
    )
    private static let passedCountRegex = try! NSRegularExpression(
        pattern: #"([0-9]+)\s+passed\b"#,
        options: [.caseInsensitive]
    )
    private static let failedCountRegex = try! NSRegularExpression(
        pattern: #"([0-9]+)\s+failed\b"#,
        options: [.caseInsensitive]
    )

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
            let passed = firstInt(in: lower, using: passedCountRegex)
            let failed = firstInt(in: lower, using: failedCountRegex) ?? 0
            if let passed {
                return (line, failed, passed)
            }
        }
        return nil
    }

    private static func firstInt(in text: String, using regex: NSRegularExpression) -> Int? {
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: full),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[range])
    }

    private static func isPytestPassedLine(_ line: String) -> Bool {
        matches(pytestPassedLineRegex, in: line)
    }

    private static func isFailureLine(_ line: String) -> Bool {
        matches(pytestFailureLineRegex, in: line)
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
