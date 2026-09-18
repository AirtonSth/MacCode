import XCTest
import CoreModel
@testable import Persistence

final class RepositoryRevisionTests: XCTestCase {
    func test_laneStateAndThreadIdentityWritesBumpTheirRevisions() throws {
        // WHY (EV-23): AppContext memoizes Token Saver admission per run to stop
        // 12-25 SQLite reads per token-usage event. The memo key carries these
        // revisions so a lane promotion or a thread re-scoped to a project is
        // admitted on the very next event, not when the run ends.
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let lanes = TokenSaverLaneStateRepository(db: db)
        let before = TokenSaverLaneStateRepository.revision
        try lanes.upsert(.init(
            projectID: UUID().uuidString,
            lane: "measurement",
            state: "shadow_only",
            reason: "test",
            evidenceLevel: "provider_usage",
            ownerRole: "test",
            permissionBoundary: "project",
            retentionDays: 0,
            optedOut: false,
            killSwitchActive: false
        ))
        XCTAssertGreaterThan(TokenSaverLaneStateRepository.revision, before)

        let threads = AgentThreadRepository(db: db)
        let thread = AgentThread(title: "t", provider: .codex, model: "m")
        let identityBefore = AgentThreadRepository.identityRevision
        try threads.upsert(thread)
        XCTAssertGreaterThan(AgentThreadRepository.identityRevision, identityBefore)
        let afterUpsert = AgentThreadRepository.identityRevision
        try threads.delete(id: thread.id)
        XCTAssertGreaterThan(AgentThreadRepository.identityRevision, afterUpsert)
    }

    func test_ensureDefaults_isReadOnlyOnceTheProjectAlreadyHasItsLanes() throws {
        // WHY: `SidebarView.reloadTokenSaverGovernance()` calls this once per
        // scoped project every time the Token Saver popover opens, on the main
        // actor. The seed/repair writes are idempotent, so a project already in
        // the target state must not open another write transaction (12 INSERT OR
        // IGNORE + 2 UPDATE + WAL append) per open.
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let lanes = TokenSaverLaneStateRepository(db: db)

        try lanes.ensureDefaults(projectID: "p1")
        XCTAssertEqual(try lanes.list(projectID: "p1").count, 12, "precondition: the first call seeds the factory lanes")

        let before = TokenSaverLaneStateRepository.revision
        try lanes.ensureDefaults(projectID: "p1")
        XCTAssertEqual(
            TokenSaverLaneStateRepository.revision, before,
            "an already-seeded project must not bump the write revision: the popover reload is called on every open and must stay read-only"
        )

        try db.execute("DELETE FROM token_saver_lane_state WHERE project_id = 'p1' AND lane = 'measurement';")
        let afterDelete = TokenSaverLaneStateRepository.revision
        try lanes.ensureDefaults(projectID: "p1")
        XCTAssertGreaterThan(
            TokenSaverLaneStateRepository.revision, afterDelete,
            "a project missing one of its factory lanes must still be repaired"
        )
        XCTAssertEqual(try lanes.list(projectID: "p1").count, 12)
    }
}
