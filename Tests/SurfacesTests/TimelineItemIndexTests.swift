import XCTest
import CoreModel
@testable import Surfaces

/// PERF: validates the pure id -> (turnIndex, itemIndex) index used to make item
/// location O(1) during timeline replay, instead of the O(turns x items) linear
/// scan that AssistantTimelineState.mutateItem performs per itemDelta/itemState.
///
/// WHY these assertions matter (Rule 8 - intent, not tautology):
/// - lookup must return the SAME (turn, item) coordinates a linear scan would, or
///   replay would mutate the wrong item and corrupt the timeline.
/// - a miss must be nil (not a stale/zero coordinate), because itemDelta can arrive
///   before its itemStarted; the caller relies on nil to buffer a pending delta.
/// - insert/update must keep the index consistent as turns/items grow during replay,
///   otherwise the O(1) fast path silently diverges from ground truth.
final class TimelineItemIndexTests: XCTestCase {

    private func turn(_ id: String, items: [String]) -> AssistantTurnSnapshot {
        AssistantTurnSnapshot(
            turnId: id,
            items: items.map { AssistantItem(id: $0, turnId: id, type: .tool, startedAtMs: 0) }
        )
    }

    /// Linear-scan ground truth mirroring AssistantTimelineState.mutateItem's search.
    private func linearLookup(_ turns: [AssistantTurnSnapshot], _ iid: String) -> TimelineItemIndex.Location? {
        for ti in turns.indices {
            for ii in turns[ti].items.indices where turns[ti].items[ii].id == iid {
                return TimelineItemIndex.Location(turnIndex: ti, itemIndex: ii)
            }
        }
        return nil
    }

    func test_build_lookupMatchesLinearScanForEveryItem() {
        let turns = [
            turn("t0", items: ["a", "b"]),
            turn("t1", items: ["c"]),
            turn("t2", items: ["d", "e", "f"]),
        ]
        let index = TimelineItemIndex(turns: turns)
        // Every present id resolves to exactly the linear-scan coordinate.
        for t in turns {
            for item in t.items {
                XCTAssertEqual(index.location(of: item.id), linearLookup(turns, item.id),
                               "index lookup for \(item.id) must match linear scan")
            }
        }
        // Spot-check concrete coordinates so a wrong-but-self-consistent index is caught.
        XCTAssertEqual(index.location(of: "a"), .init(turnIndex: 0, itemIndex: 0))
        XCTAssertEqual(index.location(of: "c"), .init(turnIndex: 1, itemIndex: 0))
        XCTAssertEqual(index.location(of: "f"), .init(turnIndex: 2, itemIndex: 2))
    }

    func test_lookup_missReturnsNil() {
        let index = TimelineItemIndex(turns: [turn("t0", items: ["a"])])
        XCTAssertNil(index.location(of: "zzz"),
                     "absent id must be nil so caller buffers a pending delta instead of mutating item 0")
        XCTAssertNil(TimelineItemIndex(turns: []).location(of: "a"),
                     "empty timeline yields nil for any id")
    }

    func test_insertItem_appendsAtTailAndIsResolvable() {
        var turns = [turn("t0", items: ["a"])]
        var index = TimelineItemIndex(turns: turns)
        // Simulate itemStarted appending a new item to an existing turn.
        turns[0].items.append(AssistantItem(id: "b", turnId: "t0", type: .tool, startedAtMs: 0))
        index.insert(id: "b", turnIndex: 0, itemIndex: turns[0].items.count - 1)
        XCTAssertEqual(index.location(of: "b"), linearLookup(turns, "b"))
        XCTAssertEqual(index.location(of: "b"), .init(turnIndex: 0, itemIndex: 1))
        // Pre-existing entry is untouched.
        XCTAssertEqual(index.location(of: "a"), .init(turnIndex: 0, itemIndex: 0))
    }

    func test_insertNewTurn_thenLookupResolvesAcrossTurns() {
        var turns = [turn("t0", items: ["a"])]
        var index = TimelineItemIndex(turns: turns)
        turns.append(turn("t1", items: ["b"]))
        index.insert(id: "b", turnIndex: 1, itemIndex: 0)
        XCTAssertEqual(index.location(of: "b"), linearLookup(turns, "b"))
        XCTAssertEqual(index.location(of: "b"), .init(turnIndex: 1, itemIndex: 0))
    }

    func test_duplicateId_resolvesToFirstOccurrence_likeLinearScan() {
        // mutateItem returns on the FIRST match; the index must mirror that so a
        // duplicate id (defensive: should not happen, but must not diverge) is
        // handled identically.
        let turns = [
            turn("t0", items: ["dup"]),
            turn("t1", items: ["dup"]),
        ]
        let index = TimelineItemIndex(turns: turns)
        XCTAssertEqual(index.location(of: "dup"), linearLookup(turns, "dup"))
        XCTAssertEqual(index.location(of: "dup"), .init(turnIndex: 0, itemIndex: 0))
    }

    func test_fullTimeline_indexAgreesWithLinearScanAtScale() {
        // Sample timeline at scale: many turns x items, the exact shape that made
        // replay O(events x items). Index must agree with linear scan for all ids
        // and miss correctly - the perf win is O(1) per lookup vs O(turns x items).
        var turns: [AssistantTurnSnapshot] = []
        for t in 0..<200 {
            let ids = (0..<10).map { "i_\(t)_\($0)" }
            turns.append(turn("turn_\(t)", items: ids))
        }
        let index = TimelineItemIndex(turns: turns)
        for t in turns {
            for item in t.items {
                XCTAssertEqual(index.location(of: item.id), linearLookup(turns, item.id))
            }
        }
        XCTAssertNil(index.location(of: "i_999_9"))
    }
}
