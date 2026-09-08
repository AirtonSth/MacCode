import XCTest
import Foundation
@testable import Persistence

final class TokenSaverDailyEconomyRepositoryTests: XCTestCase {
    private func makeDB() throws -> SQLiteDB {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ts-economy-\(UUID().uuidString).sqlite")
        let db = try SQLiteDB(path: url.path)
        try Schema.migrate(db)
        return db
    }

    func test_upsertAndReadToday() throws {
        let db = try makeDB()
        let repo = TokenSaverDailyEconomyRepository(db: db)
        let dayMs = repo.dayStartMs()
        let record = TokenSaverDailyEconomyRecord(
            dayStartMs: dayMs,
            measuredTokens: 250_000,
            dialectTokens: 1_000_000,
            graphifyTokens: 0,
            totalCredible: 1_250_000,
            windowUsageTokens: 170_000_000,
            formulaVersion: TokenSaverDailyEconomyRepository.formulaVersion,
            appliedOutputShare: 0.007,
            updatedAt: "2026-07-24T00:00:00Z"
        )
        _ = try repo.upsert(record)
        let loaded = try XCTUnwrap(repo.record(dayStartMs: dayMs))
        XCTAssertEqual(loaded.totalCredible, 1_250_000)
        XCTAssertEqual(loaded.measuredTokens, 250_000)
        XCTAssertEqual(loaded.dialectTokens, 1_000_000)
    }

    func test_weekIsSumOfDailyTotals() throws {
        // WHY: Week must be Σ(day.total_credible), not a re-estimate on the week aggregate.
        let db = try makeDB()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let repo = TokenSaverDailyEconomyRepository(db: db, calendar: cal)
        let day0 = try XCTUnwrap(DateComponents(calendar: cal, timeZone: cal.timeZone, year: 2026, month: 7, day: 20).date)
        let day1 = try XCTUnwrap(DateComponents(calendar: cal, timeZone: cal.timeZone, year: 2026, month: 7, day: 21).date)
        let day2 = try XCTUnwrap(DateComponents(calendar: cal, timeZone: cal.timeZone, year: 2026, month: 7, day: 22).date)
        for (day, total) in [(day0, 1_000_000), (day1, 2_000_000), (day2, 3_000_000)] {
            let ms = Int64(cal.startOfDay(for: day).timeIntervalSince1970 * 1000)
            _ = try repo.upsert(TokenSaverDailyEconomyRecord(
                dayStartMs: ms,
                measuredTokens: total / 5,
                dialectTokens: total - total / 5,
                graphifyTokens: 0,
                totalCredible: total,
                windowUsageTokens: 50_000_000,
                formulaVersion: "credible_v2",
                appliedOutputShare: 0.007,
                updatedAt: "t"
            ))
        }
        let from = Int64(cal.startOfDay(for: day0).timeIntervalSince1970 * 1000)
        let to = Int64(cal.startOfDay(for: day2).timeIntervalSince1970 * 1000)
        XCTAssertEqual(try repo.sumTotalCredible(fromDayStartMs: from, toDayStartMs: to), 6_000_000)
    }

    func test_windowTotal_countsEachThreadsLifetimeCacheOnceAndPreservesToday() throws {
        let db = try makeDB()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let repo = TokenSaverDailyEconomyRepository(db: db, calendar: cal)
        let savings = TokenSaverSavingsRepository(db: db, calendar: cal)
        let first = try XCTUnwrap(DateComponents(calendar: cal, year: 2026, month: 9, day: 7, hour: 12).date)
        let second = try XCTUnwrap(cal.date(byAdding: .day, value: 1, to: first))
        // A conversation and unscoped wraps span both days; another conversation
        // appears only on the second. Lifetime cache: 300 + 30 + 100 = 430.
        for (day, thread, saved) in [
            (first, "shared", 100), (first, "", 10),
            (second, "shared", 200), (second, "", 20),
            (second, "other", 40), (second, "other", 60)
        ] {
            try savings.record(provider: "codex", mode: "x", inputTokens: saved,
                               outputTokens: 0, delivered: true, threadID: thread, at: day)
        }
        for (day, measured, cache) in [(first, 110, 330), (second, 320, 430)] {
            try repo.upsert(TokenSaverDailyEconomyRecord(
                dayStartMs: repo.dayStartMs(for: day), measuredTokens: measured,
                dialectTokens: 10, graphifyTokens: 3, orchestrationTokens: 2,
                totalCredible: measured + 15 + cache, windowUsageTokens: 0,
                formulaVersion: TokenSaverDailyEconomyRepository.formulaVersion,
                appliedOutputShare: 0.007, updatedAt: "t"
            ))
        }
        let result = try repo.windowTotalCredible(
            fromDayStartMs: repo.dayStartMs(for: first),
            toDayStartMs: repo.dayStartMs(for: second),
            toDayEndMsExclusive: repo.dayEndMsExclusive(for: second)
        )
        XCTAssertEqual(result.total, 890, "460 daily savings + 430 unique cache, not 1220")
        XCTAssertEqual(result.economyDays, 2)
        XCTAssertEqual(try repo.record(dayStartMs: repo.dayStartMs(for: first))?.totalCredible, 455)
        XCTAssertEqual(try repo.record(dayStartMs: repo.dayStartMs(for: second))?.totalCredible, 765)
        let today = try repo.windowTotalCredible(
            fromDayStartMs: repo.dayStartMs(for: second),
            toDayStartMs: repo.dayStartMs(for: second),
            toDayEndMsExclusive: repo.dayEndMsExclusive(for: second)
        )
        XCTAssertEqual(today.total, 765)
    }

