import XCTest
import CoreModel
import RemoteCodeTreaty
@testable import SocketServer

/// iOS rebuilds a thread's error row from `agent.thread.read` on cold open,
/// reconnect and host restart. Without the host's action on the replayed row
/// it shows the raw machine marker and a generic Retry after every restart,
/// while the live `agent.run.error` showed the right action.
@MainActor
final class RunRecoveryActionReplayTests: XCTestCase {
    private func makeRouter() -> FakeRouter {
        let router = FakeRouter()
        router.readAgentEvents = [
            .turnStarted(turnId: "t1"),
            .error(message: "[fresh-session:incompatible-history] rejected", recoverable: false)
        ]
        router.replayedRunErrorFieldsStub = { message, recoverable in
            ["message": .string("shown:" + message), "recovery_action": .string(recoverable ? "retry" : "new_session")]
        }
        return router
    }

    private func errorRow(_ events: JSONValue?, file: StaticString = #filePath, line: UInt = #line) throws -> [String: JSONValue] {
        let rows = try XCTUnwrap(events?.arrayValue, file: file, line: line)
        XCTAssertEqual(rows.count, 2, file: file, line: line)
        XCTAssertEqual(rows[0], .object(["turnStarted": .object(["turnId": .string("t1")])]),
                       "non-error rows are untouched", file: file, line: line)
        return try XCTUnwrap(rows[1].objectValue?["error"]?.objectValue, file: file, line: line)
    }

    func test_everyThreadReadShape_carriesTheRecoveryActionOnReplayedErrors() async throws {
        let router = makeRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let tid = AgentThreadID().value.uuidString

        let plain = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "agent.thread.read",
            params: ["thread_id": .string(tid)]
        ))
        let watermark = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(2), method: "agent.thread.read",
            params: ["thread_id": .string(tid), "include_event_watermark": .bool(true)]
        ))
        let v1 = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(3), method: "agent.thread.read",
            params: ["response_version": .number(1), "thread_id": .string(tid), "include_event_watermark": .bool(true)]
        ))
        for events in [plain.result, watermark.result?.objectValue?["events"], v1.result?.objectValue?["events"]] {
            let error = try errorRow(events)
            XCTAssertEqual(error["message"], .string("shown:[fresh-session:incompatible-history] rejected"),
                           "the router classifies the RAW stored message")
            XCTAssertEqual(error["recovery_action"], .string("new_session"))
            XCTAssertEqual(error["recoverable"], .bool(false), "the stored flag stays for older clients")
        }
    }

    func test_routerWithoutClassifier_leavesReplayedErrorsAsStored() async throws {
        let router = makeRouter()
        router.replayedRunErrorFieldsStub = nil
        let response = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "agent.thread.read",
            params: ["thread_id": .string(AgentThreadID().value.uuidString)]
        ))
        let error = try errorRow(response.result)
        XCTAssertEqual(error, ["message": .string("[fresh-session:incompatible-history] rejected"), "recoverable": .bool(false)])
    }

    func test_capabilityFlagIsAdvertisedOnBothAuthorities() async throws {
        // WHY: "key absent" cannot tell an older host from "no message", so iOS
        // gates on this flag before trusting recovery_action.
        let payload = DirectHTTPServer.capabilitiesProjection(loopbackOnly: false)
            .authenticatedPayload(serverID: "host-1", bootEpoch: 1)
        let capabilities = try XCTUnwrap(payload["capabilities"] as? [String: Any])
        let agent = try XCTUnwrap(capabilities["agent"] as? [String: Any])
        XCTAssertEqual(agent["run_recovery_action_v1"] as? Bool, true)
        let decoded = try JSONDecoder().decode(
            HostCapabilities.Agent.self, from: JSONSerialization.data(withJSONObject: agent)
        )
        XCTAssertTrue(decoded.runRecoveryActionV1)

        let response = await JSONRPCDispatcher(router: FakeRouter()).dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "system.capabilities", params: nil
        ))
        XCTAssertEqual(response.result?.objectValue?["agent"]?.objectValue?["run_recovery_action_v1"], .bool(true))

        let older = try JSONDecoder().decode(
            HostCapabilities.Agent.self,
            from: Data(#"{"providers":["codex"],"supports_stream_events":true,"supports_resume":true}"#.utf8)
        )
        XCTAssertFalse(older.runRecoveryActionV1, "an older host falls back to a generic Retry")
    }
}
