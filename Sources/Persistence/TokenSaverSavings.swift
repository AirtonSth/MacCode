import Foundation

/// One thread's permanent delivered savings + run count for multi-turn cache
/// amortization into the day/week Token Saver card (matches thread-footer stack).
public struct TokenSaverThreadCacheAmortizationInput: Sendable, Equatable {
    public let threadID: String
    public let savedTokens: Int
    public let runs: Int
    /// Last delivered provider label for this thread (`claude` / `codex` / `grok` / …).
    public let provider: String

    public init(threadID: String, savedTokens: Int, runs: Int, provider: String = "unknown") {
        self.threadID = threadID
        self.savedTokens = max(0, savedTokens)
        self.runs = max(0, runs)
        let p = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.provider = p.isEmpty ? "unknown" : p
    }
}

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
/// `windowByMode` is the same retained-window technique mix as `daily` (not all-time).
///
/// `attributedSavedTokens` / `unattributedSavedTokens` are the honesty split: only
/// rows matching ``TokenSaverSavingsRepository.displayedSavingsEligibilitySQL``
/// contribute, then attributed vs unattributed is applied. Existing fields keep
/// their pre-honesty semantics (sum of the permanent accumulator as written).
public struct TokenSaverSavingsSummary: Sendable, Equatable {
    public let providers: [TokenSaverProviderSavings]
    public let daily: [TokenSaverDailySavings]
    /// Per-(provider, mode) breakdown from the permanent accumulator.
    public let modes: [TokenSaverModeSavings]
    /// Per-(provider, calendar-day) buckets over the retained report window. The
    /// collapsed `daily` is the sum of these across providers, so the windowed
    /// per-provider rows in the UI reconcile with the windowed headline.
    public let dailyByProvider: [TokenSaverProviderDailySavings]
    /// Per-(provider, mode) totals over the retained report window only. Sum of
    /// `savedTokens` across all rows equals sum of `daily.savedTokens` by construction.
    public let windowByMode: [TokenSaverModeSavings]
    /// All-time saved tokens that are display-eligible and attributed
    /// (`prompt_bound` or a real non-`unknown` provider).
    public let attributedSavedTokens: Int
    public let attributedRuns: Int
    /// All-time saved tokens that are display-eligible but not attributed
    /// (no real provider and not `prompt_bound`).
    public let unattributedSavedTokens: Int
    public let unattributedRuns: Int

    public init(
        providers: [TokenSaverProviderSavings],
        daily: [TokenSaverDailySavings],
        modes: [TokenSaverModeSavings] = [],
        dailyByProvider: [TokenSaverProviderDailySavings] = [],
        windowByMode: [TokenSaverModeSavings] = [],
        attributedSavedTokens: Int = 0,
        attributedRuns: Int = 0,
        unattributedSavedTokens: Int = 0,
        unattributedRuns: Int = 0
    ) {
        self.providers = providers
        self.daily = daily
        self.modes = modes
        self.dailyByProvider = dailyByProvider
        self.windowByMode = windowByMode
        self.attributedSavedTokens = attributedSavedTokens
        self.attributedRuns = attributedRuns
        self.unattributedSavedTokens = unattributedSavedTokens
        self.unattributedRuns = unattributedRuns
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
    /// usage recorded as "unknown"). The Token Saver card shows Claude + Codex + Grok
    /// rows; without surfacing this, the headline total (which sums ALL providers) would
    /// not reconcile with the visible rows — exactly the "Saved 23K but Claude/Codex 0"
    /// confusion. So: total == sum(known rows) + this.
    public func savedTokens(forProvidersOtherThan known: Set<String>) -> Int {
        providers.filter { !known.contains($0.provider) }.reduce(0) { $0 + $1.savedTokens }
    }

    public func runs(forProvidersOtherThan known: Set<String>) -> Int {
        providers.filter { !known.contains($0.provider) }.reduce(0) { $0 + $1.runs }
    }

    public static let empty = TokenSaverSavingsSummary(
        providers: [],
        daily: [],
        modes: [],
        dailyByProvider: [],
        windowByMode: [],
        attributedSavedTokens: 0,
        attributedRuns: 0,
        unattributedSavedTokens: 0,
        unattributedRuns: 0
    )
}

public enum TokenSaverSavingsRepositoryError: Error, Equatable, CustomStringConvertible {
    case idempotencyConflict(String)

