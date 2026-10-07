import XCTest
@testable import RemoteCodeTreaty

/// WHY: the iPhone reconciles its optimistic group message by the send
/// receipt. A receipt that does not name the round, the room and turns of
/// that same round would let it pin a reply to the wrong row, so decoding
/// must fail instead of guessing.
final class BotGroupContractsTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func turn(group: String = "g1", round: String = "r1", room: String = "room1", id: String = "t1") -> String {
        #"{"group_id":"\#(group)","round_id":"\#(round)","turn_id":"\#(id)","bot_id":"b1","state":"planned","ordinal":1,"hop":0,"room_thread_id":"\#(room)","room_message_id":"m-\#(id)","trigger_message_id":"u1","run_id":null,"error":null,"updated_at":10.5}"#
    }

    private func sendReceipt(turns: String, roundID: String = "r1") -> Data {
        Data(#"{"request_id":"req-1","client_request_id":"req-1","receipt_id":"rcpt-1","status":"completed","host_id":"host-1","readback":{"group_id":"g1","round_id":"\#(roundID)","room_thread_id":"room1","user_message_id":"u1","submit_key":"k1","turns":[\#(turns)]}}"#.utf8)
    }

    func testGroupSendResultDecodesTheHostReceipt() throws {
        let result = try decoder.decode(BotGroupSend.Result.self, from: sendReceipt(turns: turn() + "," + turn(id: "t2")))
        XCTAssertEqual(result.requestID, "req-1")
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.readback.userMessageID, "u1")
        XCTAssertEqual(result.readback.turns.map(\.turnID), ["t1", "t2"])
        XCTAssertEqual(result.readback.turns.first?.roomMessageID, "m-t1")
        XCTAssertNil(result.readback.turns.first?.runID)
    }

    func testGroupSendResultRejectsIncompleteOrForeignIdentity() {
        XCTAssertThrowsError(try decoder.decode(BotGroupSend.Result.self, from: sendReceipt(turns: "")), "no turns")
        XCTAssertThrowsError(
            try decoder.decode(BotGroupSend.Result.self, from: sendReceipt(turns: turn(round: "other"))),
            "a turn from another round"
        )
        XCTAssertThrowsError(
            try decoder.decode(BotGroupSend.Result.self, from: sendReceipt(turns: turn(group: "g2"))),
            "a turn from another group"
        )
        XCTAssertThrowsError(
            try decoder.decode(BotGroupSend.Result.self, from: sendReceipt(turns: turn(room: "room2"))),
            "a turn painting another room"
        )
        XCTAssertThrowsError(
            try decoder.decode(BotGroupSend.Result.self, from: sendReceipt(turns: turn(round: ""), roundID: "")),
            "an empty round id"
        )
    }

    func testGroupSendParamsUseTheHostWireKeys() throws {
        let data = try JSONEncoder().encode(BotGroupSend.Params(groupID: "g1", text: "hi", submitKey: "k1"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["group_id", "text", "submit_key", "attachment_ids"])
        XCTAssertEqual(object["attachment_ids"] as? [String], [])
    }

    func testGroupUpdateParamsOmitUnsetFields() throws {
        let data = try JSONEncoder().encode(BotGroupUpdate.Params(groupID: "g1", expectedRevision: 3, clearLeadBotID: true))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["group_id", "expected_revision", "clear_lead_bot_id"],
                       "an absent field keeps its value on the host")
    }

    func testGroupRowDecodesParticipantsWithOptionalThreadsAndLeftAt() throws {
        let row = try decoder.decode(BotGroupRow.self, from: Data(#"""
        {"id":"g1","title":"Launch","team_id":null,"room_thread_id":"room1","policy":"lead","lead_bot_id":"b1",
         "max_auto_hops":4,"pinned":false,"hidden":false,"unread":true,"attention_state":"needs_attention","revision":7,
         "participants":[{"bot_id":"b1","member_conversation_id":"c1","member_thread_id":null,"sort_order":0,"joined_at":1,"left_at":null},
                         {"bot_id":"b2","member_conversation_id":"c2","member_thread_id":"th2","sort_order":1,"joined_at":1,"left_at":5}],
         "created_at":1,"updated_at":2}
        """#.utf8))
        XCTAssertNil(row.teamID)
        XCTAssertEqual(row.participants.map(\.memberThreadID), [nil, "th2"])
        XCTAssertEqual(row.participants.map(\.leftAt), [nil, 5])
        XCTAssertEqual(row.attentionState, "needs_attention")
        XCTAssertEqual(row.participants.map(\.provider), [nil, nil], "older hosts send no route")
    }

    func testGroupParticipantDecodesItsRoute() throws {
        let participant = try decoder.decode(BotGroupParticipantRow.self, from: Data(#"""
        {"bot_id":"b1","member_conversation_id":"c1","member_thread_id":"th1","provider":"codex",
         "execution_target":"vm","sort_order":0,"joined_at":1,"left_at":null}
        """#.utf8))
        XCTAssertEqual(participant.provider, "codex")
        XCTAssertEqual(participant.executionTarget, "vm")
    }

    func testBotCapabilitiesDefaultTeamsAndGroupsOffForOlderHosts() throws {
        let old = try decoder.decode(HostCapabilities.Bot.self, from: Data(#"{"queue_controls":["remove"]}"#.utf8))
        XCTAssertFalse(old.teamsV1, "an older host has no team RPCs: the iPhone must hide teams")
        XCTAssertFalse(old.groupsV1)
        let current = try decoder.decode(
            HostCapabilities.Bot.self,
            from: Data(#"{"queue_controls":[],"teams_v1":true,"groups_v1":true}"#.utf8)
        )
        XCTAssertTrue(current.teamsV1)
        XCTAssertTrue(current.groupsV1)
    }

    /// WHY: team and group events come in several shapes (a reorder has no
    /// team id, a bot delete names only the bot, a delete has no row). A
    /// client must decode every one, and a change it does not know yet must
    /// not fail decoding (it re-reads the list instead).
    func testTeamAndGroupEventsDecodeEveryShape() throws {
        let reordered = try decoder.decode(BotTeamUpdatedEvent.self, from: Data(
            #"{"change":"reordered","team_ids":["t2","t1"],"deleted":false}"#.utf8
        ))
        XCTAssertEqual(reordered.change, .reordered)
        XCTAssertNil(reordered.teamID)
        XCTAssertEqual(reordered.teamIDs, ["t2", "t1"])
        let teamDeleted = try decoder.decode(BotTeamUpdatedEvent.self, from: Data(
            #"{"change":"deleted","team_id":"t1","revision":null,"deleted":true,"team":null}"#.utf8
        ))
        XCTAssertEqual(teamDeleted.change, .deleted)
        XCTAssertTrue(teamDeleted.deleted)
        XCTAssertNil(teamDeleted.team)
        let botDeleted = try decoder.decode(BotGroupUpdatedEvent.self, from: Data(
            #"{"change":"bot_deleted","bot_id":"b1","deleted":false}"#.utf8
        ))
        XCTAssertEqual(botDeleted.change, .botDeleted)
        XCTAssertEqual(botDeleted.botID, "b1")
        XCTAssertNil(botDeleted.groupID)
        let future = try decoder.decode(BotGroupUpdatedEvent.self, from: Data(
            #"{"change":"archived","group_id":"g1","revision":3,"deleted":false,"group":null}"#.utf8
        ))
        XCTAssertEqual(future.change, .unknown("archived"))
        XCTAssertEqual(future.revision, 3)
        let turn = try decoder.decode(BotGroupTurnRow.self, from: Data(turn().utf8))
        XCTAssertEqual(turn.state, "planned")
    }

    /// WHY: group refusals reuse bot error codes (-32044 is also "bot not
    /// found"). A generic handler that drops a bot on `.botNotFound` must never
    /// drop one because a group or team is missing.
    func testGroupRefusalsAreToldApartFromBotErrorsByTheirData() {
        func error(_ code: Int, _ kind: String) -> RemoteCodeError {
            RemoteCodeError(code: code, message: "", data: .object([
                "domain": .string("bot_group"), "kind": .string(kind),
            ]))
        }
        XCTAssertEqual(error(-32044, "not_found").kind, .botGroupNotFound)
        XCTAssertEqual(error(-32078, "revision_conflict").kind, .botGroupRevisionConflict)
        XCTAssertEqual(error(-32091, "runtime_unavailable").kind, .botGroupRuntimeUnavailable)
        XCTAssertEqual(error(-32602, "send_refused").kind, .invalidParams)
        XCTAssertEqual(RemoteCodeError(code: -32044, message: "", data: nil).kind, .botNotFound,
                       "a real missing bot keeps its kind")
        XCTAssertEqual(RemoteCodeError(code: -32091, message: "", data: nil).kind, .commandReceiptUnavailable)
    }
}
