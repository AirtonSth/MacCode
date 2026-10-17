import Foundation
import XCTest
import CoreModel
@testable import Persistence

/// Drives the shipped `HostDatabaseRestore` with a consistent copy of a real host database.
/// Skipped unless `RC_HOST_RESTORE_REAL_COPY` names a copy inside an isolated sandbox directory;
/// the live user database is never opened.
final class HostDatabaseRestoreRealCopyTests: XCTestCase {
    private static let tables = ["bots", "bot_revisions", "bot_conversations", "bot_memory_items", "bot_routine_definitions", "bot_teams", "bot_group_conversations", "agent_threads", "agent_runs", "agent_queued_messages", "scheduled_tasks", "bot_attention_items"]
    private static let authorityTables = ["bot_context_bindings", "bot_conversation_contexts", "bot_context_delegations"]

    private func count(_ db: SQLiteDB, _ table: String) throws -> Int64 {
        let statement = try db.prepare("SELECT COUNT(*) FROM \(table);")
        defer { statement.reset() }
        XCTAssertTrue(try statement.step())
        return statement.columnInt64(0)
    }

    private func prepare(_ backup: URL) throws -> URL {
        XCTAssertTrue(backup.path.contains("/.sandbox-worktrees/") && backup.path.contains("/.sandbox-state/host-restore-real-"), "refusing a path outside the isolated copy directory")
        let current = backup.deletingLastPathComponent().appendingPathComponent("current-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: backup, to: current)
        return current
    }

    private func realCopy() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["RC_HOST_RESTORE_REAL_COPY"] else {
            throw XCTSkip("set RC_HOST_RESTORE_REAL_COPY to a copied real database inside an isolated sandbox directory")
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func directoryNames(_ url: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path))
    }

