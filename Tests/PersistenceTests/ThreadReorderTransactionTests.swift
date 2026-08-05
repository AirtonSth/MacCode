import XCTest
@testable import Persistence
import CoreModel

/// WHY (L83 perf fix): normalizeOrder, promoteToFront, and normalizePositions
/// previously issued one implicit transaction per upsert/UPDATE row. Wrapping
/// each loop in db.transaction{} reduces N WAL fsyncs to 1. These tests pin
/// the final row state so the transaction wrap cannot silently alter observable
/// behavior (order, positions, pinned grouping, rollback consistency).
final class ThreadReorderTransactionTests: XCTestCase {

    // MARK: - Helpers

    private func makeDB() throws -> SQLiteDB {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return db
    }

    private func makeWorkspace(db: SQLiteDB) throws -> WorkspaceID {
        let wid = WorkspaceID()
        // agent_threads references workspaces only by column; no FK to a workspaces table.
        return wid
    }

    private func makeThread(
        db: SQLiteDB,
        workspaceId: WorkspaceID,
        title: String,
        pinned: Bool = false
    ) throws -> AgentThread {
        var t = AgentThread(workspaceId: workspaceId, title: title, provider: .codex, model: "m")
        t.pinned = pinned
        try AgentThreadRepository(db: db).upsert(t)
        return t
    }

    // MARK: - normalizeOrder: final row state after reorder

    /// WHY: reorder() still renumbers sortOrder in one transaction. With
    /// activity-based list order the move uses that order, but the final
    /// sortOrder set must stay contiguous 0..n-1.
    func test_reorder_finalSortOrderIsIdenticalAfterTransactionWrap() throws {
        let db = try makeDB()
        let repo = AgentThreadRepository(db: db)
        let wid = try makeWorkspace(db: db)

        _ = try makeThread(db: db, workspaceId: wid, title: "A")
        _ = try makeThread(db: db, workspaceId: wid, title: "B")
        let tC = try makeThread(db: db, workspaceId: wid, title: "C")

        try repo.reorder(id: tC.id, position: 0)

        let listed = try repo.list(workspaceId: wid)
        XCTAssertEqual(Set(listed.map(\.sortOrder)), Set([0, 1, 2]),
            "sortOrder must be contiguous 0-1-2 after normalizeOrder")
        XCTAssertEqual(listed.count, 3)
    }

    /// WHY: pin remains a retention/visual marker, but rail order is last
    /// activity only — pinning must not force a stale thread above newer work.
    func test_setPinned_doesNotOverrideLastActivityOrder() throws {
        let db = try makeDB()
        let repo = AgentThreadRepository(db: db)
        let wid = try makeWorkspace(db: db)

        var oldPinned = AgentThread(workspaceId: wid, title: "old-pinned", provider: .codex, model: "m")
        oldPinned.updatedAt = Date(timeIntervalSince1970: 100)
        try repo.upsert(oldPinned)
        try repo.setPinned(id: oldPinned.id, pinned: true)

        // setPinned bumps updatedAt — reset it so the case is activity-driven.
        var pinned = try XCTUnwrap(repo.get(id: oldPinned.id))
        pinned.updatedAt = Date(timeIntervalSince1970: 100)
        try repo.upsert(pinned)

        var fresh = AgentThread(workspaceId: wid, title: "fresh", provider: .codex, model: "m")
        fresh.updatedAt = Date(timeIntervalSince1970: 500)
        try repo.upsert(fresh)

        let listed = try repo.list(workspaceId: wid)
        XCTAssertEqual(listed.map(\.title), ["fresh", "old-pinned"],
            "last activity wins over pin for rail order")
        XCTAssertTrue(listed.contains(where: { $0.title == "old-pinned" && $0.pinned }))
    }

