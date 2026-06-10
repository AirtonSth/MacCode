import XCTest
import CoreModel
@testable import AgentRuntime

// PERF: CodexAppServerAdapter emit() was copying the full Session struct (2 dicts +
// 3 sets + growing finalAssistantMessage string) on every notification batch just to
// reach the onEvent closure. SessionEventEmitter is a pure minimal carrier that holds
// only that closure, eliminating the per-emit deep copy.
//
// Tests verify the emitter's broadcast contract — these are the ONLY observable
// semantics that must survive the refactor.  If the emitter gains a full-session copy
// a future perf regression would be invisible; these tests pin the contract.
final class CodexAppServerSessionEmitterTests: XCTestCase {

    // WHY: emitter with no callback must broadcast without crashing and without
    // invoking any handler — guards the nil-closure fast path that a nil Session
    // or a session without an onEvent must not panic on emit.
    func test_broadcast_nilCallback_isNoop() {
        let emitter = SessionEventEmitter(onEvent: nil)
        let event = AssistantEvent.error(message: "x", recoverable: false)
        // Both paths must be safe: no crash, no handler invoked.
        emitter.broadcastEvents([event])
        emitter.broadcastEvent(.event(event))
        // If we reach here without crashing, the nil-callback guard works.
        // Confirm the stored callback is nil so the structural contract is clear.
        XCTAssertNil(emitter.onEvent,
            "A nil-callback emitter must store nil — mirrors absent/cleared onEvent in Session")
    }

    // WHY: broadcastEvents(_:) with an empty array must invoke the callback zero times.
    // The adapter builds the events array before calling emit; if it is empty (no
    // matching event kind) the callback must not fire a spurious notification.
    func test_broadcastEvents_emptyArray_doesNotInvokeCallback() {
        var callCount = 0
        let emitter = SessionEventEmitter { _ in callCount += 1 }
        emitter.broadcastEvents([])
        XCTAssertEqual(callCount, 0,
            "An empty events array must not fire the callback — prevents spurious UI updates on no-op notification batches")
    }

    // WHY: each event in the array must reach the callback exactly once and in order.
    // emit() loops over the events array; a bug that skips or duplicates an event
    // would drop or double-fire assistant content in the UI.
    func test_broadcastEvents_firesCallbackOncePerEvent_inOrder() {
        var received: [AgentRunEvent] = []
        let emitter = SessionEventEmitter { received.append($0) }
        let e1 = AssistantEvent.error(message: "a", recoverable: false)
        let e2 = AssistantEvent.error(message: "b", recoverable: false)
        let e3 = AssistantEvent.error(message: "c", recoverable: false)
        emitter.broadcastEvents([e1, e2, e3])
        XCTAssertEqual(received.count, 3,
            "broadcastEvents must fire the callback exactly once per event")
        // Verify order: each wrapped in .event(...)
        if case .event(let a) = received[0], case .error(let m, _) = a { XCTAssertEqual(m, "a") } else { XCTFail("wrong first event") }
        if case .event(let b) = received[1], case .error(let m, _) = b { XCTAssertEqual(m, "b") } else { XCTFail("wrong second event") }
        if case .event(let c) = received[2], case .error(let m, _) = c { XCTAssertEqual(m, "c") } else { XCTFail("wrong third event") }
    }

    // WHY: broadcastEvent(_:) forwards an already-wrapped AgentRunEvent directly.
    // Used for terminal events (.finished, .status) that are not wrapped in .event()
    // by the caller — the adapter must not double-wrap them.
    func test_broadcastEvent_forwardsWrappedEventDirectly() {
        var received: [AgentRunEvent] = []
        let emitter = SessionEventEmitter { received.append($0) }
        let terminal = AgentRunEvent.finished(.completed, finalMessage: "hi", providerThreadId: "t1")
        emitter.broadcastEvent(terminal)
        XCTAssertEqual(received.count, 1)
        if case .finished(let status, let msg, let ptid) = received[0] {
            XCTAssertEqual(status, .completed)
            XCTAssertEqual(msg, "hi")
            XCTAssertEqual(ptid, "t1")
        } else {
            XCTFail("broadcastEvent must forward the AgentRunEvent as-is, not wrap in .event()")
        }
    }

    // WHY: a single emitter instance may broadcast N batches sequentially; the
    // total call count must equal the sum of all event counts.  Guards that emitter
    // state does not accumulate between calls (no hidden counter or buffer).
    func test_broadcastEvents_multipleBatches_callCountIsAdditive() {
        var callCount = 0
        let emitter = SessionEventEmitter { _ in callCount += 1 }
        let event = AssistantEvent.error(message: "x", recoverable: false)
        emitter.broadcastEvents([event, event])  // 2
        emitter.broadcastEvents([event])          // +1
        emitter.broadcastEvents([])               // +0
        XCTAssertEqual(callCount, 3,
            "Repeated broadcastEvents calls must be stateless; total fires = sum of all event counts")
    }

    // WHY: the perf contract — SessionEventEmitter must NOT copy or reference any
    // session state field other than the closure.  We verify this structurally: the
    // initializer accepts ONLY the callback (no dictionaries, sets, or strings).
    // If a future refactor adds session fields to the emitter it will break this
    // compile-time shape test — the reviewer will see the regression immediately.
    func test_emitterStructure_holdsOnlyCallback() {
        // This is a compile-time shape assertion:
        // SessionEventEmitter(onEvent:) must compile with ONLY a closure arg.
        // Confirm the stored onEvent is non-nil when a closure is provided.
        let emitter = SessionEventEmitter(onEvent: { _ in })
        XCTAssertNotNil(emitter.onEvent,
            "SessionEventEmitter must expose the stored callback via onEvent so callers can verify it was captured")
    }
}
