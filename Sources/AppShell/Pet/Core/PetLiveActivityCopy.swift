import Foundation
import CoreModel

/// Pure mapper: pet popover surface → Live Activity text slots.
/// Design of the Lock Screen card is unchanged; only title/status/preview/phase.
public enum PetLiveActivityCopy: Sendable {
    public struct Input: Equatable, Sendable {
        public let active: [PetActiveThreadItem]
        public let needsYou: [PetAttentionItem]
        public let completed: [PetAttentionItem]
        /// One-sentence local-LLM description of what the agent is doing.
        /// Nil until the on-device model produces one (or forever, when Token
        /// Saver is off) — the deterministic preview covers that case.
        public let summary: String?

        public init(
            active: [PetActiveThreadItem],
            needsYou: [PetAttentionItem],
            completed: [PetAttentionItem],
            summary: String? = nil
        ) {
            self.active = active
            self.needsYou = needsYou
            self.completed = completed
            self.summary = summary
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

    // MARK: - Shared title / subtitle copy (iOS LiveActivityCopy twin)
    //
    // These three helpers are the single source of the Lock Screen wording on
    // this side of the wire. The iOS twin is
    // ios-app/App/Sources/Notifications/LiveActivityCopy.swift
    // (workingTitle / completedTitle / doneFailedLine). iOS only paints its own
    // copy on a card the Mac does not own, so the two must stay identical or the
    // same state reads differently depending on who happens to own the card.

    /// "1 Thread Running" / "N Threads Running".
    public static func runningTitle(count: Int) -> String {
        let n = max(0, count)
        return n == 1 ? "1 Thread Running" : "\(n) Threads Running"
    }

    /// "1 Thread Completed" / "N Threads Completed" — finished, not necessarily green.
    public static func completedTitle(count: Int) -> String {
        let n = max(0, count)
        return n == 1 ? "1 Thread Completed" : "\(n) Threads Completed"
    }

    /// "2 done - 7 failed" — the glanceable outcome split shown as the subtitle
    /// on both the running and the terminal card.
    public static func doneFailedLine(done: Int, failed: Int) -> String {
        let d = max(0, done)
        let f = max(0, failed)
        if d > 0, f > 0 { return "\(d) done - \(f) failed" }
        if d > 0 { return d == 1 ? "1 done" : "\(d) done" }
        if f > 0 { return f == 1 ? "1 failed" : "\(f) failed" }
        return ""
    }

    /// Outcome tally of finished agent *threads* in the pet's Completed bucket.
    ///
    /// Host notifications (git / project script / SSH transfer) also live in that
    /// bucket but are deliberately excluded: they are not threads, so counting
    /// them would make "N Threads Completed" lie. Interrupted runs are folded
    /// into the failed side of the subtitle split (same rule as iOS
    /// `terminalInbox`) but kept separate so an interrupt-only inbox can say so.
    static func outcomeCounts(_ completed: [PetAttentionItem]) -> (done: Int, failed: Int, interrupted: Int) {
        var done = 0
        var failed = 0
        var interrupted = 0
        for item in completed {
            switch item.kind {
            case .agentOutcome(.completed): done += 1
            case .agentOutcome(.failed): failed += 1
            case .agentOutcome(.interrupted): interrupted += 1
            case .notification, .callback:
                continue
            }
        }
        return (done, failed, interrupted)
    }

    /// Subtitle for the terminal card: the split, or the interrupt noun when a
    /// stop was user-initiated rather than an error.
    static func terminalStatusLine(done: Int, failed: Int, interrupted: Int) -> String {
        if done == 0, failed == 0, interrupted > 0 {
            return interrupted == 1 ? "1 interrupted" : "\(interrupted) interrupted"
        }
        return doneFailedLine(done: done, failed: failed + interrupted)
    }

    // MARK: - Active (1 or many)

    private static func makeActive(_ input: Input) -> Output {
        let active = input.active
        let count = active.count
        let attentionPreview = attentionPreviewLine(needsYou: input.needsYou, completed: input.completed)
        // Subtitle while threads run is the unread outcome split, matching the
        // terminal card. Empty when nothing has finished yet — then the identity
        // crumbs below take the slot instead of showing a blank line.
        let outcomes = outcomeCounts(input.completed)
        let outcomeSplit = doneFailedLine(
            done: outcomes.done,
            failed: outcomes.failed + outcomes.interrupted
        )

        // Title is always the running count — most important Lock Screen signal
        // (iOS LiveActivityCopy.workingTitle parity). Thread identity stays on
        // statusLine / preview so outcomes and progress never replace the count.
        if count == 1, let row = active.first {
            let title = runningTitle(count: 1)
            // Outcome split first; otherwise pet detail (ws - provider - title - elapsed).
            let status = outcomeSplit.isEmpty ? (row.detail ?? "Running") : outcomeSplit
            // Single-active description: the local-LLM sentence when the model
            // produced one, else the latest material thread update (tools /
            // assistant), else identity detail. Attention still outranks all of
            // it — "Needs you · Approve: Run command" is actionable and must not
            // be replaced by prose.
            let preview = attentionPreview
                ?? input.summary
                ?? row.lastUpdatePreview
                ?? row.detail
                ?? (detailThreadTitle(from: row.detail) ?? row.title)
            let ids = routeIDs(from: row.route)
            return Output(
                title: title,
                statusLine: sanitize(status, fallback: "Running"),
                preview: sanitize(preview, fallback: title),
                phase: .running,
                activeThreadCount: 1,
                runStartDate: nil, // elapsed already embedded in pet detail when available
                workspaceId: ids.workspaceId,
                threadId: ids.threadId
            )
        }

        // Multi active: overview shape (parity with iOS multi-run card).
        let title = runningTitle(count: count)
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
        let crumbs = statusParts.isEmpty ? title : statusParts.joined(separator: " · ")
        let statusLine = outcomeSplit.isEmpty ? crumbs : outcomeSplit

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
        let preview = attentionPreview ?? input.summary ?? listPreview

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
        let statusLine: String
        if !needs.isEmpty {
            // Needs-you is a distinct, actionable state — never relabel a pending
            // approval as "Completed" just because no thread is running.
            title = needs.count == 1
                ? "1 item needs attention"
                : "\(needs.count) items need attention"
            statusLine = top.map { sanitize($0.title, fallback: title) } ?? title
        } else {
            // Terminal inbox: "N Threads Completed" over the done/failed split
            // (iOS LiveActivityCopy.terminalInbox parity).
            let outcomes = outcomeCounts(done)
            let threadTotal = outcomes.done + outcomes.failed + outcomes.interrupted
            if threadTotal > 0 {
                title = completedTitle(count: threadTotal)
                statusLine = terminalStatusLine(
                    done: outcomes.done,
                    failed: outcomes.failed,
                    interrupted: outcomes.interrupted
                )
            } else {
                // Host notifications only (git / script / SSH) — not threads, so
                // the item wording stays.
                title = attentionCount == 1
                    ? "1 item ready"
                    : "\(attentionCount) items ready"
                statusLine = top.map { sanitize($0.title, fallback: title) } ?? title
            }
        }
        // Description: the local-LLM sentence when available. It replaces the
        // identity crumb list ("elephant - Claude - https://… · +7 more"), which
        // repeated the subtitle instead of saying what happened.
        var previewParts: [String] = []
        if let detail = top.flatMap(\.detail) {
            previewParts.append(detail)
        }
        let extra = attentionCount - 1
        if extra > 0 {
            previewParts.append("+\(extra) more")
        }
        let preview = input.summary
            ?? (previewParts.isEmpty ? statusLine : previewParts.joined(separator: " · "))
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
