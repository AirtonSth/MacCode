import XCTest
@testable import Surfaces

/// Contract tests pinning the wire names in AgentQueueEventKinds.
///
/// WHY: iOS decodes these strings to route queue mirror events. A rename
/// or typo in the constant value silently breaks the iOS mirror — no mac
/// test would catch it because the emit site uses the constant. These tests
/// assert the exact UTF-8 byte sequences, so any change is intentional and
/// visible in diff.
final class AgentQueueEventKindContractTests: XCTestCase {

    // MARK: - Wire-string golden assertions

    /// WHY: "agent.message.queued" is the event iOS listens for to append a
    /// new pending row to the queue UI. A rename breaks the append path.
    func test_queued_wireString() {
        XCTAssertEqual(
            AgentQueueEventKinds.queued,
            "agent.message.queued",
            "iOS queue reducer keys on 'agent.message.queued'; changing this wire name silently breaks iOS queue append"
        )
    }

    /// WHY: "agent.message.queue.updated" is sent after every edit and reorder;
    /// iOS uses it to refresh position and text. A rename causes stale queue rows.
    func test_updated_wireString() {
        XCTAssertEqual(
            AgentQueueEventKinds.updated,
            "agent.message.queue.updated",
            "iOS queue reducer keys on 'agent.message.queue.updated'; changing this wire name silently stales queue rows"
        )
    }

    /// WHY: "agent.message.queue.drained" tells iOS the queue depth decreased;
    /// iOS uses it to collapse the queue indicator. A rename leaves the indicator stuck.
    func test_drained_wireString() {
        XCTAssertEqual(
            AgentQueueEventKinds.drained,
            "agent.message.queue.drained",
            "iOS queue reducer keys on 'agent.message.queue.drained'; changing this wire name leaves the iOS queue badge stuck"
        )
    }

    /// WHY: "agent.message.queue.cancelled" tells iOS to remove the cancelled
    /// row from its list. A rename orphans the cancelled row on iOS.
    func test_cancelled_wireString() {
        XCTAssertEqual(
            AgentQueueEventKinds.cancelled,
            "agent.message.queue.cancelled",
            "iOS queue reducer keys on 'agent.message.queue.cancelled'; changing this wire name orphans cancelled queue rows on iOS"
        )
    }

    // MARK: - Exhaustiveness: all four kinds are distinct

    /// WHY: if two constants share the same value, iOS cannot distinguish between
    /// events and would apply the wrong reducer action (e.g. drained == updated
    /// would make every edit collapse the queue).
    func test_allFourKindsAreDistinct() {
        let kinds: [String] = [
            AgentQueueEventKinds.queued,
            AgentQueueEventKinds.updated,
            AgentQueueEventKinds.drained,
            AgentQueueEventKinds.cancelled
        ]
        XCTAssertEqual(
            Set(kinds).count, kinds.count,
            "all four AgentQueueEventKinds must have distinct values; duplicates would merge unrelated reducer actions"
        )
    }
}
