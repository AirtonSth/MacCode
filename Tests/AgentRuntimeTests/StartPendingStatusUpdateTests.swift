import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: every send compiled the 26-column agent_threads row plus routing JSON
/// then upserted the full row (rewriting routing) just to mark status pending.
final class StartPendingStatusUpdateTests: XCTestCase {
    func test_startRun_sourceUsesStatusUpdateNotGetUpsert() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "// persist run"))
        // The provider-session block that follows the thread status write
        // now reads only the runtime payload JSON (9df3c782b).
        let end = try XCTUnwrap(source.range(
            of: "let existingPayload = try repo.runtimePayloadJSON(of: effectiveRequest.threadId)",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.updateStatus("))
        XCTAssertFalse(body.contains("threadRepo.get(id: effectiveRequest.threadId)"))
        XCTAssertFalse(body.contains("threadRepo.upsert(thread)"))
    }

    func test_updateStatus_marksPendingWithoutDurableGetOrRoutingRewrite() throws {
        let threadRepo = try makeThreadRepo("start-pending")
        let thread = fatThread(title: "send", status: .completed)
        try threadRepo.upsert(thread)
        let digest = thread.routingConfiguration?.policyDigest
        let getsBefore = threadRepo.durableGetCountForTesting
        let updatesBefore = threadRepo.updateStatusCountForTesting

        try threadRepo.updateStatus(
            id: thread.id,
            status: .pending,
            hasUnread: false,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(threadRepo.updateStatusCountForTesting, updatesBefore + 1)
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
        let stored = try XCTUnwrap(threadRepo.get(id: thread.id))
        XCTAssertEqual(stored.status, .pending)
        XCTAssertEqual(stored.hasUnread, false)
        XCTAssertEqual(stored.routingConfiguration?.policyDigest, digest)
        XCTAssertEqual(stored.title, "send")
        try threadRepo.updateStatus(id: AgentThreadID(), status: .pending, hasUnread: false)
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore + 1)
    }

    func test_updateStatus_fasterThanGetAndUpsert() throws {
        let threadRepo = try makeThreadRepo("start-pending-bench")
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
            "[perf-proof] start-pending updateStatus_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "updateStatus must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
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
