import Foundation
import CoreModel

public struct BootstrapReport: Equatable {
    public let createdAppSupport: Bool
    public let createdSchema: Bool
    public let schemaVersion: Int
    public let path: String
    public let firstRun: Bool
    public let touchedPaths: [String]
    public let recoveredFromCorruption: Bool

    public init(
        createdAppSupport: Bool,
        createdSchema: Bool,
        schemaVersion: Int,
        path: String,
        firstRun: Bool,
        touchedPaths: [String],
        recoveredFromCorruption: Bool = false
    ) {
        self.createdAppSupport = createdAppSupport
        self.createdSchema = createdSchema
        self.schemaVersion = schemaVersion
        self.path = path
        self.firstRun = firstRun
        self.touchedPaths = touchedPaths
        self.recoveredFromCorruption = recoveredFromCorruption
    }
}

public final class Bootstrap {
    public let channel: ReleaseChannel
    public let dbPathOverride: String?
    public let appSupportOverride: String?

    public init(channel: ReleaseChannel, dbPathOverride: String? = nil, appSupportOverride: String? = nil) {
        self.channel = channel
        self.dbPathOverride = dbPathOverride
        self.appSupportOverride = appSupportOverride
    }

    @discardableResult
    public func run() throws -> (BootstrapReport, SQLiteDB) {
        let supportURL = AppPaths.appSupportDirectory(for: channel, override: appSupportOverride)
        var touched: [String] = []
        var createdAS = false
        if !FileManager.default.fileExists(atPath: supportURL.path) {
            try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
            createdAS = true
        }
        try Self.setPermissions(0o700, at: supportURL.path)
        touched.append(supportURL.path)
        let dbPath = dbPathOverride ?? supportURL.appendingPathComponent("remotecode.sqlite").path
        let firstRun = !FileManager.default.fileExists(atPath: dbPath)
        touched.append(dbPath)

        do {
            let db = try openAndMigrate(dbPath: dbPath)
            try Self.hardenDatabaseFamily(at: dbPath)
            return (BootstrapReport(
                createdAppSupport: createdAS,
                createdSchema: firstRun,
                schemaVersion: Schema.currentVersion,
                path: dbPath,
                firstRun: firstRun,
                touchedPaths: touched,
                recoveredFromCorruption: false
            ), db)
        } catch let error where Bootstrap.isCorruptionFailure(error) {
            // The existing DB (or its WAL/SHM) is unusable. Quarantine the bad files
            // under .corrupt-<ts> names instead of terminating, then recreate fresh so
            // the app can keep running and surface a "previous data backed up" dialog.
            let timestamp = Bootstrap.corruptBackupTimestamp(Date())
            for (original, backup) in Bootstrap.corruptBackupNames(dbPath: dbPath, timestamp: timestamp) {
                if FileManager.default.fileExists(atPath: original) {
                    try? FileManager.default.removeItem(atPath: backup)
                    try FileManager.default.moveItem(atPath: original, toPath: backup)
                }
            }
            let db = try openAndMigrate(dbPath: dbPath)
            try Self.hardenDatabaseFamily(at: dbPath)
            return (BootstrapReport(
                createdAppSupport: createdAS,
                createdSchema: true,
                schemaVersion: Schema.currentVersion,
                path: dbPath,
                firstRun: true,
                touchedPaths: touched,
                recoveredFromCorruption: true
            ), db)
        }
    }

    private func openAndMigrate(dbPath: String) throws -> SQLiteDB {
        let db = try SQLiteDB(path: dbPath)
        try Schema.migrate(db)
        try db.enableFullDurability()
        // Historical terminal rows may predate causal child-delete cleanup.
        // Process only one rechecked batch per launch; recoverable fork evidence
        // is deliberately never eligible for this startup maintenance.
        _ = try AgentThreadRepository(db: db).deleteCausallyRetiredForkIntents()
        try CommandReceiptRepository(db: db).recoverInterruptedClaims()
        try initDefaults(db: db)
        return db
    }

    /// Files to quarantine when the database is corrupt: the db itself plus its
    /// WAL/SHM siblings, each renamed to `<file>.corrupt-<timestamp>`.
    /// Pure helper (no I/O, no Date()) so the naming contract is deterministically testable.
    nonisolated public static func corruptBackupNames(
        dbPath: String,
        timestamp: String
    ) -> [(original: String, backup: String)] {
        [dbPath, dbPath + "-wal", dbPath + "-shm"].map { original in
            (original: original, backup: original + ".corrupt-" + timestamp)
        }
    }

    nonisolated private static func corruptBackupTimestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withTimeZone]
        return f.string(from: date)
    }

    nonisolated private static func isCorruptionFailure(_ error: Error) -> Bool {
        // Quarantine + recreate destroys device_trust tokens and the server
        // identity, so only genuine file-corruption signatures may trigger it.
        // Everything else (locked DB, failed migration step, full disk, missing
        // permissions, schema newer than this build) must propagate loudly
        // instead of silently wiping every paired device.
        guard let sqliteError = error as? SQLiteError else { return false }
        let message = sqliteError.description.lowercased()
        return message.contains("malformed")
            || message.contains("not a database")
            || message.contains("corrupt")
            // Header schema-format number (offset 44) damaged: open succeeds
            // lazily, the first schema read fails SQLITE_ERROR with exactly
            // this text. No supported SQLite writes a format > 4, so this is
            // a pure corruption signature with no false-positive risk.
            || message.contains("unsupported file format")
    }

    private func initDefaults(db: SQLiteDB) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        // ensure singleton selection row
        let s = try db.prepare("INSERT OR IGNORE INTO workspace_selection(id, updated_at) VALUES(1, ?);")
        try s.bind(1, now)
        _ = try s.step()
        // initial settings
        for (k, v) in [
            ("theme", "dark"),
            ("first_run_completed", "0"),
            ("remote_access_enabled", "0"),
            ("provider.default", AgentProvider.codex.rawValue)
        ] {
            let st = try db.prepare("INSERT OR IGNORE INTO settings(key, value, updated_at) VALUES(?, ?, ?);")
            try st.bind(1, k)
            try st.bind(2, v)
            try st.bind(3, now)
            _ = try st.step()
        }
    }

    private static func hardenDatabaseFamily(at databasePath: String) throws {
        for path in [databasePath, databasePath + "-wal", databasePath + "-shm"]
        where FileManager.default.fileExists(atPath: path) {
            try setPermissions(0o600, at: path)
        }
    }

    private static func setPermissions(_ permissions: Int, at path: String) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: path
        )
    }
}
