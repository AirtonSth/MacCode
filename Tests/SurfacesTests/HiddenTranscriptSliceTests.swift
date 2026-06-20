import XCTest
import CoreModel
@testable import Surfaces

// Tests for AgentAppView.hiddenTranscriptSlice(allItems:visibleWindow:).
// The helper is the pure seam extracted so users can audit earlier agent work
// while a run continues (P1: "N earlier transcript items hidden" reveal feature).
final class HiddenTranscriptSliceTests: XCTestCase {

    // MARK: Helpers

    private static let threadID = AgentThreadID()

    private func messageEntry(id: UUID = UUID(), secondsSinceEpoch: TimeInterval = 0) -> AgentAppView.TranscriptEntry {
        let msgID = AgentMessageID(id)
        let msg = AgentMessage(
            id: msgID,
            threadId: Self.threadID,
            role: .user,
            content: "msg-\(id.uuidString.prefix(8))",
            createdAt: Date(timeIntervalSince1970: secondsSinceEpoch)
        )
        return .message(msg)
    }

    private func turnEntry(turnId: String, startMs: Int64 = 0) -> AgentAppView.TranscriptEntry {
        let turn = AssistantTurnSnapshot(
            turnId: turnId,
            items: [AssistantItem(id: "item-\(turnId)", turnId: turnId, type: .tool,
                                  state: .completed, summary: nil, body: "", startedAtMs: startMs)]
        )
        return .turn(turn)
    }

    // MARK: Core slice invariants

    func test_hiddenSlice_returnsItemsNotInVisibleWindow_preservingOrder() {
        // WHY: the user must see older items in chronological order so audit
        // context reads naturally top-to-bottom.
        let old1 = messageEntry(secondsSinceEpoch: 1)
        let old2 = messageEntry(secondsSinceEpoch: 2)
        let live1 = messageEntry(secondsSinceEpoch: 100)
        let live2 = messageEntry(secondsSinceEpoch: 101)
        let all = [old1, old2, live1, live2]
        let visible = [live1, live2]

        let hidden = AgentAppView.hiddenTranscriptSlice(allItems: all, visibleWindow: visible)

        XCTAssertEqual(hidden.map(\.id), [old1.id, old2.id],
                       "hidden slice must be the pre-window entries in original order")
    }

    func test_hiddenSlice_emptyWhenNothingHidden() {
        // WHY: no "N earlier items" row should appear when the whole history
        // is already in the visible window (e.g. short thread, no run trim).
        let e1 = messageEntry()
        let e2 = messageEntry()
        let all = [e1, e2]
        let visible = [e1, e2]

        let hidden = AgentAppView.hiddenTranscriptSlice(allItems: all, visibleWindow: visible)

        XCTAssertTrue(hidden.isEmpty,
                      "slice must be empty when visible window covers all items")
    }

    func test_hiddenSlice_emptyForEmptyAll() {
        // WHY: guard against degenerate thread with zero entries.
        let hidden = AgentAppView.hiddenTranscriptSlice(allItems: [], visibleWindow: [])
        XCTAssertTrue(hidden.isEmpty)
    }

    func test_hiddenSlice_allItemsHiddenWhenVisibleWindowEmpty() {
        // WHY: if window is somehow empty, all earlier items should be
        // considered hidden so the button can offer to reveal them.
        let e1 = messageEntry()
        let e2 = messageEntry()
        let hidden = AgentAppView.hiddenTranscriptSlice(allItems: [e1, e2], visibleWindow: [])

        XCTAssertEqual(hidden.map(\.id), [e1.id, e2.id],
                       "all items are hidden when visible window is empty")
    }

    func test_hiddenSlice_mixedMessageAndTurnEntries() {
        // WHY: the transcript merges AgentMessage rows and AssistantTurnSnapshot
        // rows; the slice must handle both types correctly.
        let oldMsg = messageEntry(secondsSinceEpoch: 5)
        let oldTurn = turnEntry(turnId: "turn-old", startMs: 10_000)
        let liveMsg = messageEntry(secondsSinceEpoch: 200)
        let all = [oldMsg, oldTurn, liveMsg]
        let visible = [liveMsg]

        let hidden = AgentAppView.hiddenTranscriptSlice(allItems: all, visibleWindow: visible)

        XCTAssertEqual(hidden.count, 2,
                       "hidden slice must include both message and turn entries before the window")
        XCTAssertEqual(hidden[0].id, oldMsg.id)
        XCTAssertEqual(hidden[1].id, oldTurn.id)
    }

    func test_hiddenSlice_countMatchesDifferenceBetweenAllAndVisible() {
        // WHY: the row label reads "N earlier transcript items hidden";
        // N must equal allItems.count - visibleWindow.count when no
        // duplicates or out-of-range ids exist.
        let entries = (0..<10).map { messageEntry(secondsSinceEpoch: TimeInterval($0)) }
        let visible = Array(entries.suffix(3))

        let hidden = AgentAppView.hiddenTranscriptSlice(allItems: entries, visibleWindow: visible)

        XCTAssertEqual(hidden.count, 7,
                       "count must equal allItems.count - visibleWindow.count")
    }

    func test_collapsedHiddenCount_usesCountsOnlySoTypingDoesNotScanHugeThreads() {
        // WHY: each composer keystroke invalidates AgentAppView. When older
        // transcript history is still collapsed, the UI only needs the reveal
        // row's count; materializing the hidden prefix scans the whole thread
        // and makes large threads feel frozen while typing.
        let total = 250_000
        let visible = AgentAppView.idleTranscriptWindowCount

        let hiddenCount = AgentAppView.hiddenTranscriptCount(
            totalCount: total,
            visibleCount: visible
        )

        XCTAssertEqual(hiddenCount, total - visible,
                       "collapsed transcript count must be derived without constructing the hidden prefix")
    }

    func test_hiddenSlice_singleItemInVisibleWindow() {
        // WHY: boundary case — only the most-recent item is in the window
        // (suffix(1) fallback). All other items must be surfaced as hidden.
        let entries = (0..<5).map { messageEntry(secondsSinceEpoch: TimeInterval($0)) }
        let visible = [entries[4]]

        let hidden = AgentAppView.hiddenTranscriptSlice(allItems: entries, visibleWindow: visible)

        XCTAssertEqual(hidden.count, 4)
        XCTAssertEqual(hidden.map(\.id), entries.prefix(4).map(\.id),
                       "first 4 items must all be in the hidden slice")
    }
}
