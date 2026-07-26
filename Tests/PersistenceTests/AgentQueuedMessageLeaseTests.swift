import XCTest
@testable import Persistence
import CoreModel

final class AgentQueuedMessageLeaseTests: XCTestCase {
    func test_claimReleaseAndAck_keepQueueDurableUntilProviderStartIsConfirmed() throws {
        let tmp = NSTemporaryDirectory() + "rc2-queue-lease-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let repo = AgentQueuedMessageRepository(db: db)
        let threadRepo = AgentThreadRepository(db: db)
        let thread = AgentThread(title: "queue", provider: .codex, model: "gpt")
        try threadRepo.upsert(thread)
        let queued = try repo.enqueue(threadId: thread.id, text: "do not lose me", attachments: [], interactionMode: .default)

        let firstLease = try XCTUnwrap(repo.claimFirst(threadId: thread.id, leaseId: "attempt-1", now: Date(timeIntervalSince1970: 100)))
        XCTAssertEqual(firstLease.message.id, queued.id)
        XCTAssertNil(try repo.claimFirst(threadId: thread.id, leaseId: "attempt-2", now: Date(timeIntervalSince1970: 101)),
                     "a concurrent drain must not claim an in-flight queue row twice")
        XCTAssertEqual(try repo.list(threadId: thread.id).map(\.id), [queued.id],
                       "claim is a lease, not a destructive dequeue")

        XCTAssertTrue(try repo.release(firstLease))
        let retryLease = try XCTUnwrap(repo.claimFirst(threadId: thread.id, leaseId: "attempt-2", now: Date(timeIntervalSince1970: 102)))
        XCTAssertEqual(retryLease.message.id, queued.id,
                       "provider-start failure must make the same durable message retryable")
        let runId = AgentRunID(queued.id.value)
        XCTAssertTrue(try repo.prepareDispatch(retryLease, runId: runId))
        XCTAssertTrue(try repo.markDispatched(retryLease, runId: runId))
        XCTAssertEqual(try repo.acknowledge(retryLease)?.id, queued.id)
        XCTAssertTrue(try repo.list(threadId: thread.id).isEmpty,
                      "only a confirmed provider start may acknowledge and remove the queue row")
    }

    func test_claimFirst_doesNotSkipLeasedHeadAndStartLaterMessagePrematurely() throws {
        let tmp = NSTemporaryDirectory() + "rc2-queue-lease-head-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let repo = AgentQueuedMessageRepository(db: db)
        let thread = AgentThread(title: "queue", provider: .codex, model: "gpt")
        try AgentThreadRepository(db: db).upsert(thread)
        let first = AgentQueuedMessage(threadId: thread.id, text: "first", position: 1)
        let second = AgentQueuedMessage(threadId: thread.id, text: "second", position: 2)
        try repo.upsert(first)
        try repo.upsert(second)
        let headLease = try XCTUnwrap(repo.claim(id: first.id, leaseId: "force-now"))

        XCTAssertNil(try repo.claimFirst(threadId: thread.id, leaseId: "automatic-drain"),
                     "an automatic drain must wait for the leased head; skipping to a later row can reorder provider side effects before force-now acknowledges")

        let runId = AgentRunID(first.id.value)
        XCTAssertTrue(try repo.prepareDispatch(headLease, runId: runId))
        XCTAssertTrue(try repo.markDispatched(headLease, runId: runId))
        XCTAssertEqual(try repo.acknowledge(headLease)?.id, first.id)
        XCTAssertEqual(try repo.claimFirst(threadId: thread.id, leaseId: "automatic-drain")?.message.id, second.id,
                       "after the head is acknowledged, the next row becomes claimable in order")
    }

