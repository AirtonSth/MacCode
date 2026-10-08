import XCTest
import CoreModel
@testable import Persistence

/// After a Mac relaunch the attention item of a `bot.send` run is restored as
/// `working`, but the in-memory live run that `settleRuntime` needs is gone.
/// `bot.attention.list` must close it from the run's durable status, or the
/// phone reads Working forever and can never match the run as finished.
final class BotAttentionRelaunchSettleTests: XCTestCase {
    private var db: SQLiteDB!
    private var store: BotStore!
    private var settings: SettingsStore!
    private var authority: BotRemoteControlAuthority!
    private var supportDir: URL!

    override func setUpWithError() throws {
        db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        store = BotStore(db: db)
        settings = SettingsStore(db: db)
        supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-bot-attention-relaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        authority = makeAuthority()
    }

    override func tearDown() {
        authority = nil
        settings = nil
        store = nil
        db = nil
        if let supportDir {
            try? FileManager.default.removeItem(at: supportDir)
        }
        supportDir = nil
    }

    private func makeAuthority() -> BotRemoteControlAuthority {
        BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: settings,
            appSupportDirectory: supportDir
        )
    }

    private struct StartedSend {
        let botID: String
        let runID: AgentRunID
        let threadID: AgentThreadID
    }

    /// Admits one `bot.send` bound to an Agent run through `onSend`. The run
    /// row is written only when `rowStatus` is given: in production it is
    /// created after `bot.send` returns.
    private func startSend(prefix: String, rowStatus: AgentRunStatus?) throws -> StartedSend {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "\(prefix)-create",
            "name": prefix,
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let conversation = try authority.dispatch(method: "bot.conversation.create", params: [
            "client_request_id": "\(prefix)-conversation",
            "bot_id": botID,
            "title": prefix,
        ])
        let conversationID = try XCTUnwrap(
            (conversation["readback"] as? [String: Any])?["conversation_id"] as? String
        )
        let runID = AgentRunID()
        let threadID = AgentThreadID()
        try AgentThreadRepository(db: db).upsert(
            AgentThread(id: threadID, title: prefix, provider: .codex, model: "m")
        )
        if let rowStatus {
            try writeRun(runID, threadID: threadID, status: rowStatus)
        }
        authority.onSend = { _, _, _, _, _ in
            [
                "bot_id": botID,
                "conversation_id": conversationID,
                "thread_id": threadID.value.uuidString.lowercased(),
                "run_id": runID.value.uuidString.lowercased(),
                "enqueued": true,
                "queued_follow_up": false,
            ]
        }
        _ = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "\(prefix)-send",
            "host_id": "relaunch-host",
            "bot_id": botID,
            "conversation_id": conversationID,
            "text": "\(prefix) work",
        ])
        return StartedSend(botID: botID, runID: runID, threadID: threadID)
    }

    private func writeRun(
        _ runID: AgentRunID,
        threadID: AgentThreadID,
        status: AgentRunStatus,
        finishedAt: Date? = nil
    ) throws {
        try AgentRunRepository(db: db).upsert(AgentRun(
            id: runID,
            threadId: threadID,
            provider: .codex,
            model: "m",
            status: status,
            finishedAt: finishedAt
        ))
    }

    /// A Bot with one conversation and no `bot.send`: this process tracks no
    /// live run for it.
    private func createBotConversation(prefix: String) throws -> (botID: String, conversationID: String) {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "\(prefix)-create",
            "name": prefix,
        ])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let conversation = try authority.dispatch(method: "bot.conversation.create", params: [
            "client_request_id": "\(prefix)-conversation",
            "bot_id": botID,
            "title": prefix,
        ])
        return (
            botID,
            try XCTUnwrap((conversation["readback"] as? [String: Any])?["conversation_id"] as? String)
        )
    }

    private func attentionItem(
        botID: String,
        from authority: BotRemoteControlAuthority
    ) throws -> [String: Any] {
        let listed = try authority.dispatch(method: "bot.attention.list", params: [:])
        return try XCTUnwrap((listed["items"] as? [[String: Any]])?.first {
            $0["bot_id"] as? String == botID
        })
    }

    /// WHY: the relaunch interrupted the run, so no terminal event will ever
    /// arrive. The item must end as failed, keep the identity the phone matches
    /// on (id, run_id), and stay ended on the next relaunch.
    func test_attentionList_afterRelaunch_finishesTheItemOfAnInterruptedRun() throws {
        let send = try startSend(prefix: "relaunch-interrupted", rowStatus: .running)
        let working = try attentionItem(botID: send.botID, from: authority)
        XCTAssertEqual(working["state"] as? String, "working")
        let itemID = try XCTUnwrap(working["id"] as? String)
        let runID = try XCTUnwrap(working["run_id"] as? String)

        XCTAssertEqual(try AgentRunRepository(db: db).reconcileRunningOnLaunch(), 1)
        let relaunched = makeAuthority()

        let finished = try attentionItem(botID: send.botID, from: relaunched)
        XCTAssertEqual(finished["state"] as? String, "finished")
        XCTAssertEqual(finished["outcome"] as? String, "failed")
        XCTAssertNotNil(finished["finished_at"] as? Double)
        XCTAssertEqual(finished["id"] as? String, itemID)
        XCTAssertEqual(finished["run_id"] as? String, runID)

        let secondRelaunch = makeAuthority()
        let persisted = try attentionItem(botID: send.botID, from: secondRelaunch)
        XCTAssertEqual(persisted["state"] as? String, "finished")
        XCTAssertEqual(persisted["outcome"] as? String, "failed")
        XCTAssertEqual(persisted["id"] as? String, itemID)
        XCTAssertEqual(persisted["finished_at"] as? Double, finished["finished_at"] as? Double)
    }

    /// WHY: the outcome comes from the durable run row, not from a blanket
    /// "a relaunch means failed". A run that completed just before the relaunch
    /// must still read as completed.
    func test_attentionList_afterRelaunch_keepsCompletedOutcome() throws {
        let send = try startSend(prefix: "relaunch-completed", rowStatus: .running)
        let finishedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try writeRun(send.runID, threadID: send.threadID, status: .completed, finishedAt: finishedAt)

        XCTAssertEqual(try AgentRunRepository(db: db).reconcileRunningOnLaunch(), 0)
        let relaunched = makeAuthority()

        let finished = try attentionItem(botID: send.botID, from: relaunched)
        XCTAssertEqual(finished["state"] as? String, "finished")
        XCTAssertEqual(finished["outcome"] as? String, "completed")
        XCTAssertEqual(finished["finished_at"] as? Double, finishedAt.timeIntervalSince1970)
    }

    /// WHY: each of these runs has no durable proof of an end for this
    /// process to act on. Closing any of them would show a live run as ended,
    /// or take the finished-versus-question decision away from `settleRuntime`.
    func test_attentionList_doesNotCloseTrackedOrStillLiveRuns() throws {
        // (a) Still tracked by this process: the terminal event owns the settle.
        let tracked = try startSend(prefix: "relaunch-tracked", rowStatus: .running)
        try writeRun(tracked.runID, threadID: tracked.threadID, status: .completed, finishedAt: Date())
        XCTAssertEqual(try attentionItem(botID: tracked.botID, from: authority)["state"] as? String, "working")
        XCTAssertTrue(authority.settleRuntime(
            botID: tracked.botID,
            runID: tracked.runID.value.uuidString,
            failed: false
        ))

        // (b) Row still running after the relaunch (thread preserved for the
        // scheduled-task LaunchAgent). (c) No row: the provider start may still
        // be pending.
        let stillRunning = try startSend(prefix: "relaunch-running", rowStatus: .running)
        let noRow = try startSend(prefix: "relaunch-no-row", rowStatus: nil)
        let relaunched = makeAuthority()

        XCTAssertEqual(
            try attentionItem(botID: stillRunning.botID, from: relaunched)["state"] as? String,
            "working"
        )
        XCTAssertEqual(
            try attentionItem(botID: noRow.botID, from: relaunched)["state"] as? String,
            "working"
        )
    }

    /// WHY: a delegated handoff item belongs to the handoff snapshot, which
    /// rebuilds it on every list. Its peer run is a real Agent run that the
    /// relaunch interrupts while the handoff still says Working. Closing the
    /// item from that row would tell the phone Finished against the handoff's
    /// own state, and rewrite the item on every poll.
    func test_attentionList_afterRelaunch_leavesDelegatedHandoffItemToItsSnapshot() throws {
        let owner = try createBotConversation(prefix: "handoff-owner")
        let peer = try createBotConversation(prefix: "handoff-peer")
        let peerThreadID = AgentThreadID()
        try AgentThreadRepository(db: db).upsert(
            AgentThread(id: peerThreadID, title: "handoff-peer", provider: .codex, model: "m")
        )
        let peerConversationID = BotConversationID(try XCTUnwrap(UUID(uuidString: peer.conversationID)))
        var peerConversation = try XCTUnwrap(try store.conversation(id: peerConversationID))
        peerConversation.linkedAgentThreadID = peerThreadID
        try store.upsertConversation(peerConversation)
        let peerRunID = AgentRunID()
        try writeRun(peerRunID, threadID: peerThreadID, status: .running)
        let activityID = UUID().uuidString.lowercased()
        let row: [String: Any] = [
            "id": activityID,
            "lifecycle_receipt_id": activityID,
            "bot_id": peer.botID,
            "conversation_id": peer.conversationID,
            "thread_id": peerThreadID.value.uuidString.lowercased(),
            "run_id": peerRunID.value.uuidString.lowercased(),
            "owner_bot_id": owner.botID,
            "owner_conversation_id": owner.conversationID,
            "state": "working",
            "finished_at": NSNull(),
            "ownership": "delegated",
            "primary": false,
            "delegated": true,
            "source": "bot_peer_handoff",
            "peer_phase": "peer_running",
        ]
        authority.onDelegatedAttentionSnapshot = { [row] }
        let adopted = try attentionItem(botID: peer.botID, from: authority)
        XCTAssertEqual(adopted["source"] as? String, "bot_peer_handoff")
        XCTAssertEqual(adopted["state"] as? String, "working")

        XCTAssertEqual(try AgentRunRepository(db: db).reconcileRunningOnLaunch(), 1)
        let relaunched = makeAuthority()

        // Restored from the sidecar, before the snapshot provider is wired.
        let restored = try attentionItem(botID: peer.botID, from: relaunched)
        XCTAssertEqual(restored["id"] as? String, activityID)
        XCTAssertEqual(restored["state"] as? String, "working")
        XCTAssertNil(restored["outcome"])

        // Rebuilt from the snapshot: the sweep runs right after it.
        relaunched.onDelegatedAttentionSnapshot = { [row] }
        for _ in 0..<2 {
            let listed = try attentionItem(botID: peer.botID, from: relaunched)
            XCTAssertEqual(listed["id"] as? String, activityID)
            XCTAssertEqual(listed["state"] as? String, "working")
            XCTAssertNil(listed["outcome"])
            XCTAssertTrue(listed["finished_at"] is NSNull)
        }
    }
}
