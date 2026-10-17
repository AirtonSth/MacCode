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

    /// The real database holds queued work or schedules (explicit review) and rows whose parent
    /// thread no longer exists. Without the quarantine opt-in restore must refuse and change nothing.
    func test_restoreRefusesRealCopyWithOrphanRowsByDefaultAndKeepsCurrentData() throws {
        let backup = try realCopy()
        let current = try prepare(backup)
        defer { try? FileManager.default.removeItem(at: current) }
        let namesBefore = try directoryNames(backup)
        let review = try HostDatabaseRestore.inspect(backupURL: backup)
        XCTAssertEqual(review.schemaVersion, 93, "the real copy is accepted as a trusted version-93 schema")
        XCTAssertTrue(review.requiresConfirmation, "the real host holds queued work or schedules that need explicit review")
        XCTAssertThrowsError(try HostDatabaseRestore.restore(backupURL: backup, currentURL: current)) {
            XCTAssertTrue(String(describing: $0).contains("explicit review"), "\($0)")
        }
        XCTAssertThrowsError(try HostDatabaseRestore.restore(backupURL: backup, currentURL: current, reviewToken: review.fingerprint)) {
            XCTAssertTrue(String(describing: $0).contains("foreign key check failed"), "\($0)")
        }
        let before = try SQLiteDB(path: backup.path)
        let after = try SQLiteDB(path: current.path)
        for table in Self.tables { XCTAssertEqual(try count(after, table), try count(before, table), "\(table) changed by a refused restore") }
        for table in Self.authorityTables {
            XCTAssertThrowsError(try count(after, table), "refused restore must not migrate or create \(table)")
        }
        let created = try directoryNames(backup).subtracting(namesBefore).filter { $0.hasPrefix(".restore-") }
        XCTAssertTrue(created.isEmpty, "refused restore must leave no staging, recovery or quarantine files: \(created)")
    }

    /// With the explicit review fingerprint and the quarantine opt-in, the as-is real copy restores:
    /// every non-orphan row survives, every orphan is saved in the quarantine database, and no
    /// authority is invented for a pre-contextual host.
    func test_restoreOfRealCopyWithQuarantineKeepsDataAndSavesOrphans() throws {
        let backup = try realCopy()
        let current = try prepare(backup)
        defer { try? FileManager.default.removeItem(at: current) }
        let backupBytes = try Data(contentsOf: backup)
        let review = try HostDatabaseRestore.inspect(backupURL: backup)
        let before = try SQLiteDB(path: backup.path)
        var expected: [String: Int64] = [:]
        for table in Self.tables { expected[table] = try count(before, table) }
        XCTAssertGreaterThan(expected["bots"] ?? 0, 0, "fixture must contain real bots")
        XCTAssertGreaterThan(expected["agent_runs"] ?? 0, 0, "fixture must contain real run history")
        var orphansBefore: [String: Int64] = [:]
        do {
            let check = try before.prepare("PRAGMA foreign_key_check;")
            while try check.step() { orphansBefore[check.columnText(0) ?? "", default: 0] += 1 }
            check.reset()
        }
        XCTAssertFalse(orphansBefore.isEmpty, "the real copy is expected to contain orphan rows")

        let recovery = try HostDatabaseRestore.restore(backupURL: backup, currentURL: current, reviewToken: review.fingerprint, quarantineOrphans: true)

        let after = try SQLiteDB(path: current.path)
        let quarantine = try SQLiteDB(path: HostDatabaseRestore.quarantineURL(forRecovery: recovery).path, readonly: true)
        for table in Self.tables where orphansBefore[table] == nil {
            XCTAssertEqual(try count(after, table), expected[table], "\(table) lost or gained rows through restore")
        }
        for (table, orphans) in orphansBefore {
            XCTAssertEqual(try count(after, table) + (try count(quarantine, table)), try count(before, table), "\(table): kept plus quarantined must equal the backup")
            XCTAssertGreaterThanOrEqual(try count(quarantine, table), orphans, "\(table): every orphan must be saved")
        }
        for table in Self.authorityTables {
            XCTAssertEqual(try count(after, table), 0, "restore must not create \(table) rows for a pre-contextual host")
        }
        let check = try after.prepare("PRAGMA foreign_key_check;")
        defer { check.reset() }
        XCTAssertFalse(try check.step(), "restored database must be consistent")
        XCTAssertEqual(try count(SQLiteDB(path: recovery.path, readonly: true), "bots"), expected["bots"], "pre-restore recovery copy must hold the replaced state")
        XCTAssertEqual(try Data(contentsOf: backup), backupBytes, "backup must stay untouched")
        let mode = try FileManager.default.attributesOfItem(atPath: recovery.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertFalse(try directoryNames(backup).contains { $0.hasPrefix(".restore-stage-") })
        for table in ["agent_message_display_translations", "agent_message_outbound_payloads", "agent_timeline_display_translations"] {
            XCTAssertNoThrow(try count(after, table), "legacy table \(table) must be carried over")
        }
    }
}
