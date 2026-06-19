import Foundation

/// Token Saver saved-token totals for one provider across the permanent
/// accumulator. Event rows may be pruned, but this aggregate keeps growing so
/// the user can see all tokens Token Saver has saved for them.
public struct TokenSaverProviderSavings: Sendable, Equatable {
    public let provider: String
    public let savedTokens: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let runs: Int

    public init(provider: String, savedTokens: Int, inputTokens: Int, outputTokens: Int, runs: Int) {
        self.provider = provider
        self.savedTokens = savedTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.runs = runs
    }
}

/// One calendar-day bucket of saved tokens, for the 7-day history chart.
public struct TokenSaverDailySavings: Sendable, Equatable {
    public let dayStartMs: Int64
    public let savedTokens: Int
    public let runs: Int

    public init(dayStartMs: Int64, savedTokens: Int, runs: Int) {
        self.dayStartMs = dayStartMs
        self.savedTokens = savedTokens
        self.runs = runs
    }
}

/// One (provider, calendar-day) bucket of saved tokens from the retained event
/// rows. This is the only structure with BOTH a provider and a time dimension,
/// so it is what lets the details popover show per-provider savings for the same
/// window (Today / Week) as the headline. Summing every provider's buckets for a
/// day reproduces the collapsed `TokenSaverDailySavings` for that day exactly, so
/// the per-provider rows reconcile with the windowed headline by construction.
public struct TokenSaverProviderDailySavings: Sendable, Equatable {
    public let provider: String
    public let dayStartMs: Int64
    public let savedTokens: Int
    public let runs: Int

    public init(provider: String, dayStartMs: Int64, savedTokens: Int, runs: Int) {
        self.provider = provider
        self.dayStartMs = dayStartMs
        self.savedTokens = savedTokens
        self.runs = runs
    }
}

/// All-time saved-token totals for one (provider, mode) pair from the permanent
/// accumulator. Feeds the breakdown table in the Token Saver details popover.
public struct TokenSaverModeSavings: Sendable, Equatable {
    public let provider: String
    public let mode: String
    public let savedTokens: Int
    public let runs: Int

    public init(provider: String, mode: String, savedTokens: Int, runs: Int) {
        self.provider = provider
        self.mode = mode
        self.savedTokens = savedTokens
        self.runs = runs
    }
}

/// Aggregated saved tokens. Provider totals come from the permanent accumulator
/// so the UI can show all tokens saved for the user. Daily buckets come from the
/// retained event rows and feed the short-term reports/chart. Mode rows carry the
/// same permanent totals split by (provider, mode) for the breakdown table.
public struct TokenSaverSavingsSummary: Sendable, Equatable {
    public let providers: [TokenSaverProviderSavings]
    public let daily: [TokenSaverDailySavings]
    /// Per-(provider, mode) breakdown from the permanent accumulator.
    public let modes: [TokenSaverModeSavings]
    /// Per-(provider, calendar-day) buckets over the retained report window. The
    /// collapsed `daily` is the sum of these across providers, so the windowed
    /// per-provider rows in the UI reconcile with the windowed headline.
    public let dailyByProvider: [TokenSaverProviderDailySavings]

    public init(
        providers: [TokenSaverProviderSavings],
        daily: [TokenSaverDailySavings],
        modes: [TokenSaverModeSavings] = [],
        dailyByProvider: [TokenSaverProviderDailySavings] = []
    ) {
        self.providers = providers
        self.daily = daily
        self.modes = modes
        self.dailyByProvider = dailyByProvider
    }

    public var totalSavedTokens: Int { providers.reduce(0) { $0 + $1.savedTokens } }
    public var totalRuns: Int { providers.reduce(0) { $0 + $1.runs } }
    public var totalInputTokens: Int { providers.reduce(0) { $0 + $1.inputTokens } }
    public var totalOutputTokens: Int { providers.reduce(0) { $0 + $1.outputTokens } }

    /// Mean tokens saved per compressed run — the "média" the UI advertises.
    public var averageSavedPerRun: Int {
        totalRuns > 0 ? Int((Double(totalSavedTokens) / Double(totalRuns)).rounded()) : 0
    }

    public func savings(for provider: String) -> TokenSaverProviderSavings? {
        providers.first { $0.provider == provider }
    }

    /// Saved tokens attributed to providers NOT in `known` (e.g. direct `distill` CLI
    /// usage recorded as "unknown"). The Token Saver card shows only Claude + Codex
    /// rows; without surfacing this, the headline total (which sums ALL providers) would
    /// not reconcile with the visible rows — exactly the "Saved 23K but Claude/Codex 0"
    /// confusion. So: total == sum(known rows) + this.
    public func savedTokens(forProvidersOtherThan known: Set<String>) -> Int {
        providers.filter { !known.contains($0.provider) }.reduce(0) { $0 + $1.savedTokens }
    }

