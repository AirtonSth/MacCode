import Foundation
import CoreModel

public enum TokenSaverPeriod: String, Codable, Sendable, CaseIterable {
    case today
    case sevenDays
    case thirtyDays
}

public struct TokenSaverProviderUsage: Codable, Sendable, Equatable {
    public let provider: AgentProvider
    public var actualProviderTokens: Int
    public var estimatedRawTokens: Int
    public var actualProviderBilledTokenUnits: Double
    public var estimatedRawBilledTokenUnits: Double
    public var eligibleRuns: Int
    public var currentSessionTokens: Int
    public var currentSessionLimitTokens: Int
    public var currentSessionUsedPercent: Double?
    public var currentSessionResetsAt: Date?
    public var weeklyUsedPercent: Double?
    public var weeklyWindowDurationMinutes: Int?
    public var weeklyResetsAt: Date?

    public init(
        provider: AgentProvider,
        actualProviderTokens: Int = 0,
        estimatedRawTokens: Int = 0,
        actualProviderBilledTokenUnits: Double? = nil,
        estimatedRawBilledTokenUnits: Double? = nil,
        eligibleRuns: Int = 0,
        currentSessionTokens: Int = 0,
        currentSessionLimitTokens: Int = 0,
        currentSessionUsedPercent: Double? = nil,
        currentSessionResetsAt: Date? = nil,
        weeklyUsedPercent: Double? = nil,
        weeklyWindowDurationMinutes: Int? = nil,
        weeklyResetsAt: Date? = nil
    ) {
        self.provider = provider
        self.actualProviderTokens = max(0, actualProviderTokens)
        self.estimatedRawTokens = max(0, estimatedRawTokens)
        self.actualProviderBilledTokenUnits = max(0, actualProviderBilledTokenUnits ?? Double(max(0, actualProviderTokens)))
        self.estimatedRawBilledTokenUnits = max(
            self.actualProviderBilledTokenUnits,
            estimatedRawBilledTokenUnits ?? Double(max(0, estimatedRawTokens))
        )
        self.eligibleRuns = max(0, eligibleRuns)
        self.currentSessionTokens = max(0, currentSessionTokens)
        self.currentSessionLimitTokens = max(0, currentSessionLimitTokens)
        self.currentSessionUsedPercent = Self.clampedPercent(currentSessionUsedPercent)
        self.currentSessionResetsAt = currentSessionResetsAt
        self.weeklyUsedPercent = Self.clampedPercent(weeklyUsedPercent)
        self.weeklyWindowDurationMinutes = weeklyWindowDurationMinutes.map { max(0, $0) }
        self.weeklyResetsAt = weeklyResetsAt
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case actualProviderTokens
        case estimatedRawTokens
        case actualProviderBilledTokenUnits
        case estimatedRawBilledTokenUnits
        case eligibleRuns
        case currentSessionTokens
        case currentSessionLimitTokens
        case currentSessionUsedPercent
        case currentSessionResetsAt
        case weeklyUsedPercent
        case weeklyWindowDurationMinutes
        case weeklyResetsAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(AgentProvider.self, forKey: .provider)
        actualProviderTokens = max(0, try container.decodeIfPresent(Int.self, forKey: .actualProviderTokens) ?? 0)
        estimatedRawTokens = max(0, try container.decodeIfPresent(Int.self, forKey: .estimatedRawTokens) ?? 0)
        actualProviderBilledTokenUnits = max(
            0,
            try container.decodeIfPresent(Double.self, forKey: .actualProviderBilledTokenUnits) ?? Double(actualProviderTokens)
        )
        estimatedRawBilledTokenUnits = max(
            actualProviderBilledTokenUnits,
            try container.decodeIfPresent(Double.self, forKey: .estimatedRawBilledTokenUnits) ?? Double(estimatedRawTokens)
        )
        eligibleRuns = max(0, try container.decodeIfPresent(Int.self, forKey: .eligibleRuns) ?? 0)
        currentSessionTokens = max(0, try container.decodeIfPresent(Int.self, forKey: .currentSessionTokens) ?? 0)
        currentSessionLimitTokens = max(0, try container.decodeIfPresent(Int.self, forKey: .currentSessionLimitTokens) ?? 0)
        currentSessionUsedPercent = Self.clampedPercent(try container.decodeIfPresent(Double.self, forKey: .currentSessionUsedPercent))
        currentSessionResetsAt = try container.decodeIfPresent(Date.self, forKey: .currentSessionResetsAt)
        weeklyUsedPercent = Self.clampedPercent(try container.decodeIfPresent(Double.self, forKey: .weeklyUsedPercent))
        weeklyWindowDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .weeklyWindowDurationMinutes).map { max(0, $0) }
        weeklyResetsAt = try container.decodeIfPresent(Date.self, forKey: .weeklyResetsAt)
    }

    public var measuredSavedTokens: Int {
        max(estimatedRawTokens - actualProviderTokens, 0)
    }

    public var measuredSavedBilledTokenUnits: Double {
        max(estimatedRawBilledTokenUnits - actualProviderBilledTokenUnits, 0)
    }

    public var weeklyRemainingPercent: Double? {
        weeklyUsedPercent.map { max(0, 100 - $0) }
    }

    /// Weekly used % for display after applying window expiry.
    /// When `weeklyResetsAt` is in the past the provider window has rolled over —
    /// stale cached percent (e.g. Claude stuck at 45% after the week reset / account
    /// inactive) must read as 0 until a live probe rewrites it.
    public func effectiveWeeklyUsedPercent(now: Date = Date()) -> Double? {
        Self.effectiveWeeklyUsedPercent(
            weeklyUsedPercent: weeklyUsedPercent,
            weeklyResetsAt: weeklyResetsAt,
            now: now
        )
    }

    nonisolated public static func effectiveWeeklyUsedPercent(
        weeklyUsedPercent: Double?,
        weeklyResetsAt: Date?,
        now: Date = Date()
    ) -> Double? {
        guard let weeklyUsedPercent else { return nil }
        if let weeklyResetsAt, weeklyResetsAt <= now { return 0 }
        return weeklyUsedPercent
    }

    /// Session rate-limit % for display after discarding expired / bare-zero noise.
    ///
    /// WHY: account probes and inactive-provider clears often leave
    /// `currentSessionUsedPercent = 0` without a live session window. Treating that
    /// as real data painted every Today ring as "0% used" even when weekly was 84%+.
    /// An unexpired `currentSessionResetsAt` keeps a true mid-window 0%; otherwise
    /// bare zero is treated as missing so the UI can fall back to weekly %.
    public func effectiveSessionUsedPercent(now: Date = Date()) -> Double? {
        Self.effectiveSessionUsedPercent(
            currentSessionUsedPercent: currentSessionUsedPercent,
            currentSessionResetsAt: currentSessionResetsAt,
            now: now
        )
    }

    nonisolated public static func effectiveSessionUsedPercent(
        currentSessionUsedPercent: Double?,
        currentSessionResetsAt: Date?,
        now: Date = Date()
    ) -> Double? {
        guard let currentSessionUsedPercent else { return nil }
        if let currentSessionResetsAt {
            if currentSessionResetsAt <= now { return nil }
            return currentSessionUsedPercent
        }
        if currentSessionUsedPercent <= 0 { return nil }
        return currentSessionUsedPercent
    }

    private static func clampedPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 100)
    }
}

