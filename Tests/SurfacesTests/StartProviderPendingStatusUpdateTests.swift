import XCTest
@testable import Surfaces
import CoreModel
import Persistence
import AgentRuntime

/// WHY: composer send compiled the 26-column agent_threads row plus routing
/// JSON then upserted the full row (rewriting routing) just to mark status
/// pending before coordinator.startRun, which already stamps the same chrome.
@MainActor
final class StartProviderPendingStatusUpdateTests: XCTestCase {
    func test_startProviderRun_sourceUsesStatusUpdateNotGetUpsert() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "let req = AgentRunRequest("))
        let end = try XCTUnwrap(source.range(of: "let runId = try await coordinator.startRun("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.status(of: tid)"))
        XCTAssertTrue(body.contains("threadRepo.updateStatus("))
        XCTAssertFalse(body.contains("threadRepo.get(id: tid)"))
        XCTAssertFalse(body.contains("threadRepo.upsert(pendingThread)"))
        XCTAssertFalse(body.contains("threadRepo.upsert(rolled)"))
    }

    func test_updateStatus_marksPendingWithoutDurableGetOrRoutingRewrite() throws {
        let threadRepo = try makeThreadRepo("start-provider-pending")
        let thread = fatThread(title: "send", status: .completed)
        try threadRepo.upsert(thread)
        let digest = thread.routingConfiguration?.policyDigest
        let getsBefore = threadRepo.durableGetCountForTesting
        let updatesBefore = threadRepo.updateStatusCountForTesting
        let statusBefore = threadRepo.statusProbeCountForTesting

        XCTAssertNotNil(try threadRepo.status(of: thread.id))
        try threadRepo.updateStatus(
            id: thread.id,
            status: .pending,
            hasUnread: thread.hasUnread,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(threadRepo.statusProbeCountForTesting, statusBefore + 1)
        XCTAssertEqual(threadRepo.updateStatusCountForTesting, updatesBefore + 1)
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
        let stored = try XCTUnwrap(threadRepo.get(id: thread.id))
        XCTAssertEqual(stored.status, .pending)
        XCTAssertEqual(stored.hasUnread, true)
        XCTAssertEqual(stored.routingConfiguration?.policyDigest, digest)
        XCTAssertEqual(stored.title, "send")
        XCTAssertNil(try threadRepo.status(of: AgentThreadID()))
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore + 1)
    }

    func test_updateStatus_fasterThanGetAndUpsert() throws {
        let threadRepo = try makeThreadRepo("start-provider-pending-bench")
        let thread = fatThread(title: "bench", status: .completed)
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
        for _ in 0..<warmup {
            _ = try threadRepo.status(of: thread.id)
            try threadRepo.updateStatus(id: thread.id, status: .pending, hasUnread: false)
            if var copy = try threadRepo.get(id: thread.id) {
                copy.status = .pending
                copy.hasUnread = false
                copy.updatedAt = Date()
                try threadRepo.upsert(copy)
            }
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.status(of: thread.id)
                    try threadRepo.updateStatus(id: thread.id, status: .pending, hasUnread: false)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    if var copy = try threadRepo.get(id: thread.id) {
                        copy.status = .pending
                        copy.hasUnread = false
                        copy.updatedAt = Date()
                        try threadRepo.upsert(copy)
                    }
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] start-provider-pending status+updateStatus_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "status+updateStatus must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func fatThread(title: String, status: AgentRunStatus) -> AgentThread {
        var thread = AgentThread(title: title, provider: .codex, model: "fake-model")
        thread.status = status
        thread.hasUnread = true
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
