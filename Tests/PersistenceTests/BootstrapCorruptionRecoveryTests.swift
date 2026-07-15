import XCTest
@testable import Persistence
import CoreModel

final class BootstrapCorruptionRecoveryTests: XCTestCase {
    func test_runHardensAppSupportAndSQLiteFamilyPermissions() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2SecureBootstrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o777]
        )
        defer { try? FileManager.default.removeItem(at: support) }

        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: support.path).run()
        try SettingsRepository(db: db).set("security.permission_probe", "written")

        XCTAssertEqual(try permissions(at: support.path), 0o700,
                       "App Support contains credentials and must not be traversable by other users")
        for suffix in ["", "-wal", "-shm"] {
            let path = support.appendingPathComponent("remotecode.sqlite").path + suffix
            XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                          "the live SQLite \(suffix.isEmpty ? "database" : suffix) file must exist before its mode is asserted")
            XCTAssertEqual(try permissions(at: path), 0o600,
                           "the SQLite database family must remain owner-readable and owner-writable only")
        }
    }

    // The corrupt-backup name helper must move the db AND its -wal/-shm siblings so
    // a half-written WAL cannot be reattached to the fresh DB and re-corrupt it.
    func test_corruptBackupNames_mapsDbWalShmToTimestampedBackups() {
        let dbPath = "/var/data/remotecode.sqlite"
        let names = Bootstrap.corruptBackupNames(dbPath: dbPath, timestamp: "20260609T120000Z")

        let expected: [(String, String)] = [
            ("/var/data/remotecode.sqlite",
             "/var/data/remotecode.sqlite.corrupt-20260609T120000Z"),
            ("/var/data/remotecode.sqlite-wal",
             "/var/data/remotecode.sqlite-wal.corrupt-20260609T120000Z"),
            ("/var/data/remotecode.sqlite-shm",
             "/var/data/remotecode.sqlite-shm.corrupt-20260609T120000Z")
        ]
        XCTAssertEqual(names.count, expected.count,
                       "backup helper must cover the db plus its WAL/SHM siblings so corruption is fully quarantined")
        for (got, want) in zip(names, expected) {
            XCTAssertEqual(got.original, want.0)
            XCTAssertEqual(got.backup, want.1,
                           "each quarantined file must get a .corrupt-<timestamp> backup name")
        }
    }

    // A deliberately corrupt DB must not brick the app: bootstrap renames the bad
    // file to a .corrupt-<ts> backup, recreates a fresh DB, and signals recovery so
    // the app can surface a "previous data backed up" dialog instead of terminating.
    func test_run_corruptDatabase_backsUpAndRecreatesFreshAndSignalsRecovery() throws {
        let tmp = NSTemporaryDirectory() + "RC2CorruptRecover-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let dbPath = (tmp as NSString).appendingPathComponent("remotecode.sqlite")

        // Write a file that is NOT a valid SQLite database. sqlite3_open with
        // OPEN_READWRITE succeeds lazily, but the first PRAGMA/migrate fails loud.
        try Data("this is not a sqlite file, it is corrupted garbage".utf8)
            .write(to: URL(fileURLWithPath: dbPath))

        let bs = Bootstrap(channel: .debug, dbPathOverride: dbPath)
        let (report, db) = try bs.run()

        XCTAssertTrue(report.recoveredFromCorruption,
                      "corrupt DB recovery must be signalled in the report so the app can tell the user their old data was backed up, not silently lost")

        // The corrupt original was quarantined under a .corrupt-* name (not deleted).
        let backups = try FileManager.default.contentsOfDirectory(atPath: tmp)
            .filter { $0.hasPrefix("remotecode.sqlite.corrupt-") }
        XCTAssertEqual(backups.count, 1,
                       "corrupt DB must be renamed to a single timestamped backup so users can attempt manual salvage")

        // The fresh DB is real and usable: schema migrated and defaults written.
        let version = try db.prepare("SELECT MAX(version) FROM schema_meta;")
        XCTAssertTrue(try version.step())
        XCTAssertEqual(Int(version.columnInt64(0)), Schema.currentVersion,
                       "after corruption recovery the recreated DB must be fully migrated, not a half-open handle")
        XCTAssertEqual(try SettingsRepository(db: db).get("remote_access_enabled"), "0",
                       "recovered fresh DB must run initDefaults so the app boots into a known-safe state")
    }

    // WHY: quarantine+recreate wipes device_trust (every paired iPhone gets
    // 401 "Not authorized") and the server identity. Only genuine corruption
    // may pay that price. A write failure that is NOT corruption — here a
    // read-only DB file, the same class as a locked DB or a failed migration
    // step — must propagate as an error and leave the healthy data untouched.
    func test_run_nonCorruptionFailure_doesNotWipeHealthyDatabase() throws {
        let tmp = NSTemporaryDirectory() + "RC2ReadonlyBoot-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let dbPath = (tmp as NSString).appendingPathComponent("remotecode.sqlite")

        // Healthy DB with a paired device the wipe would destroy. Scoped so
        // the connection deinits (closes) before the file goes read-only.
        try autoreleasepool {
            let (_, db) = try Bootstrap(channel: .debug, dbPathOverride: dbPath).run()
            let repo = DeviceTrustRepository(db: db)
            let code = try repo.createPairingCode()
            _ = try XCTUnwrap(try repo.redeemPairingCode(code.code, deviceName: "phone"))
        }

        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o400)],
                                              ofItemAtPath: dbPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                                       ofItemAtPath: dbPath) }

        XCTAssertThrowsError(try Bootstrap(channel: .debug, dbPathOverride: dbPath).run(),
                             "a non-corruption open/write failure must fail loudly, not silently recreate")

        let backups = try FileManager.default.contentsOfDirectory(atPath: tmp)
            .filter { $0.contains(".corrupt-") }
        XCTAssertTrue(backups.isEmpty,
                      "healthy data must never be quarantined for a non-corruption failure")

        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                              ofItemAtPath: dbPath)
        let (report, reopened) = try Bootstrap(channel: .debug, dbPathOverride: dbPath).run()
        XCTAssertFalse(report.recoveredFromCorruption)
        XCTAssertEqual(try DeviceTrustRepository(db: reopened).list().count, 1,
                       "the paired device must survive the failed launch untouched")
    }

    // WHY: legacy (pre-33) builds could write duplicate event seq rows. The
    // step-33 UNIQUE index would then fail the whole migration on upgrade —
    // and a failed migration must never cost the user their paired devices.
    // The real step-33 SQL must dedupe first (keeping the oldest row per seq)
    // so the index always builds.
    func test_schemaStep33_dedupesLegacyDuplicateSeqRows() throws {
        let tmp = NSTemporaryDirectory() + "RC2Step33-" + UUID().uuidString + ".sqlite"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let db = try SQLiteDB(path: tmp)

        // Minimal legacy shape: the tables step 33 touches, with duplicates.
        let legacy = SchemaStep(1, """
        CREATE TABLE events (seq INTEGER, kind TEXT);
        CREATE TABLE command_receipts (method TEXT NOT NULL, client_request_id TEXT NOT NULL,
                                       PRIMARY KEY(method, client_request_id));
        INSERT INTO events(seq, kind) VALUES (1, 'old-a'), (2, 'old-b'), (2, 'dup-newer'), (3, 'old-c');
        """)
        let step33 = try XCTUnwrap(Schema.steps.first { $0.version == 33 },
                                   "production must keep a step 33 for this scenario")
        try Schema.migrateSteps(db, [legacy, step33])

        let rows = try db.prepare("SELECT seq, kind FROM events ORDER BY seq;")
        var kept: [String] = []
        while try rows.step() { kept.append(rows.columnText(1) ?? "") }
        XCTAssertEqual(kept, ["old-a", "old-b", "old-c"],
                       "step 33 must keep the oldest row per seq and drop later duplicates so the UNIQUE index builds")
    }

    // The normal (healthy) open path must be untouched: no backup files, no
    // corruption flag, and firstRun semantics preserved.
    func test_run_healthyDatabase_doesNotTriggerCorruptionPath() throws {
        let tmp = NSTemporaryDirectory() + "RC2HealthyBoot-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let (report, _) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()

        XCTAssertFalse(report.recoveredFromCorruption,
                       "a fresh healthy bootstrap must not be misreported as corruption recovery")
        XCTAssertTrue(report.firstRun)
        let backups = try FileManager.default.contentsOfDirectory(atPath: tmp)
            .filter { $0.contains(".corrupt-") }
        XCTAssertTrue(backups.isEmpty,
                      "healthy open path must never create corrupt-backup files")
    }

    private func permissions(at path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
