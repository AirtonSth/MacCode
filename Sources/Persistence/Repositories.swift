import Foundation
import CoreModel

let iso = ISO8601DateFormatter()

public enum PersistenceDataError: Error, CustomStringConvertible {
    case corruptProviderEventLog(String)
    case corruptCheckpoint(String)

    public var description: String {
        switch self {
        case .corruptProviderEventLog(let message):
            return "Corrupt provider event log: \(message)"
        case .corruptCheckpoint(let message):
            return "Corrupt agent checkpoint: \(message)"
        }
    }
}

private func parseDate(_ s: String?) -> Date {
    guard let s, let d = iso.date(from: s) else { return Date() }
    return d
}

private func encodeModelSelection(_ selection: AgentModelSelection) -> String? {
    guard let data = try? JSONEncoder().encode(selection) else { return nil }
    return String(data: data, encoding: .utf8)
}

private func decodeModelSelection(
    _ json: String?,
    provider: AgentProvider,
    model: String,
    reasoningEffort: AgentReasoningEffort,
    serviceTier: AgentServiceTier
) -> AgentModelSelection {
    if let json,
       let data = json.data(using: .utf8),
       let selection = try? JSONDecoder().decode(AgentModelSelection.self, from: data) {
        return selection
    }
    return AgentModelSelection(
        provider: provider,
        modelId: model,
        reasoningEffort: reasoningEffort,
        serviceTier: serviceTier
    )
}

public final class ProjectRepository {
    let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }

    public struct Project: Codable, Equatable {
        public let id: ProjectID
        public var name: String
        public var path: String
        public var favorite: Bool
        public var createdAt: Date
        public var updatedAt: Date
    }

    public func upsert(_ p: Project) throws {
        let st = try db.prepare("""
            INSERT INTO projects(id, name, path, favorite, created_at, updated_at)
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, path=excluded.path, favorite=excluded.favorite, updated_at=excluded.updated_at;
        """)
        try st.bind(1, p.id.value.uuidString)
        try st.bind(2, p.name)
        try st.bind(3, p.path)
        try st.bind(4, p.favorite)
        try st.bind(5, iso.string(from: p.createdAt))
        try st.bind(6, iso.string(from: p.updatedAt))
        _ = try st.step()
    }

    public func list() throws -> [Project] {
        let st = try db.prepare("SELECT id, name, path, favorite, created_at, updated_at FROM projects ORDER BY updated_at DESC;")
        var out: [Project] = []
        while try st.step() {
            let id = ProjectID(UUID(uuidString: st.columnText(0) ?? "") ?? UUID())
            out.append(Project(
                id: id,
                name: st.columnText(1) ?? "",
                path: st.columnText(2) ?? "",
                favorite: st.columnInt64(3) != 0,
                createdAt: parseDate(st.columnText(4)),
                updatedAt: parseDate(st.columnText(5))
            ))
        }
        return out
    }
}

public final class AgentThreadRepository {
    let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }

    public func upsert(_ t: AgentThread) throws {
        let st = try db.prepare("""
            INSERT INTO agent_threads(id, project_id, workspace_id, title, provider, provider_instance_id, model, provider_thread_id, status, created_at, updated_at, diff_additions, diff_deletions, has_unread, color, pinned, sort_order, permission_mode, reasoning_effort, execution_mode, base_branch, worktree_path, service_tier, model_selection_json)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, provider=excluded.provider, provider_instance_id=excluded.provider_instance_id, model=excluded.model, provider_thread_id=excluded.provider_thread_id, status=excluded.status, updated_at=excluded.updated_at, diff_additions=excluded.diff_additions, diff_deletions=excluded.diff_deletions, has_unread=excluded.has_unread, color=excluded.color, pinned=excluded.pinned, sort_order=excluded.sort_order, permission_mode=excluded.permission_mode, reasoning_effort=excluded.reasoning_effort, execution_mode=excluded.execution_mode, base_branch=excluded.base_branch, worktree_path=excluded.worktree_path, service_tier=excluded.service_tier, model_selection_json=excluded.model_selection_json;
        """)
        try st.bind(1, t.id.value.uuidString)
        try st.bind(2, t.projectId?.value.uuidString)
        try st.bind(3, t.workspaceId?.value.uuidString)
        try st.bind(4, t.title)
        try st.bind(5, t.provider.rawValue)
        try st.bind(6, t.providerInstanceId ?? t.provider.rawValue)
        try st.bind(7, t.model)
        try st.bind(8, t.providerThreadId)
        try st.bind(9, t.status.rawValue)
        try st.bind(10, iso.string(from: t.createdAt))
        try st.bind(11, iso.string(from: t.updatedAt))
        try st.bind(12, Int64(t.diffAdditions))
        try st.bind(13, Int64(t.diffDeletions))
        try st.bind(14, t.hasUnread)
        try st.bind(15, t.color)
        try st.bind(16, t.pinned)
        try st.bind(17, Int64(t.sortOrder))
        try st.bind(18, t.permissionMode.rawValue)
        try st.bind(19, t.reasoningEffort.rawValue)
        try st.bind(20, t.executionMode.rawValue)
        try st.bind(21, t.baseBranch)
        try st.bind(22, t.worktreePath)
        try st.bind(23, t.serviceTier.rawValue)
        try st.bind(24, encodeModelSelection(t.modelSelection))
        _ = try st.step()
    }

    public func list(workspaceId: WorkspaceID? = nil) throws -> [AgentThread] {
        let sql = workspaceId == nil
            ? "SELECT id, project_id, workspace_id, title, provider, provider_instance_id, model, provider_thread_id, status, created_at, updated_at, diff_additions, diff_deletions, has_unread, color, pinned, sort_order, permission_mode, reasoning_effort, execution_mode, base_branch, worktree_path, service_tier, model_selection_json FROM agent_threads ORDER BY pinned DESC, sort_order ASC, updated_at DESC;"
            : "SELECT id, project_id, workspace_id, title, provider, provider_instance_id, model, provider_thread_id, status, created_at, updated_at, diff_additions, diff_deletions, has_unread, color, pinned, sort_order, permission_mode, reasoning_effort, execution_mode, base_branch, worktree_path, service_tier, model_selection_json FROM agent_threads WHERE workspace_id = ? ORDER BY pinned DESC, sort_order ASC, updated_at DESC;"
        let st = try db.prepare(sql)
        if let wid = workspaceId { try st.bind(1, wid.value.uuidString) }
        var out: [AgentThread] = []
        while try st.step() {
            let id = AgentThreadID(UUID(uuidString: st.columnText(0) ?? "") ?? UUID())
            let pid = (st.columnText(1)).flatMap { UUID(uuidString: $0) }.map { ProjectID($0) }
            let wid = (st.columnText(2)).flatMap { UUID(uuidString: $0) }.map { WorkspaceID($0) }
            let provider = AgentProvider(rawValue: st.columnText(4) ?? "codex") ?? .codex
            let model = st.columnText(6) ?? ""
            let reasoningEffort = AgentReasoningEffort(rawValue: st.columnText(18) ?? "") ?? .medium
            let serviceTier = AgentServiceTier(rawValue: st.columnText(22) ?? "") ?? .auto
            out.append(AgentThread(
                id: id,
                projectId: pid,
                workspaceId: wid,
                title: st.columnText(3) ?? "",
                provider: provider,
                providerInstanceId: st.columnText(5) ?? provider.rawValue,
                model: model,
                providerThreadId: st.columnText(7),
                status: AgentRunStatus(rawValue: st.columnText(8) ?? "") ?? .pending,
                createdAt: parseDate(st.columnText(9)),
                updatedAt: parseDate(st.columnText(10)),
                diffAdditions: Int(st.columnInt64(11)),
                diffDeletions: Int(st.columnInt64(12)),
                hasUnread: st.columnInt64(13) != 0,
                color: st.columnText(14),
                pinned: st.columnInt64(15) != 0,
                sortOrder: Int(st.columnInt64(16)),
                permissionMode: AgentPermissionMode(rawValue: st.columnText(17) ?? "") ?? .supervised,
                reasoningEffort: reasoningEffort,
                executionMode: AgentExecutionMode(rawValue: st.columnText(19) ?? "") ?? .local,
                baseBranch: st.columnText(20),
                worktreePath: st.columnText(21),
                serviceTier: serviceTier,
                modelSelection: decodeModelSelection(st.columnText(23), provider: provider, model: model, reasoningEffort: reasoningEffort, serviceTier: serviceTier)
            ))
        }
        return out
    }

    public func get(id: AgentThreadID) throws -> AgentThread? {
        let st = try db.prepare("SELECT id, project_id, workspace_id, title, provider, provider_instance_id, model, provider_thread_id, status, created_at, updated_at, diff_additions, diff_deletions, has_unread, color, pinned, sort_order, permission_mode, reasoning_effort, execution_mode, base_branch, worktree_path, service_tier, model_selection_json FROM agent_threads WHERE id = ?;")
        try st.bind(1, id.value.uuidString)
        if try st.step() {
            let idVal = AgentThreadID(UUID(uuidString: st.columnText(0) ?? "") ?? UUID())
            let pid = (st.columnText(1)).flatMap { UUID(uuidString: $0) }.map { ProjectID($0) }
            let wid = (st.columnText(2)).flatMap { UUID(uuidString: $0) }.map { WorkspaceID($0) }
            let provider = AgentProvider(rawValue: st.columnText(4) ?? "codex") ?? .codex
            let model = st.columnText(6) ?? ""
            let reasoningEffort = AgentReasoningEffort(rawValue: st.columnText(18) ?? "") ?? .medium
            let serviceTier = AgentServiceTier(rawValue: st.columnText(22) ?? "") ?? .auto
            return AgentThread(
                id: idVal,
                projectId: pid,
                workspaceId: wid,
                title: st.columnText(3) ?? "",
                provider: provider,
                providerInstanceId: st.columnText(5) ?? provider.rawValue,
                model: model,
                providerThreadId: st.columnText(7),
                status: AgentRunStatus(rawValue: st.columnText(8) ?? "") ?? .pending,
                createdAt: parseDate(st.columnText(9)),
                updatedAt: parseDate(st.columnText(10)),
                diffAdditions: Int(st.columnInt64(11)),
                diffDeletions: Int(st.columnInt64(12)),
                hasUnread: st.columnInt64(13) != 0,
                color: st.columnText(14),
                pinned: st.columnInt64(15) != 0,
                sortOrder: Int(st.columnInt64(16)),
                permissionMode: AgentPermissionMode(rawValue: st.columnText(17) ?? "") ?? .supervised,
                reasoningEffort: reasoningEffort,
                executionMode: AgentExecutionMode(rawValue: st.columnText(19) ?? "") ?? .local,
                baseBranch: st.columnText(20),
                worktreePath: st.columnText(21),
                serviceTier: serviceTier,
                modelSelection: decodeModelSelection(st.columnText(23), provider: provider, model: model, reasoningEffort: reasoningEffort, serviceTier: serviceTier)
            )
        }
        return nil
    }

    public func delete(id: AgentThreadID) throws {
        let st = try db.prepare("DELETE FROM agent_threads WHERE id = ?;")
        try st.bind(1, id.value.uuidString)
        _ = try st.step()
    }

    public func setPinned(id: AgentThreadID, pinned: Bool) throws {
        guard var t = try get(id: id) else { return }
        t.pinned = pinned
        t.updatedAt = Date()
        try upsert(t)
        if let wid = t.workspaceId { try normalizeOrder(workspaceId: wid) }
    }

    public func reorder(id: AgentThreadID, position: Int) throws {
        guard let t = try get(id: id), let wid = t.workspaceId else { return }
        var list = try list(workspaceId: wid)
        guard let current = list.firstIndex(where: { $0.id == id }) else { return }
        let item = list.remove(at: current)
        list.insert(item, at: max(0, min(position, list.count)))
        try normalizeOrder(workspaceId: wid, ordered: list)
    }

    public func delete(ids: [AgentThreadID]) throws {
        for id in ids { try delete(id: id) }
    }

    private func normalizeOrder(workspaceId: WorkspaceID, ordered: [AgentThread]? = nil) throws {
        let list: [AgentThread]
        if let ordered {
            list = ordered
        } else {
            list = try self.list(workspaceId: workspaceId)
        }
        let sorted = list.filter(\.pinned) + list.filter { !$0.pinned }
        try db.transaction {
            for (idx, var t) in sorted.enumerated() {
                t.sortOrder = idx
                try upsert(t)
            }
        }
    }
}

