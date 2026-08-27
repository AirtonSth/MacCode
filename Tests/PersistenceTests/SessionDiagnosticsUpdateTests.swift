import XCTest
import CoreModel
@testable import Persistence

/// WHY: stream flushes call updateDiagnostics on every kind change and used
/// to compile the 16-column provider_session_runtime row including
/// runtime_payload_json, then upsert the full row just to stamp
/// last_event_kind.
final class SessionDiagnosticsUpdateTests: XCTestCase {
    func test_updateDiagnostics_sourceUsesTargetedUpdateNotGetUpsert() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Persistence/Repositories.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "public func updateDiagnostics(threadId: AgentThreadID, lastEventKind: String?, lastErrorMessage: String?, at date: Date = Date()) throws {"))
        let end = try XCTUnwrap(source.range(of: "public enum CommandReceiptClaimResult"))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("UPDATE provider_session_runtime"))
        XCTAssertTrue(body.contains("last_event_kind"))
        XCTAssertFalse(body.contains("get(threadId: threadId)"))
        XCTAssertFalse(body.contains("upsert(session)"))
    }

    func test_updateDiagnostics_stampsKindWithoutDurableGetOrPayloadRewrite() throws {
        let (threadRepo, sessionRepo) = try makeRepos("session-diagnostics")
        let thread = AgentThread(title: "stream", provider: .codex, model: "fake-model")
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
            lastEventKind: "itemDelta(1)",
            lastErrorMessage: String(repeating: "e", count: 8 * 1024),
            runtimePayloadJSON: payload
        ))
        let getsBefore = sessionRepo.durableGetCountForTesting
        let updatesBefore = sessionRepo.updateDiagnosticsCountForTesting

        try sessionRepo.updateDiagnostics(
            threadId: thread.id,
            lastEventKind: "itemDelta(2)",
            lastErrorMessage: nil
        )

        XCTAssertEqual(sessionRepo.updateDiagnosticsCountForTesting, updatesBefore + 1)
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore)
        let stored = try XCTUnwrap(sessionRepo.get(threadId: thread.id))
        XCTAssertEqual(stored.lastEventKind, "itemDelta(2)")
        XCTAssertEqual(stored.lastErrorMessage, String(repeating: "e", count: 8 * 1024))
        XCTAssertEqual(stored.runtimePayloadJSON, payload)
        XCTAssertEqual(stored.status, .running)
        XCTAssertEqual(stored.resumeCursor, "sess-keep")
        XCTAssertEqual(stored.adapterKey, "keep-adapter")
        XCTAssertEqual(stored.cwd, "/tmp/keep")
        XCTAssertEqual(stored.model, "keep-model")
        try sessionRepo.updateDiagnostics(
            threadId: AgentThreadID(),
            lastEventKind: "missing",
            lastErrorMessage: nil
        )
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore + 1)
    }

    func test_updateDiagnostics_fasterThanGetAndUpsert() throws {
        let (threadRepo, sessionRepo) = try makeRepos("session-diagnostics-bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let payload = String(repeating: "p", count: 32 * 1024)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .running,
            lastEventKind: "itemDelta(0)",
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
        for i in 0..<warmup {
            try sessionRepo.updateDiagnostics(
                threadId: thread.id,
                lastEventKind: "warm-probe-\(i)",
                lastErrorMessage: nil
            )
            if var copy = try sessionRepo.get(threadId: thread.id) {
                copy.lastEventKind = "warm-get-\(i)"
                copy.updatedAt = Date()
                try sessionRepo.upsert(copy)
            }
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for sample in 0..<samples {
            probeSamples.append(try timeMs {
                for i in 0..<iterations {
                    try sessionRepo.updateDiagnostics(
                        threadId: thread.id,
                        lastEventKind: "probe-\(sample)-\(i)",
                        lastErrorMessage: nil
                    )
                }
            })
            getSamples.append(try timeMs {
                for i in 0..<iterations {
                    if var copy = try sessionRepo.get(threadId: thread.id) {
                        copy.lastEventKind = "get-\(sample)-\(i)"
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
            "[perf-proof] session-diagnostics updateDiagnostics_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "updateDiagnostics must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeRepos(_ label: String) throws -> (AgentThreadRepository, ProviderSessionRuntimeRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (AgentThreadRepository(db: db), ProviderSessionRuntimeRepository(db: db))
    }
}
