import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: finish-path persistTerminalGraph compiled the 16-column
/// provider_session_runtime row including cwd/model/status/error just to
/// copy runtime_payload_json into the terminal upsert.
final class TerminalGraphPayloadProbeTests: XCTestCase {
    func test_persistTerminalGraph_sourceUsesRuntimePayloadJSONProbeNotGet() throws {
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
        XCTAssertTrue(body.contains("runtimePayloadJSON(of: threadId)"))
        XCTAssertFalse(body.contains("providerSessionRepo.get(threadId: threadId)"))
    }

    func test_runtimePayloadJSONProbe_matchesPayloadWithoutDurableGet() throws {
        let (threadRepo, sessionRepo) = try makeRepos("terminal-graph-payload")
        let thread = AgentThread(title: "finish", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let payload = #"{"turnCount":7,"lastCompletedTurnId":"turn-7"}"#
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .running,
            lastErrorMessage: String(repeating: "e", count: 8 * 1024),
            runtimePayloadJSON: payload
        ))
        let getsBefore = sessionRepo.durableGetCountForTesting
        let probesBefore = sessionRepo.runtimePayloadJSONProbeCountForTesting

        let probed: String?? = try sessionRepo.runtimePayloadJSON(of: thread.id)
        XCTAssertEqual(probed, .some(.some(payload)))
        XCTAssertEqual(sessionRepo.runtimePayloadJSONProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore)
        let missing: String?? = try sessionRepo.runtimePayloadJSON(of: AgentThreadID())
        XCTAssertNil(missing as Any?)
        XCTAssertEqual((missing ?? nil) as String?, nil)
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore)
    }

    func test_runtimePayloadJSONProbe_fasterThanDurableGet() throws {
        let (threadRepo, sessionRepo) = try makeRepos("terminal-graph-payload-bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let payload = String(repeating: "p", count: 32 * 1024)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .running,
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
        for _ in 0..<warmup {
            _ = try sessionRepo.runtimePayloadJSON(of: thread.id)
            _ = try sessionRepo.get(threadId: thread.id)?.runtimePayloadJSON
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try sessionRepo.runtimePayloadJSON(of: thread.id) ?? nil
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try sessionRepo.get(threadId: thread.id)?.runtimePayloadJSON
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] terminal-graph-payload runtimePayloadJSON_ms=%@ get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "runtimePayloadJSON probe must beat get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeRepos(_ label: String) throws -> (AgentThreadRepository, ProviderSessionRuntimeRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (AgentThreadRepository(db: db), ProviderSessionRuntimeRepository(db: db))
    }
}
