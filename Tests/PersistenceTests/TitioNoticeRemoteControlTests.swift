import XCTest
import CoreModel
@testable import Persistence

/// The paired-device side of Titio's notice inbox (hub spec §7, §8): card
/// taps travel as `bot.notice.act`, opening the inbox as `bot.notice.read`,
/// and the roster learns the inbox from `bot.list` / `bot.conversation.list`.
/// The authority only shapes receipts; the host hub decides the outcome.
final class TitioNoticeRemoteControlTests: XCTestCase {
    private var db: SQLiteDB!
    private var store: BotStore!
    private var authority: BotRemoteControlAuthority!
    private var supportDir: URL!
    private var titio: BotDefinition!

    override func setUpWithError() throws {
        db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        store = BotStore(db: db)
        supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-titio-remote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        authority = BotRemoteControlAuthority(
            db: db,
            store: store,
            settings: SettingsStore(db: db),
            appSupportDirectory: supportDir
        )
        titio = try store.create(
            name: TitioIdentity.name,
            title: TitioIdentity.title,
            description: TitioIdentity.description,
            handle: TitioIdentity.handle,
            soul: TitioIdentity.soul
        )
    }

    override func tearDown() {
        authority = nil
        store = nil
        db = nil
        titio = nil
        if let supportDir { try? FileManager.default.removeItem(at: supportDir) }
        supportDir = nil
    }

    private var titioID: String { titio.id.value.uuidString.lowercased() }

    func test_noticeActReportsTheHubOutcomeOnceAndReplaysItsReceipt() throws {
        // WHY: an iOS retry with the same client_request_id must never claim a
        // second time; the outcome (and a navigation route) reaches the phone.
        let messageID = UUID().uuidString.lowercased()
        var calls: [(String, Int)] = []
        authority.onNoticeAct = { botID, message, index in
            XCTAssertEqual(botID, self.titio.id)
            calls.append((message, index))
            return ["outcome": "navigate", "route": ["threadId": "T1", "workspaceId": "W1"]]
        }
        let params: [String: Any] = [
            "client_request_id": "tap-1", "bot_id": titioID, "message_id": messageID, "option_index": 3,
        ]
        let first = try authority.dispatch(method: "bot.notice.act", params: params)
        let replay = try authority.dispatch(method: "bot.notice.act", params: params)

        XCTAssertEqual(calls.count, 1, "a replayed request answers from its receipt")
        XCTAssertEqual(calls.first?.0, messageID)
        XCTAssertEqual(calls.first?.1, 3)
        XCTAssertEqual(first["status"] as? String, "completed")
        XCTAssertEqual(first["outcome"] as? String, "navigate")
        XCTAssertEqual(first["route"] as? [String: String], ["threadId": "T1", "workspaceId": "W1"])
        let readback = try XCTUnwrap(first["readback"] as? [String: Any])
        XCTAssertEqual(readback["outcome"] as? String, "navigate")
        XCTAssertEqual(readback["navigation"] as? [String: String], ["threadId": "T1", "workspaceId": "W1"])
        XCTAssertEqual(readback["route"] as? String, "bot", "readback keeps its route convention")
        XCTAssertEqual(replay["receipt_id"] as? String, first["receipt_id"] as? String)
    }

    func test_noticeActOnlyAcceptsTitioAndAValidMessageAndIndex() throws {
        // WHY: notice cards exist only in Titio's inbox; anything else is a
        // forged or malformed tap and must not reach the hub.
        var calls = 0
        authority.onNoticeAct = { _, _, _ in calls += 1; return ["outcome": "accepted"] }
        let other = try store.create(name: "Dev", title: "", description: "")
        XCTAssertThrowsError(try authority.dispatch(method: "bot.notice.act", params: [
            "client_request_id": "other", "bot_id": other.id.value.uuidString.lowercased(),
            "message_id": UUID().uuidString, "option_index": 0,
        ]))
        XCTAssertThrowsError(try authority.dispatch(method: "bot.notice.act", params: [
            "client_request_id": "bad-message", "bot_id": titioID, "message_id": "not-a-uuid", "option_index": 0,
        ]))
        XCTAssertThrowsError(try authority.dispatch(method: "bot.notice.act", params: [
            "client_request_id": "bad-index", "bot_id": titioID, "message_id": UUID().uuidString, "option_index": -1,
        ]))
        XCTAssertEqual(calls, 0)
    }

