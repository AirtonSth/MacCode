import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: stream-path turn/request/plan mutations compiled the 16-column
/// provider_session_runtime row including cwd/model/status/error, then
/// upserted the full row just to rewrite runtime_payload_json.
final class StreamRuntimePayloadStampTests: XCTestCase {
    func test_updateProviderRuntimePayload_sourceUsesStampNotGetUpsert() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func updateProviderRuntimePayload("))
        let end = try XCTUnwrap(source.range(of: "private func updateProviderRuntimePayloadFromProviderEvent("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("stampRuntimePayload("))
        XCTAssertFalse(body.contains("providerSessionRepo?.get(threadId: threadId)"))
        XCTAssertFalse(body.contains("upsert(session)"))
    }

    func test_stampRuntimePayload_rewritesJSONWithoutDurableGetOrOtherColumns() throws {
        let (threadRepo, sessionRepo) = try makeRepos("stream-runtime-payload")
        let thread = AgentThread(title: "live", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let planBlob = String(repeating: "p", count: 32 * 1024)
        let payloadJSON = """
        {"providerThreadId":"sess-keep","turnCount":7,"model":"keep-me","planBlob":"\(planBlob)"}
        """
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
            runtimePayloadJSON: payloadJSON
        ))
        let getsBefore = sessionRepo.durableGetCountForTesting
        let stampsBefore = sessionRepo.stampRuntimePayloadCountForTesting

        try sessionRepo.stampRuntimePayload(threadId: thread.id) { json in
            var payload = payloadObject(json)
            payload["activeTurnId"] = "turn-9"
            json = jsonString(payload)
        }

        XCTAssertEqual(sessionRepo.stampRuntimePayloadCountForTesting, stampsBefore + 1)
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore)
        let stored = try XCTUnwrap(sessionRepo.get(threadId: thread.id))
        XCTAssertEqual(stored.status, .running)
        XCTAssertEqual(stored.adapterKey, "keep-adapter")
        XCTAssertEqual(stored.resumeCursor, "sess-keep")
        XCTAssertEqual(stored.cwd, "/tmp/keep")
        XCTAssertEqual(stored.model, "keep-model")
        XCTAssertEqual(stored.lastEventKind, "run.started")
        XCTAssertEqual(stored.lastErrorMessage, String(repeating: "e", count: 8 * 1024))
        let payload = payloadObject(stored.runtimePayloadJSON)
        XCTAssertEqual(payload["activeTurnId"] as? String, "turn-9")
        XCTAssertEqual(payload["providerThreadId"] as? String, "sess-keep")
        XCTAssertEqual(payload["turnCount"] as? Int, 7)
        XCTAssertEqual(payload["model"] as? String, "keep-me")
        XCTAssertEqual(payload["planBlob"] as? String, planBlob)

        let missing = AgentThreadID()
        try sessionRepo.stampRuntimePayload(threadId: missing) { json in
            json = "{\"activeTurnId\":\"missing\"}"
        }
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore + 1)
        XCTAssertNil(try sessionRepo.get(threadId: missing)?.runtimePayloadJSON)
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore + 2)
    }

    func test_stampRuntimePayload_fasterThanGetAndUpsert() throws {
        let (threadRepo, sessionRepo) = try makeRepos("stream-runtime-payload-bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let planBlob = String(repeating: "p", count: 32 * 1024)
        let payloadJSON = """
        {"providerThreadId":"sess-keep","turnCount":7,"model":"keep-me","planBlob":"\(planBlob)"}
        """
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .running,
            resumeCursor: "sess-keep",
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
            try sessionRepo.stampRuntimePayload(threadId: thread.id) { json in
                var payload = payloadObject(json)
                payload["activeTurnId"] = "turn-warm"
                json = jsonString(payload)
            }
            if var copy = try sessionRepo.get(threadId: thread.id) {
                copy.runtimePayloadJSON = payloadJSON
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
                    try sessionRepo.stampRuntimePayload(threadId: thread.id) { json in
                        var payload = payloadObject(json)
                        payload["activeTurnId"] = "turn-probe"
                        json = jsonString(payload)
                    }
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    if var copy = try sessionRepo.get(threadId: thread.id) {
                        var payload = payloadObject(copy.runtimePayloadJSON)
                        payload["activeTurnId"] = "turn-get"
                        copy.runtimePayloadJSON = jsonString(payload)
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
            "[perf-proof] stream-runtime-payload stampRuntimePayload_ms=%@ get+upsert_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "stampRuntimePayload must beat get+upsert by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func payloadObject(_ json: String?) -> [String: Any] {
        guard let data = json?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func makeRepos(_ label: String) throws -> (AgentThreadRepository, ProviderSessionRuntimeRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (AgentThreadRepository(db: db), ProviderSessionRuntimeRepository(db: db))
    }
}
