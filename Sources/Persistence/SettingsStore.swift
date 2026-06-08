import Foundation
import CoreModel

/// User-tunable preferences (t3code client-settings parity). Persisted as
/// one JSON blob in the `settings` kv table so adding a field never needs
/// a migration. Defaults are the V1 behaviour, so an absent/garbled blob
/// degrades safely.
public struct AppSettings: Codable, Sendable, Equatable {
    public var diffWordWrap: Bool
    public var diffIgnoreWhitespace: Bool
    /// "updated" | "created" | "manual" — sidebar workspace ordering.
    public var sidebarSort: String
    public var insomniaEnabled: Bool
    public var insomniaAllowDisplaySleep: Bool
    public var insomniaAllowSystemSleepWhenDisplayClosed: Bool
    public var insomniaAllowScreenSaverAfter45MinutesOfInactivity: Bool
    public var tokenSaverEnabled: Bool
    /// P5 SessionLearn: mine a correction rule from failed/expensive runs into the managed
    /// instructions region. Off by default — opt-in, since it writes to CLAUDE.md/AGENTS.md.
    public var sessionLearnEnabled: Bool

    public init(diffWordWrap: Bool = false,
                diffIgnoreWhitespace: Bool = false,
                sidebarSort: String = "updated",
                insomniaEnabled: Bool = false,
                insomniaAllowDisplaySleep: Bool = true,
                insomniaAllowSystemSleepWhenDisplayClosed: Bool = false,
                insomniaAllowScreenSaverAfter45MinutesOfInactivity: Bool = true,
                tokenSaverEnabled: Bool = false,
                sessionLearnEnabled: Bool = false) {
        self.diffWordWrap = diffWordWrap
        self.diffIgnoreWhitespace = diffIgnoreWhitespace
        self.sidebarSort = sidebarSort
        self.insomniaEnabled = insomniaEnabled
        self.insomniaAllowDisplaySleep = insomniaAllowDisplaySleep
        self.insomniaAllowSystemSleepWhenDisplayClosed = insomniaAllowSystemSleepWhenDisplayClosed
        self.insomniaAllowScreenSaverAfter45MinutesOfInactivity = insomniaAllowScreenSaverAfter45MinutesOfInactivity
        self.tokenSaverEnabled = tokenSaverEnabled
        self.sessionLearnEnabled = sessionLearnEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case diffWordWrap
        case diffIgnoreWhitespace
        case sidebarSort
        case insomniaEnabled
        case insomniaAllowDisplaySleep
        case insomniaAllowSystemSleepWhenDisplayClosed
        case insomniaAllowScreenSaverAfter45MinutesOfInactivity
        case tokenSaverEnabled
        case sessionLearnEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        diffWordWrap = try c.decodeIfPresent(Bool.self, forKey: .diffWordWrap) ?? false
        diffIgnoreWhitespace = try c.decodeIfPresent(Bool.self, forKey: .diffIgnoreWhitespace) ?? false
        sidebarSort = try c.decodeIfPresent(String.self, forKey: .sidebarSort) ?? "updated"
        insomniaEnabled = try c.decodeIfPresent(Bool.self, forKey: .insomniaEnabled) ?? false
        insomniaAllowDisplaySleep = try c.decodeIfPresent(Bool.self, forKey: .insomniaAllowDisplaySleep) ?? true
        insomniaAllowSystemSleepWhenDisplayClosed = try c.decodeIfPresent(Bool.self, forKey: .insomniaAllowSystemSleepWhenDisplayClosed) ?? false
        insomniaAllowScreenSaverAfter45MinutesOfInactivity = try c.decodeIfPresent(Bool.self, forKey: .insomniaAllowScreenSaverAfter45MinutesOfInactivity) ?? true
        tokenSaverEnabled = try c.decodeIfPresent(Bool.self, forKey: .tokenSaverEnabled) ?? false
        sessionLearnEnabled = try c.decodeIfPresent(Bool.self, forKey: .sessionLearnEnabled) ?? false
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

public final class AgentCustomModelStore {
    private let repo: SettingsRepository
    private let keyPrefix = "agent.custom_models."

    public init(repo: SettingsRepository) {
        self.repo = repo
    }

    public init(db: SQLiteDB) {
        self.repo = SettingsRepository(db: db)
    }

    public func list(provider: AgentProvider) -> [String] {
        guard let raw = try? repo.get(keyPrefix + provider.rawValue),
              let data = raw.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return normalized(values)
    }

    public func add(_ model: String, provider: AgentProvider) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var values = list(provider: provider)
        if !values.contains(trimmed) {
            values.append(trimmed)
        }
        save(values, provider: provider)
    }

    public func update(provider: AgentProvider, index: Int, value: String) {
        var values = list(provider: provider)
        guard values.indices.contains(index) else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            values.remove(at: index)
        } else {
            values[index] = trimmed
        }
        save(values, provider: provider)
    }

    public func remove(provider: AgentProvider, index: Int) {
        var values = list(provider: provider)
        guard values.indices.contains(index) else { return }
        values.remove(at: index)
        save(values, provider: provider)
    }

    private func save(_ models: [String], provider: AgentProvider) {
        guard let data = try? JSONEncoder().encode(normalized(models)),
              let raw = String(data: data, encoding: .utf8) else { return }
        try? repo.set(keyPrefix + provider.rawValue, raw)
    }

    private func normalized(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }
}
