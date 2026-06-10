import Foundation

/// Pure stateless parser that maps a single npm stdout/stderr line to a
/// provisioning stage and progress fraction.  Used by
/// ClaudeAgentSDKBridgeAdapter to emit rc_provisioning runtime events while
/// npm installs the SDK package, so the UI can show progress during the
/// otherwise-silent first-turn SDK provision.
public enum NpmInstallProgressParser {
    public struct Result: Sendable, Equatable {
        public let stage: String
        public let progress: Double

        public init(stage: String, progress: Double) {
            self.stage = stage
            self.progress = progress
        }
    }

    /// Returns a `Result` when `line` represents a recognisable npm progress
    /// event, or `nil` for noise lines (warnings, blank lines, unknown output).
    ///
    /// Stage order and progress fractions are chosen to be strictly monotonic
    /// across a typical install sequence so a UI progress bar never moves
    /// backwards:
    ///   resolving (0.10) -> fetching (0.45) -> installing (0.75) -> complete (1.0)
    public static func parse(line: String) -> Result? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Completion: "added N package(s) in Xs"
        if trimmed.hasPrefix("added "), trimmed.contains(" package") {
            return Result(stage: "complete", progress: 1.0)
        }

        // Fetch from npm registry
        if trimmed.contains("http fetch") {
            return Result(stage: "fetching", progress: 0.45)
        }

        // Reify = install-to-disk phase
        if trimmed.contains("reify") {
            return Result(stage: "installing", progress: 0.75)
        }

        // idealTree = dependency resolution phase
        if trimmed.contains("idealTree") {
            return Result(stage: "resolving", progress: 0.10)
        }

        return nil
    }
}
