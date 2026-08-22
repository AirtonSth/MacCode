import XCTest
@testable import Persistence

final class TokenSaverSavingsRepositoryTests: XCTestCase {
    private func makeDB() throws -> SQLiteDB {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return db
    }

    private func rawCount(_ db: SQLiteDB) throws -> Int {
        let stmt = try db.prepare("SELECT COUNT(*) FROM token_saver_savings;")
        defer { stmt.reset() }
        _ = try stmt.step()
        return Int(stmt.columnInt64(0))
    }

    private func rawTotalRuns(_ db: SQLiteDB) throws -> Int {
        let stmt = try db.prepare("SELECT COALESCE(SUM(runs), 0) FROM token_saver_savings_totals;")
        defer { stmt.reset() }
        _ = try stmt.step()
        return Int(stmt.columnInt64(0))
    }

    func test_recordAndSummaryAggregatesTotalsPerProviderAndAverage() throws {
        let db = try makeDB()
        let repo = TokenSaverSavingsRepository(db: db, retentionDays: 7)
        let now = Date(timeIntervalSince1970: 1_000_000_000)

        XCTAssertEqual(try repo.record(provider: "claude", mode: "longText", inputTokens: 1000, outputTokens: 200, at: now), 800)
        XCTAssertEqual(try repo.record(provider: "claude", mode: "longText", inputTokens: 500, outputTokens: 100, at: now), 400)
        XCTAssertEqual(try repo.record(provider: "codex", mode: "longText", inputTokens: 800, outputTokens: 300, at: now), 500)

        let summary = try repo.summary(now: now)
        XCTAssertEqual(summary.totalSavedTokens, 1700)
        XCTAssertEqual(summary.totalRuns, 3)
        XCTAssertEqual(summary.averageSavedPerRun, 567, "avg = round(1700/3) — this is the média the UI shows")

        let claude = try XCTUnwrap(summary.savings(for: "claude"))
        XCTAssertEqual(claude.savedTokens, 1200)
        XCTAssertEqual(claude.runs, 2)
        XCTAssertEqual(claude.inputTokens, 1500)
        XCTAssertEqual(claude.outputTokens, 300)

        let codex = try XCTUnwrap(summary.savings(for: "codex"))
        XCTAssertEqual(codex.savedTokens, 500)
        XCTAssertEqual(codex.runs, 1)
    }

    func test_negativeDeltaNeverProducesNegativeSavings() throws {
        let db = try makeDB()
        let repo = TokenSaverSavingsRepository(db: db)
        // "Compressed" output larger than input (model misbehavior) → 0 saved.
        XCTAssertEqual(try repo.record(provider: "claude", mode: "x", inputTokens: 100, outputTokens: 250), 0)
        XCTAssertEqual(try repo.summary().totalSavedTokens, 0)
    }

    func test_explicitSavedTokensCanUseModeSpecificFormula() throws {
        let db = try makeDB()
        let repo = TokenSaverSavingsRepository(db: db)

        XCTAssertEqual(
            try repo.record(provider: "codex", mode: "sr1-humanize", inputTokens: 180, outputTokens: 60, savedTokens: 120),
            120
        )

        let summary = try repo.summary()
        let codex = try XCTUnwrap(summary.savings(for: "codex"))
        XCTAssertEqual(codex.inputTokens, 180)
        XCTAssertEqual(codex.outputTokens, 60)
        XCTAssertEqual(codex.savedTokens, 120)
    }

