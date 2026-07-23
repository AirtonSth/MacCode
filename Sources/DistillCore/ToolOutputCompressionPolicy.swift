import Foundation
import CoreModel

public enum ToolCompressionProfile: String, Sendable, Equatable {
    case passthrough
    case conservative
    case moderate
    case aggressive

    public var allowsAbstractRewrite: Bool {
        self == .aggressive
    }

    public var allowsLinePruning: Bool {
        switch self {
        case .moderate, .aggressive:
            return true
        case .passthrough, .conservative:
            return false
        }
    }
}

public enum ToolCompressionSkipReason: String, Sendable, Equatable {
    case excludedTool = "excluded_tool"
    case notAllowlisted = "not_allowlisted"
    case belowThreshold = "below_threshold"
}

public struct ToolCompressionDecision: Sendable, Equatable {
    public let toolName: String
    public let profile: ToolCompressionProfile
    public let shouldCompress: Bool
    public let skipReason: ToolCompressionSkipReason?
    public let mode: DistillMode
    public let cacheState: String
    public let minBytes: Int
    public let minLines: Int
    public let reversibleStoreMinBytes: Int
    public let allowsAbstractRewrite: Bool
    public let allowsLinePruning: Bool
    public let contractQuestion: String
}

public struct ToolOutputCompressionPolicy: Sendable, Equatable {
    public static let defaultExcludedTools: Set<String> = [
        "Read",
        "Edit",
        "Write",
        "MultiEdit",
        "NotebookEdit"
    ]

    public static let defaultAllowlistedTools: Set<String> = [
        "Bash",
        "Grep",
        "Glob",
        "WebFetch"
    ]

    public let minBytes: Int
    public let minLines: Int
    public let reversibleStoreMinBytes: Int

    public init(minBytes: Int = 2_048, minLines: Int = 30, reversibleStoreMinBytes: Int = 2_048) {
        self.minBytes = max(1, minBytes)
        self.minLines = max(1, minLines)
        self.reversibleStoreMinBytes = max(1, reversibleStoreMinBytes)
    }

    public func decision(
        toolName: String,
        output: String,
        toolArgumentsSummary: String? = nil,
        taskSummary: String? = nil,
        bindingDigest: String? = nil
    ) -> ToolCompressionDecision {
        // Wave A shadow instrumentation (task-12): content-free scorecard; requires BindingID.
        TokenSaverWaveAShadowBridge.failOpenObserve {
            TokenSaverWaveAShadowBridge.observeToolOutput(
                toolName: toolName, output: output, bindingDigest: bindingDigest
            )
        }
        let profile = profile(for: toolName)
        let skipReason: ToolCompressionSkipReason?
        if isExcluded(toolName) {
            skipReason = .excludedTool
        } else if profile == .passthrough {
            skipReason = .notAllowlisted
        } else if !meetsSizeThreshold(output) {
            skipReason = .belowThreshold
        } else {
            skipReason = nil
        }

        return ToolCompressionDecision(
            toolName: toolName,
            profile: profile,
            shouldCompress: skipReason == nil,
            skipReason: skipReason,
            mode: .commandOutput,
            cacheState: "tool_output_hooked",
            minBytes: minBytes,
            minLines: minLines,
            reversibleStoreMinBytes: reversibleStoreMinBytes,
            allowsAbstractRewrite: profile.allowsAbstractRewrite,
            allowsLinePruning: profile.allowsLinePruning,
            contractQuestion: contractQuestion(
                toolName: toolName,
                profile: profile,
                toolArgumentsSummary: toolArgumentsSummary,
                taskSummary: taskSummary
            )
        )
    }

    public func profile(for toolName: String) -> ToolCompressionProfile {
        switch normalize(toolName) {
        case "grep", "glob":
            return .conservative
        case "bash":
            return .moderate
        case "webfetch":
            return .aggressive
        default:
            return .passthrough
        }
    }

    public func isExcluded(_ toolName: String) -> Bool {
        Self.defaultExcludedTools.map(normalize).contains(normalize(toolName))
    }

    public func meetsSizeThreshold(_ output: String) -> Bool {
        output.utf8.count > minBytes || lineCount(output) > minLines
    }

    private func contractQuestion(
        toolName: String,
        profile: ToolCompressionProfile,
        toolArgumentsSummary: String?,
        taskSummary: String?
    ) -> String {
        let context = [taskSummary, toolArgumentsSummary]
            .compactMap { value -> String? in
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return value
            }
            .joined(separator: " | ")
        let suffix = context.isEmpty ? "" : " Context: \(context)."
        switch profile {
        case .conservative:
            return "Compress search output without dropping any match line. Preserve paths, line numbers, matched text, and quoted strings verbatim; only collapse duplicate/context noise.\(suffix)"
        case .moderate:
            return "Compress command output. Preserve exit codes, failing test names, errors, warnings, assertions, numbers, paths, and quoted strings verbatim; collapse repeated progress noise.\(suffix)"
        case .aggressive:
            return "Compress fetched web content for the current task. Preserve URLs, titles, code, API signatures, numbers, and quoted strings verbatim; keep retrieve-worthy details explicit.\(suffix)"
        case .passthrough:
            return "Pass through tool output unchanged.\(suffix)"
        }
    }

    private func lineCount(_ output: String) -> Int {
        output.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private func normalize(_ toolName: String) -> String {
        toolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
    }
}
