import XCTest
import CoreModel
@testable import Persistence

/// WHY: Stop/launch/reaper compiled the 16-column provider_session_runtime
/// row including runtime_payload_json, then upserted the full row just to
/// stamp status.
final class SessionMarkStoppedTests: XCTestCase {
    func test_markStopped_sourceUsesTargetedUpdateNotGetUpsert() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Persistence/Repositories.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "public func markStopped(\n        threadId: AgentThreadID,"))
        let end = try XCTUnwrap(source.range(of: "public func updateDiagnostics(threadId: AgentThreadID, lastEventKind: String?, lastErrorMessage: String?, at date: Date = Date()) throws {"))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("UPDATE provider_session_runtime"))
        XCTAssertTrue(body.contains("SET status = ?"))
        XCTAssertFalse(body.contains("get(threadId: threadId)"))
        XCTAssertFalse(body.contains("upsert(session)"))
    }

    func test_markStopped_stampsStatusWithoutDurableGetOrPayloadRewrite() throws {
        let (threadRepo, sessionRepo) = try makeRepos("session-mark-stopped")
        let thread = AgentThread(title: "live", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let payload = String(repeating: "p", count: 32 * 1024)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            adapterKey: "keep-adapter",
            status: .running,
            resumeCursor: "sess-keep",
            cwd: "/tmp/keep",
            model: "keep-model",
            lastEventKind: "run.started",
            lastErrorMessage: String(repeating: "e", count: 8 * 1024),
            runtimePayloadJSON: payload
        ))
        let getsBefore = sessionRepo.durableGetCountForTesting
        let stopsBefore = sessionRepo.markStoppedCountForTesting

        try sessionRepo.markStopped(threadId: thread.id, status: .cancelled)

        XCTAssertEqual(sessionRepo.markStoppedCountForTesting, stopsBefore + 1)
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore)
        let stored = try XCTUnwrap(sessionRepo.get(threadId: thread.id))
        XCTAssertEqual(stored.status, .cancelled)
        XCTAssertEqual(stored.resumeCursor, "sess-keep")
        XCTAssertEqual(stored.runtimePayloadJSON, payload)
        XCTAssertEqual(stored.lastEventKind, "run.started")
        XCTAssertEqual(stored.lastErrorMessage, String(repeating: "e", count: 8 * 1024))
        XCTAssertEqual(stored.adapterKey, "keep-adapter")
        XCTAssertEqual(stored.cwd, "/tmp/keep")
        XCTAssertEqual(stored.model, "keep-model")
        try sessionRepo.markStopped(threadId: AgentThreadID(), status: .cancelled)
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore + 1)
        guard case .stopped = try sessionRepo.recoveryState(threadId: thread.id) else {
            return XCTFail("cancelled session must stay stopped")
        }

        try sessionRepo.markStopped(threadId: thread.id, status: .interrupted)
        let interrupted = try XCTUnwrap(sessionRepo.get(threadId: thread.id))
        XCTAssertEqual(interrupted.status, .interrupted)
        XCTAssertEqual(interrupted.resumeCursor, "sess-keep")
        guard case .recoverable = try sessionRepo.recoveryState(threadId: thread.id) else {
            return XCTFail("interrupted session with cursor must stay recoverable")
        }
    }

    func test_markStopped_fasterThanGetAndUpsert() throws {
        let (threadRepo, sessionRepo) = try makeRepos("session-mark-stopped-bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let payload = String(repeating: "p", count: 64 * 1024)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            adapterKey: String(repeating: "a", count: 4 * 1024),
            binaryIdentity: String(repeating: "b", count: 4 * 1024),
            status: .running,
            resumeCursor: "sess-keep",
            cwd: String(repeating: "c", count: 4 * 1024),
            model: String(repeating: "m", count: 4 * 1024),
            lastErrorMessage: String(repeating: "e", count: 32 * 1024),
            runtimePayloadJSON: payload
        ))
        let warmup = 5
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
            try sessionRepo.markStopped(threadId: thread.id, status: .cancelled)
            if var copy = try sessionRepo.get(threadId: thread.id) {
                copy.status = .cancelled
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
                    try sessionRepo.markStopped(threadId: thread.id, status: .cancelled)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    if var copy = try sessionRepo.get(threadId: thread.id) {
                        copy.status = .cancelled
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
            "[perf-proof] session-mark-stopped markStopped_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "markStopped must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeRepos(_ label: String) throws -> (AgentThreadRepository, ProviderSessionRuntimeRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (AgentThreadRepository(db: db), ProviderSessionRuntimeRepository(db: db))
    }
}
