import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: fork persist compiled the 16-column provider_session_runtime row
/// including runtime_payload_json just to copy adapter_key, binary_identity,
/// and cwd onto the child session.
final class ForkSourceSessionIdentityProbeTests: XCTestCase {
    func test_forkPersist_sourceUsesForkSourceIdentityProbeNotGet() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "var persistedChild = intent.childThread"))
        let end = try XCTUnwrap(source.range(of: "public func rollbackThread(threadId:"))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("forkSourceIdentity(of: intent.sourceThreadId)"))
        XCTAssertFalse(body.contains("providerSessionRepo?.get(threadId: intent.sourceThreadId)"))
    }

    func test_forkSourceIdentityProbe_matchesIdentityWithoutDurableGet() throws {
        let (threadRepo, sessionRepo) = try makeRepos("fork-source-session-identity")
        let thread = AgentThread(title: "live", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let payload = String(repeating: "p", count: 32 * 1024)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            adapterKey: "keep-adapter",
            binaryIdentity: "keep-binary",
            status: .completed,
            resumeCursor: "sess-keep",
            cwd: "/tmp/keep",
            model: "keep-model",
            lastEventKind: "thread/forked",
            lastErrorMessage: String(repeating: "e", count: 8 * 1024),
            runtimePayloadJSON: payload
        ))
        let getsBefore = sessionRepo.durableGetCountForTesting
        let probesBefore = sessionRepo.forkSourceIdentityProbeCountForTesting

        let probed = try XCTUnwrap(sessionRepo.forkSourceIdentity(of: thread.id))
        XCTAssertEqual(probed.adapterKey, "keep-adapter")
        XCTAssertEqual(probed.binaryIdentity, "keep-binary")
        XCTAssertEqual(probed.cwd, "/tmp/keep")
        XCTAssertEqual(sessionRepo.forkSourceIdentityProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try sessionRepo.forkSourceIdentity(of: AgentThreadID()))
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore)
    }

    func test_forkSourceIdentityProbe_fasterThanDurableGet() throws {
        let (threadRepo, sessionRepo) = try makeRepos("fork-source-session-identity-bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let payload = String(repeating: "p", count: 32 * 1024)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            adapterKey: "keep-adapter",
            binaryIdentity: "keep-binary",
            status: .completed,
            cwd: "/tmp/keep",
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
            _ = try sessionRepo.forkSourceIdentity(of: thread.id)
            _ = try sessionRepo.get(threadId: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try sessionRepo.forkSourceIdentity(of: thread.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try sessionRepo.get(threadId: thread.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] fork-source-session-identity forkSourceIdentity_ms=%@ get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "forkSourceIdentity probe must beat get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeRepos(_ label: String) throws -> (AgentThreadRepository, ProviderSessionRuntimeRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (AgentThreadRepository(db: db), ProviderSessionRuntimeRepository(db: db))
    }
}
