import Foundation
import CoreModel

public struct BootstrapReport: Equatable {
    public let createdAppSupport: Bool
    public let createdSchema: Bool
    public let schemaVersion: Int
    public let path: String
    public let firstRun: Bool
    public let touchedPaths: [String]
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
        let db = try SQLiteDB(path: dbPath)
        try Schema.migrate(db)
        try initDefaults(db: db)
        return (BootstrapReport(
            createdAppSupport: createdAS,
            createdSchema: firstRun,
            schemaVersion: Schema.currentVersion,
            path: dbPath,
            firstRun: firstRun,
            touchedPaths: touched
        ), db)
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
