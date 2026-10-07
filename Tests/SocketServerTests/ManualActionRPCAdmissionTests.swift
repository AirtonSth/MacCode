import XCTest
import RemoteCodeTreaty
@testable import SocketServer

/// WHY: the iPhone reads manual actions in its read-only batch and only shows
/// the card on hosts that advertise them. The read must be batchable and
/// read-scoped; the resolve must go through the receipt ledger so a retried
/// tap never answers the bot twice.
final class ManualActionRPCAdmissionTests: XCTestCase {
    func test_listIsBatchReadAndResolveIsLedgerMutation() {
        XCTAssertTrue(JSONRPCDispatcher.isReadOnlyBatchMethod("agent.manual_action.list"))
        XCTAssertEqual(JSONRPCDispatcher.requiredCapability(for: "agent.manual_action.list"), "read")
        XCTAssertFalse(JSONRPCDispatcher.hostMutationMethods.contains("agent.manual_action.list"))

        XCTAssertFalse(JSONRPCDispatcher.isReadOnlyBatchMethod("agent.manual_action.resolve"))
        XCTAssertEqual(JSONRPCDispatcher.requiredCapability(for: "agent.manual_action.resolve"), "write")
        XCTAssertTrue(JSONRPCDispatcher.hostMutationMethods.contains("agent.manual_action.resolve"))
    }

    func test_resolveNeedsThreadRequestAndKnownActionBeforeAnyClaim() {
        let valid: [String: JSONValue] = [
            "thread_id": .string(UUID().uuidString),
            "manual_action_id": .string(UUID().uuidString),
            "action": .string("continue"),
        ]
        for action in ["take", "continue", "decline"] {
            var params = valid
            params["action"] = .string(action)
            XCTAssertNoThrow(try HostMutationContract.preflight(method: "agent.manual_action.resolve", params: params), action)
        }
        var unknownAction = valid
        unknownAction["action"] = .string("approve")
        XCTAssertThrowsError(try HostMutationContract.preflight(method: "agent.manual_action.resolve", params: unknownAction))
        for missing in ["thread_id", "manual_action_id", "action"] {
            var params = valid
            params.removeValue(forKey: missing)
            XCTAssertThrowsError(try HostMutationContract.preflight(method: "agent.manual_action.resolve", params: params), missing)
        }
    }

    @MainActor
    func test_capabilitiesAdvertiseManualActionsOnBothAuthorities() async throws {
        let payload = DirectHTTPServer.capabilitiesProjection(loopbackOnly: false)
            .authenticatedPayload(serverID: "host-1", bootEpoch: 42)
        let capabilities = try XCTUnwrap(payload["capabilities"] as? [String: Any])
        let agent = try XCTUnwrap(capabilities["agent"] as? [String: Any])
        XCTAssertEqual(agent["manual_actions_v1"] as? Bool, true)
        let decoded = try JSONDecoder().decode(
            HostCapabilities.Agent.self,
            from: JSONSerialization.data(withJSONObject: agent)
        )
        XCTAssertTrue(decoded.manualActionsV1, "the treaty type the iPhone gates on reads the same flag")

        let response = await JSONRPCDispatcher(router: FakeRouter()).dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "system.capabilities", params: nil
        ))
        XCTAssertEqual(response.result?.objectValue?["agent"]?.objectValue?["manual_actions_v1"], .bool(true))
    }

    func test_olderHostWithoutFlagDecodesAsUnsupported() throws {
        let decoded = try JSONDecoder().decode(
            HostCapabilities.Agent.self,
            from: Data(#"{"providers":["codex"],"supports_stream_events":true,"supports_resume":true}"#.utf8)
        )
        XCTAssertFalse(decoded.manualActionsV1)
    }
}