public final class AgentMessageRepository {
    let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }

    public func append(_ m: AgentMessage) throws {
        let st = try db.prepare("INSERT OR REPLACE INTO agent_messages(id, thread_id, role, content, created_at) VALUES(?, ?, ?, ?, ?);")
        try st.bind(1, m.id.value.uuidString)
        try st.bind(2, m.threadId.value.uuidString)
        try st.bind(3, m.role.rawValue)
        try st.bind(4, m.content)
        try st.bind(5, iso.string(from: m.createdAt))
        _ = try st.step()
    }

    public func list(threadId: AgentThreadID) throws -> [AgentMessage] {
        let st = try db.prepare("SELECT id, thread_id, role, content, created_at FROM agent_messages WHERE thread_id = ? ORDER BY created_at ASC, rowid ASC;")
        try st.bind(1, threadId.value.uuidString)
        var out: [AgentMessage] = []
        while try st.step() {
            out.append(message(from: st))
        }
        return out
    }

    public func count(threadId: AgentThreadID) throws -> Int {
        let st = try db.prepare("SELECT COUNT(*) FROM agent_messages WHERE thread_id = ?;")
        try st.bind(1, threadId.value.uuidString)
        return (try st.step()) ? Int(st.columnInt64(0)) : 0
    }

    /// PERF-006: the set of thread ids that have at least one message,
    /// computed in a single query. Lets thread-list payloads derive
    /// `provider_locked` for every thread without one query per thread.
    public func threadIdsWithMessages() throws -> Set<AgentThreadID> {
        let st = try db.prepare("SELECT DISTINCT thread_id FROM agent_messages;")
        var out: Set<AgentThreadID> = []
        while try st.step() {
            if let uuid = (st.columnText(0)).flatMap({ UUID(uuidString: $0) }) {
                out.insert(AgentThreadID(uuid))
            }
        }
        return out
    }

    /// The newest `limit` messages, returned oldest→newest for display.
    /// Backs the bounded message window (B4 pagination).
    public func listRecent(threadId: AgentThreadID, limit: Int) throws -> [AgentMessage] {
        let st = try db.prepare("SELECT id, thread_id, role, content, created_at FROM agent_messages WHERE thread_id = ? ORDER BY created_at DESC, id DESC LIMIT ?;")
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, max(0, limit))
        var out: [AgentMessage] = []
        while try st.step() {
            out.append(message(from: st))
        }
        // PERF: reverse() in-place avoids allocating a second Array copy.
        // Result is identical: rows were fetched newest-first (DESC), reversing
        // gives oldest-first display order, same as the previous out.reversed().
        out.reverse()
        return out
    }

    public func get(id: AgentMessageID) throws -> AgentMessage? {
        let st = try db.prepare("SELECT id, thread_id, role, content, created_at FROM agent_messages WHERE id = ? LIMIT 1;")
        try st.bind(1, id.value.uuidString)
        return (try st.step()) ? message(from: st) : nil
    }

    public func listPage(threadId: AgentThreadID, limit requestedLimit: Int, before cursor: AgentMessageCursor?) throws -> AgentMessagePage {
        try listPage(threadId: threadId, limit: requestedLimit, before: cursor, after: nil)
    }

    public func listPage(threadId: AgentThreadID, limit requestedLimit: Int, after cursor: AgentMessageCursor?) throws -> AgentMessagePage {
        try listPage(threadId: threadId, limit: requestedLimit, before: nil, after: cursor)
    }

    public func listPage(threadId: AgentThreadID, limit requestedLimit: Int, before beforeCursor: AgentMessageCursor?, after afterCursor: AgentMessageCursor?) throws -> AgentMessagePage {
        let limit = max(0, min(requestedLimit, 500))
        let sql: String
        if let _ = afterCursor {
            sql = """
            SELECT id, thread_id, role, content, created_at
            FROM agent_messages
            WHERE thread_id = ? AND (created_at > ? OR (created_at = ? AND id > ?))
            ORDER BY created_at ASC, rowid ASC
            LIMIT ?;
            """
        } else if beforeCursor == nil {
            sql = "SELECT id, thread_id, role, content, created_at FROM agent_messages WHERE thread_id = ? ORDER BY created_at DESC, rowid DESC LIMIT ?;"
        } else {
            sql = """
            SELECT id, thread_id, role, content, created_at
            FROM agent_messages
            WHERE thread_id = ? AND (created_at < ? OR (created_at = ? AND id < ?))
            ORDER BY created_at DESC, rowid DESC
            LIMIT ?;
            """
        }
        let st = try db.prepare(sql)
        try st.bind(1, threadId.value.uuidString)
        if let cursor = afterCursor {
            let created = iso.string(from: cursor.createdAt)
            try st.bind(2, created)
            try st.bind(3, created)
            try st.bind(4, cursor.id.value.uuidString)
            try st.bind(5, limit + 1)
        } else if let cursor = beforeCursor {
            let created = iso.string(from: cursor.createdAt)
            try st.bind(2, created)
            try st.bind(3, created)
            try st.bind(4, cursor.id.value.uuidString)
            try st.bind(5, limit + 1)
        } else {
            try st.bind(2, limit + 1)
        }
        var rows: [AgentMessage] = []
        while try st.step() {
            rows.append(message(from: st))
        }
        let pageRows = Array(rows.prefix(limit))
        let display = afterCursor == nil ? Array(pageRows.reversed()) : pageRows
        let next = display.first.map { AgentMessageCursor(createdAt: $0.createdAt, id: $0.id) }
        let after = display.last.map { AgentMessageCursor(createdAt: $0.createdAt, id: $0.id) }
        return AgentMessagePage(
            messages: display,
            hasMoreOlder: afterCursor != nil || rows.count > limit,
            nextBefore: next,
            hasMoreNewer: beforeCursor != nil || (afterCursor != nil && rows.count > limit),
            nextAfter: after
        )
    }

    private func message(from st: SQLiteStatement) -> AgentMessage {
        let id = AgentMessageID(UUID(uuidString: st.columnText(0) ?? "") ?? UUID())
        let tid = AgentThreadID(UUID(uuidString: st.columnText(1) ?? "") ?? UUID())
        return AgentMessage(
            id: id,
            threadId: tid,
            role: AgentMessageRole(rawValue: st.columnText(2) ?? "") ?? .user,
            content: st.columnText(3) ?? "",
            createdAt: parseDate(st.columnText(4))
        )
    }

    public func delete(ids: [AgentMessageID]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try db.transaction {
            let st = try db.prepare("DELETE FROM agent_messages WHERE id IN (\(placeholders));")
            for (index, id) in ids.enumerated() {
                try st.bind(Int32(index + 1), id.value.uuidString)
            }
            _ = try st.step()
        }
    }
}

