import XCTest
@testable import RemoteCodeTreaty

/// WHY: the iPhone builds its manual-action card from these types. A host
/// result or event that does not decode would leave the card stuck, and a
/// refusal read only by its code would show "failed" when another device
/// already answered.
final class ManualActionContractsTests: XCTestCase {
    private let row = #"{"id":"A1","thread_id":"T1","bot_id":"B1","bot_name":"Quinn","kind":"2fa","reason":"Código","state":"taken","created_at":1.5,"resolved_at":null,"note":null,"can_take":true}"#

    func test_resolveResultDecodesWithAndWithoutFollowUp() throws {
        let continued = #"{"thread_id":"T1","manual_action":\#(row),"pending_manual_action":null,"follow_up":{"delivered":true,"status":"started","run_id":"R1"}}"#
        let result = try JSONDecoder().decode(AgentManualActionResolve.Result.self, from: Data(continued.utf8))
        XCTAssertEqual(result.manualAction.kind, "2fa")
        XCTAssertTrue(result.manualAction.isPending)
        XCTAssertEqual(result.followUp?.runID, "R1")
        XCTAssertNil(result.pendingManualAction)

        let taken = #"{"thread_id":"T1","manual_action":\#(row),"pending_manual_action":\#(row),"follow_up":null}"#
        XCTAssertNil(try JSONDecoder().decode(AgentManualActionResolve.Result.self, from: Data(taken.utf8)).followUp)

        let failed = #"{"thread_id":"T1","manual_action":\#(row),"pending_manual_action":null,"follow_up":{"delivered":false,"error":"Provider unavailable"}}"#
        let failure = try JSONDecoder().decode(AgentManualActionResolve.Result.self, from: Data(failed.utf8)).followUp
        XCTAssertEqual(failure?.delivered, false)
        XCTAssertEqual(failure?.error, "Provider unavailable")
    }

    func test_paramsEncodeTheWireKeys() throws {
        let params = AgentManualActionResolve.Params(threadID: "T1", manualActionID: "A1", action: .continue, note: "ok")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any])
        XCTAssertEqual(object["thread_id"] as? String, "T1")
        XCTAssertEqual(object["manual_action_id"] as? String, "A1")
        XCTAssertEqual(object["action"] as? String, "continue")
        XCTAssertEqual(object["note"] as? String, "ok")
        XCTAssertEqual(AgentManualActionResolve.method, "agent.manual_action.resolve")
        XCTAssertEqual(AgentManualActionList.method, "agent.manual_action.list")
    }

    func test_updatedEventDecodesAndKindIsCataloged() throws {
        let event = #"{"thread_id":"T1","manual_action":\#(row),"pending_manual_action":null}"#
        let decoded = try JSONDecoder().decode(AgentManualActionUpdatedEvent.self, from: Data(event.utf8))
        XCTAssertEqual(decoded.manualAction.id, "A1")
        XCTAssertEqual(RemoteCodeEventKind.agentManualActionUpdated.rawValue, "agent.manual_action.updated")
    }

    func test_refusalKindsReadTheDomainNotTheCodeAlone() {
        func error(_ code: Int, _ kind: String) -> RemoteCodeError {
            RemoteCodeError(code: code, message: "", data: .object(["domain": .string("manual_action"), "kind": .string(kind)]))
        }
        XCTAssertEqual(error(-32060, "not_found").kind, .manualActionNotFound)
        XCTAssertEqual(error(-32061, "state_conflict").kind, .manualActionStateConflict)
        XCTAssertEqual(error(-32062, "take_unavailable").kind, .manualActionTakeUnavailable)
        XCTAssertEqual(RemoteCodeError(code: -32061, message: "", data: nil).kind, .unknown(-32061))
    }
}
