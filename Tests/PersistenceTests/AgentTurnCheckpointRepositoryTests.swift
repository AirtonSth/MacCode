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

    // MARK: - listMetadataPage (response_version 1 projection)

    private func makeHeavyCheckpoint(
        threadId: AgentThreadID,
        turnCount: Int,
        turnId: String,
        runId: AgentRunID,
        completedAt: Date
    ) -> AgentTurnCheckpointSummary {
        AgentTurnCheckpointSummary(
            threadId: threadId,
            runId: runId,
            turnId: turnId,
            checkpointTurnCount: turnCount,
            checkpointRef: "ref-\(turnId)",
            status: .ready,
            files: [AgentTurnCheckpointFile(path: "a.swift", kind: "modified", additions: 1, deletions: 0)],
            fileSnapshots: [
                AgentTurnCheckpointFileSnapshot(
                    path: "a.swift",
                    kind: "modified",
                    contentsBase64: Data("HEAVY-SNAPSHOT-\(turnId)".utf8).base64EncodedString()
                )
            ],
            diffPatch: "diff --git a/a.swift b/a.swift\n+HEAVY-\(turnId)\n",
            fileDiffs: [AgentTurnCheckpointFileDiff(path: "a.swift", patch: "@@\n+HEAVY-\(turnId)\n")],
            assistantMessageId: nil,
            errorMessage: nil,
            completedAt: completedAt
        )
    }

    func testListMetadataPage_sqlProjectsLightColumnsWithLimit_andIgnoresCorruptHeavyBlobs() throws {
        // WHY: mobile/3G clients must not pay to read or decode file_snapshots_json,
        // diff_patch, or file_diffs_json. The observed SQL must prove explicit projection
        // + LIMIT, and corrupt heavy blobs must not poison the metadata result.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 1...3 {
            try repo.upsert(makeHeavyCheckpoint(
                threadId: tid,
                turnCount: i,
                turnId: "turn-\(i)",
                runId: rid,
                completedAt: base.addingTimeInterval(TimeInterval(i))
            ))
        }

        // Corrupt the heavy columns after a normal upsert so list() would struggle
        // if those columns were selected; metadata page must still succeed.
        let corrupt = try db.prepare("""
            UPDATE agent_turn_checkpoints
            SET files_json = 'NOT-JSON{{{',
                file_snapshots_json = 'NOT-JSON{{{',
                diff_patch = 'x',
                file_diffs_json = '{bad'
            WHERE thread_id = ?;
        """)
        try corrupt.bind(1, tid.value.uuidString)
        _ = try corrupt.step()

        var observedSQL: [String] = []
        db.beforeStatementStepForTesting = { sql in
            if sql.contains("FROM agent_turn_checkpoints") {
                observedSQL.append(sql)
            }
        }
        defer { db.beforeStatementStepForTesting = nil }

        let page = try repo.listMetadataPage(threadId: tid, maxEntries: 2, before: nil)

        XCTAssertEqual(page.items.count, 2, "LIMIT max_entries must cap emitted items")
        XCTAssertTrue(page.truncated, "LIMIT max_entries+1 must detect another page")
        XCTAssertNotNil(page.nextBefore, "cursor of final emitted item only when another page exists")
        XCTAssertEqual(page.items.map(\.turnId), ["turn-3", "turn-2"],
                       "DESC keyset must emit newest checkpoint_turn_count first")
        for item in page.items {
            XCTAssertEqual(item.fileSnapshots, [], "metadata page must never surface snapshots")
            XCTAssertNil(item.diffPatch, "metadata page must never surface diff_patch")
            XCTAssertEqual(item.fileDiffs, [], "metadata page must never surface file diffs")
            XCTAssertEqual(item.files.count, 1, "bounded file summary metadata remains available")
        }
        XCTAssertEqual(page.filesTruncated, [false, false])

        let metadataSQL = observedSQL.first { $0.contains("LIMIT") && $0.contains("ORDER BY") }
        XCTAssertNotNil(metadataSQL, "metadata page must issue an ordered LIMIT query")
        let sql = metadataSQL ?? ""
        XCTAssertTrue(
            sql.contains("files_summary_json"),
            "production v1 projection must read only the capture-time bounded file summary"
        )
        XCTAssertFalse(
            sql.replacingOccurrences(of: "files_summary_json", with: "").contains("files_json"),
            "production v1 path must not select the authoritative full files_json"
        )
        XCTAssertFalse(sql.contains("file_snapshots_json"),
                       "production v1 path must not select file_snapshots_json")
        XCTAssertFalse(sql.contains("diff_patch"),
                       "production v1 path must not select diff_patch")
        XCTAssertFalse(sql.contains("file_diffs_json"),
                       "production v1 path must not select file_diffs_json")
        XCTAssertTrue(sql.contains("LIMIT ?") || sql.contains("LIMIT"),
                      "must use LIMIT max_entries+1 paging")
        XCTAssertTrue(
            sql.contains("checkpoint_turn_count DESC")
                && sql.contains("completed_at DESC")
                && sql.contains("turn_id DESC"),
            "ORDER BY must be DESC on the full keyset"
        )
    }

    func testUpsert_keepsAuthoritativeFilesAndPersistsBoundedMobileSummary() throws {
        // WHY: bounding only during serialization still forces every list refresh
        // to read and decode the complete files_json. Capture the mobile summary
        // once while leaving authoritative checkpoint metadata untouched.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        let segment = String(repeating: "quote-\"-slash-\\-emoji-🙂-", count: 10)
        let files = (0..<200).map {
            AgentTurnCheckpointFile(
                path: "Sources/\(segment)\($0).swift",
                kind: "modified",
                additions: $0,
                deletions: $0 / 2
            )
        }
        let checkpoint = AgentTurnCheckpointSummary(
            threadId: tid,
            runId: rid,
            turnId: "bounded-summary",
            checkpointTurnCount: 1,
            checkpointRef: "ref",
            status: .ready,
            files: files,
            completedAt: Date(timeIntervalSince1970: 1_700_000_050)
        )
        try repo.upsert(checkpoint)

        let lengths = try db.prepare("""
            SELECT length(files_json), length(files_summary_json), files_summary_truncated
            FROM agent_turn_checkpoints
            WHERE thread_id = ? AND turn_id = ?;
            """)
        try lengths.bind(1, tid.value.uuidString)
        try lengths.bind(2, checkpoint.turnId)
        XCTAssertTrue(try lengths.step())
        XCTAssertGreaterThan(Int(lengths.columnInt64(0)), 6 * 1_024)
        XCTAssertLessThanOrEqual(Int(lengths.columnInt64(1)), 6 * 1_024)
        XCTAssertEqual(lengths.columnInt64(2), 1)

        let page = try repo.listMetadataPage(
            threadId: tid,
            maxEntries: 1,
            before: nil
        )
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.filesTruncated, [true])
        XCTAssertGreaterThan(page.items[0].files.count, 0)
        XCTAssertLessThan(page.items[0].files.count, 64)
        XCTAssertEqual(
            try repo.list(threadId: tid).first?.files.count,
            200,
            "legacy/detail reads must retain the authoritative complete file list"
        )
    }

    func testListMetadataPage_tieBreaksOnTurnId_withoutDuplicatesAcrossPages() throws {
        // WHY: when checkpoint_turn_count and completed_at tie, turn_id is the only
        // deterministic final tie-breaker. Page boundaries must not skip or duplicate rows.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        let sameCompleted = Date(timeIntervalSince1970: 1_700_000_100)
        // Same turn count + completed_at; lexicographic turn_id order: a < b < c < d
        for turnId in ["tie-a", "tie-b", "tie-c", "tie-d"] {
            try repo.upsert(makeHeavyCheckpoint(
                threadId: tid,
                turnCount: 7,
                turnId: turnId,
                runId: rid,
                completedAt: sameCompleted
            ))
        }

        let first = try repo.listMetadataPage(threadId: tid, maxEntries: 2, before: nil)
        XCTAssertEqual(first.items.map(\.turnId), ["tie-d", "tie-c"],
                       "DESC turn_id tie-break must prefer larger turn_id first")
        XCTAssertTrue(first.truncated)
        guard let cursor = first.nextBefore else {
            return XCTFail("first page must expose next_before when truncated")
        }
        XCTAssertEqual(cursor.turnId, "tie-c")
        XCTAssertEqual(cursor.checkpointTurnCount, 7)

        let second = try repo.listMetadataPage(threadId: tid, maxEntries: 2, before: cursor)
        XCTAssertEqual(second.items.map(\.turnId), ["tie-b", "tie-a"],
                       "second page must continue after the cursor without duplicates")
        XCTAssertFalse(second.truncated)
        XCTAssertNil(second.nextBefore, "final page must not emit next_before")

        let allIds = first.items.map(\.turnId) + second.items.map(\.turnId)
        XCTAssertEqual(allIds, ["tie-d", "tie-c", "tie-b", "tie-a"])
        XCTAssertEqual(Set(allIds).count, 4, "pages must be duplicate-free across the keyset")
    }

    func testListMetadataPage_resolvesOversizedWireCursorInsideExactTieAcrossMutation() throws {
        // WHY: an oversized provider turn id must not brick history or be echoed
        // unbounded. The wire digest still has to resume the original SQL keyset
        // after a between-page insert without a duplicate or global cursor scan.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        let sameCompleted = Date(timeIntervalSince1970: 1_700_000_200)
        let prefix = String(repeating: "oversized-\"-\\-🙂-", count: 40)
        func raw(_ suffix: String) -> String { prefix + suffix }
        for suffix in ["a", "b", "c", "d"] {
            try repo.upsert(makeHeavyCheckpoint(
                threadId: tid,
                turnCount: 9,
                turnId: raw(suffix),
                runId: rid,
                completedAt: sameCompleted
            ))
        }

        let first = try repo.listMetadataPage(
            threadId: tid,
            maxEntries: 2,
            before: nil
        )
        XCTAssertEqual(first.items.map(\.turnId), [raw("d"), raw("c")])
        guard let rawCursor = first.nextBefore else {
            return XCTFail("oversized first page must expose a cursor")
        }
        let wireTurnID = AgentTurnCheckpointWireIdentity.projectedTurnID(
            rawCursor.turnId
        )
        XCTAssertTrue(AgentTurnCheckpointWireIdentity.isDigestIdentity(wireTurnID))
        XCTAssertNotEqual(wireTurnID, rawCursor.turnId)

        // A new row before the already-emitted boundary must not leak into the
        // continuation or cause an existing row to repeat.
        try repo.upsert(makeHeavyCheckpoint(
            threadId: tid,
            turnCount: 9,
            turnId: raw("z"),
            runId: rid,
            completedAt: sameCompleted
        ))
        var observedSQL: [String] = []
        db.beforeStatementStepForTesting = { sql in
            if sql.contains("FROM agent_turn_checkpoints") {
                observedSQL.append(sql)
            }
        }
        defer { db.beforeStatementStepForTesting = nil }

        let second = try repo.listMetadataPage(
            threadId: tid,
            maxEntries: 2,
            before: AgentTurnCheckpointCursor(
                checkpointTurnCount: rawCursor.checkpointTurnCount,
                completedAt: rawCursor.completedAt,
                turnId: wireTurnID
            )
        )
        XCTAssertEqual(second.items.map(\.turnId), [raw("b"), raw("a")])
        XCTAssertFalse(second.truncated)
        let combined = first.items.map(\.turnId) + second.items.map(\.turnId)
        XCTAssertEqual(Set(combined).count, 4)
        XCTAssertFalse(combined.contains(raw("z")))
        XCTAssertTrue(
            observedSQL.contains {
                $0.contains("checkpoint_turn_count = ?")
                    && $0.contains("completed_at = ?")
                    && $0.contains("SELECT turn_id")
            },
            "digest resolution must scan only the exact count/timestamp tie"
        )
    }

    func testListMetadataPage_ambiguousDigestIdentityFailsInsteadOfChoosingARow() throws {
        // WHY: even a deliberately constructed digest alias must fail loud; choosing
        // either matching storage row would make pagination authorization ambiguous.
        let db = try makeDB()
        let repo = AgentTurnCheckpointRepository(db: db)
        let (tid, rid) = try seedThreadAndRun(db: db)
        let completed = Date(timeIntervalSince1970: 1_700_000_300)
        let oversized = String(repeating: "collision-source-🙂", count: 40)
        let digestIdentity = AgentTurnCheckpointWireIdentity.projectedTurnID(oversized)
        XCTAssertTrue(AgentTurnCheckpointWireIdentity.isDigestIdentity(digestIdentity))
        for turnID in [oversized, digestIdentity] {
            try repo.upsert(makeHeavyCheckpoint(
                threadId: tid,
                turnCount: 11,
                turnId: turnID,
                runId: rid,
                completedAt: completed
            ))
        }

        XCTAssertThrowsError(try repo.listMetadataPage(
            threadId: tid,
            maxEntries: 1,
            before: AgentTurnCheckpointCursor(
                checkpointTurnCount: 11,
                completedAt: completed,
                turnId: digestIdentity
            )
        )) { error in
            guard case PersistenceDataError.corruptCheckpoint(let message) = error else {
                return XCTFail("expected explicit corrupt cursor identity, got \(error)")
            }
            XCTAssertTrue(message.contains("missing or ambiguous"))
        }
    }

    func testWireIdentityEncodedByteCountMatchesJSONEncoderForEscapedAndUnicodeStrings() throws {
        // WHY: every metadata cap and disclosed total is expressed in actual wire
        // bytes. A hand-counting drift for escaping or multi-byte scalars could let
        // one adversarial checkpoint exceed the mobile response budget.
        let values = [
            "",
            "plain",
            "\"/\\\u{8}\t\n\u{c}\r\u{1}",
            "accent-é emoji-🙂 separator-\u{2028}"
        ]

        for value in values {
            XCTAssertEqual(
                AgentTurnCheckpointWireIdentity.encodedJSONStringByteCount(value),
                try JSONEncoder().encode(value).count,
                "wire byte count drifted for \(String(reflecting: value))"
            )
        }
    }
}
