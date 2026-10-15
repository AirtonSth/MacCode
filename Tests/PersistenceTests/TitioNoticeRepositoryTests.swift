import XCTest
import CoreModel
@testable import Persistence

/// The Titio notice ledger is what makes delivery exactly-once (hub spec §3):
/// one row per source key, frozen once posted, claimed by exactly one act, and
/// it must survive restarts and upgrades from schema v92.
final class TitioNoticeRepositoryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_792_094_460)

    private func make() throws -> (SQLiteDB, TitioNoticeRepository) {
        let path = NSTemporaryDirectory() + "titio-notices-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: path).run()
        return (db, TitioNoticeRepository(db: db))
    }

    private func rowCount(_ db: SQLiteDB, _ table: String = "titio_notices") throws -> Int {
        try db.performSync { database in
            let statement = try database.prepare("SELECT COUNT(*) FROM \(table);")
            defer { statement.reset() }
            _ = try statement.step()
            return Int(statement.columnInt64(0))
        }
    }

    private func fact(_ key: String, _ kind: TitioNoticeKind = .runCompleted, facts: TitioNoticeFacts = TitioNoticeFacts(title: "Build"),
                      actions: [TitioNoticeAction]? = nil, at offset: TimeInterval = 0) -> TitioNoticeFact {
        TitioNoticeFact(key: key, kind: kind, source: TitioNoticeSource(threadId: "T", runId: "R"), facts: facts,
                        actions: actions, occurredAt: t0.addingTimeInterval(offset))
    }

    @discardableResult
    private func post(_ repo: TitioNoticeRepository, _ keys: [String], at offset: TimeInterval = 1, preview: String = "p",
                      card: [TitioNoticeCardOption]? = nil, owner: String? = nil, unread: Bool = true) throws -> TitioNoticeFlushResult? {
        try repo.flush(keys: keys, postedAt: t0.addingTimeInterval(offset)) { rows in
            TitioNoticePosting(
                messageID: rows.count == 1 ? TitioNoticeIDs.messageID(forKey: rows[0].key).uuidString
                    : TitioNoticeIDs.digestMessageID(forKeys: rows.map(\.key)).uuidString,
                batchID: rows.count > 1 ? "batch-1" : nil,
                cardOwnerKey: owner, cardOptions: card, preview: preview, countsAsUnread: unread
            )
        }
    }

    // MARK: Ingest

    func test_sameKeyTwiceIsOneRowAndFactsMergeOnlyWhilePending() throws {
        // WHY: a replayed run-terminal callback or a second producer (scheduled
        // failure + run failure) must never create a second notice, and once the
        // message is posted its facts must not change under the user.
        let (db, repo) = try make()
        try repo.ingest(fact("run.R.failed", .runFailed, facts: TitioNoticeFacts(title: "Build", workspaceName: "api"), actions: [.openThread, .ack]))
        let merged = try XCTUnwrap(repo.ingest(TitioNoticeFact(
            key: "run.R.failed", kind: .scheduledFailed,
            source: TitioNoticeSource(scheduledTaskId: "S"),
            facts: TitioNoticeFacts(summary: "exit 1"),
            occurredAt: t0.addingTimeInterval(5)
        )))
        XCTAssertEqual(try rowCount(db), 1)
        XCTAssertEqual(merged.kind, .runFailed, "the first producer's kind stays")
        XCTAssertEqual(merged.facts, TitioNoticeFacts(title: "Build", workspaceName: "api", summary: "exit 1"))
        XCTAssertEqual(merged.source, TitioNoticeSource(threadId: "T", runId: "R", scheduledTaskId: "S"))
        XCTAssertEqual(merged.actions?.map(\.action), [.openThread, .ack], "a producer without a card keeps the existing card")
        XCTAssertNil(merged.actions?.first?.label, "labels are written only when posted")
        XCTAssertEqual(merged.state, .pending)
        XCTAssertEqual(merged.occurredAt, t0)

        try post(repo, ["run.R.failed"])
        try repo.ingest(fact("run.R.failed", .runFailed, facts: TitioNoticeFacts(title: "Changed", summary: "late")))
        let frozen = try XCTUnwrap(repo.get(key: "run.R.failed"))
        XCTAssertEqual(frozen.facts.title, "Build", "posted rows are frozen")
        XCTAssertEqual(frozen.facts.summary, "exit 1")
        XCTAssertEqual(frozen.state, .posted)
        XCTAssertEqual(try rowCount(db), 1)
    }

    func test_burstOfFiftyConcurrentIngestsLosesAndDuplicatesNothing() throws {
        // WHY (AGENTS.md loading rules): a rapid burst from several producers must
        // give exactly one row per key.
        let (db, repo) = try make()
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            _ = try? repo.ingest(fact("run.\(index % 50).completed", at: TimeInterval(index)))
        }
        XCTAssertEqual(try rowCount(db), 50)
        XCTAssertEqual(try repo.listPending().count, 50)
    }

    // MARK: Flush

    func test_flushPostsPendingRowsOnceAndUpdatesTheInbox() throws {
        // WHY: the message, the posted state and the unread bump commit together;
        // a second flush of the same keys finds nothing pending and posts nothing.
        let (_, repo) = try make()
        try repo.ingest(fact("run.A.completed"))
        let result = try XCTUnwrap(post(repo, ["run.A.completed"], at: 2, preview: "Build done"))
        let row = try XCTUnwrap(result.records.first)
        XCTAssertEqual(row.state, .posted)
        XCTAssertEqual(row.messageID, TitioNoticeIDs.messageID(forKey: "run.A.completed").uuidString)
        XCTAssertNil(row.batchID)
        XCTAssertEqual(row.postedAt, t0.addingTimeInterval(2))
        XCTAssertEqual(result.inbox.unreadCount, 1)
        XCTAssertEqual(result.inbox.lastPreview, "Build done")
        XCTAssertEqual(try repo.inboxState(), result.inbox)
        XCTAssertNil(try post(repo, ["run.A.completed"], at: 3), "already posted: no second message")
        XCTAssertEqual(try repo.inboxState().unreadCount, 1)
        XCTAssertEqual(try repo.notice(messageID: row.messageID!)?.key, "run.A.completed")
    }

    func test_flushThatThrowsRollsBackSoTheRowRetries() throws {
        // WHY (§3.6): if Titio's message cannot be written the row stays pending
        // and retries; a half-posted row would never be delivered.
        let (_, repo) = try make()
        try repo.ingest(fact("run.A.completed"))
        struct Boom: Error {}
        XCTAssertThrowsError(try repo.flush(keys: ["run.A.completed"], postedAt: t0) { _ in throw Boom() })
        XCTAssertEqual(try repo.get(key: "run.A.completed")?.state, .pending)
        XCTAssertEqual(try repo.inboxState(), TitioInboxState())
    }

    func test_digestStoresTheCardOnlyOnItsOwnerAndLookupFindsIt() throws {
        // WHY: a digest is one message for many rows; `bot.notice.act` looks the
        // card up by message id, so exactly one row may own the actions.
        let (_, repo) = try make()
        try repo.ingest(fact("run.A.completed", at: 0))
        try repo.ingest(fact("run.B.failed", .runFailed, actions: [.openThread, .ack], at: 1))
        let card = [TitioNoticeCardOption(label: "Abrir Build", action: .openThread),
                    TitioNoticeCardOption(label: "Ver tudo na Atividade", action: .openAllActivity)]
        let result = try XCTUnwrap(post(repo, ["run.B.failed", "run.A.completed"], card: card, owner: "run.B.failed"))
        XCTAssertEqual(result.records.map(\.key), ["run.A.completed", "run.B.failed"], "oldest first")
        XCTAssertEqual(Set(result.records.compactMap(\.batchID)), ["batch-1"])
        let messageID = try XCTUnwrap(result.records.first?.messageID)
        XCTAssertEqual(try repo.notice(messageID: messageID)?.key, "run.B.failed")
        XCTAssertEqual(try repo.notice(messageID: messageID)?.actions, card, "posting stores the labels the user saw")
        XCTAssertNil(try repo.get(key: "run.A.completed")?.actions)
        XCTAssertEqual(try repo.notices(messageID: messageID).count, 2)
    }

    func test_olderFlushNeverOverwritesANewerPreview() throws {
        // WHY (AGENTS.md latest-wins): a stale flush must not replace the inbox
        // preview written by a newer one.
        let (_, repo) = try make()
        try repo.ingest(fact("a"))
        try repo.ingest(fact("b"))
        try post(repo, ["b"], at: 200, preview: "newer")
        try post(repo, ["a"], at: 100, preview: "older")
        let inbox = try repo.inboxState()
        XCTAssertEqual(inbox.lastPreview, "newer")
        XCTAssertEqual(inbox.lastAt, t0.addingTimeInterval(200))
        XCTAssertEqual(inbox.unreadCount, 2, "both posts still count")
    }

    func test_viewedInboxPostsDoNotBumpUnread() throws {
        let (_, repo) = try make()
        try repo.ingest(fact("a"))
        try post(repo, ["a"], unread: false)
        XCTAssertEqual(try repo.inboxState().unreadCount, 0)
        XCTAssertEqual(try repo.updateInboxState { $0.unreadCount = 5; $0.conversationID = "C" }.unreadCount, 5)
        XCTAssertEqual(try repo.inboxState().conversationID, "C")
    }

    func test_bannerRepostListsOnlyRecentPostsWithoutABanner() throws {
        // WHY (§3.5): a crash between commit and banner must re-post that banner
        // (same identifier) at startup, and only that one.
        let (_, repo) = try make()
        for key in ["old", "recent", "bannered"] { try repo.ingest(fact(key)) }
        try post(repo, ["old"], at: 0)
        try post(repo, ["recent"], at: 900)
        try post(repo, ["bannered"], at: 900)
        try repo.markBanner(keys: ["bannered"], at: t0.addingTimeInterval(901))
        let now = t0.addingTimeInterval(1_000)
        XCTAssertEqual(try repo.rowsNeedingBannerRepost(now: now).map(\.key), ["recent"])
        XCTAssertEqual(try repo.get(key: "bannered")?.bannerAt, t0.addingTimeInterval(901))
    }

    func test_recentPostedFeedsTheDirectiveOldestFirst() throws {
        let (_, repo) = try make()
        for index in 0..<15 {
            try repo.ingest(fact("k\(index)", at: TimeInterval(index)))
            try post(repo, ["k\(index)"], at: TimeInterval(100 + index))
        }
        try repo.ingest(fact("pending"))
        let rows = try repo.recentPosted(since: t0.addingTimeInterval(102))
        XCTAssertEqual(rows.map(\.key), (3..<15).map { "k\($0)" }, "newest 12 after the cutoff, oldest first")
    }

    // MARK: Act

    func test_concurrentClaimsHaveExactlyOneWinner() throws {
        // WHY (§7.3): a Mac tap and an iPhone tap on the same card must execute
        // the approval once; every other claimer gets `already_resolved`.
        let (_, repo) = try make()
        try repo.ingest(fact("thread.T.attention.Q", .approval, actions: [.approve, .decline]))
        XCTAssertFalse(try repo.claim(key: "thread.T.attention.Q"), "a pending (unposted) row cannot be acted on")
        try post(repo, ["thread.T.attention.Q"])
        let wins = ManagedAtomicCounter()
        DispatchQueue.concurrentPerform(iterations: 24) { _ in
            if (try? repo.claim(key: "thread.T.attention.Q")) == true { wins.increment() }
        }
        XCTAssertEqual(wins.value, 1)
        XCTAssertEqual(try repo.get(key: "thread.T.attention.Q")?.state, .acting)
        XCTAssertFalse(try repo.claim(key: "missing"))
    }

    func test_resolveFinishesOnlyTheClaimedAct() throws {
        // WHY (§7.5): the row resolves only after the host result, and only for
        // the act that claimed it.
        let (_, repo) = try make()
        try repo.ingest(fact("k", .approval, actions: [.approve, .decline]))
        try post(repo, ["k"])
        XCTAssertNil(try repo.resolve(key: "k", resolution: .approved, at: t0), "not claimed yet")
        XCTAssertTrue(try repo.claim(key: "k"))
        let resolved = try XCTUnwrap(repo.resolve(key: "k", resolution: .approved, at: t0.addingTimeInterval(9)))
        XCTAssertEqual(resolved.state, .resolved)
        XCTAssertEqual(resolved.resolution, .approved)
        XCTAssertEqual(resolved.resolvedAt, t0.addingTimeInterval(9))
        XCTAssertFalse(try repo.claim(key: "k"), "a resolved card cannot be acted on again")
    }

    func test_replyHereArmsOneRowAtATime() throws {
        // WHY (§7 armed reply): only the latest "Reply here" may capture the next
        // message; an older arm goes back to an open card.
        let (_, repo) = try make()
        for key in ["a", "b"] {
            try repo.ingest(fact(key, .userInput, actions: [.replyHere, .openThread]))
            try post(repo, [key])
        }
        XCTAssertTrue(try repo.claim(key: "a"))
        XCTAssertTrue(try repo.setAwaitingReply(key: "a", at: t0))
        XCTAssertEqual(try repo.inboxState().armedReplyKey, "a")
        XCTAssertTrue(try repo.claim(key: "b"))
        XCTAssertTrue(try repo.setAwaitingReply(key: "b", at: t0.addingTimeInterval(1)))
        XCTAssertEqual(try repo.get(key: "a")?.state, .posted)
        XCTAssertEqual(try repo.get(key: "b")?.state, .awaitingReply)
        XCTAssertEqual(try repo.inboxState().armedReplyKey, "b")

        XCTAssertTrue(try repo.claim(key: "b"), "the armed reply claims the row to forward the text")
        XCTAssertNotNil(try repo.resolve(key: "b", resolution: .answered, at: t0.addingTimeInterval(2)))
        XCTAssertNil(try repo.inboxState().armedReplyKey, "resolving the armed row clears the arm")

        XCTAssertTrue(try repo.claim(key: "a"))
        XCTAssertTrue(try repo.setAwaitingReply(key: "a", at: t0))
        XCTAssertTrue(try repo.reopen(key: "a"), "another tap clears the arm")
        XCTAssertEqual(try repo.get(key: "a")?.state, .posted)
        XCTAssertNil(try repo.inboxState().armedReplyKey)
    }

    func test_sourceResolutionDropsPendingResolvesPostedAndLeavesActingAlone() throws {
        // WHY (§3, §5): a request answered elsewhere before the flush never
        // posts; after the post it rewrites to "handled elsewhere"; while the
        // host's own act runs, the resulting resolve event must not double-resolve.
        let (_, repo) = try make()
        for key in ["pending", "posted", "acting"] { try repo.ingest(fact(key, .approval, actions: [.approve, .decline])) }
        try post(repo, ["posted"])
        try post(repo, ["acting"])
        XCTAssertTrue(try repo.claim(key: "acting"))

        XCTAssertEqual(try repo.resolveFromSource(key: "pending", resolution: .elsewhere, at: t0), .dropped)
        XCTAssertEqual(try repo.get(key: "pending")?.state, .dropped)
        guard case let .resolved(record) = try repo.resolveFromSource(key: "posted", resolution: .elsewhere, at: t0) else {
            return XCTFail("posted row must resolve")
        }
        XCTAssertEqual(record.resolution, .elsewhere)
        XCTAssertEqual(record.messageID, TitioNoticeIDs.messageID(forKey: "posted").uuidString, "the caller rewrites this message")
        XCTAssertEqual(try repo.resolveFromSource(key: "acting", resolution: .elsewhere, at: t0), .unchanged)
        XCTAssertEqual(try repo.get(key: "acting")?.state, .acting)
        XCTAssertEqual(try repo.resolveFromSource(key: "missing", resolution: .elsewhere, at: t0), .unchanged)
        XCTAssertNil(try post(repo, ["pending"]), "a dropped row never posts")
    }

    func test_flapHoldDropOnlyAffectsPendingRows() throws {
        let (_, repo) = try make()
        try repo.ingest(fact("pet.ssh-disconnect.S", .sshDisconnected))
        XCTAssertTrue(try repo.drop(key: "pet.ssh-disconnect.S", at: t0))
        XCTAssertEqual(try repo.get(key: "pet.ssh-disconnect.S")?.resolution, .flap)
        XCTAssertFalse(try repo.drop(key: "pet.ssh-disconnect.S", at: t0))
    }

    // MARK: Retention

    func test_pruneRemovesOnlyFinishedRowsOlderThanThirtyDays() throws {
        // WHY (§3.7): the ledger must not grow forever, but open notices and
        // recent history (the act lookup, the directive) must stay.
        let (db, repo) = try make()
        let now = t0.addingTimeInterval(60 * 86_400)
        for key in ["oldResolved", "oldDropped", "recentResolved", "oldOpen"] { try repo.ingest(fact(key, .approval, actions: [.approve, .decline])) }
        try post(repo, ["oldResolved"])
        try post(repo, ["recentResolved"])
        try post(repo, ["oldOpen"])
        XCTAssertTrue(try repo.claim(key: "oldResolved"))
        try repo.resolve(key: "oldResolved", resolution: .approved, at: now.addingTimeInterval(-31 * 86_400))
        try repo.drop(key: "oldDropped", at: now.addingTimeInterval(-40 * 86_400))
        XCTAssertTrue(try repo.claim(key: "recentResolved"))
        try repo.resolve(key: "recentResolved", resolution: .approved, at: now.addingTimeInterval(-29 * 86_400))

        XCTAssertEqual(try repo.prune(endedBefore: now.addingTimeInterval(-TitioNoticeTiming.retention)), 2)
        XCTAssertNil(try repo.get(key: "oldResolved"))
        XCTAssertNil(try repo.get(key: "oldDropped"))
        XCTAssertNotNil(try repo.get(key: "recentResolved"))
        XCTAssertEqual(try repo.get(key: "oldOpen")?.state, .posted, "open notices are never pruned, however old")
        XCTAssertEqual(try rowCount(db), 2)
    }

    // MARK: Schema

    func test_step93AppliesOnAVersion92Database() throws {
        // WHY: every user upgrades from v92; the step must add both tables
        // without touching existing data, and re-running migrate is a no-op.
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version <= 92 })
        try db.execute("INSERT INTO activity_notification_state(item_id, viewed_at) VALUES ('run:keep', '2026-10-15T00:00:00Z');")
        XCTAssertThrowsError(try db.execute("SELECT 1 FROM titio_notices;"), "v92 has no ledger yet")

        try Schema.migrate(db)
        XCTAssertEqual(Schema.titioNoticesSchemaVersion, 93)
        let version = try db.performSync { database -> Int in
            let statement = try database.prepare("SELECT MAX(version) FROM schema_meta;")
            defer { statement.reset() }
            _ = try statement.step()
            return Int(statement.columnInt64(0))
        }
        XCTAssertEqual(version, 93)
        XCTAssertEqual(try rowCount(db, "activity_notification_state"), 1, "existing rows survive")
        XCTAssertEqual(try rowCount(db), 0)
        XCTAssertEqual(try rowCount(db, "titio_inbox_state"), 0)
        XCTAssertThrowsError(try db.execute("INSERT INTO titio_inbox_state(id) VALUES (2);"), "the inbox state is a singleton")

        let repo = TitioNoticeRepository(db: db)
        try repo.ingest(fact("run.A.completed"))
        try post(repo, ["run.A.completed"])
        try Schema.migrate(db)
        XCTAssertEqual(try repo.get(key: "run.A.completed")?.state, .posted, "re-migrate keeps ledger rows")
    }

    // MARK: Open-notice reads (stage 2)

    func test_openDecisionCountAndOpenKeysFollowTheRowState() throws {
        // WHY: the inbox stays "needs you" exactly while a decision card is
        // open, and the bot-attention projector resolves only open notices.
        let (_, repo) = try make()
        try repo.ingest(fact("thread.T.attention.Q1", .approval, actions: [.approve, .decline]))
        try repo.ingest(fact("bot.attention.A1", .botBlocked))
        try repo.ingest(fact("bot.attention.A2", .botBlocked))
        XCTAssertEqual(try repo.openDecisionCount(), 0, "a pending decision is not on screen yet")
        try post(repo, ["thread.T.attention.Q1"])
        XCTAssertEqual(try repo.openDecisionCount(), 1)
        XCTAssertTrue(try repo.claim(key: "thread.T.attention.Q1"))
        XCTAssertEqual(try repo.openDecisionCount(), 1, "acting is still open until the host result")
        _ = try repo.resolve(key: "thread.T.attention.Q1", resolution: .approved, at: t0)
        XCTAssertEqual(try repo.openDecisionCount(), 0)

        _ = try repo.drop(key: "bot.attention.A2", resolution: .elsewhere, at: t0)
        XCTAssertEqual(try repo.openKeys(prefix: "bot.attention."), ["bot.attention.A1"])
        XCTAssertEqual(try repo.openKeys(prefix: "thread."), [], "resolved rows are not open")
    }

    func test_openCardsListOnlyTappableCardsInPostOrder() throws {
        // WHY: the old-iOS text intercept may only match a card the user can
        // still tap; a claimed, resolved or card-less row must never match.
        let (_, repo) = try make()
        let card = [TitioNoticeCardOption(label: "Approve", action: .approve)]
        try repo.ingest(fact("thread.T.attention.Q1", .approval, actions: [.approve]))
        try repo.ingest(fact("thread.T.attention.Q2", .approval, actions: [.approve]))
        try repo.ingest(fact("thread.T.attention.Q3", .approval, actions: [.approve]))
        try repo.ingest(fact("run.R.completed"))
        try post(repo, ["thread.T.attention.Q1"], at: 1, card: card)
        try post(repo, ["thread.T.attention.Q2"], at: 2, card: card)
        try post(repo, ["thread.T.attention.Q3"], at: 3, card: card)
        try post(repo, ["run.R.completed"], at: 4)
        XCTAssertTrue(try repo.claim(key: "thread.T.attention.Q2"))
        XCTAssertTrue(try repo.claim(key: "thread.T.attention.Q3"))
        XCTAssertTrue(try repo.setAwaitingReply(key: "thread.T.attention.Q3", at: t0))
        XCTAssertEqual(try repo.openCards().map(\.key), ["thread.T.attention.Q1", "thread.T.attention.Q3"],
                       "acting rows and rows without a card are excluded; an armed card stays tappable")
    }
}

private final class ManagedAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
