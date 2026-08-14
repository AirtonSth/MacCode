import XCTest
import CoreModel
@testable import AgentRuntime

// Tests verify the two perf fixes in ClaudeAgentSDKBridgeAdapter:
//   (a) recoveredEventsPruneKeys: prune-eligibility logic is correct so abandoned
//       rolled-back threads do not accumulate in memory indefinitely.
//   (b) sdkInstallTimeoutSeconds / sdkInstallTimeoutNanoseconds: pure helpers are
//       consistent so the async Task.sleep matches the sync semaphore deadline.
// All helpers are nonisolated static — no adapter instantiation, no I/O, no MainActor.

final class ClaudeAgentSDKBridgeAdapterPerfTests: XCTestCase {

    // MARK: - recoveredEventsPruneKeys

    // WHY: A thread that was rolled back and never re-connected has no open session
    // and no pending re-use cursor. It must be eligible for pruning so recoveredEvents
    // does not grow without bound across repeated rollbacks of distinct threads.
    func test_pruneKeys_returnsAbandonedRolledBackThread() {
        let abandoned = AgentThreadID()
        let keys = ClaudeAgentSDKBridgeAdapter.recoveredEventsPruneKeys(
            recoveredKeys: [abandoned],
            openIds: [],
            pendingIds: []
        )
        XCTAssertEqual(keys, [abandoned],
            "A rolled-back thread with no open session and no pending cursor must be prunable")
    }

    // WHY: A thread that was rolled back AND has a pending re-use cursor (rollbackProviderThreadIds)
    // must NOT be pruned — it is about to be re-connected and its events are still needed.
    func test_pruneKeys_sparesPendingResumeThread() {
        let pending = AgentThreadID()
        let keys = ClaudeAgentSDKBridgeAdapter.recoveredEventsPruneKeys(
            recoveredKeys: [pending],
            openIds: [],
            pendingIds: [pending]
        )
        XCTAssertTrue(keys.isEmpty,
            "A rolled-back thread with a pending re-use cursor must not be pruned")
    }

    // WHY: A thread with an active session also has its events in recoveredEvents
    // (snapshot written at rollback before re-start). Must not be pruned.
    func test_pruneKeys_sparesOpenSession() {
        let open = AgentThreadID()
        let keys = ClaudeAgentSDKBridgeAdapter.recoveredEventsPruneKeys(
            recoveredKeys: [open],
            openIds: [open],
            pendingIds: []
        )
        XCTAssertTrue(keys.isEmpty,
            "A thread with an active session must not be pruned from recoveredEvents")
    }

    // WHY: mixed set — only the abandoned thread should be selected; open and pending must survive.
    func test_pruneKeys_selectsOnlyAbandonedFromMixedSet() {
        let abandoned1 = AgentThreadID()
        let abandoned2 = AgentThreadID()
        let open = AgentThreadID()
        let pending = AgentThreadID()

        let keys = ClaudeAgentSDKBridgeAdapter.recoveredEventsPruneKeys(
            recoveredKeys: [abandoned1, abandoned2, open, pending],
            openIds: [open],
            pendingIds: [pending]
        )
        XCTAssertEqual(keys, [abandoned1, abandoned2],
            "Only threads that are neither open nor pending should be selected for pruning")
    }

    // WHY: empty input must never crash or return garbage.
    func test_pruneKeys_emptyInputReturnsEmpty() {
        let keys = ClaudeAgentSDKBridgeAdapter.recoveredEventsPruneKeys(
            recoveredKeys: [],
            openIds: [],
            pendingIds: []
        )
        XCTAssertTrue(keys.isEmpty)
    }

    // MARK: - sdkInstallTimeout consistency

    // WHY: the Task.detached timeout guard and the continuation-based termination path
    // are both rooted in sdkInstallTimeoutSeconds(). If sdkInstallTimeoutNanoseconds()
    // diverges from that value the detached guard fires at a different wall-clock time,
    // leaving the continuation waiting beyond the intended limit.
    func test_installTimeoutNanosecondsIsConsistentWithSeconds() {
        let seconds = ClaudeAgentSDKBridgeAdapter.sdkInstallTimeoutSeconds()
        let nanoseconds = ClaudeAgentSDKBridgeAdapter.sdkInstallTimeoutNanoseconds()
        let expectedNs = UInt64(seconds * 1_000_000_000)
        XCTAssertEqual(nanoseconds, expectedNs,
            "Nanosecond timeout used by Task.detached must encode exactly the same wall-clock duration as sdkInstallTimeoutSeconds()")
    }

