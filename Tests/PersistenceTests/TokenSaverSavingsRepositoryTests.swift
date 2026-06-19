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
}
