import XCTest
@testable import Persistence
import CoreModel

/// Proves the snapshot restore fallback chain:
/// `latest()` walks newest→oldest until a row decodes successfully.
/// This ensures that a corrupt newest snapshot never silently destroys the
/// restore path when 20 prior valid versions are retained.
final class SessionSnapshotFallbackTests: XCTestCase {

    private func makeRepo() throws -> (SessionSnapshotRepository, SQLiteDB) {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return (SessionSnapshotRepository(db: db), db)
    }

    private func minimalSnap() -> SessionSnapshot {
        SessionSnapshot(layout: LayoutState())
    }

    // Corrupt the payload of the row with the highest id (newest).
    private func corruptNewestPayload(db: SQLiteDB) throws {
        try db.execute("""
            UPDATE session_snapshots
            SET payload_json = 'NOT_VALID_JSON'
            WHERE id = (SELECT MAX(id) FROM session_snapshots);
        """)
    }

    // MARK: - Tests

    /// When the newest snapshot has a corrupt payload, `latest()` must skip it
    /// and return the next-older valid snapshot.
    /// Business rule: 20 versions are retained precisely so corrupt head does
    /// not break restore — silently returning nil instead violates that invariant.
    func test_latestDecodable_corruptNewest_returnsOlderValid() throws {
        let (repo, db) = try makeRepo()

        let older = minimalSnap()
        try repo.save(older)

        let newer = minimalSnap()
        try repo.save(newer)

        try corruptNewestPayload(db: db)

        let result = try repo.latest()
        XCTAssertNotNil(result,
            "latest() must fall back to the older valid snapshot when the newest row is corrupt")
    }

    /// When every retained snapshot has a corrupt payload, `latest()` must
    /// return nil — not throw or crash — so callers can handle a clean-slate start.
    func test_latestDecodable_allCorrupt_returnsNil() throws {
        let (repo, db) = try makeRepo()

        try repo.save(minimalSnap())
        try db.execute("UPDATE session_snapshots SET payload_json = 'CORRUPT';")

        let result = try repo.latest()
        XCTAssertNil(result,
            "latest() must return nil only when every retained snapshot fails to decode")
    }

    /// When the newest snapshot is valid, `latest()` must return it without
    /// iterating further — preserving the original contract for the common case.
    func test_latestDecodable_validNewest_returnsNewest_noRegression() throws {
        let (repo, _) = try makeRepo()

        try repo.save(minimalSnap())

        // Save a second snap after a small date offset so createdAt differs.
        let newerDate = Date(timeIntervalSinceNow: 1)
        let newer = SessionSnapshot(createdAt: newerDate, layout: LayoutState())
        try repo.save(newer)

        let result = try XCTUnwrap(repo.latest(),
            "latest() must return the newest valid snapshot (regression guard)")
        XCTAssertEqual(result.createdAt, newerDate,
            "latest() must return the newest snapshot when it decodes successfully, not fall back needlessly")
    }
}
