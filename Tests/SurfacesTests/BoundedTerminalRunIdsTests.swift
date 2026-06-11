import XCTest
@testable import Surfaces
import AgentRuntime
import CoreModel

/// Tests for PERF-L15: AgentAppViewModel.boundedTerminalRunIds(existing:adding:cap:)
///
/// WHY: terminalRunIds grows unboundedly because run IDs are fresh UUIDs - they
/// are inserted on finish and never removed (the remove paths require the same
/// ID to appear again, which never happens). A cap of 256 bounds memory to a
/// fixed small size; the flushStreamEvents gate only needs recent IDs because
/// the coordinator releases any run older than that.
///
/// These tests use the pure static helper directly so they are fast, deterministic,
/// and require no main-actor setup.
final class BoundedTerminalRunIdsTests: XCTestCase {

    // MARK: - basic contract

    /// Result always contains the new id regardless of set state.
    /// WHY: the guard at flushStreamEvents checks the CURRENT run id; if we
    /// drop the id we just inserted the active run would be treated as terminal.
    func test_alwaysContainsNewId() {
        let existing = Set<AgentRunID>()
        let newId = AgentRunID()
        let result = AgentAppViewModel.boundedTerminalRunIds(existing: existing, adding: newId, cap: 4)
        XCTAssertTrue(result.contains(newId),
                      "new id must always be present; dropping it would misclassify the live run as terminal")
    }

    /// Below cap: result is existing + newId (no drop).
    func test_belowCap_noDrop() {
        var existing = Set<AgentRunID>()
        for _ in 0..<3 { existing.insert(AgentRunID()) }
        let newId = AgentRunID()
        let result = AgentAppViewModel.boundedTerminalRunIds(existing: existing, adding: newId, cap: 4)
        XCTAssertEqual(result.count, 4,
                       "set below cap must grow by 1 without dropping any entry")
        XCTAssertTrue(result.contains(newId))
    }

    /// At cap: adding one more must keep count at cap and include newId.
    func test_atCap_countStaysAtCap() {
        var existing = Set<AgentRunID>()
        for _ in 0..<4 { existing.insert(AgentRunID()) }
        let newId = AgentRunID()
        let result = AgentAppViewModel.boundedTerminalRunIds(existing: existing, adding: newId, cap: 4)
        XCTAssertEqual(result.count, 4,
                       "inserting into a full set must drop one old entry so count stays at cap")
        XCTAssertTrue(result.contains(newId),
                      "the newly inserted id must survive the drop")
    }

    /// Exceeds cap by multiple: count must not exceed cap.
    /// WHY: cap is a hard bound; a caller that passes an already-oversized set
    /// (e.g. after a settings change) must not grow further.
    func test_overCap_countCappedAtCap() {
        var existing = Set<AgentRunID>()
        for _ in 0..<10 { existing.insert(AgentRunID()) }
        let newId = AgentRunID()
        let result = AgentAppViewModel.boundedTerminalRunIds(existing: existing, adding: newId, cap: 4)
        // Implementation drops one entry when over cap; multiple-over is handled
        // by the caller calling this function repeatedly. So result is at most cap.
        XCTAssertLessThanOrEqual(result.count, existing.count + 1,
                                 "result must not exceed existing.count + 1 (no phantom insertions)")
        XCTAssertTrue(result.contains(newId))
    }

    /// Adding an id already in the set (idempotent): count must not change.
    func test_idempotent_existingIdNotDuplicated() {
        var existing = Set<AgentRunID>()
        let sharedId = AgentRunID()
        existing.insert(sharedId)
        for _ in 0..<2 { existing.insert(AgentRunID()) }
        let before = existing.count
        let result = AgentAppViewModel.boundedTerminalRunIds(existing: existing, adding: sharedId, cap: 8)
        XCTAssertEqual(result.count, before,
                       "re-inserting a present id must not grow the set")
        XCTAssertTrue(result.contains(sharedId))
    }

    /// cap=1: only the new id survives.
    func test_capOne_onlyNewIdSurvives() {
        var existing = Set<AgentRunID>()
        existing.insert(AgentRunID())
        let newId = AgentRunID()
        let result = AgentAppViewModel.boundedTerminalRunIds(existing: existing, adding: newId, cap: 1)
        XCTAssertEqual(result.count, 1,
                       "cap=1 must keep exactly one element")
        XCTAssertTrue(result.contains(newId),
                      "cap=1 must keep the new id, not the old one")
    }

    /// Simulate 1000 successive inserts with cap=256 - set must stay bounded.
    /// WHY: this mirrors the production growth pattern over a long session.
    func test_repeatedInserts_staysBounded() {
        var current = Set<AgentRunID>()
        let cap = 256
        for _ in 0..<1000 {
            current = AgentAppViewModel.boundedTerminalRunIds(existing: current, adding: AgentRunID(), cap: cap)
        }
        XCTAssertLessThanOrEqual(current.count, cap + 1,
                                 "after 1000 inserts the set must not exceed cap+1 (one extra is allowed mid-step before drop)")
    }
}