public final class AgentQueuedMessageRepository {
    let db: SQLiteDB
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(db: SQLiteDB) { self.db = db }

    public func enqueue(
        threadId: AgentThreadID,
        text: String,
        attachments: [AgentAttachment],
        interactionMode: AgentInteractionMode
    ) throws -> AgentQueuedMessage {
        let position = try nextPosition(threadId: threadId)
        let queued = AgentQueuedMessage(
            threadId: threadId,
            text: text,
            attachments: attachments,
            interactionMode: interactionMode,
            position: position
        )
        try upsert(queued)
        return queued
    }

    public func upsert(_ message: AgentQueuedMessage) throws {
        let st = try db.prepare("""
            INSERT INTO agent_queued_messages(id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET text=excluded.text, attachments_json=excluded.attachments_json, interaction_mode=excluded.interaction_mode, updated_at=excluded.updated_at;
        """)
        try st.bind(1, message.id.value.uuidString)
        try st.bind(2, message.threadId.value.uuidString)
        try st.bind(3, message.text)
        try st.bind(4, attachmentsJSON(message.attachments))
        try st.bind(5, message.interactionMode.rawValue)
        try st.bind(6, Int64(message.position))
        try st.bind(7, iso.string(from: message.createdAt))
        try st.bind(8, iso.string(from: message.updatedAt))
        _ = try st.step()
    }

    public func list(threadId: AgentThreadID) throws -> [AgentQueuedMessage] {
        let st = try db.prepare("""
            SELECT id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at
            FROM agent_queued_messages
            WHERE thread_id = ?
            ORDER BY position ASC, created_at ASC;
        """)
        try st.bind(1, threadId.value.uuidString)
        var out: [AgentQueuedMessage] = []
        while try st.step() {
            out.append(decodeRow(st))
        }
        return out
    }

    public func first(threadId: AgentThreadID) throws -> AgentQueuedMessage? {
        let st = try db.prepare("""
            SELECT id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at
            FROM agent_queued_messages
            WHERE thread_id = ?
            ORDER BY position ASC, created_at ASC
            LIMIT 1;
        """)
        try st.bind(1, threadId.value.uuidString)
        return try st.step() ? decodeRow(st) : nil
    }

    public func get(id: AgentQueuedMessageID) throws -> AgentQueuedMessage? {
        let st = try db.prepare("""
            SELECT id, thread_id, text, attachments_json, interaction_mode, position, created_at, updated_at
            FROM agent_queued_messages
            WHERE id = ?;
        """)
        try st.bind(1, id.value.uuidString)
        return try st.step() ? decodeRow(st) : nil
    }

    public func update(id: AgentQueuedMessageID, text: String, attachments: [AgentAttachment]) throws -> AgentQueuedMessage? {
        guard var queued = try get(id: id) else { return nil }
        queued.text = text
        queued.attachments = attachments
        queued.updatedAt = Date()
        try upsert(queued)
        return queued
    }

    public func delete(id: AgentQueuedMessageID) throws -> AgentQueuedMessage? {
        guard let queued = try get(id: id) else { return nil }
        let st = try db.prepare("DELETE FROM agent_queued_messages WHERE id = ?;")
        try st.bind(1, id.value.uuidString)
        _ = try st.step()
        try normalizePositions(threadId: queued.threadId)
        return queued
    }

    public func promoteToFront(id: AgentQueuedMessageID) throws -> AgentQueuedMessage? {
        guard let target = try get(id: id) else { return nil }
        let ordered = [target] + (try list(threadId: target.threadId)).filter { $0.id != id }
        let now = Date()
        try db.transaction {
            for (index, message) in ordered.enumerated() {
                let st = try db.prepare("UPDATE agent_queued_messages SET position = ?, updated_at = ? WHERE id = ?;")
                try st.bind(1, Int64(index + 1))
                try st.bind(2, iso.string(from: now))
                try st.bind(3, message.id.value.uuidString)
                _ = try st.step()
            }
        }
        return try get(id: id)
    }

    private func nextPosition(threadId: AgentThreadID) throws -> Int {
        let st = try db.prepare("SELECT COALESCE(MAX(position), 0) + 1 FROM agent_queued_messages WHERE thread_id = ?;")
        try st.bind(1, threadId.value.uuidString)
        return (try st.step()) ? Int(st.columnInt64(0)) : 1
    }

    private func normalizePositions(threadId: AgentThreadID) throws {
        let queued = try list(threadId: threadId)
        let now = Date()
        try db.transaction {
            for (index, message) in queued.enumerated() where message.position != index + 1 {
                let st = try db.prepare("UPDATE agent_queued_messages SET position = ?, updated_at = ? WHERE id = ?;")
                try st.bind(1, Int64(index + 1))
                try st.bind(2, iso.string(from: now))
                try st.bind(3, message.id.value.uuidString)
                _ = try st.step()
            }
        }
    }

    private func attachmentsJSON(_ attachments: [AgentAttachment]) -> String {
        guard let data = try? encoder.encode(attachments),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private func decodeAttachments(_ json: String?) -> [AgentAttachment] {
        guard let json,
              let data = json.data(using: .utf8),
              let attachments = try? decoder.decode([AgentAttachment].self, from: data) else { return [] }
        return attachments
    }

    private func decodeRow(_ st: SQLiteStatement) -> AgentQueuedMessage {
        AgentQueuedMessage(
            id: AgentQueuedMessageID(UUID(uuidString: st.columnText(0) ?? "") ?? UUID()),
            threadId: AgentThreadID(UUID(uuidString: st.columnText(1) ?? "") ?? UUID()),
            text: st.columnText(2) ?? "",
            attachments: decodeAttachments(st.columnText(3)),
            interactionMode: AgentInteractionMode(rawValue: st.columnText(4) ?? "") ?? .default,
            position: Int(st.columnInt64(5)),
            createdAt: parseDate(st.columnText(6)),
            updatedAt: parseDate(st.columnText(7))
        )
    }
}

public final class AgentRunRepository {
    let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }

    public func upsert(_ r: AgentRun) throws {
        let st = try db.prepare("""
            INSERT INTO agent_runs(id, thread_id, provider, provider_instance_id, model, status, started_at, finished_at, error_message)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET status=excluded.status, finished_at=excluded.finished_at, error_message=excluded.error_message;
        """)
        try st.bind(1, r.id.value.uuidString)
        try st.bind(2, r.threadId.value.uuidString)
        try st.bind(3, r.provider.rawValue)
        try st.bind(4, r.providerInstanceId ?? r.provider.rawValue)
        try st.bind(5, r.model)
        try st.bind(6, r.status.rawValue)
        try st.bind(7, iso.string(from: r.startedAt))
        try st.bind(8, r.finishedAt.map { iso.string(from: $0) })
        try st.bind(9, r.errorMessage)
        _ = try st.step()
    }

