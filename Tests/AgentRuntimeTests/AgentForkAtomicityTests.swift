import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// AG031: provider/local fork must be one recoverable operation.
///
/// WHY: provider-first fork followed by a local transaction can orphan a
/// provider child when the process dies between those operations. These tests
/// pin the only safe contract: stable local child identity, keyed provider
/// idempotency, durable state transitions, atomic local graph commit, and
/// idempotent compensation when local completion becomes impossible.
final class AgentForkAtomicityTests: XCTestCase {
    private final class KeyedForkAdapter: AgentProviderAdapter, @unchecked Sendable {
        let provider: AgentProvider
        let forkSafety: AgentProviderForkSafety

        private let lock = NSLock()
        private var childrenByKey: [String: String] = [:]
        private var _forkRequests: [AgentProviderForkRequest] = []
        private var _providerCreations = 0
        private var _compensationCalls = 0
        private var _failForkCount = 0
        private var _failCompensationCount = 0
        private var _onFork: (() throws -> Void)?

        init(
            provider: AgentProvider = .codex,
            safety: AgentProviderForkSafety = .keyedIdempotent(compensationSupported: true)
        ) {
            self.provider = provider
            self.forkSafety = safety
        }

        var forkRequests: [AgentProviderForkRequest] { withLock { _forkRequests } }
        var providerCreations: Int { withLock { _providerCreations } }
        var compensationCalls: Int { withLock { _compensationCalls } }
        var providerChildren: [String: String] { withLock { childrenByKey } }

        func failNextForks(_ count: Int) { withLock { _failForkCount = count } }
        func failNextCompensations(_ count: Int) { withLock { _failCompensationCount = count } }
        func onFork(_ action: @escaping () throws -> Void) { withLock { _onFork = action } }

        func forkThread(_ request: AgentProviderForkRequest) async throws -> String {
            let result: (String, (() throws -> Void)?) = try withLock {
                _forkRequests.append(request)
                if _failForkCount > 0 {
                    _failForkCount -= 1
                    throw TestFailure.provider
                }
                if let existing = childrenByKey[request.idempotencyKey] {
                    return (existing, _onFork)
                }
                let child = "provider-child-\(request.childThreadId.value.uuidString.lowercased())"
                childrenByKey[request.idempotencyKey] = child
                _providerCreations += 1
                return (child, _onFork)
            }
            try result.1?()
            return result.0
        }

        func compensateFork(
            _ request: AgentProviderForkRequest,
            providerChildThreadId: String
        ) async throws {
            try withLock {
                _compensationCalls += 1
                if _failCompensationCount > 0 {
                    _failCompensationCount -= 1
                    throw TestFailure.compensation
                }
                if childrenByKey[request.idempotencyKey] == providerChildThreadId {
                    childrenByKey.removeValue(forKey: request.idempotencyKey)
                }
            }
        }

