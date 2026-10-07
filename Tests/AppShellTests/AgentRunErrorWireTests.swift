import XCTest
@testable import AppShell
import SocketServer

/// `agent.run.error` / `agent.run.failed` carry the action iOS renders.
final class AgentRunErrorWireTests: XCTestCase {
    func test_failedRunFields_carryDisplayTextAndRecoveryAction() {
        let raw = "[fresh-session:incompatible-history] The model rejected this Distill session's history; Retry starts a new Distill session: boom"
        let fields = AgentRunErrorWire.fields(message: raw, recoverable: false)
        XCTAssertEqual(fields["message"], .string("The model rejected this Distill session's history; Retry starts a new Distill session: boom"),
                       "iOS shows `message` as-is, so the host strips the machine marker")
        XCTAssertEqual(fields["recovery_action"], .string("new_session"))
        XCTAssertEqual(AgentRunErrorWire.fields(message: "[auth-required] 401", recoverable: false)["recovery_action"], .string("sign_in"))
    }

    func test_failedRunFields_sendExplicitNullWhenNoActionIsSafe() {
        // WHY: an explicit null tells a new client "no action", while an absent
        // key means an older host (client falls back to Retry).
        let fields = AgentRunErrorWire.fields(message: "invalid request payload", recoverable: false)
        XCTAssertEqual(fields["recovery_action"], .null)
        XCTAssertEqual(fields["message"], .string("invalid request payload"))
    }
}
