import XCTest
@testable import Persistence
import CoreModel

/// Correctness pin for AgentMessageRepository.threadIdsWithMessages() (PERF-007).
///
/// WHY: agent.thread.list now calls threadIdsWithMessages() once and derives
/// provider_locked from the returned set instead of issuing one
/// listAgentMessages(thread:limit:1) query per thread. This test asserts that
/// the batch path returns the same per-thread locked value as the original N
/// per-thread queries, so collapsing N queries to 1 cannot silently change the
/// computed values.
final class ThreadIdsWithMessagesTests: XCTestCase {

    private struct Harness {
        let repo: AgentMessageRepository
        let threads: [AgentThreadID]
    }

    private func makeHarness(threadCount: Int, populatedIndices: Set<Int>) throws -> Harness {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let threadRepo = AgentThreadRepository(db: db)
        var ids: [AgentThreadID] = []
        for i in 0..<threadCount {
            let t = AgentThread(title: "t\(i)", provider: .codex, model: "m")
            try threadRepo.upsert(t)
            ids.append(t.id)
        }
        let msgRepo = AgentMessageRepository(db: db)
        for idx in populatedIndices {
            try msgRepo.append(AgentMessage(
                threadId: ids[idx],
                role: .user,
                content: "hello",
                createdAt: Date(timeIntervalSinceReferenceDate: Double(idx) * 1000)
            ))
        }
        return Harness(repo: msgRepo, threads: ids)
    }

    // batch result must equal per-thread result for a mixed set of threads.
    func test_batchMatchesPerThread_mixedPopulation() throws {
        let h = try makeHarness(threadCount: 5, populatedIndices: [0, 2, 4])

        // per-thread path (original N queries)
        let perThread: [AgentThreadID: Bool] = Dictionary(uniqueKeysWithValues: h.threads.map { tid in
            (tid, !((try? h.repo.listRecent(threadId: tid, limit: 1)) ?? []).isEmpty)
        })

        // batch path (PERF-007 single query)
        let locked = try h.repo.threadIdsWithMessages()
        let batchResult: [AgentThreadID: Bool] = Dictionary(uniqueKeysWithValues: h.threads.map { tid in
            (tid, locked.contains(tid))
        })

        XCTAssertEqual(batchResult, perThread,
            "batch threadIdsWithMessages must produce the same locked flag as the " +
            "per-thread listRecent(limit:1) path; collapsing N queries to 1 must not " +
            "change the computed provider_locked value for any thread")
    }

    // when no threads have messages, both paths must report all threads as unlocked.
    func test_noMessages_allUnlocked() throws {
        let h = try makeHarness(threadCount: 3, populatedIndices: [])
        let locked = try h.repo.threadIdsWithMessages()
        for tid in h.threads {
            XCTAssertFalse(locked.contains(tid),
                "thread with no messages must not appear in threadIdsWithMessages set")
        }
    }

    // when all threads have messages, both paths must report all threads as locked.
    func test_allHaveMessages_allLocked() throws {
        let h = try makeHarness(threadCount: 4, populatedIndices: [0, 1, 2, 3])
        let locked = try h.repo.threadIdsWithMessages()
        for tid in h.threads {
            XCTAssertTrue(locked.contains(tid),
                "thread with at least one message must appear in threadIdsWithMessages set")
        }
    }
}