    public func get(id: AgentRunID) throws -> AgentRun? {
        let st = try db.prepare("""
            SELECT id, thread_id, provider, provider_instance_id, model, status, started_at, finished_at, error_message
            FROM agent_runs
            WHERE id = ?;
        """)
        try st.bind(1, id.value.uuidString)
        guard try st.step() else { return nil }
        return AgentRun(
            id: AgentRunID(UUID(uuidString: st.columnText(0) ?? "") ?? id.value),
            threadId: AgentThreadID(UUID(uuidString: st.columnText(1) ?? "") ?? UUID()),
            provider: AgentProvider(rawValue: st.columnText(2) ?? "") ?? .codex,
            providerInstanceId: st.columnText(3) ?? (AgentProvider(rawValue: st.columnText(2) ?? "") ?? .codex).rawValue,
            model: st.columnText(4) ?? "",
            status: AgentRunStatus(rawValue: st.columnText(5) ?? "") ?? .pending,
            startedAt: parseDate(st.columnText(6)),
            finishedAt: st.columnText(7).map(parseDate),
            errorMessage: st.columnText(8)
        )
    }

    public func reconcileRunningOnLaunch() throws -> Int {
        let countBefore = try countRunning()
        let st = try db.prepare("UPDATE agent_runs SET status='interrupted', finished_at=? WHERE status='running';")
        try st.bind(1, iso.string(from: Date()))
        _ = try st.step()
        return countBefore
    }

    public func markStopped(id: AgentRunID, status: AgentRunStatus = .cancelled, at date: Date = Date()) throws {
        let st = try db.prepare("UPDATE agent_runs SET status=?, finished_at=? WHERE id=? AND status IN ('pending', 'running');")
        try st.bind(1, status.rawValue)
        try st.bind(2, iso.string(from: date))
        try st.bind(3, id.value.uuidString)
        _ = try st.step()
    }

    private func countRunning() throws -> Int {
        let st = try db.prepare("SELECT COUNT(*) FROM agent_runs WHERE status='running';")
        if try st.step() { return Int(st.columnInt64(0)) }
        return 0
    }

    public func appendStreamEvent(runId: AgentRunID, seq: Int, kind: String, payloadJSON: String) throws {
        let st = try db.prepare("INSERT INTO agent_stream_events(run_id, seq, event_kind, payload_json, created_at) VALUES(?, ?, ?, ?, ?);")
        try st.bind(1, runId.value.uuidString)
        try st.bind(2, Int64(seq))
        try st.bind(3, kind)
        try st.bind(4, payloadJSON)
        try st.bind(5, iso.string(from: Date()))
        _ = try st.step()
    }

    public func appendProviderEventLog(threadId: AgentThreadID, runId: AgentRunID?, event: ProviderRuntimeEvent) throws {
        let st = try db.prepare("""
            INSERT INTO agent_provider_event_logs(
                thread_id, run_id, event_id, provider, source, method,
                provider_turn_id, provider_item_id, provider_request_id,
                payload_json, received_at_ms, created_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, runId?.value.uuidString)
        try st.bind(3, event.id)
        try st.bind(4, event.provider.rawValue)
        try st.bind(5, event.source)
        try st.bind(6, event.method)
        try st.bind(7, event.providerTurnId)
        try st.bind(8, event.providerItemId)
        try st.bind(9, event.providerRequestId)
        try st.bind(10, event.payloadJSON)
        try st.bind(11, Int64(event.receivedAtMs))
        try st.bind(12, iso.string(from: Date()))
        _ = try st.step()
    }

    public func countProviderEventLogs(threadId: AgentThreadID) throws -> Int {
        let st = try db.prepare("SELECT COUNT(*) FROM agent_provider_event_logs WHERE thread_id = ?;")
        try st.bind(1, threadId.value.uuidString)
        if try st.step() { return Int(st.columnInt64(0)) }
        return 0
    }

    public func listLatestProviderEventLogs(threadId: AgentThreadID, limit: Int = 500) throws -> [ProviderRuntimeEvent] {
        let st = try db.prepare("""
            SELECT event_id, provider, source, method, provider_turn_id, provider_item_id,
                   provider_request_id, payload_json, received_at_ms
            FROM (
                SELECT id, event_id, provider, source, method, provider_turn_id, provider_item_id,
                       provider_request_id, payload_json, received_at_ms
                FROM agent_provider_event_logs
                WHERE thread_id = ?
                ORDER BY id DESC
                LIMIT ?
            )
            ORDER BY id ASC;
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, Int64(limit))
        var events: [ProviderRuntimeEvent] = []
        while try st.step() {
            guard let id = st.columnText(0) else {
                throw PersistenceDataError.corruptProviderEventLog("missing event id")
            }
            guard let providerRaw = st.columnText(1),
                  let provider = AgentProvider(rawValue: providerRaw) else {
                throw PersistenceDataError.corruptProviderEventLog("invalid provider for event \(id)")
            }
            guard let source = st.columnText(2), !source.isEmpty else {
                throw PersistenceDataError.corruptProviderEventLog("missing source for event \(id)")
            }
            guard let method = st.columnText(3), !method.isEmpty else {
                throw PersistenceDataError.corruptProviderEventLog("missing method for event \(id)")
            }
            guard let payload = st.columnText(7) else {
                throw PersistenceDataError.corruptProviderEventLog("missing payload for event \(id)")
            }
            events.append(ProviderRuntimeEvent(
                id: id,
                provider: provider,
                source: source,
                method: method,
                providerTurnId: st.columnText(4),
                providerItemId: st.columnText(5),
                providerRequestId: st.columnText(6),
                payloadJSON: payload,
                receivedAtMs: Int64(st.columnInt64(8))
            ))
        }
        return events
    }

    public func pruneProviderEventLogs(threadId: AgentThreadID, keepLatest limit: Int = 10_000) throws {
        guard limit > 0 else { return }
        let st = try db.prepare("""
            DELETE FROM agent_provider_event_logs
            WHERE id IN (
                SELECT id FROM (
                    SELECT id
                    FROM agent_provider_event_logs
                    WHERE thread_id = ?
                    ORDER BY id DESC
                    LIMIT -1 OFFSET ?
                )
            );
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, Int64(limit))
        _ = try st.step()
    }

    public func pruneStreamEvents(threadId: AgentThreadID, keepLatest limit: Int = 5_000) throws {
        guard limit > 0 else { return }
        let st = try db.prepare("""
            DELETE FROM agent_stream_events
            WHERE id IN (
                SELECT id FROM (
                    SELECT e.id
                    FROM agent_stream_events e
                    JOIN agent_runs r ON r.id = e.run_id
                    WHERE r.thread_id = ?
                    ORDER BY r.started_at DESC, e.seq DESC, e.id DESC
                    LIMIT -1 OFFSET ?
                )
            );
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, Int64(limit))
        _ = try st.step()
    }

    public func countStreamEvents(threadId: AgentThreadID) throws -> Int {
        let st = try db.prepare("""
            SELECT COUNT(*)
            FROM agent_stream_events e
            JOIN agent_runs r ON r.id = e.run_id
            WHERE r.thread_id = ?;
        """)
        try st.bind(1, threadId.value.uuidString)
        if try st.step() { return Int(st.columnInt64(0)) }
        return 0
    }

