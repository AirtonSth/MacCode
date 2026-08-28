import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: recoverAdapterSessionIfNeeded compiled the 16-column
/// provider_session_runtime row including runtime_payload_json and
/// last_error_message on every open/read/stop without a live session,
/// then JSON-decoded the blob just for activeTurnId.
final class RecoverySessionChromeProbeTests: XCTestCase {
    func test_recoverAdapterSessionIfNeeded_sourceUsesAdapterRecoverySessionNotGet() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func recoverAdapterSessionIfNeeded("))
        let end = try XCTUnwrap(source.range(of: "private func recoveryEventRunId("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("adapterRecoverySession(of: threadId)"))
        XCTAssertFalse(body.contains("providerSessionRepo?.get(threadId: threadId)"))
        XCTAssertFalse(body.contains("ProviderSessionRuntimePayload.decode"))
    }

    func test_adapterRecoverySessionProbe_matchesChromeWithoutDurableGet() throws {
        let (threadRepo, sessionRepo) = try makeRepos("recovery-session-chrome")
        let thread = AgentThread(title: "live", provider: .codex, model: "keep-model")
        try threadRepo.upsert(thread)
        let runId = AgentRunID()
        let payload = #"{"providerThreadId":"sess-keep","activeTurnId":"turn-keep","turnCount":3,"pendingApprovalRequestIds":["a"]}"#
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .interrupted,
            resumeCursor: "sess-keep",
            cwd: "/tmp/keep",
            model: "keep-model",
            serviceTier: .fast,
            runtimeMode: .fullAccess,
            lastRunId: runId,
            lastEventKind: "itemDelta",
            lastErrorMessage: String(repeating: "e", count: 8 * 1024),
            runtimePayloadJSON: payload
        ))
        let getsBefore = sessionRepo.durableGetCountForTesting
        let probesBefore = sessionRepo.adapterRecoverySessionProbeCountForTesting

        let chrome = try XCTUnwrap(sessionRepo.adapterRecoverySession(of: thread.id))
        XCTAssertEqual(chrome.provider, .codex)
        XCTAssertEqual(chrome.status, .interrupted)
        XCTAssertEqual(chrome.resumeCursor, "sess-keep")
        XCTAssertEqual(chrome.cwd, "/tmp/keep")
        XCTAssertEqual(chrome.model, "keep-model")
        XCTAssertEqual(chrome.serviceTier, .fast)
        XCTAssertEqual(chrome.runtimeMode, .fullAccess)
        XCTAssertEqual(chrome.lastRunId, runId)
        XCTAssertEqual(chrome.activeTurnId, "turn-keep")
        XCTAssertEqual(sessionRepo.adapterRecoverySessionProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try sessionRepo.adapterRecoverySession(of: AgentThreadID()))
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore)

        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .interrupted,
            resumeCursor: "sess-keep",
            runtimePayloadJSON: String(repeating: "p", count: 32 * 1024)
        ))
        XCTAssertNil(try sessionRepo.adapterRecoverySession(of: thread.id)?.activeTurnId)
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore)
    }

    func test_adapterRecoverySessionProbe_fasterThanDurableGet() throws {
        let (threadRepo, sessionRepo) = try makeRepos("recovery-session-chrome-bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let payload = String(repeating: "p", count: 32 * 1024)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .interrupted,
            resumeCursor: "sess-bench",
            cwd: "/tmp/keep",
            model: "keep-model",
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
            _ = try sessionRepo.adapterRecoverySession(of: thread.id)
            _ = try sessionRepo.get(threadId: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try sessionRepo.adapterRecoverySession(of: thread.id)
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
            "[perf-proof] recovery-session-chrome adapterRecoverySession_ms=%@ get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "adapterRecoverySession probe must beat get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeRepos(_ label: String) throws -> (AgentThreadRepository, ProviderSessionRuntimeRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (AgentThreadRepository(db: db), ProviderSessionRuntimeRepository(db: db))
    }
}
