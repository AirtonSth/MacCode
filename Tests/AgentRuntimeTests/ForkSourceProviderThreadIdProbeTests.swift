import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: fork reconcile compiled the 26-column agent_threads row plus routing
/// JSON just to copy the source provider_thread_id.
final class ForkSourceProviderThreadIdProbeTests: XCTestCase {
    private func makeRepos(_ label: String) throws -> AgentThreadRepository {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return AgentThreadRepository(db: db)
    }

    private func fatThread(title: String, providerThreadId: String?) -> AgentThread {
        var thread = AgentThread(title: title, provider: .codex, model: "fake-model")
        thread.providerThreadId = providerThreadId
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        return thread
    }

    func test_reconcileForkIntent_sourceUsesProviderThreadIdProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func reconcileForkIntent("))
        let end = try XCTUnwrap(source.range(of: "public func rollbackThread(threadId:"))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.providerThreadId(of: intent.sourceThreadId)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: intent.sourceThreadId)"))
    }

    func test_providerThreadIdProbe_matchesCursorWithoutDurableGet() throws {
        let threadRepo = try makeRepos("fork-cursor")
        let present = fatThread(title: "fork", providerThreadId: "sess-1")
        try threadRepo.upsert(present)
        let getsBefore = threadRepo.durableGetCountForTesting
        let probesBefore = threadRepo.providerThreadIdProbeCountForTesting
        XCTAssertEqual(try threadRepo.providerThreadId(of: present.id), "sess-1")
        XCTAssertEqual(threadRepo.providerThreadIdProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try threadRepo.providerThreadId(of: AgentThreadID()))
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
        let empty = fatThread(title: "empty", providerThreadId: nil)
        try threadRepo.upsert(empty)
        XCTAssertEqual(try threadRepo.providerThreadId(of: empty.id), "")
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
    }

    func test_providerThreadIdProbe_fasterThanDurableGet() throws {
        let threadRepo = try makeRepos("fork-cursor-bench")
        let thread = fatThread(title: "bench", providerThreadId: "sess-bench")
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
            _ = try threadRepo.providerThreadId(of: thread.id)
            _ = try threadRepo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.providerThreadId(of: thread.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.get(id: thread.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] fork-cursor providerThreadId_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "providerThreadId probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}
