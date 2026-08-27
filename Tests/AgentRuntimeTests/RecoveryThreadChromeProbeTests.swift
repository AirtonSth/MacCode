import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: recoverAdapterSessionIfNeeded compiled the 26-column agent_threads
/// row plus routing JSON on every open/read/stop without a live session,
/// including completed threads that return before any provider recovery.
final class RecoveryThreadChromeProbeTests: XCTestCase {
    func test_recoverAdapterSessionIfNeeded_sourceUsesAdapterRecoveryNotGet() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func recoverAdapterSessionIfNeeded("))
        let end = try XCTUnwrap(source.range(of: "private func recoveryEventRunId("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("adapterRecovery(of: threadId)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadId)"))
    }

    func test_adapterRecoveryProbe_matchesChromeWithoutDurableGet() throws {
        let repo = try makeRepo("recovery-thread-chrome")
        var thread = AgentThread(title: "live", provider: .codex, model: "keep-model")
        thread.status = .completed
        thread.worktreePath = "/tmp/keep"
        thread.providerInstanceId = "keep-instance"
        thread.reasoningEffort = .high
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "keep-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        try repo.upsert(thread)
        let getsBefore = repo.durableGetCountForTesting
        let probesBefore = repo.adapterRecoveryProbeCountForTesting

        let chrome = try XCTUnwrap(repo.adapterRecovery(of: thread.id))
        XCTAssertEqual(chrome.status, .completed)
        XCTAssertEqual(chrome.provider, .codex)
        XCTAssertEqual(chrome.providerInstanceId, "keep-instance")
        XCTAssertEqual(chrome.model, "keep-model")
        XCTAssertEqual(chrome.reasoningEffort, .high)
        XCTAssertEqual(chrome.worktreePath, "/tmp/keep")
        XCTAssertEqual(repo.adapterRecoveryProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try repo.adapterRecovery(of: AgentThreadID()))
        XCTAssertEqual(repo.durableGetCountForTesting, getsBefore)
    }

    func test_adapterRecoveryProbe_fasterThanDurableGet() throws {
        let repo = try makeRepo("recovery-thread-chrome-bench")
        var thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        thread.status = .completed
        thread.worktreePath = "/tmp/keep"
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        try repo.upsert(thread)
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
            _ = try repo.adapterRecovery(of: thread.id)
            _ = try repo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try repo.adapterRecovery(of: thread.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try repo.get(id: thread.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] recovery-thread-chrome adapterRecovery_ms=%@ get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "adapterRecovery probe must beat get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeRepo(_ label: String) throws -> AgentThreadRepository {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return AgentThreadRepository(db: db)
    }
}
