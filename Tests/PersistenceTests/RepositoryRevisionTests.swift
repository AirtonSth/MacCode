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
}
