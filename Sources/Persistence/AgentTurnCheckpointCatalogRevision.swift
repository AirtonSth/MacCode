import Foundation

/// Per-process catalog generation fence for `agent.checkpoint.list` v1.
///
/// Incremented transactionally with every insert/upsert/delete that can change
/// list-emitted fields or order keys. First page returns the revision; later
/// pages require it and restart once on drift. Never digests the full catalog.
public enum AgentTurnCheckpointCatalogRevision {
    public static let tableSQL = """
        CREATE TABLE IF NOT EXISTS agent_turn_checkpoint_catalog_meta (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            revision INTEGER NOT NULL DEFAULT 1
        );
        """

    public static let seedSQL = """
        INSERT OR IGNORE INTO agent_turn_checkpoint_catalog_meta(id, revision) VALUES(1, 1);
        """

    public static let insertTriggerSQL = """
        CREATE TRIGGER IF NOT EXISTS trg_agent_turn_checkpoints_catalog_insert
        AFTER INSERT ON agent_turn_checkpoints
        BEGIN
            UPDATE agent_turn_checkpoint_catalog_meta
            SET revision = revision + 1
            WHERE id = 1;
        END;
        """

    public static let updateTriggerSQL = """
        CREATE TRIGGER IF NOT EXISTS trg_agent_turn_checkpoints_catalog_update
        AFTER UPDATE ON agent_turn_checkpoints
        BEGIN
            UPDATE agent_turn_checkpoint_catalog_meta
            SET revision = revision + 1
            WHERE id = 1;
        END;
        """

    public static let deleteTriggerSQL = """
        CREATE TRIGGER IF NOT EXISTS trg_agent_turn_checkpoints_catalog_delete
        AFTER DELETE ON agent_turn_checkpoints
        BEGIN
            UPDATE agent_turn_checkpoint_catalog_meta
            SET revision = revision + 1
            WHERE id = 1;
        END;
        """

    public static func ensureTable(_ db: SQLiteDB) throws {
        try db.execute(tableSQL)
        try db.execute(seedSQL)
        try db.execute(insertTriggerSQL)
        try db.execute(updateTriggerSQL)
        try db.execute(deleteTriggerSQL)
    }

    public static func current(db: SQLiteDB) throws -> Int64 {
        try ensureTable(db)
        let st = try db.prepare(
            "SELECT revision FROM agent_turn_checkpoint_catalog_meta WHERE id = 1;"
        )
        guard try st.step() else { return 1 }
        return st.columnInt64(0)
    }

    /// Explicit bump for call sites that need a revision change outside row
    /// triggers (tests). Production mutations rely on INSERT/UPDATE/DELETE
    /// triggers so revision stays transactional with the row write.
    @discardableResult
    public static func bump(db: SQLiteDB) throws -> Int64 {
        try ensureTable(db)
        try db.execute(
            "UPDATE agent_turn_checkpoint_catalog_meta SET revision = revision + 1 WHERE id = 1;"
        )
        return try current(db: db)
    }
}
