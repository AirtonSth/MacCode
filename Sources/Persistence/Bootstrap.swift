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
        touched.append(supportURL.path)
        let dbPath = dbPathOverride ?? supportURL.appendingPathComponent("remotecode.sqlite").path
        let firstRun = !FileManager.default.fileExists(atPath: dbPath)
        touched.append(dbPath)

        do {
            let db = try openAndMigrate(dbPath: dbPath)
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
        switch error {
        case is SQLiteError, is SchemaError:
            return true
        default:
            return false
        }
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
}
