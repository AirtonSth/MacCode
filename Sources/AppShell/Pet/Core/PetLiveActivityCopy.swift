import Foundation
import CoreModel
import RemoteCodeTreaty

/// Maps the authoritative Activity page to the existing Live Activity payload.
public enum PetLiveActivityCopy: Sendable {
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

    /// Nil means no current activity should own the Live Activity.
    public static func makeActivity(page: AgentActivityPage?) -> Output? {
        guard let page else { return nil }

        let pendingCallbacks = page.items
            .filter {
                $0.kind == .request && $0.blocking && $0.needsAction
                    && ($0.state == .waitingApproval || $0.state == .waitingAnswer)
            }
            .sorted { $0.occurredAt > $1.occurredAt }

        if page.counts.needsYou > 0 {
            let callback = pendingCallbacks.first
            let action = callback.map(Self.callbackLabel) ?? "Action required"
            let title = page.counts.needsYou == 1
                ? "1 item needs attention"
                : "\(page.counts.needsYou) items need attention"
            return Output(
                title: title,
                statusLine: action,
                preview: callback == nil ? action : "Needs you · \(action)",
                phase: .failed,
                activeThreadCount: page.counts.running,
                workspaceId: nil,
                threadId: nil
            )
        }

        if page.counts.running > 0 {
            let active = page.items
                .filter { $0.state == .running }
                .sorted { $0.occurredAt > $1.occurredAt }
                .first
            let status = page.counts.newResults > 0
                ? newResultsLabel(page.counts.newResults)
                : "Running"
            let identifiers = page.counts.running == 1 ? routeIDs(from: active) : (workspaceId: nil, threadId: nil)
            return Output(
                title: "\(page.counts.running) running",
                statusLine: status,
                preview: runningPreview(page: page, active: active),
                phase: .running,
                activeThreadCount: page.counts.running,
                runStartDate: page.counts.running == 1 ? active?.startedAt : nil,
                workspaceId: identifiers.workspaceId,
                threadId: identifiers.threadId
            )
        }

        guard page.counts.newResults > 0,
              let latest = page.items
                .filter({
                    $0.finishedAt != nil && $0.viewedAt == nil
                        && [.completed, .failed, .interrupted, .stopped].contains($0.state)
                })
                .sorted(by: { $0.occurredAt > $1.occurredAt })
                .first else { return nil }

        let status: String
        let phase: PrivateLiveActivityProjectionPhase
        switch latest.state {
        case .stopped:
            status = "Stopped by you"
            phase = .completed
        case .failed:
            status = "Failed"
            phase = .failed
        case .interrupted:
            status = "Interrupted"
            phase = .failed
        default:
            status = "Completed"
            phase = .completed
        }
        let preview = page.counts.newResults > 0
            ? "\(newResultsLabel(page.counts.newResults)) · \(status)"
            : status
        let identifiers = routeIDs(from: latest)
        return Output(
            title: completedTitle(count: page.counts.newResults),
            statusLine: status,
            preview: preview,
            phase: phase,
            activeThreadCount: 0,
            workspaceId: identifiers.workspaceId,
            threadId: identifiers.threadId
        )
    }

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

    /// "2 done - 7 failed" — stable shared wording for existing consumers.
    public static func doneFailedLine(done: Int, failed: Int) -> String {
        let d = max(0, done)
        let f = max(0, failed)
        if d > 0, f > 0 { return "\(d) done - \(f) failed" }
        if d > 0 { return d == 1 ? "1 done" : "\(d) done" }
        if f > 0 { return f == 1 ? "1 failed" : "\(f) failed" }
        return ""
    }

    private static func runningPreview(page: AgentActivityPage, active: AgentActivityItem?) -> String {
        guard page.counts.running == 1 else { return "Work is running" }
        return active?.kind == .operation ? "Registered operation running" : "Agent running"
    }

    private static func newResultsLabel(_ count: Int) -> String {
        count == 1 ? "1 new result" : "\(count) new results"
    }

    private static func callbackLabel(_ item: AgentActivityItem) -> String {
        item.state == .waitingApproval ? "Approval required" : "Input required"
    }

    private static func routeIDs(from item: AgentActivityItem?) -> (workspaceId: String?, threadId: String?) {
        guard let item else { return (nil, nil) }
        return (item.workspaceID?.uuidString, item.threadID?.uuidString)
    }

    private static func routeIDs(from item: AgentActivityItem) -> (workspaceId: String?, threadId: String?) {
        (item.workspaceID?.uuidString, item.threadID?.uuidString)
    }
}
