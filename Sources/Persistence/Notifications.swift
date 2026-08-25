import Foundation
import CoreModel

public struct AppNotification: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var workspaceId: WorkspaceID?
    public var surfaceId: SurfaceID?
    public var title: String
    public var body: String?
    public var category: String?
    public var createdAt: Date
    public var readAt: Date?
    public var dismissedAt: Date?

    public init(id: String = UUID().uuidString, workspaceId: WorkspaceID? = nil, surfaceId: SurfaceID? = nil, title: String, body: String? = nil, category: String? = nil, createdAt: Date = Date(), readAt: Date? = nil, dismissedAt: Date? = nil) {
        self.id = id; self.workspaceId = workspaceId; self.surfaceId = surfaceId
        self.title = title; self.body = body; self.category = category
        self.createdAt = createdAt; self.readAt = readAt; self.dismissedAt = dismissedAt
    }
}

public final class NotificationRepository {
    let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }
    private let iso = LockedISO8601Formatter(ISO8601DateFormatter())

    public func insert(_ n: AppNotification) throws {
        let st = try db.prepare("""
            INSERT INTO notifications(id, workspace_id, surface_id, title, body, category, created_at, read_at, dismissed_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, body=excluded.body, category=excluded.category, read_at=excluded.read_at, dismissed_at=excluded.dismissed_at;
        """)
        try bind(n, to: st)
        _ = try st.step()
    }

    /// Idempotent event projection. Unlike `insert`, replaying the same stable
    /// event ID must not clear an existing read/dismissed timestamp and resurrect
    /// an item the user already acknowledged.
    @discardableResult
    public func insertIfAbsent(_ n: AppNotification) throws -> Bool {
        let st = try db.prepare("""
            INSERT OR IGNORE INTO notifications(id, workspace_id, surface_id, title, body, category, created_at, read_at, dismissed_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?);
        """)
        try bind(n, to: st)
        _ = try st.step()
        let changed = try db.prepare("SELECT changes();")
        defer { changed.reset() }
        return try changed.step() && changed.columnInt64(0) == 1
    }

    /// Reopens one stable stateful notification for a new live occurrence.
    /// Durable replay uses `insertIfAbsent` instead so an acknowledged historical
    /// event cannot resurrect itself during startup recovery.
    public func resurface(_ n: AppNotification) throws {
        let st = try db.prepare("""
            INSERT INTO notifications(id, workspace_id, surface_id, title, body, category, created_at, read_at, dismissed_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                workspace_id=excluded.workspace_id,
                surface_id=excluded.surface_id,
                title=excluded.title,
                body=excluded.body,
                category=excluded.category,
                created_at=excluded.created_at,
                read_at=excluded.read_at,
                dismissed_at=excluded.dismissed_at;
        """)
        try bind(n, to: st)
        _ = try st.step()
    }

    private func bind(_ notification: AppNotification, to statement: SQLiteStatement) throws {
        try statement.bind(1, notification.id)
        try statement.bind(2, notification.workspaceId?.value.uuidString)
        try statement.bind(3, notification.surfaceId?.value.uuidString)
        try statement.bind(4, notification.title)
        try statement.bind(5, notification.body)
        try statement.bind(6, notification.category)
        try statement.bind(7, iso.string(from: notification.createdAt))
        try statement.bind(8, notification.readAt.map { iso.string(from: $0) })
        try statement.bind(9, notification.dismissedAt.map { iso.string(from: $0) })
    }

    /// Fetch non-dismissed notifications newest-first, bounded by `limit` to
    /// prevent unbounded query cost on long-lived installs where dismissed rows
    /// accumulate indefinitely (dismissed rows are excluded by the WHERE clause
    /// but un-dismissed rows are not pruned elsewhere).
    public func list(workspaceId: WorkspaceID? = nil, unreadOnly: Bool = false, limit: Int = 200) throws -> [AppNotification] {
        var sql = "SELECT id, workspace_id, surface_id, title, body, category, created_at, read_at, dismissed_at FROM notifications WHERE dismissed_at IS NULL"
        if workspaceId != nil { sql += " AND workspace_id = ?" }
        if unreadOnly { sql += " AND read_at IS NULL" }
        sql += " ORDER BY created_at DESC LIMIT ?;"
        let st = try db.prepare(sql)
        var p: Int32 = 1
        if let wid = workspaceId { try st.bind(p, wid.value.uuidString); p += 1 }
        try st.bind(p, Int64(max(1, limit)))
        var out: [AppNotification] = []
        while try st.step() {
            let wid = (st.columnText(1)).flatMap { UUID(uuidString: $0) }.map { WorkspaceID($0) }
            let sid = (st.columnText(2)).flatMap { UUID(uuidString: $0) }.map { SurfaceID($0) }
            out.append(AppNotification(
                id: st.columnText(0) ?? "",
                workspaceId: wid,
                surfaceId: sid,
                title: st.columnText(3) ?? "",
                body: st.columnText(4),
                category: st.columnText(5),
                createdAt: iso.date(from: st.columnText(6) ?? "") ?? Date(),
                readAt: (st.columnText(7)).flatMap { iso.date(from: $0) },
                dismissedAt: (st.columnText(8)).flatMap { iso.date(from: $0) }
            ))
        }
        return out
    }

    public func markRead(id: String) throws {
        let st = try db.prepare("UPDATE notifications SET read_at = ? WHERE id = ?;")
        try st.bind(1, iso.string(from: Date()))
        try st.bind(2, id)
        _ = try st.step()
    }

    public func dismiss(id: String) throws {
        let st = try db.prepare("UPDATE notifications SET dismissed_at = ? WHERE id = ?;")
        try st.bind(1, iso.string(from: Date()))
        try st.bind(2, id)
        _ = try st.step()
    }
}