    func test_claimedMessageRejectsEditCancelAndReorderAtProviderStartSeam() throws {
        let tmp = NSTemporaryDirectory() + "rc2-queue-lease-mutations-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let repo = AgentQueuedMessageRepository(db: db)
        let threadRepo = AgentThreadRepository(db: db)
        let thread = AgentThread(title: "queue", provider: .codex, model: "gpt")
        try threadRepo.upsert(thread)
        let first = try repo.enqueue(threadId: thread.id, text: "first", attachments: [], interactionMode: .default)
        let claimed = try repo.enqueue(threadId: thread.id, text: "provider start", attachments: [], interactionMode: .default)
        let third = try repo.enqueue(threadId: thread.id, text: "third", attachments: [], interactionMode: .default)
        let lease = try XCTUnwrap(repo.claim(id: claimed.id, leaseId: "provider-start"))

        XCTAssertNil(try repo.update(id: claimed.id, text: "edited too late", attachments: []),
                     "the UI edit seam must not change text already handed to the provider")
        XCTAssertNil(try repo.delete(id: claimed.id),
                     "cancel must not delete a message while provider start acknowledgement is pending")
        XCTAssertNil(try repo.promoteToFront(id: claimed.id),
                     "reorder must not move a message whose provider-start lease is active")

        var reorderedFirst = first
        reorderedFirst.position = 3
        XCTAssertThrowsError(try repo.upsert(reorderedFirst)) { error in
            XCTAssertEqual(error as? AgentQueuedMessageMutationError, .queueIsLeased)
        }
        XCTAssertEqual(try repo.list(threadId: thread.id).map(\.id), [first.id, claimed.id, third.id],
                       "a rejected bulk reorder must leave every queue position unchanged")

        XCTAssertTrue(try repo.release(lease))
        XCTAssertEqual(try repo.update(id: claimed.id, text: "editable again", attachments: [])?.text, "editable again")
    }

    func test_promoteUnleasedMessageAheadOfActiveLeasePreservesLeaseAndNextIntent() throws {
        // WHY: a second Force may arrive while the first intent owns the
        // provider-start lease. It must choose the next intent without mutating
        // or replaying the in-flight owner.
        let tmp = NSTemporaryDirectory() + "rc2-queue-force-next-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let repo = AgentQueuedMessageRepository(db: db)
        let thread = AgentThread(title: "queue", provider: .codex, model: "gpt")
        try AgentThreadRepository(db: db).upsert(thread)
        let first = try repo.enqueue(
            threadId: thread.id,
            text: "in-flight owner",
            attachments: [],
            interactionMode: .default
        )
        let second = try repo.enqueue(
            threadId: thread.id,
            text: "forced next",
            attachments: [],
            interactionMode: .default
        )
        let lease = try XCTUnwrap(repo.claim(id: first.id, leaseId: "provider-start"))
        let runId = AgentRunID(first.id.value)
        XCTAssertTrue(try repo.prepareDispatch(lease, runId: runId))

        XCTAssertNil(
            try repo.promoteToFront(id: second.id),
            "promotion must remain deferred while the durable owner is ambiguous"
        )
        XCTAssertEqual(try repo.first(threadId: thread.id)?.id, first.id,
                       "a crash in this window must still recover the prepared owner first")
        XCTAssertNil(
            try repo.claimFirst(threadId: thread.id, leaseId: "must-wait"),
            "the active lease remains the provider-side owner until it settles"
        )
        XCTAssertTrue(try repo.releasePrepared(lease, runId: runId, promoting: second.id))
        XCTAssertEqual(
            try repo.claimFirst(threadId: thread.id, leaseId: "next")?.message.id,
            second.id,
            "after the cancelled owner releases, the explicitly forced intent must run next"
        )
        XCTAssertNotNil(try repo.get(id: first.id),
                        "promoting the next intent must not discard the prior durable intent")
    }

