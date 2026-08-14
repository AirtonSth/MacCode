import Foundation
import CoreModel

// MARK: - SettingsCache

/// Thread-safe in-memory cache for one AppSettings value.
/// get/set/invalidate are the only surface; no MainActor required.
final class SettingsCache: @unchecked Sendable {
    private var value: AppSettings?
    private var lock = NSLock()

    func get() -> AppSettings? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ v: AppSettings) {
        lock.lock(); defer { lock.unlock() }
        value = v
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        value = nil
    }
}

// MARK: - AppSettings

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
    /// Global kill switch for automatic scheduled-task occurrences. When false,
    /// due ticks do not claim or run tasks (travel / temporary pause). Per-task
    /// Pause still applies independently. Default true.
    public var scheduledTasksActive: Bool
    /// Base terminal font size in points. 0 means use Ghostty's configured default.
    public var terminalFontSize: Double
    /// P5 SessionLearn: mine a correction rule from failed/expensive runs into the managed
    /// instructions region. Off by default — opt-in, since it writes to CLAUDE.md/AGENTS.md.
    public var sessionLearnEnabled: Bool
    /// P3: compact large tool output in persisted stream events (CCR-backed, structure-
    /// preserving). Off by default — opt-in, since it makes stored history lossy-recoverable.
    public var historyCompactionEnabled: Bool

    /// Graphify host integration (external CLI). Preference on by default, but
    /// runtime is gated by Token Saver — see `isGraphifyRuntimeActive`.
    public var graphifyEnabled: Bool
    /// Absolute path to `graphify` binary (GUI PATH bypass). Empty = auto-resolve.
    public var graphifyBinaryPath: String
    /// Fire-and-forget ensure on resolve when Graphify runtime is active.
    public var graphifyAutoEnsure: Bool
    /// Absolute paths of pinned multi-repo roots for sticky bootstrap (JSON array stored as joined newlines).
    public var graphifyPinnedRoots: [String]
    /// When true, also write `graphify-out/` inside the user's repo. Default false:
    /// graphs live only under Application Support (no workspace pollution).
    public var graphifyWriteInRepo: Bool

    /// Host Graphify preflight/ensure/env/prompt injection is a Token Saver
    /// capability: both toggles must be on. Fail-open when Token Saver is off
    /// (no RC_GRAPHIFY_*, no ensure, no query-first nudge).
    public var isGraphifyRuntimeActive: Bool {
        tokenSaverEnabled && graphifyEnabled
    }

    /// Floating desktop pet. On by default so it is visible without setup.
    public var petEnabled: Bool
    public var petAnimationsEnabled: Bool
    public var petReadyCounterEnabled: Bool
    /// "bottomRight" | "bottomLeft" | "free".
    public var petPosition: String
    /// Display scale multiplier: 0.75, 1, 1.25, or 1.5.
    public var petSize: Double
    /// "all" | "completed" | "needsYou".
    public var petAttentionFilter: String
    /// App override may only reduce motion beyond the system preference.
    public var petReduceMotion: Bool

    public init(diffWordWrap: Bool = false,
                diffIgnoreWhitespace: Bool = false,
                sidebarSort: String = "updated",
                insomniaEnabled: Bool = false,
                insomniaAllowDisplaySleep: Bool = true,
                insomniaAllowSystemSleepWhenDisplayClosed: Bool = false,
                insomniaAllowScreenSaverAfter45MinutesOfInactivity: Bool = true,
                tokenSaverEnabled: Bool = false,
                scheduledTasksActive: Bool = true,
                terminalFontSize: Double = 0,
                sessionLearnEnabled: Bool = false,
                historyCompactionEnabled: Bool = false,
                graphifyEnabled: Bool = true,
                graphifyBinaryPath: String = "",
                graphifyAutoEnsure: Bool = true,
                graphifyPinnedRoots: [String] = [],
                graphifyWriteInRepo: Bool = false,
                petEnabled: Bool = true,
                petAnimationsEnabled: Bool = true,
                petReadyCounterEnabled: Bool = true,
                petPosition: String = "bottomRight",
                petSize: Double = 1.5,
                petAttentionFilter: String = "all",
                petReduceMotion: Bool = false) {
        self.diffWordWrap = diffWordWrap
        self.diffIgnoreWhitespace = diffIgnoreWhitespace
        self.sidebarSort = sidebarSort
        self.insomniaEnabled = insomniaEnabled
        self.insomniaAllowDisplaySleep = insomniaAllowDisplaySleep
        self.insomniaAllowSystemSleepWhenDisplayClosed = insomniaAllowSystemSleepWhenDisplayClosed
        self.insomniaAllowScreenSaverAfter45MinutesOfInactivity = insomniaAllowScreenSaverAfter45MinutesOfInactivity
        self.tokenSaverEnabled = tokenSaverEnabled
        self.scheduledTasksActive = scheduledTasksActive
        self.terminalFontSize = terminalFontSize
        self.sessionLearnEnabled = sessionLearnEnabled
        self.historyCompactionEnabled = historyCompactionEnabled
        self.graphifyEnabled = graphifyEnabled
        self.graphifyBinaryPath = graphifyBinaryPath
        self.graphifyAutoEnsure = graphifyAutoEnsure
        self.graphifyPinnedRoots = graphifyPinnedRoots
        self.graphifyWriteInRepo = graphifyWriteInRepo
        self.petEnabled = petEnabled
        self.petAnimationsEnabled = petAnimationsEnabled
        self.petReadyCounterEnabled = petReadyCounterEnabled
        self.petPosition = petPosition
        self.petSize = petSize
        self.petAttentionFilter = petAttentionFilter
        self.petReduceMotion = petReduceMotion
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
        case scheduledTasksActive
        case terminalFontSize
        case sessionLearnEnabled
        case historyCompactionEnabled
        case graphifyEnabled
        case graphifyBinaryPath
        case graphifyAutoEnsure
        case graphifyPinnedRoots
        case graphifyWriteInRepo
        case petEnabled
        case petAnimationsEnabled
        case petReadyCounterEnabled
        case petPosition
        case petSize
        case petAttentionFilter
        case petReduceMotion
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
        scheduledTasksActive = try c.decodeIfPresent(Bool.self, forKey: .scheduledTasksActive) ?? true
        terminalFontSize = try c.decodeIfPresent(Double.self, forKey: .terminalFontSize) ?? 0
        sessionLearnEnabled = try c.decodeIfPresent(Bool.self, forKey: .sessionLearnEnabled) ?? false
        historyCompactionEnabled = try c.decodeIfPresent(Bool.self, forKey: .historyCompactionEnabled) ?? false
        graphifyEnabled = try c.decodeIfPresent(Bool.self, forKey: .graphifyEnabled) ?? true
        graphifyBinaryPath = try c.decodeIfPresent(String.self, forKey: .graphifyBinaryPath) ?? ""
        graphifyAutoEnsure = try c.decodeIfPresent(Bool.self, forKey: .graphifyAutoEnsure) ?? true
        graphifyPinnedRoots = try c.decodeIfPresent([String].self, forKey: .graphifyPinnedRoots) ?? []
        graphifyWriteInRepo = try c.decodeIfPresent(Bool.self, forKey: .graphifyWriteInRepo) ?? false
        petEnabled = try c.decodeIfPresent(Bool.self, forKey: .petEnabled) ?? true
        petAnimationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .petAnimationsEnabled) ?? true
        petReadyCounterEnabled = try c.decodeIfPresent(Bool.self, forKey: .petReadyCounterEnabled) ?? true
        petPosition = try c.decodeIfPresent(String.self, forKey: .petPosition) ?? "bottomRight"
        petSize = try c.decodeIfPresent(Double.self, forKey: .petSize) ?? 1.5
        petAttentionFilter = try c.decodeIfPresent(String.self, forKey: .petAttentionFilter) ?? "all"
        petReduceMotion = try c.decodeIfPresent(Bool.self, forKey: .petReduceMotion) ?? false
    }
}

