import XCTest
@testable import Surfaces
import AgentRuntime

/// Proves the decline-with-reason contract:
/// The payload builder is a pure static helper - no UI, no MainActor, no flakiness.
/// These tests encode WHY the behaviour matters for the supervised-mode steering loop:
/// a reason must reach the agent so it can adjust future requests;
/// blank/nil must still produce a valid decline without an empty annotation.
final class DeclinePayloadTests: XCTestCase {

    func test_declinePayload_withNonEmptyReason_includesReason() {
        let result = AgentAppViewModel.declinePayload(reason: "too risky")
        XCTAssertEqual(result, .decline("too risky"),
                       "a non-empty reason must be forwarded so the agent can steer future requests")
    }

    func test_declinePayload_withWhitespaceOnlyReason_producesNilReason() {
        let result = AgentAppViewModel.declinePayload(reason: "   ")
        XCTAssertEqual(result, .decline(nil),
                       "whitespace-only text carries no steering signal and must be treated as no reason")
    }

    func test_declinePayload_withNilReason_producesNilReason() {
        let result = AgentAppViewModel.declinePayload(reason: nil)
        XCTAssertEqual(result, .decline(nil),
                       "nil reason must produce a plain decline payload - existing callers that pass nil must be unaffected")
    }

    func test_declinePayload_withEmptyStringReason_producesNilReason() {
        let result = AgentAppViewModel.declinePayload(reason: "")
        XCTAssertEqual(result, .decline(nil),
                       "an empty string is not a useful reason; the payload must carry nil so no blank annotation reaches the agent")
    }

    func test_declinePayload_trimsLeadingAndTrailingWhitespace() {
        let result = AgentAppViewModel.declinePayload(reason: "  do not run prod migrations  ")
        XCTAssertEqual(result, .decline("do not run prod migrations"),
                       "the reason must be trimmed before it reaches the agent to avoid spurious leading/trailing space")
    }
}