    /// WHY: reorder to a clamped position (beyond list end) must renumber
    /// sortOrder without leaving gaps or crashing.
    func test_reorder_beyondEnd_clampsToTail() throws {
        let db = try makeDB()
        let repo = AgentThreadRepository(db: db)
        let wid = try makeWorkspace(db: db)

        let tA = try makeThread(db: db, workspaceId: wid, title: "A")
        _ = try makeThread(db: db, workspaceId: wid, title: "B")
        _ = try makeThread(db: db, workspaceId: wid, title: "C")

        try repo.reorder(id: tA.id, position: 999)

        let listed = try repo.list(workspaceId: wid)
        XCTAssertEqual(Set(listed.map(\.sortOrder)), Set([0, 1, 2]),
            "reorder beyond end must leave contiguous sortOrder values")
        XCTAssertEqual(listed.first(where: { $0.id == tA.id })?.sortOrder, 2,
            "clamped tail index is the last sortOrder slot")
    }

    /// WHY: users expect the rail to surface the most recently finished/active
    /// thread at the top (last activity DESC), not a frozen manual sort_order.
    func test_list_ordersByLastActivityDescending_becauseFinishedRunsShouldFloatToTop() throws {
        let db = try makeDB()
        let repo = AgentThreadRepository(db: db)
        let wid = try makeWorkspace(db: db)

        var older = AgentThread(workspaceId: wid, title: "older", provider: .codex, model: "m")
        older.updatedAt = Date(timeIntervalSince1970: 100)
        older.status = .completed
        try repo.upsert(older)

        var middle = AgentThread(workspaceId: wid, title: "middle", provider: .codex, model: "m")
        middle.updatedAt = Date(timeIntervalSince1970: 200)
        middle.status = .completed
        try repo.upsert(middle)

        var newest = AgentThread(workspaceId: wid, title: "newest", provider: .codex, model: "m")
        newest.updatedAt = Date(timeIntervalSince1970: 300)
        newest.status = .completed
        try repo.upsert(newest)

        let listed = try repo.list(workspaceId: wid)
        XCTAssertEqual(listed.map(\.title), ["newest", "middle", "older"],
            "list must order by updated_at DESC so the most recent activity is first")
    }

    /// WHY: each workspace keeps at most maxThreadsPerWorkspace (5) so scheduled
    /// runs cannot grow SQLite without bound. Only empty terminal shells are
    /// eligible; among those, the oldest updated_at go first. Active runs never
    /// qualify.
    func test_enforceWorkspaceThreadLimit_prunesOldestBeyond100() throws {
        let db = try makeDB()
        let repo = AgentThreadRepository(db: db)
        let wid = try makeWorkspace(db: db)
        let limit = 5

        for i in 0..<8 {
            var t = AgentThread(workspaceId: wid, title: "t\(i)", provider: .codex, model: "m")
            t.updatedAt = Date(timeIntervalSince1970: TimeInterval(i))
            t.status = .completed
            try repo.upsert(t)
        }
        // Keep one old running thread — must not be pruned.
        var running = AgentThread(workspaceId: wid, title: "running", provider: .codex, model: "m")
        running.updatedAt = Date(timeIntervalSince1970: 0)
        running.status = .running
        try repo.upsert(running)

        let deleted = try repo.enforceWorkspaceThreadLimit(workspaceId: wid, limit: limit)
        XCTAssertEqual(try repo.count(workspaceId: wid), limit)
        XCTAssertEqual(deleted.count, 4, "9 rows → keep 5, delete 4 oldest eligible empty shells")
        let remaining = try repo.list(workspaceId: wid)
        XCTAssertTrue(remaining.contains(where: { $0.title == "running" }),
                      "running threads must never be auto-pruned")
        XCTAssertFalse(remaining.contains(where: { $0.title == "t1" }),
                       "oldest empty shells must be pruned first")
    }

