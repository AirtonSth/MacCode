import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: idle/stale `stopRun(threadId:)` used to full-get 26 columns + routing
/// JSON just to learn whether durable status is still running/pending (F19).
final class StopRunStatusProbeTests: XCTestCase {
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

    func test_stopRun_idleFinished_usesStatusProbeWithoutDurableGet() throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("stop-status")
        var thread = AgentThread(title: "finished", provider: .codex, model: "fake-model")
        thread.status = .completed
        try threadRepo.upsert(thread)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .completed,
            resumeCursor: "provider-thread-1",
            cwd: tmp,
            model: "fake-model"
        ))
        let adapter = IdleStopSessionAdapter()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providerAdapters: [.codex: adapter]
        )
        let getsBefore = threadRepo.durableGetCountForTesting
        let probesBefore = threadRepo.statusProbeCountForTesting
        coordinator.stopRun(threadId: thread.id)
        XCTAssertEqual(
            threadRepo.statusProbeCountForTesting,
            probesBefore + 1,
            "idle Stop must probe status once"
        )
        XCTAssertEqual(
            threadRepo.durableGetCountForTesting,
            getsBefore,
            "idle Stop must not compile a full 26-column get just to read status"
        )
        XCTAssertEqual(adapter.stopSessionCalls, 0)
        XCTAssertEqual(adapter.interruptCalls, 0)
        XCTAssertEqual(try threadRepo.get(id: thread.id)?.status, .completed)
    }

    func test_stopRun_sourceUsesStatusProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "public func stopRun(threadId: AgentThreadID)"))
        let body = String(source[range.lowerBound...].prefix(8000))
        XCTAssertTrue(body.contains("threadRepo.status(of: threadId)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadId)"))
    }

    func test_stopRun_statusProbe_fasterThanDurableGet() throws {
        let (threadRepo, _, _, _, _) = try makeRepos("stop-status-bench")
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
            "[perf-proof] idle-stop status_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
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

private final class IdleStopSessionAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let lock = NSLock()
    private var _stopSessionCalls = 0
    private var _interruptCalls = 0

    var stopSessionCalls: Int { lock.withLock { _stopSessionCalls } }
    var interruptCalls: Int { lock.withLock { _interruptCalls } }

    func listModels() async -> [AgentModelDescriptor] { [] }
    func startSession(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func sendTurn(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func interruptTurn(threadId: AgentThreadID) throws {
        lock.lock(); _interruptCalls += 1; lock.unlock()
    }
    func respondToRequest(
        threadId: AgentThreadID,
        requestId: String,
        response: AgentProviderRequestResponse
    ) async throws {}
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {}
    func stopSession(threadId: AgentThreadID) throws {
        lock.lock(); _stopSessionCalls += 1; lock.unlock()
    }
    func recoverSession(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] { [] }
    func hasSession(threadId: AgentThreadID) -> Bool { false }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func streamEvents(
        threadId: AgentThreadID,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) throws {}
}
