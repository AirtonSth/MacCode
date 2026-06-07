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

    func test_retentionKeepsOnlySevenDaysAndPrunesPhysically() throws {
        let db = try makeDB()
        let repo = TokenSaverSavingsRepository(db: db, retentionDays: 7)
        let now = Date(timeIntervalSince1970: 1_000_000_000)

        // An 8-day-old row (older than the window).
        _ = try repo.record(provider: "claude", mode: "x", inputTokens: 999, outputTokens: 0, at: now.addingTimeInterval(-8 * 86_400))
        // A fresh row at `now` — its insert prunes anything older than now-7d.
        _ = try repo.record(provider: "claude", mode: "x", inputTokens: 100, outputTokens: 10, at: now)

        XCTAssertEqual(try rawCount(db), 1, "history older than 7 days must be physically deleted, not just hidden")
        let summary = try repo.summary(now: now)
        XCTAssertEqual(summary.totalSavedTokens, 90)
        XCTAssertEqual(summary.totalRuns, 1)
    }

    func test_dailyBucketsGroupByUTCDay() throws {
        let db = try makeDB()
        let repo = TokenSaverSavingsRepository(db: db, retentionDays: 7)
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        _ = try repo.record(provider: "claude", mode: "x", inputTokens: 100, outputTokens: 40, at: now)
        _ = try repo.record(provider: "codex", mode: "x", inputTokens: 50, outputTokens: 10, at: now)
        // Different UTC day, still inside the window.
        _ = try repo.record(provider: "claude", mode: "x", inputTokens: 200, outputTokens: 100, at: now.addingTimeInterval(-2 * 86_400))

        let summary = try repo.summary(now: now)
        XCTAssertEqual(summary.daily.count, 2, "two distinct UTC days must produce two daily buckets")
        XCTAssertEqual(summary.daily.map(\.savedTokens).reduce(0, +), summary.totalSavedTokens)
    }
}