    /// WHY: hard cap reclaims oldest terminal history (including messages) but
    /// never a live-bound surface selection. Empty shells and old chats are both
    /// eligible; binding is not.
    func test_workspaceThreadLimitReclaimsHistoryButProtectsLiveSurfaceBinding() throws {
        let db = try makeDB()
        let repo = AgentThreadRepository(db: db)
        let messages = AgentMessageRepository(db: db)
        let wid = try makeWorkspace(db: db)

        var withHistory = AgentThread(workspaceId: wid, title: "has history", provider: .codex, model: "m")
        withHistory.status = .completed
        withHistory.updatedAt = Date(timeIntervalSince1970: 1)
        var liveBound = AgentThread(workspaceId: wid, title: "live bound", provider: .codex, model: "m")
        liveBound.status = .completed
        liveBound.updatedAt = Date(timeIntervalSince1970: 2)
        var newerHistory = AgentThread(workspaceId: wid, title: "newer history", provider: .codex, model: "m")
        newerHistory.status = .completed
        newerHistory.updatedAt = Date(timeIntervalSince1970: 3)
        for thread in [withHistory, liveBound, newerHistory] {
            try repo.upsert(thread)
        }
        try messages.append(AgentMessage(threadId: withHistory.id, role: .user, content: "old chat"))
        try messages.append(AgentMessage(threadId: newerHistory.id, role: .user, content: "newer chat"))
        let surfaceID = SurfaceID()
        repo.setLiveSurfaceBinding(surfaceID: surfaceID, threadID: liveBound.id)
        XCTAssertEqual(repo.liveSurfaceBoundThreadIDsForTesting, [liveBound.id])

        let created = AgentThread(workspaceId: wid, title: "new thread", provider: .codex, model: "m")
        let pruned = try repo.upsertEnforcingWorkspaceThreadLimit(created, limit: 3)

        XCTAssertEqual(pruned, [withHistory.id],
                       "oldest terminal history is reclaimed first, even with messages")
        XCTAssertNil(try repo.get(id: withHistory.id))
        XCTAssertNotNil(try repo.get(id: liveBound.id), "live surface binding must not be a victim")
        XCTAssertNotNil(try repo.get(id: newerHistory.id))
        XCTAssertNotNil(try repo.get(id: created.id))

        // Wipe reclaimable terminals; leave only live-bound + active runs.
        try repo.delete(id: newerHistory.id)
        try repo.delete(id: created.id)
        for index in 0..<2 {
            var running = AgentThread(workspaceId: wid, title: "running \(index)", provider: .codex, model: "m")
            running.status = .running
            running.updatedAt = Date(timeIntervalSince1970: TimeInterval(10 + index))
            try repo.upsert(running)
        }
        // liveBound + 2 running = 3; blocked create needs a victim but none eligible.
        let blocked = AgentThread(workspaceId: wid, title: "blocked", provider: .codex, model: "m")
        XCTAssertThrowsError(try repo.upsertEnforcingWorkspaceThreadLimit(blocked, limit: 3)) { error in
            guard case let .workspaceLimitExceeded(_, _, _, diagnostics)? =
                    error as? AgentThreadCapacityError else {
                return XCTFail("expected capacity error with diagnostics")
            }
            XCTAssertGreaterThan(diagnostics.protectedCounts["surface_bound"] ?? 0, 0)
            XCTAssertTrue(
                (error as? AgentThreadCapacityError)?.description.contains("No reclaimable terminal thread") == true
            )
        }
        XCTAssertNil(try repo.get(id: blocked.id))

        repo.setLiveSurfaceBinding(surfaceID: surfaceID, threadID: nil)
        XCTAssertTrue(repo.liveSurfaceBoundThreadIDsForTesting.isEmpty)
    }

