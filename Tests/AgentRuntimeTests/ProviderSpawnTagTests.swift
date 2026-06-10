import XCTest
import Darwin
@testable import AgentRuntime

// Tests for the setpgid-based spawn tagging and periodic orphan sweep.
//
// WHY these tests exist:
//   Orphan provider processes were only swept at app launch (ppid==1 heuristic).
//   Processes spawned by claude --print / codex exec that detach mid-run escape
//   that heuristic because their ppid drifts before the next launch sweep.
//   setpgid(pid, 0) makes the child its own process-group leader; a periodic
//   sweeper can match by pgid even after reparenting, and the age gate prevents
//   killing a process that is legitimately still running its first turn.
final class ProviderSpawnTagTests: XCTestCase {

    // MARK: - SpawnedProcessTag construction

    func test_spawnedProcessTag_storesFields() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let tag = SpawnedProcessTag(pgid: 42, spawnedAt: now)

        XCTAssertEqual(tag.pgid, 42)
        XCTAssertEqual(tag.spawnedAt, now)
    }

    func test_spawnedProcessTag_equality() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let a = SpawnedProcessTag(pgid: 99, spawnedAt: now)
        let b = SpawnedProcessTag(pgid: 99, spawnedAt: now)
        let c = SpawnedProcessTag(pgid: 100, spawnedAt: now)

        XCTAssertEqual(a, b, "identical pgid+spawnedAt must be equal")
        XCTAssertNotEqual(a, c, "different pgid must not be equal")
    }

    // MARK: - isEligibleForReap: pure decision logic

    func test_eligibility_taggedOldAlive_isReapable() {
        // WHY: the core contract — a process tagged at spawn, older than minAge,
        // and still alive must be flagged for reap so the periodic sweeper kills it.
        let spawnedAt = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 60) // 60 s > 30 s defaultMinAge

        let eligible = ProcessSpawnTagger.isEligibleForReap(
            pgid: 1234,
            spawnedAt: spawnedAt,
            minAge: 30,
            isAlive: { _ in true },
            now: now
        )

        XCTAssertTrue(eligible, "tagged + old + alive must be reapable")
    }

    func test_eligibility_untagged_notReaped() {
        // WHY: processes NOT recorded by tagProcess have no SpawnedProcessTag entry
        // and therefore never appear in the sweeper's tag list — this test documents
        // that the sweeper is opt-in via tagging, not command-line heuristic.
        // The helper itself requires a tag to call, so an empty tag list produces
        // no reap candidates.
        let now = Date(timeIntervalSince1970: 60)

        let result = ProviderProcessSweeper.sweepTaggedOrphans(
            tags: [],   // no tags -> nothing eligible
            minAge: 30,
            isAlive: { _ in true },
            now: now,
            terminate: { _ in true }
        )

        XCTAssertTrue(result.orphanRootPIDs.isEmpty, "no tags -> no orphan candidates")
        XCTAssertTrue(result.terminatedPIDs.isEmpty)
    }

    func test_eligibility_fresh_notReaped() {
        // WHY: a process spawned < minAge ago must not be reaped — it may be actively
        // running its first turn. The age gate prevents killing live work.
        let spawnedAt = Date(timeIntervalSince1970: 50)
        let now = Date(timeIntervalSince1970: 60) // only 10 s old < 30 s minAge

        let eligible = ProcessSpawnTagger.isEligibleForReap(
            pgid: 777,
            spawnedAt: spawnedAt,
            minAge: 30,
            isAlive: { _ in true },
            now: now
        )

        XCTAssertFalse(eligible, "fresh process (age < minAge) must NOT be reapable")
    }

    func test_eligibility_dead_notReaped() {
        // WHY: a process that already exited must not be re-signalled — avoids
        // racing a recycled pid that belongs to an unrelated process.
        let spawnedAt = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 120)

        let eligible = ProcessSpawnTagger.isEligibleForReap(
            pgid: 888,
            spawnedAt: spawnedAt,
            minAge: 30,
            isAlive: { _ in false },
            now: now
        )

        XCTAssertFalse(eligible, "dead process must NOT be reapable (avoid pid recycling race)")
    }

    func test_eligibility_exactlyAtMinAge_isReapable() {
        // WHY: boundary condition — a process aged exactly minAge seconds is eligible.
        let spawnedAt = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 30) // exactly 30 s == minAge

        let eligible = ProcessSpawnTagger.isEligibleForReap(
            pgid: 555,
            spawnedAt: spawnedAt,
            minAge: 30,
            isAlive: { _ in true },
            now: now
        )

        XCTAssertTrue(eligible, "process aged exactly minAge must be reapable (>= boundary)")
    }

    // MARK: - sweepTaggedOrphans: periodic sweep integration

    func test_sweep_reapsMixedTagSet() {
        // WHY: validates that the periodic sweeper correctly separates eligible from
        // ineligible tags in a mixed batch (old vs fresh, alive vs dead).
        let base = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 120)

        let tags: [SpawnedProcessTag] = [
            SpawnedProcessTag(pgid: 10, spawnedAt: base),           // old + alive -> reap
            SpawnedProcessTag(pgid: 20, spawnedAt: Date(timeIntervalSince1970: 110)), // fresh -> skip
            SpawnedProcessTag(pgid: 30, spawnedAt: base),           // old + dead -> skip
        ]

        let aliveSet: Set<pid_t> = [10, 20] // 30 is dead
        var terminated: [pid_t] = []

        let result = ProviderProcessSweeper.sweepTaggedOrphans(
            tags: tags,
            minAge: 30,
            isAlive: { aliveSet.contains($0) },
            now: now,
            terminate: { pid in terminated.append(pid); return true }
        )

        XCTAssertEqual(result.orphanRootPIDs, [10],
                       "only the old+alive tag must be an orphan candidate")
        XCTAssertEqual(result.terminatedPIDs, [10],
                       "terminate must be called for the eligible pgid")
        XCTAssertFalse(terminated.contains(20), "fresh process must not be terminated")
        XCTAssertFalse(terminated.contains(30), "dead process must not be terminated (pid recycling guard)")
    }

    func test_sweep_terminateFailureRecordedInFailed() {
        // WHY: if killpg fails (e.g. EPERM) the pgid must appear in failedPIDs so
        // the caller can log/retry; it must NOT appear in terminatedPIDs.
        let base = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 120)
        let tags = [SpawnedProcessTag(pgid: 99, spawnedAt: base)]

        let result = ProviderProcessSweeper.sweepTaggedOrphans(
            tags: tags,
            minAge: 30,
            isAlive: { _ in true },
            now: now,
            terminate: { _ in false } // simulate killpg failure
        )

        XCTAssertEqual(result.orphanRootPIDs, [99])
        XCTAssertEqual(result.failedPIDs, [99], "failed terminate must be recorded in failedPIDs")
        XCTAssertTrue(result.terminatedPIDs.isEmpty)
    }

    func test_sweep_orphanRootPIDsAreSorted() {
        // WHY: deterministic output simplifies logging and idempotent retry logic.
        let base = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 120)
        let tags = [
            SpawnedProcessTag(pgid: 300, spawnedAt: base),
            SpawnedProcessTag(pgid: 100, spawnedAt: base),
            SpawnedProcessTag(pgid: 200, spawnedAt: base),
        ]

        let result = ProviderProcessSweeper.sweepTaggedOrphans(
            tags: tags,
            minAge: 30,
            isAlive: { _ in true },
            now: now,
            terminate: { _ in true }
        )

        XCTAssertEqual(result.orphanRootPIDs, [100, 200, 300],
                       "orphan root PIDs must be sorted ascending for deterministic output")
    }

    // MARK: - SpawnedProcessTag does not regress ProcessTerminator

    func test_terminationPlanUnaffectedBySpawnTagAddition() {
        // WHY: regression guard — SpawnedProcessTag/ProcessSpawnTagger additions must
        // not change the SIGTERM->SIGKILL plan used by terminateTree.
        let pids: [Int32] = [10, 20, 30]

        let phase1 = ProcessTerminator.terminationPlan(
            pids: pids,
            isAlive: { _ in true },
            graceElapsed: false
        )
        let phase2 = ProcessTerminator.terminationPlan(
            pids: pids,
            isAlive: { $0 == 20 },
            graceElapsed: true
        )

        XCTAssertEqual(phase1.map(\.signal), [SIGTERM, SIGTERM, SIGTERM],
                       "phase 1 must send SIGTERM to all pids (spawn tag must not affect this)")
        XCTAssertEqual(phase2, [ProcessTerminationStep(pid: 20, signal: SIGKILL)],
                       "phase 2 must SIGKILL only survivors (spawn tag must not affect this)")
    }
}
