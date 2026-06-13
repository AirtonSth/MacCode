import XCTest
@testable import Persistence
import CoreModel

/// Retention caps for high-volume tables.
/// WHY these tests matter:
///   - agent_provider_event_logs is unbounded per thread; without a cap it grows forever.
///   - terminal_output_chunks is unbounded per surface; a long-lived terminal session
///     can exhaust storage and memory. delete-on-close must remove all chunks for a surface.
final class RetentionCapTests: XCTestCase {

    // MARK: - Helpers

    private func makeDB() throws -> SQLiteDB {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return db
    }

    private func makeThread(db: SQLiteDB, title: String = "t") throws -> AgentThread {
        let thread = AgentThread(title: title, provider: .codex, model: "m")
        try AgentThreadRepository(db: db).upsert(thread)
        return thread
    }

    private func makeRun(db: SQLiteDB, threadId: AgentThreadID) throws -> AgentRun {
        let run = AgentRun(threadId: threadId, provider: .codex, model: "m", status: .running)
        try AgentRunRepository(db: db).upsert(run)
        return run
    }

    private func appendEvent(runs: AgentRunRepository, run: AgentRun, index: Int) throws {
        let event = ProviderRuntimeEvent(
            id: "evt-\(index)",
            provider: .codex,
            source: "codex.app-server",
            method: "item/completed",
            providerTurnId: "turn-\(index)",
            providerItemId: "item-\(index)",
            providerRequestId: nil,
            payloadJSON: #"{"i":\#(index)}"#,
            receivedAtMs: Int64(index)
        )
        try runs.appendProviderEventLog(threadId: run.threadId, runId: run.id, event: event)
    }

    // MARK: - agent_provider_event_logs

    func test_pruneProviderEventLogs_removesOldestDownToCap() throws {
        // WHY: inserting 20 events then capping at 10 must remove rows 0-9,
        // keeping only the newest 10. Validates the per-thread growth bound.
        let db = try makeDB()
        let runs = AgentRunRepository(db: db)
        let thread = try makeThread(db: db)
        let run = try makeRun(db: db, threadId: thread.id)

        for i in 0..<20 {
            try appendEvent(runs: runs, run: run, index: i)
        }

        XCTAssertEqual(try runs.countProviderEventLogs(threadId: thread.id), 20,
                       "pre-condition: 20 rows present before prune")

        try runs.pruneProviderEventLogs(threadId: thread.id, keepLatest: 10)

        XCTAssertEqual(try runs.countProviderEventLogs(threadId: thread.id), 10,
                       "prune must reduce count to the cap so the table cannot grow unboundedly per thread")

        let latest = try runs.listLatestProviderEventLogs(threadId: thread.id, limit: 20)
        XCTAssertEqual(latest.map(\.id), (10..<20).map { "evt-\($0)" },
                       "retained rows must be the newest N events, not a random subset")
    }

    func test_pruneProviderEventLogs_belowCapIsNoop() throws {
        // WHY: calling prune when count < cap must not delete anything — prune must
        // never silently discard events that are still within budget.
        let db = try makeDB()
        let runs = AgentRunRepository(db: db)
        let thread = try makeThread(db: db)
        let run = try makeRun(db: db, threadId: thread.id)

        for i in 0..<5 {
            try appendEvent(runs: runs, run: run, index: i)
        }

        try runs.pruneProviderEventLogs(threadId: thread.id, keepLatest: 100)

        XCTAssertEqual(try runs.countProviderEventLogs(threadId: thread.id), 5,
                       "prune with cap > count must be a no-op and must not remove any event")
    }

    func test_pruneProviderEventLogs_isolatesAcrossThreads() throws {
        // WHY: prune for threadA must not touch threadB's rows. Two threads share
        // the same table; a bug in the WHERE clause would silently lose another
        // thread's diagnostic evidence.
        let db = try makeDB()
        let runs = AgentRunRepository(db: db)
        let threadA = try makeThread(db: db, title: "A")
        let threadB = try makeThread(db: db, title: "B")
        let runA = try makeRun(db: db, threadId: threadA.id)
        let runB = try makeRun(db: db, threadId: threadB.id)

        for i in 0..<15 { try appendEvent(runs: runs, run: runA, index: i) }
        for i in 0..<15 { try appendEvent(runs: runs, run: runB, index: i) }

        try runs.pruneProviderEventLogs(threadId: threadA.id, keepLatest: 5)

        XCTAssertEqual(try runs.countProviderEventLogs(threadId: threadA.id), 5,
                       "threadA must be pruned to cap")
        XCTAssertEqual(try runs.countProviderEventLogs(threadId: threadB.id), 15,
                       "threadB must be untouched by a prune scoped to threadA")
    }

