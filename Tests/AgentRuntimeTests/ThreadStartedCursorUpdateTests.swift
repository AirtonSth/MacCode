import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: `.threadStarted` compiled the 26-column agent_threads row plus routing
/// JSON, then upserted the full row (rewriting routing) just to stamp
/// provider_thread_id.
final class ThreadStartedCursorUpdateTests: XCTestCase {
    func test_threadStarted_sourceUsesProviderThreadIdUpdateNotGetUpsert() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "case .threadStarted(let eventThreadId, let providerThreadId):"))
        let end = try XCTUnwrap(source.range(of: "case .providerRuntime(let runtimeEvent):"))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.updateProviderThreadId("))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadId)"))
        XCTAssertFalse(body.contains("threadRepo.upsert(thread)"))
    }

    func test_updateProviderThreadId_stampsCursorWithoutDurableGetOrRoutingRewrite() throws {
        let threadRepo = try makeThreadRepo("thread-started-cursor")
        let thread = fatThread(title: "live")
        try threadRepo.upsert(thread)
        let digest = thread.routingConfiguration?.policyDigest
        let getsBefore = threadRepo.durableGetCountForTesting
        let updatesBefore = threadRepo.updateProviderThreadIdCountForTesting

        try threadRepo.updateProviderThreadId(id: thread.id, providerThreadId: "sess-abc")

        XCTAssertEqual(threadRepo.updateProviderThreadIdCountForTesting, updatesBefore + 1)
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
        XCTAssertEqual(try threadRepo.providerThreadId(of: thread.id), "sess-abc")
        let stored = try XCTUnwrap(threadRepo.get(id: thread.id))
        XCTAssertEqual(stored.routingConfiguration?.policyDigest, digest)
        XCTAssertEqual(stored.title, "live")
        XCTAssertEqual(stored.status, .running)
        try threadRepo.updateProviderThreadId(id: AgentThreadID(), providerThreadId: "missing")
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore + 1)
    }

    func test_updateProviderThreadId_fasterThanGetAndUpsert() throws {
        let threadRepo = try makeThreadRepo("thread-started-bench")
        let thread = fatThread(title: "bench")
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
            try threadRepo.updateProviderThreadId(id: thread.id, providerThreadId: "sess-warm")
            if var copy = try threadRepo.get(id: thread.id) {
                copy.providerThreadId = "sess-warm"
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
                    try threadRepo.updateProviderThreadId(id: thread.id, providerThreadId: "sess-probe")
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    if var copy = try threadRepo.get(id: thread.id) {
                        copy.providerThreadId = "sess-get"
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
            "[perf-proof] thread-started updateProviderThreadId_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "updateProviderThreadId must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func fatThread(title: String) -> AgentThread {
        var thread = AgentThread(title: title, provider: .codex, model: "fake-model")
        thread.status = .running
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