    public func listLatestStreamEvents(threadId: AgentThreadID, limit: Int = 500) throws -> [AssistantEvent] {
        let st = try db.prepare("""
            SELECT payload_json
            FROM (
                SELECT e.payload_json, r.started_at, e.seq, e.id
                FROM agent_stream_events e
                JOIN agent_runs r ON r.id = e.run_id
                WHERE r.thread_id = ?
                ORDER BY r.started_at DESC, e.seq DESC, e.id DESC
                LIMIT ?
            )
            ORDER BY started_at ASC, seq ASC, id ASC;
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, Int64(limit))
        var events: [AssistantEvent] = []
        let decoder = JSONDecoder()
        while try st.step() {
            guard let json = st.columnText(0),
                  let data = json.data(using: .utf8),
                  let event = try? decoder.decode(AssistantEvent.self, from: data) else { continue }
            events.append(event)
        }
        return events
    }
}

public struct AgentProposedPlanRecord: Equatable, Sendable {
    public var threadId: AgentThreadID
    public var plan: AssistantProposedPlan
    public var implementationThreadId: AgentThreadID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(threadId: AgentThreadID, plan: AssistantProposedPlan, implementationThreadId: AgentThreadID? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.threadId = threadId
        self.plan = plan
        self.implementationThreadId = implementationThreadId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public final class AgentProposedPlanRepository {
    let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }

    public func upsert(threadId: AgentThreadID, plan: AssistantProposedPlan) throws {
        let now = iso.string(from: Date())
        let st = try db.prepare("""
            INSERT INTO agent_proposed_plans(thread_id, plan_id, turn_id, markdown, implemented_at, implementation_thread_id, created_at, updated_at)
            VALUES(?, ?, ?, ?, ?, NULL, ?, ?)
            ON CONFLICT(thread_id, plan_id) DO UPDATE SET
                turn_id=excluded.turn_id,
                markdown=excluded.markdown,
                implemented_at=excluded.implemented_at,
                updated_at=excluded.updated_at;
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, plan.id)
        try st.bind(3, plan.turnId)
        try st.bind(4, plan.markdown)
        try st.bind(5, plan.implementedAtMs.map { iso.string(from: Date(timeIntervalSince1970: Double($0) / 1000.0)) })
        try st.bind(6, now)
        try st.bind(7, now)
        _ = try st.step()
    }

    public func markImplemented(threadId: AgentThreadID, planId: String, implementationThreadId: AgentThreadID, at date: Date = Date()) throws {
        let st = try db.prepare("""
            UPDATE agent_proposed_plans
            SET implemented_at = ?, implementation_thread_id = ?, updated_at = ?
            WHERE thread_id = ? AND plan_id = ?;
        """)
        let now = iso.string(from: date)
        try st.bind(1, now)
        try st.bind(2, implementationThreadId.value.uuidString)
        try st.bind(3, now)
        try st.bind(4, threadId.value.uuidString)
        try st.bind(5, planId)
        _ = try st.step()
    }

    public func list(threadId: AgentThreadID) throws -> [AgentProposedPlanRecord] {
        let st = try db.prepare("""
            SELECT thread_id, plan_id, turn_id, markdown, implemented_at, implementation_thread_id, created_at, updated_at
            FROM agent_proposed_plans
            WHERE thread_id = ?
            ORDER BY created_at ASC, plan_id ASC;
        """)
        try st.bind(1, threadId.value.uuidString)
        var out: [AgentProposedPlanRecord] = []
        while try st.step() {
            let storedThreadId = AgentThreadID(UUID(uuidString: st.columnText(0) ?? "") ?? threadId.value)
            let implementedAt = st.columnText(4).map(parseDate)
            let implementationThreadId = st.columnText(5).flatMap(UUID.init(uuidString:)).map(AgentThreadID.init)
            out.append(AgentProposedPlanRecord(
                threadId: storedThreadId,
                plan: AssistantProposedPlan(
                    id: st.columnText(1) ?? "",
                    turnId: st.columnText(2),
                    markdown: st.columnText(3) ?? "",
                    implementedAtMs: implementedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
                ),
                implementationThreadId: implementationThreadId,
                createdAt: parseDate(st.columnText(6)),
                updatedAt: parseDate(st.columnText(7))
            ))
        }
        return out
    }
}

public final class AgentTurnCheckpointRepository {
    let db: SQLiteDB
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(db: SQLiteDB) { self.db = db }

    public func upsert(_ checkpoint: AgentTurnCheckpointSummary) throws {
        let filesData = try encoder.encode(checkpoint.files)
        let filesJSON = String(data: filesData, encoding: .utf8) ?? "[]"
        let snapshotsData = try encoder.encode(checkpoint.fileSnapshots)
        let snapshotsJSON = String(data: snapshotsData, encoding: .utf8) ?? "[]"
        let fileDiffsData = try encoder.encode(checkpoint.fileDiffs)
        let fileDiffsJSON = String(data: fileDiffsData, encoding: .utf8) ?? "[]"
        let now = iso.string(from: Date())
        let st = try db.prepare("""
            INSERT INTO agent_turn_checkpoints(thread_id, run_id, turn_id, checkpoint_turn_count, checkpoint_ref, status, files_json, assistant_message_id, error_message, completed_at, created_at, file_snapshots_json, diff_patch, file_diffs_json)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(thread_id, turn_id) DO UPDATE SET
                run_id=excluded.run_id,
                checkpoint_turn_count=excluded.checkpoint_turn_count,
                checkpoint_ref=excluded.checkpoint_ref,
                status=excluded.status,
                files_json=excluded.files_json,
                file_snapshots_json=excluded.file_snapshots_json,
                diff_patch=excluded.diff_patch,
                file_diffs_json=excluded.file_diffs_json,
                assistant_message_id=excluded.assistant_message_id,
                error_message=excluded.error_message,
                completed_at=excluded.completed_at;
        """)
        try st.bind(1, checkpoint.threadId.value.uuidString)
        try st.bind(2, checkpoint.runId.value.uuidString)
        try st.bind(3, checkpoint.turnId)
        try st.bind(4, Int64(checkpoint.checkpointTurnCount))
        try st.bind(5, checkpoint.checkpointRef)
        try st.bind(6, checkpoint.status.rawValue)
        try st.bind(7, filesJSON)
        try st.bind(8, checkpoint.assistantMessageId?.value.uuidString)
        try st.bind(9, checkpoint.errorMessage)
        try st.bind(10, iso.string(from: checkpoint.completedAt))
        try st.bind(11, now)
        try st.bind(12, snapshotsJSON)
        try st.bind(13, checkpoint.diffPatch)
        try st.bind(14, fileDiffsJSON)
        _ = try st.step()
    }

    public func nextTurnCount(threadId: AgentThreadID) throws -> Int {
        let st = try db.prepare("""
            SELECT COALESCE(MAX(checkpoint_turn_count), 0) + 1
            FROM agent_turn_checkpoints
            WHERE thread_id = ?;
        """)
        try st.bind(1, threadId.value.uuidString)
        guard try st.step() else { return 1 }
        return Int(st.columnInt64(0))
    }

    public func list(threadId: AgentThreadID) throws -> [AgentTurnCheckpointSummary] {
        let st = try db.prepare("""
            SELECT thread_id, run_id, turn_id, checkpoint_turn_count, checkpoint_ref, status, files_json, assistant_message_id, error_message, completed_at, file_snapshots_json, diff_patch, file_diffs_json
            FROM agent_turn_checkpoints
            WHERE thread_id = ?
            ORDER BY checkpoint_turn_count ASC, completed_at ASC;
        """)
        try st.bind(1, threadId.value.uuidString)
        var out: [AgentTurnCheckpointSummary] = []
        while try st.step() {
            out.append(try decodeCheckpoint(from: st, fallbackThreadId: threadId))
        }
        return out
    }

    public func get(threadId: AgentThreadID, checkpointTurnCount: Int) throws -> AgentTurnCheckpointSummary? {
        let st = try db.prepare("""
            SELECT thread_id, run_id, turn_id, checkpoint_turn_count, checkpoint_ref, status, files_json, assistant_message_id, error_message, completed_at, file_snapshots_json, diff_patch, file_diffs_json
            FROM agent_turn_checkpoints
            WHERE thread_id = ? AND checkpoint_turn_count = ?
            ORDER BY completed_at DESC
            LIMIT 1;
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, Int64(checkpointTurnCount))
        guard try st.step() else { return nil }
        return try decodeCheckpoint(from: st, fallbackThreadId: threadId)
    }

    public func listAfter(threadId: AgentThreadID, checkpointTurnCount: Int) throws -> [AgentTurnCheckpointSummary] {
        let st = try db.prepare("""
            SELECT thread_id, run_id, turn_id, checkpoint_turn_count, checkpoint_ref, status, files_json, assistant_message_id, error_message, completed_at, file_snapshots_json, diff_patch, file_diffs_json
            FROM agent_turn_checkpoints
            WHERE thread_id = ? AND checkpoint_turn_count > ?
            ORDER BY checkpoint_turn_count ASC, completed_at ASC;
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, Int64(checkpointTurnCount))
        var out: [AgentTurnCheckpointSummary] = []
        while try st.step() {
            out.append(try decodeCheckpoint(from: st, fallbackThreadId: threadId))
        }
        return out
    }

