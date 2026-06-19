import XCTest
import CoreModel
@testable import Surfaces

// F7: AgentAppView.mergeTranscriptEntries must produce EXACTLY the same ordering
// as the canonical full sort it replaces — the O(N) merge is only allowed when it
// is provably identical, with a full-sort fallback otherwise.
final class MergeTranscriptEntriesTests: XCTestCase {

    private static let tid = AgentThreadID()

    private func msg(_ id: UUID, _ secs: TimeInterval) -> AgentMessage {
        AgentMessage(id: AgentMessageID(id), threadId: Self.tid, role: .user,
                     content: "m", createdAt: Date(timeIntervalSince1970: secs))
    }

    private func turn(_ turnId: String, _ startMs: Int64) -> AssistantTurnSnapshot {
        AssistantTurnSnapshot(turnId: turnId,
                              items: [AssistantItem(id: "i-\(turnId)", turnId: turnId, type: .tool, startedAtMs: startMs)])
    }

    private func reference(_ m: [AgentMessage], _ t: [AssistantTurnSnapshot]) -> [String] {
        (m.map(AgentAppView.TranscriptEntry.message) + t.map(AgentAppView.TranscriptEntry.turn))
            .sorted(by: AgentAppView.transcriptEntryOrdersBefore).map(\.id)
    }

    private func merged(_ m: [AgentMessage], _ t: [AssistantTurnSnapshot]) -> [String] {
        AgentAppView.mergeTranscriptEntries(messages: m, turns: t).map(\.id)
    }

    private func assertMatchesSort(_ m: [AgentMessage], _ t: [AssistantTurnSnapshot],
                                   _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(merged(m, t), reference(m, t), message, file: file, line: line)
    }

    func test_merge_interleavedDistinctTimestamps_matchesSort() {
        let m = [msg(UUID(), 1), msg(UUID(), 3), msg(UUID(), 5)]
        let t = [turn("a", 2000), turn("b", 4000)]   // sortTime = ms/1000 -> 2s, 4s
        assertMatchesSort(m, t, "fast-path merge of two ordered sides must interleave exactly like the full sort")
    }

    func test_merge_messageAndTurnShareSortTime_breaksTieByIdPrefix() {
        // A message and a turn at the same instant: id prefixes ("message-" < "turn-")
        // give a deterministic order that the merge must reproduce.
        let m = [msg(UUID(), 2)]
        let t = [turn("x", 2000)]
        assertMatchesSort(m, t, "equal-time message/turn tie must order identically to the canonical sort")
    }

    func test_merge_messagesOutOfIdOrderAtEqualTime_fallsBackToSort() {
        // Two messages at the SAME createdAt but supplied largest-id-first violates
        // canonical (sortTime, id) order, so the merge precondition fails and the
        // function must fall back to a full sort and still match exactly.
        let lo = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let hi = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let m = [msg(hi, 5), msg(lo, 5)]             // out of canonical order on purpose
        let t = [turn("a", 5000)]
        XCTAssertFalse(AgentAppView.isOrderedByTranscriptOrder(m.map(AgentAppView.TranscriptEntry.message)),
                       "precondition: the message side is intentionally out of canonical order")
        assertMatchesSort(m, t, "out-of-order ties must fall back to the full sort and remain identical")
    }

    func test_merge_emptySides() {
        assertMatchesSort([], [turn("a", 1000)], "empty messages must yield the turns in order")
        assertMatchesSort([msg(UUID(), 1)], [], "empty turns must yield the messages in order")
        assertMatchesSort([], [], "both empty must yield empty")
    }

    func test_merge_allMessagesBeforeAllTurns_andViceVersa() {
        let mEarly = [msg(UUID(), 1), msg(UUID(), 2)]
        let tLate = [turn("a", 10_000), turn("b", 11_000)]
        assertMatchesSort(mEarly, tLate, "non-overlapping ranges must concatenate in order")
        let mLate = [msg(UUID(), 100)]
        let tEarly = [turn("a", 1000)]
        assertMatchesSort(mLate, tEarly, "a turn entirely before a message must come first")
    }
}
