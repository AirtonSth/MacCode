import Foundation
import Darwin
import CoreModel

/// Offline restore only: caller must own the host instance lock, with no live AppContext.
public enum HostDatabaseRestore {
    public static func restore(backupURL: URL, currentURL: URL) throws -> URL {
        let sourceInfo = try regularFile(backupURL)
        let currentInfo = try regularFile(currentURL)
        guard sourceInfo.st_dev != currentInfo.st_dev || sourceInfo.st_ino != currentInfo.st_ino else {
            throw SQLiteError.open("restore source and current database are the same file")
        }
        let directory = currentURL.deletingLastPathComponent()
        let token = UUID().uuidString
        let stageURL = directory.appendingPathComponent(".restore-stage-\(token).sqlite")
        let recoveryURL = directory.appendingPathComponent(".restore-recovery-\(token).sqlite")
        var recoveryCreated = false
        do {
            try restore(backupURL: backupURL, currentURL: currentURL, stageURL: stageURL,
                        recoveryURL: recoveryURL, recoveryCreated: &recoveryCreated)
            do {
                try removeStage(stageURL)
            } catch {
                throw SQLiteError.execute("database restore committed but staging cleanup failed: \(error)")
            }
            return recoveryURL
        } catch {
            try? removeStage(stageURL)
            if recoveryCreated {
                throw SQLiteError.execute("\(error); pre-restore recovery database: \(recoveryURL.path)")
            }
            try? removeStage(recoveryURL)
            throw error
        }
    }

    private static func restore(backupURL: URL, currentURL: URL, stageURL: URL,
                                recoveryURL: URL, recoveryCreated: inout Bool) throws {
        let source = try SQLiteDB(path: backupURL.path, readonly: true)
        try validateBackupSchema(source)
        try createPrivateFile(stageURL)
        do {
            let stage = try SQLiteDB(path: stageURL.path)
            try source.backup(to: stage)
            try Schema.migrate(stage)
            try stage.enableFullDurability()
            try validateRestorableWork(stage)
        }

        let current = try SQLiteDB(path: currentURL.path)
        try current.enableFullDurability()
        try current.execute("PRAGMA locking_mode=EXCLUSIVE;")
        try current.execute("BEGIN EXCLUSIVE;")
        try current.execute("COMMIT;")
        try validateVersion(current)
        try Schema.migrate(current)
        try createPrivateFile(recoveryURL)
        let recovery = try SQLiteDB(path: recoveryURL.path)
        try recovery.enableFullDurability()
        try current.backup(to: recovery)
        recoveryCreated = true

        do {
            let attach = try current.prepare("ATTACH DATABASE ? AS restored;")
            defer { attach.reset() }
            try attach.bind(1, stageURL.path)
            _ = try attach.step()
        }
        var columns: [String] = []
        do {
            let info = try current.prepare("PRAGMA table_info(bots);")
            defer { info.reset() }
            while try info.step() {
                if let name = info.columnText(1), name != "id" {
                    columns.append(name.replacingOccurrences(of: "\"", with: "\"\""))
                }
            }
        }
        let botUpdates = columns.map { "\"\($0)\"=latest.\"\($0)\"" }.joined(separator: ",")
        do {
            try current.transaction {
                try current.execute("""
                    INSERT INTO restored.bots SELECT b.* FROM main.bots AS b
                    WHERE b.id IN (SELECT bot_id FROM main.bot_context_bindings)
                      AND NOT EXISTS (SELECT 1 FROM restored.bots WHERE restored.bots.id=b.id);
                    INSERT INTO restored.bot_revisions SELECT r.* FROM main.bot_revisions AS r
                    WHERE r.bot_id IN (SELECT id FROM restored.bots)
                      AND NOT EXISTS (SELECT 1 FROM restored.bot_revisions WHERE id=r.id);
                    UPDATE restored.bots AS old SET \(botUpdates)
                    FROM main.bots AS latest WHERE old.id=latest.id;
                    DELETE FROM restored.bot_handles WHERE bot_id IN (SELECT id FROM main.bots);
                    INSERT INTO restored.bot_handles SELECT h.* FROM main.bot_handles AS h
                    WHERE h.bot_id IN (SELECT id FROM restored.bots);
                    INSERT INTO restored.bot_handle_tombstones SELECT t.* FROM main.bot_handle_tombstones AS t
                    WHERE NOT EXISTS (SELECT 1 FROM restored.bot_handle_tombstones WHERE handle=t.handle);
                    DELETE FROM restored.bot_context_bindings;
                    INSERT INTO restored.bot_context_bindings SELECT * FROM main.bot_context_bindings;
                    DELETE FROM restored.settings;
                    INSERT INTO restored.settings SELECT * FROM main.settings;
                    DELETE FROM restored.command_receipts;
                    INSERT INTO restored.command_receipts SELECT * FROM main.command_receipts;
                    UPDATE restored.agent_runs AS old
                    SET status=latest.status, finished_at=latest.finished_at,
                        error_message=latest.error_message, terminal_reason=latest.terminal_reason
                    FROM main.agent_runs AS latest
                    WHERE old.id=latest.id AND latest.status NOT IN ('running','pending');
                    """)
            }
        } catch {
            try? current.execute("DETACH DATABASE restored;")
            throw error
        }
        try current.execute("DETACH DATABASE restored;")
        let stage = try SQLiteDB(path: stageURL.path)
        try stage.enableFullDurability()
        try CommandReceiptRepository(db: stage).recoverInterruptedClaims()
        _ = try AgentRunRepository(db: stage).reconcileRunningOnLaunch()
        try AgentThreadRepository(db: stage).reconcileRunningOnLaunch()
        do {
            let check = try stage.prepare("PRAGMA integrity_check;")
            defer { check.reset() }
            guard try check.step(), check.columnText(0) == "ok", try !check.step() else {
                throw SQLiteError.execute("restore integrity check failed")
            }
        }
        do {
            let check = try stage.prepare("PRAGMA foreign_key_check;")
            defer { check.reset() }
            guard try !check.step() else { throw SQLiteError.execute("restore foreign key check failed") }
        }
        try stage.backup(to: current)
    }

