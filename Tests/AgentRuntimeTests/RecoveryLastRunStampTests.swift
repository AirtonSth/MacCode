import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: recovery minted a new run then compiled the 16-column
/// provider_session_runtime row including runtime_payload_json and
/// upserted the full row just to stamp last_run_id.
final class RecoveryLastRunStampTests: XCTestCase {
    func test_recoveryEventRunId_sourceUsesStampNotGetUpsert() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func recoveryEventRunId("))
        let end = try XCTUnwrap(source.range(of: "private func providerBinaryIdentity("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("stampLastRunId("))
        XCTAssertFalse(body.contains("providerSessionRepo?.get(threadId: thread.id)"))
        XCTAssertFalse(body.contains("upsert(persistedSession)"))
    }

    func test_stampLastRunId_stampsRunWithoutDurableGetOrPayloadRewrite() throws {
        let (threadRepo, sessionRepo) = try makeRepos("recovery-last-run")
        let thread = AgentThread(title: "live", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let payload = String(repeating: "p", count: 32 * 1024)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            adapterKey: "keep-adapter",
            status: .interrupted,
            resumeCursor: "sess-keep",
            cwd: "/tmp/keep",
            model: "keep-model",
            lastEventKind: "run.started",
            lastErrorMessage: String(repeating: "e", count: 8 * 1024),
            runtimePayloadJSON: payload
        ))
        let getsBefore = sessionRepo.durableGetCountForTesting
        let stampsBefore = sessionRepo.stampLastRunIdCountForTesting
        let runId = AgentRunID()

        try sessionRepo.stampLastRunId(threadId: thread.id, lastRunId: runId)

        XCTAssertEqual(sessionRepo.stampLastRunIdCountForTesting, stampsBefore + 1)
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore)
        let stored = try XCTUnwrap(sessionRepo.get(threadId: thread.id))
        XCTAssertEqual(stored.lastRunId, runId)
        XCTAssertEqual(stored.status, .interrupted)
        XCTAssertEqual(stored.adapterKey, "keep-adapter")
        XCTAssertEqual(stored.resumeCursor, "sess-keep")
        XCTAssertEqual(stored.cwd, "/tmp/keep")
        XCTAssertEqual(stored.model, "keep-model")
        XCTAssertEqual(stored.lastEventKind, "run.started")
        XCTAssertEqual(stored.lastErrorMessage, String(repeating: "e", count: 8 * 1024))
        XCTAssertEqual(stored.runtimePayloadJSON, payload)
        try sessionRepo.stampLastRunId(threadId: AgentThreadID(), lastRunId: AgentRunID())
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore + 1)
    }

    func test_stampLastRunId_fasterThanGetAndUpsert() throws {
        let (threadRepo, sessionRepo) = try makeRepos("recovery-last-run-bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let payload = String(repeating: "p", count: 32 * 1024)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .interrupted,
            resumeCursor: "sess-keep",
            lastErrorMessage: String(repeating: "e", count: 8 * 1024),
            runtimePayloadJSON: payload
        ))
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
        let runId = AgentRunID()
        for _ in 0..<warmup {
            try sessionRepo.stampLastRunId(threadId: thread.id, lastRunId: runId)
            if var copy = try sessionRepo.get(threadId: thread.id) {
                copy.lastRunId = runId
                copy.updatedAt = Date()
                try sessionRepo.upsert(copy)
            }
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    try sessionRepo.stampLastRunId(threadId: thread.id, lastRunId: runId)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    if var copy = try sessionRepo.get(threadId: thread.id) {
                        copy.lastRunId = runId
                        copy.updatedAt = Date()
                        try sessionRepo.upsert(copy)
                    }
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] recovery-last-run stampLastRunId_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "stampLastRunId must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeRepos(_ label: String) throws -> (AgentThreadRepository, ProviderSessionRuntimeRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (AgentThreadRepository(db: db), ProviderSessionRuntimeRepository(db: db))
    }
}
