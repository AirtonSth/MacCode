import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: every run-finish persistTerminalGraph compiled the 26-column
/// agent_threads row plus routing JSON (and the 10-column agent_runs row
/// including error_message) just to stamp terminal status/unread/cursor.
final class TerminalGraphStampTests: XCTestCase {
    func test_persistTerminalGraph_sourceUsesChromeNotGet() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func persistTerminalGraph("))
        let end = try XCTUnwrap(source.range(of: "private func retryStartFailureCommit("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("adapterRecovery(of: threadId)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadId)"))
        XCTAssertFalse(body.contains("runRepo.get(id: runId)"))
    }

    func test_stampTerminal_preservesRoutingWithoutDurableGet() throws {
        let (threadRepo, runRepo) = try makeRepos("terminal-graph-stamp")
        var thread = AgentThread(title: "keep-title", provider: .codex, model: "keep-model")
        thread.providerThreadId = "sess-keep"
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "keep-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        try threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "keep-model",
            status: .running,
            errorMessage: String(repeating: "e", count: 8 * 1024)
        )
        try runRepo.upsert(run)
        let threadGetsBefore = threadRepo.durableGetCountForTesting
        let runGetsBefore = runRepo.durableGetCountForTesting
        let stampsBefore = threadRepo.stampTerminalCountForTesting

        try threadRepo.stampTerminal(
            id: thread.id,
            status: .completed,
            hasUnread: true,
            providerThreadId: "sess-done",
            at: Date(timeIntervalSince1970: 1_700_000_123)
        )
        XCTAssertTrue(try runRepo.stampTerminal(
            id: run.id,
            status: .completed,
            finishedAt: Date(timeIntervalSince1970: 1_700_000_123),
            errorMessage: "done",
            terminalReason: "completed"
        ))

        XCTAssertEqual(threadRepo.stampTerminalCountForTesting, stampsBefore + 1)
        XCTAssertEqual(threadRepo.durableGetCountForTesting, threadGetsBefore)
        XCTAssertEqual(runRepo.durableGetCountForTesting, runGetsBefore)
        let stored = try XCTUnwrap(threadRepo.get(id: thread.id))
        XCTAssertEqual(stored.title, "keep-title")
        XCTAssertEqual(stored.status, .completed)
        XCTAssertEqual(stored.hasUnread, true)
        XCTAssertEqual(stored.providerThreadId, "sess-done")
        XCTAssertEqual(stored.routingConfiguration?.policyDigest, thread.routingConfiguration?.policyDigest)
        let storedRun = try XCTUnwrap(runRepo.get(id: run.id))
        XCTAssertEqual(storedRun.status, .completed)
        XCTAssertEqual(storedRun.errorMessage, "done")
        XCTAssertEqual(storedRun.model, "keep-model")
        XCTAssertFalse(try runRepo.stampTerminal(
            id: AgentRunID(),
            status: .failed,
            finishedAt: Date(),
            errorMessage: nil,
            terminalReason: nil
        ))
    }

    func test_stampTerminal_fasterThanGetAndUpsert() throws {
        let (threadRepo, _) = try makeRepos("terminal-graph-stamp-bench")
        var thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        thread.routingConfiguration = AgentRoutingConfiguration(
            mode: .manual,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "fake-model"),
            policyDigest: String(repeating: "r", count: 32 * 1024)
        )
        try threadRepo.upsert(thread)
        let warmup = 3
        let samples = 5
        let iterations = 50
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
            try threadRepo.stampTerminal(
                id: thread.id, status: .completed, hasUnread: true, providerThreadId: "s", at: Date()
            )
            if var copy = try threadRepo.get(id: thread.id) {
                copy.status = .completed
                copy.hasUnread = true
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
                    try threadRepo.stampTerminal(
                        id: thread.id, status: .completed, hasUnread: true, providerThreadId: "s", at: Date()
                    )
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    if var copy = try threadRepo.get(id: thread.id) {
                        copy.status = .completed
                        copy.hasUnread = true
                        try threadRepo.upsert(copy)
                    }
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] terminal-graph-stamp stampTerminal_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "stampTerminal must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeRepos(_ label: String) throws -> (AgentThreadRepository, AgentRunRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (AgentThreadRepository(db: db), AgentRunRepository(db: db))
    }
}
