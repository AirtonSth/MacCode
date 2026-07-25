import XCTest
@testable import AgentRuntime
import CoreModel

// Pure-helper coverage for the long-thread streaming perf fixes:
//   F8 — readable-event prune amortization (hysteresis)
//   F4 — session-snapshot coalesce signature
final class ClaudeStreamingAdapterPerfHelpersTests: XCTestCase {

    // MARK: F8 — prune hysteresis

    private func turnEvents(_ n: Int) -> [AssistantEvent] {
        (0..<n).map { .turnStarted(turnId: "t\($0)") }
    }

    func test_prunedReadableEvents_leavesBufferUntouchedWithinCapPlusSlack() {
        let cap = 5, slack = 4
        // WHY: once the buffer reaches the cap, the old prune re-copied the whole
        // cap-sized array on EVERY append. Returning nil here means no realloc — the
        // append stays O(1) until the buffer grows a full `slack` past the cap.
        XCTAssertNil(ClaudeStreamingCLIAdapter.prunedReadableEvents(turnEvents(cap), cap: cap, slack: slack),
                     "no prune (no O(cap) copy) while the buffer is at the cap")
        XCTAssertNil(ClaudeStreamingCLIAdapter.prunedReadableEvents(turnEvents(cap + slack), cap: cap, slack: slack),
                     "no prune until the buffer exceeds cap + slack")
    }

    func test_prunedReadableEvents_trimsBackToCapOnlyOncePastSlack() {
        let cap = 5, slack = 4
        let trimmed = ClaudeStreamingCLIAdapter.prunedReadableEvents(turnEvents(cap + slack + 1), cap: cap, slack: slack)
        XCTAssertEqual(trimmed?.count, cap,
                       "once it exceeds cap + slack the buffer trims back to exactly the cap, amortizing the copy over `slack` appends")
        // The trim keeps the newest events (suffix), so recent history is never lost.
        guard case .turnStarted(let lastId)? = trimmed?.last else {
            return XCTFail("expected a turnStarted event as the newest retained event")
        }
        XCTAssertEqual(lastId, "t\(cap + slack)",
                       "the prune keeps the newest events; the latest turn must survive")
    }

    // MARK: F4 — snapshot coalesce signature

    private func signature(
        model: String = "m",
        turnCount: Int = 0,
        pending: Set<String> = [],
        userInput: Set<String> = [],
        inFlight: Set<String> = [],
        backgroundTasks: Set<String> = [],
        providerThreadId: String? = nil,
        activeTurnId: String? = nil,
        lastCompletedTurnId: String? = nil,
        lastAssistantUuid: String? = nil
    ) -> String {
        ClaudeStreamingCLIAdapter.snapshotStateSignature(
            model: model, turnCount: turnCount,
            pendingRequestIds: pending, pendingUserInputIds: userInput, inFlightToolIds: inFlight,
            pendingBackgroundTaskIds: backgroundTasks,
            providerThreadId: providerThreadId, activeTurnId: activeTurnId,
            lastCompletedTurnId: lastCompletedTurnId, lastAssistantUuid: lastAssistantUuid
        )
    }

    func test_snapshotSignature_isStableAcrossSetInsertionOrder() {
        // WHY: the signature coalesces identical snapshots. It must NOT change just
        // because a Set yields its members in a different order, or every tool delta
        // would falsely look "changed" and re-broadcast (defeating the coalesce).
        let a = signature(inFlight: ["tool-a", "tool-b", "tool-c"])
        let b = signature(inFlight: ["tool-c", "tool-a", "tool-b"])
        XCTAssertEqual(a, b, "set order must not affect the coalesce signature")
    }

    func test_snapshotSignature_changesWhenAnyBroadcastFieldChanges() {
        // WHY: coalescing must never drop a snapshot whose state genuinely changed,
        // or the UI would show stale in-flight/turn state.
        let base = signature(turnCount: 1, inFlight: ["a"], activeTurnId: "turn-1")
        XCTAssertNotEqual(base, signature(turnCount: 2, inFlight: ["a"], activeTurnId: "turn-1"),
                          "a new completed turn must change the signature")
        XCTAssertNotEqual(base, signature(turnCount: 1, inFlight: ["a", "b"], activeTurnId: "turn-1"),
                          "a newly started tool must change the signature")
        XCTAssertNotEqual(base, signature(turnCount: 1, inFlight: [], activeTurnId: "turn-1"),
                          "a completed tool (in-flight cleared) must change the signature")
        XCTAssertNotEqual(base, signature(turnCount: 1, inFlight: ["a"], activeTurnId: "turn-2"),
                          "a turn transition must change the signature")
    }

    func test_snapshotSignature_changesWhenOnlyBackgroundWorkChanges() {
        // THE REPORTED GAP: the pending background-task set was in neither the
        // snapshot payload nor this signature, so a snapshot whose ONLY change was
        // "a background shell started / finished" coalesced away and was never
        // broadcast. Measured consequence: across 7,093 persisted snapshots in a
        // real user DB, the `background_work_pending` reason appeared ZERO times
        // (it is emitted right after a `turn_completed` snapshot, whose state
        // fields are identical) — so no UI could ever show running shells.
        // The turn-end state below is exactly that case: same turn/tool state,
        // different background work.
        let turnEnded = signature(turnCount: 1, inFlight: [], activeTurnId: nil)
        XCTAssertNotEqual(turnEnded, signature(turnCount: 1, inFlight: [], backgroundTasks: ["T1"], activeTurnId: nil),
                          "a background shell still running at turn end must change the signature, or the snapshot that reports it is coalesced away")
        XCTAssertNotEqual(signature(backgroundTasks: ["T1"]), signature(backgroundTasks: ["T1", "T2"]),
                          "a second background shell must change the signature so the chip count updates")
        XCTAssertNotEqual(signature(backgroundTasks: ["T1"]), signature(backgroundTasks: []),
                          "background work finishing must change the signature so the chip clears")
        XCTAssertEqual(signature(backgroundTasks: ["T1", "T2"]), signature(backgroundTasks: ["T2", "T1"]),
                       "set order must not change the signature (would defeat the coalesce)")
    }

    func test_snapshotSignature_distinguishesAdjacentFields() {
        // WHY: the unit separator prevents a value from one field bleeding into the
        // next (e.g. providerThreadId "a" + activeTurnId "b" must not collide with
        // providerThreadId "ab" + activeTurnId "").
        XCTAssertNotEqual(signature(providerThreadId: "a", activeTurnId: "b"),
                          signature(providerThreadId: "ab", activeTurnId: ""),
                          "field boundaries must be unambiguous so distinct states never coalesce")
    }
}
