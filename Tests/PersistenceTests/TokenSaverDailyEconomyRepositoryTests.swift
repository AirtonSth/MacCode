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

        // Feature day: economy with full formula total.
        let newMs = Int64(cal.startOfDay(for: dayNew).timeIntervalSince1970 * 1000)
        _ = try repo.upsert(TokenSaverDailyEconomyRecord(
            dayStartMs: newMs,
            measuredTokens: 250_000,
            dialectTokens: 1_000_000,
            graphifyTokens: 0,
            totalCredible: 1_250_000,
            windowUsageTokens: 100_000_000,
            formulaVersion: "credible_v2",
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
}
