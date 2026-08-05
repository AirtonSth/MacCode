import CoreModel

/// Pure lifecycle decisions shared by both Claude transports. Keeping these
/// decisions outside process/session plumbing makes the incident invariants
/// deterministic to test without launching a provider.
enum ClaudeTurnLifecycleGuard {
    enum CompletionAction: Equatable {
        case ignore
        case deferFinish
        case finish
    }

    static func hasForegroundOwnership(_ object: [String: Any]) -> Bool {
        let type = object["type"] as? String
        switch type {
        case "assistant", "message_start", "content_block_start", "content_block_delta":
            return true
        case "stream_event":
            let nested = (object["event"] as? [String: Any])?["type"] as? String
            return nested == "message_start"
                || nested == "content_block_start"
                || nested == "content_block_delta"
        default:
            return false
        }
    }

    /// A successful `result` with no assistant activity in this invocation is
    /// ambient replay/recovery traffic. It must not synthesize turn lifecycle.
    /// Provider failures remain terminal unless their origin explicitly marks
    /// them as ambient task-notification traffic. Local cancellation is always
    /// terminal because it belongs to the active invocation.
    static func suppressesTurnLifecycle(
        for object: [String: Any],
        hasForegroundOwnership: Bool,
        cancellationRequested: Bool
    ) -> Bool {
        guard (object["type"] as? String) == "result",
              !cancellationRequested else { return false }
        let isError = (object["is_error"] as? Bool)
            ?? ((object["subtype"] as? String).map { $0 != "success" } ?? false)
        let originKind = (object["origin"] as? [String: Any])?["kind"] as? String
        // The provider can emit assistant-shaped notification prose immediately
        // before this ambient result. Neither that prose nor an error-shaped
        // notification may lend lifecycle ownership to the parent turn.
        if originKind == "task-notification" { return true }
        return !isError && !hasForegroundOwnership
    }

    static func filteringTurnLifecycle(
        _ events: [AssistantEvent],
        suppress: Bool
    ) -> [AssistantEvent] {
        guard suppress else { return events }
        return events.filter { event in
            switch event {
            case .turnStarted, .turnCompleted:
                return false
            default:
                return true
            }
        }
    }

    static func completionAction(
        status: AgentRunStatus,
        hasForegroundOwnership: Bool,
        pendingTaskCount: Int,
        allowDeferral: Bool
    ) -> CompletionAction {
        if status == .completed && !hasForegroundOwnership {
            return .ignore
        }
        if status == .completed && allowDeferral && pendingTaskCount > 0 {
            return .deferFinish
        }
        return .finish
    }

    /// Returns a replacement pending-task set only for authoritative task
    /// lifecycle records. A `result` (including task-notification origin) never
    /// mutates this set by itself.
    static func updatedPendingTaskIDs(
        current: Set<String>,
        from object: [String: Any]
    ) -> Set<String>? {
        guard (object["type"] as? String) == "system",
              let subtype = object["subtype"] as? String else { return nil }
        switch subtype {
        case "background_tasks_changed":
            // An explicit empty array is authoritative idle. Missing, wrong-
            // typed, or partially malformed snapshots are ambiguity and must
            // preserve the previous pending set instead of fabricating idle.
            guard let tasks = object["tasks"] as? [[String: Any]] else { return nil }
            var ids = Set<String>()
            for task in tasks {
                guard let rawID = task["task_id"] as? String else { return nil }
                let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else { return nil }
                ids.insert(id)
            }
            return ids
        case "task_started":
            guard let id = object["task_id"] as? String else { return nil }
            var next = current
            next.insert(id)
            return next
        case "task_updated", "task_notification":
            guard let id = object["task_id"] as? String else { return nil }
            let status = (object["patch"] as? [String: Any])?["status"] as? String
                ?? object["status"] as? String
            guard let status,
                  ["completed", "failed", "killed", "cancelled"].contains(status) else {
                return nil
            }
            var next = current
            next.remove(id)
            return next
        default:
            return nil
        }
    }

    static func shouldEscalateInterrupt(
        expectedRunId: AgentRunID,
        activeRunId: AgentRunID?,
        sessionIsCurrent: Bool
    ) -> Bool {
        sessionIsCurrent && activeRunId == expectedRunId
    }
}