    func test_noticeReadClearsTheInboxThroughTheHub() throws {
        // WHY: opening the inbox on iOS clears its unread count on the host,
        // the only authority for it.
        let conversation = UUID()
        var reads: [BotConversationID] = []
        authority.onNoticeRead = { _, id in reads.append(id); return ["unread_count": 0] }
        let reply = try authority.dispatch(method: "bot.notice.read", params: [
            "client_request_id": "read-1", "bot_id": titioID, "conversation_id": conversation.uuidString,
        ])
        XCTAssertEqual(reads, [BotConversationID(conversation)])
        let readback = try XCTUnwrap(reply["readback"] as? [String: Any])
        XCTAssertEqual(readback["unread_count"] as? Int, 0)
        XCTAssertEqual(readback["conversation_id"] as? String, conversation.uuidString.lowercased())
    }

    func test_botListCarriesTitioInboxAndTheConversationListMarksTheInbox() throws {
        // WHY: the iOS roster shows Titio's preview, time and unread badge from
        // `titio_inbox` and pins the inbox first by `kind`; other Bots and
        // other conversations stay unchanged.
        let inbox = BotConversation(botID: titio.id, title: "Notifications")
        let chat = BotConversation(botID: titio.id, title: "Chat")
        try store.upsertConversation(inbox)
        try store.upsertConversation(chat)
        let other = try store.create(name: "Dev", title: "", description: "")
        authority.onTitioInbox = {
            [
                "conversation_id": inbox.id.value.uuidString.lowercased(),
                "thread_id": UUID().uuidString.lowercased(),
                "unread_count": 2,
                "open_decisions": 1,
                "last_preview": "I need you to decide something",
                "last_at": 1_792_094_460.0,
            ]
        }

        let listed = try authority.dispatch(method: "bot.list", params: [:])
        let bots = try XCTUnwrap(listed["bots"] as? [[String: Any]])
        let titioRow = try XCTUnwrap(bots.first { $0["id"] as? String == titioID })
        let wire = try XCTUnwrap(titioRow["titio_inbox"] as? [String: Any])
        XCTAssertEqual(wire["unread_count"] as? Int, 2)
        XCTAssertEqual(wire["open_decisions"] as? Int, 1)
        let otherRow = try XCTUnwrap(bots.first { $0["id"] as? String == other.id.value.uuidString.lowercased() })
        XCTAssertNil(otherRow["titio_inbox"], "only Titio carries the inbox")

        let conversations = try authority.dispatch(method: "bot.conversation.list", params: ["bot_id": titioID])
        let rows = try XCTUnwrap(conversations["conversations"] as? [[String: Any]])
        XCTAssertEqual(rows.first { $0["id"] as? String == inbox.id.value.uuidString.lowercased() }?["kind"] as? String, "titio_inbox")
        XCTAssertNil(rows.first { $0["id"] as? String == chat.id.value.uuidString.lowercased() }?["kind"])
    }

    func test_aSendTheHostConsumedForANoticeRegistersNoRun() throws {
        // WHY: an armed "Reply here" (or an old build's option text) is taken
        // by the host; registering a live run would leave Titio "working"
        // forever on the phone.
        let inbox = BotConversation(botID: titio.id, title: "Notifications")
        try store.upsertConversation(inbox)
        let conversationID = inbox.id.value.uuidString.lowercased()
        authority.onSend = { [titioID] _, _, _, _, _, _ in
            [
                "bot_id": titioID,
                "conversation_id": conversationID,
                "enqueued": false,
                "queued_follow_up": false,
                "host_consumed": true,
                "titio_notice": "reply",
            ]
        }
        let reply = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "send-1", "host_id": "host-1", "bot_id": titioID,
            "conversation_id": conversationID, "text": "use staging",
        ])
        XCTAssertEqual(reply["status"] as? String, "completed")
        let readback = try XCTUnwrap(reply["readback"] as? [String: Any])
        XCTAssertEqual(readback["host_consumed"] as? Bool, true)
        XCTAssertNil(readback["run_id"], "no run was started")
        let attention = try authority.dispatch(method: "bot.attention.list", params: [:])
        let items = (attention["items"] as? [[String: Any]]) ?? []
        XCTAssertFalse(items.contains { $0["bot_id"] as? String == titioID && $0["state"] as? String == "working" })
    }
}
