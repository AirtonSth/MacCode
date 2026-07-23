import Foundation
import CoreModel

/// Production bridge for Wave B typed crushers (task-15).
/// Default registry/master OFF → crushers always deny; no provider payload mutation.
public enum TokenSaverTypedCrushersBridge {
    public static let taskID = "task-15"

    /// Extract pytest failure case lines (not the summary "N failed" line).
    public static func pytestFailureLines(from output: String) -> [String] {
        output.split(separator: "\n").map(String.init).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            // Case result lines, not summary
            if t.range(of: #"^\d+\s+failed"#, options: .regularExpression) != nil { return false }
            if t.contains("=====") { return false }
            return t.contains(" FAILED") || t.hasSuffix(" FAILED") || t.hasPrefix("FAILED ")
        }
    }

    /// Probe crushers on tool output. Fail-open: never throws; never mutates `output`.
    public static func observeToolOutput(toolName: String, output: String) {
        if output.range(of: #"\d+\s+failed"#, options: .regularExpression) != nil
            || output.contains("pytest") {
            _ = TokenSaverTypedCrushers.crushPytest(
                original: output,
                failureLines: pytestFailureLines(from: output)
            )
        }
        if output.contains("Traceback")
            || output.split(separator: "\n").contains(where: { TokenSaverTypedCrushers.isStackFrameLine(String($0)) }) {
            _ = TokenSaverTypedCrushers.crushStacktrace(original: output)
        }
        if TokenSaverTypedCrushers.isUnifiedDiff(output) {
            _ = TokenSaverTypedCrushers.crushDiff(original: output, isBinary: false)
        }
        if toolName == "Grep" || toolName == "Glob" {
            let lines = output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            _ = TokenSaverTypedCrushers.crushSearch(original: output, matchLines: lines)
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "{" || trimmed.first == "[" {
            _ = TokenSaverTypedCrushers.crushAdaptiveJSON(original: trimmed)
        }
    }
}
