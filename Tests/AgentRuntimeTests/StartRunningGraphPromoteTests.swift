import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: after sendTurn, startRun compiled a 10-column agent_runs row
/// (including error_message) plus a 26-column thread row and routing JSON,
/// then upserted the full graph just to flip pending → running.
final class StartRunningGraphPromoteTests: XCTestCase {
    func test_startRun_sourcePromotesWithoutGetUpsert() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "// `sendTurn` returning is the first provider-independent proof"))
        let end = try XCTUnwrap(source.range(of: "let terminalStatus = (try? runRepo.status(of: runId))"))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("runRepo.promotePendingStartToRunning("))
        XCTAssertFalse(body.contains("runRepo.get(id: runId)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: effectiveRequest.threadId)"))
        XCTAssertFalse(body.contains("persistActiveGraph("))
    }

    func test_promotePendingStartToRunning_flipsPendingWithoutRewritingBlobs() throws {
        let (threadRepo, runRepo, sessionRepo) = try makeRepos("promote-running")
        let thread = fatThread(title: "send", status: .pending)
        try threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .pending,
            errorMessage: String(repeating: "e", count: 32 * 1024)
        )
        try runRepo.upsert(run)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .pending,
            lastEventKind: "run.pending",
            lastErrorMessage: "keep-me",
            runtimePayloadJSON: String(repeating: "p", count: 8 * 1024)
        ))
        let digest = thread.routingConfiguration?.policyDigest
        let runGetsBefore = runRepo.durableGetCountForTesting
        let threadGetsBefore = threadRepo.durableGetCountForTesting
        let promotesBefore = runRepo.promotePendingStartToRunningCountForTesting

        XCTAssertTrue(try runRepo.promotePendingStartToRunning(runId: run.id, threadId: thread.id))

        XCTAssertEqual(runRepo.promotePendingStartToRunningCountForTesting, promotesBefore + 1)
        XCTAssertEqual(runRepo.durableGetCountForTesting, runGetsBefore)
        XCTAssertEqual(threadRepo.durableGetCountForTesting, threadGetsBefore)
        XCTAssertEqual(try runRepo.status(of: run.id), .running)
        XCTAssertEqual(try runRepo.errorMessage(of: run.id), String(repeating: "e", count: 32 * 1024))
        let storedThread = try XCTUnwrap(threadRepo.get(id: thread.id))
        XCTAssertEqual(storedThread.status, .running)
        XCTAssertEqual(storedThread.routingConfiguration?.policyDigest, digest)
        let storedSession = try XCTUnwrap(sessionRepo.get(threadId: thread.id))
        XCTAssertEqual(storedSession.status, .running)
        XCTAssertEqual(storedSession.lastEventKind, "run.started")
        XCTAssertEqual(storedSession.lastErrorMessage, "keep-me")
        XCTAssertEqual(storedSession.runtimePayloadJSON, String(repeating: "p", count: 8 * 1024))

        var finished = run
        finished.status = .completed
        finished.finishedAt = Date()
        try runRepo.upsert(finished)
        XCTAssertFalse(try runRepo.promotePendingStartToRunning(runId: run.id, threadId: thread.id))
        XCTAssertEqual(try runRepo.status(of: run.id), .completed)
    }

    func test_promotePendingStartToRunning_fasterThanGetAndPersistActiveGraph() throws {
        let (threadRepo, runRepo, sessionRepo) = try makeRepos("promote-bench")
        let thread = fatThread(title: "bench", status: .pending)
        try threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .pending,
            errorMessage: String(repeating: "e", count: 32 * 1024)
        )
        try runRepo.upsert(run)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .pending,
            lastEventKind: "run.pending",
            runtimePayloadJSON: String(repeating: "p", count: 8 * 1024)
        ))
        let warmup = 2
        let samples = 5
        let iterations = 10
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
        let pendingSession = ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .pending,
            lastEventKind: "run.pending",
            runtimePayloadJSON: String(repeating: "p", count: 8 * 1024)
        )
        func restorePending() throws {
            var pendingRun = run
            pendingRun.status = .pending
            try runRepo.upsert(pendingRun)
            var pendingThread = thread
            pendingThread.status = .pending
            try threadRepo.upsert(pendingThread)
            try sessionRepo.upsert(pendingSession)
        }
        for _ in 0..<warmup {
            _ = try runRepo.promotePendingStartToRunning(runId: run.id, threadId: thread.id)
            try restorePending()
            if var startedRun = try runRepo.get(id: run.id), startedRun.status == .pending {
                startedRun.status = .running
                var startedThread = try threadRepo.get(id: thread.id)
                startedThread?.status = .running
                startedThread?.updatedAt = Date()
                var startedSession = try sessionRepo.get(threadId: thread.id)
                startedSession?.status = .running
                startedSession?.lastEventKind = "run.started"
                startedSession?.updatedAt = Date()
                try runRepo.persistActiveGraph(
                    run: startedRun,
                    thread: startedThread,
                    providerSession: startedSession
                )
            }
            try restorePending()
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try runRepo.promotePendingStartToRunning(runId: run.id, threadId: thread.id)
                    try restorePending()
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    if var startedRun = try runRepo.get(id: run.id), startedRun.status == .pending {
                        startedRun.status = .running
                        var startedThread = try threadRepo.get(id: thread.id)
                        startedThread?.status = .running
                        startedThread?.updatedAt = Date()
                        var startedSession = try sessionRepo.get(threadId: thread.id)
                        startedSession?.status = .running
                        startedSession?.lastEventKind = "run.started"
                        startedSession?.updatedAt = Date()
                        try runRepo.persistActiveGraph(
                            run: startedRun,
                            thread: startedThread,
                            providerSession: startedSession
                        )
                    }
                    try restorePending()
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] start-running promote_ms=%@ get+persistActiveGraph_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "promotePendingStartToRunning must beat get+persistActiveGraph by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
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

    private func makeRepos(
        _ label: String
    ) throws -> (AgentThreadRepository, AgentRunRepository, ProviderSessionRuntimeRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (
            AgentThreadRepository(db: db),
            AgentRunRepository(db: db),
            ProviderSessionRuntimeRepository(db: db)
        )
    }
}
