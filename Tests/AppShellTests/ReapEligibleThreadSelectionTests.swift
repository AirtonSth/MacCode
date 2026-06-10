import XCTest
import CoreModel
@testable import AppShell

// Pins the reap-eligibility rule that decides which idle provider sessions get
// their adapter.stopSession called (so codex app-server / node-bridge processes
// are actually released, not just DB-marked stopped). WHY each assert matters is
// stated inline: the selection must mirror ProviderSessionReaper exactly
// (updated_at < cutoff AND not active), or live processes leak or get killed.
final class ReapEligibleThreadSelectionTests: XCTestCase {

    private func candidate(_ id: AgentThreadID, idleAt: Date, active: Bool) -> AppContext.ReapCandidate {
        AppContext.ReapCandidate(threadId: id, lastActivityAt: idleAt, isActive: active)
    }

    func test_selectsOnlyThreadsIdlePastCutoff_freshExcluded() {
        // WHY: a thread last active AFTER the cutoff is still warm; stopping its
        // session would kill a process the user may resume. Only stale threads
        // (activity strictly before cutoff) may be reaped/stopped.
        let cutoff = Date(timeIntervalSince1970: 1_000_000)
        let stale = AgentThreadID()
        let fresh = AgentThreadID()
        let selected = AppContext.reapEligibleThreadIds(
            candidates: [
                candidate(stale, idleAt: cutoff.addingTimeInterval(-60), active: false),
                candidate(fresh, idleAt: cutoff.addingTimeInterval(60), active: false)
            ],
            idleCutoff: cutoff
        )
        XCTAssertEqual(selected, [stale])
    }

    func test_activeIdleThreadIsExcluded_evenWhenStale() {
        // WHY: an active thread (running turn) must never have its session
        // stopped by the reaper, regardless of how old its session row is.
        let cutoff = Date(timeIntervalSince1970: 1_000_000)
        let activeStale = AgentThreadID()
        let selected = AppContext.reapEligibleThreadIds(
            candidates: [candidate(activeStale, idleAt: cutoff.addingTimeInterval(-10_000), active: true)],
            idleCutoff: cutoff
        )
        XCTAssertTrue(selected.isEmpty)
    }

    func test_boundaryActivityEqualToCutoffIsExcluded() {
        // WHY: the DB query uses strict `updated_at < cutoff`. A thread whose
        // last activity equals the cutoff must NOT be reaped, or the pure helper
        // and the reaper would disagree and stop a session the reaper kept.
        let cutoff = Date(timeIntervalSince1970: 1_000_000)
        let boundary = AgentThreadID()
        let selected = AppContext.reapEligibleThreadIds(
            candidates: [candidate(boundary, idleAt: cutoff, active: false)],
            idleCutoff: cutoff
        )
        XCTAssertTrue(selected.isEmpty)
    }

    func test_selectedSetIsExactlyTheThreadsThatGetStopped_mixedInput() {
        // WHY: the returned IDs are precisely the set fed to adapter.stopSession.
        // Mixed input proves the filter composes both rules (stale AND inactive)
        // and excludes every other combination.
        let cutoff = Date(timeIntervalSince1970: 1_000_000)
        let staleIdle = AgentThreadID()      // reaped
        let staleActive = AgentThreadID()    // kept (active)
        let freshIdle = AgentThreadID()      // kept (warm)
        let selected = Set(
            AppContext.reapEligibleThreadIds(
                candidates: [
                    candidate(staleIdle, idleAt: cutoff.addingTimeInterval(-1), active: false),
                    candidate(staleActive, idleAt: cutoff.addingTimeInterval(-1), active: true),
                    candidate(freshIdle, idleAt: cutoff.addingTimeInterval(1), active: false)
                ],
                idleCutoff: cutoff
            )
        )
        XCTAssertEqual(selected, [staleIdle])
    }
}
