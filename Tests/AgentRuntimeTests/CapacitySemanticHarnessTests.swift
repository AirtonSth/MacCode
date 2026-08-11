import XCTest
@testable import AgentRuntime

/// S2: deterministic semantic harness + subprocess fixture catalog.
final class CapacitySemanticHarnessTests: XCTestCase {
    func test_sameSeed_producesIdenticalSchedule() {
        let a = CapacitySemanticHarness.buildSchedule(seed: 0xC0FFEE)
        let b = CapacitySemanticHarness.buildSchedule(seed: 0xC0FFEE)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.nodes.count, 32 + 64)
        XCTAssertEqual(a.nodes.filter { $0.kind == .root }.count, 32)
        XCTAssertEqual(a.nodes.filter { $0.kind == .nested }.count, 64)
        XCTAssertTrue(a.nodes.contains { $0.depth == 1 } || a.nodes.contains { $0.depth == 2 } || a.nodes.contains { $0.depth == 4 })
    }

    func test_differentSeeds_diverge() {
        let a = CapacitySemanticHarness.buildSchedule(seed: 1)
        let b = CapacitySemanticHarness.buildSchedule(seed: 2)
        XCTAssertNotEqual(a.nodes.map(\.id), b.nodes.map(\.id))
    }

    func test_run_drainsQueueAndRejoinsExactlyOnce() {
        let schedule = CapacitySemanticHarness.buildSchedule(roots: 8, nestedNodes: 16, seed: 42)
        let clock = CapacityManualClock(startMs: 0)
        let result = CapacitySemanticHarness.run(schedule: schedule, clock: clock)
        XCTAssertTrue(result.queueDrained)
        XCTAssertTrue(result.rejoinExactlyOnce)
        XCTAssertTrue(result.terminalOwnershipExact)
        XCTAssertEqual(result.completedCount + result.cancelledCount + result.failedCount, schedule.nodes.count)
        XCTAssertGreaterThanOrEqual(result.longestNoProgressMs, 0)
    }

    func test_run_cancelNodes_neverSpawnTerminalAsCompleted() {
        let schedule = CapacitySemanticHarness.buildSchedule(roots: 4, nestedNodes: 4, seed: 7)
        let cancel = Set(schedule.nodes.prefix(2).map(\.id))
        let clock = CapacityManualClock()
        let result = CapacitySemanticHarness.run(
            schedule: schedule,
            clock: clock,
            cancelNodeIds: cancel
        )
        for node in result.nodes where cancel.contains(node.id) {
            XCTAssertEqual(node.status, .cancelled)
        }
        XCTAssertTrue(result.queueDrained)
    }

    func test_subprocessFixtureCatalog_coversThreeProviders() {
        let catalog = CapacitySubprocessFixtureSpec.catalog()
        XCTAssertEqual(Set(catalog.map(\.provider)), Set(["claude", "codex", "grok"]))
        let seed: UInt64 = 99
        let framesA = catalog[1].materializedFrames(seed: seed)
        let framesB = catalog[1].materializedFrames(seed: seed)
        XCTAssertEqual(framesA, framesB, "materialized frames must be seed-stable")
        XCTAssertTrue(catalog[2].materializedFrames(seed: seed).contains("[[rc:stop_race]]"))
    }

    func test_manualClock_advancesDeterministically() {
        let clock = CapacityManualClock(startMs: 10)
        XCTAssertEqual(clock.nowMs, 10)
        clock.advance(byMs: 5)
        XCTAssertEqual(clock.nowMs, 15)
        clock.advance(byMs: -3)
        XCTAssertEqual(clock.nowMs, 15, "negative advance is a no-op")
    }
}
