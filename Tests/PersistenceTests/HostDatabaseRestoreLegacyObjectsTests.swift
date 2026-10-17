import Foundation
import XCTest
@testable import Persistence

/// Backups written by builds that still carried display-cache tables, and databases holding rows
/// whose parent was deleted, must restore without silent loss and without widening what restore accepts.
final class HostDatabaseRestoreLegacyObjectsTests: XCTestCase {
    private let legacyDDL = """
        CREATE TABLE agent_message_outbound_payloads (
            message_id TEXT PRIMARY KEY NOT NULL,
            thread_id TEXT NOT NULL,
            outbound_text TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(message_id) REFERENCES agent_messages(id) ON DELETE CASCADE,
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        CREATE INDEX idx_agent_message_outbound_payloads_thread
            ON agent_message_outbound_payloads(thread_id, created_at);
        CREATE TABLE agent_message_display_translations (
            message_id TEXT PRIMARY KEY NOT NULL,
            thread_id TEXT NOT NULL,
            wire_sha256 TEXT NOT NULL,
            display_text TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(message_id) REFERENCES agent_messages(id) ON DELETE CASCADE,
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        CREATE INDEX idx_agent_message_display_translations_thread
            ON agent_message_display_translations(thread_id, created_at);
        CREATE TABLE agent_timeline_display_translations (
            owner_kind TEXT NOT NULL,
            owner_id TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            wire_sha256 TEXT NOT NULL,
            display_text TEXT NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY(thread_id, owner_kind, owner_id),
            FOREIGN KEY(thread_id) REFERENCES agent_threads(id) ON DELETE CASCADE
        );
        CREATE INDEX idx_agent_timeline_display_translations_thread
            ON agent_timeline_display_translations(thread_id, created_at);
        """

    private let thread = "11111111-1111-4111-8111-111111111111"
    private let lostThread = "22222222-2222-4222-8222-222222222222"

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HostRestoreLegacy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func count(_ db: SQLiteDB, _ table: String) throws -> Int64 {
        let statement = try db.prepare("SELECT COUNT(*) FROM \(table);")
        defer { statement.reset() }
        XCTAssertTrue(try statement.step())
        return statement.columnInt64(0)
    }

    /// Writes a current database and a backup that carries the legacy tables, one kept row in each,
    /// and optionally one orphan message and one orphan translation whose parent thread is gone.
    private func makePair(_ root: URL, withOrphans: Bool, legacyTables: Bool = true) throws -> (backup: URL, current: URL) {
        let current = root.appendingPathComponent("current.sqlite")
        try Schema.migrate(SQLiteDB(path: current.path))
        let source = try SQLiteDB(path: root.appendingPathComponent("source.sqlite").path)
        try Schema.migrate(source)
        if legacyTables { try source.execute(legacyDDL) }
        try source.execute("""
            INSERT INTO agent_threads(id,title,provider,model,status,created_at,updated_at) VALUES('\(thread)','kept','distill','test','completed','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');
            INSERT INTO agent_messages(id,thread_id,role,content,created_at) VALUES('m-kept','\(thread)','user','hello','2026-01-01T00:00:00Z');
            """)
        if legacyTables {
            try source.execute("""
                INSERT INTO agent_message_display_translations VALUES('m-kept','\(thread)','sha','olá','2026-01-01T00:00:00Z');
                INSERT INTO agent_message_outbound_payloads VALUES('m-kept','\(thread)','wire hello','2026-01-01T00:00:00Z');
                INSERT INTO agent_timeline_display_translations VALUES('tool','t1','\(thread)','sha','feito','2026-01-01T00:00:00Z');
                """)
        }
        if withOrphans {
            try source.execute("PRAGMA foreign_keys=OFF;")
            try source.execute("INSERT INTO agent_messages(id,thread_id,role,content,created_at) VALUES('m-orphan','\(lostThread)','user','lost parent','2026-01-01T00:00:00Z');")
            if legacyTables {
                try source.execute("INSERT INTO agent_message_display_translations VALUES('m-orphan','\(lostThread)','sha','perdido','2026-01-01T00:00:00Z');")
            }
        }
        let backup = root.appendingPathComponent("backup.sqlite")
        let target = try SQLiteDB(path: backup.path)
        try source.backup(to: target)
        return (backup, current)
    }