    public func runs(forProvidersOtherThan known: Set<String>) -> Int {
        providers.filter { !known.contains($0.provider) }.reduce(0) { $0 + $1.runs }
    }

    public static let empty = TokenSaverSavingsSummary(providers: [], daily: [], modes: [])
}

/// Persists Token Saver savings events to the local SQLite database, keeps event
/// rows for at least one week for reports/charts, and updates a permanent
/// accumulator so total saved tokens keep adding up for the user.
/// Each `record` is atomic insert-update-prune on the DB serial queue, so
/// concurrent agent runs cannot lose or corrupt rows.
public final class TokenSaverSavingsRepository: @unchecked Sendable {
    private let db: SQLiteDB
    private let retentionDays: Int
    private let calendar: Calendar
    private static let isoFormatter = ISO8601DateFormatter()

    public init(db: SQLiteDB, retentionDays: Int = 7, calendar: Calendar = .current) {
        self.db = db
        self.retentionDays = max(7, retentionDays)
        self.calendar = calendar
    }

    private var retentionMs: Int64 { Int64(retentionDays) * 86_400_000 }

    /// Record one savings event. The column names are historical; sidecar
    /// command-output rows store original/distilled character lengths, while
    /// SR1 humanization rows store the explicit mode-specific accounting.
    /// saved = max(input-output, 0).
    /// Returns the saved tokens persisted. Old event rows beyond the window are
    /// pruned in the same transaction, but the permanent total is not pruned.
    @discardableResult
    public func record(
        provider: String,
        mode: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheState: String = "unknown",
        at date: Date = Date()
    ) throws -> Int {
        let saved = max(inputTokens - outputTokens, 0)
        return try record(
            provider: provider,
            mode: mode,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            savedTokens: saved,
            cacheState: cacheState,
            at: date
        )
    }

    /// Record one savings event with an explicit saved value. This is used for
    /// sidecar modes whose accounting is not simply `input - output` in the
    /// stored units, such as SR1 humanization.
    @discardableResult
    public func record(
        provider: String,
        mode: String,
        inputTokens: Int,
        outputTokens: Int,
        savedTokens: Int,
        cacheState: String = "unknown",
        at date: Date = Date()
    ) throws -> Int {
        let saved = max(savedTokens, 0)
        let ms = Int64(date.timeIntervalSince1970 * 1000)
        let iso = Self.isoFormatter.string(from: date)
        let cutoff = ms - retentionMs
        try db.performSync { database in
            let insert = try database.prepare("""
                INSERT INTO token_saver_savings
                    (provider, mode, input_tokens, output_tokens, saved_tokens, created_at, created_at_ms, cache_state)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """)
            defer { insert.reset() }
            try insert.bind(1, provider)
            try insert.bind(2, mode)
            try insert.bind(3, max(0, inputTokens))
            try insert.bind(4, max(0, outputTokens))
            try insert.bind(5, saved)
            try insert.bind(6, iso)
            try insert.bind(7, ms)
            try insert.bind(8, cacheState)
            _ = try insert.step()

            let total = try database.prepare("""
                INSERT INTO token_saver_savings_totals
                    (provider, mode, input_tokens, output_tokens, saved_tokens, runs, updated_at)
                VALUES (?, ?, ?, ?, ?, 1, ?)
                ON CONFLICT(provider, mode) DO UPDATE SET
                    input_tokens = token_saver_savings_totals.input_tokens + excluded.input_tokens,
                    output_tokens = token_saver_savings_totals.output_tokens + excluded.output_tokens,
                    saved_tokens = token_saver_savings_totals.saved_tokens + excluded.saved_tokens,
                    runs = token_saver_savings_totals.runs + excluded.runs,
                    updated_at = excluded.updated_at;
            """)
            defer { total.reset() }
            try total.bind(1, provider)
            try total.bind(2, mode)
            try total.bind(3, max(0, inputTokens))
            try total.bind(4, max(0, outputTokens))
            try total.bind(5, saved)
            try total.bind(6, iso)
            _ = try total.step()

            let prune = try database.prepare("DELETE FROM token_saver_savings WHERE created_at_ms < ?;")
            defer { prune.reset() }
            try prune.bind(1, cutoff)
            _ = try prune.step()
        }
        return saved
    }

    /// Delete any rows older than the retention window. Safe to call on launch.
    public func prune(now: Date = Date()) throws {
        let cutoff = Int64(now.timeIntervalSince1970 * 1000) - retentionMs
        try db.performSync { database in
            let prune = try database.prepare("DELETE FROM token_saver_savings WHERE created_at_ms < ?;")
            defer { prune.reset() }
            try prune.bind(1, cutoff)
            _ = try prune.step()
        }
    }

