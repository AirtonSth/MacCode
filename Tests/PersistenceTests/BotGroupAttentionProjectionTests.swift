import XCTest
import CoreModel
@testable import Persistence

/// WHY: the iPhone "Ready for you" inbox reads `bot.attention.list`. A group
/// whose bot failed must show up there as a group item (kind `group`) that
/// opens the room, anchored on the failed turn; a quiet group must not.
final class BotGroupAttentionProjectionTests: BotStoreGroupsFixture {
    private var authority: BotRemoteControlAuthority!
    private var supportDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-bot-group-attention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        authority = BotRemoteControlAuthority(
            db: db, store: store, settings: SettingsStore(db: db), appSupportDirectory: supportDir
        )
    }

    override func tearDown() {
        authority = nil
        if let supportDir { try? FileManager.default.removeItem(at: supportDir) }
        super.tearDown()
    }

    /// Group items are opt-in: a client without groups never gets one.
    private func groupItems(optIn: Bool = true) throws -> [[String: Any]] {
        let params: [String: Any] = optIn ? ["include_kinds": ["group"]] : [:]
        let listed = try authority.dispatch(method: "bot.attention.list", params: params)
        return ((listed["items"] as? [[String: Any]]) ?? []).filter { $0["kind"] as? String == "group" }
    }

    func test_groupNeedingAttentionIsListedAsAGroupItemAnchoredOnTheFailedTurn() throws {
        let ana = try makeBot("Ana")
        let bob = try makeBot("Bob")
        let group = try makeGroup([ana, bob])
        let round = BotGroupRoundID()
        let answered = BotGroupTurn(groupID: group.id, roundID: round, botID: ana.id, ordinal: 1)
        let failed = BotGroupTurn(groupID: group.id, roundID: round, botID: bob.id, ordinal: 2)
        try store.insertGroupTurns([answered, failed])
        try store.transitionGroupTurn(id: answered.id, from: [.planned], to: .completed)
        try store.transitionGroupTurn(id: failed.id, from: [.planned], to: .failed, error: "boom")
        XCTAssertTrue(try groupItems().isEmpty, "attention none: the group is quiet")

        _ = try store.updateGroup(id: group.id, expectedRevision: nil) {
            $0.attentionState = .needsAttention
            $0.unread = true
        }

        let item = try XCTUnwrap(try groupItems().first)
        XCTAssertEqual(try groupItems().count, 1)
        XCTAssertTrue(try groupItems(optIn: false).isEmpty, "an older client never sees a group item")
        XCTAssertEqual(item["state"] as? String, "needs_attention")
        XCTAssertEqual(item["group_id"] as? String, group.id.value.uuidString.lowercased())
        XCTAssertEqual(item["thread_id"] as? String, group.roomThreadID.value.uuidString.lowercased(),
                       "opening the item opens the room")
        XCTAssertEqual(item["id"] as? String, failed.id.value.uuidString.lowercased())
        XCTAssertEqual(item["turn_id"] as? String, failed.id.value.uuidString.lowercased())
        XCTAssertEqual(item["bot_id"] as? String, bob.id.value.uuidString.lowercased())
        XCTAssertEqual(item["attention_item_id"] as? String, item["id"] as? String)
        XCTAssertEqual(item["title"] as? String, group.title)

        _ = try store.updateGroup(id: group.id, expectedRevision: nil) {
            $0.attentionState = .none
            $0.unread = false
        }
        XCTAssertTrue(try groupItems().isEmpty, "a selected group leaves the inbox")
    }

    func test_hiddenGroupIsNotListed() throws {
        let ana = try makeBot("Ana")
        let group = try makeGroup([ana])
        let turn = BotGroupTurn(groupID: group.id, roundID: BotGroupRoundID(), botID: ana.id, ordinal: 1)
        try store.insertGroupTurns([turn])
        _ = try store.updateGroup(id: group.id, expectedRevision: nil) {
            $0.attentionState = .working
            $0.hidden = true
        }
        XCTAssertTrue(try groupItems().isEmpty)
    }
}