    public func deleteAfter(threadId: AgentThreadID, checkpointTurnCount: Int) throws {
        let st = try db.prepare("""
            DELETE FROM agent_turn_checkpoints
            WHERE thread_id = ? AND checkpoint_turn_count > ?;
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, Int64(checkpointTurnCount))
        _ = try st.step()
    }

    private func decodeCheckpoint(from st: SQLiteStatement, fallbackThreadId: AgentThreadID) throws -> AgentTurnCheckpointSummary {
        let filesJSON = st.columnText(6) ?? "[]"
        let files: [AgentTurnCheckpointFile]
        do {
            files = try decoder.decode([AgentTurnCheckpointFile].self, from: Data(filesJSON.utf8))
        } catch {
            throw PersistenceDataError.corruptCheckpoint("invalid files_json for turn \(st.columnText(2) ?? "<unknown>"): \(error)")
        }
        let snapshotsJSON = st.columnText(10) ?? "[]"
        let snapshots: [AgentTurnCheckpointFileSnapshot]
        do {
            snapshots = try decoder.decode([AgentTurnCheckpointFileSnapshot].self, from: Data(snapshotsJSON.utf8))
        } catch {
            throw PersistenceDataError.corruptCheckpoint("invalid file_snapshots_json for turn \(st.columnText(2) ?? "<unknown>"): \(error)")
        }
        let fileDiffsJSON = st.columnText(12) ?? "[]"
        let fileDiffs: [AgentTurnCheckpointFileDiff]
        do {
            fileDiffs = try decoder.decode([AgentTurnCheckpointFileDiff].self, from: Data(fileDiffsJSON.utf8))
        } catch {
            throw PersistenceDataError.corruptCheckpoint("invalid file_diffs_json for turn \(st.columnText(2) ?? "<unknown>"): \(error)")
        }
        return AgentTurnCheckpointSummary(
            threadId: AgentThreadID(UUID(uuidString: st.columnText(0) ?? "") ?? fallbackThreadId.value),
            runId: AgentRunID(UUID(uuidString: st.columnText(1) ?? "") ?? UUID()),
            turnId: st.columnText(2) ?? "",
            checkpointTurnCount: Int(st.columnInt64(3)),
            checkpointRef: st.columnText(4) ?? "",
            status: AgentTurnCheckpointStatus(rawValue: st.columnText(5) ?? "") ?? .error,
            files: files,
            fileSnapshots: snapshots,
            diffPatch: st.columnText(11),
            fileDiffs: fileDiffs,
            assistantMessageId: st.columnText(7).flatMap(UUID.init(uuidString:)).map(AgentMessageID.init),
            errorMessage: st.columnText(8),
            completedAt: parseDate(st.columnText(9))
        )
    }
}

public final class ProviderSessionRuntimeRepository {
    let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }

    public func upsert(_ session: ProviderSessionRuntime) throws {
        let st = try db.prepare("""
            INSERT INTO provider_session_runtime(thread_id, provider, provider_instance_id, adapter_key, binary_identity, status, resume_cursor, runtime_payload_json, updated_at, cwd, model, service_tier, runtime_mode, last_event_kind, last_error_message)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(thread_id) DO UPDATE SET
                provider=excluded.provider,
                provider_instance_id=excluded.provider_instance_id,
                adapter_key=excluded.adapter_key,
                binary_identity=excluded.binary_identity,
                status=excluded.status,
                resume_cursor=excluded.resume_cursor,
                runtime_payload_json=excluded.runtime_payload_json,
                updated_at=excluded.updated_at,
                cwd=excluded.cwd,
                model=excluded.model,
                service_tier=excluded.service_tier,
                runtime_mode=excluded.runtime_mode,
                last_event_kind=excluded.last_event_kind,
                last_error_message=excluded.last_error_message;
        """)
        try st.bind(1, session.threadId.value.uuidString)
        try st.bind(2, session.provider.rawValue)
        try st.bind(3, session.providerInstanceId)
        try st.bind(4, session.adapterKey)
        try st.bind(5, session.binaryIdentity)
        try st.bind(6, session.status.rawValue)
        try st.bind(7, session.resumeCursor)
        try st.bind(8, session.runtimePayloadJSON)
        try st.bind(9, iso.string(from: session.updatedAt))
        try st.bind(10, session.cwd)
        try st.bind(11, session.model)
        try st.bind(12, session.serviceTier.rawValue)
        try st.bind(13, session.runtimeMode.rawValue)
        try st.bind(14, session.lastEventKind)
        try st.bind(15, session.lastErrorMessage)
        _ = try st.step()
    }

    public func get(threadId: AgentThreadID) throws -> ProviderSessionRuntime? {
        let st = try db.prepare("""
            SELECT thread_id, provider, provider_instance_id, adapter_key, binary_identity, status, resume_cursor, runtime_payload_json, updated_at, cwd, model, service_tier, runtime_mode, last_event_kind, last_error_message
            FROM provider_session_runtime
            WHERE thread_id = ?;
        """)
        try st.bind(1, threadId.value.uuidString)
        guard try st.step() else { return nil }
        return ProviderSessionRuntime(
            threadId: AgentThreadID(UUID(uuidString: st.columnText(0) ?? "") ?? threadId.value),
            provider: AgentProvider(rawValue: st.columnText(1) ?? "") ?? .codex,
            providerInstanceId: st.columnText(2),
            adapterKey: st.columnText(3),
            binaryIdentity: st.columnText(4),
            status: AgentRunStatus(rawValue: st.columnText(5) ?? "") ?? .pending,
            resumeCursor: st.columnText(6),
            cwd: st.columnText(9),
            model: st.columnText(10),
            serviceTier: AgentServiceTier(rawValue: st.columnText(11) ?? "") ?? .auto,
            runtimeMode: AgentPermissionMode(rawValue: st.columnText(12) ?? "") ?? .supervised,
            lastEventKind: st.columnText(13),
            lastErrorMessage: st.columnText(14),
            runtimePayloadJSON: st.columnText(7),
            updatedAt: parseDate(st.columnText(8))
        )
    }

    public func list(status: AgentRunStatus, updatedBefore cutoff: Date) throws -> [ProviderSessionRuntime] {
        let st = try db.prepare("""
            SELECT thread_id, provider, provider_instance_id, adapter_key, binary_identity, status, resume_cursor, runtime_payload_json, updated_at, cwd, model, service_tier, runtime_mode, last_event_kind, last_error_message
            FROM provider_session_runtime
            WHERE status = ? AND updated_at < ?
            ORDER BY updated_at ASC;
        """)
        try st.bind(1, status.rawValue)
        try st.bind(2, iso.string(from: cutoff))
        var sessions: [ProviderSessionRuntime] = []
        while try st.step() {
            sessions.append(ProviderSessionRuntime(
                threadId: AgentThreadID(UUID(uuidString: st.columnText(0) ?? "") ?? UUID()),
                provider: AgentProvider(rawValue: st.columnText(1) ?? "") ?? .codex,
                providerInstanceId: st.columnText(2),
                adapterKey: st.columnText(3),
                binaryIdentity: st.columnText(4),
                status: AgentRunStatus(rawValue: st.columnText(5) ?? "") ?? .pending,
                resumeCursor: st.columnText(6),
                cwd: st.columnText(9),
                model: st.columnText(10),
                serviceTier: AgentServiceTier(rawValue: st.columnText(11) ?? "") ?? .auto,
                runtimeMode: AgentPermissionMode(rawValue: st.columnText(12) ?? "") ?? .supervised,
                lastEventKind: st.columnText(13),
                lastErrorMessage: st.columnText(14),
                runtimePayloadJSON: st.columnText(7),
                updatedAt: parseDate(st.columnText(8))
            ))
        }
        return sessions
    }

    public func markStopped(threadId: AgentThreadID, at date: Date = Date()) throws {
        guard var session = try get(threadId: threadId) else { return }
        session.status = .interrupted
        session.updatedAt = date
        try upsert(session)
    }

    public func updateDiagnostics(threadId: AgentThreadID, lastEventKind: String?, lastErrorMessage: String?, at date: Date = Date()) throws {
        guard var session = try get(threadId: threadId) else { return }
        session.lastEventKind = lastEventKind ?? session.lastEventKind
        session.lastErrorMessage = lastErrorMessage ?? session.lastErrorMessage
        session.updatedAt = date
        try upsert(session)
    }
}

public final class CommandReceiptRepository {
    let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }

    public func get(method: String, clientRequestId: String) throws -> String? {
        let st = try db.prepare("""
            SELECT result_json
            FROM command_receipts
            WHERE method = ? AND client_request_id = ?;
        """)
        try st.bind(1, method)
        try st.bind(2, clientRequestId)
        guard try st.step() else { return nil }
        return st.columnText(0)
    }

    public func record(method: String, clientRequestId: String, resultJSON: String) throws {
        let st = try db.prepare("""
            INSERT OR IGNORE INTO command_receipts(method, client_request_id, result_json, created_at)
            VALUES(?, ?, ?, ?);
        """)
        try st.bind(1, method)
        try st.bind(2, clientRequestId)
        try st.bind(3, resultJSON)
        try st.bind(4, iso.string(from: Date()))
        _ = try st.step()
    }
}

public enum ProviderPendingCallbackKind: String, Codable, Sendable, Equatable {
    case approval
    case userInput
}

public struct ProviderPendingCallback: Codable, Sendable, Equatable {
    public let threadId: AgentThreadID
    public let requestId: String
    public let kind: ProviderPendingCallbackKind
    public var state: AssistantRequestState
    public var payloadJSON: String
    public var createdAt: Date
    public var resolvedAt: Date?
    public var staleReason: String?

    public init(
        threadId: AgentThreadID,
        requestId: String,
        kind: ProviderPendingCallbackKind,
        state: AssistantRequestState = .pending,
        payloadJSON: String,
        createdAt: Date = Date(),
        resolvedAt: Date? = nil,
        staleReason: String? = nil
    ) {
        self.threadId = threadId
        self.requestId = requestId
        self.kind = kind
        self.state = state
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.staleReason = staleReason
    }
}

public final class ProviderPendingCallbackRepository {
    let db: SQLiteDB
    private let encoder = JSONEncoder()
    public init(db: SQLiteDB) { self.db = db }

    public func record(threadId: AgentThreadID, request: AssistantPendingRequest) throws {
        let data = try encoder.encode(request)
        try upsert(ProviderPendingCallback(
            threadId: threadId,
            requestId: request.id,
            kind: .approval,
            state: request.state,
            payloadJSON: String(decoding: data, as: UTF8.self),
            createdAt: Date(timeIntervalSince1970: Double(request.createdAtMs) / 1000.0)
        ))
    }

    public func record(threadId: AgentThreadID, userInput: AssistantUserInputRequest) throws {
        let data = try encoder.encode(userInput)
        try upsert(ProviderPendingCallback(
            threadId: threadId,
            requestId: userInput.id,
            kind: .userInput,
            state: userInput.state,
            payloadJSON: String(decoding: data, as: UTF8.self),
            createdAt: Date(timeIntervalSince1970: Double(userInput.createdAtMs) / 1000.0)
        ))
    }

    public func resolve(threadId: AgentThreadID, requestId: String, kind: ProviderPendingCallbackKind, state: AssistantRequestState, at date: Date = Date()) throws {
        let st = try db.prepare("""
            UPDATE provider_pending_callbacks
            SET state = ?, resolved_at = ?, stale_reason = NULL
            WHERE thread_id = ? AND request_id = ? AND callback_kind = ?;
        """)
        try st.bind(1, state.rawValue)
        try st.bind(2, iso.string(from: date))
        try st.bind(3, threadId.value.uuidString)
        try st.bind(4, requestId)
        try st.bind(5, kind.rawValue)
        _ = try st.step()
    }

    public func markStale(threadId: AgentThreadID, requestId: String, kind: ProviderPendingCallbackKind, reason: String, at date: Date = Date()) throws {
        let st = try db.prepare("""
            UPDATE provider_pending_callbacks
            SET state = ?, resolved_at = ?, stale_reason = ?
            WHERE thread_id = ? AND request_id = ? AND callback_kind = ?;
        """)
        try st.bind(1, AssistantRequestState.stale.rawValue)
        try st.bind(2, iso.string(from: date))
        try st.bind(3, reason)
        try st.bind(4, threadId.value.uuidString)
        try st.bind(5, requestId)
        try st.bind(6, kind.rawValue)
        _ = try st.step()
    }

    public func markOpenStale(reason: String, at date: Date = Date()) throws -> Int {
        let open = try listOpen()
        let st = try db.prepare("""
            UPDATE provider_pending_callbacks
            SET state = ?, resolved_at = ?, stale_reason = ?
            WHERE state = ?;
        """)
        try st.bind(1, AssistantRequestState.stale.rawValue)
        try st.bind(2, iso.string(from: date))
        try st.bind(3, reason)
        try st.bind(4, AssistantRequestState.pending.rawValue)
        _ = try st.step()
        return open.count
    }

    public func get(threadId: AgentThreadID, requestId: String, kind: ProviderPendingCallbackKind) throws -> ProviderPendingCallback? {
        let st = try db.prepare("""
            SELECT thread_id, request_id, callback_kind, state, payload_json, created_at, resolved_at, stale_reason
            FROM provider_pending_callbacks
            WHERE thread_id = ? AND request_id = ? AND callback_kind = ?;
        """)
        try st.bind(1, threadId.value.uuidString)
        try st.bind(2, requestId)
        try st.bind(3, kind.rawValue)
        guard try st.step() else { return nil }
        return row(st)
    }

    public func listOpen(threadId: AgentThreadID? = nil) throws -> [ProviderPendingCallback] {
        try list(states: [.pending], threadId: threadId)
    }

    public func listVisible(threadId: AgentThreadID) throws -> [ProviderPendingCallback] {
        try list(states: [.pending, .stale], threadId: threadId)
    }

    public func list(states: [AssistantRequestState], threadId: AgentThreadID? = nil) throws -> [ProviderPendingCallback] {
        let sql: String
        if threadId == nil {
            sql = """
                SELECT thread_id, request_id, callback_kind, state, payload_json, created_at, resolved_at, stale_reason
                FROM provider_pending_callbacks
                WHERE state IN (\(states.map { _ in "?" }.joined(separator: ",")))
                ORDER BY created_at ASC;
            """
        } else {
            sql = """
                SELECT thread_id, request_id, callback_kind, state, payload_json, created_at, resolved_at, stale_reason
                FROM provider_pending_callbacks
                WHERE state IN (\(states.map { _ in "?" }.joined(separator: ","))) AND thread_id = ?
                ORDER BY created_at ASC;
            """
        }
        let st = try db.prepare(sql)
        for (offset, state) in states.enumerated() {
            try st.bind(Int32(offset + 1), state.rawValue)
        }
        if let threadId { try st.bind(Int32(states.count + 1), threadId.value.uuidString) }
        var out: [ProviderPendingCallback] = []
        while try st.step() { out.append(row(st)) }
        return out
    }

    private func upsert(_ callback: ProviderPendingCallback) throws {
        let st = try db.prepare("""
            INSERT INTO provider_pending_callbacks(thread_id, request_id, callback_kind, state, payload_json, created_at, resolved_at, stale_reason)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(thread_id, request_id, callback_kind) DO UPDATE SET
                state=excluded.state,
                payload_json=excluded.payload_json,
                created_at=excluded.created_at,
                resolved_at=excluded.resolved_at,
                stale_reason=excluded.stale_reason;
        """)
        try st.bind(1, callback.threadId.value.uuidString)
        try st.bind(2, callback.requestId)
        try st.bind(3, callback.kind.rawValue)
        try st.bind(4, callback.state.rawValue)
        try st.bind(5, callback.payloadJSON)
        try st.bind(6, iso.string(from: callback.createdAt))
        try st.bind(7, callback.resolvedAt.map(iso.string))
        try st.bind(8, callback.staleReason)
        _ = try st.step()
    }

    private func row(_ st: SQLiteStatement) -> ProviderPendingCallback {
        ProviderPendingCallback(
            threadId: AgentThreadID(UUID(uuidString: st.columnText(0) ?? "") ?? UUID()),
            requestId: st.columnText(1) ?? "",
            kind: ProviderPendingCallbackKind(rawValue: st.columnText(2) ?? "") ?? .approval,
            state: AssistantRequestState(rawValue: st.columnText(3) ?? "") ?? .pending,
            payloadJSON: st.columnText(4) ?? "{}",
            createdAt: parseDate(st.columnText(5)),
            resolvedAt: st.columnText(6).flatMap(parseDate),
            staleReason: st.columnText(7)
        )
    }
}

public enum ProviderSessionRecoveryState: Equatable {
    case active(ProviderSessionRuntime)
    case recoverable(ProviderSessionRuntime)
    case stopped(ProviderSessionRuntime)
    case unrecoverable(String)
}

public extension ProviderSessionRuntimeRepository {
    func recoveryState(threadId: AgentThreadID) throws -> ProviderSessionRecoveryState {
        guard let session = try get(threadId: threadId) else {
            return .unrecoverable("No provider session runtime row for thread.")
        }
        switch session.status {
        case .running:
            return .active(session)
        case .completed:
            if session.resumeCursor?.isEmpty == false {
                return .recoverable(session)
            }
            return .unrecoverable("Provider session has no resume cursor.")
        case .cancelled, .interrupted:
            return .stopped(session)
        case .failed:
            return .unrecoverable("Provider session failed.")
        case .pending:
            return .unrecoverable("Provider session has not started.")
        }
    }
}

public struct TerminalOutputChunk: Equatable {
    public let id: Int64
    public let surfaceID: String
    public let workspaceID: String?
    public let chunkIndex: Int64
    public let data: Data
    public let createdAt: Date

    public init(id: Int64, surfaceID: String, workspaceID: String?, chunkIndex: Int64, data: Data, createdAt: Date) {
        self.id = id
        self.surfaceID = surfaceID
        self.workspaceID = workspaceID
        self.chunkIndex = chunkIndex
        self.data = data
        self.createdAt = createdAt
    }

    public var text: String {
        String(decoding: data, as: UTF8.self)
    }
}

public struct TerminalOutputWindow: Equatable {
    public let chunks: [TerminalOutputChunk]
    public let hasMoreOlder: Bool
    public let nextBeforeChunkID: Int64?

    public init(chunks: [TerminalOutputChunk], hasMoreOlder: Bool, nextBeforeChunkID: Int64?) {
        self.chunks = chunks
        self.hasMoreOlder = hasMoreOlder
        self.nextBeforeChunkID = nextBeforeChunkID
    }

    public var text: String {
        chunks.map(\.text).joined()
    }
}

public final class TerminalOutputRepository {
    let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }

    public func append(surfaceID: String, workspaceID: String?, chunkIndex: Int64, data: Data) throws {
        guard !data.isEmpty else { return }
        let st = try db.prepare("""
            INSERT OR IGNORE INTO terminal_output_chunks(surface_id, workspace_id, chunk_index, data, byte_count, created_at)
            VALUES(?, ?, ?, ?, ?, ?);
        """)
        try st.bind(1, surfaceID)
        try st.bind(2, workspaceID)
        try st.bind(3, chunkIndex)
        try st.bind(4, data)
        try st.bind(5, Int64(data.count))
        try st.bind(6, iso.string(from: Date()))
        _ = try st.step()
    }

    public func nextChunkIndex(surfaceID: String) throws -> Int64 {
        let st = try db.prepare("SELECT COALESCE(MAX(chunk_index), 0) + 1 FROM terminal_output_chunks WHERE surface_id = ?;")
        try st.bind(1, surfaceID)
        return (try st.step()) ? st.columnInt64(0) : 1
    }

    public func readWindow(surfaceID: String, beforeChunkID: Int64? = nil, maxBytes: Int = 256 * 1024) throws -> TerminalOutputWindow {
        let byteLimit = max(1, maxBytes)
        let sql: String
        if beforeChunkID == nil {
            sql = """
                SELECT id, surface_id, workspace_id, chunk_index, data, created_at
                FROM terminal_output_chunks
                WHERE surface_id = ?
                ORDER BY id DESC;
            """
        } else {
            sql = """
                SELECT id, surface_id, workspace_id, chunk_index, data, created_at
                FROM terminal_output_chunks
                WHERE surface_id = ? AND id < ?
                ORDER BY id DESC;
            """
        }
        let st = try db.prepare(sql)
        try st.bind(1, surfaceID)
        if let beforeChunkID { try st.bind(2, beforeChunkID) }

        var reversed: [TerminalOutputChunk] = []
        var bytes = 0
        var hasMoreOlder = false
        while try st.step() {
            guard let data = st.columnBlob(4) else { continue }
            if !reversed.isEmpty && bytes + data.count > byteLimit {
                hasMoreOlder = true
                break
            }
            reversed.append(TerminalOutputChunk(
                id: st.columnInt64(0),
                surfaceID: st.columnText(1) ?? "",
                workspaceID: st.columnText(2),
                chunkIndex: st.columnInt64(3),
                data: data,
                createdAt: parseDate(st.columnText(5))
            ))
            bytes += data.count
            if bytes >= byteLimit { break }
        }
        let chunks = Array(reversed.reversed())
        return TerminalOutputWindow(
            chunks: chunks,
            hasMoreOlder: hasMoreOlder || hasOlder(surfaceID: surfaceID, before: chunks.first?.id),
            nextBeforeChunkID: chunks.first?.id
        )
    }

    /// Prune oldest chunks for `surfaceID` so total stored bytes ≤ `maxBytes`.
    /// Deletes rows with the smallest `id` values (oldest) until the byte sum fits.
    public func pruneByteCap(surfaceID: String, maxBytes: Int) throws {
        guard maxBytes > 0 else { return }
        // Walk oldest-first, accumulate bytes, delete rows that exceed the cap.
        let st = try db.prepare("""
            DELETE FROM terminal_output_chunks
            WHERE surface_id = ? AND id NOT IN (
                SELECT id FROM (
                    SELECT id, SUM(byte_count) OVER (ORDER BY id DESC) AS running
                    FROM terminal_output_chunks
                    WHERE surface_id = ?
                )
                WHERE running <= ?
            );
        """)
        try st.bind(1, surfaceID)
        try st.bind(2, surfaceID)
        try st.bind(3, Int64(maxBytes))
        _ = try st.step()
    }

    public func totalBytes(surfaceID: String) throws -> Int {
        let st = try db.prepare("SELECT COALESCE(SUM(byte_count), 0) FROM terminal_output_chunks WHERE surface_id = ?;")
        try st.bind(1, surfaceID)
        return (try st.step()) ? Int(st.columnInt64(0)) : 0
    }

    public func delete(surfaceID: String) throws {
        let st = try db.prepare("DELETE FROM terminal_output_chunks WHERE surface_id = ?;")
        try st.bind(1, surfaceID)
        _ = try st.step()
    }

    private func hasOlder(surfaceID: String, before id: Int64?) -> Bool {
        guard let id else { return false }
        guard let st = try? db.prepare("SELECT 1 FROM terminal_output_chunks WHERE surface_id = ? AND id < ? LIMIT 1;") else { return false }
        try? st.bind(1, surfaceID)
        try? st.bind(2, id)
        return ((try? st.step()) ?? false)
    }
}

extension TerminalOutputRepository: @unchecked Sendable {}

public final class SessionSnapshotRepository {
    let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }

    public func save(_ snap: SessionSnapshot) throws {
        let data = try JSONEncoder().encode(snap)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let st = try db.prepare("INSERT INTO session_snapshots(version, payload_json, created_at) VALUES(?, ?, ?);")
        try st.bind(1, Int64(snap.version))
        try st.bind(2, json)
        try st.bind(3, iso.string(from: snap.createdAt))
        _ = try st.step()
        // prune old
        try db.execute("DELETE FROM session_snapshots WHERE id NOT IN (SELECT id FROM session_snapshots ORDER BY id DESC LIMIT 20);")
    }

    public func latest() throws -> SessionSnapshot? {
        let st = try db.prepare("SELECT payload_json FROM session_snapshots ORDER BY id DESC LIMIT 20;")
        while try st.step() {
            guard let json = st.columnText(0), let data = json.data(using: .utf8) else { continue }
            if let snap = try? JSONDecoder().decode(SessionSnapshot.self, from: data) { return snap }
        }
        return nil
    }
}

public final class SettingsRepository {
    let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }

    public func get(_ key: String) throws -> String? {
        let st = try db.prepare("SELECT value FROM settings WHERE key = ?;")
        try st.bind(1, key)
        if try st.step() { return st.columnText(0) }
        return nil
    }

    public func set(_ key: String, _ value: String) throws {
        let st = try db.prepare("""
            INSERT INTO settings(key, value, updated_at) VALUES(?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at;
        """)
        try st.bind(1, key)
        try st.bind(2, value)
        try st.bind(3, iso.string(from: Date()))
        _ = try st.step()
    }

    /// Delete a single settings row by exact key. No-op if absent.
    public func delete(key: String) throws {
        let st = try db.prepare("DELETE FROM settings WHERE key = ?;")
        try st.bind(1, key)
        _ = try st.step()
    }

    /// Delete every settings row whose key starts with `prefix`. Used to clean
    /// up per-entity blobs (e.g. prompt-history, plan-notes) when the owning
    /// entity is removed.
    public func deleteByPrefix(_ prefix: String) throws {
        // Use '!' as the LIKE escape character to avoid backslash quoting
        // ambiguity.  Workspace UUIDs contain only hex digits and hyphens so
        // the only characters that need escaping are '%' and '_'.
        let st = try db.prepare("DELETE FROM settings WHERE key LIKE ? ESCAPE '!';")
        let escaped = prefix
            .replacingOccurrences(of: "!", with: "!!")
            .replacingOccurrences(of: "%", with: "!%")
            .replacingOccurrences(of: "_", with: "!_")
        try st.bind(1, escaped + "%")
        _ = try st.step()
    }
}