    func test_staleLeaseCannotReleaseOrAcknowledgeReplacementLease() throws {
        let tmp = NSTemporaryDirectory() + "rc2-queue-lease-owner-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let repo = AgentQueuedMessageRepository(db: db)
        let threadRepo = AgentThreadRepository(db: db)
        let thread = AgentThread(title: "queue", provider: .codex, model: "gpt")
        try threadRepo.upsert(thread)
        let queued = try repo.enqueue(threadId: thread.id, text: "exactly once", attachments: [], interactionMode: .default)
        let stale = try XCTUnwrap(repo.claim(id: queued.id, leaseId: "stale", now: Date(timeIntervalSince1970: 100)))
        let current = try XCTUnwrap(repo.claim(
            id: queued.id,
            leaseId: "current",
            now: Date(timeIntervalSince1970: 1_000),
            leaseTimeout: 100
        ))

        XCTAssertFalse(try repo.release(stale), "release must compare-and-clear by lease_id in one SQL mutation")
        XCTAssertNil(try repo.acknowledge(stale), "acknowledge must compare-and-delete by lease_id in one transaction")
        XCTAssertEqual(try repo.get(id: queued.id)?.id, queued.id)
        let runId = AgentRunID(queued.id.value)
        XCTAssertTrue(try repo.prepareDispatch(current, runId: runId))
        XCTAssertTrue(try repo.markDispatched(current, runId: runId))
        XCTAssertEqual(try repo.acknowledge(current)?.id, queued.id)
        XCTAssertNil(try repo.get(id: queued.id))
    }

    func test_deleteDoesNotRepositionAnotherClaimedMessageAndReleaseClosesGap() throws {
        let tmp = NSTemporaryDirectory() + "rc2-queue-lease-position-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let repo = AgentQueuedMessageRepository(db: db)
        let threadRepo = AgentThreadRepository(db: db)
        let thread = AgentThread(title: "queue", provider: .codex, model: "gpt")
        try threadRepo.upsert(thread)
        let first = try repo.enqueue(threadId: thread.id, text: "first", attachments: [], interactionMode: .default)
        let claimed = try repo.enqueue(threadId: thread.id, text: "claimed", attachments: [], interactionMode: .default)
        let third = try repo.enqueue(threadId: thread.id, text: "third", attachments: [], interactionMode: .default)
        let lease = try XCTUnwrap(repo.claim(id: claimed.id, leaseId: "provider-start"))

        XCTAssertEqual(try repo.delete(id: first.id)?.id, first.id)
        XCTAssertEqual(try repo.get(id: claimed.id)?.position, 2,
                       "normalizing another deletion must not reorder a claimed message")
        XCTAssertEqual(try repo.get(id: third.id)?.position, 1)

        XCTAssertTrue(try repo.release(lease))
        XCTAssertEqual(try repo.list(threadId: thread.id).map(\.position), [1, 2],
                       "release makes the row mutable again and closes any deferred position gap")
    }

    func test_preparedDispatchRequeuesOnlyAfterCallerProvesProviderStartWasNotReached() throws {
        let tmp = NSTemporaryDirectory() + "rc2-queue-prepared-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let repo = AgentQueuedMessageRepository(db: db)
        let thread = AgentThread(title: "queue", provider: .codex, model: "gpt")
        try AgentThreadRepository(db: db).upsert(thread)
        let first = try repo.enqueue(threadId: thread.id, text: "ambiguous", attachments: [], interactionMode: .default)
        _ = try repo.enqueue(threadId: thread.id, text: "later", attachments: [], interactionMode: .default)
        let lease = try XCTUnwrap(repo.claim(id: first.id, leaseId: "owner", now: Date(timeIntervalSince1970: 100)))
        let runId = AgentRunID(first.id.value)
        XCTAssertTrue(try repo.prepareDispatch(lease, runId: runId, at: Date(timeIntervalSince1970: 101)))

        XCTAssertNil(try repo.claim(id: first.id, leaseId: "relaunch", now: Date(timeIntervalSince1970: 10_000), leaseTimeout: 1),
                     "prepared intent must stay non-replayable until run-row absence is proved")
        XCTAssertEqual(try repo.dispatch(id: first.id)?.state, .prepared)
        XCTAssertEqual(try repo.dispatch(id: first.id)?.runId, runId)

        XCTAssertEqual(try repo.recoverPreparedBeforeProviderStart(id: first.id, runId: runId)?.id, first.id,
                       "run-row absence proof must CAS the exact prepared identity back to queued")
        XCTAssertNil(try repo.recoverPreparedBeforeProviderStart(id: first.id, runId: runId),
                     "concurrent launch reconcilers may recover the prepared row exactly once")
        XCTAssertEqual(try repo.claimFirst(threadId: thread.id, leaseId: "retry")?.message.id, first.id,
                       "safe recovery must restore the original head without skipping later messages")
    }