    func test_sameLogicalDeliveryRetryIsCountedExactlyOnce() throws {
        // WHY: the first HTTP 200 can be lost after SQLite commits. The managed
        // CLI retries the same request, which must not inflate rows or totals.
        let db = try makeDB()
        let repo = TokenSaverSavingsRepository(db: db)
        let key = "request-123"
        let now = Date(timeIntervalSince1970: 1_000_000_000)

        XCTAssertEqual(try repo.record(
            provider: "claude", mode: "command-output", inputTokens: 1_000,
            outputTokens: 100, savedTokens: 900, delivered: true,
            threadID: "thread-1", idempotencyKey: key, at: now
        ), 900)
        XCTAssertEqual(try repo.record(
            provider: "claude", mode: "command-output", inputTokens: 1_000,
            outputTokens: 100, savedTokens: 900, delivered: true,
            threadID: "thread-1", idempotencyKey: key, at: now.addingTimeInterval(1)
        ), 0, "an exact retry must report no newly persisted savings")

        let summary = try repo.summary(now: now.addingTimeInterval(1))
        XCTAssertEqual(try rawCount(db), 1)
        XCTAssertEqual(summary.totalRuns, 1)
        XCTAssertEqual(summary.totalSavedTokens, 900)
        XCTAssertEqual(try repo.savedTokens(forThreadID: "thread-1"), 900,
                       "the permanent thread accumulator must also remain idempotent")
    }

    func test_reusedIdempotencyKeyWithDifferentSavingsFailsLoudAndAtomically() throws {
        // WHY: silently treating a changed payload as a retry would conceal an
        // identity collision and make the accounting unverifiable.
        let db = try makeDB()
        let repo = TokenSaverSavingsRepository(db: db)
        _ = try repo.record(
            provider: "codex", mode: "command-output", inputTokens: 500,
            outputTokens: 100, savedTokens: 400, delivered: true,
            idempotencyKey: "request-conflict"
        )

        XCTAssertThrowsError(try repo.record(
            provider: "codex", mode: "command-output", inputTokens: 500,
            outputTokens: 90, savedTokens: 410, delivered: true,
            idempotencyKey: "request-conflict"
        )) { error in
            XCTAssertEqual(
                error as? TokenSaverSavingsRepositoryError,
                .idempotencyConflict("request-conflict")
            )
        }
        XCTAssertEqual(try rawCount(db), 1)
        XCTAssertEqual(try repo.summary().totalRuns, 1,
                       "a conflicting retry must roll back before touching totals")
        XCTAssertEqual(try repo.summary().totalSavedTokens, 400)
    }

    func test_retentionKeepsAtLeastSevenDaysAndPrunesOnlyEventRows() throws {
        let db = try makeDB()
        let repo = TokenSaverSavingsRepository(db: db, retentionDays: 1)
        let now = Date(timeIntervalSince1970: 1_000_000_000)

        // Caller-requested retention below one week must still keep a full week.
        _ = try repo.record(provider: "claude", mode: "x", inputTokens: 50, outputTokens: 10, at: now.addingTimeInterval(-6 * 86_400))
        // An 8-day-old row (older than the window).
        _ = try repo.record(provider: "claude", mode: "x", inputTokens: 999, outputTokens: 0, at: now.addingTimeInterval(-8 * 86_400))
        // A fresh row at `now` — its insert prunes anything older than now-7d.
        _ = try repo.record(provider: "claude", mode: "x", inputTokens: 100, outputTokens: 10, at: now)

        XCTAssertEqual(try rawCount(db), 2, "event history must keep at least the last 7 days, even if a caller requests less")
        XCTAssertEqual(try rawTotalRuns(db), 3, "the permanent total must keep counting pruned events")
        let summary = try repo.summary(now: now)
        XCTAssertEqual(summary.totalSavedTokens, 1_129)
        XCTAssertEqual(summary.totalRuns, 3)
        XCTAssertEqual(summary.daily.map(\.savedTokens).reduce(0, +), 130, "daily report buckets stay limited to retained event rows")
    }

