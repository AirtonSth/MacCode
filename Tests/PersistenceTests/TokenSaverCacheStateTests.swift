import XCTest
@testable import Persistence

final class TokenSaverCacheStateTests: XCTestCase {
    private func makeDB() throws -> SQLiteDB {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return db
    }

    func test_schemaVersionIs29() {
        XCTAssertEqual(Schema.currentVersion, 29)
    }

    func test_recordStoresCacheState() throws {
        let db = try makeDB()
        let repo = TokenSaverSavingsRepository(db: db)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try repo.record(provider: "claude", mode: "command-output", inputTokens: 100, outputTokens: 10, cacheState: "tool_output_oneshot", at: now)
        _ = try repo.record(provider: "claude", mode: "longText", inputTokens: 50, outputTokens: 20, cacheState: "prompt", at: now)

        var states: [String: Int] = [:]
        let stmt = try db.prepare("SELECT cache_state, COUNT(*) FROM token_saver_savings GROUP BY cache_state;")
        defer { stmt.reset() }
        while try stmt.step() { states[stmt.columnText(0) ?? ""] = Int(stmt.columnInt64(1)) }
        XCTAssertEqual(states["tool_output_oneshot"], 1)
        XCTAssertEqual(states["prompt"], 1)
    }

    func test_defaultCacheStateIsUnknown() throws {
        let db = try makeDB()
        let repo = TokenSaverSavingsRepository(db: db)
        _ = try repo.record(provider: "codex", mode: "command-output", inputTokens: 10, outputTokens: 1)
        let stmt = try db.prepare("SELECT cache_state FROM token_saver_savings LIMIT 1;")
        defer { stmt.reset() }
        _ = try stmt.step()
        XCTAssertEqual(stmt.columnText(0), "unknown")
    }

    func test_additiveMigrationKeepsExistingRows() throws {
        let db = try makeDB()
        try db.execute("""
            INSERT INTO token_saver_savings (provider, mode, input_tokens, output_tokens, saved_tokens, created_at, created_at_ms)
            VALUES ('x','longText',5,1,4,'2026-01-01T00:00:00Z',1);
        """)
        try Schema.migrate(db) // re-run must be a no-op and not drop the row
        let stmt = try db.prepare("SELECT cache_state FROM token_saver_savings WHERE provider='x';")
        defer { stmt.reset() }
        XCTAssertTrue(try stmt.step())
        XCTAssertEqual(stmt.columnText(0), "unknown", "pre-existing rows get the new column's default")
    }
}
