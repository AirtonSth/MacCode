import XCTest
import CoreModel
import Surfaces
@testable import AppShell

/// Desk chat contract: peer rows that arrive mid-turn (Mentions/From bubbles,
/// waiting indicators) split the live turn into chronological segments so the
/// timeline appends in arrival order instead of growing above the replies.
final class BotsDeskChatFlowTests: XCTestCase {

    private func item(_ id: String, ms: Int64) -> AssistantItem {
        AssistantItem(id: id, turnId: "t1", type: .tool, startedAtMs: ms)
    }

    private func peerMessage(
        _ text: String,
        direction: BotDeskPeer.Direction,
        secs: TimeInterval,
        phase: BotPeerActivityPhase? = nil
    ) -> BotDeskMessage {
        BotDeskMessage(
            role: direction == .messaged ? .user : .assistant,
            text: text,
            createdAt: Date(timeIntervalSince1970: secs),
            peer: BotDeskPeer(
                direction: direction,
                botID: BotID(),
                name: "Ceo",
                title: "CEO",
                handle: "ceo",
                avatarSymbol: "star.fill",
                activityPhase: phase
            )
        )
    }

    private func kinds(_ items: [BotDeskTimelineItem]) -> [String] {
        items.map { item in
            switch item {
            case .message: return "msg"
            case .workLog: return "log"
            case .liveTurn: return "turn"
            case .liveTurnSegment(let segment, _):
                return "seg(\(segment.snapshot.items.map(\.id).joined(separator: "+")))"
            }
        }
    }

    func test_interleavingTurnSegments_peerRowsSplitTheTurnInArrivalOrder() {
        let turn = AssistantTurnSnapshot(
            turnId: "t1",
            items: [item("ask", ms: 1_000), item("round2", ms: 60_000)],
            finalAssistantMessage: "done",
            finished: false,
            startedAtMs: 1_000
        )
        let reply = peerMessage("From Ceo reply", direction: .fromPeer, secs: 30)
        let items = BotsDeskFollowThrough.interleavingTurnSegments([
            .liveTurn(turn, hideAssistantOutput: true),
            .message(reply)
        ])
        XCTAssertEqual(kinds(items), ["seg(ask)", "msg", "seg(round2)"])
        guard case .liveTurnSegment(let first, let firstHide) = items[0],
              case .liveTurnSegment(let last, let lastHide) = items[2] else {
            return XCTFail("expected turn segments around the peer reply")
        }
        XCTAssertTrue(first.isFirst)
        XCTAssertNil(first.snapshot.finalAssistantMessage, "mid-turn slice must not repeat the final")
        XCTAssertFalse(firstHide, "mid-turn narration stays visible")
        XCTAssertTrue(last.isLast)
        XCTAssertEqual(last.snapshot.finalAssistantMessage, "done")
        XCTAssertTrue(lastHide, "the whole-turn dedup gate applies where the final paints")
        XCTAssertEqual(items[0].id, "turn-t1", "the turn head keeps its row identity when it splits")
    }

    func test_interleavingTurnSegments_plainMessagesAndWorkLogsDoNotSplit() {
        let turn = AssistantTurnSnapshot(
            turnId: "t1",
            items: [item("a", ms: 1_000), item("b", ms: 60_000)],
            finished: false,
            startedAtMs: 1_000
        )
        let plain = BotDeskMessage(
            role: .assistant,
            text: "unattributed",
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let unchanged: [BotDeskTimelineItem] = [
            .liveTurn(turn, hideAssistantOutput: false),
            .message(plain)
        ]
        XCTAssertEqual(kinds(BotsDeskFollowThrough.interleavingTurnSegments(unchanged)), ["turn", "msg"])
    }

    func test_deskTimeline_endToEnd_waitingPeerBubbleInterleavesLiveTurn() {
        // WHY: the reported disorder — the host keeps working after asking a
        // peer, and the new work painted above the Mentions/waiting bubble.
        let turn = AssistantTurnSnapshot(
            turnId: "t1",
            items: [item("before", ms: 10_000), item("after", ms: 90_000)],
            finished: false,
            startedAtMs: 10_000
        )
        let user = BotDeskMessage(
            role: .user,
            text: "compare php",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let ask = peerMessage("ask ceo", direction: .messaged, secs: 50, phase: .waiting)
        let items = BotsDeskFollowThrough.timeline(
            messages: [user, ask],
            workLog: [],
            turns: [turn],
            hideWorkLog: true,
            hideWorkingPlaceholder: true
        )
        XCTAssertEqual(
            kinds(items),
            ["msg", "seg(before)", "msg", "seg(after)"],
            "work after the ask paints below the waiting bubble, not above it"
        )
    }
}
