import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: thread-select rehydrate compiled the 16-column
/// provider_session_runtime row including cwd/model/status/error just to
/// restore resume_cursor and payload plan/approval state.
final class ActiveThreadSessionChromeTests: XCTestCase {
    func test_durableActiveThreadState_sourceUsesActiveChromeProbeNotGet() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "public func durableActiveThreadState(threadId: AgentThreadID)"))
        let end = try XCTUnwrap(source.range(of: "public func forkThread("))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("activeChrome(of: threadId)"))
        XCTAssertFalse(body.contains("providerSessionRepo.get(threadId: threadId)"))
    }

    func test_activeChromeProbe_matchesCursorAndPayloadWithoutDurableGet() throws {
        let (threadRepo, sessionRepo) = try makeRepos("active-thread-chrome")
        let thread = AgentThread(title: "live", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let payload = #"{"providerThreadId":"sess-keep","activeTurnId":"turn-1","turnCount":3}"#
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .running,
            resumeCursor: "sess-keep",
            lastErrorMessage: String(repeating: "e", count: 8 * 1024),
            runtimePayloadJSON: payload
        ))
        let getsBefore = sessionRepo.durableGetCountForTesting
        let probesBefore = sessionRepo.activeChromeProbeCountForTesting

        let chrome = try XCTUnwrap(sessionRepo.activeChrome(of: thread.id))
        XCTAssertEqual(chrome.resumeCursor, "sess-keep")
        XCTAssertEqual(chrome.runtimePayloadJSON, payload)
        XCTAssertEqual(sessionRepo.activeChromeProbeCountForTesting, probesBefore + 1)
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore)
        XCTAssertNil(try sessionRepo.activeChrome(of: AgentThreadID()))
        XCTAssertEqual(sessionRepo.durableGetCountForTesting, getsBefore)
    }

    func test_activeChromeProbe_fasterThanDurableGet() throws {
        let (threadRepo, sessionRepo) = try makeRepos("active-thread-chrome-bench")
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
            _ = try sessionRepo.activeChrome(of: thread.id)
            _ = try sessionRepo.get(threadId: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try sessionRepo.activeChrome(of: thread.id)
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
            "[perf-proof] active-thread-chrome activeChrome_ms=%@ get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples),
            String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "activeChrome probe must beat get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    private func makeRepos(_ label: String) throws -> (AgentThreadRepository, ProviderSessionRuntimeRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (AgentThreadRepository(db: db), ProviderSessionRuntimeRepository(db: db))
    }
}
