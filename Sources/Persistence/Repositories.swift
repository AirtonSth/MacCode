import Foundation
import CoreModel

private let iso = ISO8601DateFormatter()

private func parseDate(_ s: String?) -> Date {
    guard let s, let d = iso.date(from: s) else { return Date() }
    return d
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
            INSERT INTO agent_threads(id, project_id, workspace_id, title, provider, model, provider_thread_id, status, created_at, updated_at, diff_additions, diff_deletions, has_unread)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, provider=excluded.provider, model=excluded.model, provider_thread_id=excluded.provider_thread_id, status=excluded.status, updated_at=excluded.updated_at, diff_additions=excluded.diff_additions, diff_deletions=excluded.diff_deletions, has_unread=excluded.has_unread;
        """)
        try st.bind(1, t.id.value.uuidString)
        try st.bind(2, t.projectId?.value.uuidString)
        try st.bind(3, t.workspaceId?.value.uuidString)
        try st.bind(4, t.title)
        try st.bind(5, t.provider.rawValue)
        try st.bind(6, t.model)
        try st.bind(7, t.providerThreadId)
        try st.bind(8, t.status.rawValue)
        try st.bind(9, iso.string(from: t.createdAt))
        try st.bind(10, iso.string(from: t.updatedAt))
        try st.bind(11, Int64(t.diffAdditions))
        try st.bind(12, Int64(t.diffDeletions))
        try st.bind(13, t.hasUnread)
        _ = try st.step()
    }

    public func list(workspaceId: WorkspaceID? = nil) throws -> [AgentThread] {
        let sql = workspaceId == nil
            ? "SELECT id, project_id, workspace_id, title, provider, model, provider_thread_id, status, created_at, updated_at, diff_additions, diff_deletions, has_unread FROM agent_threads ORDER BY updated_at DESC;"
            : "SELECT id, project_id, workspace_id, title, provider, model, provider_thread_id, status, created_at, updated_at, diff_additions, diff_deletions, has_unread FROM agent_threads WHERE workspace_id = ? ORDER BY updated_at DESC;"
        let st = try db.prepare(sql)
        if let wid = workspaceId { try st.bind(1, wid.value.uuidString) }
        var out: [AgentThread] = []
        while try st.step() {
            let id = AgentThreadID(UUID(uuidString: st.columnText(0) ?? "") ?? UUID())
            let pid = (st.columnText(1)).flatMap { UUID(uuidString: $0) }.map { ProjectID($0) }
            let wid = (st.columnText(2)).flatMap { UUID(uuidString: $0) }.map { WorkspaceID($0) }
            out.append(AgentThread(
                id: id,
                projectId: pid,
                workspaceId: wid,
                title: st.columnText(3) ?? "",
                provider: AgentProvider(rawValue: st.columnText(4) ?? "codex") ?? .codex,
                model: st.columnText(5) ?? "",
                providerThreadId: st.columnText(6),
                status: AgentRunStatus(rawValue: st.columnText(7) ?? "") ?? .pending,
                createdAt: parseDate(st.columnText(8)),
                updatedAt: parseDate(st.columnText(9)),
                diffAdditions: Int(st.columnInt64(10)),
                diffDeletions: Int(st.columnInt64(11)),
                hasUnread: st.columnInt64(12) != 0
            ))
        }
        return out
    }

    public func get(id: AgentThreadID) throws -> AgentThread? {
        let st = try db.prepare("SELECT id, project_id, workspace_id, title, provider, model, provider_thread_id, status, created_at, updated_at, diff_additions, diff_deletions, has_unread FROM agent_threads WHERE id = ?;")
        try st.bind(1, id.value.uuidString)
        if try st.step() {
            let idVal = AgentThreadID(UUID(uuidString: st.columnText(0) ?? "") ?? UUID())
            let pid = (st.columnText(1)).flatMap { UUID(uuidString: $0) }.map { ProjectID($0) }
            let wid = (st.columnText(2)).flatMap { UUID(uuidString: $0) }.map { WorkspaceID($0) }
            return AgentThread(
                id: idVal,
                projectId: pid,
                workspaceId: wid,
                title: st.columnText(3) ?? "",
                provider: AgentProvider(rawValue: st.columnText(4) ?? "codex") ?? .codex,
                model: st.columnText(5) ?? "",
                providerThreadId: st.columnText(6),
                status: AgentRunStatus(rawValue: st.columnText(7) ?? "") ?? .pending,
                createdAt: parseDate(st.columnText(8)),
                updatedAt: parseDate(st.columnText(9)),
                diffAdditions: Int(st.columnInt64(10)),
                diffDeletions: Int(st.columnInt64(11)),
                hasUnread: st.columnInt64(12) != 0
            )
        }
        return nil
    }

    public func delete(id: AgentThreadID) throws {
        let st = try db.prepare("DELETE FROM agent_threads WHERE id = ?;")
        try st.bind(1, id.value.uuidString)
        _ = try st.step()
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
        let st = try db.prepare("SELECT id, thread_id, role, content, created_at FROM agent_messages WHERE thread_id = ? ORDER BY created_at ASC;")
        try st.bind(1, threadId.value.uuidString)
        var out: [AgentMessage] = []
        while try st.step() {
            let id = AgentMessageID(UUID(uuidString: st.columnText(0) ?? "") ?? UUID())
            let tid = AgentThreadID(UUID(uuidString: st.columnText(1) ?? "") ?? UUID())
            out.append(AgentMessage(
                id: id,
                threadId: tid,
                role: AgentMessageRole(rawValue: st.columnText(2) ?? "") ?? .user,
                content: st.columnText(3) ?? "",
                createdAt: parseDate(st.columnText(4))
            ))
        }
        return out
    }
}

public final class AgentRunRepository {
    let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }

    public func upsert(_ r: AgentRun) throws {
        let st = try db.prepare("""
            INSERT INTO agent_runs(id, thread_id, provider, model, status, started_at, finished_at, error_message)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET status=excluded.status, finished_at=excluded.finished_at, error_message=excluded.error_message;
        """)
        try st.bind(1, r.id.value.uuidString)
        try st.bind(2, r.threadId.value.uuidString)
        try st.bind(3, r.provider.rawValue)
        try st.bind(4, r.model)
        try st.bind(5, r.status.rawValue)
        try st.bind(6, iso.string(from: r.startedAt))
        try st.bind(7, r.finishedAt.map { iso.string(from: $0) })
        try st.bind(8, r.errorMessage)
        _ = try st.step()
    }

    public func reconcileRunningOnLaunch() throws -> Int {
        let countBefore = try countRunning()
        let st = try db.prepare("UPDATE agent_runs SET status='interrupted', finished_at=? WHERE status='running';")
        try st.bind(1, iso.string(from: Date()))
        _ = try st.step()
        return countBefore
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
}

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
        let st = try db.prepare("SELECT payload_json FROM session_snapshots ORDER BY id DESC LIMIT 1;")
        if try st.step() {
            guard let json = st.columnText(0), let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
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
        try st.bind(3, ISO8601DateFormatter().string(from: Date()))
        _ = try st.step()
    }
}
