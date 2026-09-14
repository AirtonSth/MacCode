import XCTest
import CoreModel
@testable import Persistence

final class ProviderEventIdCacheBoundTests: XCTestCase {
    func test_knownProviderEventIdsStayBoundedPerThread() throws {
        // WHY (EV-24): retention keeps ~100 provider rows per thread but the
        // in-memory id set kept every id ever inserted for the run (and a live
        // copy forced a full Set copy per insert). The cache must stay bounded.
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let threads = AgentThreadRepository(db: db)
        let runs = AgentRunRepository(db: db)
        let thread = AgentThread(title: "t", provider: .codex, model: "m")
        try threads.upsert(thread)
        let limit = AgentRunRepository.knownProviderEventIdsPerThreadLimit
        for i in 0..<(limit + 50) {
            try runs.appendProviderEventLog(
                threadId: thread.id,
                runId: nil,
                event: ProviderRuntimeEvent(
                    id: "evt-\(i)",
                    provider: .codex,
                    source: "test",
                    method: "item/started",
                    payloadJSON: "{}",
                    receivedAtMs: Int64(i)
                )
            )
        }
        let cached = runs.knownProviderEventIdCountForTesting(threadId: thread.id) ?? 0
        XCTAssertLessThanOrEqual(cached, limit, "the id cache must be dropped/re-seeded instead of growing with the run")
        // Idempotency still holds after the cache was re-seeded from retained rows.
        let before = try runs.countProviderEventLogs(threadId: thread.id)
        try runs.appendProviderEventLog(
            threadId: thread.id,
            runId: nil,
            event: ProviderRuntimeEvent(id: "evt-\(limit + 49)", provider: .codex, source: "test", method: "item/started", payloadJSON: "{}", receivedAtMs: Int64(limit + 49))
        )
        XCTAssertEqual(try runs.countProviderEventLogs(threadId: thread.id), before, "a replayed id must not insert twice")
    }
}
