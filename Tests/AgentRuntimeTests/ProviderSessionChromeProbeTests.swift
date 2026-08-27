import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: send/queue consults hasProviderSession on MainActor. That used to
/// full-get 26 columns + routing JSON just to learn which adapter owns the
/// thread.
final class ProviderSessionChromeProbeTests: XCTestCase {
    private func makeRepos(_ label: String) throws -> (AgentThreadRepository, AgentMessageRepository, AgentRunRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (AgentThreadRepository(db: db), AgentMessageRepository(db: db), AgentRunRepository(db: db))
    }

    func test_hasProviderSession_usesListChromeWithoutDurableGet() throws {
        let (threadRepo, messageRepo, runRepo) = try makeRepos("session-chrome")
        let thread = AgentThread(title: "session", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let adapter = LiveSessionAdapter(threadId: thread.id)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerAdapters: [.codex: adapter]
        )
        let getsBefore = threadRepo.durableGetCountForTesting
        let chromeBefore = threadRepo.listChromeCallCountForTesting
        XCTAssertTrue(coordinator.hasProviderSession(threadId: thread.id))
        XCTAssertEqual(
            threadRepo.durableGetCountForTesting,
            getsBefore,
            "hasProviderSession must not compile a full 26-column get just to read provider"
        )
        XCTAssertEqual(threadRepo.listChromeCallCountForTesting, chromeBefore + 1)

        let missingGets = threadRepo.durableGetCountForTesting
        XCTAssertFalse(coordinator.hasProviderSession(threadId: AgentThreadID()))
        XCTAssertEqual(
            threadRepo.durableGetCountForTesting,
            missingGets,
            "a missing thread must fail on listChrome, not a full get"
        )
    }

    func test_adapterForThread_sourceUsesListChrome() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/AgentRuntime/AgentRunCoordinator.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "private func adapterForThread(_ threadId: AgentThreadID)"))
        let body = String(source[range.lowerBound...].prefix(900))
        XCTAssertTrue(body.contains("threadRepo.listChrome(ids: [threadId])"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadId)"))
    }

    func test_listChrome_fasterThanDurableGet() throws {
        let (threadRepo, _, _) = try makeRepos("session-chrome-bench")
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
            "[perf-proof] adapter-for-thread listChrome_ms=%@ durable_get_ms=%@ improvement_pct=%.2f chrome=%@ get=%@",
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

private final class LiveSessionAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let threadId: AgentThreadID

    init(threadId: AgentThreadID) {
        self.threadId = threadId
    }

    func listModels() async -> [AgentModelDescriptor] { [] }
    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func interruptTurn(threadId: AgentThreadID) throws {}
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {}
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {}
    func cancelUserInput(threadId: AgentThreadID, requestId: String) throws {}
    func stopSession(threadId: AgentThreadID) throws {}
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] {
        [AgentProviderSessionSummary(
            threadId: threadId,
            provider: .codex,
            status: .running,
            providerThreadId: nil
        )]
    }
    func hasSession(threadId: AgentThreadID) -> Bool { threadId == self.threadId }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
    func forkThread(threadId: AgentThreadID) async throws -> String { "child" }
    func forkThread(_ request: AgentProviderForkRequest) async throws -> String { "child" }
    func compensateFork(_ request: AgentProviderForkRequest, providerChildThreadId: String) async throws {}
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func stopAllForAppTermination() {}
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}
}
