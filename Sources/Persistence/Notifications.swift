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
    private let iso = ISO8601DateFormatter()

    public func insert(_ n: AppNotification) throws {
        let st = try db.prepare("""
            INSERT INTO notifications(id, workspace_id, surface_id, title, body, category, created_at, read_at, dismissed_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, body=excluded.body, category=excluded.category, read_at=excluded.read_at, dismissed_at=excluded.dismissed_at;
        """)
        try st.bind(1, n.id)
        try st.bind(2, n.workspaceId?.value.uuidString)
        try st.bind(3, n.surfaceId?.value.uuidString)
        try st.bind(4, n.title)
        try st.bind(5, n.body)
        try st.bind(6, n.category)
        try st.bind(7, iso.string(from: n.createdAt))
        try st.bind(8, n.readAt.map { iso.string(from: $0) })
        try st.bind(9, n.dismissedAt.map { iso.string(from: $0) })
        _ = try st.step()
    }

    public func list(workspaceId: WorkspaceID? = nil, unreadOnly: Bool = false) throws -> [AppNotification] {
        var sql = "SELECT id, workspace_id, surface_id, title, body, category, created_at, read_at, dismissed_at FROM notifications WHERE dismissed_at IS NULL"
        if let _ = workspaceId { sql += " AND workspace_id = ?" }
        if unreadOnly { sql += " AND read_at IS NULL" }
        sql += " ORDER BY created_at DESC;"
        let st = try db.prepare(sql)
        var p: Int32 = 1
        if let wid = workspaceId { try st.bind(p, wid.value.uuidString); p += 1 }
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
