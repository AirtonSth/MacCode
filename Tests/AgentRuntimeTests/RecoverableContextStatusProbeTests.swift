import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: Continue chrome (`hasRecoverableContext`) used to full-get 26 columns +
/// routing JSON just to learn whether durable status is `.interrupted`.
final class RecoverableContextStatusProbeTests: XCTestCase {
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

    func test_hasRecoverableContext_usesStatusProbeWithoutDurableGet() throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("continue-status")
        var completed = AgentThread(title: "done", provider: .codex, model: "fake-model")
        completed.status = .completed
        try threadRepo.upsert(completed)
        var interrupted = AgentThread(title: "paused", provider: .codex, model: "fake-model")
        interrupted.status = .interrupted
        interrupted.providerThreadId = "cursor-1"
        try threadRepo.upsert(interrupted)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: interrupted.id,
            provider: .codex,
            status: .interrupted,
            resumeCursor: "cursor-1",
            cwd: tmp,
            model: "fake-model"
        ))
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [:]
        )

        let getsBeforeCompleted = threadRepo.durableGetCountForTesting
        let probesBeforeCompleted = threadRepo.statusProbeCountForTesting
        XCTAssertFalse(
            coordinator.hasRecoverableContext(threadId: completed.id),
            "completed threads must not arm Continue"
        )
        XCTAssertEqual(
            threadRepo.statusProbeCountForTesting,
            probesBeforeCompleted + 1,
            "completed Continue probe must read status once"
        )
        XCTAssertEqual(
            threadRepo.durableGetCountForTesting,
            getsBeforeCompleted,
            "completed Continue probe must not compile a full 26-column get"
        )

        let getsBeforeInterrupted = threadRepo.durableGetCountForTesting
        let probesBeforeInterrupted = threadRepo.statusProbeCountForTesting
        XCTAssertTrue(
            coordinator.hasRecoverableContext(threadId: interrupted.id),
            "an interrupted thread with an interrupted session must arm Continue"
        )
        XCTAssertEqual(
            threadRepo.statusProbeCountForTesting,
            probesBeforeInterrupted + 1,
            "interrupted Continue probe must read status once"
        )
        XCTAssertEqual(
            threadRepo.durableGetCountForTesting,
            getsBeforeInterrupted,
            "interrupted Continue probe must not compile a full 26-column get"
        )
    }

    func test_hasRecoverableContext_sourceUsesStatusProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "public func hasRecoverableContext(threadId: AgentThreadID)"))
        let end = try XCTUnwrap(source.range(of: "nonisolated static func isTerminalThreadStatus("))
        let body = String(source[range.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("threadRepo.status(of: threadId)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadId)"))
    }

    func test_recoverableContext_statusProbe_fasterThanDurableGet() throws {
        let (threadRepo, _, _, _, _) = try makeRepos("continue-status-bench")
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
            "[perf-proof] continue status_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
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
