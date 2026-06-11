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
    /// not break restore - silently returning nil instead violates that invariant.
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
    /// return nil - not throw or crash - so callers can handle a clean-slate start.
    func test_latestDecodable_allCorrupt_returnsNil() throws {
        let (repo, db) = try makeRepo()

        try repo.save(minimalSnap())
        try db.execute("UPDATE session_snapshots SET payload_json = 'CORRUPT';")

        let result = try repo.latest()
        XCTAssertNil(result,
            "latest() must return nil only when every retained snapshot fails to decode")
    }

    /// When the newest snapshot is valid, `latest()` must return it without
    /// iterating further - preserving the original contract for the common case.
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

    // MARK: - Future-version row

    /// WHY (T013 fixture): SessionSnapshot.currentVersion is 1.  A future version
    /// (e.g. written by a newer build after an upgrade) contains a higher version
    /// integer but otherwise valid JSON.  The current Codable decoder does NOT
    /// validate the version field, so latest() returns the row without rejecting
    /// it.  This test pins that behavior so a future version-gating migration step
    /// (when added) will be detectable: the test must change from NotNil to Nil or
    /// to a fallback to the prior valid row.
    func test_latestDecodable_futureVersion_decodesSuccessfully() throws {
        let (repo, db) = try makeRepo()

        // Encode a valid snapshot, then patch the version field in the JSON bytes
        // so the DB row carries version=999 while all other fields are structurally valid.
        let base = SessionSnapshot(layout: LayoutState())
        let baseData = try JSONEncoder().encode(base)
        guard var dict = try JSONSerialization.jsonObject(with: baseData) as? [String: Any] else {
            XCTFail("expected JSON object from encoder"); return
        }
        dict["version"] = 999
        let patched = try JSONSerialization.data(withJSONObject: dict)
        let patchedString = String(data: patched, encoding: .utf8) ?? "{}"

        let st = try db.prepare("""
            INSERT INTO session_snapshots(version, payload_json, created_at)
            VALUES(?, ?, ?);
        """)
        try st.bind(1, Int64(999))
        try st.bind(2, patchedString)
        try st.bind(3, "2030-01-01T00:00:00Z")
        _ = try st.step()

        // Current behavior: no version gate, so the row decodes and is returned.
        // If version validation is added later, update this assertion to reflect the
        // new behavior (e.g. fallback-to-prior-valid-row or XCTAssertNil).
        let result = try repo.latest()
        XCTAssertNotNil(result,
            "current behavior: latest() has no version gate - a future-version row decodes and is returned. " +
            "If version validation is added, update this test and verify the fallback behavior.")
        XCTAssertEqual(result?.version, 999,
            "the decoded snapshot must carry the stored version integer so callers can detect and migrate it")
    }

    // MARK: - Dangling selectedSurfaceID

    /// WHY (T013 fixture): a PaneNode can be stored with a selectedSurfaceID that
    /// does not appear in its surfaces array (e.g. written by a concurrent write path
    /// that deleted the surface but did not clear the selection pointer).  Codable
    /// decodes this without error because selectedSurfaceID is Optional.  This test
    /// documents that latest() returns the snapshot even when selectedSurfaceID is
    /// dangling, so callers that resolve the selection must guard against a missing
    /// surface rather than assuming the stored ID is always valid.
    func test_latestDecodable_danglingSelectedSurfaceID_decodesSuccessfully() throws {
        let (repo, _) = try makeRepo()

        // Build a pane where selectedSurfaceID is explicitly set to a UUID that is
        // NOT in the surfaces array.  PaneNode.init takes selectedSurfaceID as an
        // explicit parameter - passing danglingID directly achieves this without
        // JSON patching.
        let danglingID = SurfaceID()
        let surfaceDesc = SurfaceDescriptor(id: SurfaceID(), type: .terminal, title: "t")
        // Pass danglingID explicitly so pane.selectedSurfaceID != surfaceDesc.id.
        let pane = PaneNode(surfaces: [surfaceDesc], selectedSurfaceID: danglingID)
        let ws = Workspace(name: "W", cwd: "/tmp", layout: .pane(pane))
        let layout = LayoutState(workspaces: [ws.id: ws])
        let snap = SessionSnapshot(layout: layout)

        // Use repo.save() so the encoder/decoder path is the same as production.
        try repo.save(snap)

        let result = try repo.latest()
        XCTAssertNotNil(result,
            "latest() must decode and return a snapshot even when a pane's selectedSurfaceID is dangling " +
            "- callers must guard against a missing surface rather than assuming the stored ID is valid")

        // The decoded pane must carry the dangling selectedSurfaceID intact so
        // callers can detect and clear it; if it were silently nil the caller
        // could not distinguish 'no selection ever set' from 'selection points at a deleted surface'.
        guard let decoded = result,
              case .pane(let decodedPane) = decoded.layout.workspaces.values.first?.layout else {
            XCTFail("expected a pane layout in the decoded snapshot"); return
        }
        XCTAssertEqual(decodedPane.selectedSurfaceID?.value, danglingID.value,
            "a dangling selectedSurfaceID must survive the round-trip with its value intact " +
            "so callers can detect and clear it")
        let surfaceIDs = decodedPane.surfaces.map(\.id.value)
        XCTAssertFalse(surfaceIDs.contains(danglingID.value),
            "the dangling selectedSurfaceID must not match any surface in the pane; " +
            "if it does the test fixture is wrong")
    }
}
