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

    public var weeklyRemainingPercent: Double? {
        weeklyUsedPercent.map { max(0, 100 - $0) }
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
            TokenSaverProviderUsage(provider: .codex)
        ])
    }
}

public final class TokenSaverUsageStore: @unchecked Sendable {
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
        return snapshot
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
        eligibleRuns: Int = 1,
        currentSessionTokens: Int = 0,
        currentSessionLimitTokens: Int? = nil,
        period: TokenSaverPeriod = .sevenDays
    ) throws -> TokenSaverUsageSnapshot {
        let snapshot = load(period: period)
        var providers = snapshot.providers
        let delta = TokenSaverProviderUsage(
            provider: provider,
            actualProviderTokens: actualProviderTokens,
            estimatedRawTokens: max(estimatedRawTokens, actualProviderTokens),
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
        let snapshot = load(period: period)
        var providers = snapshot.providers
        if let index = providers.firstIndex(where: { $0.provider == provider }) {
            let current = providers[index]
            providers[index] = TokenSaverProviderUsage(
                provider: provider,
                actualProviderTokens: current.actualProviderTokens,
                estimatedRawTokens: current.estimatedRawTokens,
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
