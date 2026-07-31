import Foundation
import CoreModel

/// Pure mapper: pet popover surface → Live Activity text slots.
/// Design of the Lock Screen card is unchanged; only title/status/preview/phase.
public enum PetLiveActivityCopy: Sendable {
    public struct Input: Equatable, Sendable {
        public let active: [PetActiveThreadItem]
        public let needsYou: [PetAttentionItem]
        public let completed: [PetAttentionItem]

        public init(
            active: [PetActiveThreadItem],
            needsYou: [PetAttentionItem],
            completed: [PetAttentionItem]
        ) {
            self.active = active
            self.needsYou = needsYou
            self.completed = completed
        }

        public var isEmpty: Bool {
            active.isEmpty && needsYou.isEmpty && completed.isEmpty
        }
    }

    public struct Output: Equatable, Sendable {
        public let title: String
        public let statusLine: String
        public let preview: String
        public let phase: PrivateLiveActivityProjectionPhase
        public let activeThreadCount: Int
        public let runStartDate: Date?
        public let workspaceId: String?
        public let threadId: String?

        public init(
            title: String,
            statusLine: String,
            preview: String,
            phase: PrivateLiveActivityProjectionPhase,
            activeThreadCount: Int,
            runStartDate: Date? = nil,
            workspaceId: String? = nil,
            threadId: String? = nil
        ) {
            self.title = title
            self.statusLine = statusLine
            self.preview = preview
            self.phase = phase
            self.activeThreadCount = activeThreadCount
            self.runStartDate = runStartDate
            self.workspaceId = workspaceId
            self.threadId = threadId
        }
    }

    /// Returns nil when the Live Activity should end (nothing on the pet surface).
    public static func make(_ input: Input) -> Output? {
        guard !input.isEmpty else { return nil }

        if !input.active.isEmpty {
            return makeActive(input)
        }
        return makeAttentionOnly(input)
    }

    // MARK: - Active (1 or many)

    private static func makeActive(_ input: Input) -> Output {
        let active = input.active
        let count = active.count
        let attentionPreview = attentionPreviewLine(needsYou: input.needsYou, completed: input.completed)

        if count == 1, let row = active.first {
            let title = row.title == "Agent run in progress"
                ? (detailThreadTitle(from: row.detail) ?? row.title)
                : row.title
            // Prefer pet detail (ws - provider - title - elapsed) on status when present.
            let status = row.detail ?? "1 active run"
            // Single-active description: latest material thread update (tools /
            // assistant) when known; identity detail only as fallback. Attention
            // still wins so "Needs you" stays visible.
            let preview = attentionPreview
                ?? row.lastUpdatePreview
                ?? row.detail
                ?? title
            let ids = routeIDs(from: row.route)
            return Output(
                title: sanitize(title, fallback: "Agent run in progress"),
                statusLine: sanitize(status, fallback: "1 active run"),
                preview: sanitize(preview, fallback: title),
                phase: .running,
                activeThreadCount: 1,
                runStartDate: nil, // elapsed already embedded in pet detail when available
                workspaceId: ids.workspaceId,
                threadId: ids.threadId
            )
        }

        // Multi active: overview shape (parity with iOS multi-run card).
        let title = "\(count) active runs"
        let workspaces = unique(active.compactMap(\.workspaceName))
        let workspacePart: String?
        if workspaces.isEmpty {
            workspacePart = nil
        } else if workspaces.count <= 2 {
            workspacePart = workspaces.joined(separator: ", ")
        } else {
            workspacePart = "\(workspaces.count) workspaces"
        }
        // Providers are embedded in detail as "ws - Provider - …"; extract when possible.
        let providers = unique(active.compactMap { providerFromDetail($0.detail) })
        let providerPart: String?
        if providers.isEmpty {
            providerPart = nil
        } else if providers.count <= 2 {
            providerPart = providers.joined(separator: ", ")
        } else {
            providerPart = providers.prefix(2).joined(separator: ", ") + "…"
        }
        let statusParts = [workspacePart, providerPart].compactMap { $0 }
        let statusLine = statusParts.isEmpty ? title : statusParts.joined(separator: " · ")

        let titles = unique(active.compactMap { detailThreadTitle(from: $0.detail) ?? shortTitle($0.title) })
        let listPreview: String
        if titles.isEmpty {
            listPreview = title
        } else if titles.count <= 2 {
            listPreview = titles.map { "• \($0)" }.joined(separator: "  · ")
        } else {
            let head = titles.prefix(2).map { "• \($0)" }.joined(separator: "  · ")
            listPreview = "\(head)  · +\(titles.count - 2) more"
        }
        let preview = attentionPreview ?? listPreview

        return Output(
            title: title,
            statusLine: sanitize(statusLine, fallback: title),
            preview: sanitize(preview, fallback: title),
            phase: .running,
            activeThreadCount: count,
            runStartDate: nil,
            workspaceId: nil,
            threadId: nil
        )
    }