    public var description: String {
        switch self {
        case .idempotencyConflict(let key):
            return "Token Saver savings idempotency conflict for \(key)"
        }
    }
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

    /// HISTORICAL-ROW RULE — single SQL fragment for every honesty read path.
    ///
    /// WHY: A row is display-eligible when `delivered = 1` (compressed bytes
    /// actually replaced the original). Pre-migration rows never received a
    /// class: migration defaults leave `delivered = 0` and
    /// `attributability = 'unknown'`. Those unclassed rows must still count
    /// when the provider is a real (non-`unknown`) provider so the all-time
    /// figure cannot regress to zero. Explicit `delivered = 0` with a known
    /// attributability (fail-open / verbatim) is excluded.
    ///
    /// Values for `attributability`: `prompt_bound` | `not_prompt_bound` | `unknown`.
    public static let displayedSavingsEligibilitySQL = """
        (delivered = 1 OR (attributability = 'unknown' AND provider != 'unknown'))
        """

    /// Among display-eligible rows: counts toward the *attributed* figure when
    /// the row is `prompt_bound` OR the provider is a real (non-`unknown`) provider.
    /// Compose with ``displayedSavingsEligibilitySQL``; do not copy-paste either.
    public static let attributedSavingsSQL = """
        (attributability = 'prompt_bound' OR (provider IS NOT NULL AND provider != '' AND provider != 'unknown'))
        """

    public init(db: SQLiteDB, retentionDays: Int = 7, calendar: Calendar = .current) {
        self.db = db
        self.retentionDays = max(7, retentionDays)
        self.calendar = calendar
    }

    private var retentionMs: Int64 { Int64(retentionDays) * 86_400_000 }

