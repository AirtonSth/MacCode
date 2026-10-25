import Foundation
import CoreModel

/// Uses the existing transactional settings table; only non-secret connection metadata is serialized.
public final class ConnectionStore: @unchecked Sendable {
    public static let storageKey = "app_connections_v1"
    private let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }
    public func list() throws -> [AppConnection] {
        guard let raw = try SettingsRepository(db: db).get(Self.storageKey) else { return [] }
        guard let data = raw.data(using: .utf8), let connections = try? JSONDecoder().decode([AppConnection].self, from: data) else { throw ConnectionError.storage }
        return connections
    }
    /// A task grant belongs only to its exact live occurrence, never another run reusing that thread.
    public func scheduledTaskID(forThreadID threadID: AgentThreadID, activeRunID: AgentRunID) throws -> String? {
        guard let occurrence = try ScheduledTaskStore(db: db).activeRun(forThreadID: threadID), occurrence.agentRunID == activeRunID else { return nil }
        return occurrence.taskID.uuidString.lowercased()
    }
    public func get(_ id: UUID) throws -> AppConnection? { try list().first { $0.id == id } }
    public func save(_ connection: AppConnection, expectedRevision: Int? = nil) throws {
        try connection.validate()
        try db.transaction {
            var all = try list()
            if let index = all.firstIndex(where: { $0.id == connection.id }) {
                if let expectedRevision, all[index].revision != expectedRevision { throw ConnectionError.stale }
                var next = connection; next.revision = all[index].revision + 1
                all[index] = next
            } else {
                guard expectedRevision == nil else { throw ConnectionError.stale }
                all.append(connection)
            }
            try write(all)
        }
    }
    public func disconnect(_ id: UUID) throws {
        try db.transaction {
            var all = try list()
            guard let index = all.firstIndex(where: { $0.id == id }) else { throw ConnectionError.unavailable }
            all[index].status = .disconnected; all[index].testedAt = nil; all[index].revision += 1
            try write(all)
        }
    }
    public func markTest(_ id: UUID, revision: Int, success: Bool) throws {
        try db.transaction {
            var all = try list()
            guard let index = all.firstIndex(where: { $0.id == id }), all[index].revision == revision else { throw ConnectionError.stale }
            all[index].status = success ? .tested : .unavailable
            all[index].testedAt = success ? Date() : nil
            all[index].revision += 1
            try write(all)
        }
    }
    private func write(_ values: [AppConnection]) throws {
        guard let raw = String(data: try JSONEncoder().encode(values), encoding: .utf8) else { throw ConnectionError.storage }
        try SettingsRepository(db: db).set(Self.storageKey, raw)
    }
}
