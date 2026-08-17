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
    /// XCTest / `swift test` suite footer. Singular "1 test" is legal.
    private static let xctestExecutedRegex = try! NSRegularExpression(
        pattern: #"Executed\s+(\d+)\s+tests?,\s+with\s+(\d+)\s+failures?"#
    )

    public static func looksLikeTestReport(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        if pytestSummary(in: lines) != nil && lines.contains(where: isPytestPassedLine) {
            return true
        }
        return xctestSummary(in: lines) != nil
            && lines.contains(where: { isXCTestPassedLine($0) || isXCTestFailedLine($0) })
    }

    public static func crush(_ input: String, handle: String?) -> String? {
        guard let handle, !handle.isEmpty else { return nil }
        let lines = input.components(separatedBy: "\n")
        if let pytest = crushPytest(lines: lines, handle: handle),
           pytest.utf8.count < input.utf8.count {
            return pytest
        }
        if let xctest = crushXCTest(lines: lines, handle: handle),
           xctest.utf8.count < input.utf8.count {
            return xctest
        }
        return nil
    }

    private static func crushPytest(lines: [String], handle: String) -> String? {
        guard let summary = pytestSummary(in: lines) else { return nil }

        let passedLines = lines.filter(isPytestPassedLine)
        guard passedLines.count == summary.passed else { return nil }

        let failureLines = lines.filter(isFailureLine)
        guard failureLines.count >= summary.failed else { return nil }

        var out: [String] = []
        out.append("pytest: \(passedLines.count) passing-test lines elided [[rc:\(handle)]]")
        out.append(contentsOf: failureLines)
        out.append(summary.line)
        return out.joined(separator: "\n")
    }

    /// Elide XCTest `started` / `passed` chatter. Keep failed cases, error text,
    /// file:line, suite headers, and the `Executed N tests, with F failures` footer.
    /// Reject when the footer counts do not match the kept/elided case lines so a
    /// `swift test | tail` fragment cannot drop a failure.
    private static func crushXCTest(lines: [String], handle: String) -> String? {
        guard let summary = xctestSummary(in: lines) else { return nil }
        let passedLines = lines.filter(isXCTestPassedLine)
        let failedLines = lines.filter(isXCTestFailedLine)
        guard passedLines.count == summary.executed - summary.failed else { return nil }
        guard failedLines.count == summary.failed else { return nil }

        var out: [String] = []
        var progress = 0
        out.append("xctest: \(passedLines.count) passing-test lines elided [[rc:\(handle)]]")
        out.reserveCapacity(lines.count - passedLines.count + 2)
        for line in lines {
            if isXCTestStartedLine(line) || isXCTestPassedLine(line) { continue }
            if BuildProgressCrusher.isProgressLine(line) {
                progress += 1
                continue
            }
            out.append(line)
        }
        if progress >= BuildProgressCrusher.minProgressLines {
            out.insert("spm: \(progress) progress lines elided [[rc:\(handle)]]", at: 1)
        }
        return out.joined(separator: "\n")
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

    private static func xctestSummary(in lines: [String]) -> (line: String, executed: Int, failed: Int)? {
        for line in lines.reversed() {
            let full = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = xctestExecutedRegex.firstMatch(in: line, options: [], range: full),
                  match.numberOfRanges >= 3,
                  let executedRange = Range(match.range(at: 1), in: line),
                  let failedRange = Range(match.range(at: 2), in: line),
                  let executed = Int(line[executedRange]),
                  let failed = Int(line[failedRange]) else {
                continue
            }
            return (line, executed, failed)
        }
        return nil
    }

    private static func isXCTestPassedLine(_ line: String) -> Bool {
        line.contains("Test Case '") && line.contains(" passed (")
    }

    private static func isXCTestFailedLine(_ line: String) -> Bool {
        line.contains("Test Case '") && line.contains(" failed (")
    }

    private static func isXCTestStartedLine(_ line: String) -> Bool {
        line.contains("Test Case '") && line.hasSuffix("started.")
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
