import XCTest
@testable import Persistence
import CoreModel

/// QA-mac:49 -- prove write atomicity when a failure occurs BETWEEN statements.
///
/// The crash/interruption-injection hook :49 proposed exists to prove one thing:
/// a failure partway through a multi-statement write must leave the database in
/// its pre-write state, never a partial commit (T002/T021/T034). That guarantee is
/// structural -- SQLiteDB.transaction wraps the block in BEGIN IMMEDIATE and
/// ROLLBACKs on any thrown error -- so it is provable with a NATURAL mid-block
/// throw, without adding a test-only injection hook to the hot SQLite path.
final class TransactionAtomicityTests: XCTestCase {

    private struct InjectedFailure: Error {}

    private func makeDB() throws -> SQLiteDB {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RC2Atomic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: dir.appendingPathComponent("atomic.sqlite").path)
        try Schema.migrate(db)
        return db
    }

    func test_failureBetweenStatementsRollsBackEntireTransaction() throws {
        let db = try makeDB()
        let repo = NotificationRepository(db: db)

        // A transaction that inserts the first row, then fails BEFORE the second.
        // The whole unit must roll back: neither row may survive.
        XCTAssertThrowsError(
            try db.transaction {
                try repo.insert(AppNotification(id: "first", title: "a", category: "atomic"))
                throw InjectedFailure()   // crash/interruption between statements
                // unreachable: try repo.insert(AppNotification(id: "second", ...))
            }
        )

        XCTAssertEqual(try repo.list(limit: 50).count, 0,
            "a failure between statements must roll back the ENTIRE transaction -- the first insert must NOT survive (no partial commit)")
    }

    func test_successfulTransactionCommitsAllStatements() throws {
        let db = try makeDB()
        let repo = NotificationRepository(db: db)

        try db.transaction {
            try repo.insert(AppNotification(id: "one", title: "a", category: "atomic"))
            try repo.insert(AppNotification(id: "two", title: "b", category: "atomic"))
        }

        XCTAssertEqual(try repo.list(limit: 50).count, 2,
            "a transaction that completes must commit every statement atomically")
    }

    func test_connectionRecoversAfterRolledBackTransaction() throws {
        // Interruption robustness: a rolled-back transaction must not leave a
        // half-open transaction that wedges the connection. A subsequent normal
        // write must succeed and be visible.
        let db = try makeDB()
        let repo = NotificationRepository(db: db)

        _ = try? db.transaction {
            try repo.insert(AppNotification(id: "doomed", title: "x", category: "atomic"))
            throw InjectedFailure()
        }

        // The connection must be usable again immediately.
        try repo.insert(AppNotification(id: "after", title: "ok", category: "atomic"))
        let all = try repo.list(limit: 50)
        XCTAssertEqual(all.count, 1, "only the post-rollback insert may exist")
        XCTAssertEqual(all.first?.id, "after",
            "the connection must recover after a rolled-back transaction -- no wedged half-open transaction")
    }
}
