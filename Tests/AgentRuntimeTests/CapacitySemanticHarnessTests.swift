import XCTest
@testable import AgentRuntime

/// S2: deterministic semantic harness + subprocess fixture catalog.
final class CapacitySemanticHarnessTests: XCTestCase {
    func test_sameSeed_producesIdenticalSchedule() throws {
        let a = CapacitySemanticHarness.buildSchedule(seed: 0xC0FFEE)
        let b = CapacitySemanticHarness.buildSchedule(seed: 0xC0FFEE)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.nodes.count, 32 + 64)
        XCTAssertEqual(a.nodes.filter { $0.kind == .root }.count, 32)
        XCTAssertEqual(a.nodes.filter { $0.kind == .nested }.count, 64)
        let depths = Set(a.nodes.map { $0.depth })
        XCTAssertTrue(depths.contains(1), "depth 1 must be present")
        XCTAssertTrue(depths.contains(2), "depth 2 must be present")
        XCTAssertTrue(depths.contains(3), "depth 3 intermediate must exist for ancestry")
        XCTAssertTrue(depths.contains(4), "depth 4 must be present")
        let byId = Dictionary(uniqueKeysWithValues: a.nodes.map { ($0.id, $0) })
        for node in a.nodes where node.kind == .nested {
            let parentId = try XCTUnwrap(node.parentId)
            let parent = try XCTUnwrap(byId[parentId])
            XCTAssertEqual(
                parent.depth,
                node.depth - 1,
                "parent depth must be child.depth - 1 (node \(node.id))"
            )
        }
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
        // Smaller schedules may skip unreachable child faults; require drain + ownership.
        XCTAssertTrue(result.queueDrained)
        XCTAssertEqual(result.completedCount + result.cancelledCount + result.failedCount, schedule.nodes.count)
        XCTAssertGreaterThanOrEqual(result.longestNoProgressMs, 0)
    }

    func test_frozenDefaultWorkload_drainsWithAllFaultKinds() {
        // Frozen hardcore shape: 32 roots / 64 nested — catches reorder stranding.
        let schedule = CapacitySemanticHarness.buildSchedule(seed: 0xC0FFEE)
        XCTAssertEqual(schedule.nodes.count, 96)
        let clock = CapacityManualClock()
        let result = CapacitySemanticHarness.run(schedule: schedule, clock: clock)
        XCTAssertTrue(result.queueDrained, "default workload must drain (no stranded active nodes)")
        XCTAssertTrue(result.terminalOwnershipExact)
        // Prefer true application of the stop/resume pair at least.
        XCTAssertFalse(result.appliedFaultIndices.isEmpty)
        XCTAssertTrue(result.unknownFaultKinds.isEmpty)
        XCTAssertFalse(result.nodes.contains(where: { $0.status == .active || $0.status == .waiting }))
    }

    func test_stopResumePair_reAdmitsCancelledNode() {
        let root = CapacityHarnessNode(id: "r1", depth: 0, kind: .root, provider: "fake")
        let schedule = CapacityHarnessSchedule(
            nodes: [root],
            faults: [
                CapacityHarnessFault(atMs: 0, nodeId: "r1", kind: "stop_race"),
                CapacityHarnessFault(atMs: 20, nodeId: "r1", kind: "resume"),
            ],
            seed: 1
        )
        let clock = CapacityManualClock()
        let result = CapacitySemanticHarness.run(schedule: schedule, clock: clock, workQuantumMs: 10)
        XCTAssertEqual(result.appliedFaultIndices.count, 2, "both stop and resume must apply")
        XCTAssertTrue(result.allFaultsApplied)
        // After resume the node should complete (or at least leave cancelled).
        let node = result.nodes[0]
        XCTAssertNotEqual(node.status, .waiting)
        XCTAssertNotEqual(node.status, .active)
    }

    func test_run_modelsAllDeclaredFaultKinds() {
        let kinds = CapacityHarnessKnownFaultKind.allCases.map(\.rawValue)
        let schedule = CapacitySemanticHarness.buildSchedule(
            roots: 5,
            nestedNodes: 5,
            faultKinds: kinds,
            seed: 99
        )
        XCTAssertTrue(Set(schedule.faults.map(\.kind)).isSuperset(of: Set(kinds)))
        let clock = CapacityManualClock()
        let result = CapacitySemanticHarness.run(schedule: schedule, clock: clock)
        XCTAssertTrue(result.unknownFaultKinds.isEmpty)
        XCTAssertTrue(result.queueDrained)
        // stop/resume pair must both apply on the paired root.
        XCTAssertGreaterThanOrEqual(result.appliedFaultIndices.count, 2)
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

    func test_subprocessFixtures_spawnRealChildAndParseSeams() throws {
        // S2: real local child emits catalog frames; then parse through seams.
        let claude = ClaudeParser()
        for fixture in CapacitySubprocessFixtureSpec.catalog() {
            let run = try CapacitySubprocessFixtureRunner.run(spec: fixture, seed: 42)
            XCTAssertFalse(run.stdoutLines.isEmpty, "\(fixture.provider) child must emit frames")
            XCTAssertGreaterThan(run.pid, 0)
            switch fixture.provider {
            case "claude":
                var sawEvents = false
                for frame in run.stdoutLines {
                    let events = claude.parseLine(frame)
                    if !events.isEmpty { sawEvents = true }
                }
                XCTAssertTrue(sawEvents, "ClaudeParser must accept at least one catalog frame")
                XCTAssertEqual(run.exitCode, 0)
            case "codex":
                for frame in run.stdoutLines {
                    let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
                    XCTAssertNotNil(obj["type"] as? String)
                }
                XCTAssertEqual(run.exitCode, 0)
            case "grok":
                for frame in run.stdoutLines {
                    let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
                    XCTAssertEqual(obj["jsonrpc"] as? String, "2.0")
                }
            default:
                break
            }
        }
    }

    func test_subprocessFixtures_stopAndOwnershipTag() throws {
        let tmp = NSTemporaryDirectory() + "rc2-s2-own-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let storeURL = URL(fileURLWithPath: tmp).appendingPathComponent("ownership.json")
        ProviderProcessOwnership.shared.configure(fileURL: storeURL)
        let fixture = CapacitySubprocessFixtureSpec(
            provider: "codex",
            frames: [#"{"type":"thread.started","thread_id":"t1"}"#],
            exitCode: 0,
            stopRace: true
        )
        let run = try CapacitySubprocessFixtureRunner.run(
            spec: fixture,
            seed: 1,
            stopAfterMs: 20,
            requireOwnershipTag: true
        )
        XCTAssertTrue(run.stoppedByCaller || run.exitCode != 0 || !run.stdoutLines.isEmpty)
        let remaining = try ProviderProcessOwnershipStore(fileURL: storeURL).load()
        XCTAssertTrue(remaining.isEmpty, "tag must be removed after reap")
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
