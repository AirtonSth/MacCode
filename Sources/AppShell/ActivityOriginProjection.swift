import Foundation
import RemoteCodeTreaty
import CoreModel
import Persistence

struct ActivityOriginSnapshot: Sendable {
    let labelsByRunID: [String: String]
    let botRequests: [AgentActivityItem]
    let scheduledOccurrences: [AgentActivityItem]
}

enum ActivityOriginProjection {
    static func load(db: SQLiteDB, threads: [AgentThread]) throws -> ActivityOriginSnapshot {
        let threadByID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id.value.uuidString.lowercased(), $0) })
        var labels: [String: String] = [:]
        let taskRuns = try db.performSync { database -> [(String, String)] in
            let statement = try database.prepare("""
                SELECT r.agent_run_id, t.title
                FROM scheduled_task_runs r
                JOIN scheduled_tasks t ON t.id = r.task_id
                WHERE r.agent_run_id IS NOT NULL;
                """)
            defer { statement.reset() }
            var rows: [(String, String)] = []
            while try statement.step() {
                if let runID = statement.columnText(0), let title = statement.columnText(1) {
                    rows.append((runID, title))
                }
            }
            return rows
        }
        for (runID, title) in taskRuns {
            if let id = UUID(uuidString: runID) { labels[id.uuidString] = "Scheduled task: \(PetAttentionRedactor.safeContextLabel(title) ?? "Task")" }
        }

        let botStore = BotStore(db: db)
        let conversations = try [BotAttentionState.none, .working, .unreadActivity, .needsAttention]
            .flatMap { try botStore.listConversations(attentionStates: [$0]) }
        let contextLabels = Dictionary(conversations.compactMap { conversation -> (String, String)? in
            guard let threadID = conversation.linkedAgentThreadID,
                  threadByID[threadID.value.uuidString.lowercased()] != nil else { return nil }
            return (threadID.value.uuidString.lowercased(), "Bot conversation: \(conversation.title)")
        }, uniquingKeysWith: { first, _ in first })
        let runThreads = try db.performSync { database -> [(String, String)] in
            let statement = try database.prepare("SELECT id, thread_id FROM agent_runs;")
            defer { statement.reset() }
            var rows: [(String, String)] = []
            while try statement.step() {
                if let runID = statement.columnText(0), let threadID = statement.columnText(1) {
                    rows.append((runID, threadID.lowercased()))
                }
            }
            return rows
        }
        for (runID, threadID) in runThreads where labels[runID] == nil {
            if let label = contextLabels[threadID] { labels[runID] = label }
        }

        let requests = try botStore.listAttention(includeAcknowledged: false).compactMap { item -> AgentActivityItem? in
            let state: AgentActivityState
            switch item.kind {
            case .question: state = .waitingAnswer
            case .approval: state = .waitingApproval
            case .handoff, .blocked, .unknownEffect: state = .needsYou
            case .unread: return nil
            }
            let conversation = item.conversationID.flatMap { id in conversations.first(where: { $0.id == id }) }
            let thread = conversation?.linkedAgentThreadID.flatMap { threadByID[$0.value.uuidString.lowercased()] }
            return AgentActivityItem(
                id: "bot-attention:\(item.id.value.uuidString.lowercased())",
                kind: .request,
                workspaceID: thread?.workspaceId?.value,
                threadID: thread?.id.value,
                state: state,
                title: item.kind == .approval ? "Bot approval needed" : (item.kind == .question ? "Bot answer needed" : "Bot needs attention"),
                occurredAt: item.createdAt,
                needsAction: true,
                botID: item.botID.value,
                conversationID: item.conversationID?.value
            )
        }
        let scheduledState = try db.performSync { database -> [String: (Date?, Date?)] in
            let statement = try database.prepare("SELECT item_id, viewed_at, acknowledged_at FROM activity_notification_state WHERE item_id LIKE 'activity:scheduled-occurrence:%';")
            defer { statement.reset() }
            var result: [String: (Date?, Date?)] = [:]
            while try statement.step() {
                guard let key = statement.columnText(0) else { continue }
                result[String(key.dropFirst("activity:".count))] = (statement.columnText(1).flatMap(Self.parseDate), statement.columnText(2).flatMap(Self.parseDate))
            }
            return result
        }
        let scheduledOccurrences = try db.performSync { database -> [AgentActivityItem] in
            let statement = try database.prepare("""
                SELECT r.id, r.status, r.queued_at, r.started_at, r.finished_at, r.error_summary,
                       t.id, t.title, t.workspace_id, t.provider
                FROM scheduled_task_runs r
                JOIN scheduled_tasks t ON t.id = r.task_id
                WHERE r.agent_run_id IS NULL
                ORDER BY COALESCE(r.finished_at, r.started_at, r.queued_at) DESC;
                """)
            defer { statement.reset() }
            func date(_ index: Int32) -> Date? {
                guard let raw = statement.columnText(index) else { return nil }
                return Self.parseDate(raw)
            }
            var items: [AgentActivityItem] = []
            while try statement.step() {
                guard let id = statement.columnText(0), let rawStatus = statement.columnText(1),
                      let queuedAt = date(2), let workspace = statement.columnText(8).flatMap(UUID.init(uuidString:)) else { continue }
                let state: AgentActivityState
                switch rawStatus {
                case "queued": state = .queued
                case "running": state = .running
                case "completed": state = .completed
                case "failed": state = .failed
                case "cancelled": state = .stopped
                default: continue
                }
                let finishedAt = date(4)
                let itemID = "scheduled-occurrence:\(id)"
                let storedState = scheduledState[itemID]
                items.append(AgentActivityItem(
                    id: itemID, kind: .operation, workspaceID: workspace,
                    state: state, title: PetAttentionRedactor.safeContextLabel(statement.columnText(7) ?? "Scheduled task") ?? "Scheduled task",
                    provider: statement.columnText(9), summary: statement.columnText(5),
                    occurredAt: finishedAt ?? date(3) ?? queuedAt, startedAt: date(3), finishedAt: finishedAt,
                    viewedAt: storedState?.0, attentionAcknowledgedAt: storedState?.1,
                    needsAction: state == .failed && storedState?.1 == nil, originLabel: "Scheduled task"
                ))
            }
            return items
        }
        return ActivityOriginSnapshot(labelsByRunID: labels, botRequests: requests, scheduledOccurrences: scheduledOccurrences)
    }

    private static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return fractional.date(from: raw) ?? plain.date(from: raw)
    }
}