    // MARK: - terminal_output_chunks byte cap

    func test_pruneByteCap_removesOldestChunksUntilWithinBudget() throws {
        // WHY: a terminal surface that appends many chunks must stay within a byte
        // budget after pruning; the oldest chunks (smallest id) are sacrificed first
        // so the most-recent output is always what's visible to the user.
        let db = try makeDB()
        let repo = TerminalOutputRepository(db: db)
        let surfaceID = "surface-cap-test"

        // 5 chunks × 10 bytes each = 50 bytes total
        for i in 0..<5 {
            try repo.append(surfaceID: surfaceID, workspaceID: nil, chunkIndex: Int64(i), data: Data("0123456789".utf8))
        }

        XCTAssertEqual(try repo.totalBytes(surfaceID: surfaceID), 50,
                       "pre-condition: 50 bytes present before prune")

        // Cap at 30 bytes: must delete oldest 2 chunks (20 bytes), keeping newest 3 (30 bytes).
        try repo.pruneByteCap(surfaceID: surfaceID, maxBytes: 30)

        XCTAssertLessThanOrEqual(try repo.totalBytes(surfaceID: surfaceID), 30,
                                 "byte cap prune must bring stored bytes within the budget")

        let window = try repo.readWindow(surfaceID: surfaceID, maxBytes: 256 * 1024)
        XCTAssertEqual(window.chunks.count, 3,
                       "three newest chunks must remain after pruning to 30-byte cap")
    }

    func test_pruneByteCap_belowBudgetIsNoop() throws {
        // WHY: pruning a surface already within the byte budget must not remove
        // anything — an over-eager prune would silently truncate valid scrollback.
        let db = try makeDB()
        let repo = TerminalOutputRepository(db: db)
        let surfaceID = "surface-noop"

        for i in 0..<3 {
            try repo.append(surfaceID: surfaceID, workspaceID: nil, chunkIndex: Int64(i), data: Data("ab".utf8))
        }

        let before = try repo.totalBytes(surfaceID: surfaceID)
        try repo.pruneByteCap(surfaceID: surfaceID, maxBytes: 1024)
        XCTAssertEqual(try repo.totalBytes(surfaceID: surfaceID), before,
                       "pruneByteCap must be a no-op when total bytes are already within budget")
    }

    func test_pruneByteCap_isolatesAcrossSurfaces() throws {
        // WHY: pruning surfaceA must not delete chunks from surfaceB. Two terminal
        // surfaces share the same table; a scoping bug would silently erase another
        // surface's scrollback.
        let db = try makeDB()
        let repo = TerminalOutputRepository(db: db)
        let surfA = "surf-A"
        let surfB = "surf-B"

        for i in 0..<4 {
            try repo.append(surfaceID: surfA, workspaceID: nil, chunkIndex: Int64(i), data: Data("AAAA".utf8))
            try repo.append(surfaceID: surfB, workspaceID: nil, chunkIndex: Int64(i), data: Data("BBBB".utf8))
        }

        try repo.pruneByteCap(surfaceID: surfA, maxBytes: 8) // keep 2 × 4 bytes from A

        XCTAssertLessThanOrEqual(try repo.totalBytes(surfaceID: surfA), 8,
                                 "surfA must be within byte cap")
        XCTAssertEqual(try repo.totalBytes(surfaceID: surfB), 16,
                       "surfB must be untouched by a prune scoped to surfA")
    }

    // MARK: - terminal_output_chunks delete-on-close

