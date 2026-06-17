import XCTest
import CoreModel
@testable import Surfaces

// Tests for AgentAppView.visibleTranscriptWindow(entries:status:runStartedAt:).
//
// WHY this matters: idle/completed threads render their transcript in an eager
// (non-Lazy) VStack, so a very long thread re-builds and re-lays-out its entire
// history on every routine SwiftUI invalidation (focus, hover, scroll, the
// one-shot completion tick). On a huge thread this saturates the main thread and
// reads as a permanent hang — the reported bug, which only manifests once a run
// COMPLETES (while running, the live-window filter hides old turns, so the same
// invalidations re-render a handful of rows and the app stays fast).
//
// The window seam must:
//  (a) bound the IDLE render to a recent tail so cost is O(window), not O(thread);
//  (b) ALWAYS keep the newest entries visible (the user must still see the latest
//      reply, e.g. the "translated from compressed output" message);
//  (c) leave the RUNNING-state time-cutoff window byte-identical (no regression);
//  (d) never silently drop history — the pre-window slice stays reachable via
//      hiddenTranscriptSlice + the existing reveal row.
final class VisibleTranscriptWindowTests: XCTestCase {

    private static let threadID = AgentThreadID()

    /// Message entry whose sortTime is `secondsSinceEpoch`.
    private func messageEntry(secondsSinceEpoch: TimeInterval) -> AgentAppView.TranscriptEntry {
        let msg = AgentMessage(
            id: AgentMessageID(UUID()),
            threadId: Self.threadID,
            role: .assistant,
            content: "m-\(secondsSinceEpoch)",
            createdAt: Date(timeIntervalSince1970: secondsSinceEpoch)
        )
        return .message(msg)
    }

    private func turnEntry(turnId: String, startMs: Int64) -> AgentAppView.TranscriptEntry {
        let turn = AssistantTurnSnapshot(
            turnId: turnId,
            items: [AssistantItem(id: "item-\(turnId)", turnId: turnId, type: .tool,
                                  state: .completed, summary: nil, body: "", startedAtMs: startMs)]
        )
        return .turn(turn)
    }

    // MARK: Idle windowing (the fix)

    func test_idleThread_longerThanWindow_rendersOnlyRecentTail() {
        // WHY (a): cost of an idle render must scale with the window, not the
        // whole thread, so a huge completed thread stops re-rendering in full.
        let total = 500
        let entries = (0..<total).map { messageEntry(secondsSinceEpoch: TimeInterval($0)) }

        let visible = AgentAppView.visibleTranscriptWindow(
            entries: entries, status: .completed, runStartedAt: nil
        )

        XCTAssertEqual(visible.count, AgentAppView.idleTranscriptWindowCount,
                       "idle thread must render only the bounded recent tail, not all \(total) entries")
        let hidden = AgentAppView.hiddenTranscriptSlice(allItems: entries, visibleWindow: visible)
        XCTAssertEqual(hidden.count, total - AgentAppView.idleTranscriptWindowCount,
                       "the pre-window slice must remain reachable via the reveal row, so no history is dropped")
    }

    func test_idleWindow_keepsTheNewestEntriesVisible() {
        // WHY (b): the latest reply (e.g. the translated final message) must stay
        // on screen — windowing trims the OLD prefix, never the recent tail.
        let total = 100
        let entries = (0..<total).map { messageEntry(secondsSinceEpoch: TimeInterval($0)) }

        let visible = AgentAppView.visibleTranscriptWindow(
            entries: entries, status: .completed, runStartedAt: nil
        )

        XCTAssertEqual(visible.map(\.id), Array(entries.suffix(AgentAppView.idleTranscriptWindowCount)).map(\.id),
                       "idle window must be the trailing slice (newest entries), in order")
        XCTAssertEqual(visible.last?.id, entries.last?.id,
                       "the newest entry must always be visible idle")
    }

    func test_idleThread_shorterThanWindow_rendersEverything() {
        // WHY: short/normal threads must be completely unaffected — no reveal row,
        // full thread shown, zero behavior change for the common case.
        let entries = (0..<10).map { messageEntry(secondsSinceEpoch: TimeInterval($0)) }

        let visible = AgentAppView.visibleTranscriptWindow(
            entries: entries, status: .completed, runStartedAt: nil
        )

        XCTAssertEqual(visible.map(\.id), entries.map(\.id),
                       "a thread at/under the window cap renders in full, unchanged")
        XCTAssertTrue(AgentAppView.hiddenTranscriptSlice(allItems: entries, visibleWindow: visible).isEmpty,
                      "no reveal row for short threads")
    }

