import XCTest
import CoreModel
@testable import Surfaces

/// PERF: validates the pure helper that decides which threads still need a
/// placeholder-title repair, enabling reloadThreads to skip messageRepo.list
/// for threads whose titles were already fixed this session.
///
/// WHY these assertions matter (Rule 8):
/// - A thread once repaired must NEVER re-appear in toRepair, otherwise every
///   reloadThreads call would re-issue a full messageRepo.list for it (the bug).
/// - A thread with a fresh placeholder title must appear in toRepair the first time,
///   otherwise newly created threads would never get their title fixed.
/// - A thread with a real (non-placeholder) title must be excluded unconditionally,
///   so the memoization set is not needed to prevent a spurious DB read for it.
final class PlaceholderRepairGuardTests: XCTestCase {

    // MARK: - Helpers

    private func thread(title: String) -> AgentThread {
        AgentThread(
            title: title,
            provider: .codex,
            model: "gpt-5.5"
        )
    }

    private func needsRepair(
        _ threads: [AgentThread],
        alreadyRepaired: Set<AgentThreadID> = []
    ) -> [Int] {
        AgentAppViewModel.indicesNeedingRepair(
            in: threads,
            alreadyRepaired: alreadyRepaired
        )
    }

    // MARK: - Tests

    /// A placeholder-titled thread not yet in the repaired set must appear in toRepair.
    /// WHY: if it were missing, the first reloadThreads would never fix its title.
    func test_newPlaceholder_isInToRepair() {
        let t = thread(title: AgentThreadTitle.defaultTitle)
        let indices = needsRepair([t])
        XCTAssertEqual(indices, [0],
                       "a fresh placeholder thread must be included so its title gets repaired")
    }

    /// A legacy-placeholder-titled thread must also appear in toRepair.
    /// WHY: both "New thread" and the legacy "Thread" string are placeholders;
    /// missing either means old threads are never renamed.
    func test_legacyPlaceholder_isInToRepair() {
        let t = thread(title: AgentThreadTitle.legacyDefaultTitle)
        let indices = needsRepair([t])
        XCTAssertEqual(indices, [0],
                       "legacy placeholder title must also trigger repair")
    }

    /// A thread whose id is already in the repaired set must NOT appear in toRepair,
    /// even when its title is still a placeholder string.
    /// WHY: this is the performance contract — once visited, never re-visit, so
    /// reloadThreads does not issue messageRepo.list for the same thread twice.
    func test_alreadyRepaired_isExcluded() {
        let t = thread(title: AgentThreadTitle.defaultTitle)
        let indices = needsRepair([t], alreadyRepaired: [t.id])
        XCTAssertTrue(indices.isEmpty,
                      "a thread already in the repaired set must be skipped to avoid a redundant DB read")
    }

    /// A thread with a real user-provided title must be excluded unconditionally,
    /// regardless of the repaired set.
    /// WHY: non-placeholder threads never need repair; checking isPlaceholder is the
    /// guard — the repaired set is an optimisation on top of it.
    func test_nonPlaceholder_isExcluded() {
        let t = thread(title: "Refactor the auth layer")
        let indices = needsRepair([t])
        XCTAssertTrue(indices.isEmpty,
                      "a thread with a real title needs no repair and must never trigger a messageRepo.list")
    }

    /// Mixed list: only the un-repaired placeholder indices are returned.
    /// WHY: verifies the filter applies correctly to each element independently
    /// so a repaired thread cannot cause a neighbour to be skipped.
    func test_mixedList_onlyUnrepairedPlaceholdersReturned() {
        let realTitle = thread(title: "Deploy pipeline fix")
        let placeholder1 = thread(title: AgentThreadTitle.defaultTitle)
        let placeholder2 = thread(title: AgentThreadTitle.defaultTitle)
        let alreadyDone = thread(title: AgentThreadTitle.defaultTitle)

        let threads = [realTitle, placeholder1, alreadyDone, placeholder2]
        let indices = needsRepair(threads, alreadyRepaired: [alreadyDone.id])

        XCTAssertEqual(Set(indices), [1, 3],
                       "only un-repaired placeholder indices must appear; real titles and already-repaired ids must both be excluded")
    }

    /// Empty thread list produces no indices. Sanity guard for the nil/empty case
    /// that can occur on first launch before any thread is created.
    func test_emptyList_returnsEmpty() {
        XCTAssertTrue(needsRepair([]).isEmpty,
                      "an empty thread list must never produce repair candidates")
    }
}
