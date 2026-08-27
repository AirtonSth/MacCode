import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: start-gate ghost-live reconcile compiled the 26-column agent_threads
/// row plus routing JSON just to copy status and provider_thread_id.
final class GhostLiveTerminalProbeTests: XCTestCase {
    private func makeRepos(_ label: String) throws -> AgentThreadRepository {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return AgentThreadRepository(db: db)
    }

    private func fatThread(
        title: String,
        status: AgentRunStatus,
        providerThreadId: String?
    ) -> AgentThread {
        var thread = AgentThread(title: title, provider: .codex, model: "fake-model")
        thread.status = status
        thread.providerThreadId = providerThreadId
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        return thread
    }

    func test_ghostLiveReconcile_sourceUsesStatusAndProviderThreadIdProbes() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(
            source.range(of: "private func reconcileGhostLiveProviderSessionIfDurableTerminal(")
        )
        let end = try XCTUnwrap(source.range(of: "public func releaseProviderSession(threadId:"))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.status(of: threadId)"))
        XCTAssertTrue(body.contains("threadRepo.providerThreadId(of: threadId)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadId)"))
    }

    func test_statusAndProviderThreadIdProbes_matchGhostChromeWithoutDurableGet() throws {
        let threadRepo = try makeRepos("ghost-chrome")
        let present = fatThread(title: "ghost", status: .completed, providerThreadId: "sess-1")
        try threadRepo.upsert(present)
        let getsBefore = threadRepo.durableGetCountForTesting
        let statusBefore = threadRepo.statusProbeCountForTesting
        let cursorBefore = threadRepo.providerThreadIdProbeCountForTesting
        XCTAssertEqual(try threadRepo.status(of: present.id), .completed)
        XCTAssertEqual(try threadRepo.providerThreadId(of: present.id), "sess-1")
        XCTAssertEqual(threadRepo.statusProbeCountForTesting, statusBefore + 1)
        XCTAssertEqual(threadRepo.providerThreadIdProbeCountForTesting, cursorBefore + 1)
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try threadRepo.status(of: AgentThreadID()))
        XCTAssertNil(try threadRepo.providerThreadId(of: AgentThreadID()))
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
        let empty = fatThread(title: "empty", status: .cancelled, providerThreadId: nil)
        try threadRepo.upsert(empty)
        XCTAssertEqual(try threadRepo.status(of: empty.id), .cancelled)
        XCTAssertEqual(try threadRepo.providerThreadId(of: empty.id), "")
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
    }

    func test_statusAndProviderThreadIdProbes_fasterThanDurableGet() throws {
        let threadRepo = try makeRepos("ghost-bench")
        let thread = fatThread(title: "bench", status: .completed, providerThreadId: "sess-bench")
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
                    _ = try threadRepo.status(of: thread.id)
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
            "[perf-proof] ghost-live status+providerThreadId_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "status+providerThreadId probes must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}
