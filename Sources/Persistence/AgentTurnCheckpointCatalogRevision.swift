import Foundation
import CoreModel

/// Per-thread catalog generation fence for `agent.checkpoint.list` v1.
///
/// Each agent thread owns an independent revision counter. Mutations on thread B
/// never invalidate or starve pagination on thread A. Bumped transactionally
/// only when an emitted list metadata/order field for that exact thread changes
/// (or a row is inserted/deleted). First page returns the revision; later pages
/// require it and restart once on drift. Never digests the full catalog.
public enum AgentTurnCheckpointCatalogRevision {
    /// Columns that affect list-emitted metadata or keyset order. Detail-only
    /// payloads (`files_json`, snapshots, diffs, raw turn_id/ref/error) are
    /// intentionally excluded so non-emitted rewrites do not spuriously fence.
    public static let listEmittedChangePredicateSQL = """
        OLD.checkpoint_turn_count IS NOT NEW.checkpoint_turn_count
        OR OLD.status IS NOT NEW.status
        OR OLD.assistant_message_id IS NOT NEW.assistant_message_id
        OR OLD.files_summary_json IS NOT NEW.files_summary_json
        OR OLD.files_summary_truncated IS NOT NEW.files_summary_truncated
        OR OLD.list_turn_id IS NOT NEW.list_turn_id
        OR OLD.list_turn_id_encoded_bytes IS NOT NEW.list_turn_id_encoded_bytes
        OR OLD.list_turn_id_sha256 IS NOT NEW.list_turn_id_sha256
        OR OLD.list_turn_id_truncated IS NOT NEW.list_turn_id_truncated
        OR OLD.list_checkpoint_ref IS NOT NEW.list_checkpoint_ref
        OR OLD.list_checkpoint_ref_encoded_bytes IS NOT NEW.list_checkpoint_ref_encoded_bytes
        OR OLD.list_checkpoint_ref_sha256 IS NOT NEW.list_checkpoint_ref_sha256
        OR OLD.list_checkpoint_ref_truncated IS NOT NEW.list_checkpoint_ref_truncated
        OR OLD.list_error_message IS NOT NEW.list_error_message
        OR OLD.list_error_message_encoded_bytes IS NOT NEW.list_error_message_encoded_bytes
        OR OLD.list_error_message_sha256 IS NOT NEW.list_error_message_sha256
        OR OLD.list_error_message_truncated IS NOT NEW.list_error_message_truncated
        OR OLD.list_completed_at IS NOT NEW.list_completed_at
        OR OLD.list_metadata_unavailable IS NOT NEW.list_metadata_unavailable
        OR OLD.run_id IS NOT NEW.run_id
        """

    public static let tableSQL = """
        CREATE TABLE IF NOT EXISTS agent_turn_checkpoint_catalog_meta (
            thread_id TEXT PRIMARY KEY NOT NULL,
            revision INTEGER NOT NULL DEFAULT 1
        );
        """

    public static let insertTriggerSQL = """
        CREATE TRIGGER IF NOT EXISTS trg_agent_turn_checkpoints_catalog_insert
        AFTER INSERT ON agent_turn_checkpoints
        BEGIN
            INSERT INTO agent_turn_checkpoint_catalog_meta(thread_id, revision)
            VALUES (NEW.thread_id, 2)
            ON CONFLICT(thread_id) DO UPDATE SET
                revision = agent_turn_checkpoint_catalog_meta.revision + 1;
        END;
        """

    public static let updateTriggerSQL = """
        CREATE TRIGGER IF NOT EXISTS trg_agent_turn_checkpoints_catalog_update
        AFTER UPDATE ON agent_turn_checkpoints
        WHEN \(listEmittedChangePredicateSQL)
        BEGIN
            INSERT INTO agent_turn_checkpoint_catalog_meta(thread_id, revision)
            VALUES (NEW.thread_id, 2)
            ON CONFLICT(thread_id) DO UPDATE SET
                revision = agent_turn_checkpoint_catalog_meta.revision + 1;
        END;
        """

    public static let deleteTriggerSQL = """
        CREATE TRIGGER IF NOT EXISTS trg_agent_turn_checkpoints_catalog_delete
        AFTER DELETE ON agent_turn_checkpoints
        BEGIN
            INSERT INTO agent_turn_checkpoint_catalog_meta(thread_id, revision)
            VALUES (OLD.thread_id, 2)
            ON CONFLICT(thread_id) DO UPDATE SET
                revision = agent_turn_checkpoint_catalog_meta.revision + 1;
        END;
        """

    public static func ensureTable(_ db: SQLiteDB) throws {
        try db.execute(tableSQL)
        try db.execute(insertTriggerSQL)
        try db.execute(updateTriggerSQL)
        try db.execute(deleteTriggerSQL)
    }

    /// Revision fence for `threadId`. Threads with no prior list-affecting
    /// mutation report `1` so first-page clients start from a stable baseline.
    public static func current(db: SQLiteDB, threadId: AgentThreadID) throws -> Int64 {
        try ensureTable(db)
        let st = try db.prepare(
            """
            SELECT revision FROM agent_turn_checkpoint_catalog_meta
            WHERE thread_id = ?;
            """
        )
        try st.bind(1, threadId.value.uuidString)
        guard try st.step() else { return 1 }
        return st.columnInt64(0)
    }

    /// Explicit bump for call sites that need a revision change outside row
    /// triggers (tests). Production mutations rely on INSERT/UPDATE/DELETE
    /// triggers so revision stays transactional with the row write.
    @discardableResult
    public static func bump(db: SQLiteDB, threadId: AgentThreadID) throws -> Int64 {
        try ensureTable(db)
        let st = try db.prepare(
            """
            INSERT INTO agent_turn_checkpoint_catalog_meta(thread_id, revision)
            VALUES (?, 2)
            ON CONFLICT(thread_id) DO UPDATE SET
                revision = agent_turn_checkpoint_catalog_meta.revision + 1;
            """
        )
        try st.bind(1, threadId.value.uuidString)
        _ = try st.step()
        return try current(db: db, threadId: threadId)
    }
}
