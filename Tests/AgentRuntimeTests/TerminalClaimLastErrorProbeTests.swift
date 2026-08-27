import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: finish-path terminal claim compiled the 16-column
/// provider_session_runtime row including runtime_payload_json just to
/// copy last_error_message for stderr classification.
final class TerminalClaimLastErrorProbeTests: XCTestCase {
    func test_needsTerminalClaim_sourceUsesLastErrorMessageProbeNotGet() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "let needsTerminalClaim = pendingTerminalEvents"))
        let body = String(source[range.lowerBound...].prefix(2500))
        XCTAssertTrue(body.contains("lastErrorMessage(of: threadId)"))
        XCTAssertFalse(body.contains("providerSessionRepo?.get(threadId: threadId)"))
    }

    func test_lastErrorMessageProbe_matchesErrorWithoutDurableGet() throws {
        let (threadRepo, sessionRepo) = try makeRepos("terminal-claim-error")
        let thread = AgentThread(title: "finish", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let payload = String(repeating: "p", count: 32 * 1024)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .running,
            lastErrorMessage: "boom",
            runtimePayloadJSON: payload
        ))
        let getsBefore = sessionRepo.durableGetCountForTesting
        let probesBefore = sessionRepo.lastErrorMessageProbeCountForTesting

        XCTAssertEqual(try sessionRepo.lastErrorMessage(of: thread.id), "boom")
        XCTAssertEqual(sessionRepo.lastErrorMessageProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try sessionRepo.lastErrorMessage(of: AgentThreadID()))
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore)

        let empty = AgentThread(title: "empty", provider: .codex, model: "fake-model")
        try threadRepo.upsert(empty)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: empty.id,
            provider: .codex,
            status: .running,
            lastErrorMessage: nil,
            runtimePayloadJSON: payload
        ))
        XCTAssertNil(try sessionRepo.lastErrorMessage(of: empty.id))
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore)
    }

    func test_lastErrorMessageProbe_fasterThanDurableGet() throws {
        let (threadRepo, sessionRepo) = try makeRepos("terminal-claim-error-bench")
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
            _ = try sessionRepo.lastErrorMessage(of: thread.id)
            _ = try sessionRepo.get(threadId: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try sessionRepo.lastErrorMessage(of: thread.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try sessionRepo.get(threadId: thread.id)?.lastErrorMessage
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] terminal-claim-error lastErrorMessage_ms=%@ get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "lastErrorMessage probe must beat get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeRepos(_ label: String) throws -> (AgentThreadRepository, ProviderSessionRuntimeRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (AgentThreadRepository(db: db), ProviderSessionRuntimeRepository(db: db))
    }
}