    private static func validateBackupSchema(_ db: SQLiteDB) throws {
        // ponytail: accept the exact current schema; older schema imports need a validated data-only migration.
        let trusted = try SQLiteDB(path: ":memory:")
        try Schema.migrate(trusted)
        func schema(_ database: SQLiteDB) throws -> [String: String] {
            let statement = try database.prepare("SELECT type,name,sql FROM sqlite_schema WHERE sql IS NOT NULL ORDER BY type,name;")
            defer { statement.reset() }
            var result: [String: String] = [:]
            while try statement.step() {
                guard let type = statement.columnText(0), let name = statement.columnText(1), let sql = statement.columnText(2) else {
                    throw SQLiteError.execute("restore backup contains an unsupported schema object")
                }
                result[type + "/" + name] = sql
            }
            return result
        }
        guard try schema(db) == schema(trusted) else {
            throw SQLiteError.execute("restore requires the exact trusted current database schema")
        }
        try validateVersion(db)
    }

    private static func validateVersion(_ db: SQLiteDB) throws {
        let statement = try db.prepare("SELECT MAX(version), typeof(MAX(version)) FROM schema_meta;")
        defer { statement.reset() }
        guard try statement.step(), statement.columnText(1) == "integer",
              statement.columnInt64(0) > 0, statement.columnInt64(0) <= Int64(Schema.currentVersion) else {
            throw SQLiteError.execute("restore requires a supported RemoteCode database schema")
        }
    }

    private static func validateRestorableWork(_ db: SQLiteDB) throws {
        // ponytail: legacy queued work and enabled schedules require a future explicit-review restore path.
        let statement = try db.prepare("""
            SELECT 1 WHERE EXISTS (
                SELECT 1 FROM agent_queued_messages q WHERE NOT EXISTS (
                    SELECT 1 FROM bot_conversation_contexts c WHERE c.thread_id=q.thread_id))
            OR EXISTS (SELECT 1 FROM bot_queued_follow_ups q WHERE NOT EXISTS (
                SELECT 1 FROM bot_conversation_contexts c WHERE c.conversation_id=q.conversation_id))
            OR EXISTS (SELECT 1 FROM bot_routine_activations WHERE is_enabled<>0)
            OR EXISTS (SELECT 1 FROM scheduled_tasks WHERE enabled<>0);
            """)
        defer { statement.reset() }
        guard try !statement.step() else {
            throw SQLiteError.execute("backup contains legacy queued work or enabled schedules requiring explicit review")
        }
    }

    private static func regularFile(_ url: URL) throws -> stat {
        var info = stat()
        guard url.isFileURL, lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw SQLiteError.open("restore input is not an existing regular file")
        }
        return info
    }

    private static func createPrivateFile(_ url: URL) throws {
        let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SQLiteError.open("cannot create private restore database") }
        close(descriptor)
    }

    private static func removeStage(_ url: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
        }
    }
}