public struct TokenSaverDayUsage: Codable, Sendable, Equatable, Identifiable {
    public let dayStart: Date
    public var actualProviderTokens: Int
    public var estimatedRawTokens: Int
    public var eligibleRuns: Int

    public init(
        dayStart: Date,
        actualProviderTokens: Int = 0,
        estimatedRawTokens: Int = 0,
        eligibleRuns: Int = 0
    ) {
        self.dayStart = dayStart
        self.actualProviderTokens = max(0, actualProviderTokens)
        self.estimatedRawTokens = max(0, estimatedRawTokens)
        self.eligibleRuns = max(0, eligibleRuns)
    }

    public var id: Date { dayStart }

    public var measuredSavedTokens: Int {
        max(estimatedRawTokens - actualProviderTokens, 0)
    }
}

public struct TokenSaverUsageSnapshot: Codable, Sendable, Equatable {
    public let period: TokenSaverPeriod
    public let providers: [TokenSaverProviderUsage]
    public let daily: [TokenSaverDayUsage]

    public init(
        period: TokenSaverPeriod,
        providers: [TokenSaverProviderUsage],
        daily: [TokenSaverDayUsage] = []
    ) {
        self.period = period
        self.providers = providers
        self.daily = daily.sorted { $0.dayStart < $1.dayStart }
    }