    // WHY: the timeout must be positive — a zero or negative value would bypass the
    // guard entirely and let npm installs run forever, re-introducing the pinned-thread bug.
    func test_installTimeoutSecondsIsPositive() {
        XCTAssertGreaterThan(
            ClaudeAgentSDKBridgeAdapter.sdkInstallTimeoutSeconds(), 0,
            "Install timeout must be > 0 so the async Task.sleep guard is meaningful")
    }

    // MARK: - decode-once SDK line ingest

    // WHY: handleLine used to JSONSerialization the same token line 3–4 times
    // (sdk_error probe, user_input_request, fromJSONLine, parseLine). Each
    // Claude SDK stdout line must decode once; extra parses allocate at token
    // rate without changing events.
    func test_interpretSDKLine_decodesJSONOnce() {
        ClaudeAgentSDKBridgeAdapter.sdkLineJSONDecodeCountForTesting = 0
        let line = #"{"type":"content_block_delta","index":0,"session_id":"sid","delta":{"type":"text_delta","text":"Hi"}}"#
        let parser = ClaudeParser()
        _ = parser.parseObject([
            "type": "system",
            "subtype": "init",
            "session_id": "sid",
        ], now: 1)
        _ = parser.parseObject([
            "type": "message_start",
            "message": ["id": "m1"],
        ], now: 1)
        _ = parser.parseObject([
            "type": "content_block_start",
            "index": 0,
            "content_block": ["type": "text", "id": "item0"],
        ], now: 1)
        ClaudeAgentSDKBridgeAdapter.sdkLineJSONDecodeCountForTesting = 0
        let interpretation = ClaudeAgentSDKBridgeAdapter.interpretSDKLine(line, parser: parser)
        XCTAssertEqual(
            ClaudeAgentSDKBridgeAdapter.sdkLineJSONDecodeCountForTesting, 1,
            "sdk_error + user-input + runtime + parser must share one JSONSerialization"
        )
        XCTAssertFalse(interpretation.isSDKError)
        XCTAssertNil(interpretation.userInputRequest)
        XCTAssertNil(
            interpretation.runtimeEvent,
            "token-rate deltas must not mint providerRuntime; itemDelta is the product event"
        )
        XCTAssertTrue(
            interpretation.parsedEvents.contains { event in
                if case .itemDelta(_, let body, _, _) = event { return body == "Hi" }
                return false
            },
            "decode-once must still surface the text delta: \(interpretation.parsedEvents)"
        )

        ClaudeAgentSDKBridgeAdapter.sdkLineJSONDecodeCountForTesting = 0
        let wrapped = #"{"type":"stream_event","session_id":"sid","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}}"#
        let wrappedInterp = ClaudeAgentSDKBridgeAdapter.interpretSDKLine(wrapped, parser: parser)
        XCTAssertEqual(ClaudeAgentSDKBridgeAdapter.sdkLineJSONDecodeCountForTesting, 1)
        XCTAssertNil(
            wrappedInterp.runtimeEvent,
            "SDK stream_event wrappers around content_block_delta must not mint providerRuntime"
        )
        XCTAssertTrue(
            wrappedInterp.parsedEvents.contains { event in
                if case .itemDelta(_, let body, _, _) = event { return body == "Hi" }
                return false
            },
            "wrapped delta must still surface itemDelta: \(wrappedInterp.parsedEvents)"
        )
    }

    func test_interpretSDKLine_detectsSDKErrorAndUserInputWithoutSecondParse() {
        ClaudeAgentSDKBridgeAdapter.sdkLineJSONDecodeCountForTesting = 0
        let errorLine = #"{"type":"sdk_error","message":"spawn claude ENOENT"}"#
        let error = ClaudeAgentSDKBridgeAdapter.interpretSDKLine(errorLine, parser: ClaudeParser())
        XCTAssertEqual(ClaudeAgentSDKBridgeAdapter.sdkLineJSONDecodeCountForTesting, 1)
        XCTAssertTrue(error.isSDKError)
        XCTAssertEqual(error.runtimeEvent?.method, "sdk_error")

        ClaudeAgentSDKBridgeAdapter.sdkLineJSONDecodeCountForTesting = 0
        let inputLine = #"{"type":"user_input_request","request_id":"q1","requested_schema":{"properties":{"a":{"type":"string"}}}}"#
        let input = ClaudeAgentSDKBridgeAdapter.interpretSDKLine(inputLine, parser: ClaudeParser())
        XCTAssertEqual(ClaudeAgentSDKBridgeAdapter.sdkLineJSONDecodeCountForTesting, 1)
        XCTAssertEqual(input.userInputRequest?.id, "q1")
        XCTAssertNotNil(input.userInputRequest?.requestedSchema)
        XCTAssertTrue(
            input.parsedEvents.contains { event in
                if case .userInputRequested(let request) = event { return request.id == "q1" }
                return false
            },
            "user_input_request must still become a parser event: \(input.parsedEvents)"
        )
    }
}