    // MARK: - Attention only (0 active)

    private static func makeAttentionOnly(_ input: Input) -> Output {
        let needs = input.needsYou
        let done = input.completed
        let top = needs.first ?? done.first
        let attentionCount = needs.count + done.count
        let phase: PrivateLiveActivityProjectionPhase = {
            guard let top else { return .completed }
            switch top.kind {
            case .agentOutcome(.failed): return .failed
            case .agentOutcome(.interrupted): return .failed
            case .callback: return .failed // needs you — keep visually urgent
            default: return .completed
            }
        }()

        let title: String
        if !needs.isEmpty {
            title = needs.count == 1
                ? "1 item needs attention"
                : "\(needs.count) items need attention"
        } else {
            title = attentionCount == 1
                ? "1 item ready"
                : "\(attentionCount) items ready"
        }

        let statusLine = top.map { sanitize($0.title, fallback: title) } ?? title
        var previewParts: [String] = []
        if let detail = top.flatMap(\.detail) {
            previewParts.append(detail)
        }
        let extra = attentionCount - 1
        if extra > 0 {
            previewParts.append("+\(extra) more")
        }
        let preview = previewParts.isEmpty
            ? statusLine
            : previewParts.joined(separator: " · ")
        let ids = top.map { routeIDs(from: $0.route) } ?? (workspaceId: nil, threadId: nil)

        return Output(
            title: title,
            statusLine: statusLine,
            preview: sanitize(preview, fallback: statusLine),
            phase: phase,
            activeThreadCount: 0,
            runStartDate: nil,
            workspaceId: ids.workspaceId,
            threadId: ids.threadId
        )
    }

    private static func attentionPreviewLine(
        needsYou: [PetAttentionItem],
        completed: [PetAttentionItem]
    ) -> String? {
        if let top = needsYou.first {
            let more = needsYou.count - 1
            let base = "Needs you · \(top.title)"
            return more > 0 ? "\(base) · +\(more)" : base
        }
        if let top = completed.first {
            let more = completed.count - 1
            let base = "Done · \(top.title)"
            return more > 0 ? "\(base) · +\(more)" : base
        }
        return nil
    }

    // MARK: - Helpers

    private static func routeIDs(from route: PetAttentionRoute) -> (workspaceId: String?, threadId: String?) {
        switch route {
        case .agentThread(let threadID, let workspaceID):
            return (workspaceID?.value.uuidString, threadID.value.uuidString)
        case .surface(_, let workspaceID):
            return (workspaceID?.value.uuidString, nil)
        case .workspace(let workspaceID):
            return (workspaceID.value.uuidString, nil)
        case .settings:
            return (nil, nil)
        }
    }

    /// Detail format: `workspace - provider - title [- elapsed]`.
    private static func detailThreadTitle(from detail: String?) -> String? {
        guard let detail else { return nil }
        let parts = detail.split(separator: " - ").map(String.init)
        guard parts.count >= 3 else { return nil }
        // Drop trailing elapsed like "2m" / "12s" when present.
        let candidate = parts[2]
        if parts.count >= 4, isElapsed(parts.last!) {
            return shortTitle(candidate)
        }
        return shortTitle(candidate)
    }

    private static func providerFromDetail(_ detail: String?) -> String? {
        guard let detail else { return nil }
        let parts = detail.split(separator: " - ").map(String.init)
        guard parts.count >= 2 else { return nil }
        let provider = parts[1]
        if ["Codex", "Claude", "Grok"].contains(provider) { return provider }
        return nil
    }

    private static func isElapsed(_ value: String) -> Bool {
        value.range(of: #"^\d+[smhd](\s+\d+[smhd])?$"#, options: .regularExpression) != nil
    }

    private static func shortTitle(_ raw: String) -> String {
        sanitize(raw, fallback: raw, limit: 28)
    }

    private static func sanitize(_ raw: String, fallback: String, limit: Int = 80) -> String {
        let redacted = PetAttentionRedactor.safeContextLabel(raw) ?? fallback
        guard redacted.count > limit else { return redacted }
        return String(redacted.prefix(limit - 1)) + "…"
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values {
            let key = value.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(value)
        }
        return out
    }
}