    private enum CodingKeys: String, CodingKey {
        case period
        case providers
        case daily
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        period = try container.decode(TokenSaverPeriod.self, forKey: .period)
        providers = try container.decode([TokenSaverProviderUsage].self, forKey: .providers)
        daily = try container.decodeIfPresent([TokenSaverDayUsage].self, forKey: .daily) ?? []
    }

    public var usedTokens: Int {
        providers.reduce(0) { $0 + $1.actualProviderTokens }
    }

    public var measuredSavedTokens: Int {
        providers.reduce(0) { $0 + $1.measuredSavedTokens }
    }

    public var eligibleRuns: Int {
        providers.reduce(0) { $0 + $1.eligibleRuns }
    }

    public static func empty(period: TokenSaverPeriod = .sevenDays) -> TokenSaverUsageSnapshot {
        TokenSaverUsageSnapshot(period: period, providers: [
            TokenSaverProviderUsage(provider: .claude),
            TokenSaverProviderUsage(provider: .codex),
            TokenSaverProviderUsage(provider: .grok)
        ])
    }
}

public final class TokenSaverUsageStore: @unchecked Sendable {
    // Callers construct a fresh store per write (AppContext does this from the
    // provider stream thread AND from MainActor), so a per-instance lock would
    // not serialize anything. This process-wide lock makes every
    // read-modify-write atomic against all other writers of usage.json.
    private static let ioLock = NSLock()
    private let url: URL
    private let fileManager: FileManager
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        appSupportDirectory: URL,
        fileManager: FileManager = .default,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.url = appSupportDirectory
            .appendingPathComponent("TokenSaver", isDirectory: true)
            .appendingPathComponent("usage.json")
        self.fileManager = fileManager
        self.calendar = calendar
        self.now = now
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load(period: TokenSaverPeriod = .sevenDays) -> TokenSaverUsageSnapshot {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(TokenSaverUsageSnapshot.self, from: data),
              snapshot.period == period else {
            return .empty(period: period)
        }
        // Older usage.json files predate Grok; ensure every managed agent provider
        // has a row so Token Saver rings never look like the provider is missing.
        // Also fold expired weekly windows to 0 so inactive providers do not stay
        // locked on a pre-reset percentage (Claude 45% after the week rolls).
        return Self.expiringStaleWeeklyUsage(
            Self.ensuringManagedProviders(snapshot),
            now: now()
        )
    }

    /// Zero weekly/session account-usage percents whose reset time is already past.
    public static func expiringStaleWeeklyUsage(
        _ snapshot: TokenSaverUsageSnapshot,
        now: Date = Date()
    ) -> TokenSaverUsageSnapshot {
        let providers = snapshot.providers.map { usage -> TokenSaverProviderUsage in
            var next = usage
            if let resets = next.weeklyResetsAt, resets <= now {
                next.weeklyUsedPercent = 0
            }
            if let sessionResets = next.currentSessionResetsAt, sessionResets <= now {
                next.currentSessionUsedPercent = 0
            }
            return next
        }
        return TokenSaverUsageSnapshot(period: snapshot.period, providers: providers, daily: snapshot.daily)
    }

