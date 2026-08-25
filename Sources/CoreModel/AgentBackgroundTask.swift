import Foundation

/// CLI-owned background work that can keep an Agent App run live after the
/// model has already stopped talking (`local_bash` shells, `local_agent`
/// subagents). Parsed from `claude.session.snapshot` so the UI can name the
/// thing holding Stop instead of a generic "Awaiting".
public enum AgentBackgroundTaskKind: String, Sendable, Equatable {
    case shell
    case agent
    case unknown

    public init(taskType: String?) {
        switch taskType {
        case "local_bash": self = .shell
        case "local_agent": self = .agent
        default: self = .unknown
        }
    }
}

public struct AgentBackgroundTask: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: AgentBackgroundTaskKind
    public let description: String?

    public init(id: String, kind: AgentBackgroundTaskKind, description: String? = nil) {
        self.id = id
        self.kind = kind
        self.description = Self.safeDescription(description)
    }

    /// Never put a provider payload / command-shaped JSON blob in compact
    /// working chrome. Malformed or sparse rows simply fall back to count + kind.
    private static func safeDescription(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data),
           value is [String: Any] || value is [Any] {
            return nil
        }
        return trimmed.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Unknown-kind placeholders for the adapter's id-only snapshots.
    public static func placeholders(fromIds ids: [String]) -> [AgentBackgroundTask] {
        ids.compactMap { id in
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return AgentBackgroundTask(id: trimmed, kind: .unknown)
        }
    }
}
