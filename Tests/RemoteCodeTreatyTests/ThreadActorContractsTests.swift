import XCTest
@testable import RemoteCodeTreaty

/// WHY: the iPhone builds its actor badge and its "run on the Mac?" row from
/// these types. A host row or result that does not decode would hide the
/// badge or leave the row stuck, and a refusal read only by its code would
/// show "failed" when another device already answered.
final class ThreadActorContractsTests: XCTestCase {
    private let fields = #""actor":{"kind":"bot","bot_id":"b1","botId":"b1"},"actor_locked_at":1.5,"execution_target":"vm","guest_runtime":"guest-v1","runs_in_guest":true,"pending_mac_execution":{"reason":"Xcode"}"#

    func test_threadRowFieldsDecodeLockedAndUnlocked() throws {
        let locked = try JSONDecoder().decode(AgentThreadActorFields.self, from: Data("{\(fields),\"title\":\"x\"}".utf8))
        XCTAssertEqual(locked.actor, .bot("b1"))
        XCTAssertEqual(locked.actorLockedAt, 1.5)
        XCTAssertEqual(locked.executionTarget, "vm")
        XCTAssertEqual(locked.guestRuntime, "guest-v1")
        XCTAssertTrue(locked.runsInGuest)
        XCTAssertEqual(locked.pendingMacExecution?.reason, "Xcode")

        let unlocked = #"{"actor":{"kind":"none","bot_id":null},"actor_locked_at":null,"execution_target":null,"guest_runtime":null,"runs_in_guest":false,"pending_mac_execution":null}"#
        let none = try JSONDecoder().decode(AgentThreadActorFields.self, from: Data(unlocked.utf8))
        XCTAssertEqual(none.actor, .none)
        XCTAssertNil(none.actorLockedAt)
        XCTAssertNil(none.pendingMacExecution)
    }

    func test_resultsDecodeTheTopLevelFields() throws {
        let set = try JSONDecoder().decode(
            AgentThreadActorSet.Result.self,
            from: Data(#"{"thread_id":"T1",\#(fields),"thread":{}}"#.utf8)
        )
        XCTAssertEqual(set.threadID, "T1")
        XCTAssertEqual(set.fields.executionTarget, "vm")

        let resolved = try JSONDecoder().decode(
            AgentMacExecutionResolve.Result.self,
            from: Data(#"{"thread_id":"T1","approved":false,\#(fields),"thread":{},"follow_up":{"delivered":false,"error":"offline"}}"#.utf8)
        )
        XCTAssertFalse(resolved.approved)
        XCTAssertEqual(resolved.followUp.delivered, false)
        XCTAssertEqual(resolved.followUp.error, "offline")
        XCTAssertEqual(resolved.fields.guestRuntime, "guest-v1")
    }

    func test_paramsEncodeTheWireKeys() throws {
        let set = AgentThreadActorSet.Params(threadID: "T1", actor: .bot("B1"), executionTarget: "mac")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(set)) as? [String: Any])
        XCTAssertEqual(object["thread_id"] as? String, "T1")
        XCTAssertEqual((object["actor"] as? [String: Any])?["kind"] as? String, "bot")
        XCTAssertEqual((object["actor"] as? [String: Any])?["bot_id"] as? String, "B1")
        XCTAssertEqual(object["execution_target"] as? String, "mac")
        let resolve = AgentMacExecutionResolve.Params(threadID: "T1", approve: true)
        let resolveObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(resolve)) as? [String: Any])
        XCTAssertEqual(resolveObject["approve"] as? Bool, true)
        XCTAssertEqual(AgentThreadActorSet.method, "agent.thread.actor.set")
        XCTAssertEqual(AgentMacExecutionResolve.method, "agent.mac_execution.resolve")
    }

    func test_requestedEventDecodesAndKindIsCataloged() throws {
        let event = try JSONDecoder().decode(
            AgentMacExecutionRequestedEvent.self,
            from: Data(#"{"thread_id":"T1","reason":"Xcode","pending_mac_execution":{"reason":"Xcode"}}"#.utf8)
        )
        XCTAssertEqual(event.reason, "Xcode")
        XCTAssertEqual(RemoteCodeEventKind.agentMacExecutionRequested.rawValue, "agent.mac_execution.requested")
    }

    func test_refusalKindsReadTheDomainNotTheCodeAlone() {
        func error(_ code: Int, _ domain: String, _ kind: String) -> RemoteCodeError {
            RemoteCodeError(code: code, message: "", data: .object(["domain": .string(domain), "kind": .string(kind)]))
        }
        XCTAssertEqual(error(-32060, "thread_actor", "not_found").kind, .threadActorNotFound)
        XCTAssertEqual(error(-32063, "thread_actor", "locked").kind, .threadActorLocked)
        XCTAssertEqual(error(-32064, "thread_actor", "target_unavailable").kind, .threadActorTargetUnavailable)
        XCTAssertEqual(error(-32060, "mac_execution", "not_found").kind, .macExecutionNotFound)
        XCTAssertEqual(error(-32065, "mac_execution", "not_pending").kind, .macExecutionNotPending)
        XCTAssertEqual(error(-32060, "manual_action", "not_found").kind, .manualActionNotFound, "domains do not collide")
    }
}