        func hasSession(threadId: AgentThreadID) -> Bool { true }
        func listModels() async -> [AgentModelDescriptor] { [] }
        func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
            AgentRunHandle(runId: request.runId, process: nil, cancel: {})
        }
        func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
            AgentRunHandle(runId: request.runId, process: nil, cancel: {})
        }
        func interruptTurn(threadId: AgentThreadID) throws {}
        func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {}
        func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {}
        func stopSession(threadId: AgentThreadID) throws {}
        func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
        func listSessions() -> [AgentProviderSessionSummary] { [] }
        func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
        func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
        func stopAll() {}
        func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}

        private func withLock<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock(); defer { lock.unlock() }
            return try body()
        }
    }

    private enum TestFailure: Error { case provider, compensation }

    private struct Harness {
        let root: String
        let db: SQLiteDB
        let threadRepo: AgentThreadRepository
        let messageRepo: AgentMessageRepository
        let sessionRepo: ProviderSessionRuntimeRepository
        let parent: AgentThread
        let child: AgentThread

        func coordinator(adapter: AgentProviderAdapter) -> AgentRunCoordinator {
            AgentRunCoordinator(
                runRepo: AgentRunRepository(db: db),
                messageRepo: messageRepo,
                threadRepo: threadRepo,
                providerSessionRepo: sessionRepo,
                providerAdapters: [adapter.provider: adapter]
            )
        }
    }

    private func makeHarness(provider: AgentProvider = .codex) throws -> Harness {
        let root = NSTemporaryDirectory() + "rc2-fork-atomicity-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let parent = AgentThread(
            workspaceId: WorkspaceID(),
            title: "parent",
            provider: provider,
            model: "model",
            providerThreadId: "provider-parent",
            status: .completed,
            worktreePath: root
        )
        let child = AgentThread(
            workspaceId: parent.workspaceId,
            title: "child",
            provider: provider,
            model: parent.model,
            status: .completed,
            worktreePath: root
        )
        try threadRepo.upsert(parent)
        try messageRepo.append(AgentMessage(threadId: parent.id, role: .user, content: "question"))
        try messageRepo.append(AgentMessage(threadId: parent.id, role: .assistant, content: "answer"))
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: parent.id,
            provider: provider,
            status: .completed,
            resumeCursor: "provider-parent",
            cwd: root,
            model: "model"
        ))
        return Harness(
            root: root,
            db: db,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            sessionRepo: sessionRepo,
            parent: parent,
            child: child
        )
    }

    private func stableKey(_ child: AgentThreadID) -> String {
        "remotecode-thread-fork:\(child.value.uuidString.lowercased())"
    }

    private func assertNoLocalChild(_ harness: Harness, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertNil(try harness.threadRepo.get(id: harness.child.id), file: file, line: line)
        XCTAssertTrue(try harness.messageRepo.list(threadId: harness.child.id).isEmpty, file: file, line: line)
        XCTAssertNil(try harness.sessionRepo.get(threadId: harness.child.id), file: file, line: line)
    }

    private func sourceMessagesJSONByteCount(_ harness: Harness) throws -> Int {
        let statement = try harness.db.prepare("""
            SELECT length(CAST(source_messages_json AS BLOB))
            FROM agent_thread_fork_intents WHERE child_thread_id = ?;
        """)
        try statement.bind(1, harness.child.id.value.uuidString)
        guard try statement.step() else { return 0 }
        return Int(statement.columnInt64(0))
    }

    func test_unsafeProvidersFailClosedBeforeProviderOrLocalMutation() async throws {
        for provider in AgentProvider.allCases {
            let harness = try makeHarness(provider: provider)
            let adapter = KeyedForkAdapter(provider: provider, safety: .unsupported)
            do {
                _ = try await harness.coordinator(adapter: adapter).forkThread(
                    sourceThreadId: harness.parent.id,
                    childThread: harness.child
                )
                XCTFail("\(provider.rawValue) must reject a fork without a crash-safe adapter contract")
            } catch {
                XCTAssertTrue(String(describing: error).contains("not crash-safe"))
            }
            XCTAssertTrue(adapter.forkRequests.isEmpty,
                          "unsafe \(provider.rawValue) adapter must not receive a provider mutation")
            XCTAssertNil(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id),
                         "unsafe \(provider.rawValue) adapter must not create a misleading local intent")
            try assertNoLocalChild(harness)
        }
    }

    func test_productionAdaptersDeclareForkUnsafeAndCoordinatorNeverLaunchesThem() async throws {
        let adapters: [AgentProviderAdapter] = [
            CodexAppServerAdapter(binaryNameOverride: "/definitely/missing/codex"),
            ClaudeStreamingCLIAdapter(binaryNameOverride: "/definitely/missing/claude"),
            GrokACPAdapter(binaryNameOverride: "/definitely/missing/grok")
        ]

        for adapter in adapters {
            XCTAssertEqual(adapter.forkSafety, .unsupported,
                           "\(adapter.provider.rawValue) must not claim a keyed contract its provider protocol does not expose")
            let harness = try makeHarness(provider: adapter.provider)
            do {
                _ = try await harness.coordinator(adapter: adapter).forkThread(
                    sourceThreadId: harness.parent.id,
                    childThread: harness.child
                )
                XCTFail("\(adapter.provider.rawValue) production adapter must fail closed")
            } catch {
                XCTAssertTrue(String(describing: error).contains("not crash-safe"),
                              "the safety gate must run before any missing-binary/provider call: \(error)")
            }
            XCTAssertNil(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id))
            try assertNoLocalChild(harness)
        }
    }

    func test_preparedIntentRelaunchCreatesProviderAndLocalChildExactlyOnce() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        _ = try harness.threadRepo.prepareForkIntent(
            sourceThreadId: harness.parent.id,
            childThread: harness.child,
            idempotencyKey: stableKey(harness.child.id)
        )

        let relaunched = harness.coordinator(adapter: adapter)
        try relaunched.reconcileOnLaunch()
        await relaunched.waitForForkReconciliation()

        XCTAssertEqual(adapter.forkRequests.count, 1)
        XCTAssertEqual(adapter.providerCreations, 1)
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .localCommitted)
        XCTAssertNotNil(try harness.threadRepo.get(id: harness.child.id))
        XCTAssertEqual(try harness.messageRepo.list(threadId: harness.child.id).map(\.content), ["question", "answer"])

        let secondRelaunch = harness.coordinator(adapter: adapter)
        try secondRelaunch.reconcileOnLaunch()
        await secondRelaunch.waitForForkReconciliation()
        XCTAssertEqual(adapter.forkRequests.count, 1,
                       "a locally committed intent is terminal and must not call the provider on later launches")
        XCTAssertEqual(adapter.providerCreations, 1)
    }

    func test_forkIntentTranscriptSurvivesRecoverableStatesAndClearsInEveryTerminalTombstone() throws {
        let payloadBytes = 256 * 1024

        func prepareLargeIntent(_ harness: Harness, suffix: String) throws -> AgentThreadForkIntent {
            try harness.messageRepo.append(AgentMessage(
                threadId: harness.parent.id,
                role: .user,
                content: String(repeating: suffix, count: payloadBytes)
            ))
            return try harness.threadRepo.prepareForkIntent(
                sourceThreadId: harness.parent.id,
                childThread: harness.child,
                idempotencyKey: "\(stableKey(harness.child.id))-\(suffix)"
            )
        }

        func assertIdentity(
            _ actual: AgentThreadForkIntent,
            prepared: AgentThreadForkIntent,
            state: AgentThreadForkIntentState,
            providerChildThreadId: String?,
            lastError: String?,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertEqual(actual.state, state, file: file, line: line)
            XCTAssertEqual(actual.sourceThreadId, prepared.sourceThreadId, file: file, line: line)
            XCTAssertEqual(actual.childThread, prepared.childThread, file: file, line: line)
            XCTAssertEqual(actual.provider, prepared.provider, file: file, line: line)
            XCTAssertEqual(actual.idempotencyKey, prepared.idempotencyKey, file: file, line: line)
            XCTAssertEqual(actual.providerChildThreadId, providerChildThreadId, file: file, line: line)
            XCTAssertEqual(actual.lastError, lastError, file: file, line: line)
        }

        let committedHarness = try makeHarness()
        let committedPrepared = try prepareLargeIntent(committedHarness, suffix: "L")
        let committedPreparedBytes = try sourceMessagesJSONByteCount(committedHarness)
        XCTAssertGreaterThan(committedPreparedBytes, payloadBytes,
                             "prepared must retain the complete fork-boundary transcript")
        let committedProviderID = "provider-local-committed"
        let providerCreated = try committedHarness.threadRepo.recordForkProviderCreated(
            childThreadId: committedHarness.child.id,
            providerChildThreadId: committedProviderID
        )
        assertIdentity(providerCreated, prepared: committedPrepared, state: .providerCreated,
                       providerChildThreadId: committedProviderID, lastError: nil)
        XCTAssertEqual(try sourceMessagesJSONByteCount(committedHarness), committedPreparedBytes,
                       "provider_created recovery still needs the exact prepared transcript")
        var committedChild = committedHarness.child
        committedChild.providerThreadId = committedProviderID
        _ = try committedHarness.threadRepo.persistForkedChildGraphReturningPrunedThreadIDs(
            sourceThreadId: committedHarness.parent.id,
            childThread: committedChild,
            providerSession: nil,
            forkIntentChildThreadId: committedChild.id
        )
        let localCommitted = try XCTUnwrap(
            committedHarness.threadRepo.getForkIntent(childThreadId: committedChild.id)
        )
        assertIdentity(localCommitted, prepared: committedPrepared, state: .localCommitted,
                       providerChildThreadId: committedProviderID, lastError: nil)
        XCTAssertTrue(localCommitted.sourceMessages.isEmpty)
        XCTAssertEqual(try sourceMessagesJSONByteCount(committedHarness), 2,
                       "local_committed must retain only the [] tombstone payload")

        let compensatedHarness = try makeHarness()
        let compensatedPrepared = try prepareLargeIntent(compensatedHarness, suffix: "C")
        let compensatedPreparedBytes = try sourceMessagesJSONByteCount(compensatedHarness)
        let compensatedProviderID = "provider-compensated"
        _ = try compensatedHarness.threadRepo.recordForkProviderCreated(
            childThreadId: compensatedHarness.child.id,
            providerChildThreadId: compensatedProviderID
        )
        let compensatingError = "local graph conflict"
        let compensating = try compensatedHarness.threadRepo.markForkCompensating(
            childThreadId: compensatedHarness.child.id,
            error: compensatingError
        )
        assertIdentity(compensating, prepared: compensatedPrepared, state: .compensating,
                       providerChildThreadId: compensatedProviderID, lastError: compensatingError)
        XCTAssertEqual(try sourceMessagesJSONByteCount(compensatedHarness), compensatedPreparedBytes,
                       "compensating retry must retain the recovery transcript")
        try compensatedHarness.threadRepo.markForkCompensated(childThreadId: compensatedHarness.child.id)
        let compensated = try XCTUnwrap(
            compensatedHarness.threadRepo.getForkIntent(childThreadId: compensatedHarness.child.id)
        )
        assertIdentity(compensated, prepared: compensatedPrepared, state: .compensated,
                       providerChildThreadId: compensatedProviderID, lastError: nil)
        XCTAssertTrue(compensated.sourceMessages.isEmpty)
        XCTAssertEqual(try sourceMessagesJSONByteCount(compensatedHarness), 2,
                       "compensated must retain only the [] tombstone payload")

        let abandonedHarness = try makeHarness()
        let abandonedPrepared = try prepareLargeIntent(abandonedHarness, suffix: "A")
        XCTAssertGreaterThan(try sourceMessagesJSONByteCount(abandonedHarness), payloadBytes)
        let abandonedError = "source disappeared before provider creation"
        try abandonedHarness.threadRepo.markPreparedForkAbandoned(
            childThreadId: abandonedHarness.child.id,
            error: abandonedError
        )
        let abandoned = try XCTUnwrap(
            abandonedHarness.threadRepo.getForkIntent(childThreadId: abandonedHarness.child.id)
        )
        assertIdentity(abandoned, prepared: abandonedPrepared, state: .abandoned,
                       providerChildThreadId: nil, lastError: abandonedError)
        XCTAssertTrue(abandoned.sourceMessages.isEmpty)
        XCTAssertEqual(try sourceMessagesJSONByteCount(abandonedHarness), 2,
                       "abandoned must retain only the [] tombstone payload")
    }

    func test_parentRunCannotRaceAheadOfPreparedLaunchRecovery() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        _ = try harness.threadRepo.prepareForkIntent(
            sourceThreadId: harness.parent.id,
            childThread: harness.child,
            idempotencyKey: stableKey(harness.child.id)
        )
        let coordinator = harness.coordinator(adapter: adapter)

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                threadId: harness.parent.id,
                provider: .codex,
                model: "model",
                cwd: harness.root,
                prompt: "must wait for relaunch recovery"
            ))
            XCTFail("a parent run must not change the provider snapshot before its prepared fork recovers")
        } catch {
            XCTAssertTrue(String(describing: error).contains("cannot overtake durable fork recovery"))
        }
        XCTAssertFalse(try harness.messageRepo.list(threadId: harness.parent.id).contains {
            $0.content == "must wait for relaunch recovery"
        })

        try coordinator.reconcileOnLaunch()
        await coordinator.waitForForkReconciliation()
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .localCommitted)
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: harness.parent.id,
            provider: .codex,
            model: "model",
            cwd: harness.root,
            prompt: "allowed after fork recovery"
        ))
        XCTAssertTrue(try harness.messageRepo.list(threadId: harness.parent.id).contains {
            $0.content == "allowed after fork recovery"
        })
    }

    func test_providerCreatedIntentRelaunchCommitsLocallyWithoutReforking() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        let intent = try harness.threadRepo.prepareForkIntent(
            sourceThreadId: harness.parent.id,
            childThread: harness.child,
            idempotencyKey: stableKey(harness.child.id)
        )
        let request = AgentProviderForkRequest(
            sourceThreadId: harness.parent.id,
            childThreadId: harness.child.id,
            idempotencyKey: intent.idempotencyKey
        )
        let providerChild = try await adapter.forkThread(request)
        _ = try harness.threadRepo.recordForkProviderCreated(
            childThreadId: harness.child.id,
            providerChildThreadId: providerChild
        )

        let requestCountBeforeRelaunch = adapter.forkRequests.count
        let relaunched = harness.coordinator(adapter: adapter)
        try relaunched.reconcileOnLaunch()
        await relaunched.waitForForkReconciliation()

        XCTAssertEqual(adapter.forkRequests.count, requestCountBeforeRelaunch,
                       "provider_created must continue at the local commit, never fork again")
        XCTAssertEqual(adapter.providerCreations, 1)
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .localCommitted)
        XCTAssertEqual(try harness.threadRepo.get(id: harness.child.id)?.providerThreadId, providerChild)
    }

    func test_recoveryCopiesPreparedTranscriptSnapshotNotLaterParentMessages() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        let intent = try harness.threadRepo.prepareForkIntent(
            sourceThreadId: harness.parent.id,
            childThread: harness.child,
            idempotencyKey: stableKey(harness.child.id)
        )
        let request = AgentProviderForkRequest(
            sourceThreadId: harness.parent.id,
            childThreadId: harness.child.id,
            idempotencyKey: intent.idempotencyKey
        )
        let providerChild = try await adapter.forkThread(request)
        _ = try harness.threadRepo.recordForkProviderCreated(
            childThreadId: harness.child.id,
            providerChildThreadId: providerChild
        )
        try harness.messageRepo.append(AgentMessage(
            threadId: harness.parent.id,
            role: .user,
            content: "later parent-only turn"
        ))

        let relaunched = harness.coordinator(adapter: adapter)
        try relaunched.reconcileOnLaunch()
        await relaunched.waitForForkReconciliation()

        XCTAssertEqual(
            try harness.messageRepo.list(threadId: harness.child.id).map(\.content),
            ["question", "answer"],
            "recovery must copy the durable fork boundary, not history appended to the parent after provider fork"
        )
        XCTAssertEqual(
            try harness.messageRepo.list(threadId: harness.parent.id).map(\.content),
            ["question", "answer", "later parent-only turn"],
            "fork recovery must never rewrite or truncate parent identity/history"
        )
    }

    func test_crashWindowAfterProviderCreationReplaysSameKeyWithoutDuplicateProviderChild() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        try harness.db.execute("""
            CREATE TRIGGER fail_provider_created_transition
            BEFORE UPDATE ON agent_thread_fork_intents
            WHEN NEW.child_thread_id = '\(harness.child.id.value.uuidString)'
              AND NEW.state = 'provider_created'
            BEGIN SELECT RAISE(ABORT, 'injected provider-created persistence failure'); END;
        """)

        do {
            _ = try await harness.coordinator(adapter: adapter).forkThread(
                sourceThreadId: harness.parent.id,
                childThread: harness.child
            )
            XCTFail("provider-created transition fault must surface")
        } catch {
            XCTAssertTrue(String(describing: error).contains("injected provider-created persistence failure"))
        }
        XCTAssertEqual(adapter.providerCreations, 1)
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .prepared)
        try assertNoLocalChild(harness)

        try harness.db.execute("DROP TRIGGER fail_provider_created_transition;")
        let relaunched = harness.coordinator(adapter: adapter)
        try relaunched.reconcileOnLaunch()
        await relaunched.waitForForkReconciliation()

        XCTAssertEqual(adapter.forkRequests.count, 2,
                       "relaunch must replay the original request key after the unrecorded response")
        XCTAssertEqual(Set(adapter.forkRequests.map(\.idempotencyKey)), [stableKey(harness.child.id)])
        XCTAssertEqual(adapter.providerCreations, 1,
                       "keyed replay must resolve to the original provider child, not create an orphan duplicate")
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .localCommitted)
    }

    func test_eachLocalGraphWriteFaultRollsBackAndRelaunchFinishesWithoutProviderReplay() async throws {
        let stages: [(String, String)] = [
            ("child_thread", """
                CREATE TRIGGER fail_child_thread BEFORE INSERT ON agent_threads
                WHEN NEW.id = '%CHILD%'
                BEGIN SELECT RAISE(ABORT, 'injected child thread failure'); END;
                """),
            ("child_message", """
                CREATE TRIGGER fail_child_message BEFORE INSERT ON agent_messages
                WHEN NEW.thread_id = '%CHILD%'
                BEGIN SELECT RAISE(ABORT, 'injected child message failure'); END;
                """),
            ("child_session", """
                CREATE TRIGGER fail_child_session_atomic BEFORE INSERT ON provider_session_runtime
                WHEN NEW.thread_id = '%CHILD%'
                BEGIN SELECT RAISE(ABORT, 'injected child session failure'); END;
                """),
            ("intent_commit", """
                CREATE TRIGGER fail_fork_intent_commit BEFORE UPDATE ON agent_thread_fork_intents
                WHEN NEW.child_thread_id = '%CHILD%' AND NEW.state = 'local_committed'
                BEGIN SELECT RAISE(ABORT, 'injected intent commit failure'); END;
                """)
        ]

        for (name, rawTrigger) in stages {
            let harness = try makeHarness()
            let adapter = KeyedForkAdapter()
            let trigger = rawTrigger.replacingOccurrences(
                of: "%CHILD%",
                with: harness.child.id.value.uuidString
            )
            try harness.db.execute(trigger)

            do {
                _ = try await harness.coordinator(adapter: adapter).forkThread(
                    sourceThreadId: harness.parent.id,
                    childThread: harness.child
                )
                XCTFail("\(name) fault must abort the complete local graph")
            } catch {
                XCTAssertTrue(String(describing: error).contains("injected"), "\(name): \(error)")
            }
            try assertNoLocalChild(harness)
            XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .providerCreated,
                           "\(name) must retain provider-created recovery evidence")
            XCTAssertEqual(adapter.providerCreations, 1)

            let triggerName: String
            switch name {
            case "child_thread": triggerName = "fail_child_thread"
            case "child_message": triggerName = "fail_child_message"
            case "child_session": triggerName = "fail_child_session_atomic"
            default: triggerName = "fail_fork_intent_commit"
            }
            try harness.db.execute("DROP TRIGGER \(triggerName);")
            let relaunched = harness.coordinator(adapter: adapter)
            try relaunched.reconcileOnLaunch()
            await relaunched.waitForForkReconciliation()

            XCTAssertEqual(adapter.forkRequests.count, 1,
                           "\(name) recovery starts from provider_created and must not refork")
            XCTAssertEqual(adapter.providerCreations, 1)
            XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .localCommitted)
            XCTAssertNotNil(try harness.threadRepo.get(id: harness.child.id))
        }
    }

    func test_prepareWriteFailureNeverCallsProvider() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        try harness.db.execute("""
            CREATE TRIGGER fail_fork_prepare BEFORE INSERT ON agent_thread_fork_intents
            BEGIN SELECT RAISE(ABORT, 'injected fork prepare failure'); END;
        """)

        do {
            _ = try await harness.coordinator(adapter: adapter).forkThread(
                sourceThreadId: harness.parent.id,
                childThread: harness.child
            )
            XCTFail("prepare fault must surface")
        } catch {
            XCTAssertTrue(String(describing: error).contains("injected fork prepare failure"))
        }
        XCTAssertTrue(adapter.forkRequests.isEmpty,
                      "provider mutation is forbidden until the durable local identity exists")
        XCTAssertNil(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id))
        try assertNoLocalChild(harness)
    }

    func test_providerFailureLeavesPreparedIntentAndRelaunchRetriesSameIdentity() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        adapter.failNextForks(1)

        do {
            _ = try await harness.coordinator(adapter: adapter).forkThread(
                sourceThreadId: harness.parent.id,
                childThread: harness.child
            )
            XCTFail("provider failure must surface")
        } catch TestFailure.provider {}
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .prepared)
        try assertNoLocalChild(harness)

        let relaunched = harness.coordinator(adapter: adapter)
        try relaunched.reconcileOnLaunch()
        await relaunched.waitForForkReconciliation()
        XCTAssertEqual(adapter.forkRequests.count, 2)
        XCTAssertEqual(Set(adapter.forkRequests.map(\.idempotencyKey)), [stableKey(harness.child.id)])
        XCTAssertEqual(adapter.providerCreations, 1)
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .localCommitted)
    }

    func test_preparedIntentWithDeletedSourceAbandonsWithoutProviderMutation() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        _ = try harness.threadRepo.prepareForkIntent(
            sourceThreadId: harness.parent.id,
            childThread: harness.child,
            idempotencyKey: stableKey(harness.child.id)
        )
        try harness.threadRepo.delete(id: harness.parent.id)

        let relaunched = harness.coordinator(adapter: adapter)
        try relaunched.reconcileOnLaunch()
        await relaunched.waitForForkReconciliation()

        XCTAssertTrue(adapter.forkRequests.isEmpty,
                      "a missing source before provider creation must never create a detached provider child")
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .abandoned)
        try assertNoLocalChild(harness)
    }

    func test_concurrentDuplicateCallsProduceOneProviderAndOneLocalChild() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        let coordinator = harness.coordinator(adapter: adapter)

        let attempt: () async -> Result<AgentThread, Error> = {
            do {
                return .success(try await coordinator.forkThread(
                    sourceThreadId: harness.parent.id,
                    childThread: harness.child
                ))
            } catch {
                return .failure(error)
            }
        }
        async let first = attempt()
        async let second = attempt()
        let concurrentResults = await [first, second]
        XCTAssertEqual(concurrentResults.compactMap { try? $0.get() }.map(\.id), [harness.child.id])
        XCTAssertEqual(concurrentResults.filter {
            guard case .failure(let error) = $0 else { return false }
            return String(describing: error).contains("another provider mutation is active")
        }.count, 1, "the in-flight duplicate must fail loudly instead of racing the snapshot boundary")

        let retried = try await coordinator.forkThread(
            sourceThreadId: harness.parent.id,
            childThread: harness.child
        )

        XCTAssertEqual(retried.id, harness.child.id,
                       "retry after the first commit must resolve the durable child idempotently")
        XCTAssertEqual(adapter.providerCreations, 1)
        XCTAssertEqual(Set(adapter.forkRequests.map(\.idempotencyKey)), [stableKey(harness.child.id)])
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .localCommitted)
        XCTAssertEqual(try harness.threadRepo.list().filter { $0.id == harness.child.id }.count, 1)
        XCTAssertEqual(try harness.messageRepo.list(threadId: harness.child.id).map(\.content), ["question", "answer"])
    }

    func test_runStartCannotOvertakeForkSnapshotBoundary() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        let enteredProviderFork = expectation(description: "provider fork entered")
        let releaseProviderFork = DispatchSemaphore(value: 0)
        adapter.onFork {
            enteredProviderFork.fulfill()
            releaseProviderFork.wait()
        }
        let coordinator = harness.coordinator(adapter: adapter)
        let forkTask = Task {
            try await coordinator.forkThread(
                sourceThreadId: harness.parent.id,
                childThread: harness.child
            )
        }
        await fulfillment(of: [enteredProviderFork], timeout: 2)

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                threadId: harness.parent.id,
                provider: .codex,
                model: "model",
                cwd: harness.root,
                prompt: "must not overtake fork"
            ))
            XCTFail("run start must not mutate the parent while its fork boundary is in flight")
        } catch {
            XCTAssertTrue(String(describing: error).contains("cannot overtake durable fork recovery"))
        }

        releaseProviderFork.signal()
        _ = try await forkTask.value
        XCTAssertEqual(adapter.providerCreations, 1)
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .localCommitted)
        XCTAssertFalse(try harness.messageRepo.list(threadId: harness.parent.id).contains {
            $0.content == "must not overtake fork"
        }, "rejected concurrent start must not persist a user message")
    }

    func test_unrecoverableLocalConflictCompensatesProviderExactlyOnce() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        adapter.onFork { try harness.threadRepo.delete(id: harness.parent.id) }

        do {
            _ = try await harness.coordinator(adapter: adapter).forkThread(
                sourceThreadId: harness.parent.id,
                childThread: harness.child
            )
            XCTFail("deleted source must prevent a detached local child")
        } catch let error as AgentThreadForkPersistenceError {
            XCTAssertEqual(error, .sourceThreadNotFound)
        }

        XCTAssertEqual(adapter.providerCreations, 1)
        XCTAssertEqual(adapter.compensationCalls, 1)
        XCTAssertTrue(adapter.providerChildren.isEmpty)
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .compensated)
        try assertNoLocalChild(harness)
    }

    func test_compensationFailureRelaunchRetriesDeleteWithoutReforking() async throws {
        let harness = try makeHarness()
        let adapter = KeyedForkAdapter()
        adapter.failNextCompensations(1)
        adapter.onFork { try harness.threadRepo.delete(id: harness.parent.id) }

        do {
            _ = try await harness.coordinator(adapter: adapter).forkThread(
                sourceThreadId: harness.parent.id,
                childThread: harness.child
            )
            XCTFail("first compensation failure must surface")
        } catch TestFailure.compensation {}
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .compensating)
        XCTAssertEqual(adapter.providerChildren.count, 1)

        let relaunched = harness.coordinator(adapter: adapter)
        try relaunched.reconcileOnLaunch()
        await relaunched.waitForForkReconciliation()

        XCTAssertEqual(adapter.forkRequests.count, 1,
                       "compensating recovery must not create another provider child")
        XCTAssertEqual(adapter.providerCreations, 1)
        XCTAssertEqual(adapter.compensationCalls, 2)
        XCTAssertTrue(adapter.providerChildren.isEmpty)
        XCTAssertEqual(try harness.threadRepo.getForkIntent(childThreadId: harness.child.id)?.state, .compensated)
        try assertNoLocalChild(harness)
    }
}