    func test_preparedDispatchWithRunEvidenceAcknowledgesExactlyOnceWithoutReplay() throws {
        let tmp = NSTemporaryDirectory() + "rc2-queue-prepared-run-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let repo = AgentQueuedMessageRepository(db: db)
        let thread = AgentThread(title: "queue", provider: .codex, model: "gpt")
        try AgentThreadRepository(db: db).upsert(thread)
        let queued = try repo.enqueue(threadId: thread.id, text: "accepted by coordinator", attachments: [], interactionMode: .default)
        let lease = try XCTUnwrap(repo.claim(id: queued.id, leaseId: "dead-owner"))
        let runId = AgentRunID(queued.id.value)
        XCTAssertTrue(try repo.prepareDispatch(lease, runId: runId))

        XCTAssertNil(try repo.acknowledgePreparedWithRunEvidence(id: queued.id, runId: AgentRunID()),
                     "acknowledgement must match the deterministic queue/run identity")
        XCTAssertEqual(try repo.acknowledgePreparedWithRunEvidence(id: queued.id, runId: runId)?.id, queued.id)
        XCTAssertNil(try repo.acknowledgePreparedWithRunEvidence(id: queued.id, runId: runId),
                     "concurrent launch reconcilers may acknowledge prepared intent exactly once")
        XCTAssertNil(try repo.get(id: queued.id))
    }

    func test_dispatchedRecoveryAcknowledgesExactlyOnceWithoutLeaseTakeover() throws {
        let tmp = NSTemporaryDirectory() + "rc2-queue-dispatched-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let repo = AgentQueuedMessageRepository(db: db)
        let thread = AgentThread(title: "queue", provider: .codex, model: "gpt")
        try AgentThreadRepository(db: db).upsert(thread)
        let queued = try repo.enqueue(threadId: thread.id, text: "already accepted", attachments: [], interactionMode: .default)
        let lease = try XCTUnwrap(repo.claim(id: queued.id, leaseId: "dead-owner"))
        let runId = AgentRunID(queued.id.value)
        XCTAssertTrue(try repo.prepareDispatch(lease, runId: runId))
        XCTAssertTrue(try repo.markDispatched(lease, runId: runId))

        XCTAssertNil(try repo.acknowledgeDispatched(id: queued.id, runId: AgentRunID()),
                     "relaunch recovery must require the durable run identity")
        XCTAssertEqual(try repo.acknowledgeDispatched(id: queued.id, runId: runId)?.id, queued.id,
                       "dispatched recovery performs ack-only and never needs to reconstruct or steal the old lease")
        XCTAssertNil(try repo.acknowledgeDispatched(id: queued.id, runId: runId),
                     "concurrent/repeated recovery may emit drained only for the one successful delete")
    }

    func test_claimCASAcrossTwoSQLiteConnectionsHasSingleWinner() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rc2-queue-cas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("queue.sqlite").path
        let firstDB = try SQLiteDB(path: path)
        try Schema.migrate(firstDB)
        let secondDB = try SQLiteDB(path: path)
        let firstRepo = AgentQueuedMessageRepository(db: firstDB)
        let secondRepo = AgentQueuedMessageRepository(db: secondDB)
        let thread = AgentThread(title: "queue", provider: .codex, model: "gpt")
        try AgentThreadRepository(db: firstDB).upsert(thread)
        let queued = try firstRepo.enqueue(threadId: thread.id, text: "one start", attachments: [], interactionMode: .default)
        let lock = NSLock()
        var winners: [AgentQueuedMessageLease] = []

        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let repo = index.isMultiple(of: 2) ? firstRepo : secondRepo
            if let lease = try? repo.claim(id: queued.id, leaseId: "attempt-\(index)") {
                lock.withLock { winners.append(lease) }
            }
        }

        XCTAssertEqual(winners.count, 1,
                       "CAS across independent SQLite connections must admit exactly one provider-start owner")
    }
}
