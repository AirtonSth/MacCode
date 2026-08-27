import XCTest
import CoreModel
@testable import Persistence

/// WHY: every run-finish persistTerminalGraph compiled the 26-column
/// agent_threads row plus routing JSON just to learn whether the thread exists.
final class TerminalGraphThreadExistenceProbeTests: XCTestCase {
    private func makeRepos(_ label: String) throws -> (
        AgentThreadRepository,
        AgentRunRepository
    ) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (
            AgentThreadRepository(db: db),
            AgentRunRepository(db: db)
        )
    }

    private func fatThread(title: String) -> AgentThread {
        var thread = AgentThread(title: title, provider: .codex, model: "fake-model")
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        return thread
    }

    func test_persistTerminalGraph_sourceUsesStatusProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Persistence/Repositories.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "public func persistTerminalGraph("))
        let end = try XCTUnwrap(source.range(of: "public func persistStreamBatch("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.status(of: thread.id)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: thread.id)"))
    }

    func test_statusProbe_matchesExistenceWithoutDurableGet() throws {
        let (threadRepo, _) = try makeRepos("terminal-exist")
        let thread = fatThread(title: "terminal")
        try threadRepo.upsert(thread)
        let getsBefore = threadRepo.durableGetCountForTesting
        let probesBefore = threadRepo.statusProbeCountForTesting
        XCTAssertNotNil(try threadRepo.status(of: thread.id))
        XCTAssertEqual(threadRepo.statusProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try threadRepo.status(of: AgentThreadID()))
        XCTAssertEqual(threadRepo.durableGetCountForTesting, getsBefore)
    }

    func test_statusProbe_fasterThanDurableGet() throws {
        let (threadRepo, _) = try makeRepos("terminal-bench")
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
            _ = try threadRepo.status(of: thread.id)
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
            "[perf-proof] terminal-graph status_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "status probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}
