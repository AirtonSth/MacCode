import XCTest
import Darwin
@testable import AgentRuntime

// Verifies the SIGTERM -> grace -> SIGKILL escalation plan that guarantees
// cancellation always wins, even against a child that traps/ignores SIGTERM.
final class ProcessTerminationPlanTests: XCTestCase {

    // Phase 1 (before grace): every pid in the tree gets SIGTERM, in the given
    // children-first order. WHY: graceful shutdown is attempted first so a
    // well-behaved process can flush/exit cleanly, and leaves must be signalled
    // before their parents.
    func testPhaseOneSendsSigtermToEveryPidInOrder() {
        let pids: [Int32] = [501, 502, 500]

        let plan = ProcessTerminator.terminationPlan(
            pids: pids,
            isAlive: { _ in true },
            graceElapsed: false
        )

        XCTAssertEqual(plan, [
            ProcessTerminationStep(pid: 501, signal: SIGTERM),
            ProcessTerminationStep(pid: 502, signal: SIGTERM),
            ProcessTerminationStep(pid: 500, signal: SIGTERM)
        ])
    }

    // Phase 2 (after grace): a survivor that ignored SIGTERM is escalated to
    // SIGKILL. WHY: this is the load-bearing guarantee -- cancel must terminate a
    // SIGTERM-trapping child, which the previous implementation could not do.
    func testPhaseTwoEscalatesSurvivorsToSigkill() {
        let survivor: Int32 = 502
        let pids: [Int32] = [501, survivor, 500]

        let plan = ProcessTerminator.terminationPlan(
            pids: pids,
            isAlive: { $0 == survivor },
            graceElapsed: true
        )

        XCTAssertEqual(plan, [ProcessTerminationStep(pid: survivor, signal: SIGKILL)])
    }

    // Phase 2: pids that already died during the grace window are skipped --
    // no SIGKILL is sent to them. WHY: avoids racing a reused pid (a recycled
    // pid could belong to an unrelated process; killing it would be a bug), and
    // proves the plan reflects real liveness rather than blindly re-signalling.
    func testPhaseTwoSkipsAlreadyDeadPids() {
        let pids: [Int32] = [501, 502, 500]

        let plan = ProcessTerminator.terminationPlan(
            pids: pids,
            isAlive: { _ in false },
            graceElapsed: true
        )

        XCTAssertTrue(plan.isEmpty, "Dead pids must not receive SIGKILL")
    }

    // Phase 2 with a mix: only the alive subset is escalated, dead ones skipped.
    // WHY: confirms filtering is per-pid, not all-or-nothing.
    func testPhaseTwoEscalatesOnlyAlivePidsInMixedTree() {
        let pids: [Int32] = [501, 502, 503, 500]
        let aliveSet: Set<Int32> = [502, 500]

        let plan = ProcessTerminator.terminationPlan(
            pids: pids,
            isAlive: { aliveSet.contains($0) },
            graceElapsed: true
        )

        XCTAssertEqual(plan, [
            ProcessTerminationStep(pid: 502, signal: SIGKILL),
            ProcessTerminationStep(pid: 500, signal: SIGKILL)
        ])
    }
}
