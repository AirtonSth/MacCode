import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: provider `.error` handling compiled the 16-column
/// provider_session_runtime row including runtime_payload_json under
/// mirrorEventLock just to copy resume_cursor for recoverable.
final class ErrorSessionResumeCursorProbeTests: XCTestCase {
    func test_errorPath_sourceUsesSessionResumeCursorProbeNotGet() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "case .error(let m):"))
        let end = try XCTUnwrap(source.range(of: "private func persistTerminalGraph("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("resumeCursor(of: threadId)"))
        XCTAssertTrue(body.contains("threadRepo.providerThreadId(of: threadId)"))
        XCTAssertFalse(body.contains("providerSessionRepo?.get(threadId: threadId)"))
    }

    func test_resumeCursorProbe_matchesCursorWithoutDurableGet() throws {
        let (threadRepo, sessionRepo) = try makeRepos("error-session-cursor")
        let thread = AgentThread(title: "error", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let payload = String(repeating: "p", count: 32 * 1024)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .running,
            resumeCursor: "sess-abc",
            lastErrorMessage: String(repeating: "e", count: 8 * 1024),
            runtimePayloadJSON: payload
        ))
        let getsBefore = sessionRepo.durableGetCountForTesting
        let probesBefore = sessionRepo.resumeCursorProbeCountForTesting

        XCTAssertEqual(try sessionRepo.resumeCursor(of: thread.id), "sess-abc")
        XCTAssertEqual(sessionRepo.resumeCursorProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try sessionRepo.resumeCursor(of: AgentThreadID()))
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore)

        let empty = AgentThread(title: "empty", provider: .codex, model: "fake-model")
        try threadRepo.upsert(empty)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: empty.id,
            provider: .codex,
            status: .running,
            resumeCursor: nil,
            runtimePayloadJSON: payload
        ))
        XCTAssertNil(try sessionRepo.resumeCursor(of: empty.id))
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore)
    }

    func test_resumeCursorProbe_fasterThanDurableGet() throws {
        let (threadRepo, sessionRepo) = try makeRepos("error-session-cursor-bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let payload = String(repeating: "p", count: 32 * 1024)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .running,
            resumeCursor: "sess-bench",
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
            _ = try sessionRepo.resumeCursor(of: thread.id)
            _ = try sessionRepo.get(threadId: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try sessionRepo.resumeCursor(of: thread.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try sessionRepo.get(threadId: thread.id)?.resumeCursor
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] error-session-cursor resumeCursor_ms=%@ get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "resumeCursor probe must beat get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeRepos(_ label: String) throws -> (AgentThreadRepository, ProviderSessionRuntimeRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (AgentThreadRepository(db: db), ProviderSessionRuntimeRepository(db: db))
    }
}