    /// Aggregate measured savings. Provider totals are all-time accumulated
    /// values; daily buckets cover the retained report window; mode rows carry
    /// per-(provider, mode) all-time totals for the breakdown table.
    public func summary(now: Date = Date()) throws -> TokenSaverSavingsSummary {
        let cutoff = Int64(now.timeIntervalSince1970 * 1000) - retentionMs
        return try db.performSync { database in
            var providers: [TokenSaverProviderSavings] = []
            let perProvider = try database.prepare("""
                SELECT provider,
                       COALESCE(SUM(saved_tokens), 0),
                       COALESCE(SUM(input_tokens), 0),
                       COALESCE(SUM(output_tokens), 0),
                       COALESCE(SUM(runs), 0)
                FROM token_saver_savings_totals
                GROUP BY provider;
            """)
            defer { perProvider.reset() }
            while try perProvider.step() {
                providers.append(TokenSaverProviderSavings(
                    provider: perProvider.columnText(0) ?? "unknown",
                    savedTokens: Int(perProvider.columnInt64(1)),
                    inputTokens: Int(perProvider.columnInt64(2)),
                    outputTokens: Int(perProvider.columnInt64(3)),
                    runs: Int(perProvider.columnInt64(4))
                ))
            }

            // Bucket the retained event rows by (provider, calendar-day). The
            // collapsed daily total is derived from the same buckets so the
            // per-provider windowed rows always sum to the windowed headline.
            var providerDayBuckets: [String: [Int64: (savedTokens: Int, runs: Int)]] = [:]
            let perDay = try database.prepare("""
                SELECT provider,
                       created_at_ms,
                       COALESCE(saved_tokens, 0)
                FROM token_saver_savings
                WHERE created_at_ms >= ?
                ORDER BY created_at_ms;
            """)
            defer { perDay.reset() }
            try perDay.bind(1, cutoff)
            while try perDay.step() {
                let provider = perDay.columnText(0) ?? "unknown"
                let createdAtMs = perDay.columnInt64(1)
                let savedTokens = Int(perDay.columnInt64(2))
                let dayStartMs = self.dayStartMs(for: Date(timeIntervalSince1970: Double(createdAtMs) / 1000.0))
                var byDay = providerDayBuckets[provider] ?? [:]
                let current = byDay[dayStartMs] ?? (savedTokens: 0, runs: 0)
                byDay[dayStartMs] = (
                    savedTokens: current.savedTokens + savedTokens,
                    runs: current.runs + 1
                )
                providerDayBuckets[provider] = byDay
            }
            var dailyByProvider: [TokenSaverProviderDailySavings] = []
            var collapsed: [Int64: (savedTokens: Int, runs: Int)] = [:]
            for (provider, byDay) in providerDayBuckets {
                for (dayStartMs, totals) in byDay {
                    dailyByProvider.append(TokenSaverProviderDailySavings(
                        provider: provider,
                        dayStartMs: dayStartMs,
                        savedTokens: totals.savedTokens,
                        runs: totals.runs
                    ))
                    let current = collapsed[dayStartMs] ?? (savedTokens: 0, runs: 0)
                    collapsed[dayStartMs] = (
                        savedTokens: current.savedTokens + totals.savedTokens,
                        runs: current.runs + totals.runs
                    )
                }
            }
            dailyByProvider.sort {
                $0.dayStartMs != $1.dayStartMs ? $0.dayStartMs < $1.dayStartMs : $0.provider < $1.provider
            }
            let daily = collapsed
                .map { TokenSaverDailySavings(dayStartMs: $0.key, savedTokens: $0.value.savedTokens, runs: $0.value.runs) }
                .sorted { $0.dayStartMs < $1.dayStartMs }

            var modes: [TokenSaverModeSavings] = []
            let perMode = try database.prepare("""
                SELECT provider, mode,
                       COALESCE(saved_tokens, 0),
                       COALESCE(runs, 0)
                FROM token_saver_savings_totals
                ORDER BY provider, mode;
            """)
            defer { perMode.reset() }
            while try perMode.step() {
                modes.append(TokenSaverModeSavings(
                    provider: perMode.columnText(0) ?? "unknown",
                    mode: perMode.columnText(1) ?? "unknown",
                    savedTokens: Int(perMode.columnInt64(2)),
                    runs: Int(perMode.columnInt64(3))
                ))
            }

            return TokenSaverSavingsSummary(providers: providers, daily: daily, modes: modes, dailyByProvider: dailyByProvider)
        }
    }

    private func dayStartMs(for date: Date) -> Int64 {
        Int64(calendar.startOfDay(for: date).timeIntervalSince1970 * 1000)
    }
}
