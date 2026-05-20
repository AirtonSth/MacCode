import Foundation

/// User-tunable preferences (t3code client-settings parity). Persisted as
/// one JSON blob in the `settings` kv table so adding a field never needs
/// a migration. Defaults are the V1 behaviour, so an absent/garbled blob
/// degrades safely.
public struct AppSettings: Codable, Sendable, Equatable {
    public var diffWordWrap: Bool
    public var diffIgnoreWhitespace: Bool
    /// "updated" | "created" | "manual" — sidebar workspace ordering.
    public var sidebarSort: String

    public init(diffWordWrap: Bool = false,
                diffIgnoreWhitespace: Bool = false,
                sidebarSort: String = "updated") {
        self.diffWordWrap = diffWordWrap
        self.diffIgnoreWhitespace = diffIgnoreWhitespace
        self.sidebarSort = sidebarSort
    }
}

public final class SettingsStore {
    private let repo: SettingsRepository
    private let key = "app_settings"
    public init(db: SQLiteDB) { self.repo = SettingsRepository(db: db) }

    public func load() -> AppSettings {
        guard let json = try? repo.get(key), let data = json.data(using: .utf8),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return s
    }

    public func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings),
              let json = String(data: data, encoding: .utf8) else { return }
        try? repo.set(key, json)
    }

    /// Read-modify-write a single field without clobbering the others.
    public func update(_ mutate: (inout AppSettings) -> Void) {
        var s = load(); mutate(&s); save(s)
    }
}
