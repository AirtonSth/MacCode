import Foundation
import CoreModel

/// Per-conversation Bot desk routing (schema v89).
///
/// The row holds the encoded `BotDeskRouting` the AppShell owns; this layer
/// stores it as opaque JSON so the Mac desk and paired `bot.send` read one
/// source of truth. A row only exists for a live desk conversation and is
/// deleted with it (`ON DELETE CASCADE`).
extension BotStore {
    /// Every stored route, keyed by conversation.
    public func listDeskRoutingJSON() throws -> [BotConversationID: String] {
        try db.performSync { database in
            let statement = try database.prepare(
                "SELECT conversation_id, routing_json FROM bot_conversation_routing;"
            )
            defer { statement.reset() }
            var rows: [BotConversationID: String] = [:]
            while try statement.step() {
                guard let raw = statement.columnText(0),
                      let uuid = UUID(uuidString: raw),
                      let json = statement.columnText(1) else { continue }
                rows[BotConversationID(uuid)] = json
            }
            return rows
        }
    }

    public func deskRoutingJSON(conversationID: BotConversationID) throws -> String? {
        try db.performSync { database in
            let statement = try database.prepare(
                "SELECT routing_json FROM bot_conversation_routing WHERE conversation_id = ?;"
            )
            defer { statement.reset() }
            try statement.bind(1, conversationID.value.uuidString.lowercased())
            return try statement.step() ? statement.columnText(0) : nil
        }
    }

    /// Upserts the route for a desk conversation. Returns false (and writes
    /// nothing) when the conversation no longer exists, so a stale writer
    /// cannot leave an orphan row.
    @discardableResult
    public func setDeskRoutingJSON(
        _ json: String,
        conversationID: BotConversationID,
        now: Date = Date()
    ) throws -> Bool {
        try db.performSync { database in
            let key = conversationID.value.uuidString.lowercased()
            let exists = try database.prepare("SELECT 1 FROM bot_conversations WHERE id = ?;")
            defer { exists.reset() }
            try exists.bind(1, key)
            guard try exists.step() else { return false }
            exists.reset()
            let statement = try database.prepare("""
                INSERT INTO bot_conversation_routing(conversation_id, routing_json, updated_at)
                VALUES(?, ?, ?)
                ON CONFLICT(conversation_id) DO UPDATE SET
                    routing_json=excluded.routing_json, updated_at=excluded.updated_at;
                """)
            defer { statement.reset() }
            try statement.bind(1, key)
            try statement.bind(2, json)
            try statement.bind(3, string(now))
            _ = try statement.step()
            return true
        }
    }
}