    /// Record one savings event. The column names are historical; sidecar
    /// command-output rows store original/distilled character lengths, while
    /// model-rendering rows store the explicit mode-specific accounting.
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
        contentType: String = "unknown",
        engine: String = "unknown",
        attributability: String = "unknown",
        delivered: Bool = false,
        governance: String = "{}",
        threadID: String = "",
        idempotencyKey: String = "",
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
            contentType: contentType,
            engine: engine,
            attributability: attributability,
            delivered: delivered,
            governance: governance,
            threadID: threadID,
            idempotencyKey: idempotencyKey,
            at: date
        )
    }

    /// Record one savings event with an explicit saved value. This is used for
    /// sidecar modes whose accounting is not simply `input - output` in the
    /// stored units, such as local model rendering.
    @discardableResult
    public func record(
        provider: String,
        mode: String,
        inputTokens: Int,
        outputTokens: Int,
        savedTokens: Int,
        cacheState: String = "unknown",
        contentType: String = "unknown",
        engine: String = "unknown",
        attributability: String = "unknown",
        delivered: Bool = false,
        governance: String = "{}",
        threadID: String = "",
        idempotencyKey: String = "",
        at date: Date = Date()
    ) throws -> Int {
        let saved = max(savedTokens, 0)
        let ms = Int64(date.timeIntervalSince1970 * 1000)
        let iso = Self.isoFormatter.string(from: date)
        let cutoff = ms - retentionMs
        let deliveredFlag = delivered ? 1 : 0
        let attr = Self.normalizedAttributability(attributability)
        let gov = governance.isEmpty ? "{}" : governance
        let trimmedContent = contentType.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = trimmedContent.isEmpty ? "unknown" : trimmedContent
        let trimmedEngine = engine.trimmingCharacters(in: .whitespacesAndNewlines)
        let eng = trimmedEngine.isEmpty ? "unknown" : trimmedEngine
        let thread = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let inserted = try db.performSync { database in
            try database.transaction {
                let insert = try database.prepare("""
                    INSERT OR IGNORE INTO token_saver_savings
                        (provider, mode, input_tokens, output_tokens, saved_tokens, created_at, created_at_ms,
                         cache_state, content_type, engine, attributability, delivered, governance_json, thread_id,
                         idempotency_key)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
                try insert.bind(9, content)
                try insert.bind(10, eng)
                try insert.bind(11, attr)
                try insert.bind(12, deliveredFlag)
                try insert.bind(13, gov)
                try insert.bind(14, thread)
                try insert.bind(15, key)
                _ = try insert.step()

                let changes = try database.prepare("SELECT changes();")
                defer { changes.reset() }
                let didInsert = try changes.step() && changes.columnInt64(0) == 1
                guard didInsert else {
                    let existing = try database.prepare("""
                        SELECT provider, mode, input_tokens, output_tokens, saved_tokens,
                               cache_state, content_type, engine, attributability, delivered,
                               governance_json, thread_id
                        FROM token_saver_savings
                        WHERE idempotency_key = ?
                        LIMIT 1;
                    """)
                    defer { existing.reset() }
                    try existing.bind(1, key)
                    guard !key.isEmpty,
                          try existing.step(),
                          existing.columnText(0) == provider,
                          existing.columnText(1) == mode,
                          existing.columnInt64(2) == Int64(max(0, inputTokens)),
                          existing.columnInt64(3) == Int64(max(0, outputTokens)),
                          existing.columnInt64(4) == Int64(saved),
                          existing.columnText(5) == cacheState,
                          existing.columnText(6) == content,
                          existing.columnText(7) == eng,
                          existing.columnText(8) == attr,
                          existing.columnInt64(9) == Int64(deliveredFlag),
                          existing.columnText(10) == gov,
                          existing.columnText(11) == thread else {
                        throw TokenSaverSavingsRepositoryError.idempotencyConflict(key)
                    }
                    return false
                }

                let total = try database.prepare("""
                    INSERT INTO token_saver_savings_totals
                        (provider, mode, input_tokens, output_tokens, saved_tokens, runs, updated_at,
                         attributability, delivered, governance_json)
                    VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, ?)
                    ON CONFLICT(provider, mode) DO UPDATE SET
                        input_tokens = token_saver_savings_totals.input_tokens + excluded.input_tokens,
                        output_tokens = token_saver_savings_totals.output_tokens + excluded.output_tokens,
                        saved_tokens = token_saver_savings_totals.saved_tokens + excluded.saved_tokens,
                        runs = token_saver_savings_totals.runs + excluded.runs,
                        updated_at = excluded.updated_at,
                        delivered = MAX(token_saver_savings_totals.delivered, excluded.delivered),
                        attributability = CASE
                            WHEN excluded.attributability != 'unknown' THEN excluded.attributability
                            ELSE token_saver_savings_totals.attributability
                        END,
                        governance_json = CASE
                            WHEN excluded.governance_json != '{}' THEN excluded.governance_json
                            ELSE token_saver_savings_totals.governance_json
                        END;
                """)
                defer { total.reset() }
                try total.bind(1, provider)
                try total.bind(2, mode)
                try total.bind(3, max(0, inputTokens))
                try total.bind(4, max(0, outputTokens))
                try total.bind(5, saved)
                try total.bind(6, iso)
                try total.bind(7, attr)
                try total.bind(8, deliveredFlag)
                try total.bind(9, gov)
                _ = try total.step()

                // Permanent per-thread accumulator (only delivered rows count toward
                // the user-facing "saved in this thread" claim).
                if !thread.isEmpty, delivered {
                    let threadTotal = try database.prepare("""
                        INSERT INTO token_saver_thread_totals
                            (thread_id, saved_tokens, runs, updated_at)
                        VALUES (?, ?, 1, ?)
                        ON CONFLICT(thread_id) DO UPDATE SET
                            saved_tokens = token_saver_thread_totals.saved_tokens + excluded.saved_tokens,
                            runs = token_saver_thread_totals.runs + excluded.runs,
                            updated_at = excluded.updated_at;
                    """)
                    defer { threadTotal.reset() }
                    try threadTotal.bind(1, thread)
                    try threadTotal.bind(2, saved)
                    try threadTotal.bind(3, iso)
                    _ = try threadTotal.step()
                }

                let prune = try database.prepare("DELETE FROM token_saver_savings WHERE created_at_ms < ?;")
                defer { prune.reset() }
                try prune.bind(1, cutoff)
                _ = try prune.step()
                return true
            }
        }
        return inserted ? saved : 0
    }

    /// Permanent delivered savings and run count for one agent thread.
    /// Empty / unknown / missing thread ids return `(0, 0)`.
    public func deliveredTotal(forThreadID threadID: String) throws -> (savedTokens: Int, runs: Int) {
        let thread = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !thread.isEmpty else { return (0, 0) }
        return try db.performSync { database in
            let stmt = try database.prepare("""
                SELECT COALESCE(saved_tokens, 0), COALESCE(runs, 0)
                FROM token_saver_thread_totals
                WHERE thread_id = ?
                LIMIT 1;
            """)
            defer { stmt.reset() }
            try stmt.bind(1, thread)
            guard try stmt.step() else { return (0, 0) }
            return (Int(stmt.columnInt64(0)), Int(stmt.columnInt64(1)))
        }
    }

    /// Cumulative delivered tokens saved for one agent thread (permanent total).
    /// Empty / unknown thread ids return 0.
    public func savedTokens(forThreadID threadID: String) throws -> Int {
        try deliveredTotal(forThreadID: threadID).savedTokens
    }

    /// Threads with activity in `[dayStartMs, dayEndMsExclusive)` plus their
    /// **permanent** delivered totals/runs from `token_saver_thread_totals`.
    ///
    /// WHY permanent totals (not day-only SUM): the multi-turn cache stack that
    /// produces the user-trusted "Estimated save ~476M" headline multiplies the
    /// thread's lifetime saved chip by remaining re-reads (runs − 1). Day-scoped
    /// SUM × weak proxy under-counted that stack by ~25× vs the thread footer.
    /// Only threads with delivered savings inside the window are included so
    /// idle historical threads do not contribute.
    public func threadCacheAmortizationInputs(
        dayStartMs: Int64,
        dayEndMsExclusive: Int64
    ) throws -> [TokenSaverThreadCacheAmortizationInput] {
        try db.performSync { database in
            let stmt = try database.prepare("""
                SELECT t.thread_id,
                       COALESCE(t.saved_tokens, 0),
                       COALESCE(t.runs, 0),
                       COALESCE((
                           SELECT s2.provider
                           FROM token_saver_savings s2
                           WHERE s2.thread_id = t.thread_id
                             AND s2.delivered = 1
                             AND s2.created_at_ms >= ?
                             AND s2.created_at_ms < ?
                             AND TRIM(s2.thread_id) != ''
                           ORDER BY s2.created_at_ms DESC
                           LIMIT 1
                       ), 'unknown')
                FROM token_saver_thread_totals t
                WHERE EXISTS (
                    SELECT 1
                    FROM token_saver_savings s
                    WHERE s.thread_id = t.thread_id
                      AND s.delivered = 1
                      AND s.created_at_ms >= ?
                      AND s.created_at_ms < ?
                      AND TRIM(s.thread_id) != ''
                );
            """)
            defer { stmt.reset() }
            try stmt.bind(1, dayStartMs)
            try stmt.bind(2, dayEndMsExclusive)
            try stmt.bind(3, dayStartMs)
            try stmt.bind(4, dayEndMsExclusive)
            var rows: [TokenSaverThreadCacheAmortizationInput] = []
            while try stmt.step() {
                let id = (stmt.columnText(0) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else { continue }
                rows.append(TokenSaverThreadCacheAmortizationInput(
                    threadID: id,
                    savedTokens: Int(stmt.columnInt64(1)),
                    runs: Int(stmt.columnInt64(2)),
                    provider: (stmt.columnText(3) ?? "unknown")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                ))
            }
            return rows
        }
    }

    private static func normalizedAttributability(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "prompt_bound", "not_prompt_bound", "unknown":
            return trimmed
        default:
            return "unknown"
        }
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

            // Bucket the retained event rows by (provider, calendar-day) and by
            // (provider, mode). Collapsed daily and windowByMode both derive from
            // the same event scan so technique mix reconciles with the headline.
            var providerDayBuckets: [String: [Int64: (savedTokens: Int, runs: Int)]] = [:]
            var providerModeBuckets: [String: [String: (savedTokens: Int, runs: Int)]] = [:]
            let perDay = try database.prepare("""
                SELECT provider,
                       created_at_ms,
                       COALESCE(saved_tokens, 0),
                       mode
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
                let mode = (perDay.columnText(3) ?? "unknown").trimmingCharacters(in: .whitespacesAndNewlines)
                let modeKey = mode.isEmpty ? "unknown" : mode
                let dayStartMs = self.dayStartMs(for: Date(timeIntervalSince1970: Double(createdAtMs) / 1000.0))
                var byDay = providerDayBuckets[provider] ?? [:]
                let current = byDay[dayStartMs] ?? (savedTokens: 0, runs: 0)
                byDay[dayStartMs] = (
                    savedTokens: current.savedTokens + savedTokens,
                    runs: current.runs + 1
                )
                providerDayBuckets[provider] = byDay

                var byMode = providerModeBuckets[provider] ?? [:]
                let modeCurrent = byMode[modeKey] ?? (savedTokens: 0, runs: 0)
                byMode[modeKey] = (
                    savedTokens: modeCurrent.savedTokens + savedTokens,
                    runs: modeCurrent.runs + 1
                )
                providerModeBuckets[provider] = byMode
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

            var windowByMode: [TokenSaverModeSavings] = []
            for (provider, byMode) in providerModeBuckets {
                for (mode, totals) in byMode {
                    windowByMode.append(TokenSaverModeSavings(
                        provider: provider,
                        mode: mode,
                        savedTokens: totals.savedTokens,
                        runs: totals.runs
                    ))
                }
            }
            windowByMode.sort {
                if $0.provider != $1.provider { return $0.provider < $1.provider }
                return $0.mode < $1.mode
            }

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

            // Honesty split: one eligibility predicate + attributed classifier.
            // Existing `providers` / `totalSavedTokens` semantics are unchanged.
            let honesty = try database.prepare("""
                SELECT
                    COALESCE(SUM(CASE
                        WHEN \(Self.displayedSavingsEligibilitySQL)
                             AND \(Self.attributedSavingsSQL)
                        THEN saved_tokens ELSE 0 END), 0),
                    COALESCE(SUM(CASE
                        WHEN \(Self.displayedSavingsEligibilitySQL)
                             AND \(Self.attributedSavingsSQL)
                        THEN runs ELSE 0 END), 0),
                    COALESCE(SUM(CASE
                        WHEN \(Self.displayedSavingsEligibilitySQL)
                             AND NOT (\(Self.attributedSavingsSQL))
                        THEN saved_tokens ELSE 0 END), 0),
                    COALESCE(SUM(CASE
                        WHEN \(Self.displayedSavingsEligibilitySQL)
                             AND NOT (\(Self.attributedSavingsSQL))
                        THEN runs ELSE 0 END), 0)
                FROM token_saver_savings_totals;
            """)
            defer { honesty.reset() }
            var attributedSaved = 0
            var attributedRuns = 0
            var unattributedSaved = 0
            var unattributedRuns = 0
            if try honesty.step() {
                attributedSaved = Int(honesty.columnInt64(0))
                attributedRuns = Int(honesty.columnInt64(1))
                unattributedSaved = Int(honesty.columnInt64(2))
                unattributedRuns = Int(honesty.columnInt64(3))
            }

            return TokenSaverSavingsSummary(
                providers: providers,
                daily: daily,
                modes: modes,
                dailyByProvider: dailyByProvider,
                windowByMode: windowByMode,
                attributedSavedTokens: attributedSaved,
                attributedRuns: attributedRuns,
                unattributedSavedTokens: unattributedSaved,
                unattributedRuns: unattributedRuns
            )
        }
    }

    private func dayStartMs(for date: Date) -> Int64 {
        Int64(calendar.startOfDay(for: date).timeIntervalSince1970 * 1000)
    }
}