    /// Providers that a partial account-usage refresh successfully updated.
    /// Missing managed providers are treated as inactive/unreachable and must not
    /// keep a frozen weekly % from an earlier probe.
    public static func providersMissingFromAccountUsageRefresh(
        returned: [AgentProvider],
        managed: [AgentProvider] = [.claude, .codex, .grok]
    ) -> [AgentProvider] {
        let present = Set(returned)
        return managed.filter { !present.contains($0) }
    }

    /// Subset of missing providers that should actually have their cached weekly %
    /// cleared after a partial account-usage refresh.
    ///
    /// WHY: a flaky probe (or Grok billing-log window miss) must not wipe a still-
    /// valid weekly window. Grok often sits at a real 40–70% while the log scan
    /// briefly returns nil; clearing it painted the purple ring as 0%. Only clear
    /// when there is no unexpired `weeklyResetsAt` protecting the last probe.
    /// Expired windows already read as 0% via `effectiveWeeklyUsedPercent`.
    public static func providersToClearAfterPartialAccountUsageRefresh(
        returned: [AgentProvider],
        existing: [TokenSaverProviderUsage],
        now: Date = Date(),
        managed: [AgentProvider] = [.claude, .codex, .grok]
    ) -> [AgentProvider] {
        let missing = providersMissingFromAccountUsageRefresh(returned: returned, managed: managed)
        let byProvider = Dictionary(uniqueKeysWithValues: existing.map { ($0.provider, $0) })
        return missing.filter { provider in
            guard let usage = byProvider[provider] else { return true }
            if let resetsAt = usage.weeklyResetsAt, resetsAt > now {
                return false
            }
            return true
        }
    }

    /// Clears live rate-limit percents for a provider while keeping Token Saver
    /// savings counters. Used when a refresh no longer sees the provider (signed
    /// out / inactive) so the ring drops to 0% instead of locking on last known %.
    @discardableResult
    public func clearAccountUsagePercentages(
        provider: AgentProvider,
        period: TokenSaverPeriod = .sevenDays
    ) throws -> TokenSaverUsageSnapshot {
        Self.ioLock.lock()
        defer { Self.ioLock.unlock() }
        let snapshot = load(period: period)
        var providers = snapshot.providers
        if let index = providers.firstIndex(where: { $0.provider == provider }) {
            let current = providers[index]
            providers[index] = TokenSaverProviderUsage(
                provider: provider,
                actualProviderTokens: current.actualProviderTokens,
                estimatedRawTokens: current.estimatedRawTokens,
                actualProviderBilledTokenUnits: current.actualProviderBilledTokenUnits,
                estimatedRawBilledTokenUnits: current.estimatedRawBilledTokenUnits,
                eligibleRuns: current.eligibleRuns,
                currentSessionTokens: current.currentSessionTokens,
                currentSessionLimitTokens: current.currentSessionLimitTokens,
                currentSessionUsedPercent: 0,
                currentSessionResetsAt: current.currentSessionResetsAt,
                weeklyUsedPercent: 0,
                weeklyWindowDurationMinutes: current.weeklyWindowDurationMinutes,
                weeklyResetsAt: current.weeklyResetsAt
            )
        } else {
            providers.append(TokenSaverProviderUsage(
                provider: provider,
                currentSessionUsedPercent: 0,
                weeklyUsedPercent: 0
            ))
        }
        let updated = TokenSaverUsageSnapshot(period: period, providers: providers, daily: snapshot.daily)
        try save(updated)
        return updated
    }

