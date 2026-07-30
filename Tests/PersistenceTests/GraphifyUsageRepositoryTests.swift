import XCTest
@testable import Persistence
@testable import CoreModel

final class GraphifyUsageRepositoryTests: XCTestCase {
    private var dbPath: String!
    private var db: SQLiteDB!
    private var repo: GraphifyUsageRepository!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "graphify-usage-\(UUID().uuidString).sqlite"
        db = try SQLiteDB(path: dbPath)
        try Schema.migrate(db)
        repo = GraphifyUsageRepository(db: db)
    }

    override func tearDownWithError() throws {
        db = nil
        repo = nil
        if let dbPath { try? FileManager.default.removeItem(atPath: dbPath) }
    }

    func test_schema54_createsTable() throws {
        XCTAssertEqual(Schema.currentVersion, Schema.checkpointListSchemaVersion)
        let count: Int = try db.performSync { database in
            let stmt = try database.prepare(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='graphify_usage_events';"
            )
            defer { stmt.reset() }
            _ = try stmt.step()
            return Int(stmt.columnInt64(0))
        }
        XCTAssertEqual(count, 1)
    }

    func test_insertDedupeAndDayCount_onlySuccessful() throws {
        // WHY: Claude may replay tool blocks; (run,item,sub) must count once.
        // Pending (ok=0) must not inflate the day signal count.
        let dayStart: Int64 = 1_700_000_000_000
        let e1 = GraphifyUsageEvent(
            createdAtMs: dayStart + 1_000,
            provider: "claude",
            runId: "run-1",
            itemId: "tool-1",
            subcommand: "query",
            answerTokens: 0,
            ok: false
        )
        try repo.insert(e1)
        try repo.insert(e1) // duplicate
        try repo.markSucceeded(runId: "run-1", itemId: "tool-1", answerTokens: 10)
        try repo.insert(
            GraphifyUsageEvent(
                createdAtMs: dayStart + 2_000,
                provider: "claude",
                runId: "run-1",
                itemId: "tool-2",
                subcommand: "path",
                answerTokens: 50,
                ok: true
            )
        )
        // Pending third signal — not yet ok.
        try repo.insert(
            GraphifyUsageEvent(
                createdAtMs: dayStart + 2_500,
                provider: "claude",
                runId: "run-1",
                itemId: "tool-2b",
                subcommand: "explain",
                ok: false
            )
        )
        // Exploration sample must not count as signal.
        try repo.insertExplorationSample(
            createdAtMs: dayStart + 3_000,
            provider: "claude",
            runId: "run-1",
            itemId: "tool-3",
            answerTokens: 2_000,
            toolName: "Read",
            ok: true
        )

        let count = try repo.signalCount(fromMs: dayStart, toMsExclusive: dayStart + 86_400_000)
        XCTAssertEqual(count, 2)
        let answers = try repo.answerTokensSum(fromMs: dayStart, toMsExclusive: dayStart + 86_400_000)
        XCTAssertEqual(answers, 60)
    }

    func test_deleteItem_removesFailed() throws {
        try repo.insert(
            GraphifyUsageEvent(
                createdAtMs: 100,
                provider: "claude",
                runId: "r",
                itemId: "i",
                subcommand: "query",
                ok: false
            )
        )
        try repo.deleteItem(runId: "r", itemId: "i")
        XCTAssertEqual(try repo.signalCount(fromMs: 0, toMsExclusive: 1_000), 0)
    }

    func test_markSucceeded_countsAndSums() throws {
        try repo.insert(
            GraphifyUsageEvent(
                createdAtMs: 100,
                provider: "claude",
                runId: "r",
                itemId: "i",
                subcommand: "query",
                answerTokens: 0,
                ok: false
            )
        )
        XCTAssertEqual(try repo.signalCount(fromMs: 0, toMsExclusive: 1_000), 0)
        try repo.markSucceeded(runId: "r", itemId: "i", answerTokens: 420)
        XCTAssertEqual(try repo.signalCount(fromMs: 0, toMsExclusive: 1_000), 1)
        XCTAssertEqual(try repo.answerTokensSum(fromMs: 0, toMsExclusive: 1_000), 420)
    }

    func test_medianExplorationRequiresMinSamples() throws {
        let now: Int64 = 2_000_000_000_000
        for i in 0..<7 {
            try repo.insertExplorationSample(
                createdAtMs: now - Int64(i) * 1_000,
                provider: "claude",
                runId: "r\(i)",
                itemId: "i\(i)",
                answerTokens: 1_000 + i * 100,
                toolName: "Read",
                ok: true
            )
        }
        XCTAssertNil(try repo.medianExplorationTokens(nowMs: now, minSamples: 8))

        try repo.insertExplorationSample(
            createdAtMs: now - 8_000,
            provider: "claude",
            runId: "r8",
            itemId: "i8",
            answerTokens: 2_000,
            toolName: "Grep",
            ok: true
        )
        let median = try repo.medianExplorationTokens(nowMs: now, minSamples: 8)
        XCTAssertNotNil(median)
        XCTAssertGreaterThan(median ?? 0, 0)
    }

    func test_pruneDropsOldRows() throws {
        let now: Int64 = 3_000_000_000_000
        let old = now - Int64(GraphifyUsageRepository.retentionDays + 1) * 86_400_000
        try repo.insert(
            GraphifyUsageEvent(
                createdAtMs: old,
                provider: "claude",
                runId: "old",
                itemId: "old",
                subcommand: "query",
                ok: true
            )
        )
        try repo.insert(
            GraphifyUsageEvent(
                createdAtMs: now - 1_000,
                provider: "claude",
                runId: "new",
                itemId: "new",
                subcommand: "query",
                ok: true
            )
        )
        try repo.prune(nowMs: now)
        XCTAssertEqual(try repo.signalCount(fromMs: 0, toMsExclusive: now + 1), 1)
    }
}
