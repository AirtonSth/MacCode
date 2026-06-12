import XCTest
@testable import Persistence
import CoreModel

/// Tests for AgentTurnCheckpointRepository.decodableCheckpoints (pure seam) and
/// listTolerant/list corruption tolerance.
///
/// WHY these tests matter:
///   - One corrupt checkpoint row in a thread must NOT hide the user's other good
///     checkpoints. Before this fix, list() threw on the first corrupt row, making
///     ALL checkpoints in that thread unreachable. The seam enforces the invariant:
///     healthy rows survive; corruptCount is always reported (never silently zero'd).
final class AgentTurnCheckpointRepositoryTests: XCTestCase {

    // MARK: - Helpers

    private func makeDB() throws -> SQLiteDB {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return db
    }

    private func makeThreadId() -> AgentThreadID {
        AgentThreadID(UUID())
    }

    /// Seeds the parent thread + run a checkpoint FK-references, returning the run id
    /// so the caller can attach checkpoints to it (DB round-trip tests only).
    private func seedThreadAndRun(db: SQLiteDB) throws -> (threadId: AgentThreadID, runId: AgentRunID) {
        let thread = AgentThread(title: "t", provider: .codex, model: "m")
        try AgentThreadRepository(db: db).upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m", status: .running)
        try AgentRunRepository(db: db).upsert(run)
        return (thread.id, run.id)
    }

    private func makeCheckpoint(
        threadId: AgentThreadID,
        turnCount: Int,
        turnId: String? = nil,
        runId: AgentRunID? = nil
    ) -> AgentTurnCheckpointSummary {
        AgentTurnCheckpointSummary(
            threadId: threadId,
            runId: runId ?? AgentRunID(UUID()),
            turnId: turnId ?? "turn-\(turnCount)",
            checkpointTurnCount: turnCount,
            checkpointRef: "ref-\(turnCount)",
            status: .ready,
            files: [],
            fileSnapshots: [],
            diffPatch: nil,
            fileDiffs: [],
            assistantMessageId: nil,
            errorMessage: nil,
            completedAt: Date(timeIntervalSince1970: Double(turnCount))
        )
    }

    // MARK: - Pure seam: decodableCheckpoints

    func testSeam_mixedValidCorrupt_returnsHealthyPlusCount() {
        // WHY: [valid, corrupt, valid] must yield 2 healthy and corruptCount=1.
        // This is the core invariant -- one bad row must not hide the surrounding good ones.
        let tid = makeThreadId()
        let cp1 = makeCheckpoint(threadId: tid, turnCount: 1)
        let cp2 = makeCheckpoint(threadId: tid, turnCount: 2)
        let fakeError = PersistenceDataError.corruptCheckpoint("bad json")

        let attempts: [Result<AgentTurnCheckpointSummary, Error>] = [
            .success(cp1),
            .failure(fakeError),
            .success(cp2)
        ]
        let result = AgentTurnCheckpointRepository.decodableCheckpoints(attempts)

        XCTAssertEqual(result.healthy.count, 2)
        XCTAssertEqual(result.corruptCount, 1)
        XCTAssertEqual(result.healthy[0].checkpointTurnCount, 1)
        XCTAssertEqual(result.healthy[1].checkpointTurnCount, 2)
    }

    func testSeam_allCorrupt_returnsEmptyPlusCount() {
        // WHY: a fully corrupt thread must yield empty healthy list and accurate count.
        let attempts: [Result<AgentTurnCheckpointSummary, Error>] = [
            .failure(PersistenceDataError.corruptCheckpoint("a")),
            .failure(PersistenceDataError.corruptCheckpoint("b"))
        ]
        let result = AgentTurnCheckpointRepository.decodableCheckpoints(attempts)

        XCTAssertEqual(result.healthy.count, 0)
        XCTAssertEqual(result.corruptCount, 2)
    }

    func testSeam_allValid_returnsAllPlusZeroCount() {
        // WHY: a fully healthy thread must pass through unchanged with corruptCount=0.
        let tid = makeThreadId()
        let attempts: [Result<AgentTurnCheckpointSummary, Error>] = [
            .success(makeCheckpoint(threadId: tid, turnCount: 1)),
            .success(makeCheckpoint(threadId: tid, turnCount: 2)),
            .success(makeCheckpoint(threadId: tid, turnCount: 3))
        ]
        let result = AgentTurnCheckpointRepository.decodableCheckpoints(attempts)

        XCTAssertEqual(result.healthy.count, 3)
        XCTAssertEqual(result.corruptCount, 0)
    }

    func testSeam_empty_returnsEmptyZeroCount() {
        let result = AgentTurnCheckpointRepository.decodableCheckpoints([])
        XCTAssertEqual(result.healthy.count, 0)
        XCTAssertEqual(result.corruptCount, 0)
    }

    func testSeam_preservesOrderOfHealthyRows() {
        // WHY: healthy rows must remain in original (checkpoint_turn_count ASC) order.
        // Out-of-order checkpoints would show the wrong restore point to the user.
        let tid = makeThreadId()
        let cp1 = makeCheckpoint(threadId: tid, turnCount: 1)
        let cp3 = makeCheckpoint(threadId: tid, turnCount: 3)
        let cp5 = makeCheckpoint(threadId: tid, turnCount: 5)
        let attempts: [Result<AgentTurnCheckpointSummary, Error>] = [
            .success(cp1),
            .failure(PersistenceDataError.corruptCheckpoint("turn 2")),
            .success(cp3),
            .failure(PersistenceDataError.corruptCheckpoint("turn 4")),
            .success(cp5)
        ]
        let result = AgentTurnCheckpointRepository.decodableCheckpoints(attempts)

        XCTAssertEqual(result.healthy.map(\.checkpointTurnCount), [1, 3, 5])
        XCTAssertEqual(result.corruptCount, 2)
    }

    // MARK: - listTolerant integration (DB round-trip)

    func testListTolerant_allValid_returnsAllZeroCount() throws {
        // WHY: listTolerant must not degrade the happy path -- all good rows come back.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        try repo.upsert(makeCheckpoint(threadId: tid, turnCount: 1, runId: rid))
        try repo.upsert(makeCheckpoint(threadId: tid, turnCount: 2, runId: rid))

        let result = try repo.listTolerant(threadId: tid)

        XCTAssertEqual(result.healthy.count, 2)
        XCTAssertEqual(result.corruptCount, 0)
    }

    func testListTolerant_emptyThread_returnsEmptyZeroCount() throws {
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let tid = makeThreadId()

        let result = try repo.listTolerant(threadId: tid)

        XCTAssertEqual(result.healthy.count, 0)
        XCTAssertEqual(result.corruptCount, 0)
    }

    // MARK: - list backward-compat: now returns healthy only, does not throw on corrupt

    func testList_allValid_returnsAll() throws {
        // WHY: existing callers rely on list() returning all good checkpoints unchanged.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        try repo.upsert(makeCheckpoint(threadId: tid, turnCount: 1, runId: rid))
        try repo.upsert(makeCheckpoint(threadId: tid, turnCount: 2, runId: rid))

        let result = try repo.list(threadId: tid)

        XCTAssertEqual(result.count, 2)
    }
}
