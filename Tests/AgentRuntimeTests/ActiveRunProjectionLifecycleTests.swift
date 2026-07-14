import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

final class ActiveRunProjectionLifecycleTests: XCTestCase {
    private final class ControlledRunner: AgentProviderRunner, @unchecked Sendable {
        let provider: AgentProvider = .codex
        private let lock = NSLock()
        private var callbacks: [AgentRunID: @Sendable (AgentRunEvent) -> Void] = [:]

        func listModels() async -> [AgentModelDescriptor] { [] }

        func startRun(
            _ request: AgentRunRequest,
            onEvent: @escaping @Sendable (AgentRunEvent) -> Void
        ) async throws -> AgentRunHandle {
            lock.withLock { callbacks[request.runId] = onEvent }
            return AgentRunHandle(runId: request.runId, process: nil) {}
        }

        func finish(_ runId: AgentRunID, status: AgentRunStatus = .completed) {
            let callback = lock.withLock { callbacks[runId] }
            callback?(.finished(status, finalMessage: "done", providerThreadId: nil))
        }
    }

    private struct StartFailure: Error {}

    private final class FailingRunner: AgentProviderRunner, @unchecked Sendable {
        let provider: AgentProvider = .codex
        func listModels() async -> [AgentModelDescriptor] { [] }
        func startRun(
            _ request: AgentRunRequest,
            onEvent: @escaping @Sendable (AgentRunEvent) -> Void
        ) async throws -> AgentRunHandle {
            throw StartFailure()
        }
    }

    private final class ProjectionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [ActiveRunProjection] = []

        func append(_ projection: ActiveRunProjection) {
            lock.withLock { values.append(projection) }
        }

        var snapshots: [ActiveRunProjection] { lock.withLock { values } }
    }

    private func makeCoordinator(
        runner: AgentProviderRunner,
        label: String
    ) throws -> (AgentRunCoordinator, AgentThreadRepository, String) {
        let tmp = NSTemporaryDirectory() + "rc2-active-projection-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: AgentMessageRepository(db: db),
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        return (coordinator, threadRepo, tmp)
    }

    func testStartPublishesOnlyAfterActiveRegistration() async throws {
        let runner = ControlledRunner()
        let (coordinator, threadRepo, tmp) = try makeCoordinator(runner: runner, label: "commit-order")
        let thread = AgentThread(title: "one", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let recorder = ProjectionRecorder()

        coordinator.onActiveRunProjectionChanged = { projection, _ in
            XCTAssertEqual(
                coordinator.activeThreadIdsSnapshot().count,
                projection.activeRunCount,
                "the host projection must publish only after activeThreads commits"
            )
            recorder.append(projection)
        }

        let runId = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: "work"
        ))

        XCTAssertEqual(recorder.snapshots.map(\.activeRunCount), [1])
        XCTAssertEqual(recorder.snapshots.last?.primaryRunId, runId)
    }

    func testFailedPreRegistrationStartDoesNotPublishFalseActiveProjection() async throws {
        let (coordinator, threadRepo, tmp) = try makeCoordinator(runner: FailingRunner(), label: "failed-start")
        let thread = AgentThread(title: "fails", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let recorder = ProjectionRecorder()
        coordinator.onActiveRunProjectionChanged = { projection, _ in recorder.append(projection) }

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: "fail"
            ))
            XCTFail("start must fail")
        } catch is StartFailure {}

        XCTAssertTrue(
            recorder.snapshots.isEmpty,
            "a provider failure before activeThreads registration must never flash a running Live Activity"
        )
    }

    func testTwoRunsProjectTwoThenOneThenFinalZero() async throws {
        let runner = ControlledRunner()
        let (coordinator, threadRepo, tmp) = try makeCoordinator(runner: runner, label: "aggregate")
        let firstThread = AgentThread(title: "first", provider: .codex, model: "fake-model")
        let secondThread = AgentThread(title: "second", provider: .codex, model: "fake-model")
        try threadRepo.upsert(firstThread)
        try threadRepo.upsert(secondThread)
        let recorder = ProjectionRecorder()
        coordinator.onActiveRunProjectionChanged = { projection, _ in recorder.append(projection) }

        let firstRun = AgentRunID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let secondRun = AgentRunID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        _ = try await coordinator.startRun(AgentRunRequest(
            runId: firstRun, threadId: firstThread.id, provider: .codex,
            model: "fake-model", cwd: tmp, prompt: "first"
        ))
        _ = try await coordinator.startRun(AgentRunRequest(
            runId: secondRun, threadId: secondThread.id, provider: .codex,
            model: "fake-model", cwd: tmp, prompt: "second"
        ))

        XCTAssertEqual(recorder.snapshots.last?.activeRunCount, 2)
        XCTAssertEqual(
            recorder.snapshots.last?.primaryRunId,
            secondRun,
            "primary selection must be deterministic instead of dictionary-order dependent"
        )

        runner.finish(secondRun)
        XCTAssertEqual(recorder.snapshots.last?.activeRunCount, 1)
        XCTAssertEqual(recorder.snapshots.last?.primaryRunId, firstRun)

        runner.finish(firstRun)
        XCTAssertEqual(recorder.snapshots.last?.activeRunCount, 0)
        XCTAssertNil(recorder.snapshots.last?.primaryRunId)
        XCTAssertEqual(recorder.snapshots.map(\.activeRunCount), [1, 2, 1, 0])
    }

    func testLaunchReconciliationPublishesEmptyCorrection() throws {
        let (coordinator, _, _) = try makeCoordinator(runner: ControlledRunner(), label: "launch")
        let recorder = ProjectionRecorder()
        coordinator.onActiveRunProjectionChanged = { projection, _ in recorder.append(projection) }

        try coordinator.reconcileOnLaunch()

        XCTAssertEqual(recorder.snapshots.map(\.activeRunCount), [0],
                       "a host restart must emit an empty correction so stale remote cards can end")
    }
}
