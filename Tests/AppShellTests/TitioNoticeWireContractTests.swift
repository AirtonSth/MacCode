import XCTest
import CoreModel
import RemoteCodeTreaty
@testable import AppShell
@testable import Persistence

/// The exact Mac wire shapes the paired iOS app decodes for Titio's inbox:
/// each test feeds what the Mac really emits to the decoder or field reader
/// the phone uses, so the two sides cannot drift apart with green tests.
final class TitioNoticeWireContractTests: XCTestCase {
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
            .appendingPathComponent("rc-titio-wire-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        authority = BotRemoteControlAuthority(db: db, store: store, settings: SettingsStore(db: db), appSupportDirectory: supportDir)
        titio = try store.create(name: TitioIdentity.name, title: TitioIdentity.title, description: TitioIdentity.description,
                                 handle: TitioIdentity.handle, soul: TitioIdentity.soul)
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

    private func decodeBotSend(_ reply: [String: Any]) throws -> BotSend.Result {
        let data = try JSONSerialization.data(withJSONObject: reply)
        return try JSONDecoder().decode(BotSend.Result.self, from: data)
    }

    func test_aHostConsumedSendDecodesAsADeliveredSendOnThePhone() throws {
        // WHY: after "Reply here" the phone's answer is forwarded by the Mac,
        // but the consumed receipt lacked request_id/client_request_id, so
        // `BotSend.Result` threw and iOS showed the delivered answer as failed
        // and put it back in the composer (a retry became a normal Titio run).
        let inbox = BotConversation(botID: titio.id, title: "Notifications")
        try store.upsertConversation(inbox)
        let conversationID = inbox.id.value.uuidString.lowercased()
        authority.onSend = { [titioID] _, _, _, _, _, _ in
            // The exact object BotsViewModel.interceptTitioInboxSend returns.
            [
                "bot_id": titioID,
                "conversation_id": conversationID,
                "enqueued": false,
                "queued_follow_up": false,
                "host_consumed": true,
                "titio_notice": "reply",
                "thread_id": UUID().uuidString.lowercased(),
            ]
        }
        let reply = try authority.dispatch(method: "bot.send", params: [
            "client_request_id": "send-1", "host_id": "host-1", "bot_id": titioID,
            "conversation_id": conversationID, "text": "use staging",
        ])
        let result = try decodeBotSend(reply)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.requestID, "send-1")
        XCTAssertEqual(result.clientRequestID, "send-1")
        XCTAssertEqual(result.botID, titioID)
        XCTAssertEqual(result.conversationID, conversationID)
        XCTAssertEqual(result.disposition, .hostConsumed(notice: "reply"))
    }

    func test_noticeActNavigateReceiptCarriesTheRouteObjectWhereThePhoneReadsIt() throws {
        // WHY: `readback.route` is the readback's route name ("bot"); the
        // navigation target is `readback.navigation` and the top-level
        // `route`. A phone reading `readback.route` first got a string and
        // showed "The Mac did not say where to open this".
        authority.onNoticeAct = { _, _, _ in
            ["outcome": "navigate", "route": ["threadId": "T1", "workspaceId": "W1"]]
        }
        let reply = try authority.dispatch(method: "bot.notice.act", params: [
            "client_request_id": "tap-1", "bot_id": titioID,
            "message_id": UUID().uuidString.lowercased(), "option_index": 2,
        ])
        let readback = try XCTUnwrap(reply["readback"] as? [String: Any])
        XCTAssertEqual(readback["outcome"] as? String, "navigate")
        XCTAssertEqual(readback["navigation"] as? [String: String], ["threadId": "T1", "workspaceId": "W1"])
        XCTAssertEqual(reply["route"] as? [String: String], ["threadId": "T1", "workspaceId": "W1"])
        XCTAssertEqual(readback["route"] as? String, "bot", "a string here: clients must read `navigation` first")
    }

    func test_titioInboxLastAtIsEpochSecondsOnBothWirePaths() throws {
        // WHY: iOS reads `last_at` as a number; an ISO string made it nil, so
        // the roster never showed the inbox preview or its time.
        let lastAt = Date(timeIntervalSince1970: 1_792_094_460.5)
        let snapshot = TitioInboxSnapshot(
            botID: titio.id, conversationID: BotConversationID(), threadID: AgentThreadID(),
            unreadCount: 2, openDecisions: 1, lastPreview: "Hi", lastAt: lastAt
        )
        guard case .number(let seconds)? = snapshot.wireObject.objectValue?["last_at"] else {
            return XCTFail("bot.updated last_at must be a number")
        }
        XCTAssertEqual(seconds, lastAt.timeIntervalSince1970)
        XCTAssertEqual(snapshot.foundationObject["last_at"] as? Double, lastAt.timeIntervalSince1970)
    }

    func test_inboxEventPayloadHasNoMethodSoTheRosterAppliesItWithoutARefetch() throws {
        // WHY: the phone skips the full `bot.list` read only for a
        // method-less (or `bot.notice.*`) `titio_inbox` payload; the old
        // "bot.titio_inbox" method cost a roster refetch per notice.
        let snapshot = TitioInboxSnapshot(
            botID: titio.id, conversationID: BotConversationID(), threadID: AgentThreadID(),
            unreadCount: 1, openDecisions: 0, lastPreview: nil, lastAt: nil
        )
        let payload = try XCTUnwrap(AppContext.titioInboxEventPayload(snapshot).objectValue)
        XCTAssertNil(payload["method"])
        XCTAssertNotNil(payload["titio_inbox"]?.objectValue)
        XCTAssertEqual(payload["bot_id"]?.stringValue, titioID)
    }
}