    /// Inserts zero rows for claude/codex/grok when a loaded snapshot omits them.
    public static func ensuringManagedProviders(_ snapshot: TokenSaverUsageSnapshot) -> TokenSaverUsageSnapshot {
        let required: [AgentProvider] = [.claude, .codex, .grok]
        var providers = snapshot.providers
        for provider in required where !providers.contains(where: { $0.provider == provider }) {
            providers.append(TokenSaverProviderUsage(provider: provider))
        }
        // Stable order: claude, codex, grok, then any extras.
        providers.sort { lhs, rhs in
            let order: [AgentProvider: Int] = [.claude: 0, .codex: 1, .grok: 2]
            let l = order[lhs.provider] ?? 100
            let r = order[rhs.provider] ?? 100
            if l != r { return l < r }
            return lhs.provider.rawValue < rhs.provider.rawValue
        }
        return TokenSaverUsageSnapshot(period: snapshot.period, providers: providers, daily: snapshot.daily)
    }

    public func save(_ snapshot: TokenSaverUsageSnapshot) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    @discardableResult
    public func record(
        provider: AgentProvider,
        actualProviderTokens: Int,
        estimatedRawTokens: Int,
        actualProviderBilledTokenUnits: Double? = nil,
        estimatedRawBilledTokenUnits: Double? = nil,
        eligibleRuns: Int = 1,
        currentSessionTokens: Int = 0,
        currentSessionLimitTokens: Int? = nil,
        period: TokenSaverPeriod = .sevenDays
    ) throws -> TokenSaverUsageSnapshot {
        Self.ioLock.lock()
        defer { Self.ioLock.unlock() }
        let snapshot = load(period: period)
        var providers = snapshot.providers
        let delta = TokenSaverProviderUsage(
            provider: provider,
            actualProviderTokens: actualProviderTokens,
            estimatedRawTokens: max(estimatedRawTokens, actualProviderTokens),
            actualProviderBilledTokenUnits: actualProviderBilledTokenUnits,
            estimatedRawBilledTokenUnits: estimatedRawBilledTokenUnits,
            eligibleRuns: eligibleRuns,
            currentSessionTokens: currentSessionTokens,
            currentSessionLimitTokens: currentSessionLimitTokens ?? 0
        )
        if let index = providers.firstIndex(where: { $0.provider == provider }) {
            let current = providers[index]
            providers[index] = TokenSaverProviderUsage(
                provider: provider,
                actualProviderTokens: current.actualProviderTokens + delta.actualProviderTokens,
                estimatedRawTokens: current.estimatedRawTokens + delta.estimatedRawTokens,
                actualProviderBilledTokenUnits: current.actualProviderBilledTokenUnits + delta.actualProviderBilledTokenUnits,
                estimatedRawBilledTokenUnits: current.estimatedRawBilledTokenUnits + delta.estimatedRawBilledTokenUnits,
                eligibleRuns: current.eligibleRuns + delta.eligibleRuns,
                currentSessionTokens: max(current.currentSessionTokens, delta.currentSessionTokens),
                currentSessionLimitTokens: max(current.currentSessionLimitTokens, delta.currentSessionLimitTokens),
                currentSessionUsedPercent: current.currentSessionUsedPercent,
                currentSessionResetsAt: current.currentSessionResetsAt,
                weeklyUsedPercent: current.weeklyUsedPercent,
                weeklyWindowDurationMinutes: current.weeklyWindowDurationMinutes,
                weeklyResetsAt: current.weeklyResetsAt
            )
        } else {
            providers.append(delta)
        }

        let updated = TokenSaverUsageSnapshot(
            period: period,
            providers: providers,
            daily: updatedDailyBuckets(from: snapshot.daily, delta: delta, period: period)
        )
        try save(updated)
        return updated
    }