    func test_deleteOnClose_removesAllChunksForSurface() throws {
        // WHY: when a terminal surface closes, all its chunks must be removed so
        // closed surfaces do not accumulate orphaned bytes indefinitely.
        let db = try makeDB()
        let repo = TerminalOutputRepository(db: db)
        let surfaceID = "surface-close"
        let otherID   = "surface-other"

        for i in 0..<5 {
            try repo.append(surfaceID: surfaceID, workspaceID: nil, chunkIndex: Int64(i), data: Data("x".utf8))
        }
        try repo.append(surfaceID: otherID, workspaceID: nil, chunkIndex: 0, data: Data("y".utf8))

        try repo.delete(surfaceID: surfaceID)

        let window = try repo.readWindow(surfaceID: surfaceID, maxBytes: 256 * 1024)
        XCTAssertTrue(window.chunks.isEmpty,
                      "delete-on-close must remove all chunks for the closed surface so storage is reclaimed")

        // Other surface must be unaffected.
        let otherWindow = try repo.readWindow(surfaceID: otherID, maxBytes: 256 * 1024)
        XCTAssertEqual(otherWindow.chunks.count, 1,
                       "delete-on-close must not affect chunks belonging to other surfaces")
    }

    // MARK: - QA-mac:75 scripted heavy session -> whole-DB footprint stays bounded

    func test_heavySession_allRetentionCapsTogetherBoundTheDatabase() throws {
        // WHY: the per-cap tests prove each table is bounded in isolation. This is the
        // scripted-heavy-session integration QA-mac:75 asks for: drive ONE thread/surface
        // far past every cap, apply all three prunes, and assert every growth table lands
        // at/under its cap simultaneously -- i.e. a long-lived session cannot grow the DB
        // without bound. This composition is what "would have caught" the unbounded
        // agent_provider_event_logs / agent_stream_events / terminal_output_chunks growth.
        let db = try makeDB()
        let runs = AgentRunRepository(db: db)
        let thread = try makeThread(db: db)
        let run = try makeRun(db: db, threadId: thread.id)

        // Caps chosen small but exceeded by a wide margin (heavy load relative to cap),
        // so the assertion proves the bound regardless of how long the session runs.
        let providerCap = 100, streamCap = 100, terminalByteCap = 1_000
        let heavy = 250

        for i in 0..<heavy { try appendEvent(runs: runs, run: run, index: i) }          // provider event logs
        for i in 0..<heavy {                                                            // stream events
            try runs.appendStreamEvent(runId: run.id, seq: i, kind: "k", payloadJSON: #"{"i":\#(i)}"#)
        }
        let surfaceID = "surface-heavy"
        let chunkRepo = TerminalOutputRepository(db: db)
        for i in 0..<heavy {                                                            // terminal chunks: 250 x 10B = 2500B
            try chunkRepo.append(surfaceID: surfaceID, workspaceID: nil, chunkIndex: Int64(i), data: Data("0123456789".utf8))
        }

        // Pre-condition: everything is over budget before pruning.
        XCTAssertGreaterThan(try runs.countProviderEventLogs(threadId: thread.id), providerCap)
        XCTAssertGreaterThan(try runs.countStreamEvents(threadId: thread.id), streamCap)
        XCTAssertGreaterThan(try chunkRepo.totalBytes(surfaceID: surfaceID), terminalByteCap)

        // Apply every retention cap, as the coordinator does on the write path.
        try runs.pruneProviderEventLogs(threadId: thread.id, keepLatest: providerCap)
        try runs.pruneStreamEvents(threadId: thread.id, keepLatest: streamCap)
        try chunkRepo.pruneByteCap(surfaceID: surfaceID, maxBytes: terminalByteCap)

        // Post-condition: every growth table is bounded simultaneously.
        XCTAssertEqual(try runs.countProviderEventLogs(threadId: thread.id), providerCap,
                       "provider event logs must be capped at keepLatest after a heavy session")
        XCTAssertEqual(try runs.countStreamEvents(threadId: thread.id), streamCap,
                       "stream events must be capped at keepLatest after a heavy session")
        XCTAssertLessThanOrEqual(try chunkRepo.totalBytes(surfaceID: surfaceID), terminalByteCap,
                       "terminal output bytes must stay within the byte cap after a heavy session")
    }
}
