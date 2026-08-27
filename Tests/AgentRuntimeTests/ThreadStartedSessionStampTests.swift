import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: `.threadStarted` compiled the 16-column provider_session_runtime row
/// including runtime_payload_json, then decoded/encoded the payload and
/// upserted the full row just to stamp resume_cursor.
final class ThreadStartedSessionStampTests: XCTestCase {
    func test_threadStarted_sourceUsesSessionStampNotGetUpsert() throws {
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
        XCTAssertTrue(body.contains("stampResumeCursor("))
        XCTAssertTrue(body.contains("threadRepo.updateProviderThreadId("))
        XCTAssertFalse(body.contains("providerSessionRepo?.get(threadId: threadId)"))
        XCTAssertFalse(body.contains("upsert(session)"))
    }

    func test_stampResumeCursor_stampsCursorWithoutDurableGetOrBlobRewrite() throws {
        let (threadRepo, sessionRepo) = try makeRepos("thread-started-session")
        let thread = fatThread(title: "live")
        try threadRepo.upsert(thread)
        let planBlob = String(repeating: "p", count: 32 * 1024)
        let payloadJSON = """
        {"providerThreadId":"old","turnCount":7,"model":"keep-me","planBlob":"\(planBlob)"}
        """
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            adapterKey: "keep-adapter",
            status: .running,
            resumeCursor: "old",
            cwd: "/tmp/keep",
            model: "keep-model",
            lastEventKind: "run.started",
            lastErrorMessage: String(repeating: "e", count: 8 * 1024),
            runtimePayloadJSON: payloadJSON
        ))
        let getsBefore = sessionRepo.durableGetCountForTesting
        let stampsBefore = sessionRepo.stampResumeCursorCountForTesting

        try sessionRepo.stampResumeCursor(threadId: thread.id, resumeCursor: "sess-abc")

        XCTAssertEqual(sessionRepo.stampResumeCursorCountForTesting, stampsBefore + 1)
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore)
        let stored = try XCTUnwrap(sessionRepo.get(threadId: thread.id))
        XCTAssertEqual(stored.resumeCursor, "sess-abc")
        XCTAssertEqual(stored.status, .running)
        XCTAssertEqual(stored.adapterKey, "keep-adapter")
        XCTAssertEqual(stored.cwd, "/tmp/keep")
        XCTAssertEqual(stored.model, "keep-model")
        XCTAssertEqual(stored.lastEventKind, "run.started")
        XCTAssertEqual(stored.lastErrorMessage, String(repeating: "e", count: 8 * 1024))
        let payload = try payloadObject(stored.runtimePayloadJSON)
        XCTAssertEqual(payload["providerThreadId"] as? String, "sess-abc")
        XCTAssertEqual(payload["turnCount"] as? Int, 7)
        XCTAssertEqual(payload["model"] as? String, "keep-me")
        XCTAssertEqual(payload["planBlob"] as? String, planBlob)
        XCTAssertNotNil(payload["updatedAtMs"])
        try sessionRepo.stampResumeCursor(threadId: AgentThreadID(), resumeCursor: "missing")
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore + 1)
    }

    func test_stampResumeCursor_fasterThanGetAndUpsert() throws {
        let (threadRepo, sessionRepo) = try makeRepos("thread-started-session-bench")
        let thread = fatThread(title: "bench")
        try threadRepo.upsert(thread)
        let planBlob = String(repeating: "p", count: 32 * 1024)
        let payloadJSON = """
        {"providerThreadId":"old","turnCount":7,"model":"keep-me","planBlob":"\(planBlob)"}
        """
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .running,
            resumeCursor: "old",
            lastErrorMessage: String(repeating: "e", count: 8 * 1024),
            runtimePayloadJSON: payloadJSON
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
        for _ in 0..<warmup {
            try sessionRepo.stampResumeCursor(threadId: thread.id, resumeCursor: "sess-warm")
            if var copy = try sessionRepo.get(threadId: thread.id) {
                copy.resumeCursor = "sess-warm"
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
                    try sessionRepo.stampResumeCursor(threadId: thread.id, resumeCursor: "sess-probe")
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    if var copy = try sessionRepo.get(threadId: thread.id) {
                        copy.resumeCursor = "sess-get"
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
            "[perf-proof] thread-started-session stampResumeCursor_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "stampResumeCursor must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func payloadObject(_ json: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(json?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func fatThread(title: String) -> AgentThread {
        var thread = AgentThread(title: title, provider: .codex, model: "fake-model")
        thread.status = .running
        return thread
    }

    private func makeRepos(_ label: String) throws -> (AgentThreadRepository, ProviderSessionRuntimeRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (AgentThreadRepository(db: db), ProviderSessionRuntimeRepository(db: db))
    }
}
