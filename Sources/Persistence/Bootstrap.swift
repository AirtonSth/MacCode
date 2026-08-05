import Foundation
import CoreModel
import os

private let forkIntentMaintenanceLog = Logger(
    subsystem: "io.remotecode.persistence",
    category: "fork-intent-maintenance"
)

struct ForkIntentMaintenanceReceipt: Equatable, Sendable {
    let batchCount: Int
    let remainingCandidateCount: Int
    let durationMilliseconds: Int
    let errorKind: String?
}

private final class ForkIntentMaintenanceLoop: SQLiteDBOwnedMaintenance, @unchecked Sendable {
    private weak var db: SQLiteDB?
    private let beforeBatch: (@Sendable () -> Void)?
    private let receiptHandler: (@Sendable (ForkIntentMaintenanceReceipt) -> Void)?
    private let retryDelayOverrideNanoseconds: UInt64?
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(
        db: SQLiteDB,
        beforeBatch: (@Sendable () -> Void)?,
        receiptHandler: (@Sendable (ForkIntentMaintenanceReceipt) -> Void)?,
        retryDelayOverrideNanoseconds: UInt64?
    ) {
        self.db = db
        self.beforeBatch = beforeBatch
        self.receiptHandler = receiptHandler
        self.retryDelayOverrideNanoseconds = retryDelayOverrideNanoseconds
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }
        task = Task.detached(priority: .utility) { [weak self] in
            await self?.run()
        }
    }

    func cancel() {
        lock.lock()
        let task = task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }

    private func run() async {
        defer { clearTask() }
        var retryDelayNanoseconds: UInt64 = 10_000_000
        while !Task.isCancelled {
            beforeBatch?()
            guard !Task.isCancelled, let receipt = performBatch() else { return }
            emit(receipt)
            if receipt.errorKind == nil {
                retryDelayNanoseconds = 10_000_000
                guard receipt.remainingCandidateCount > 0 else { return }
                await Task.yield()
            } else {
                let delay = retryDelayOverrideNanoseconds ?? retryDelayNanoseconds
                try? await Task.sleep(nanoseconds: delay)
                retryDelayNanoseconds = min(retryDelayNanoseconds * 2, 1_000_000_000)
            }
        }
    }

    private func clearTask() {
        lock.lock()
        task = nil
        lock.unlock()
    }

    /// The only scope that promotes the weak connection to a strong reference.
    /// It is synchronous, so SQLiteDB cannot deinitialize during a batch and no
    /// connection reference can cross the loop's yield or retry sleep.
    private func performBatch() -> ForkIntentMaintenanceReceipt? {
        guard let db else { return nil }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        do {
            let batch = try AgentThreadRepository(db: db).maintainHistoricalForkIntents()
            let receipt = ForkIntentMaintenanceReceipt(
                batchCount: batch.processedCount,
                remainingCandidateCount: batch.remainingCandidateCount,
                durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                errorKind: nil
            )
            if batch.remainingCandidateCount == 0 {
                db.releaseOwnedMaintenance(self)
            }
            return receipt
        } catch {
            let remaining = (try? AgentThreadRepository(db: db)
                .historicalForkIntentMaintenanceCandidateCount()) ?? -1
            return ForkIntentMaintenanceReceipt(
                batchCount: 0,
                remainingCandidateCount: remaining,
                durationMilliseconds: Self.elapsedMilliseconds(since: startedAt),
                errorKind: String(describing: type(of: error))
            )
        }
    }

    private func emit(_ receipt: ForkIntentMaintenanceReceipt) {
        receiptHandler?(receipt)
        if let errorKind = receipt.errorKind {
            forkIntentMaintenanceLog.error(
                "batch_count=\(receipt.batchCount, privacy: .public) remaining_candidate_count=\(receipt.remainingCandidateCount, privacy: .public) duration_ms=\(receipt.durationMilliseconds, privacy: .public) error_kind=\(errorKind, privacy: .public)"
            )
        } else {
            forkIntentMaintenanceLog.info(
                "batch_count=\(receipt.batchCount, privacy: .public) remaining_candidate_count=\(receipt.remainingCandidateCount, privacy: .public) duration_ms=\(receipt.durationMilliseconds, privacy: .public)"
            )
        }
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Int {
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return Int(elapsed / 1_000_000)
    }
}

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
    var beforeSchemaMigrationForTesting: ((SQLiteDB) throws -> Void)?
    var beforeForkIntentMaintenanceBatchForTesting: (@Sendable () -> Void)?
    var forkIntentMaintenanceReceiptForTesting: (@Sendable (ForkIntentMaintenanceReceipt) -> Void)?
    var forkIntentMaintenanceRetryDelayNanosecondsForTesting: UInt64?

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
        try db.enableFullDurability()
        try beforeSchemaMigrationForTesting?(db)
        try Schema.migrate(db)
        try CommandReceiptRepository(db: db).recoverInterruptedClaims()
        try initDefaults(db: db)
        let maintenance = ForkIntentMaintenanceLoop(
            db: db,
            beforeBatch: beforeForkIntentMaintenanceBatchForTesting,
            receiptHandler: forkIntentMaintenanceReceiptForTesting,
            retryDelayOverrideNanoseconds: forkIntentMaintenanceRetryDelayNanosecondsForTesting
        )
        if db.installOwnedMaintenance(maintenance) {
            maintenance.start()
        }
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