    @discardableResult
    public func recordAccountUsage(
        provider: AgentProvider,
        weeklyUsedPercent: Double,
        weeklyWindowDurationMinutes: Int? = nil,
        weeklyResetsAt: Date? = nil,
        currentSessionUsedPercent: Double? = nil,
        currentSessionResetsAt: Date? = nil,
        period: TokenSaverPeriod = .sevenDays
    ) throws -> TokenSaverUsageSnapshot {
        Self.ioLock.lock()
        defer { Self.ioLock.unlock() }
        let snapshot = load(period: period)
        var providers = snapshot.providers
        if let index = providers.firstIndex(where: { $0.provider == provider }) {
            let current = providers[index]
            providers[index] = TokenSaverProviderUsage(
                provider: provider,
                actualProviderTokens: current.actualProviderTokens,
                estimatedRawTokens: current.estimatedRawTokens,
                actualProviderBilledTokenUnits: current.actualProviderBilledTokenUnits,
                estimatedRawBilledTokenUnits: current.estimatedRawBilledTokenUnits,
                eligibleRuns: current.eligibleRuns,
                currentSessionTokens: current.currentSessionTokens,
                currentSessionLimitTokens: current.currentSessionLimitTokens,
                currentSessionUsedPercent: currentSessionUsedPercent ?? current.currentSessionUsedPercent,
                currentSessionResetsAt: currentSessionResetsAt ?? current.currentSessionResetsAt,
                weeklyUsedPercent: weeklyUsedPercent,
                weeklyWindowDurationMinutes: weeklyWindowDurationMinutes ?? current.weeklyWindowDurationMinutes,
                weeklyResetsAt: weeklyResetsAt ?? current.weeklyResetsAt
            )
        } else {
            providers.append(TokenSaverProviderUsage(
                provider: provider,
                currentSessionUsedPercent: currentSessionUsedPercent,
                currentSessionResetsAt: currentSessionResetsAt,
                weeklyUsedPercent: weeklyUsedPercent,
                weeklyWindowDurationMinutes: weeklyWindowDurationMinutes,
                weeklyResetsAt: weeklyResetsAt
            ))
        }
        let updated = TokenSaverUsageSnapshot(period: period, providers: providers, daily: snapshot.daily)
        try save(updated)
        return updated
    }

    public static func estimatePotentialSavings(usedTokens: Int, compressionRatio: Double = 0.42) -> Int {
        guard usedTokens > 0 else { return 0 }
        let boundedRatio = min(max(compressionRatio, 0.05), 0.95)
        return max(Int((Double(usedTokens) * (1.0 - boundedRatio)).rounded()), 0)
    }

    private func updatedDailyBuckets(
        from existing: [TokenSaverDayUsage],
        delta: TokenSaverProviderUsage,
        period: TokenSaverPeriod
    ) -> [TokenSaverDayUsage] {
        let dayStart = calendar.startOfDay(for: now())
        var buckets = existing
        if let index = buckets.firstIndex(where: { calendar.isDate($0.dayStart, inSameDayAs: dayStart) }) {
            let current = buckets[index]
            buckets[index] = TokenSaverDayUsage(
                dayStart: current.dayStart,
                actualProviderTokens: current.actualProviderTokens + delta.actualProviderTokens,
                estimatedRawTokens: current.estimatedRawTokens + delta.estimatedRawTokens,
                eligibleRuns: current.eligibleRuns + delta.eligibleRuns
            )
        } else {
            buckets.append(TokenSaverDayUsage(
                dayStart: dayStart,
                actualProviderTokens: delta.actualProviderTokens,
                estimatedRawTokens: delta.estimatedRawTokens,
                eligibleRuns: delta.eligibleRuns
            ))
        }

        let retainedDays: Int
        switch period {
        case .today:
            retainedDays = 1
        case .sevenDays:
            retainedDays = 7
        case .thirtyDays:
            retainedDays = 30
        }
        let cutoff = calendar.date(byAdding: .day, value: 1 - retainedDays, to: dayStart) ?? dayStart
        return buckets
            .filter { $0.dayStart >= cutoff }
            .sorted { $0.dayStart < $1.dayStart }
    }
}