    func test_totalSavedTokensKeepAddingAfterReportWindowPrunes() throws {
        let db = try makeDB()
        let repo = TokenSaverSavingsRepository(db: db, retentionDays: 7)
        let now = Date(timeIntervalSince1970: 1_000_000_000)

        _ = try repo.record(provider: "codex", mode: "command-output", inputTokens: 84, outputTokens: 51, savedTokens: 33, at: now.addingTimeInterval(-9 * 86_400))
        _ = try repo.record(provider: "codex", mode: "sr1-humanize", inputTokens: 192, outputTokens: 132, savedTokens: 60, at: now)

        XCTAssertEqual(try rawCount(db), 1)
        let summary = try repo.summary(now: now)
        XCTAssertEqual(summary.totalSavedTokens, 93, "user-visible savings must be all saved tokens, not only the unpruned report rows")
        XCTAssertEqual(summary.totalRuns, 2)
        let codex = try XCTUnwrap(summary.savings(for: "codex"))
        XCTAssertEqual(codex.savedTokens, 93)
        XCTAssertEqual(codex.runs, 2)
    }

    func test_dailyBucketsGroupByCalendarDay() throws {
        let db = try makeDB()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let repo = TokenSaverSavingsRepository(db: db, retentionDays: 7, calendar: calendar)
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        _ = try repo.record(provider: "claude", mode: "x", inputTokens: 100, outputTokens: 40, at: now)
        _ = try repo.record(provider: "codex", mode: "x", inputTokens: 50, outputTokens: 10, at: now)
        // Different calendar day, still inside the window.
        _ = try repo.record(provider: "claude", mode: "x", inputTokens: 200, outputTokens: 100, at: now.addingTimeInterval(-2 * 86_400))

        let summary = try repo.summary(now: now)
        XCTAssertEqual(summary.daily.count, 2, "two distinct calendar days must produce two daily buckets")
        XCTAssertEqual(summary.daily.map(\.savedTokens).reduce(0, +), summary.totalSavedTokens)
    }

