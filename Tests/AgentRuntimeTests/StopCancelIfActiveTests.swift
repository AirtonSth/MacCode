import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: Stop with no live handle compiled the 26-column agent_threads row
/// plus routing JSON, then upserted the full row (rewriting routing) just to
/// cancel leftover running/pending shells.
final class StopCancelIfActiveTests: XCTestCase {
    func test_markStopRequested_sourceUsesCancelIfActiveNotGetUpsert() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func markStopRequested(threadId: AgentThreadID, runId: AgentRunID?)"))
        let end = try XCTUnwrap(source.range(of: "public func forgetThread(_ threadId: AgentThreadID)"))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.cancelIfActive("))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadId)"))
        XCTAssertFalse(body.contains("threadRepo.upsert(thread)"))
    }

    func test_cancelIfActive_cancelsRunningPendingWithoutRewritingRouting() throws {
        let threadRepo = try makeThreadRepo("stop-cancel")
        let running = fatThread(title: "running", status: .running)
        let pending = fatThread(title: "pending", status: .pending)
        let completed = fatThread(title: "done", status: .completed)
        try threadRepo.upsert(running)
        try threadRepo.upsert(pending)
        try threadRepo.upsert(completed)
        let digest = running.routingConfiguration?.policyDigest
        let getsBefore = threadRepo.durableGetCountForTesting
        let cancelsBefore = threadRepo.cancelIfActiveCountForTesting

        try threadRepo.cancelIfActive(id: running.id, hasUnread: false)
        try threadRepo.cancelIfActive(id: pending.id, hasUnread: false)
        try threadRepo.cancelIfActive(id: completed.id, hasUnread: false)

        XCTAssertEqual(threadRepo.cancelIfActiveCountForTesting, cancelsBefore + 3)
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
        XCTAssertEqual(try threadRepo.status(of: running.id), .cancelled)
        XCTAssertEqual(try threadRepo.status(of: pending.id), .cancelled)
        XCTAssertEqual(try threadRepo.status(of: completed.id), .completed)
        let stored = try XCTUnwrap(threadRepo.get(id: running.id))
        XCTAssertEqual(stored.hasUnread, false)
        XCTAssertEqual(stored.routingConfiguration?.policyDigest, digest)
        try threadRepo.cancelIfActive(id: AgentThreadID(), hasUnread: false)
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore + 1)
    }

    func test_cancelIfActive_fasterThanGetAndUpsert() throws {
        let threadRepo = try makeThreadRepo("stop-cancel-bench")
        let thread = fatThread(title: "bench", status: .running)
        try threadRepo.upsert(thread)
        let warmup = 3
        let samples = 5
        let iterations = 200
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
            try threadRepo.updateStatus(id: thread.id, status: .running, hasUnread: false)
        }
        for _ in 0..<warmup {
            try threadRepo.cancelIfActive(id: thread.id, hasUnread: false)
            try restoreRunning()
            if var copy = try threadRepo.get(id: thread.id),
               copy.status == .running || copy.status == .pending {
                copy.status = .cancelled
                copy.hasUnread = false
                copy.updatedAt = Date()
                try threadRepo.upsert(copy)
            }
            try restoreRunning()
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    try threadRepo.cancelIfActive(id: thread.id, hasUnread: false)
                    try restoreRunning()
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    if var copy = try threadRepo.get(id: thread.id),
                       copy.status == .running || copy.status == .pending {
                        copy.status = .cancelled
                        copy.hasUnread = false
                        copy.updatedAt = Date()
                        try threadRepo.upsert(copy)
                    }
                    try restoreRunning()
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] stop-cancel cancelIfActive_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "cancelIfActive must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
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
}
