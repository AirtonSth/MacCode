import Foundation

/// Measured Token Saver savings for one provider over the retention window.
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

/// One UTC day bucket of measured savings, for the 7-day history chart.
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

/// Aggregated measured savings over the retention window. This is the source of
/// the honest "tokens saved" totals and the per-run average shown in the UI.
public struct TokenSaverSavingsSummary: Sendable, Equatable {
    public let providers: [TokenSaverProviderSavings]
    public let daily: [TokenSaverDailySavings]

    public init(providers: [TokenSaverProviderSavings], daily: [TokenSaverDailySavings]) {
        self.providers = providers
        self.daily = daily
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

    public static let empty = TokenSaverSavingsSummary(providers: [], daily: [])
}

/// Persists every real, measured Token Saver compression event to the local
/// SQLite database and keeps only the trailing retention window (7 days).
/// Each `record` is atomic insert-then-prune on the DB serial queue, so
/// concurrent agent runs cannot lose or corrupt rows.
public final class TokenSaverSavingsRepository {
    private let db: SQLiteDB
    private let retentionDays: Int
    private static let isoFormatter = ISO8601DateFormatter()

    public init(db: SQLiteDB, retentionDays: Int = 7) {
        self.db = db
        self.retentionDays = max(1, retentionDays)
    }

    private var retentionMs: Int64 { Int64(retentionDays) * 86_400_000 }

    /// Record one compression event. `inputTokens`/`outputTokens` are the
    /// measured raw vs distilled token counts; saved = max(input-output, 0).
    /// Returns the saved tokens persisted. Old rows beyond the window are
    /// pruned in the same transaction so history never exceeds `retentionDays`.
    @discardableResult
    public func record(
        provider: String,
        mode: String,
        inputTokens: Int,
        outputTokens: Int,
        at date: Date = Date()
    ) throws -> Int {
        let saved = max(inputTokens - outputTokens, 0)
        let ms = Int64(date.timeIntervalSince1970 * 1000)
        let iso = Self.isoFormatter.string(from: date)
        let cutoff = ms - retentionMs
        try db.performSync { database in
            let insert = try database.prepare("""
                INSERT INTO token_saver_savings
                    (provider, mode, input_tokens, output_tokens, saved_tokens, created_at, created_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?);
            """)
            defer { insert.reset() }
            try insert.bind(1, provider)
            try insert.bind(2, mode)
            try insert.bind(3, max(0, inputTokens))
            try insert.bind(4, max(0, outputTokens))
            try insert.bind(5, saved)
            try insert.bind(6, iso)
            try insert.bind(7, ms)
            _ = try insert.step()

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

    /// Aggregate measured savings over the trailing retention window.
    public func summary(now: Date = Date()) throws -> TokenSaverSavingsSummary {
        let cutoff = Int64(now.timeIntervalSince1970 * 1000) - retentionMs
        return try db.performSync { database in
            var providers: [TokenSaverProviderSavings] = []
            let perProvider = try database.prepare("""
                SELECT provider,
                       COALESCE(SUM(saved_tokens), 0),
                       COALESCE(SUM(input_tokens), 0),
                       COALESCE(SUM(output_tokens), 0),
                       COUNT(*)
                FROM token_saver_savings
                WHERE created_at_ms >= ?
                GROUP BY provider;
            """)
            defer { perProvider.reset() }
            try perProvider.bind(1, cutoff)
            while try perProvider.step() {
                providers.append(TokenSaverProviderSavings(
                    provider: perProvider.columnText(0) ?? "unknown",
                    savedTokens: Int(perProvider.columnInt64(1)),
                    inputTokens: Int(perProvider.columnInt64(2)),
                    outputTokens: Int(perProvider.columnInt64(3)),
                    runs: Int(perProvider.columnInt64(4))
                ))
            }

            var daily: [TokenSaverDailySavings] = []
            let perDay = try database.prepare("""
                SELECT (created_at_ms / 86400000) * 86400000 AS day,
                       COALESCE(SUM(saved_tokens), 0),
                       COUNT(*)
                FROM token_saver_savings
                WHERE created_at_ms >= ?
                GROUP BY day
                ORDER BY day;
            """)
            defer { perDay.reset() }
            try perDay.bind(1, cutoff)
            while try perDay.step() {
                daily.append(TokenSaverDailySavings(
                    dayStartMs: perDay.columnInt64(0),
                    savedTokens: Int(perDay.columnInt64(1)),
                    runs: Int(perDay.columnInt64(2))
                ))
            }
            return TokenSaverSavingsSummary(providers: providers, daily: daily)
        }
    }
}