/// Minimal write surface used by SettingsStore. Allows injection of a
/// test double without touching callers that use SettingsRepository directly.
public protocol SettingsWriteRepository {
    func get(_ key: String) throws -> String?
    func set(_ key: String, _ value: String) throws
}

extension SettingsRepository: SettingsWriteRepository {}

protocol SettingsKeyValueRepository: SettingsWriteRepository {
    func delete(key: String) throws
}

extension SettingsRepository: SettingsKeyValueRepository {}

public final class SettingsStore {
    private let repo: any SettingsWriteRepository
    private let key = "app_settings"
    private let cache = SettingsCache()
    // PERF: cache-miss load and every save/update allocated JSONDecoder/
    // JSONEncoder. Concurrent surfaces share stores — serialize under a short
    // lock and reuse one pair (wire JSON formatting unchanged).
    private let codecLock = NSLock()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    /// Called on the calling thread when a user-initiated write fails.
    /// Nil = silent (legacy behaviour, only use for non-user-initiated paths).
    public var onWriteError: ((Error) -> Void)?

    public init(db: SQLiteDB) { self.repo = SettingsRepository(db: db) }

    /// Seam for testing: inject any SettingsWriteRepository.
    init(repo: any SettingsWriteRepository) { self.repo = repo }

    private func loadFromRepository() throws -> AppSettings {
        guard let json = try repo.get(key), let data = json.data(using: .utf8) else {
            return AppSettings()
        }
        codecLock.lock()
        let settings = try? decoder.decode(AppSettings.self, from: data)
        codecLock.unlock()
        return settings ?? AppSettings()
    }

    public func load() -> AppSettings {
        if let cached = cache.get() { return cached }
        let s = (try? loadFromRepository()) ?? AppSettings()
        cache.set(s)
        return s
    }

    public func reload() -> AppSettings {
        cache.invalidate()
        return load()
    }