    func test_windowTotal_usesMeasuredOnlyForDaysWithoutEconomyRow() throws {
        let db = try makeDB()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let repo = TokenSaverDailyEconomyRepository(db: db, calendar: cal)
        let savings = TokenSaverSavingsRepository(db: db, calendar: cal)

        let dayOld = try XCTUnwrap(DateComponents(calendar: cal, timeZone: cal.timeZone, year: 2026, month: 7, day: 20, hour: 12).date)
        let dayNew = try XCTUnwrap(DateComponents(calendar: cal, timeZone: cal.timeZone, year: 2026, month: 7, day: 24, hour: 12).date)

        // Pre-feature day: only ledger pipes, no economy row.
        _ = try savings.record(provider: "claude", mode: "command-output (deterministic)", inputTokens: 1000, outputTokens: 100, at: dayOld) // 900

        // Feature day: economy with full formula total (current formula only).
        let newMs = Int64(cal.startOfDay(for: dayNew).timeIntervalSince1970 * 1000)
        _ = try repo.upsert(TokenSaverDailyEconomyRecord(
            dayStartMs: newMs,
            measuredTokens: 250_000,
            dialectTokens: 1_000_000,
            graphifyTokens: 0,
            totalCredible: 1_250_000,
            windowUsageTokens: 100_000_000,
            formulaVersion: TokenSaverDailyEconomyRepository.formulaVersion,
            appliedOutputShare: 0.007,
            updatedAt: "t"
        ))

        let from = Int64(cal.startOfDay(for: dayOld).timeIntervalSince1970 * 1000)
        let to = newMs
        let end = Int64((cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: dayNew))!).timeIntervalSince1970 * 1000)
        let result = try repo.windowTotalCredible(fromDayStartMs: from, toDayStartMs: to, toDayEndMsExclusive: end)
        // 900 measured-only + 1_250_000 economy
        XCTAssertEqual(result.total, 900 + 1_250_000)
        XCTAssertEqual(result.economyDays, 1)
        XCTAssertEqual(result.measuredOnlyDays, 1)
    }

    /// WHY: pre-v6 permanent-amort rows at ~hundreds of millions must not paint
    /// Week ~999M after a formula bump; stale rows fall back to measured pipes.
    func test_windowTotal_ignoresStaleFormulaRowsAndUsesMeasured() throws {
        let db = try makeDB()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let repo = TokenSaverDailyEconomyRepository(db: db, calendar: cal)
        let savings = TokenSaverSavingsRepository(db: db, calendar: cal)

        let day = try XCTUnwrap(DateComponents(calendar: cal, timeZone: cal.timeZone, year: 2026, month: 8, day: 4, hour: 12).date)
        _ = try savings.record(provider: "codex", mode: "x", inputTokens: 2_000_000, outputTokens: 0, at: day)
        let dayMs = Int64(cal.startOfDay(for: day).timeIntervalSince1970 * 1000)
        _ = try repo.upsert(TokenSaverDailyEconomyRecord(
            dayStartMs: dayMs,
            measuredTokens: 2_000_000,
            dialectTokens: 0,
            graphifyTokens: 0,
            totalCredible: 383_000_000,
            windowUsageTokens: 100_000_000,
            formulaVersion: "credible_v5",
            appliedOutputShare: 0.007,
            updatedAt: "t"
        ))
        let end = dayMs + 86_400_000
        let result = try repo.windowTotalCredible(
            fromDayStartMs: dayMs,
            toDayStartMs: dayMs,
            toDayEndMsExclusive: end
        )
        XCTAssertEqual(result.total, 2_000_000, "stale fantasy total_credible must not win")
        XCTAssertEqual(result.economyDays, 0)
        XCTAssertEqual(result.measuredOnlyDays, 1)
    }

    func test_v4_roundTripsDialectRawCapBindingAndFormulaVersion() throws {
        // WHY: collapse detection needs pre-cap legs + which bound applied; mixed
        // formula versions must be labelled (credible_v5), never silently compared.
        let db = try makeDB()
        let repo = TokenSaverDailyEconomyRepository(db: db)
        let dayMs = repo.dayStartMs()
        XCTAssertEqual(TokenSaverDailyEconomyRepository.formulaVersion, "credible_v10")
        let record = TokenSaverDailyEconomyRecord(
            dayStartMs: dayMs,
            measuredTokens: 2,
            dialectTokens: 8,
            graphifyTokens: 0,
            totalCredible: 10,
            windowUsageTokens: 78_658_351,
            formulaVersion: TokenSaverDailyEconomyRepository.formulaVersion,
            appliedOutputShare: 0.007,
            updatedAt: "2026-07-28T00:00:00Z",
            dialectRawTokens: 550_608,
            graphifyRawTokens: 12_345,
            capBinding: "no_proof_allowance",
            windowUsageBilledUnits: 9_832_294.0
        )
        _ = try repo.upsert(record)
        let loaded = try XCTUnwrap(repo.record(dayStartMs: dayMs))
        XCTAssertEqual(loaded.dialectRawTokens, 550_608)
        XCTAssertEqual(loaded.graphifyRawTokens, 12_345)
        XCTAssertEqual(loaded.capBinding, "no_proof_allowance")
        XCTAssertEqual(loaded.windowUsageBilledUnits, 9_832_294.0, accuracy: 0.001)
        XCTAssertEqual(loaded.formulaVersion, "credible_v10")
        XCTAssertEqual(loaded.totalCredible, 10)
    }
}
