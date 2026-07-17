import Foundation

public enum PetAttentionOutcome: Sendable, Equatable {
    case completed
    case failed
    case interrupted
}

public enum PetAttentionOperationOutcome: Sendable, Equatable {
    case succeeded
    case failed
}

public enum PetAttentionKind: Sendable, Equatable {
    case agentOutcome(PetAttentionOutcome)
    case agentRunning
    case approval
    case question(isSecret: Bool)
    case fileConflict
    case gitDelivery(PetAttentionOperationOutcome)
    case projectScript(PetAttentionOperationOutcome)
    case sshTransfer(PetAttentionOperationOutcome)
    case providerUpdateFailed
    case serverListenerFailed
}

public struct PetAttentionContext: Sendable, Equatable {
    public let workspaceName: String?
    public let providerName: String?

    public init(workspaceName: String? = nil, providerName: String? = nil) {
        self.workspaceName = workspaceName
        self.providerName = providerName
    }
}

/// Raw provider/operation text may be supplied by integration code for diagnostics,
/// but is deliberately ignored by `PetAttentionPresentation.safe`.
public struct PetAttentionRawContent: Sendable, Equatable {
    public let title: String?
    public let detail: String?

    public init(title: String? = nil, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }
}

public struct PetAttentionPresentation: Sendable, Equatable {
    public let title: String
    public let detail: String?

    public init(title: String, detail: String?) {
        self.title = title
        self.detail = detail
    }

    public static func safe(
        kind: PetAttentionKind,
        context: PetAttentionContext = PetAttentionContext(),
        untrusted: PetAttentionRawContent? = nil
    ) -> PetAttentionPresentation {
        // Explicitly discard prompts, commands, paths, tokens, and provider detail.
        // The fixed copy below is the privacy boundary for the always-on-top window.
        _ = untrusted

        let title: String
        switch kind {
        case .agentOutcome(.completed): title = "Agent run completed"
        case .agentOutcome(.failed): title = "Agent run failed"
        case .agentOutcome(.interrupted): title = "Agent run interrupted"
        case .agentRunning: title = "Agent run in progress"
        case .approval: title = "Approval required"
        case .question(isSecret: false): title = "Input requested"
        case .question(isSecret: true): title = "Secret input requested"
        case .fileConflict: title = "File conflict needs review"
        case .gitDelivery(.succeeded): title = "Git delivery completed"
        case .gitDelivery(.failed): title = "Git delivery failed"
        case .projectScript(.succeeded): title = "Project script completed"
        case .projectScript(.failed): title = "Project script failed"
        case .sshTransfer(.succeeded): title = "SSH transfer completed"
        case .sshTransfer(.failed): title = "SSH transfer failed"
        case .providerUpdateFailed: title = "Provider update failed"
        case .serverListenerFailed: title = "Remote Code listener needs attention"
        }

        let contextParts = [context.workspaceName, context.providerName]
            .compactMap(PetAttentionRedactor.safeContextLabel)
        return PetAttentionPresentation(
            title: title,
            detail: contextParts.isEmpty ? nil : contextParts.joined(separator: " · ")
        )
    }
}

public enum PetAttentionCountFormatter {
    public static func badgeText(count: Int, isEnabled: Bool = true) -> String? {
        guard isEnabled, count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }

    public static func accessibilityValue(count: Int) -> String {
        switch max(0, count) {
        case 0: return "No items need attention"
        case 1: return "1 item needs attention"
        case let count: return "\(count) items need attention"
        }
    }
}

/// Blue pet badge for in-flight agent threads. Always enabled when count > 0;
/// membership must come from the live active-run projection, not DB status.
public enum PetActiveThreadCountFormatter {
    public static func badgeText(count: Int) -> String? {
        PetAttentionCountFormatter.badgeText(count: count, isEnabled: true)
    }

    public static func accessibilityValue(count: Int) -> String {
        switch max(0, count) {
        case 0: return "No active agent threads"
        case 1: return "1 active agent thread"
        case let count: return "\(count) active agent threads"
        }
    }

    public static func combinedAccessibilityValue(activeCount: Int, attentionCount: Int) -> String {
        let active = accessibilityValue(count: activeCount)
        let attention = PetAttentionCountFormatter.accessibilityValue(count: attentionCount)
        if max(0, activeCount) == 0 { return attention }
        if max(0, attentionCount) == 0 { return active }
        return "\(active). \(attention)"
    }
}

public enum PetAttentionRedactor {
    public static let maximumContextCharacters = 80

    public static func safeContextLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var value = raw.replacingOccurrences(
            of: #"(?i)\bbearer\s+[^\s,;]+"#,
            with: "Bearer [redacted]",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?i)\b(password|passwd|(?:(?:access|refresh|id)[_-]?)?token|client[_-]?secret|secret|api[_-]?key|private[_-]?key|authorization|cookie)\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
            with: "$1=[redacted]",
            options: .regularExpression
        )
        value = value
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return String(value.prefix(maximumContextCharacters))
    }
}