    func testLegacyDisplayTablesAreAcceptedAndCarriedOver() throws {
        let root = try makeRoot()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let pair = try makePair(root, withOrphans: false)
        let review = try HostDatabaseRestore.inspect(backupURL: pair.backup)
        XCTAssertFalse(review.requiresConfirmation)
        _ = try HostDatabaseRestore.restore(backupURL: pair.backup, currentURL: pair.current)
        let after = try SQLiteDB(path: pair.current.path)
        for table in ["agent_message_display_translations", "agent_message_outbound_payloads", "agent_timeline_display_translations"] {
            XCTAssertEqual(try count(after, table), 1, "\(table) must be carried over, not dropped")
        }
        XCTAssertEqual(try count(after, "agent_messages"), 1)
    }

    func testAlteredLegacyTableIsStillRefused() throws {
        let root = try makeRoot()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let pair = try makePair(root, withOrphans: false)
        let source = try SQLiteDB(path: pair.backup.path)
        try source.execute("ALTER TABLE agent_message_display_translations ADD COLUMN smuggled TEXT;")
        XCTAssertThrowsError(try HostDatabaseRestore.restore(backupURL: pair.backup, currentURL: pair.current)) {
            XCTAssertTrue(String(describing: $0).contains("exact trusted database schema"), "\($0)")
        }
        XCTAssertEqual(try count(SQLiteDB(path: pair.current.path), "agent_messages"), 0, "current database must be untouched")
    }

    func testOrphanRowsRefuseByDefaultAndNameTheTables() throws {
        let root = try makeRoot()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let pair = try makePair(root, withOrphans: true)
        XCTAssertThrowsError(try HostDatabaseRestore.restore(backupURL: pair.backup, currentURL: pair.current)) {
            let message = String(describing: $0)
            XCTAssertTrue(message.contains("foreign key check failed"), message)
            XCTAssertTrue(message.contains("agent_messages=1"), message)
        }
        XCTAssertEqual(try count(SQLiteDB(path: pair.current.path), "agent_messages"), 0)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".restore-") }
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }

    func testOptInQuarantineKeepsEveryOrphanAsideAndRestoresTheRest() throws {
        let root = try makeRoot()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let pair = try makePair(root, withOrphans: true)
        let recovery = try HostDatabaseRestore.restore(backupURL: pair.backup, currentURL: pair.current, quarantineOrphans: true)
        let after = try SQLiteDB(path: pair.current.path)
        XCTAssertEqual(try count(after, "agent_messages"), 1, "only the message with a parent stays")
        XCTAssertEqual(try count(after, "agent_message_display_translations"), 1)
        XCTAssertEqual(try count(after, "agent_threads"), 1)
        let quarantineURL = HostDatabaseRestore.quarantineURL(forRecovery: recovery)
        let quarantine = try SQLiteDB(path: quarantineURL.path, readonly: true)
        XCTAssertEqual(try count(quarantine, "agent_messages"), 1, "orphan message saved, not dropped")
        XCTAssertEqual(try count(quarantine, "agent_message_display_translations"), 1, "orphan translation saved, not dropped")
        let mode = try FileManager.default.attributesOfItem(atPath: quarantineURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let check = try after.prepare("PRAGMA foreign_key_check;")
        defer { check.reset() }
        XCTAssertFalse(try check.step(), "restored database must be consistent")
    }

    func testQuarantineOptionIsInertWhenThereAreNoOrphans() throws {
        let root = try makeRoot()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let pair = try makePair(root, withOrphans: false)
        let recovery = try HostDatabaseRestore.restore(backupURL: pair.backup, currentURL: pair.current, quarantineOrphans: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: HostDatabaseRestore.quarantineURL(forRecovery: recovery).path))
    }
}
