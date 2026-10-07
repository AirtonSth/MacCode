import XCTest
import RemoteCodeTreaty
@testable import SocketServer

/// WHY: the iPhone only shows the actor badge and the Mac-execution row on
/// hosts that advertise them, and both writes must go through the receipt
/// ledger: a retried tap must never lock a thread twice or answer the bot
/// twice. A malformed actor must be refused before any claim, so the request
/// id is not fenced as an unknown outcome.
final class ThreadActorRPCAdmissionTests: XCTestCase {
    func test_bothWritesAreLedgerMutationsWithWriteScope() {
        for method in ["agent.thread.actor.set", "agent.mac_execution.resolve"] {
            XCTAssertFalse(JSONRPCDispatcher.isReadOnlyBatchMethod(method), method)
            XCTAssertEqual(JSONRPCDispatcher.requiredCapability(for: method), "write", method)
            XCTAssertTrue(JSONRPCDispatcher.hostMutationMethods.contains(method), method)
        }
    }

    func test_actorSetPreflight_acceptsBothActorsAndTargets() {
        let thread = JSONValue.string(UUID().uuidString)
        let valid: [[String: JSONValue]] = [
            ["thread_id": thread, "actor": .object(["kind": .string("none")])],
            ["thread_id": thread, "actor": .object(["kind": .string("bot"), "bot_id": .string(UUID().uuidString)])],
            ["thread_id": thread, "actor": .object(["kind": .string("bot"), "bot_id": .string(UUID().uuidString)]), "execution_target": .string("vm")],
            ["thread_id": thread, "actor": .object(["kind": .string("bot"), "bot_id": .string(UUID().uuidString)]), "execution_target": .string("mac")],
            ["thread_id": thread, "actor": .object(["kind": .string("bot"), "bot_id": .string(UUID().uuidString)]), "execution_target": .null],
        ]
        for params in valid {
            XCTAssertNoThrow(try HostMutationContract.preflight(method: "agent.thread.actor.set", params: params), "\(params)")
        }
    }

    func test_actorSetPreflight_refusesMalformedActorOrTarget() {
        let thread = JSONValue.string(UUID().uuidString)
        let bot = JSONValue.object(["kind": .string("bot"), "bot_id": .string(UUID().uuidString)])
        let invalid: [[String: JSONValue]] = [
            ["actor": bot],
            ["thread_id": thread],
            ["thread_id": thread, "actor": .string("bot")],
            ["thread_id": thread, "actor": .object(["kind": .string("user")])],
            ["thread_id": thread, "actor": .object(["kind": .string("bot")])],
            ["thread_id": thread, "actor": .object(["kind": .string("bot"), "bot_id": .string("nope")])],
            ["thread_id": thread, "actor": bot, "execution_target": .string("cloud")],
            ["thread_id": thread, "actor": bot, "execution_target": .bool(true)],
        ]
        for params in invalid {
            XCTAssertThrowsError(try HostMutationContract.preflight(method: "agent.thread.actor.set", params: params), "\(params)") {
                XCTAssertEqual(($0 as? JSONRPCError)?.code, JSONRPCError.invalidParams.code)
            }
        }
    }

    func test_macExecutionResolvePreflight_needsThreadAndBoolApprove() {
        let thread = JSONValue.string(UUID().uuidString)
        XCTAssertNoThrow(try HostMutationContract.preflight(method: "agent.mac_execution.resolve", params: ["thread_id": thread, "approve": .bool(false)]))
        for params: [String: JSONValue] in [["thread_id": thread], ["approve": .bool(true)], ["thread_id": thread, "approve": .string("true")]] {
            XCTAssertThrowsError(try HostMutationContract.preflight(method: "agent.mac_execution.resolve", params: params), "\(params)")
        }
    }

    @MainActor
    func test_capabilitiesAdvertiseThreadActorOnBothAuthorities() async throws {
        let payload = DirectHTTPServer.capabilitiesProjection(loopbackOnly: false)
            .authenticatedPayload(serverID: "host-1", bootEpoch: 42)
        let capabilities = try XCTUnwrap(payload["capabilities"] as? [String: Any])
        let agent = try XCTUnwrap(capabilities["agent"] as? [String: Any])
        XCTAssertEqual(agent["thread_actor_v1"] as? Bool, true)
        let decoded = try JSONDecoder().decode(
            HostCapabilities.Agent.self,
            from: JSONSerialization.data(withJSONObject: agent)
        )
        XCTAssertTrue(decoded.threadActorV1, "the treaty type the iPhone gates on reads the same flag")

        let response = await JSONRPCDispatcher(router: FakeRouter()).dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "system.capabilities", params: nil
        ))
        XCTAssertEqual(response.result?.objectValue?["agent"]?.objectValue?["thread_actor_v1"], .bool(true))
    }

    func test_olderHostWithoutFlagDecodesAsUnsupported() throws {
        let decoded = try JSONDecoder().decode(
            HostCapabilities.Agent.self,
            from: Data(#"{"providers":["codex"],"supports_stream_events":true,"supports_resume":true,"manual_actions_v1":true}"#.utf8)
        )
        XCTAssertFalse(decoded.threadActorV1)
    }
}