    public func save(_ settings: AppSettings) {
        codecLock.lock()
        let data = try? encoder.encode(settings)
        codecLock.unlock()
        guard let data,
              let json = String(data: data, encoding: .utf8) else { return }
        do {
            try repo.set(key, json)
            cache.invalidate()
            // Independent SettingsStore instances do not share caches. A
            // process-wide revision lets hot readers (agent item deltas)
            // skip a new store + SQLite load until any instance writes.
            Self.bumpRevision()
        } catch {
            onWriteError?(error)
        }
    }

    private static let revisionLock = NSLock()
    private static var revisionValue: UInt64 = 0

    /// Monotonic write generation. Starts at 0; increments on every successful save.
    public static var revision: UInt64 {
        revisionLock.lock()
        defer { revisionLock.unlock() }
        return revisionValue
    }

    private static func bumpRevision() {
        revisionLock.lock()
        revisionValue &+= 1
        revisionLock.unlock()
    }

    /// Read-modify-write a single field without clobbering the others.
    public func update(_ mutate: (inout AppSettings) -> Void) {
        do {
            // SettingsStore instances have independent caches. Read the canonical
            // row directly so a stale instance cannot resurrect older field values.
            var settings = try loadFromRepository()
            mutate(&settings)
            save(settings)
        } catch {
            // A failed read must not turn into defaults and overwrite valid settings.
            onWriteError?(error)
        }
    }
}

/// Remembers the last model the user selected per provider so new threads
/// reopen on that model instead of a stale built-in default.
public final class AgentLastModelStore: @unchecked Sendable {
    public static let shared = AgentLastModelStore()

    private let defaults: UserDefaults
    private let key = "agent.lastModel.byProvider.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func model(for provider: AgentProvider) -> String? {
        let value = dict()[provider.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    public func remember(model: String, for provider: AgentProvider) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var values = dict()
        values[provider.rawValue] = trimmed
        defaults.set(values, forKey: key)
    }

    private func dict() -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}

public struct AgentNewThreadDefaults: Codable, Sendable, Equatable {
    public var routingMode: AgentRoutingMode
    public var runAsUser: AgentRunAsUser?
    public var provider: AgentProvider
    public var providerInstanceId: String
    public var model: String
    public var reasoningEffort: AgentReasoningEffort

    public init(
        routingMode: AgentRoutingMode,
        runAsUser: AgentRunAsUser?,
        provider: AgentProvider,
        providerInstanceId: String,
        model: String,
        reasoningEffort: AgentReasoningEffort
    ) {
        self.routingMode = routingMode
        self.runAsUser = runAsUser
        self.provider = provider
        self.providerInstanceId = providerInstanceId
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

/// Persists the user's last explicit Agent picker choices so every fresh
/// surface and subsequent thread starts from the same configuration.
public final class AgentNewThreadDefaultsStore: @unchecked Sendable {
    public static let shared = AgentNewThreadDefaultsStore()

    private let defaults: UserDefaults
    private let key = "agent.newThreadDefaults.v1"
    // PERF: load/save allocated JSONDecoder/JSONEncoder per call. Shared
    // process-wide instance; serialize under a short lock (codecs are not
    // thread-safe).
    private let codecLock = NSLock()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AgentNewThreadDefaults? {
        guard let data = defaults.data(forKey: key) else { return nil }
        codecLock.lock()
        let value = try? decoder.decode(AgentNewThreadDefaults.self, from: data)
        codecLock.unlock()
        return value
    }

    public func save(_ value: AgentNewThreadDefaults) {
        codecLock.lock()
        let data = try? encoder.encode(value)
        codecLock.unlock()
        guard let data else { return }
        defaults.set(data, forKey: key)
    }
}

public final class AgentCustomModelStore {
    private let repo: any SettingsWriteRepository
    private let keyPrefix = "agent.custom_models."
    public var onWriteError: ((Error) -> Void)?
    // PERF: list/save allocated JSONDecoder/JSONEncoder per call. Concurrent
    // settings UI / agent surfaces share stores — serialize under a short lock.
    private let codecLock = NSLock()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(repo: SettingsRepository) {
        self.repo = repo
    }

    public init(db: SQLiteDB) {
        self.repo = SettingsRepository(db: db)
    }

    init(repo: any SettingsWriteRepository) {
        self.repo = repo
    }

    public func list(provider: AgentProvider) -> [String] {
        guard let raw = try? repo.get(keyPrefix + provider.rawValue),
              let data = raw.data(using: .utf8) else { return [] }
        codecLock.lock()
        let values = try? decoder.decode([String].self, from: data)
        codecLock.unlock()
        guard let values else { return [] }
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
        codecLock.lock()
        let data = try? encoder.encode(normalized(models))
        codecLock.unlock()
        guard let data,
              let raw = String(data: data, encoding: .utf8) else { return }
        do {
            try repo.set(keyPrefix + provider.rawValue, raw)
        } catch {
            onWriteError?(error)
        }
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
