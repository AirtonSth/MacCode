import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: finish-path terminal claim used to full-get 26 columns + routing JSON
/// just to learn `provider` when in-memory run metadata was already gone.
final class TerminalClaimProviderChromeProbeTests: XCTestCase {
    private func makeRepos(_ label: String) throws -> (
        AgentThreadRepository,
        AgentMessageRepository,
        AgentRunRepository
    ) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (
            AgentThreadRepository(db: db),
            AgentMessageRepository(db: db),
            AgentRunRepository(db: db)
        )
    }

    func test_finishedWithoutRunMetadata_usesListChromeForProvider() throws {
        let (threadRepo, messageRepo, runRepo) = try makeRepos("terminal-chrome")
        let thread = AgentThread(title: "finish", provider: .claude, model: "fake-model")
        let runId = AgentRunID()
        try threadRepo.upsert(thread)
        // Late admission needs a durable running graph. `finishedAt` must stay
        // nil or handle() returns before the terminal-claim provider probe.
        try runRepo.upsert(AgentRun(
            id: runId,
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            status: .running
        ))
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [:]
        )
        var admitted = false
        coordinator.runCallbackDidAdmitBeforeMutationForTesting = { id, candidateThreadId in
            if id == runId, candidateThreadId == thread.id {
                admitted = true
            }
        }
        let chromeBefore = threadRepo.listChromeCallCountForTesting
        coordinator.handleRunEventForTesting(
            .finished(.completed, finalMessage: nil, providerThreadId: nil),
            runId: runId,
            threadId: thread.id
        )
        XCTAssertTrue(admitted, "finish must be admitted so the terminal-claim path can run")
        XCTAssertGreaterThanOrEqual(
            threadRepo.listChromeCallCountForTesting,
            chromeBefore + 1,
            "a metadata-less finish must probe listChrome for provider (adapter teardown may add a second probe)"
        )
    }

    func test_needsTerminalClaim_sourceUsesListChrome() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "let needsTerminalClaim = pendingTerminalEvents"))
        let body = String(source[range.lowerBound...].prefix(1400))
        XCTAssertTrue(body.contains("threadRepo.listChrome(ids: [threadId])"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadId)"))
    }

    func test_terminalClaim_listChrome_fasterThanDurableGet() throws {
        let (threadRepo, _, _) = try makeRepos("terminal-chrome-bench")
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
            _ = try threadRepo.listChrome(ids: [thread.id])
            _ = try threadRepo.get(id: thread.id)
        }
        var chromeSamples: [Double] = []
        var getSamples: [Double] = []
        chromeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            chromeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.listChrome(ids: [thread.id])
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.get(id: thread.id)
                }
            })
        }
        let chromeMed = median(chromeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - chromeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] terminal-claim listChrome_ms=%@ durable_get_ms=%@ improvement_pct=%.2f chrome=%@ get=%@",
            String(chromeMed), String(getMed), improvement,
            String(describing: chromeSamples), String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "listChrome must beat durable get by ≥5% (got \(improvement)%; chrome=\(chromeMed)ms get=\(getMed)ms)"
        )
    }
}
