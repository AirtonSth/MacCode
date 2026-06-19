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
        providerThreadId: String? = nil,
        activeTurnId: String? = nil,
        lastCompletedTurnId: String? = nil,
        lastAssistantUuid: String? = nil
    ) -> String {
        ClaudeStreamingCLIAdapter.snapshotStateSignature(
            model: model, turnCount: turnCount,
            pendingRequestIds: pending, pendingUserInputIds: userInput, inFlightToolIds: inFlight,
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

    func test_snapshotSignature_distinguishesAdjacentFields() {
        // WHY: the unit separator prevents a value from one field bleeding into the
        // next (e.g. providerThreadId "a" + activeTurnId "b" must not collide with
        // providerThreadId "ab" + activeTurnId "").
        XCTAssertNotEqual(signature(providerThreadId: "a", activeTurnId: "b"),
                          signature(providerThreadId: "ab", activeTurnId: ""),
                          "field boundaries must be unambiguous so distinct states never coalesce")
    }
}
