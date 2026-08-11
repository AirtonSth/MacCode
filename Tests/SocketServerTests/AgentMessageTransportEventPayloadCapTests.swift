import XCTest
@testable import SocketServer

/// Wire payload ceiling for agent.message.* transport events (memory loop).
///
/// WHY: content is already prefix-capped at eventContentMaxBytes (2 KiB), but the
/// full escaped JSON payload (metadata + attachments preview) can still grow.
/// Bound encoded payload so one message event cannot consume a large WS frame.
final class AgentMessageTransportEventPayloadCapTests: XCTestCase {

    func test_eventPayloadMaxBytes_is32KiB() {
        XCTAssertEqual(AgentMessageTransport.eventPayloadMaxBytes, 32 * 1_024)
        XCTAssertLessThan(AgentMessageTransport.eventPayloadMaxBytes, 64 * 1_024)
        XCTAssertGreaterThan(
            AgentMessageTransport.eventPayloadMaxBytes,
            AgentMessageTransport.eventContentMaxBytes
        )
    }

    func test_retentionEstimate_eventPayload_64KiBTo32KiB() {
        let prior = 64 * 1_024
        let limit = AgentMessageTransport.eventPayloadMaxBytes
        let reduction = Double(prior - limit) / Double(prior)
        XCTAssertGreaterThan(reduction, 0.49)
        XCTAssertEqual(limit, 32 * 1_024)

        // Basis: peak encoded agent.message event payload retained/sent per event.
        // 64 KiB → 32 KiB (−50%).
        XCTAssertEqual(prior, 65_536)
        XCTAssertEqual(limit, 32_768)
    }

    func test_getMaxBytesCap_is128KiB() {
        XCTAssertEqual(AgentMessageTransport.getMaxBytesCap, 128 * 1_024)
        XCTAssertEqual(
            AgentMessageTransport.clampGetMaxBytes(10 * 1_048_576),
            AgentMessageTransport.getMaxBytesCap
        )
    }

    func test_retentionEstimate_getMaxBytesCap_256KiBTo128KiB() {
        // Prior getMaxBytesCap 256 KiB → 128 KiB (−50%) peak agent.message.get envelope.
        let prior = 256 * 1_024
        let limit = AgentMessageTransport.getMaxBytesCap
        XCTAssertEqual(limit, 128 * 1_024)
        let reduction = Double(prior - limit) / Double(prior)
        XCTAssertEqual(reduction, 0.5, accuracy: 0.001)
    }

    func test_listMaxBodyBytesCap_is256KiB() {
        XCTAssertEqual(AgentMessageTransport.listMaxBodyBytesCap, 256 * 1_024)
        XCTAssertEqual(
            AgentMessageTransport.clampListMaxBodyBytes(10 * 1_048_576),
            AgentMessageTransport.listMaxBodyBytesCap
        )
    }

    func test_retentionEstimate_listMaxBodyBytesCap_512KiBTo256KiB() {
        // Prior listMaxBodyBytesCap 512 KiB → 256 KiB (−50%) peak agent.message.list envelope.
        let prior = 512 * 1_024
        let limit = AgentMessageTransport.listMaxBodyBytesCap
        XCTAssertEqual(limit, 256 * 1_024)
        let reduction = Double(prior - limit) / Double(prior)
        XCTAssertEqual(reduction, 0.5, accuracy: 0.001)
    }
}
