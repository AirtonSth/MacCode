import XCTest
import CoreModel
@testable import Surfaces

/// Freeze regressions for many open Agent App tabs / long sessions.
///
/// WHY: every AgentAppViewModel registers as an AgentRunObserver. Without an
/// early interest filter, one streaming tab forced N idle tabs to buffer events
/// and schedule MainActor flushes — saturating the UI after enough tabs/time.
final class AgentAppMultiTabFreezeSeamTests: XCTestCase {

    func test_acceptsStreamEvent_onlyWhenThreadMatchesInterest() {
        let a = AgentThreadID()
        let b = AgentThreadID()

        XCTAssertTrue(
            AgentAppViewModel.acceptsStreamEvent(eventThreadId: a, interestedThreadId: a),
            "the surface bound to the streaming thread must accept its events"
        )
        XCTAssertFalse(
            AgentAppViewModel.acceptsStreamEvent(eventThreadId: a, interestedThreadId: b),
            "sibling Agent App tabs must drop other threads' stream events before buffering"
        )
        XCTAssertFalse(
            AgentAppViewModel.acceptsStreamEvent(eventThreadId: a, interestedThreadId: nil),
            "fresh-composer surfaces with no selected thread must not buffer any stream"
        )
    }

    func test_streamEventBatch_preservesOrderForAcceptedThread() {
        // Guard PERF-MAC_AGENT-010 still holds when only matching events are appended.
        let batch = StreamEventBatch()
        let thread = AgentThreadID()
        let run = AgentRunID()
        let firstSchedule = batch.append(
            event: .itemDelta(itemId: "1", bodyAppend: "a", outputAppend: nil, summary: nil),
            run: run,
            threadId: thread
        )
        let secondSchedule = batch.append(
            event: .itemDelta(itemId: "1", bodyAppend: "b", outputAppend: nil, summary: nil),
            run: run,
            threadId: thread
        )
        XCTAssertTrue(firstSchedule, "first append of a tick must request a flush Task")
        XCTAssertFalse(secondSchedule, "later appends in the same tick must not allocate extra Tasks")

        let drained = batch.drain()
        XCTAssertEqual(drained.count, 2)
        XCTAssertEqual(drained.map(\.threadId), [thread, thread])
        if case let .itemDelta(_, body0, _, _) = drained[0].event {
            XCTAssertEqual(body0, "a")
        } else {
            XCTFail("expected first item delta")
        }
        if case let .itemDelta(_, body1, _, _) = drained[1].event {
            XCTAssertEqual(body1, "b")
        } else {
            XCTFail("expected second item delta")
        }
        XCTAssertTrue(batch.drain().isEmpty, "drain must reset the buffer for the next tick")
    }
}
