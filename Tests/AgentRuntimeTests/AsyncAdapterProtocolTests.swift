import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// Async-adapter conversion proof (macos:38 / perf:24 / perf:114).
///
/// WHY: `respondToRequest`, `recoverSession`, `readThread`, and `rollbackThread`
/// were converted from synchronous `throws` to `async throws` so the
/// CodexAppServerAdapter no longer bridges the async app-server client by
/// blocking the calling thread (often @MainActor) on a `DispatchSemaphore`.
/// That bridge caused 10-30s UI freezes on thread-open / approval / rollback.
///
/// These tests pin the intent at the coordinator seam (public, reachable):
///  1. The async coordinator methods forward to the adapter via `await` and
///     surface its return value / thrown error — the chain must actually reach
///     the provider, not silently no-op after the rewrite.
///  2. A coordinator call whose adapter suspends on a continuation does NOT
///     complete until the continuation is resumed. A semaphore bridge would
///     have blocked a thread instead of suspending; suspension is the whole
///     point of the conversion.
final class AsyncAdapterProtocolTests: XCTestCase {

    // MARK: - Fake adapter

    /// Records call order and lets a test suspend a chosen method on a
    /// continuation so suspension (not blocking) can be observed.
    private final class FakeAdapter: AgentProviderAdapter, @unchecked Sendable {
        let provider: AgentProvider = .codex
        let forkSafety: AgentProviderForkSafety = .keyedIdempotent(compensationSupported: true)

        // Call-order log (serialized via lock).
        private let lock = NSLock()
        private(set) var calls: [String] = []
        private func log(_ name: String) { lock.lock(); calls.append(name); lock.unlock() }

        // Forwarding-test fixtures.
        var readThreadResult: [AssistantEvent] = []
        var forkThreadResult = "provider-child"
        var rollbackError: Error?
        var respondError: Error?

        // Suspension hook: when set for a method, that method parks on the
        // continuation until the test resumes it.
        var suspendReadThread = false
        private let suspendLock = NSLock()
        private var readContinuation: CheckedContinuation<Void, Never>?
        private var readSuspendedSignal: (() -> Void)?

        /// Test calls this to be notified the moment readThread has parked.
        func onReadThreadSuspended(_ signal: @escaping () -> Void) {
            suspendLock.lock(); readSuspendedSignal = signal; suspendLock.unlock()
        }
        /// Test calls this to let a parked readThread proceed.
        func resumeReadThread() {
            suspendLock.lock()
            let c = readContinuation
            readContinuation = nil
            suspendLock.unlock()
            c?.resume()
        }

        // hasSession returns true so the coordinator's recovery short-circuits
        // and forwards straight to the adapter under test.
        func hasSession(threadId: AgentThreadID) -> Bool { true }

