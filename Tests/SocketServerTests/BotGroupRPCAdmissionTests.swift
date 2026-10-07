import XCTest
import RemoteCodeTreaty
@testable import SocketServer

/// WHY: the iPhone loads teams and groups in its read-only batch and hides
/// the feature on hosts that do not advertise it. Reads must be batchable
/// and grantable to read-only devices; every write must go through the
/// receipt ledger, never the context-free batch.
final class BotGroupRPCAdmissionTests: XCTestCase {
    private let reads = ["bot.team.list", "bot.group.list", "bot.group.get"]
    private let writes = [
        "bot.team.create", "bot.team.update", "bot.team.set_members", "bot.team.delete", "bot.team.reorder",
        "bot.group.create", "bot.group.update", "bot.group.set_participants", "bot.group.send",
        "bot.group.stop", "bot.group.retry_turn", "bot.group.select", "bot.group.delete",
    ]

    func test_readsAreBatchAdmittedAndReadScopedWritesAreLedgerMutations() {
        for method in reads {
            XCTAssertTrue(JSONRPCDispatcher.isReadOnlyBatchMethod(method), method)
            XCTAssertEqual(JSONRPCDispatcher.requiredCapability(for: method), "read", method)
            XCTAssertFalse(JSONRPCDispatcher.hostMutationMethods.contains(method), method)
        }
        for method in writes {
            XCTAssertFalse(JSONRPCDispatcher.isReadOnlyBatchMethod(method), method)
            XCTAssertEqual(JSONRPCDispatcher.requiredCapability(for: method), "write", method)
            XCTAssertTrue(JSONRPCDispatcher.hostMutationMethods.contains(method), method)
        }
    }

    func test_sendRequiresGroupTextAndSubmitKeyBeforeAnyClaim() {
        let group = UUID().uuidString
        XCTAssertNoThrow(try HostMutationContract.preflight(method: "bot.group.send", params: [
            "group_id": .string(group), "text": .string("hi"), "submit_key": .string("k"),
        ]))
        for missing in ["group_id", "text", "submit_key"] {
            var params: [String: JSONValue] = [
                "group_id": .string(group), "text": .string("hi"), "submit_key": .string("k"),
            ]
            params.removeValue(forKey: missing)
            XCTAssertThrowsError(try HostMutationContract.preflight(method: "bot.group.send", params: params), missing)
        }
    }

    func test_membersMayBeEmptyButMustBeUUIDs() {
        let team = UUID().uuidString
        XCTAssertNoThrow(try HostMutationContract.preflight(method: "bot.team.set_members", params: [
            "team_id": .string(team), "expected_revision": .number(1), "bot_ids": .array([]),
        ]), "emptying a team is a real edit")
        XCTAssertThrowsError(try HostMutationContract.preflight(method: "bot.team.set_members", params: [
            "team_id": .string(team), "expected_revision": .number(1), "bot_ids": .array([.string("nope")]),
        ]))
    }

    func test_authenticatedCapabilitiesAdvertiseTeamsAndGroups() throws {
        let payload = DirectHTTPServer.capabilitiesProjection(loopbackOnly: false)
            .authenticatedPayload(serverID: "host-1", bootEpoch: 42)
        let capabilities = try XCTUnwrap(payload["capabilities"] as? [String: Any])
        let bot = try XCTUnwrap(capabilities["bot"] as? [String: Any])
        XCTAssertEqual(bot["teams_v1"] as? Bool, true)
        XCTAssertEqual(bot["groups_v1"] as? Bool, true)
        let data = try JSONSerialization.data(withJSONObject: bot)
        let decoded = try JSONDecoder().decode(HostCapabilities.Bot.self, from: data)
        XCTAssertTrue(decoded.teamsV1, "the treaty type the iPhone gates on reads the same flag")
        XCTAssertTrue(decoded.groupsV1)
    }
}
