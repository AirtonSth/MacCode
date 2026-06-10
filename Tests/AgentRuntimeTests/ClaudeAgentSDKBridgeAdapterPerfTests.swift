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
}
