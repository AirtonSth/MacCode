import XCTest
@testable import Surfaces
import CoreModel

/// Covers AgentAppViewModel.reorderQueue(_:from:to:) pure helper.
/// No DB, no MainActor — the helper is nonisolated static.
///
/// WHY each test: queue reordering must never corrupt order or silently
/// swallow out-of-range drag operations (Rule 8 — test intent, not just
/// behavior).
final class QueueReorderTests: XCTestCase {

    // MARK: - Fixture

    private let threadId = AgentThreadID()

    private func makeQueue(count: Int) -> [AgentQueuedMessage] {
        (1...count).map { i in
            AgentQueuedMessage(
                threadId: threadId,
                text: "msg-\(i)",
                position: i
            )
        }
    }

    // MARK: - Move-down (from < to)

    func test_reorderQueue_moveDown_reordersCorrectly() {
        // [A,B,C,D] move index 0 -> 2  =>  [B,C,A,D]
        let q = makeQueue(count: 4)
        let result = AgentAppViewModel.reorderQueue(q, from: 0, to: 2)
        XCTAssertEqual(result.map { $0.text }, ["msg-2", "msg-3", "msg-1", "msg-4"],
                       "moving first item down two slots must produce correct intermediate order")
    }

    // MARK: - Move-up (from > to)

    func test_reorderQueue_moveUp_reordersCorrectly() {
        // [A,B,C,D] move index 3 -> 1  =>  [A,D,B,C]
        let q = makeQueue(count: 4)
        let result = AgentAppViewModel.reorderQueue(q, from: 3, to: 1)
        XCTAssertEqual(result.map { $0.text }, ["msg-1", "msg-4", "msg-2", "msg-3"],
                       "moving last item up two slots must place it at the target index")
    }

    // MARK: - No-op: same index

    func test_reorderQueue_sameIndex_isNoOp() {
        let q = makeQueue(count: 3)
        let result = AgentAppViewModel.reorderQueue(q, from: 1, to: 1)
        XCTAssertEqual(result.map { $0.text }, ["msg-1", "msg-2", "msg-3"],
                       "from == to must leave the queue unchanged (drag to same position)")
    }

    // MARK: - No-op: single item

    func test_reorderQueue_singleItem_isNoOp() {
        let q = makeQueue(count: 1)
        let result = AgentAppViewModel.reorderQueue(q, from: 0, to: 0)
        XCTAssertEqual(result.map { $0.text }, ["msg-1"],
                       "a one-item queue cannot be reordered and must survive the call intact")
    }

    // MARK: - Out-of-bounds: from too large

    func test_reorderQueue_outOfBoundsFrom_isNoOp() {
        let q = makeQueue(count: 3)
        let result = AgentAppViewModel.reorderQueue(q, from: 5, to: 0)
        XCTAssertEqual(result.map { $0.text }, ["msg-1", "msg-2", "msg-3"],
                       "out-of-bounds from index must not crash and must return queue unchanged")
    }

    // MARK: - Out-of-bounds: to too large

    func test_reorderQueue_outOfBoundsTo_isNoOp() {
        let q = makeQueue(count: 3)
        let result = AgentAppViewModel.reorderQueue(q, from: 0, to: 99)
        XCTAssertEqual(result.map { $0.text }, ["msg-1", "msg-2", "msg-3"],
                       "out-of-bounds to index must not crash and must return queue unchanged")
    }

    // MARK: - Count preserved

    func test_reorderQueue_preservesCount() {
        let q = makeQueue(count: 5)
        let result = AgentAppViewModel.reorderQueue(q, from: 0, to: 4)
        XCTAssertEqual(result.count, 5,
                       "reorder must never drop or duplicate items — message count must be invariant")
    }

    // MARK: - Identity preserved (no messages lost)

    func test_reorderQueue_preservesAllIdentities() {
        let q = makeQueue(count: 4)
        let originalIds = Set(q.map { $0.id })
        let result = AgentAppViewModel.reorderQueue(q, from: 2, to: 0)
        XCTAssertEqual(Set(result.map { $0.id }), originalIds,
                       "every message ID present before reorder must be present after — no silent drops")
    }
}
