import XCTest
import CoreModel
@testable import Persistence

/// Paired `bot.send` routing parity (P1): a send with no routing receipt must
/// run the conversation's own desk route (never a hardcoded legacy provider),
/// and a conversation-scoped `bot.routing.set` pins the exact route, Worker
/// included, to that conversation only.
final class BotSendRoutingParityTests: XCTestCase {
    private var db: SQLiteDB!
    private var store: BotStore!
    private var authority: BotRemoteControlAuthority!
    private var supportDir: URL!

    override func setUpWithError() throws {
        db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        store = BotStore(db: db)
        supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-bot-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        authority = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: SettingsStore(db: db),
            appSupportDirectory: supportDir
        )
    }

    override func tearDown() {
        authority = nil
        store = nil
        db = nil
        if let supportDir { try? FileManager.default.removeItem(at: supportDir) }
        supportDir = nil
    }

    private func makeBot(_ name: String) throws -> String {
        let created = try authority.dispatch(method: "bot.create", params: [
            "client_request_id": "create-\(name)", "name": name,
        ])
        return try XCTUnwrap(created["bot_id"] as? String)
    }

    private func makeConversation(botID: String, _ title: String) throws -> String {
        let created = try authority.dispatch(method: "bot.conversation.create", params: [
            "client_request_id": "conversation-\(title)", "bot_id": botID, "title": title,
        ])
        return try XCTUnwrap((created["readback"] as? [String: Any])?["conversation_id"] as? String)
    }

    private func admittedSend(botID: String, conversationID: String) -> [String: Any] {
        [
            "bot_id": botID,
            "conversation_id": conversationID,
            "thread_id": UUID().uuidString.lowercased(),
            "run_id": UUID().uuidString.lowercased(),
            "enqueued": true,
            "queued_follow_up": false,
            "effective_routing": ["provider": "distill", "model": "main-b", "worker_model": "worker-a"],
        ]
    }

    func test_sendWithoutReceipt_letsTheHostRunTheConversationRoute_neverAHardcodedGrok() throws {
        // WHY: iOS sends without a receipt used to run a hardcoded grok/auto/""
        // route while the Mac desk showed another model. The host must decide
        // (conversation route or resolved Distill default) and report it.
        let botID = try makeBot("Piper")
        let conversationID = try makeConversation(botID: botID, "Plan")
        var receivedRouting: [String: Any]?? = .none
        authority.onSend = { _, _, _, _, routing in
            receivedRouting = .some(routing)
            return self.admittedSend(botID: botID, conversationID: conversationID)
        }

        let sent = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "receiptless", "host_id": "host", "bot_id": botID,
            "conversation_id": conversationID, "text": "go",
        ])

        let passed = try XCTUnwrap(receivedRouting, "the host send hook must run")
        XCTAssertNil(passed, "no receipt means no caller route: the host's conversation route applies")
        let readback = try XCTUnwrap(sent["readback"] as? [String: Any])
        let effective = try XCTUnwrap(readback["effective_routing"] as? [String: Any])
        XCTAssertEqual(effective["provider"] as? String, "distill")
        XCTAssertEqual(effective["model"] as? String, "main-b",
                       "the receipt reports the route the host actually ran")
        let run = try XCTUnwrap(readback["run"] as? [String: Any])
        XCTAssertNotEqual((run["routing"] as? [String: Any])?["provider"] as? String, "grok")
    }

    func test_conversationScopedRoutingSet_adoptsTheRoute_andPinsWorkerAndConversation() throws {
        // WHY: a route chosen on iOS for one conversation must become that
        // conversation's desk route on the Mac (single source of truth) and the
        // receipt must not be replayable on another conversation or with a
        // different Worker than the one admitted.
        let botID = try makeBot("Piper")
        let planID = try makeConversation(botID: botID, "Plan")
        let otherID = try makeConversation(botID: botID, "Other")
        var adopted: (BotConversationID, [String: Any])?
        authority.onConversationRoutingSet = { _, conversationID, values in
            adopted = (conversationID, values)
            var resolved = values
            resolved["model"] = "main-a"
            return resolved
        }
        let routeParams: [String: Any] = [
            "client_request_id": "route", "bot_id": botID, "host_id": "host",
            "conversation_id": planID,
            "provider": "distill", "provider_instance_id": "distill", "model": "",
            "routing_mode": "manual", "permission_mode": "supervised",
            "reasoning_effort": "medium", "service_tier": "auto",
            "worker_model": "worker-a", "worker_effort": "high", "distill_main_effort": "auto",
        ]
        let routed = try authority.dispatch(method: "bot.routing.set", params: routeParams)
        let receiptID = try XCTUnwrap(routed["receipt_id"] as? String)
        let readback = try XCTUnwrap(routed["readback"] as? [String: Any])
        XCTAssertEqual(adopted?.0.value.uuidString.lowercased(), planID)
        XCTAssertEqual(adopted?.1["worker_model"] as? String, "worker-a")
        XCTAssertEqual(readback["conversation_id"] as? String, planID)
        XCTAssertEqual((readback["effective"] as? [String: Any])?["model"] as? String, "main-a",
                       "the receipt shows the host-resolved route, not the empty request model")
        XCTAssertEqual(readback["model"] as? String, "main-a",
                       "the device echoes the resolved model, so what runs equals its receipt")
        XCTAssertEqual((readback["effective"] as? [String: Any])?["routing_receipt_id"] as? String, receiptID,
                       "effective keeps the receipt keys with conversation_id too")
        XCTAssertEqual((readback["effective"] as? [String: Any])?["host_id"] as? String, "host")

        var send: [String: Any] = routeParams
        send["model"] = readback["model"]
        send["client_request_id"] = "send"
        send["routing_receipt_id"] = receiptID
        send["text"] = "go"
        send["run_as_user"] = readback["run_as_user"]
        var otherSend = send
        otherSend["client_request_id"] = "send-other"
        otherSend["conversation_id"] = otherID
        XCTAssertThrowsError(try authority.dispatch(method: "bot.send", params: otherSend)) {
            XCTAssertEqual($0 as? BotRemoteControlAuthority.Error, .crossTarget,
                           "a conversation-scoped receipt cannot route another conversation")
        }
        var wrongWorker = send
        wrongWorker["client_request_id"] = "send-wrong-worker"
        wrongWorker["worker_model"] = "worker-b"
        XCTAssertThrowsError(try authority.dispatch(method: "bot.send", params: wrongWorker)) {
            XCTAssertEqual($0 as? BotRemoteControlAuthority.Error, .crossTarget,
                           "the Worker is part of the admitted route")
        }
        var missingWorker = send
        missingWorker["client_request_id"] = "send-missing-worker"
        missingWorker.removeValue(forKey: "worker_model")
        XCTAssertThrowsError(try authority.dispatch(method: "bot.send", params: missingWorker)) {
            XCTAssertEqual($0 as? BotRemoteControlAuthority.Error, .crossTarget)
        }

        var sentRouting: [String: Any]?
        authority.onSend = { _, _, _, _, routing in
            sentRouting = routing
            return self.admittedSend(botID: botID, conversationID: planID)
        }
        _ = try authority.dispatch(method: "bot.send", params: send)
        XCTAssertEqual(sentRouting?["worker_model"] as? String, "worker-a")
        XCTAssertEqual(sentRouting?["worker_effort"] as? String, "high")
        XCTAssertEqual(sentRouting?["routing_receipt_id"] as? String, receiptID)
    }

    func test_routingSetRejectsForeignGroupMissingConversationsAndBadEfforts() throws {
        // WHY: a route must only land on a desk conversation of the same bot;
        // group member conversations are driven by the group orchestrator.
        let piper = try makeBot("Piper")
        let ruth = try makeBot("Ruth")
        let ruthConversation = try makeConversation(botID: ruth, "Ruth's")
        let base: [String: Any] = ["client_request_id": "r", "bot_id": piper, "host_id": "host"]
        var foreign = base
        foreign["conversation_id"] = ruthConversation
        XCTAssertThrowsError(try authority.dispatch(method: "bot.routing.set", params: foreign)) {
            XCTAssertEqual($0 as? BotRemoteControlAuthority.Error, .crossTarget)
        }
        var missing = base
        missing["client_request_id"] = "r-missing"
        missing["conversation_id"] = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try authority.dispatch(method: "bot.routing.set", params: missing)) {
            XCTAssertEqual($0 as? BotRemoteControlAuthority.Error, .conversationGone)
        }
        var badEffort = base
        badEffort["client_request_id"] = "r-effort"
        badEffort["worker_effort"] = "ludicrous"
        XCTAssertThrowsError(try authority.dispatch(method: "bot.routing.set", params: badEffort)) {
            XCTAssertEqual($0 as? BotRemoteControlAuthority.Error, .invalidParams)
        }
    }

    func test_conversationListReportsEachConversationsNextSendRoute() throws {
        // WHY: iOS shows the Main/Worker pill of an empty conversation; it must
        // read the exact route the next send runs from the host.
        let botID = try makeBot("Piper")
        let conversationID = try makeConversation(botID: botID, "Plan")
        authority.onConversationRouting = { conversation in
            ["provider": "distill", "model": "main-\(conversation.id.value.uuidString.prefix(4).lowercased())"]
        }
        let listed = try authority.dispatch(method: "bot.conversation.list", params: ["bot_id": botID])
        let row = try XCTUnwrap((listed["conversations"] as? [[String: Any]])?.first)
        XCTAssertEqual((row["desk_routing"] as? [String: Any])?["model"] as? String,
                       "main-\(conversationID.prefix(4))")
    }

    func test_deskRoutingRowsLiveAndDieWithTheirConversation() throws {
        // WHY: the per-conversation route replaces a UserDefaults map that kept
        // routes of deleted conversations forever; the DB row must cascade.
        let botID = try makeBot("Piper")
        let raw = try makeConversation(botID: botID, "Plan")
        let conversationID = BotConversationID(try XCTUnwrap(UUID(uuidString: raw)))
        XCTAssertTrue(try store.setDeskRoutingJSON(#"{"model":"a"}"#, conversationID: conversationID))
        XCTAssertTrue(try store.setDeskRoutingJSON(#"{"model":"b"}"#, conversationID: conversationID))
        XCTAssertEqual(try store.deskRoutingJSON(conversationID: conversationID), #"{"model":"b"}"#)
        XCTAssertFalse(try store.setDeskRoutingJSON("{}", conversationID: BotConversationID()),
                       "no orphan row for a conversation that does not exist")

        try store.deleteConversations(botID: BotID(try XCTUnwrap(UUID(uuidString: botID))))

        XCTAssertNil(try store.deskRoutingJSON(conversationID: conversationID))
        XCTAssertTrue(try store.listDeskRoutingJSON().isEmpty)
    }

    func test_migrationIsIdempotentAndHealsASkippedStep() throws {
        // WHY: a sibling branch may record v89 first; the table must still exist.
        try db.execute("DROP TABLE bot_conversation_routing;")
        try Schema.migrate(db)
        try Schema.migrate(db)
        XCTAssertTrue(try store.listDeskRoutingJSON().isEmpty)
        XCTAssertEqual(Schema.currentVersion, 90)
    }
}
