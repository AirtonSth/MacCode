import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: launch reconciliation compiled every agent_threads row (26 columns +
/// routing JSON) just to interrupt leftover `running` shells, then upsert
/// rewrote routing. Scheduled Path B owners must stay running.
final class LaunchThreadReconcileProbeTests: XCTestCase {
    func test_reconcileOnLaunch_sourceUsesRunningUpdateNotFullList() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "public func reconcileOnLaunch(preservingThreadIDs:"))
        let end = try XCTUnwrap(source.range(of: "public func waitForForkReconciliation()"))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.reconcileRunningOnLaunch("))
        XCTAssertFalse(body.contains("threadRepo.list()"))
        XCTAssertFalse(body.contains("threadRepo.upsert(copy)"))
    }

    func test_reconcileOnLaunch_interruptsRunningWithoutListingCatalog() throws {
        let (coordinator, threadRepo, _) = try makeCoordinator("launch-list")
        let idle = fatThread(title: "idle", status: .completed)
        let pending = fatThread(title: "pending", status: .pending)
        let stale = fatThread(title: "stale-running", status: .running)
        let preserved = fatThread(title: "scheduled", status: .running)
        try threadRepo.upsert(idle)
        try threadRepo.upsert(pending)
        try threadRepo.upsert(stale)
        try threadRepo.upsert(preserved)
        let listsBefore = threadRepo.durableListCountForTesting
        let updatesBefore = threadRepo.reconcileRunningOnLaunchCountForTesting

        try coordinator.reconcileOnLaunch(preservingThreadIDs: [preserved.id])

        XCTAssertEqual(threadRepo.reconcileRunningOnLaunchCountForTesting, updatesBefore + 1)
        XCTAssertEqual(threadRepo.durableListCountForTesting, listsBefore)
        XCTAssertEqual(try threadRepo.status(of: idle.id), .completed)
        XCTAssertEqual(try threadRepo.status(of: pending.id), .pending)
        XCTAssertEqual(try threadRepo.status(of: stale.id), .interrupted)
        XCTAssertEqual(try threadRepo.get(id: stale.id)?.hasUnread, true)
        XCTAssertEqual(try threadRepo.status(of: preserved.id), .running)
        XCTAssertEqual(
            try threadRepo.get(id: stale.id)?.routingConfiguration?.policyDigest,
            idle.routingConfiguration?.policyDigest
        )
    }

    func test_reconcileRunningOnLaunch_fasterThanListAndUpsert() throws {
        let threadRepo = try makeThreadRepo("launch-bench")
        var idle: [AgentThread] = []
        idle.reserveCapacity(40)
        for index in 0..<40 {
            let thread = fatThread(title: "idle-\(index)", status: .completed)
            idle.append(thread)
            try threadRepo.upsert(thread)
        }
        let runningA = fatThread(title: "running-a", status: .running)
        let runningB = fatThread(title: "running-b", status: .running)
        try threadRepo.upsert(runningA)
        try threadRepo.upsert(runningB)
        let running = [runningA, runningB]
        let warmup = 3
        let samples = 5
        let iterations = 20
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func timeMs(_ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000.0
        }
        func restoreRunning() throws {
            for var thread in running {
                thread.status = .running
                thread.hasUnread = false
                try threadRepo.upsert(thread)
            }
        }
        for _ in 0..<warmup {
            try threadRepo.reconcileRunningOnLaunch(at: Date(), hasUnread: true)
            try restoreRunning()
            for thread in try threadRepo.list() where thread.status == .running {
                var copy = thread
                copy.status = .interrupted
                copy.hasUnread = true
                copy.updatedAt = Date()
                try threadRepo.upsert(copy)
            }
            try restoreRunning()
        }
        var probeSamples: [Double] = []
        var listSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        listSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    try threadRepo.reconcileRunningOnLaunch(at: Date(), hasUnread: true)
                    try restoreRunning()
                }
            })
            listSamples.append(try timeMs {
                for _ in 0..<iterations {
                    for thread in try threadRepo.list() where thread.status == .running {
                        var copy = thread
                        copy.status = .interrupted
                        copy.hasUnread = true
                        copy.updatedAt = Date()
                        try threadRepo.upsert(copy)
                    }
                    try restoreRunning()
                }
            })
        }
        let probeMed = median(probeSamples)
        let listMed = median(listSamples)
        let improvement = (listMed - probeMed) / listMed * 100.0
        NSLog(
            "[perf-proof] launch-thread reconcile_ms=%@ list+upsert_ms=%@ improvement_pct=%.2f probe=%@ list=%@",
            String(probeMed), String(listMed), improvement,
            String(describing: probeSamples),
            String(describing: listSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "launch thread UPDATE must beat list+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms list=\(listMed)ms)"
        )
    }

    private func fatThread(title: String, status: AgentRunStatus) -> AgentThread {
        var thread = AgentThread(title: title, provider: .codex, model: "fake-model")
        thread.status = status
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        return thread
    }

    private func makeThreadRepo(_ label: String) throws -> AgentThreadRepository {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return AgentThreadRepository(db: db)
    }

    private func makeCoordinator(
        _ label: String
    ) throws -> (AgentRunCoordinator, AgentThreadRepository, AgentRunRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [:]
        )
        return (coordinator, threadRepo, runRepo)
    }
}