    func test_idleThread_exactlyAtWindowCap_rendersEverything_boundary() {
        // WHY: the cap is an inclusive ceiling (strict `>` trigger). A thread of
        // exactly idleTranscriptWindowCount entries must render whole (no reveal
        // row); only one more entry should trim. Locks the off-by-one.
        let cap = AgentAppView.idleTranscriptWindowCount
        let atCap = (0..<cap).map { messageEntry(secondsSinceEpoch: TimeInterval($0)) }
        let overCap = (0..<(cap + 1)).map { messageEntry(secondsSinceEpoch: TimeInterval($0)) }

        let visibleAtCap = AgentAppView.visibleTranscriptWindow(
            entries: atCap, status: .completed, runStartedAt: nil
        )
        let visibleOverCap = AgentAppView.visibleTranscriptWindow(
            entries: overCap, status: .completed, runStartedAt: nil
        )

        XCTAssertEqual(visibleAtCap.count, cap, "exactly cap entries render whole, no trim")
        XCTAssertEqual(visibleOverCap.count, cap, "cap+1 entries trim to the cap")
        XCTAssertEqual(visibleOverCap.first?.id, overCap[1].id, "cap+1 trims exactly the oldest entry")
    }

    // MARK: Running path is unchanged (regression guard)

    func test_runningThread_keepsTimeCutoffLiveWindow_unchanged() {
        // WHY (c): the running-state window is the time cutoff (entries at/after
        // runStartedAt - slack); old turns are hidden. This must not regress.
        let started = Date(timeIntervalSince1970: 1_000)
        // Three "old" entries well before the run, two "live" entries after start.
        let old = (0..<3).map { turnEntry(turnId: "old-\($0)", startMs: Int64(($0 + 1) * 1_000)) }
        let live = [
            turnEntry(turnId: "live-0", startMs: Int64(started.timeIntervalSince1970 * 1_000)),
            turnEntry(turnId: "live-1", startMs: Int64((started.timeIntervalSince1970 + 5) * 1_000)),
        ]
        let entries = old + live

        let visible = AgentAppView.visibleTranscriptWindow(
            entries: entries, status: .running, runStartedAt: started
        )

        XCTAssertEqual(visible.map(\.id), live.map(\.id),
                       "running window must keep only entries at/after the run-start cutoff")
    }

    func test_runningThread_allEntriesBeforeCutoff_fallsBackToLastTwo() {
        // WHY (c): the running fallback (no live entries yet) is the last two
        // entries so the view is never empty at run start. Must not regress.
        let started = Date(timeIntervalSince1970: 10_000)
        let entries = (0..<5).map { turnEntry(turnId: "t-\($0)", startMs: Int64(($0 + 1) * 1_000)) }

        let visible = AgentAppView.visibleTranscriptWindow(
            entries: entries, status: .running, runStartedAt: started
        )

        XCTAssertEqual(visible.map(\.id), Array(entries.suffix(2)).map(\.id),
                       "running with no post-cutoff entries falls back to the last two")
    }

    func test_runningThread_withoutRunStartedAt_returnsAll_unchanged() {
        // WHY (c): idle windowing must NOT leak into the running state. A transient
        // running substate with no runStartedAt yet kept the full thread before the
        // fix; it must still do so (only non-running status is windowed).
        let entries = (0..<(AgentAppView.idleTranscriptWindowCount + 50))
            .map { messageEntry(secondsSinceEpoch: TimeInterval($0)) }

        let visible = AgentAppView.visibleTranscriptWindow(
            entries: entries, status: .running, runStartedAt: nil
        )

        XCTAssertEqual(visible.map(\.id), entries.map(\.id),
                       "running without runStartedAt must return all entries, never the idle window")
    }

    func test_runningThread_atMostTwoEntries_returnsAll_unchanged() {
        // WHY (c): the running window only engages past 2 entries; tiny threads
        // render whole even while running. Must not regress.
        let started = Date(timeIntervalSince1970: 10_000)
        let entries = [turnEntry(turnId: "only", startMs: 1_000)]

        let visible = AgentAppView.visibleTranscriptWindow(
            entries: entries, status: .running, runStartedAt: started
        )

        XCTAssertEqual(visible.map(\.id), entries.map(\.id),
                       "a 1-entry running thread renders in full, unchanged")
    }
}