    private func trimmedCopy(of original: URL, name: String) throws -> URL {
        let copy = original.deletingLastPathComponent().appendingPathComponent(name)
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: original, to: copy)
        let trim = try SQLiteDB(path: copy.path)
        for table in ["agent_message_display_translations", "agent_message_outbound_payloads", "agent_timeline_display_translations"] {
            try trim.execute("DROP TABLE IF EXISTS \(table);")
        }
        return copy
    }

    /// A real database written by a newer build carries objects this schema does not know.
    /// Restore must refuse it and leave the current database byte-for-byte unchanged.
    func test_restoreRefusesRealCopyWithUnknownNewerObjectsAndChangesNothing() throws {
        let backup = try realCopy()
        let current = try prepare(backup)
        defer { try? FileManager.default.removeItem(at: current) }
        let before = try Data(contentsOf: current)
        let namesBefore = try directoryNames(backup)
        XCTAssertThrowsError(try HostDatabaseRestore.inspect(backupURL: backup)) {
            XCTAssertTrue(String(describing: $0).contains("exact trusted database schema"), "\($0)")
        }
        XCTAssertThrowsError(try HostDatabaseRestore.restore(backupURL: backup, currentURL: current)) {
            XCTAssertTrue(String(describing: $0).contains("exact trusted database schema"), "\($0)")
        }
        XCTAssertEqual(try Data(contentsOf: current), before, "refused restore must not alter the current database")
        let created = try directoryNames(backup).subtracting(namesBefore).filter { $0.hasPrefix(".restore-") }
        XCTAssertTrue(created.isEmpty, "refused restore must leave no staging or recovery files: \(created)")
    }

    /// The real database holds queued work or schedules, which need explicit review, and rows whose
    /// parent thread no longer exists. Restore must refuse both ways and keep the current data.
    func test_restoreRefusesRealCopyWithOrphanRowsAndKeepsCurrentData() throws {
        let backup = try trimmedCopy(of: try realCopy(), name: "backup-trimmed.sqlite")
        let current = try prepare(backup)
        defer { try? FileManager.default.removeItem(at: current) }
        let beforeDB = try SQLiteDB(path: backup.path)
        let expectedRuns = try count(beforeDB, "agent_runs"), expectedBots = try count(beforeDB, "bots")
        let review = try HostDatabaseRestore.inspect(backupURL: backup)
        XCTAssertTrue(review.requiresConfirmation, "the real host holds queued work or schedules that need explicit review")
        XCTAssertThrowsError(try HostDatabaseRestore.restore(backupURL: backup, currentURL: current)) {
            XCTAssertTrue(String(describing: $0).contains("explicit review"), "\($0)")
        }
        XCTAssertThrowsError(try HostDatabaseRestore.restore(backupURL: backup, currentURL: current, reviewToken: review.fingerprint)) {
            XCTAssertTrue(String(describing: $0).contains("foreign key check failed"), "\($0)")
        }
        let afterDB = try SQLiteDB(path: current.path)
        XCTAssertEqual(try count(afterDB, "agent_runs"), expectedRuns)
        XCTAssertEqual(try count(afterDB, "bots"), expectedBots)
        for table in Self.authorityTables { XCTAssertEqual(try count(afterDB, table), 0) }
    }

    /// With the unknown objects and the orphan rows removed from the sandbox copy, the real data
    /// restores completely and no authority is invented for a pre-contextual host.
    func test_restoreOfCleanedRealCopyKeepsDataAndInventsNoAuthority() throws {
        let backup = try trimmedCopy(of: try realCopy(), name: "backup-cleaned.sqlite")
        do {
            let db = try SQLiteDB(path: backup.path)
            for _ in 0..<5 {
                var orphans: [(String, Int64)] = []
                let check = try db.prepare("PRAGMA foreign_key_check;")
                while try check.step() { orphans.append((check.columnText(0) ?? "", check.columnInt64(1))) }
                check.reset()
                if orphans.isEmpty { break }
                for (table, rowid) in orphans { try db.execute("DELETE FROM \"\(table)\" WHERE rowid=\(rowid);") }
            }
            let verify = try db.prepare("PRAGMA foreign_key_check;")
            defer { verify.reset() }
            XCTAssertFalse(try verify.step(), "sandbox copy must be free of orphan rows")
        }
        let current = try prepare(backup)
        defer { try? FileManager.default.removeItem(at: current) }
        let backupBytes = try Data(contentsOf: backup)

        let review = try HostDatabaseRestore.inspect(backupURL: backup)
        XCTAssertEqual(review.schemaVersion, 93, "the real copy predates contextual workspaces")
        let before = try SQLiteDB(path: backup.path, readonly: true)
        var expected: [String: Int64] = [:]
        for table in Self.tables { expected[table] = try count(before, table) }
        XCTAssertGreaterThan(expected["bots"] ?? 0, 0, "fixture must contain real bots")
        XCTAssertGreaterThan(expected["agent_runs"] ?? 0, 0, "fixture must contain real run history")

        let recovery = try HostDatabaseRestore.restore(backupURL: backup, currentURL: current, reviewToken: review.requiresConfirmation ? review.fingerprint : nil)

        let after = try SQLiteDB(path: current.path, readonly: true)
        for table in Self.tables {
            XCTAssertEqual(try count(after, table), expected[table], "\(table) lost or gained rows through restore")
        }
        for table in Self.authorityTables {
            XCTAssertEqual(try count(after, table), 0, "restore must not create \(table) rows for a pre-contextual host")
        }
        let recovered = try SQLiteDB(path: recovery.path, readonly: true)
        XCTAssertEqual(try count(recovered, "bots"), expected["bots"], "pre-restore recovery copy must hold the replaced state")
        XCTAssertEqual(try Data(contentsOf: backup), backupBytes, "backup must stay untouched")
        let mode = try FileManager.default.attributesOfItem(atPath: recovery.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertFalse(try directoryNames(backup).contains { $0.hasPrefix(".restore-stage-") })
    }
}
