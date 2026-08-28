import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: launch reconciliation used to full-get 26 columns + routing JSON just
/// to copy durable thread status onto a stale running provider session.
final class LaunchSessionStatusProbeTests: XCTestCase {
    private func makeRepos(_ label: String) throws -> (
        AgentThreadRepository,
        AgentMessageRepository,
        AgentRunRepository,
        ProviderSessionRuntimeRepository,
        String
    ) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (
            AgentThreadRepository(db: db),
            AgentMessageRepository(db: db),
            AgentRunRepository(db: db),
            ProviderSessionRuntimeRepository(db: db),
            tmp
        )
    }

    func test_reconcileOnLaunch_usesStatusProbeWithoutDurableGet() throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("launch-session-status")
        var thread = AgentThread(title: "already done", provider: .grok, model: "grok-4.5")
        thread.status = .completed
        try threadRepo.upsert(thread)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .grok,
            status: .running,
            resumeCursor: "cursor-1",
            cwd: tmp,
            model: "grok-4.5"
        ))
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [:]
        )

        let getsBefore = threadRepo.durableGetCountForTesting
        let probesBefore = threadRepo.statusProbeCountForTesting
        try coordinator.reconcileOnLaunch()
        XCTAssertEqual(
            threadRepo.statusProbeCountForTesting,
            probesBefore + 1,
            "launch session heal must probe status once"
        )
        XCTAssertEqual(
            threadRepo.durableGetCountForTesting,
            getsBefore,
            "launch session heal must not compile a full 26-column get just to read status"
        )
        XCTAssertEqual(try sessionRepo.get(threadId: thread.id)?.status, .completed)
    }

    func test_reconcileOnLaunch_sourceUsesStatusProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "A stale running session on an already-terminal thread is not a"))
        let body = String(source[range.lowerBound...].prefix(900))
        XCTAssertTrue(body.contains("threadRepo.status(of: session.threadId)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: session.threadId)"))
    }

    func test_statusProbe_fasterThanDurableGet() throws {
        let (threadRepo, _, _, _, _) = try makeRepos("launch-session-bench")
        let thread = AgentThread(title: "bench", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
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
            _ = try threadRepo.status(of: thread.id)
            _ = try threadRepo.get(id: thread.id)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.status(of: thread.id)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.get(id: thread.id)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] launch-session status_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples), String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "status probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }
}