    /// WHY: long agent sessions must not retain unbounded durable messages;
    /// only the newest N movements stay in SQLite after each append.
    func test_append_prunesMessagesKeepingOnlyLatest100() throws {
        let db = try makeDB()
        let threads = AgentThreadRepository(db: db)
        let messages = AgentMessageRepository(db: db)
        let wid = try makeWorkspace(db: db)
        var thread = AgentThread(workspaceId: wid, title: "long chat", provider: .codex, model: "m")
        thread.status = .completed
        try threads.upsert(thread)

        let keep = AgentMessageRepository.maxMessagesPerThread
        for index in 0..<(keep + 25) {
            try messages.append(AgentMessage(
                threadId: thread.id,
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "msg-\(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            ))
        }
        let remaining = try messages.list(threadId: thread.id)
        XCTAssertEqual(remaining.count, keep)
        XCTAssertEqual(remaining.first?.content, "msg-25",
                       "oldest messages beyond the retention window must be deleted")
        XCTAssertEqual(remaining.last?.content, "msg-\(keep + 24)",
                       "the newest message must survive pruning")
    }

    /// WHY: the automatic cap is allowed to reclaim cached history, never an
    /// unsent user draft or a thread that owns a materialized worktree. Both a
    /// clean and a dirty worktree are resources outside this DELETE transaction.
    func test_workspaceThreadLimitProtectsDurableDraftsAndCleanOrDirtyWorktrees() throws {
        let db = try makeDB()
        let repo = AgentThreadRepository(db: db)
        let drafts = AgentThreadDraftRepository(db: db)
        let wid = try makeWorkspace(db: db)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-thread-cap-protected-\(UUID().uuidString)", isDirectory: true)
        let cleanPath = root.appendingPathComponent("clean", isDirectory: true)
        let dirtyPath = root.appendingPathComponent("dirty", isDirectory: true)
        try FileManager.default.createDirectory(at: cleanPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirtyPath, withIntermediateDirectories: true)
        try Data("uncommitted".utf8).write(to: dirtyPath.appendingPathComponent("dirty.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        var draft = AgentThread(workspaceId: wid, title: "durable draft", provider: .codex, model: "m")
        draft.status = .completed
        draft.updatedAt = Date(timeIntervalSince1970: 1)
        var cleanWorktree = AgentThread(
            workspaceId: wid,
            title: "clean worktree",
            provider: .codex,
            model: "m",
            status: .completed,
            executionMode: .worktree,
            worktreePath: cleanPath.path
        )
        cleanWorktree.updatedAt = Date(timeIntervalSince1970: 2)
        var dirtyWorktree = AgentThread(
            workspaceId: wid,
            title: "dirty worktree",
            provider: .codex,
            model: "m",
            status: .completed,
            executionMode: .worktree,
            worktreePath: dirtyPath.path
        )
        dirtyWorktree.updatedAt = Date(timeIntervalSince1970: 3)
        var disposable = AgentThread(workspaceId: wid, title: "disposable cache", provider: .codex, model: "m")
        disposable.status = .completed
        disposable.updatedAt = Date(timeIntervalSince1970: 4)
        for thread in [draft, cleanWorktree, dirtyWorktree, disposable] {
            try repo.upsert(thread)
        }
        try drafts.upsert(AgentThreadDraft(
            threadId: draft.id,
            providerInstanceId: "codex",
            text: "do not lose this unsent prompt",
            attachments: [AgentAttachment(path: root.appendingPathComponent("note.txt").path, kind: .file)]
        ))

        let created = AgentThread(workspaceId: wid, title: "new thread", provider: .codex, model: "m")
        let pruned = try repo.upsertEnforcingWorkspaceThreadLimit(created, limit: 4)

        XCTAssertEqual(pruned, [disposable.id],
                       "only genuinely disposable cached history may satisfy the cap")
        for protected in [draft, cleanWorktree, dirtyWorktree] {
            XCTAssertNotNil(try repo.get(id: protected.id),
                            "automatic retention must preserve \(protected.title)")
        }
        XCTAssertNotNil(try repo.get(id: created.id))
    }

    /// WHY: when every possible victim owns user data or a worktree, the new row
    /// must roll back as one transaction. Returning an empty victim list while
    /// retaining the overflowing row would falsely report a successful cap pass.
    func test_workspaceThreadLimitFailsAtomicallyWhenOnlyDraftAndWorktreeRowsRemain() throws {
        let db = try makeDB()
        let repo = AgentThreadRepository(db: db)
        let drafts = AgentThreadDraftRepository(db: db)
        let wid = try makeWorkspace(db: db)
        var draft = AgentThread(workspaceId: wid, title: "protected draft", provider: .codex, model: "m")
        draft.status = .completed
        var cleanWorktree = AgentThread(
            workspaceId: wid,
            title: "protected clean worktree",
            provider: .codex,
            model: "m",
            status: .completed,
            executionMode: .worktree,
            worktreePath: "/tmp/clean-worktree"
        )
        var dirtyWorktree = AgentThread(
            workspaceId: wid,
            title: "protected dirty worktree",
            provider: .codex,
            model: "m",
            status: .completed,
            executionMode: .worktree,
            worktreePath: "/tmp/dirty-worktree"
        )
        draft.updatedAt = Date(timeIntervalSince1970: 1)
        cleanWorktree.updatedAt = Date(timeIntervalSince1970: 2)
        dirtyWorktree.updatedAt = Date(timeIntervalSince1970: 3)
        for thread in [draft, cleanWorktree, dirtyWorktree] {
            try repo.upsert(thread)
        }
        try drafts.upsert(AgentThreadDraft(
            threadId: draft.id,
            providerInstanceId: "codex",
            text: "",
            attachments: [AgentAttachment(path: "/tmp/attachment.txt", kind: .file)]
        ))
        let prospective = AgentThread(workspaceId: wid, title: "must roll back", provider: .codex, model: "m")
        let originalIDs = Set([draft.id, cleanWorktree.id, dirtyWorktree.id])

        XCTAssertThrowsError(try repo.enforceWorkspaceThreadLimit(workspaceId: wid, limit: 2)) {
            XCTAssertTrue($0 is AgentThreadCapacityError)
        }
        XCTAssertThrowsError(try repo.preflightWorkspaceThreadInsertion(
            workspaceId: wid,
            prospectiveThreadId: prospective.id,
            limit: 3
        )) { XCTAssertTrue($0 is AgentThreadCapacityError) }
        XCTAssertThrowsError(try repo.upsertEnforcingWorkspaceThreadLimit(prospective, limit: 3)) {
            XCTAssertTrue($0 is AgentThreadCapacityError)
        }

        XCTAssertEqual(Set(try repo.list(workspaceId: wid).map(\.id)), originalIDs,
                       "a protected-only cap failure must leave every original row untouched")
        XCTAssertNil(try repo.get(id: prospective.id),
                     "the rejected producer row must roll back with the failed cap transaction")
    }

    /// WHY: selection is advisory. If an idle thread gains a durable draft in
    /// the narrow selection-to-delete window, the final DELETE guard must fail
    /// loud and roll back every tentative delete instead of silently cascading
    /// the just-saved draft.
    func test_enforceWorkspaceThreadLimit_draftAddedDuringVictimDeleteRollsBackEverything() throws {
        let db = try makeDB()
        let repo = AgentThreadRepository(db: db)
        let drafts = AgentThreadDraftRepository(db: db)
        let wid = try makeWorkspace(db: db)
        var threads: [AgentThread] = []
        for index in 0..<3 {
            var thread = AgentThread(workspaceId: wid, title: "candidate \(index)", provider: .codex, model: "m")
            thread.status = .completed
            thread.updatedAt = Date(timeIntervalSince1970: TimeInterval(index))
            try repo.upsert(thread)
            threads.append(thread)
        }
        var addedDraft = false
        db.beforeStatementStepForTesting = { sql in
            guard !addedDraft, sql.contains("DELETE FROM agent_threads") else { return }
            addedDraft = true
            try? drafts.upsert(AgentThreadDraft(
                threadId: threads[0].id,
                providerInstanceId: "codex",
                text: "saved during cap delete"
            ))
        }
        defer { db.beforeStatementStepForTesting = nil }

        XCTAssertThrowsError(try repo.enforceWorkspaceThreadLimit(workspaceId: wid, limit: 2)) {
            XCTAssertTrue($0 is AgentThreadCapacityError)
        }
        XCTAssertTrue(addedDraft)
        XCTAssertEqual(Set(try repo.list(workspaceId: wid).map(\.id)), Set(threads.map(\.id)),
                       "the transaction must restore all rows when the selected victim becomes protected")
        XCTAssertNil(try drafts.get(threadId: threads[0].id),
                     "the simulated concurrent draft belongs to the rolled-back cap transaction")
    }

    /// WHY: a victim can become active after selection but before deletion.
    /// Reload-time retention must revalidate under one transaction and roll
    /// every tentative delete back instead of deleting the newly active row.
    func test_enforceWorkspaceThreadLimit_changedVictimRollsBackEveryDelete() throws {
        let db = try makeDB()
        let repo = AgentThreadRepository(db: db)
        let wid = try makeWorkspace(db: db)
        var threads: [AgentThread] = []
        for index in 0..<4 {
            var thread = AgentThread(
                workspaceId: wid,
                title: "candidate \(index)",
                provider: .codex,
                model: "m"
            )
            thread.status = .completed
            thread.updatedAt = Date(timeIntervalSince1970: TimeInterval(index))
            try repo.upsert(thread)
            threads.append(thread)
        }
        let changedVictim = threads[1]
        var didChangeVictim = false
        var mutationError: Error?
        db.beforeStatementStepForTesting = { sql in
            guard !didChangeVictim, sql.contains("DELETE FROM agent_threads") else { return }
            didChangeVictim = true
            do {
                try db.execute("""
                    UPDATE agent_threads SET status = 'running'
                    WHERE id = '\(changedVictim.id.value.uuidString)';
                    """)
            } catch {
                mutationError = error
            }
        }
        defer { db.beforeStatementStepForTesting = nil }

        XCTAssertThrowsError(try repo.enforceWorkspaceThreadLimit(workspaceId: wid, limit: 2)) {
            XCTAssertTrue($0 is AgentThreadCapacityError)
        }

        XCTAssertTrue(didChangeVictim, "the race hook must run between victim selection and deletion")
        XCTAssertNil(mutationError)
        XCTAssertEqual(try repo.count(workspaceId: wid), 4,
                       "a changed victim must roll back every earlier tentative victim delete")
        XCTAssertEqual(try repo.get(id: changedVictim.id)?.status, .completed,
                       "the simulated concurrent status write belongs to the rolled-back transaction")
        XCTAssertEqual(Set(try repo.list(workspaceId: wid).map(\.id)), Set(threads.map(\.id)))
    }

    /// WHY: one producer enforcing the cap must not prune the durable recovery
    /// identities of another in-flight fork. Both source and child are protected
    /// in every recoverable intent state, including preflight eligibility counts.
    func test_concurrentCapProducerProtectsRecoverableForkSourceAndChildGlobally() throws {
        for intentState in [
            AgentThreadForkIntentState.prepared,
            .providerCreated,
            .compensating
        ] {
            let db = try makeDB()
            let repo = AgentThreadRepository(db: db)
            let wid = try makeWorkspace(db: db)
            var source = AgentThread(workspaceId: wid, title: "source", provider: .codex, model: "m")
            source.status = .completed
            source.updatedAt = Date(timeIntervalSince1970: 1)
            var child = AgentThread(workspaceId: wid, title: "child", provider: .codex, model: "m")
            child.status = .completed
            child.updatedAt = Date(timeIntervalSince1970: 2)
            try repo.upsert(source)
            _ = try repo.prepareForkIntent(
                sourceThreadId: source.id,
                childThread: child,
                idempotencyKey: "fork-\(intentState.rawValue)"
            )
            if intentState != .prepared {
                _ = try repo.recordForkProviderCreated(
                    childThreadId: child.id,
                    providerChildThreadId: "provider-\(intentState.rawValue)"
                )
            }
            if intentState == .compensating {
                _ = try repo.markForkCompensating(childThreadId: child.id, error: "retry cleanup")
            }
            // Model a recoverable local child row left by an interrupted producer.
            try repo.upsert(child)
            let prospective = AgentThread(workspaceId: wid, title: "prospective", provider: .codex, model: "m")

            XCTAssertThrowsError(try repo.preflightWorkspaceThreadInsertion(
                workspaceId: wid,
                prospectiveThreadId: prospective.id,
                limit: 2
            )) { error in
                XCTAssertTrue(error is AgentThreadCapacityError,
                              "\(intentState.rawValue) participants are not eligible preflight victims")
            }

            var sibling = AgentThread(workspaceId: wid, title: "eligible sibling", provider: .codex, model: "m")
            sibling.status = .completed
            sibling.updatedAt = Date(timeIntervalSince1970: 3)
            try repo.upsert(sibling)
            var producer = prospective
            producer.status = .completed
            producer.updatedAt = Date(timeIntervalSince1970: 4)
            let pruned = try repo.upsertEnforcingWorkspaceThreadLimit(producer, limit: 3)

            XCTAssertEqual(pruned, [sibling.id],
                           "\(intentState.rawValue) must protect source and child from another producer")
            XCTAssertNotNil(try repo.get(id: source.id))
            XCTAssertNotNil(try repo.get(id: child.id))
            XCTAssertNotNil(try repo.get(id: producer.id))
        }
    }

    // MARK: - promoteToFront: final positions after transaction wrap

    /// WHY: promoteToFront now issues a single transaction for all position UPDATEs.
    /// Final positions must be identical: promoted=1, others shift up preserving relative order.
    func test_promoteToFront_finalPositionsIdenticalAfterTransactionWrap() throws {
        let db = try makeDB()
        let repo = AgentQueuedMessageRepository(db: db)
        let threadRepo = AgentThreadRepository(db: db)
        let thread = AgentThread(title: "q", provider: .codex, model: "m")
        try threadRepo.upsert(thread)

        let m1 = try repo.enqueue(threadId: thread.id, text: "first", attachments: [], interactionMode: .default)
        let m2 = try repo.enqueue(threadId: thread.id, text: "second", attachments: [], interactionMode: .default)
        let m3 = try repo.enqueue(threadId: thread.id, text: "third", attachments: [], interactionMode: .default)

        let promoted = try repo.promoteToFront(id: m3.id)

        XCTAssertEqual(promoted?.position, 1,
            "promoted message must be at position 1; transaction wrap must not alter the assignment")
        let listed = try repo.list(threadId: thread.id)
        XCTAssertEqual(listed.map(\.text), ["third", "first", "second"],
            "list after promote must be third-first-second preserving relative order of non-promoted messages")
        XCTAssertEqual(listed.map(\.position), [1, 2, 3],
            "positions must be contiguous 1-2-3 after promoteToFront; transaction must not leave gaps")
    }

    // MARK: - normalizePositions: final positions after delete + transaction wrap

    /// WHY: delete() calls normalizePositions which now issues a single transaction.
    /// Remaining rows must get contiguous positions with no gaps.
    func test_delete_normalizePositions_contiguousAfterTransactionWrap() throws {
        let db = try makeDB()
        let repo = AgentQueuedMessageRepository(db: db)
        let threadRepo = AgentThreadRepository(db: db)
        let thread = AgentThread(title: "q2", provider: .codex, model: "m")
        try threadRepo.upsert(thread)

        let m1 = try repo.enqueue(threadId: thread.id, text: "A", attachments: [], interactionMode: .default)
        let m2 = try repo.enqueue(threadId: thread.id, text: "B", attachments: [], interactionMode: .default)
        let m3 = try repo.enqueue(threadId: thread.id, text: "C", attachments: [], interactionMode: .default)
        let m4 = try repo.enqueue(threadId: thread.id, text: "D", attachments: [], interactionMode: .default)

        // Delete position-2 message (B)
        _ = try repo.delete(id: m2.id)

        let listed = try repo.list(threadId: thread.id)
        XCTAssertEqual(listed.map(\.text), ["A", "C", "D"],
            "B must be removed; A-C-D remain in original relative order")
        XCTAssertEqual(listed.map(\.position), [1, 2, 3],
            "positions must be renormalized to 1-2-3 with no gap at former position 2; transaction wrap must not change this")
    }
}