        func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] {
            log("readThread")
            if suspendReadThread {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    suspendLock.lock()
                    readContinuation = c
                    let signal = readSuspendedSignal
                    suspendLock.unlock()
                    signal?()
                }
            }
            return readThreadResult
        }

        func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {
            log("rollbackThread")
            if let rollbackError { throw rollbackError }
        }

        func forkThread(threadId: AgentThreadID) async throws -> String {
            log("forkThread")
            return forkThreadResult
        }

        func forkThread(_ request: AgentProviderForkRequest) async throws -> String {
            log("forkThread")
            return forkThreadResult
        }

        func compensateFork(_ request: AgentProviderForkRequest, providerChildThreadId: String) async throws {}

        func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
            log("respondToRequest")
            if let respondError { throw respondError }
        }

        func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {
            log("recoverSession")
        }

        // Unused protocol surface for these tests.
        func listModels() async -> [AgentModelDescriptor] { [] }
        func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
            AgentRunHandle(runId: request.runId, process: nil, cancel: {})
        }
        func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
            AgentRunHandle(runId: request.runId, process: nil, cancel: {})
        }
        func interruptTurn(threadId: AgentThreadID) throws {}
        func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {}
        func stopSession(threadId: AgentThreadID) throws {}
        func listSessions() -> [AgentProviderSessionSummary] { [] }
        func stopAll() {}
        func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}
    }

    private struct TestError: Error, Equatable { let tag: String }

    // MARK: - Harness

    private func makeCoordinator(adapter: AgentProviderAdapter) throws -> (AgentRunCoordinator, AgentThreadID) {
        let tmp = NSTemporaryDirectory() + "rc2-async-adapter-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "async-adapter", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerAdapters: [:]
        )
        coordinator.replaceProviderAdapter(.codex, adapter: adapter)
        return (coordinator, thread.id)
    }

    // MARK: - Forwarding

    func test_readThread_forwardsToAdapterAndReturnsItsEvents() async throws {
        // WHY: the async coordinator.readThread must reach the provider adapter
        // and return exactly what the provider produced; a no-op rewrite would
        // silently drop the provider snapshot used to replay the thread.
        let adapter = FakeAdapter()
        adapter.readThreadResult = [.error(message: "snapshot-event", recoverable: true)]
        let (coordinator, threadId) = try makeCoordinator(adapter: adapter)

        let events = try await coordinator.readThread(threadId: threadId)

        XCTAssertEqual(adapter.calls, ["readThread"], "coordinator.readThread must forward to the adapter")
        guard case .error(let message, _)? = events.first else {
            return XCTFail("coordinator must return the adapter's events unchanged")
        }
        XCTAssertEqual(message, "snapshot-event")
    }

    func test_rollbackThread_propagatesAdapterError() async throws {
        // WHY: rollback failures must surface to the RPC caller (e.g. an invalid
        // checkpoint), not be swallowed by the async bridge.
        let adapter = FakeAdapter()
        adapter.rollbackError = TestError(tag: "rollback")
        let (coordinator, threadId) = try makeCoordinator(adapter: adapter)

        do {
            try await coordinator.rollbackThread(threadId: threadId, toTurnId: "turn-1")
            XCTFail("coordinator.rollbackThread must rethrow the adapter error")
        } catch let error as TestError {
            XCTAssertEqual(error, TestError(tag: "rollback"))
        }
        XCTAssertEqual(adapter.calls, ["rollbackThread"])
    }

    func test_forkThread_persistsDistinctChildProviderContextWithoutMutatingParent() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-native-fork-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let parent = AgentThread(
            workspaceId: WorkspaceID(),
            title: "parent",
            provider: .codex,
            providerInstanceId: "codex-work",
            model: "fake-model",
            providerThreadId: "provider-parent",
            permissionMode: .fullAccess,
            reasoningEffort: .high,
            executionMode: .worktree,
            baseBranch: "main",
            worktreePath: tmp,
            serviceTier: .fast,
            interactionMode: .plan
        )
        let child = AgentThread(
            workspaceId: parent.workspaceId,
            title: "child",
            provider: .codex,
            providerInstanceId: parent.providerInstanceId,
            model: "fake-model",
            permissionMode: parent.permissionMode,
            reasoningEffort: parent.reasoningEffort,
            executionMode: parent.executionMode,
            baseBranch: parent.baseBranch,
            worktreePath: parent.worktreePath,
            serviceTier: parent.serviceTier,
            modelSelection: parent.modelSelection,
            interactionMode: parent.effectiveInteractionMode
        )
        let attachment = AgentAttachment(
            path: "/tmp/identity-proof.png",
            displayName: "identity-proof.png",
            kind: .image,
            mimeType: "image/png"
        )
        try threadRepo.upsert(parent)
        try messageRepo.append(AgentMessage(threadId: parent.id, role: .user, content: "q1", attachments: [attachment]))
        try messageRepo.append(AgentMessage(threadId: parent.id, role: .assistant, content: "a1"))
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: parent.id,
            provider: .codex,
            status: .completed,
            resumeCursor: "provider-parent",
            cwd: tmp,
            model: "fake-model"
        ))
        let adapter = FakeAdapter()
        adapter.forkThreadResult = "provider-child"
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providerAdapters: [.codex: adapter]
        )

        let forked = try await coordinator.forkThread(sourceThreadId: parent.id, childThread: child)

        XCTAssertEqual(adapter.calls, ["forkThread"])
        XCTAssertEqual(forked.providerThreadId, "provider-child")
        XCTAssertEqual(try threadRepo.get(id: child.id)?.providerThreadId, "provider-child")
        XCTAssertEqual(try sessionRepo.get(threadId: child.id)?.resumeCursor, "provider-child",
                       "the first dependent child question must resume the provider-native branch")
        let copied = try messageRepo.list(threadId: child.id)
        XCTAssertEqual(copied.map(\.content), ["q1", "a1"],
                       "the child graph must atomically include the complete visible parent transcript")
        XCTAssertEqual(copied.first?.attachments, [attachment],
                       "fork must preserve attachment identity metadata exactly, not rebuild or detach it")
        XCTAssertEqual(try threadRepo.get(id: child.id)?.permissionMode, parent.permissionMode)
        XCTAssertEqual(try threadRepo.get(id: child.id)?.executionMode, parent.executionMode)
        XCTAssertEqual(try threadRepo.get(id: child.id)?.effectiveInteractionMode, parent.effectiveInteractionMode)
        XCTAssertEqual(try threadRepo.get(id: parent.id)?.providerThreadId, "provider-parent")
        XCTAssertEqual(try sessionRepo.get(threadId: parent.id)?.resumeCursor, "provider-parent",
                       "forking must not redirect later parent turns into the child session")
    }

    func test_forkThread_sessionWriteFailureRollsBackEntireLocalChildGraph() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-native-fork-atomic-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let parent = AgentThread(title: "parent", provider: .codex, model: "fake-model", providerThreadId: "provider-parent")
        let child = AgentThread(title: "child", provider: .codex, model: "fake-model")
        try threadRepo.upsert(parent)
        try messageRepo.append(AgentMessage(threadId: parent.id, role: .user, content: "must copy"))
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: parent.id,
            provider: .codex,
            status: .completed,
            resumeCursor: "provider-parent",
            cwd: tmp,
            model: "fake-model"
        ))
        try db.execute("""
            CREATE TRIGGER fail_child_session
            BEFORE INSERT ON provider_session_runtime
            WHEN NEW.thread_id = '\(child.id.value.uuidString)'
            BEGIN SELECT RAISE(ABORT, 'injected child session failure'); END;
            """)
        let adapter = FakeAdapter()
        adapter.forkThreadResult = "provider-child"
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providerAdapters: [.codex: adapter]
        )

        do {
            _ = try await coordinator.forkThread(sourceThreadId: parent.id, childThread: child)
            XCTFail("fault injection after child/thread transcript writes must fail the fork")
        } catch {
            XCTAssertTrue(String(describing: error).contains("injected child session failure"))
        }

        XCTAssertNil(try threadRepo.get(id: child.id),
                     "any child graph write failure must roll back the child thread row")
        XCTAssertTrue(try messageRepo.list(threadId: child.id).isEmpty,
                      "any child graph write failure must roll back copied messages and attachment references")
        XCTAssertNil(try sessionRepo.get(threadId: child.id),
                     "any child graph write failure must leave no child provider-session row")
        XCTAssertEqual(try threadRepo.get(id: parent.id)?.providerThreadId, "provider-parent",
                       "local rollback must not mutate the parent graph")
    }

    func test_respondToRequest_propagatesAdapterError() async throws {
        // WHY: an approval that fails at the provider must propagate so the UI
        // marks the request stale instead of falsely showing it resolved.
        let adapter = FakeAdapter()
        adapter.respondError = TestError(tag: "approve")
        let (coordinator, threadId) = try makeCoordinator(adapter: adapter)

        do {
            try await coordinator.respondToRequest(threadId: threadId, requestId: "req-1", response: .approve)
            XCTFail("coordinator.respondToRequest must rethrow the adapter error")
        } catch let error as TestError {
            XCTAssertEqual(error, TestError(tag: "approve"))
        }
        XCTAssertEqual(adapter.calls, ["respondToRequest"])
    }

    // MARK: - Suspension (freeze-elimination intent)

    func test_readThread_suspendsUntilAdapterResumes_doesNotBlock() async throws {
        // WHY: the conversion exists so the call SUSPENDS (yields the thread)
        // instead of blocking on a semaphore. Prove the coordinator call has not
        // completed while the adapter is parked, and completes only once the
        // adapter's continuation is resumed.
        let adapter = FakeAdapter()
        adapter.suspendReadThread = true
        let (coordinator, threadId) = try makeCoordinator(adapter: adapter)

        let parked = expectation(description: "adapter parked on continuation")
        adapter.onReadThreadSuspended { parked.fulfill() }

        let completed = expectation(description: "coordinator.readThread completed")
        let task = Task {
            _ = try await coordinator.readThread(threadId: threadId)
            completed.fulfill()
        }

        // The adapter must reach its suspension point...
        await fulfillment(of: [parked], timeout: 2)
        // ...and the coordinator call must still be in flight (suspended, not done).
        XCTAssertEqual(adapter.calls, ["readThread"])

        // Resuming the continuation lets the suspended call finish.
        adapter.resumeReadThread()
        await fulfillment(of: [completed], timeout: 2)
        _ = try await task.value
    }
}