    func test_dailyBucketsSeparateEventsAcrossMidnight() throws {
        let db = try makeDB()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let repo = TokenSaverSavingsRepository(db: db, retentionDays: 7, calendar: calendar)
        let beforeMidnight = try XCTUnwrap(DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 17,
            hour: 23,
            minute: 59,
            second: 59
        ).date)
        let oneSecondAfterMidnight = try XCTUnwrap(DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 18,
            hour: 0,
            minute: 0,
            second: 1
        ).date)

        _ = try repo.record(provider: "claude", mode: "x", inputTokens: 100, outputTokens: 10, at: beforeMidnight)
        _ = try repo.record(provider: "codex", mode: "x", inputTokens: 200, outputTokens: 20, at: oneSecondAfterMidnight)

        let summary = try repo.summary(now: oneSecondAfterMidnight)

        XCTAssertEqual(summary.daily.count, 2, "23:59:59 and 00:00:01 must register in different Daily buckets")
        XCTAssertEqual(summary.daily.map(\.savedTokens), [90, 180])
        XCTAssertEqual(summary.daily.map(\.savedTokens).reduce(0, +), 270,
                       "Week/report-window savings must include both calendar-day buckets")
    }

    /// WHY: day-card amort used permanent thread totals, so one long thread's
    /// lifetime 8M × 50 turns painted Today ~400M and Week ~999M. Inputs must
    /// only sum savings delivered inside the requested window.
    func test_threadCacheAmortizationInputs_areDayScopedNotPermanent() throws {
        let db = try makeDB()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let repo = TokenSaverSavingsRepository(db: db, retentionDays: 14, calendar: calendar)
        let today = try XCTUnwrap(DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: 2026, month: 8, day: 5, hour: 12
        ).date)
        let yesterday = try XCTUnwrap(DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: 2026, month: 8, day: 4, hour: 12
        ).date)
        let thread = "THREAD-AMORT-1"
        // Lifetime pile-up on the same thread (must NOT enter today's amort base).
        _ = try repo.record(
            provider: "codex", mode: "x", inputTokens: 8_000_000, outputTokens: 0,
            attributability: "prompt_bound", delivered: true, threadID: thread, at: yesterday
        )
        _ = try repo.record(
            provider: "codex", mode: "x", inputTokens: 100_000, outputTokens: 0,
            attributability: "prompt_bound", delivered: true, threadID: thread, at: today
        )
        _ = try repo.record(
            provider: "codex", mode: "x", inputTokens: 50_000, outputTokens: 0,
            attributability: "prompt_bound", delivered: true, threadID: thread, at: today
        )
        let dayStart = Int64(calendar.startOfDay(for: today).timeIntervalSince1970 * 1000)
        let dayEnd = dayStart + 86_400_000
        let inputs = try repo.threadCacheAmortizationInputs(
            dayStartMs: dayStart,
            dayEndMsExclusive: dayEnd
        )
        XCTAssertEqual(inputs.count, 1)
        let row = try XCTUnwrap(inputs.first)
        XCTAssertEqual(row.threadID, thread)
        XCTAssertEqual(row.savedTokens, 150_000,
                       "must sum only today's delivered savings, not permanent 8.15M")
        XCTAssertEqual(row.runs, 2, "run count is today's compress events only")
        XCTAssertEqual(row.provider, "codex")
    }

    /// The windowed reconciliation: per-(provider, day) buckets must sum to the
    /// collapsed daily bucket for the same day, so the scoped per-provider rows in
    /// the UI reconcile with the windowed headline (which reads the collapsed daily).
    func test_dailyByProviderSplitsBucketsAndReconcilesWithCollapsedDaily() throws {
        let db = try makeDB()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let repo = TokenSaverSavingsRepository(db: db, retentionDays: 7, calendar: calendar)
        let today = try XCTUnwrap(DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: 2026, month: 6, day: 18, hour: 12
        ).date)
        let yesterday = try XCTUnwrap(DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: 2026, month: 6, day: 17, hour: 12
        ).date)

        _ = try repo.record(provider: "claude", mode: "longText", inputTokens: 1000, outputTokens: 400, at: today)   // 600
        _ = try repo.record(provider: "codex", mode: "longText", inputTokens: 800, outputTokens: 300, at: today)     // 500
        _ = try repo.record(provider: "unknown", mode: "command-output", inputTokens: 3000, outputTokens: 470, at: today) // 2530
        _ = try repo.record(provider: "claude", mode: "longText", inputTokens: 500, outputTokens: 100, at: yesterday) // 400

        let s = try repo.summary(now: today)

        // Per-(provider, day) rows carry the provider dimension that collapsed
        // `daily` lacks: claude/codex/unknown today + claude yesterday.
        XCTAssertEqual(s.dailyByProvider.count, 4)

        // For every calendar day, the per-provider buckets sum to the collapsed bucket.
        for bucket in s.daily {
            let perProviderSum = s.dailyByProvider
                .filter { $0.dayStartMs == bucket.dayStartMs }
                .reduce(0) { $0 + $1.savedTokens }
            XCTAssertEqual(perProviderSum, bucket.savedTokens,
                           "per-provider buckets must sum to the collapsed daily bucket for the same day")
        }

        let todayStartMs = Int64(calendar.startOfDay(for: today).timeIntervalSince1970 * 1000)
        let todayClaude = s.dailyByProvider.first { $0.provider == "claude" && $0.dayStartMs == todayStartMs }?.savedTokens
        let todayCodex = s.dailyByProvider.first { $0.provider == "codex" && $0.dayStartMs == todayStartMs }?.savedTokens
        let todayUnknown = s.dailyByProvider.first { $0.provider == "unknown" && $0.dayStartMs == todayStartMs }?.savedTokens
        XCTAssertEqual(todayClaude, 600)
        XCTAssertEqual(todayCodex, 500)
        XCTAssertEqual(todayUnknown, 2530)
        let todayCollapsed = s.daily.first { $0.dayStartMs == todayStartMs }?.savedTokens
        XCTAssertEqual((todayClaude ?? 0) + (todayCodex ?? 0) + (todayUnknown ?? 0), todayCollapsed,
                       "Today's Claude + Codex + CLI rows must equal the Today headline (collapsed daily)")
    }

    func test_windowByModeReconcilesWithCollapsedDaily() throws {
        // WHY: technique mix for Today/Week must sum to the same window as the ring.
        let db = try makeDB()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let repo = TokenSaverSavingsRepository(db: db, retentionDays: 7, calendar: calendar)
        let today = try XCTUnwrap(DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: 2026, month: 6, day: 18, hour: 12
        ).date)
        let yesterday = try XCTUnwrap(DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: 2026, month: 6, day: 17, hour: 12
        ).date)

        _ = try repo.record(provider: "claude", mode: "command-output (deterministic)", inputTokens: 1000, outputTokens: 400, at: today) // 600
        _ = try repo.record(provider: "codex", mode: "command-output (model)", inputTokens: 800, outputTokens: 300, at: today) // 500
        _ = try repo.record(provider: "claude", mode: "sr1-humanize", inputTokens: 90, outputTokens: 30, savedTokens: 60, at: yesterday)

        let s = try repo.summary(now: today)
        let windowModeSum = s.windowByMode.reduce(0) { $0 + $1.savedTokens }
        let dailySum = s.daily.reduce(0) { $0 + $1.savedTokens }
        XCTAssertEqual(windowModeSum, dailySum, "windowByMode must reconcile with daily window")
        XCTAssertEqual(s.windowByMode.count, 3)
        XCTAssertEqual(
            s.windowByMode.first { $0.mode == "command-output (deterministic)" }?.savedTokens,
            600
        )
    }

    /// The Token Saver card bug: direct `distill` CLI usage is recorded as provider
    /// "unknown", so the headline total counted it but the per-provider (Claude/Codex)
    /// rows showed 0 — the numbers didn't reconcile. This proves the displayed rows
    /// (Claude + Codex + "CLI & other") sum exactly to the headline total.
    func test_displayedSavingsReconcileWithHeadlineTotal() throws {
        let db = try makeDB()
        let repo = TokenSaverSavingsRepository(db: db, retentionDays: 7)
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        // 9 command-output runs from the direct CLI → provider "unknown" (the screenshot).
        for _ in 0..<9 {
            _ = try repo.record(provider: "unknown", mode: "command-output", inputTokens: 3000, outputTokens: 470, at: now)
        }
        _ = try repo.record(provider: "claude", mode: "longText", inputTokens: 100, outputTokens: 40, at: now)

        let s = try repo.summary(now: now)
        let claude = s.savings(for: "claude")?.savedTokens ?? 0
        let codex = s.savings(for: "codex")?.savedTokens ?? 0
        let other = s.savedTokens(forProvidersOtherThan: ["claude", "codex"])

        XCTAssertEqual(codex, 0)
        XCTAssertGreaterThan(other, 0, "the unknown/CLI savings must be surfaced, not hidden")
        XCTAssertEqual(other, 9 * (3000 - 470))
        // The invariant the UI now upholds: visible rows sum to the headline total.
        XCTAssertEqual(claude + codex + other, s.totalSavedTokens,
                       "Claude + Codex + 'CLI & other' must equal the headline 'Saved N'")
        XCTAssertEqual(s.runs(forProvidersOtherThan: ["claude", "codex"]), 9)
    }

    /// Honesty axes persist on the event row so later readers can attribute savings
    /// without re-deriving from mode/provider alone.
    func test_recordPersistsHonestyAxesAndEngineContentType() throws {
        let db = try makeDB()
        let repo = TokenSaverSavingsRepository(db: db)
        let now = Date(timeIntervalSince1970: 1_000_000_000)

        _ = try repo.record(
            provider: "claude",
            mode: "longText",
            inputTokens: 500,
            outputTokens: 100,
            savedTokens: 400,
            cacheState: "prompt",
            contentType: "prose",
            engine: "encoder_bert",
            attributability: "prompt_bound",
            delivered: true,
            governance: #"{"lane":"longText"}"#,
            at: now
        )

        let stmt = try db.prepare("""
            SELECT content_type, engine, attributability, delivered, governance_json, cache_state
            FROM token_saver_savings;
            """)
        defer { stmt.reset() }
        XCTAssertTrue(try stmt.step())
        XCTAssertEqual(stmt.columnText(0), "prose")
        XCTAssertEqual(stmt.columnText(1), "encoder_bert")
        XCTAssertEqual(stmt.columnText(2), "prompt_bound")
        XCTAssertEqual(stmt.columnInt64(3), 1)
        XCTAssertEqual(stmt.columnText(4), #"{"lane":"longText"}"#)
        XCTAssertEqual(stmt.columnText(5), "prompt")

        let summary = try repo.summary(now: now)
        XCTAssertEqual(summary.attributedSavedTokens, 400)
        XCTAssertEqual(summary.attributedRuns, 1)
        XCTAssertEqual(summary.unattributedSavedTokens, 0)
        XCTAssertEqual(summary.unattributedRuns, 0)
    }

    /// HISTORICAL-ROW RULE: pre-migration rows keep column defaults
    /// (delivered=0, attributability='unknown'). A real-provider row must still
    /// count toward the attributed display total so all-time cannot regress to zero.
    func test_historicalRowRuleKeepsPreMigrationProviderAttributedRowCounted() throws {
        let db = try makeDB()
        let repo = TokenSaverSavingsRepository(db: db)
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let iso = ISO8601DateFormatter().string(from: now)
        let ms = Int64(now.timeIntervalSince1970 * 1000)

        // Simulate a pre-migration write: only the original columns, so honesty
        // axes take their NOT NULL DEFAULT values (unknown / 0 / '{}').
        try db.performSync { database in
            let insert = try database.prepare("""
                INSERT INTO token_saver_savings
                    (provider, mode, input_tokens, output_tokens, saved_tokens, created_at, created_at_ms, cache_state)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """)
            defer { insert.reset() }
            try insert.bind(1, "claude")
            try insert.bind(2, "longText")
            try insert.bind(3, 1000)
            try insert.bind(4, 200)
            try insert.bind(5, 800)
            try insert.bind(6, iso)
            try insert.bind(7, ms)
            try insert.bind(8, "unknown")
            _ = try insert.step()

            let total = try database.prepare("""
                INSERT INTO token_saver_savings_totals
                    (provider, mode, input_tokens, output_tokens, saved_tokens, runs, updated_at)
                VALUES (?, ?, ?, ?, ?, 1, ?);
                """)
            defer { total.reset() }
            try total.bind(1, "claude")
            try total.bind(2, "longText")
            try total.bind(3, 1000)
            try total.bind(4, 200)
            try total.bind(5, 800)
            try total.bind(6, iso)
            _ = try total.step()
        }

        // Defaults landed as expected for an unclassed historical row.
        let check = try db.prepare("""
            SELECT attributability, delivered, governance_json
            FROM token_saver_savings_totals WHERE provider = 'claude';
            """)
        defer { check.reset() }
        XCTAssertTrue(try check.step())
        XCTAssertEqual(check.columnText(0), "unknown")
        XCTAssertEqual(check.columnInt64(1), 0)
        XCTAssertEqual(check.columnText(2), "{}")

        let summary = try repo.summary(now: now)
        XCTAssertEqual(summary.totalSavedTokens, 800, "existing total semantics still sum the permanent accumulator")
        XCTAssertEqual(
            summary.attributedSavedTokens, 800,
            "WHY: historical delivered=0 + attributability=unknown + real provider must still count as attributed"
        )
        XCTAssertEqual(summary.attributedRuns, 1)
        XCTAssertEqual(summary.unattributedSavedTokens, 0)
    }

    /// A measured-but-discarded compression (delivered=0 with a known class) must
    /// not inflate the honesty display totals even if the event row is stored.
    func test_deliveredZeroExcludedFromDisplayedHonestyTotals() throws {
        let db = try makeDB()
        let repo = TokenSaverSavingsRepository(db: db)
        let now = Date(timeIntervalSince1970: 1_000_000_000)

        // Delivered compression — counts. Distinct (provider, mode) keys so the
        // permanent accumulator does not merge delivered/non-delivered classes.
        _ = try repo.record(
            provider: "codex",
            mode: "command-output",
            inputTokens: 300,
            outputTokens: 100,
            savedTokens: 200,
            attributability: "not_prompt_bound",
            delivered: true,
            at: now
        )
        // Verbatim fail-open — stored, but excluded from displayed honesty totals.
        _ = try repo.record(
            provider: "codex",
            mode: "command-output-failopen",
            inputTokens: 500,
            outputTokens: 500,
            savedTokens: 0,
            attributability: "not_prompt_bound",
            delivered: false,
            at: now
        )
        // Discarded compression with non-zero computed savings still excluded.
        _ = try repo.record(
            provider: "unknown",
            mode: "command-output-discarded",
            inputTokens: 1000,
            outputTokens: 100,
            savedTokens: 900,
            attributability: "not_prompt_bound",
            delivered: false,
            at: now
        )

        let summary = try repo.summary(now: now)
        XCTAssertEqual(summary.attributedSavedTokens, 200)
        XCTAssertEqual(summary.attributedRuns, 1)
        XCTAssertEqual(summary.unattributedSavedTokens, 0, "delivered=0 rows must not appear in unattributed either")
        XCTAssertEqual(summary.unattributedRuns, 0)
        // Permanent accumulator still records every write (existing field semantics).
        XCTAssertEqual(summary.totalSavedTokens, 1100)
        XCTAssertEqual(summary.totalRuns, 3)
    }

    func test_threadTotals_accumulateDeliveredOnly_andSurviveEventPrune() throws {
        // WHY: Agent final-reply footer needs a permanent per-thread total that
        // does not vanish when event rows age out of the retention window.
        let db = try makeDB()
        let repo = TokenSaverSavingsRepository(db: db, retentionDays: 1)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let threadA = "11111111-1111-1111-1111-111111111111"
        let threadB = "22222222-2222-2222-2222-222222222222"

        _ = try repo.record(
            provider: "claude",
            mode: "command-output",
            inputTokens: 1_000,
            outputTokens: 100,
            savedTokens: 900,
            delivered: true,
            threadID: threadA,
            at: now.addingTimeInterval(-10 * 86_400)
        )
        _ = try repo.record(
            provider: "claude",
            mode: "command-output",
            inputTokens: 500,
            outputTokens: 50,
            savedTokens: 450,
            delivered: true,
            threadID: threadA,
            at: now
        )
        // Undelivered forfeit must not inflate the user-facing thread total.
        _ = try repo.record(
            provider: "claude",
            mode: "command-output (discarded)",
            inputTokens: 800,
            outputTokens: 80,
            savedTokens: 720,
            delivered: false,
            threadID: threadA,
            at: now
        )
        _ = try repo.record(
            provider: "codex",
            mode: "command-output",
            inputTokens: 200,
            outputTokens: 20,
            savedTokens: 180,
            delivered: true,
            threadID: threadB,
            at: now
        )

        XCTAssertEqual(try repo.savedTokens(forThreadID: threadA), 1_350)
        XCTAssertEqual(try repo.savedTokens(forThreadID: threadB), 180)
        XCTAssertEqual(try repo.savedTokens(forThreadID: ""), 0)
        XCTAssertEqual(try repo.savedTokens(forThreadID: "missing"), 0)

        // Prune deletes old event rows but must keep the permanent thread total.
        try repo.prune(now: now)
        XCTAssertEqual(try repo.savedTokens(forThreadID: threadA), 1_350,
                       "thread total must survive event prune")
    }
}
