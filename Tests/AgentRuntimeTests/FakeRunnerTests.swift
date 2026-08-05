import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

final class FakeRunnerTests: XCTestCase {
    private func runShell(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }

    private func mkTmpRepo(prefix: String = "rc2-coordinator-checkpoint-") throws -> String {
        let dir = NSTemporaryDirectory() + prefix + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        runShell(["git", "init", "-q", "-b", "main", dir])
        runShell(["git", "-C", dir, "config", "user.email", "t@t.t"])
        runShell(["git", "-C", dir, "config", "user.name", "test"])
        try "hello\n".write(toFile: dir + "/README.md", atomically: true, encoding: .utf8)
        runShell(["git", "-C", dir, "add", "README.md"])
        runShell(["git", "-C", dir, "commit", "-q", "-m", "init"])
        return dir
    }

    func test_fakeRunner_emitsCompleteTimeline() async throws {
        let runner = FakeProviderRunner(scenario: .simpleAssistant(reply: "OK"))
        let req = AgentRunRequest(threadId: AgentThreadID(), provider: .codex, model: "fake-model", cwd: "/tmp", prompt: "hi")

        actor Collector {
            var events: [AssistantEvent] = []
            var finishedStatus: AgentRunStatus?
            var finishedMessage: String?
            func add(_ e: AssistantEvent) { events.append(e) }
            func finish(_ status: AgentRunStatus, message: String?) { finishedStatus = status; finishedMessage = message }
        }
        let collector = Collector()
        let done = expectation(description: "finished")
        _ = try await runner.startRun(req) { ev in
            switch ev {
            case .event(let e):
                Task { await collector.add(e) }
            case .finished(let st, let m, _):
                Task { await collector.finish(st, message: m); done.fulfill() }
            case .status, .error: break
            }
        }
        await fulfillment(of: [done], timeout: 3)
        let events = await collector.events
        let status = await collector.finishedStatus
        let message = await collector.finishedMessage
        XCTAssertEqual(status, .completed)
        XCTAssertEqual(message, "OK")
        XCTAssertTrue(events.contains { if case .turnCompleted = $0 { return true } else { return false } })
    }

    func test_coordinator_persistsAssistantOnTurnCompleted() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "t", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [.codex: FakeProviderRunner(scenario: .simpleAssistant(reply: "OK"))])
        let req = AgentRunRequest(threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: "hi")
        _ = try await coordinator.startRun(req)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let messages = (try? messageRepo.list(threadId: thread.id)) ?? []
            if messages.contains(where: { $0.role == .assistant && $0.content == "OK" }) {
                XCTAssertEqual(messages.filter { $0.role == .assistant && $0.content == "OK" }.count, 1,
                               "turn completion + finish must not duplicate the final assistant reply")
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("assistant reply must persist from the turn completion event")
    }

    func test_providerAdmissionFailure_preventsSpawnAndPendingPersistence() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-provider-admission-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "admission", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(scenario: .simpleAssistant(reply: "must-not-run"))]
        )
        coordinator.providerAdmissionCheck = { _, _ in
            throw NSError(
                domain: "RemoteCode.ProviderAdmission",
                code: 429,
                userInfo: [NSLocalizedDescriptionKey: "provider cap reached"]
            )
        }
        let request = AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "do not persist"
        )

        do {
            _ = try await coordinator.startRun(request)
            XCTFail("a blocked low-memory admission must fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("provider cap"))
        }
        XCTAssertNil(try runRepo.get(id: request.runId),
                     "admission runs before the pending run graph is written")
        XCTAssertEqual(try messageRepo.count(threadId: thread.id), 0,
                       "a rejected provider spawn must not leave a user message that was never sent")
    }

    func test_compactActiveThreadState_survivesCoordinatorRestart() throws {
        let tmp = NSTemporaryDirectory() + "rc2-active-state-restart-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let thread = AgentThread(title: "active state", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let plan = AssistantActivePlan(
            explanation: "resume this plan",
            steps: [.init(id: "step-1", title: "Keep correctness state", status: .inProgress)],
            updatedAtMs: 123
        )
        let state = AgentActiveThreadState(
            resumeCursor: "cursor-1",
            activeTurnId: "turn-1",
            activePlan: plan,
            pendingApprovalRequestIds: ["approval-1"],
            pendingUserInputRequestIds: ["input-1"]
        )
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .interrupted,
            resumeCursor: "cursor-1",
            runtimePayloadJSON: json
        ))

        let restarted = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: FakeProviderRunner(scenario: .simpleAssistant(reply: "unused"))]
        )
        let recovered = try XCTUnwrap(restarted.durableActiveThreadState(threadId: thread.id))
        XCTAssertEqual(recovered, state,
                       "active plan, approval, input, turn, and resume cursor must not depend on retained transcript rows")
    }

    func test_coordinator_preservesProviderAndModelWhenRunFinishes() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-provider-model-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "claude", provider: .claude, model: "claude-opus-4-7")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [.claude: FakeProviderRunner(provider: .claude, scenario: .simpleAssistant(reply: "OK"))])
        let req = AgentRunRequest(threadId: thread.id, provider: .claude, model: "claude-opus-4-7", cwd: tmp, prompt: "hi")
        let runId = try await coordinator.startRun(req)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let run = try? runRepo.get(id: runId), run.status == .completed {
                XCTAssertEqual(run.provider, .claude,
                               "finished runs must keep their provider so Claude sessions can be resumed and audited")
                XCTAssertEqual(run.model, "claude-opus-4-7",
                               "finished runs must keep the requested model instead of erasing resume metadata")
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("run must complete and preserve provider/model metadata")
    }

    func test_coordinatorCapturesCheckpointSummaryForCompletedTurn() async throws {
        let appSupport = NSTemporaryDirectory() + "rc2-checkpoint-db-" + UUID().uuidString
        let repoDir = try mkTmpRepo()
        defer {
            try? FileManager.default.removeItem(atPath: appSupport)
            try? FileManager.default.removeItem(atPath: repoDir)
        }
        try "hello\nchanged\n".write(toFile: repoDir + "/README.md", atomically: true, encoding: .utf8)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let checkpointRepo = AgentTurnCheckpointRepository(db: db)
        let thread = AgentThread(title: "checkpoint", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              checkpointRepo: checkpointRepo,
                                              providers: [.codex: FakeProviderRunner(scenario: .simpleAssistant(reply: "OK"))])
        let runId = try await coordinator.startRun(AgentRunRequest(threadId: thread.id, provider: .codex, model: "fake-model", cwd: repoDir, prompt: "hi"))

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let checkpoints = (try? checkpointRepo.list(threadId: thread.id)) ?? []
            if let checkpoint = checkpoints.first {
                XCTAssertEqual(checkpoint.runId, runId)
                XCTAssertFalse(checkpoint.turnId.isEmpty)
                XCTAssertEqual(checkpoint.checkpointTurnCount, 1)
                XCTAssertEqual(checkpoint.status, .ready)
                XCTAssertTrue(checkpoint.checkpointRef.contains(runId.value.uuidString))
                XCTAssertTrue(checkpoint.files.contains { $0.path == "README.md" && $0.kind == "modified" },
                              "completed mutation turns must retain a file-level checkpoint summary for recovery and audit")
                XCTAssertTrue(checkpoint.diffPatch?.contains("README.md") == true)
                XCTAssertTrue(checkpoint.fileDiffs.contains { $0.path == "README.md" && $0.patch.contains("changed") },
                              "checkpoint rows must keep per-file diff patches so a later UI can inspect the exact agent turn")
                XCTAssertNotNil(checkpoint.assistantMessageId,
                                "checkpoint summaries must be coupled to the assistant turn output when the provider emitted one")
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("completed run must capture a checkpoint summary")
    }

    func test_coordinatorRecordsMissingCheckpointWhenWorkspaceIsNotGit() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-checkpoint-missing-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let checkpointRepo = AgentTurnCheckpointRepository(db: db)
        let thread = AgentThread(title: "checkpoint", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              checkpointRepo: checkpointRepo,
                                              providers: [.codex: FakeProviderRunner(scenario: .simpleAssistant(reply: "OK"))])
        _ = try await coordinator.startRun(AgentRunRequest(threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: "hi"))

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let checkpoints = (try? checkpointRepo.list(threadId: thread.id)) ?? []
            if let checkpoint = checkpoints.first {
                XCTAssertEqual(checkpoint.status, .missing)
                XCTAssertEqual(checkpoint.errorMessage, "Not a git repository.",
                               "completed turns outside a git repo must leave an explicit missing checkpoint status instead of pretending recovery exists")
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("non-git completed run must still record an explicit missing checkpoint")
    }

    func test_revertThreadToCheckpointRestoresWorkspaceAndRollsBackProvider() async throws {
        let appSupport = NSTemporaryDirectory() + "rc2-checkpoint-revert-db-" + UUID().uuidString
        let repoDir = try mkTmpRepo(prefix: "rc2-checkpoint-revert-repo-")
        defer {
            try? FileManager.default.removeItem(atPath: appSupport)
            try? FileManager.default.removeItem(atPath: repoDir)
        }
        let turnOneBody = "hello\nturn one\n"
        let turnTwoBody = "hello\nturn two\n"
        try turnTwoBody.write(toFile: repoDir + "/README.md", atomically: true, encoding: .utf8)
        try "later\n".write(toFile: repoDir + "/later.txt", atomically: true, encoding: .utf8)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let checkpointRepo = AgentTurnCheckpointRepository(db: db)
        let thread = AgentThread(title: "revert", provider: .codex, model: "fake-model")
        let runOne = AgentRunID()
        let runTwo = AgentRunID()
        let assistantOne = AgentMessage(threadId: thread.id, role: .assistant, content: "turn one")
        let assistantTwo = AgentMessage(threadId: thread.id, role: .assistant, content: "turn two")
        try threadRepo.upsert(thread)
        try runRepo.upsert(AgentRun(id: runOne, threadId: thread.id, provider: .codex, model: "fake-model", status: .completed))
        try runRepo.upsert(AgentRun(id: runTwo, threadId: thread.id, provider: .codex, model: "fake-model", status: .completed))
        try messageRepo.append(assistantOne)
        try messageRepo.append(assistantTwo)
        try checkpointRepo.upsert(AgentTurnCheckpointSummary(
            threadId: thread.id,
            runId: runOne,
            turnId: "turn-1",
            checkpointTurnCount: 1,
            checkpointRef: "local-diff:\(runOne.value.uuidString):turn-1",
            status: .ready,
            files: [AgentTurnCheckpointFile(path: "README.md", kind: "modified", additions: 1, deletions: 0)],
            fileSnapshots: [AgentTurnCheckpointFileSnapshot(path: "README.md", kind: "modified", contentsBase64: Data(turnOneBody.utf8).base64EncodedString())],
            assistantMessageId: assistantOne.id
        ))
        try checkpointRepo.upsert(AgentTurnCheckpointSummary(
            threadId: thread.id,
            runId: runTwo,
            turnId: "turn-2",
            checkpointTurnCount: 2,
            checkpointRef: "local-diff:\(runTwo.value.uuidString):turn-2",
            status: .ready,
            files: [AgentTurnCheckpointFile(path: "README.md", kind: "modified", additions: 1, deletions: 0),
                    AgentTurnCheckpointFile(path: "later.txt", kind: "untracked", additions: 0, deletions: 0)],
            fileSnapshots: [
                AgentTurnCheckpointFileSnapshot(path: "README.md", kind: "modified", contentsBase64: Data(turnTwoBody.utf8).base64EncodedString()),
                AgentTurnCheckpointFileSnapshot(path: "later.txt", kind: "untracked", contentsBase64: Data("later\n".utf8).base64EncodedString())
            ],
            assistantMessageId: assistantTwo.id
        ))
        let adapter = SpyProviderAdapter(provider: .codex)
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              checkpointRepo: checkpointRepo,
                                              providerAdapters: [.codex: adapter])

        _ = try await coordinator.revertThreadToCheckpoint(threadId: thread.id, checkpointTurnCount: 1, cwd: repoDir)

        XCTAssertEqual(try String(contentsOfFile: repoDir + "/README.md", encoding: .utf8), turnOneBody)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoDir + "/later.txt"),
                       "reverting to an earlier checkpoint must remove files introduced by newer provider turns")
        XCTAssertEqual(adapter.lastRollback?.1, "turn-1",
                       "workspace checkpoint revert must also roll back the provider conversation to the checkpoint turn")
        XCTAssertEqual(try checkpointRepo.list(threadId: thread.id).map(\.checkpointTurnCount), [1])
        XCTAssertEqual(try messageRepo.list(threadId: thread.id).map(\.content), ["turn one"],
                       "local assistant messages after the target checkpoint must be pruned when their checkpoint trace is known")
    }

    func test_revertThreadToCheckpointRecoversPersistedProviderSessionBeforeRollback() async throws {
        let appSupport = NSTemporaryDirectory() + "rc2-checkpoint-recover-revert-db-" + UUID().uuidString
        let repoDir = try mkTmpRepo(prefix: "rc2-checkpoint-recover-revert-repo-")
        defer {
            try? FileManager.default.removeItem(atPath: appSupport)
            try? FileManager.default.removeItem(atPath: repoDir)
        }
        let targetBody = "hello\nrecover target\n"
        let newerBody = "hello\nrecover newer\n"
        try newerBody.write(toFile: repoDir + "/README.md", atomically: true, encoding: .utf8)

        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let checkpointRepo = AgentTurnCheckpointRepository(db: db)
        let providerSessionRepo = ProviderSessionRuntimeRepository(db: db)
        let thread = AgentThread(title: "recover revert", provider: .codex, model: "gpt-5.5", providerThreadId: "codex-thread-recovered")
        let runOne = AgentRunID()
        let runTwo = AgentRunID()
        try threadRepo.upsert(thread)
        try runRepo.upsert(AgentRun(id: runOne, threadId: thread.id, provider: .codex, model: "gpt-5.5", status: .completed))
        try runRepo.upsert(AgentRun(id: runTwo, threadId: thread.id, provider: .codex, model: "gpt-5.5", status: .completed))
        try providerSessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .completed,
            resumeCursor: "codex-thread-recovered",
            cwd: repoDir,
            model: "gpt-5.5"
        ))
        try checkpointRepo.upsert(AgentTurnCheckpointSummary(
            threadId: thread.id,
            runId: runOne,
            turnId: "turn-1",
            checkpointTurnCount: 1,
            checkpointRef: "local-diff:\(runOne.value.uuidString):turn-1",
            status: .ready,
            files: [AgentTurnCheckpointFile(path: "README.md", kind: "modified", additions: 1, deletions: 0)],
            fileSnapshots: [AgentTurnCheckpointFileSnapshot(path: "README.md", kind: "modified", contentsBase64: Data(targetBody.utf8).base64EncodedString())]
        ))
        try checkpointRepo.upsert(AgentTurnCheckpointSummary(
            threadId: thread.id,
            runId: runTwo,
            turnId: "turn-2",
            checkpointTurnCount: 2,
            checkpointRef: "local-diff:\(runTwo.value.uuidString):turn-2",
            status: .ready,
            files: [AgentTurnCheckpointFile(path: "README.md", kind: "modified", additions: 1, deletions: 0)],
            fileSnapshots: [AgentTurnCheckpointFileSnapshot(path: "README.md", kind: "modified", contentsBase64: Data(newerBody.utf8).base64EncodedString())]
        ))
        let adapter = SpyProviderAdapter(provider: .codex)
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerSessionRepo: providerSessionRepo,
                                              checkpointRepo: checkpointRepo,
                                              providerAdapters: [.codex: adapter])

        _ = try await coordinator.revertThreadToCheckpoint(threadId: thread.id, checkpointTurnCount: 1, cwd: repoDir)

        XCTAssertEqual(adapter.lastProviderThreadId, "codex-thread-recovered",
                       "checkpoint revert after app restart must recover the persisted provider session before calling rollback")
        XCTAssertEqual(adapter.lastRollback?.1, "turn-1")
        XCTAssertEqual(try String(contentsOfFile: repoDir + "/README.md", encoding: .utf8), targetBody)
    }

    func test_revertThreadToCheckpointPreflightsSnapshotsBeforeProviderRollback() async throws {
        let appSupport = NSTemporaryDirectory() + "rc2-checkpoint-corrupt-revert-db-" + UUID().uuidString
        let repoDir = try mkTmpRepo(prefix: "rc2-checkpoint-corrupt-revert-repo-")
        defer {
            try? FileManager.default.removeItem(atPath: appSupport)
            try? FileManager.default.removeItem(atPath: repoDir)
        }

        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let checkpointRepo = AgentTurnCheckpointRepository(db: db)
        let thread = AgentThread(title: "corrupt revert", provider: .codex, model: "gpt-5.5")
        let run = AgentRunID()
        try threadRepo.upsert(thread)
        try runRepo.upsert(AgentRun(id: run, threadId: thread.id, provider: .codex, model: "gpt-5.5", status: .completed))
        try checkpointRepo.upsert(AgentTurnCheckpointSummary(
            threadId: thread.id,
            runId: run,
            turnId: "turn-corrupt",
            checkpointTurnCount: 1,
            checkpointRef: "local-diff:\(run.value.uuidString):turn-corrupt",
            status: .ready,
            files: [AgentTurnCheckpointFile(path: "README.md", kind: "modified", additions: 1, deletions: 0)],
            fileSnapshots: [AgentTurnCheckpointFileSnapshot(path: "README.md", kind: "modified", contentsBase64: "not-base64")]
        ))
        let adapter = SpyProviderAdapter(provider: .codex)
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              checkpointRepo: checkpointRepo,
                                              providerAdapters: [.codex: adapter])

        do {
            _ = try await coordinator.revertThreadToCheckpoint(threadId: thread.id, checkpointTurnCount: 1, cwd: repoDir)
            XCTFail("checkpoint revert must throw when local snapshots are not restorable")
        } catch {
            // expected
        }
        XCTAssertNil(adapter.lastRollback,
                     "checkpoint revert must prove local snapshots are restorable before rolling back the provider conversation")
    }

    func test_coordinatorReleasesActiveRunStateAcrossManySequentialTurns() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-long-run-release-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "long", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [.codex: PromptEchoRunner()])

        for index in 0..<30 {
            let runId = try await coordinator.startRun(AgentRunRequest(threadId: thread.id,
                                                                       provider: .codex,
                                                                       model: "fake-model",
                                                                       cwd: tmp,
                                                                       prompt: "turn \(index)"))
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if let run = try? runRepo.get(id: runId),
                   run.status == .completed,
                   coordinator.activeThreadIdsSnapshot().isEmpty {
                    break
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(try runRepo.get(id: runId)?.status, .completed,
                           "each long-run turn must finish instead of leaving the Agent App stuck running")
            XCTAssertTrue(coordinator.activeThreadIdsSnapshot().isEmpty,
                          "completed turns must be removed from active run tracking so long sessions do not pile up run handles")
        }

        let messages = try messageRepo.list(threadId: thread.id)
        XCTAssertEqual(messages.filter { $0.role == .assistant && $0.content.hasPrefix("OK turn ") }.count, 30,
                       "long sequential sessions must persist one assistant result per completed turn without losing output")
    }

    func test_coordinator_writesProviderSessionRuntimeForRecovery() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-session-runtime-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let thread = AgentThread(title: "resume", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerSessionRepo: sessionRepo,
                                              providers: [.codex: FakeProviderRunner(provider: .codex, scenario: .simpleAssistant(reply: "OK"))])
        _ = try await coordinator.startRun(AgentRunRequest(threadId: thread.id, provider: .codex, model: "gpt-5.5", cwd: tmp, prompt: "hi", permissionMode: .autoAcceptEdits, serviceTier: .fast, interactionMode: .plan))

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if case .recoverable(let session)? = try? sessionRepo.recoveryState(threadId: thread.id) {
                XCTAssertEqual(session.provider, .codex)
                XCTAssertEqual(session.cwd, tmp)
                XCTAssertEqual(session.model, "gpt-5.5")
                XCTAssertEqual(session.serviceTier, .fast)
                XCTAssertEqual(session.runtimeMode, .autoAcceptEdits)
                XCTAssertEqual(session.adapterKey, "OneShotProviderAdapter:FakeProviderRunner",
                               "provider runtime metadata must record the adapter shape for restart recovery diagnostics")
                XCTAssertEqual(session.binaryIdentity?.hasPrefix("codex:"), true,
                               "provider runtime metadata must record CLI identity for recovery diagnostics")
                XCTAssertEqual(session.lastEventKind, "run.finished")
                XCTAssertEqual(session.resumeCursor?.isEmpty, false,
                               "finished provider sessions must persist a resume cursor so follow-up prompts do not start a disconnected thread")
                let payloadData = try XCTUnwrap(session.runtimePayloadJSON?.data(using: .utf8))
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
                XCTAssertEqual(payload["providerThreadId"] as? String, session.resumeCursor,
                               "runtime payload must carry the provider thread id used by restart recovery")
                XCTAssertEqual(payload["turnCount"] as? Int, 1,
                               "runtime payload must count completed turns so resumed CLI sessions do not lose turn history")
                XCTAssertEqual((payload["lastCompletedTurnId"] as? String)?.isEmpty, false,
                               "runtime payload must record the last completed provider turn for restart diagnostics")
                XCTAssertEqual(payload["model"] as? String, "gpt-5.5")
                XCTAssertEqual(payload["serviceTier"] as? String, "fast")
                XCTAssertEqual(payload["runtimeMode"] as? String, "auto_accept_edits")
                XCTAssertEqual(payload["interactionMode"] as? String, "plan",
                               "runtime payload must persist interaction mode so provider sessions can recover plan/default behavior explicitly")
                XCTAssertNotNil(payload["updatedAtMs"],
                                "runtime payload must include a resume timestamp so stale recovery state is visible")
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("coordinator must write a recoverable provider session runtime row")
    }

    func test_coordinatorTracksPendingUserInputIdsInProviderRuntimePayload() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-pending-runtime-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let thread = AgentThread(title: "pending", provider: .claude, model: "claude-haiku-4-5-20251001")
        try threadRepo.upsert(thread)
        let adapter = PendingUserInputAdapter()
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerSessionRepo: sessionRepo,
                                              providerAdapters: [.claude: adapter])
        _ = try await coordinator.startRun(AgentRunRequest(threadId: thread.id, provider: .claude, model: "claude-haiku-4-5-20251001", cwd: tmp, prompt: "ask"))

        try await waitUntil("pending user-input id persisted in runtime payload") {
            guard let session = try? sessionRepo.get(threadId: thread.id),
                  let payload = Self.runtimePayload(session.runtimePayloadJSON),
                  let ids = payload["pendingUserInputRequestIds"] as? [String] else { return false }
            return ids == ["ask-runtime-1"]
        }

        try await coordinator.respondToUserInput(threadId: thread.id, requestId: "ask-runtime-1", text: "continue")

        try await waitUntil("resolved user-input id removed from runtime payload") {
            guard let session = try? sessionRepo.get(threadId: thread.id),
                  let payload = Self.runtimePayload(session.runtimePayloadJSON),
                  let ids = payload["pendingUserInputRequestIds"] as? [String] else { return false }
            return ids.isEmpty
        }
    }

    func test_coordinatorTracksPendingApprovalIdsInProviderRuntimePayload() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-pending-approval-runtime-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let thread = AgentThread(title: "approval", provider: .claude, model: "claude-haiku-4-5-20251001")
        try threadRepo.upsert(thread)
        let adapter = PendingApprovalAdapter()
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerSessionRepo: sessionRepo,
                                              providerAdapters: [.claude: adapter])
        _ = try await coordinator.startRun(AgentRunRequest(threadId: thread.id, provider: .claude, model: "claude-haiku-4-5-20251001", cwd: tmp, prompt: "approve"))

        try await waitUntil("pending approval id persisted in runtime payload") {
            guard let session = try? sessionRepo.get(threadId: thread.id),
                  let payload = Self.runtimePayload(session.runtimePayloadJSON),
                  let ids = payload["pendingApprovalRequestIds"] as? [String] else { return false }
            return ids == ["approval-runtime-1"]
        }

        try await coordinator.respondToRequest(threadId: thread.id, requestId: "approval-runtime-1", response: .approveForSession)

        try await waitUntil("resolved approval id removed from runtime payload") {
            guard let session = try? sessionRepo.get(threadId: thread.id),
                  let payload = Self.runtimePayload(session.runtimePayloadJSON),
                  let ids = payload["pendingApprovalRequestIds"] as? [String] else { return false }
            return ids.isEmpty
        }
    }

    func test_coordinatorPersistsClaudeSessionSnapshotRuntimePayload() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-claude-snapshot-runtime-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let thread = AgentThread(title: "claude snapshot", provider: .claude, model: "claude-haiku-4-5-20251001")
        try threadRepo.upsert(thread)
        let adapter = ClaudeSessionSnapshotAdapter()
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerSessionRepo: sessionRepo,
                                              providerAdapters: [.claude: adapter])

        _ = try await coordinator.startRun(AgentRunRequest(threadId: thread.id, provider: .claude, model: "claude-haiku-4-5-20251001", cwd: tmp, prompt: "snapshot"))

        try await waitUntil("Claude session snapshot persisted in runtime payload") {
            guard let session = try? sessionRepo.get(threadId: thread.id),
                  let payload = Self.runtimePayload(session.runtimePayloadJSON) else { return false }
            return payload["providerThreadId"] as? String == "claude-sdk-session-1"
                && payload["lastCompletedTurnId"] as? String == "turn-snapshot-1"
                && payload["turnCount"] as? Int == 1
                && payload["activeTurnId"] == nil
                && payload["claudeResumeSessionAt"] as? String == "assistant-uuid-1"
                && (payload["claudeInFlightToolIds"] as? [String]) == []
                && (payload["pendingApprovalRequestIds"] as? [String]) == []
                && (payload["pendingUserInputRequestIds"] as? [String]) == []
        }
    }

    func test_coordinatorPreservesRuntimePayloadWhileStartingFollowupTurn() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-runtime-payload-preserve-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let thread = AgentThread(title: "resume", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .completed,
            resumeCursor: "provider-thread-7",
            cwd: tmp,
            model: "gpt-5.5",
            serviceTier: .fast,
            runtimeMode: .autoAcceptEdits,
            lastEventKind: "run.finished",
            runtimePayloadJSON: #"{"turnCount":7,"lastCompletedTurnId":"turn-7"}"#
        ))
        let adapter = SpyProviderAdapter(provider: .codex, finishImmediately: false)
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerSessionRepo: sessionRepo,
                                              providerAdapters: [.codex: adapter])

        _ = try await coordinator.startRun(AgentRunRequest(threadId: thread.id,
                                                           provider: .codex,
                                                           model: "gpt-5.5",
                                                           cwd: tmp,
                                                           prompt: "continue"))

        let session = try XCTUnwrap(try sessionRepo.get(threadId: thread.id))
        XCTAssertEqual(session.status, .running)
        XCTAssertEqual(session.runtimePayloadJSON, #"{"turnCount":7,"lastCompletedTurnId":"turn-7"}"#,
                       "starting a follow-up turn must not erase completed-turn recovery payload before the provider emits its next durable cursor")
        XCTAssertEqual(adapter.lastProviderThreadId, "provider-thread-7")
    }

    func test_coordinatorUsesRecoverableSessionCursorForFollowupTurn() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-recovery-route-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let thread = AgentThread(title: "resume", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .completed,
            resumeCursor: "provider-thread-1",
            cwd: tmp,
            model: "gpt-5.5",
            lastEventKind: "turn.completed"
        ))
        let adapter = SpyProviderAdapter(provider: .codex)
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerSessionRepo: sessionRepo,
                                              providerAdapters: [.codex: adapter])

        _ = try await coordinator.startRun(AgentRunRequest(threadId: thread.id, provider: .codex, model: "gpt-5.5", cwd: tmp, prompt: "continue"))

        XCTAssertEqual(adapter.lastProviderThreadId, "provider-thread-1",
                       "follow-up turns must use the persisted provider resume cursor when UI state omits providerThreadId")
    }

    func test_coordinatorAppliesRecoveredRuntimeModeToFollowupTurn() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-recovery-runtime-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let thread = AgentThread(title: "resume", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .completed,
            resumeCursor: "provider-thread-1",
            cwd: tmp,
            model: "gpt-5.5",
            serviceTier: .fast,
            runtimeMode: .fullAccess,
            lastEventKind: "turn.completed",
            runtimePayloadJSON: #"{"interactionMode":"plan","turnCount":2}"#
        ))
        let adapter = SpyProviderAdapter(provider: .codex)
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerSessionRepo: sessionRepo,
                                              providerAdapters: [.codex: adapter])

        _ = try await coordinator.startRun(AgentRunRequest(threadId: thread.id,
                                                           provider: .codex,
                                                           model: "gpt-5.5",
                                                           cwd: tmp,
                                                           prompt: "continue"))

        XCTAssertEqual(adapter.lastProviderThreadId, "provider-thread-1")
        XCTAssertEqual(adapter.lastPermissionMode, .fullAccess,
                       "restart recovery must apply the persisted runtime mode instead of silently downgrading resumed Codex turns to supervised")
        XCTAssertEqual(adapter.lastServiceTier, .fast,
                       "restart recovery must keep the persisted Codex service tier when the UI request omits it")
        XCTAssertEqual(adapter.lastInteractionMode, .plan,
                       "restart recovery must keep plan/default mode aligned with the persisted provider session")
    }

    func test_codexFollowupTurnReusesSameProviderThreadFromPersistedRecoveryState() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-codex-thread-continuity-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let thread = AgentThread(title: "codex continuity", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        let adapter = SpyProviderAdapter(provider: .codex)
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerSessionRepo: sessionRepo,
                                              providerAdapters: [.codex: adapter])

        _ = try await coordinator.startRun(AgentRunRequest(threadId: thread.id,
                                                           provider: .codex,
                                                           model: "gpt-5.5",
                                                           cwd: tmp,
                                                           prompt: "first"))
        let firstProviderThreadId = try await waitForCompletedProviderSession(
            sessionRepo: sessionRepo,
            threadId: thread.id
        )
        _ = try await coordinator.startRun(AgentRunRequest(threadId: thread.id,
                                                           provider: .codex,
                                                           model: "gpt-5.5",
                                                           cwd: tmp,
                                                           prompt: "second"))

        XCTAssertEqual(adapter.sendTurnCount, 2)
        XCTAssertEqual(adapter.lastProviderThreadId, firstProviderThreadId,
                       "Codex follow-up turns must reuse the persisted provider thread id so multi-turn tasks do not fork into disconnected sessions")
    }

    func test_coordinatorFailsLoudWhenExistingProviderThreadIsUnrecoverable() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-unrecoverable-route-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let thread = AgentThread(title: "broken", provider: .codex, model: "gpt-5.5", providerThreadId: "provider-thread-1")
        try threadRepo.upsert(thread)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .completed,
            resumeCursor: nil,
            cwd: tmp,
            model: "gpt-5.5",
            lastEventKind: "turn.completed"
        ))
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerSessionRepo: sessionRepo,
                                              providerAdapters: [.codex: SpyProviderAdapter(provider: .codex)])

        do {
            _ = try await coordinator.startRun(AgentRunRequest(threadId: thread.id, provider: .codex, model: "gpt-5.5", cwd: tmp, prompt: "continue"))
            XCTFail("missing resume data for an existing provider thread must fail loudly instead of silently starting a disconnected session")
        } catch {
            XCTAssertTrue(String(describing: error).contains("no resume cursor"))
        }
    }

    func test_coordinatorUsesLiveAdapterSessionWhenRuntimeCursorIsMissing() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-live-adapter-route-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let thread = AgentThread(title: "live", provider: .codex, model: "gpt-5.5", providerThreadId: "lost-persisted-cursor")
        try threadRepo.upsert(thread)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .completed,
            resumeCursor: nil,
            cwd: tmp,
            model: "gpt-5.5",
            lastEventKind: "turn.completed"
        ))
        let adapter = SpyProviderAdapter(provider: .codex)
        adapter.sessionSummaries = [
            AgentProviderSessionSummary(threadId: thread.id, provider: .codex, status: .completed, providerThreadId: "live-session-1")
        ]
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerSessionRepo: sessionRepo,
                                              providerAdapters: [.codex: adapter])

        _ = try await coordinator.startRun(AgentRunRequest(threadId: thread.id, provider: .codex, model: "gpt-5.5", cwd: tmp, prompt: "continue live"))

        XCTAssertEqual(adapter.lastProviderThreadId, "live-session-1",
                       "live adapter sessions must be adopted before declaring missing durable resume data unrecoverable")
    }

    func test_coordinatorRejectsOrphanedLiveAdapterTurnBeforePersistingDuplicateRun() async throws {
        // WHY: a surface/coordinator can lose its in-memory active-run projection
        // while the provider adapter still owns a running turn. A second start must
        // fail before it persists another user bubble or invokes the provider.
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-orphaned-live-turn-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(
            title: "orphaned live turn",
            provider: .codex,
            model: "gpt-5.5",
            providerThreadId: "live-session-1"
        )
        try threadRepo.upsert(thread)
        let adapter = SpyProviderAdapter(provider: .codex, finishImmediately: false)
        adapter.sessionSummaries = [
            AgentProviderSessionSummary(
                threadId: thread.id,
                provider: .codex,
                status: .running,
                providerThreadId: "live-session-1"
            )
        ]
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerAdapters: [.codex: adapter]
        )
        let attemptedRunId = AgentRunID()

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                runId: attemptedRunId,
                threadId: thread.id,
                provider: .codex,
                model: "gpt-5.5",
                cwd: tmp,
                prompt: "must not duplicate",
                providerThreadId: "live-session-1"
            ))
            XCTFail("a running adapter session must block a second coordinator start")
        } catch {
            XCTAssertTrue(String(describing: error).contains("in-flight turn"))
        }

        XCTAssertEqual(adapter.sendTurnCount, 0,
                       "the coordinator guard must stop before asking the adapter to reject the duplicate")
        XCTAssertTrue(try messageRepo.list(threadId: thread.id).isEmpty,
                      "a rejected duplicate start must not persist another user message")
        XCTAssertNil(try runRepo.get(id: attemptedRunId),
                     "a rejected duplicate start must not create a failed phantom run")
    }

    func test_coordinatorFailsLoudWhenActiveRuntimeSessionHasNoLiveSessionOrCursor() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-stale-active-route-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let thread = AgentThread(title: "stale active", provider: .codex, model: "gpt-5.5", providerThreadId: "provider-thread-1")
        try threadRepo.upsert(thread)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .running,
            resumeCursor: nil,
            cwd: tmp,
            model: "gpt-5.5",
            lastEventKind: "run.started"
        ))
        let adapter = SpyProviderAdapter(provider: .codex)
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerSessionRepo: sessionRepo,
                                              providerAdapters: [.codex: adapter])

        do {
            _ = try await coordinator.startRun(AgentRunRequest(threadId: thread.id,
                                                               provider: .codex,
                                                               model: "gpt-5.5",
                                                               cwd: tmp,
                                                               prompt: "continue stale active"))
            XCTFail("stale active runtime state without a live adapter session must fail loudly instead of forking a disconnected provider session")
        } catch {
            XCTAssertTrue(String(describing: error).contains("marked active"),
                          "error should explain that the active provider session cannot be recovered")
            XCTAssertEqual(adapter.sendTurnCount, 0,
                           "coordinator must not start a new provider process when existing thread recovery is unsafe")
        }
    }

    func test_coordinatorStopsLiveAdapterSessionWithoutLocalRunHandle() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-stop-live-adapter-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "live stop", provider: .claude, model: "claude-opus-4-7")
        try threadRepo.upsert(thread)
        let adapter = SpyProviderAdapter(provider: .claude, finishImmediately: false)
        adapter.sessionSummaries = [
            AgentProviderSessionSummary(threadId: thread.id, provider: .claude, status: .running, providerThreadId: "claude-live-1")
        ]
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerAdapters: [.claude: adapter])
        coordinator.stopRun(threadId: thread.id)

        XCTAssertEqual(adapter.stopSessionCallCount, 1,
                       "stop must close a live provider adapter session even after local active run state was lost")
        _ = try await coordinator.startRun(AgentRunRequest(threadId: thread.id,
                                                           provider: .claude,
                                                           model: "claude-opus-4-7",
                                                           cwd: tmp,
                                                           prompt: "restart after live stop"))
        XCTAssertEqual(adapter.cancelCount, 0,
                       "stopping a recovered live provider session must not leave a pending cancellation for the next run")
    }

    func test_coordinatorIgnoresStopForAlreadyStoppedThreadWithoutLiveSession() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-stop-stale-no-session-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "stale stop", provider: .claude, model: "claude-opus-4-7", status: .cancelled)
        try threadRepo.upsert(thread)
        let adapter = SpyProviderAdapter(provider: .claude, finishImmediately: false)
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerAdapters: [.claude: adapter])

        coordinator.stopRun(threadId: thread.id)
        _ = try await coordinator.startRun(AgentRunRequest(threadId: thread.id,
                                                           provider: .claude,
                                                           model: "claude-opus-4-7",
                                                           cwd: tmp,
                                                           prompt: "restart after stale stop"))

        XCTAssertEqual(adapter.sendTurnCount, 1,
                       "the next run must still start on an already-stopped thread")
        XCTAssertEqual(adapter.cancelCount, 0,
                       "stop on an already-stopped thread must not leave a pending cancellation that auto-cancels the next run")
    }

    func test_coordinatorRecoversPersistedActiveSessionBeforeInterruptingStop() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-stop-recovered-adapter-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let thread = AgentThread(title: "recovered stop", provider: .codex, model: "gpt-5.5", providerThreadId: "codex-thread-recovered")
        try threadRepo.upsert(thread)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .running,
            resumeCursor: "codex-thread-recovered",
            cwd: tmp,
            model: "gpt-5.5",
            lastEventKind: "turn.started",
            runtimePayloadJSON: #"{"turnCount":0,"activeTurnId":"turn-active-recovered"}"#
        ))
        let adapter = SpyProviderAdapter(provider: .codex)
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerSessionRepo: sessionRepo,
                                              providerAdapters: [.codex: adapter])

        coordinator.stopRun(threadId: thread.id)

        try await waitUntil("persisted provider recovery before stop interrupt") {
            adapter.lastProviderThreadId == "codex-thread-recovered"
                && adapter.interruptTurnCallCount == 1
        }

        XCTAssertEqual(adapter.lastProviderThreadId, "codex-thread-recovered",
                       "stop after app restart must recover the persisted provider session before interrupting it")
        XCTAssertEqual(adapter.lastRecoveredExtraArgs, ["remotecode.recovery.activeTurnId=turn-active-recovered"],
                       "recovery must carry the active provider turn id so Codex app-server can interrupt the exact running turn")
        XCTAssertEqual(adapter.interruptTurnCallCount, 1,
                       "stop after app restart must call provider-native interrupt instead of only queuing a local cancellation")
    }

    func test_coordinator_emitsVisibleErrorWhenLifecyclePersistenceFails() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-persistence-fail-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "deleted", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [.codex: DelayedEventRunner()])
        actor Issues {
            var messages: [String] = []
            func append(_ message: String) { messages.append(message) }
            func containsPersistenceFailure() -> Bool {
                messages.contains { $0.contains("Persistence failure") }
            }
        }
        let issues = Issues()
        coordinator.onPersistenceIssue = { message, _, _ in
            Task { await issues.append(message) }
        }

        _ = try await coordinator.startRun(AgentRunRequest(threadId: thread.id, provider: .codex, model: "gpt-5.5", cwd: tmp, prompt: "hi"))
        try threadRepo.delete(id: thread.id)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await issues.containsPersistenceFailure() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("lifecycle persistence failures must be surfaced instead of hidden behind try?")
    }

    func test_coordinatorRoutesTurnsThroughProviderAdapterBoundary() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-provider-adapter-boundary-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "adapter", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        let adapter = SpyProviderAdapter(provider: .codex)
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerAdapters: [.codex: adapter])

        _ = try await coordinator.startRun(AgentRunRequest(threadId: thread.id, provider: .codex, model: "gpt-5.5", cwd: tmp, prompt: "hi"))

        await waitForAdapterSend(adapter)
        XCTAssertEqual(adapter.sendTurnCount, 1,
                       "coordinator must route provider execution through the adapter boundary, not spawn a provider runner directly")
        XCTAssertEqual(adapter.lastPrompt, "hi")
    }

    func test_reconcileOnLaunchClearsThreadAndProviderSessionStateForInterruptedRuns() throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-launch-reconcile-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        var thread = AgentThread(title: "stale codex", provider: .codex, model: "gpt-5.5")
        thread.status = .running
        try threadRepo.upsert(thread)
        let run = AgentRun(id: AgentRunID(), threadId: thread.id, provider: .codex, model: "gpt-5.5", status: .running)
        try runRepo.upsert(run)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .running,
            resumeCursor: nil,
            updatedAt: Date(timeIntervalSince1970: 1)
        ))
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerSessionRepo: sessionRepo,
                                              providerAdapters: [.codex: SpyProviderAdapter(provider: .codex)])

        try coordinator.reconcileOnLaunch()

        XCTAssertEqual(try runRepo.get(id: run.id)?.status, .interrupted,
                       "launch recovery must not leave a persisted Codex run marked running when no provider process survived restart")
        XCTAssertEqual(try threadRepo.get(id: thread.id)?.status, .interrupted,
                       "Agent App must not show an endless running spinner after launch reconciles a dead Codex run")
        XCTAssertEqual(try sessionRepo.get(threadId: thread.id)?.status, .interrupted,
                       "provider recovery state must not keep a dead Codex app-server session active after launch")
    }

    /// WHY: if a turn already finished (thread completed) but the provider
    /// session row was still running, launch must not invent an interrupt.
    /// That mismatch made pet-open show "This thread was interrupted by an app
    /// restart" on finished Grok/Codex threads.
    func test_reconcileOnLaunchAlignsStaleRunningSessionToCompletedThread() throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-launch-completed-session-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        var thread = AgentThread(title: "already done", provider: .grok, model: "grok-4.5", providerThreadId: "cursor-1")
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
            providerAdapters: [.grok: SpyProviderAdapter(provider: .grok)]
        )

        try coordinator.reconcileOnLaunch()

        XCTAssertEqual(try threadRepo.get(id: thread.id)?.status, .completed,
                       "launch must not rewrite a completed thread into interrupted")
        XCTAssertEqual(try sessionRepo.get(threadId: thread.id)?.status, .completed,
                       "stale running sessions on completed threads must heal to completed, not interrupted")
        XCTAssertFalse(coordinator.hasRecoverableContext(threadId: thread.id),
                       "finished work must not expose the Continue affordance after launch reconciliation")
    }

    func test_startRunFailureMarksThreadAndSessionFailedInsteadOfLeavingRunningSpinner() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-start-failure-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let thread = AgentThread(title: "auth failure", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerSessionRepo: sessionRepo,
                                              providerAdapters: [.codex: FailingProviderAdapter(provider: .codex)])
        let runId = AgentRunID()

        do {
            _ = try await coordinator.startRun(AgentRunRequest(runId: runId, threadId: thread.id, provider: .codex, model: "gpt-5.5", cwd: tmp, prompt: "count"))
            XCTFail("Codex app-server startup failures must be surfaced to the caller")
        } catch {
            // Expected: the important assertion is persisted state below.
        }

        XCTAssertEqual(try runRepo.get(id: runId)?.status, .failed,
                       "provider startup failure must close the persisted run instead of leaving it running")
        XCTAssertEqual(try threadRepo.get(id: thread.id)?.status, .failed,
                       "Agent App must show a failed run state when Codex exits during startup, not an endless spinner")
        XCTAssertEqual(try sessionRepo.get(threadId: thread.id)?.status, .failed,
                       "provider session runtime must record that Codex startup failed so recovery does not try to resume a dead process")
        XCTAssertTrue((try sessionRepo.get(threadId: thread.id)?.lastErrorMessage ?? "").contains("simulated provider startup failure"))
    }

    func test_continueStartFailurePreservesInterruptedSessionForRetry() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-continue-start-failure-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        var thread = AgentThread(title: "continue after auth", provider: .codex, model: "gpt-5.5")
        thread.status = .interrupted
        thread.providerThreadId = "codex-resume-cursor"
        try threadRepo.upsert(thread)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .interrupted,
            resumeCursor: "codex-resume-cursor",
            cwd: tmp,
            model: "gpt-5.5"
        ))
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providerAdapters: [.codex: FailingProviderAdapter(provider: .codex)]
        )
        let runId = AgentRunID()

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                runId: runId,
                threadId: thread.id,
                provider: .codex,
                model: "gpt-5.5",
                cwd: tmp,
                prompt: "Continue the interrupted turn from the last saved context."
            ), recordUserMessage: false)
            XCTFail("a failed provider recovery must be surfaced")
        } catch {
            // Expected. The durable cursor must remain retryable below.
        }

        XCTAssertEqual(try runRepo.get(id: runId)?.status, .failed,
                       "the failed Continue attempt itself must terminate")
        XCTAssertEqual(try threadRepo.get(id: thread.id)?.status, .interrupted,
                       "a transient Continue start failure must not erase the thread's interrupted state")
        XCTAssertEqual(try sessionRepo.get(threadId: thread.id)?.status, .interrupted)
        XCTAssertTrue(coordinator.hasRecoverableContext(threadId: thread.id),
                      "the original provider cursor must remain available for another Continue attempt")
        XCTAssertTrue(try messageRepo.list(threadId: thread.id).isEmpty,
                      "a failed provider-only Continue must not invent a user message")
    }

    func test_interruptedProviderSessionWithoutResumeCursorStartsFreshTurn() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-interrupted-fresh-start-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        var thread = AgentThread(title: "retry", provider: .codex, model: "gpt-5.5")
        thread.status = .interrupted
        try threadRepo.upsert(thread)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .interrupted,
            resumeCursor: nil,
            cwd: tmp,
            model: "gpt-5.5",
            lastEventKind: "run.started"
        ))
        let adapter = SpyProviderAdapter(provider: .codex)
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerSessionRepo: sessionRepo,
                                              providerAdapters: [.codex: adapter])

        _ = try await coordinator.startRun(AgentRunRequest(threadId: thread.id, provider: .codex, model: "gpt-5.5", cwd: tmp, prompt: "retry"))

        await waitForAdapterSend(adapter)
        XCTAssertEqual(adapter.lastProviderThreadId, nil,
                       "an interrupted Codex thread with no persisted provider cursor must start a clean app-server session instead of blocking retry")
        XCTAssertEqual(try messageRepo.list(threadId: thread.id).last?.content, "retry",
                       "retry after interrupted startup must persist the user's new prompt")
    }

    func test_continueInterruptedSessionRestoresRuntimeContextWithoutPersistingSyntheticUserMessage() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-coordinator-interrupted-continue-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        var thread = AgentThread(title: "continue", provider: .claude, model: "claude-sonnet")
        thread.status = .interrupted
        thread.providerThreadId = "claude-session-1"
        try threadRepo.upsert(thread)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .claude,
            status: .interrupted,
            resumeCursor: "claude-session-1",
            cwd: tmp,
            model: "claude-sonnet",
            serviceTier: .fast,
            runtimeMode: .autoAcceptEdits,
            runtimePayloadJSON: #"{"interactionMode":"plan"}"#
        ))
        let adapter = SpyProviderAdapter(provider: .claude)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providerAdapters: [.claude: adapter]
        )
        let providerOnlyInstruction = "Continue the interrupted turn from the last saved context."

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .claude,
            model: "ignored-model",
            cwd: tmp,
            prompt: providerOnlyInstruction,
            providerThreadId: nil,
            permissionMode: .supervised,
            serviceTier: .auto,
            interactionMode: .default
        ), recordUserMessage: false)

        await waitForAdapterSend(adapter)
        XCTAssertEqual(adapter.lastProviderThreadId, "claude-session-1",
                       "Continue must recover the durable provider cursor after relaunch")
        XCTAssertEqual(adapter.lastPermissionMode, .autoAcceptEdits,
                       "Continue must restore the interrupted session authority instead of current composer defaults")
        XCTAssertEqual(adapter.lastServiceTier, .fast,
                       "Continue must restore provider runtime configuration from the interrupted session")
        XCTAssertEqual(adapter.lastInteractionMode, .plan,
                       "Continue must restore the mode used by the interrupted turn")
        XCTAssertEqual(adapter.lastPrompt, providerOnlyInstruction,
                       "Continue must send a non-empty provider instruction so Claude never receives an empty turn")
        XCTAssertTrue(try messageRepo.list(threadId: thread.id).isEmpty,
                      "the provider-only recovery instruction must not appear as an invented user message")
    }

    func test_coordinatorRoutesApprovalAndUserInputResponsesThroughProviderAdapter() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-provider-adapter-callbacks-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "adapter", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        let adapter = SpyProviderAdapter(provider: .codex)
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerAdapters: [.codex: adapter])

        try await coordinator.respondToRequest(threadId: thread.id, requestId: "approval-1", response: .approveForSession)
        try await coordinator.respondToUserInput(threadId: thread.id, requestId: "question-1", text: "Run")

        XCTAssertEqual(adapter.lastRequestResponse?.0, thread.id)
        XCTAssertEqual(adapter.lastRequestResponse?.1, "approval-1")
        XCTAssertEqual(adapter.lastRequestResponse?.2, .approveForSession)
        XCTAssertEqual(adapter.lastUserInputResponse?.0, thread.id)
        XCTAssertEqual(adapter.lastUserInputResponse?.1, "question-1")
        XCTAssertEqual(adapter.lastUserInputResponse?.2, "Run")
    }

    func test_coordinatorRoutesReadAndRollbackThroughProviderAdapter() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-provider-adapter-read-rollback-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "adapter", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        let adapter = SpyProviderAdapter(provider: .codex)
        adapter.readEvents = [.turnStarted(turnId: "turn-1")]
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerAdapters: [.codex: adapter])

        let readTurn1 = try await coordinator.readThread(threadId: thread.id)
        XCTAssertEqual(readTurn1, [.turnStarted(turnId: "turn-1")])
        try await coordinator.rollbackThread(threadId: thread.id, toTurnId: "turn-1")

        XCTAssertEqual(adapter.lastRollback?.0, thread.id)
        XCTAssertEqual(adapter.lastRollback?.1, "turn-1")
    }

    func test_claudeFirstTurnStartsThroughProviderAdapter() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-claude-first-turn-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "claude", provider: .claude, model: "claude-opus-4-7")
        try threadRepo.upsert(thread)
        let adapter = SpyProviderAdapter(provider: .claude)
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerAdapters: [.claude: adapter])

        _ = try await coordinator.startRun(AgentRunRequest(threadId: thread.id,
                                                           provider: .claude,
                                                           model: "claude-opus-4-7",
                                                           cwd: tmp,
                                                           prompt: "start claude"))

        await waitForAdapterSend(adapter)
        XCTAssertEqual(adapter.sendTurnCount, 1,
                       "Claude first turns must be routed through the provider adapter boundary so SDK-session integration has one ownership point")
        XCTAssertEqual(adapter.lastPrompt, "start claude")
        XCTAssertNil(adapter.lastProviderThreadId,
                     "a new Claude session must start without accidentally borrowing a stale provider thread id")
    }

    func test_claudeRecoveryAfterStopAllUsesPersistedResumeState() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-claude-resume-after-stopall-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let thread = AgentThread(title: "claude", provider: .claude, model: "claude-opus-4-7")
        try threadRepo.upsert(thread)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .claude,
            status: .completed,
            resumeCursor: "claude-session-1",
            cwd: tmp,
            model: "claude-opus-4-7",
            lastEventKind: "turn.completed"
        ))
        let adapter = SpyProviderAdapter(provider: .claude)
        adapter.stopAll()
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerSessionRepo: sessionRepo,
                                              providerAdapters: [.claude: adapter])

        _ = try await coordinator.startRun(AgentRunRequest(threadId: thread.id,
                                                           provider: .claude,
                                                           model: "claude-opus-4-7",
                                                           cwd: tmp,
                                                           prompt: "resume claude"))

        await waitForAdapterSend(adapter)
        XCTAssertTrue(adapter.stopAllCalled,
                      "the test must simulate provider runtime loss before recovery")
        XCTAssertEqual(adapter.lastProviderThreadId, "claude-session-1",
                       "Claude recovery must use persisted resume state after provider stopAll instead of starting a disconnected thread")
    }

    func test_claudeCallbacksReadAndRollbackRouteThroughProviderAdapter() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-claude-callback-read-rollback-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "claude", provider: .claude, model: "claude-opus-4-7")
        try threadRepo.upsert(thread)
        let adapter = SpyProviderAdapter(provider: .claude)
        adapter.readEvents = [.turnStarted(turnId: "claude-turn-1")]
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerAdapters: [.claude: adapter])

        try await coordinator.respondToRequest(threadId: thread.id, requestId: "approval-1", response: .approveForSession)
        try await coordinator.respondToUserInput(threadId: thread.id, requestId: "question-1", text: "Run")
        let readClaudeTurn1 = try await coordinator.readThread(threadId: thread.id)
        XCTAssertEqual(readClaudeTurn1, [.turnStarted(turnId: "claude-turn-1")])
        try await coordinator.rollbackThread(threadId: thread.id, toTurnId: "claude-turn-1")

        XCTAssertEqual(adapter.lastRequestResponse?.2, .approveForSession,
                       "Claude approval responses must route through the provider adapter")
        XCTAssertEqual(adapter.lastUserInputResponse?.2, "Run",
                       "Claude user input responses must route through the provider adapter")
        XCTAssertEqual(adapter.lastRollback?.1, "claude-turn-1",
                       "Claude rollback/revert must route through the provider adapter")
    }

    func test_claudeStopRunCancelsActiveProviderHandle() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-claude-interrupt-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "claude", provider: .claude, model: "claude-opus-4-7")
        try threadRepo.upsert(thread)
        let adapter = SpyProviderAdapter(provider: .claude, finishImmediately: false)
        let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                              messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerAdapters: [.claude: adapter])
        coordinator.gracefulStopTimeout = 0.05

        _ = try await coordinator.startRun(AgentRunRequest(threadId: thread.id,
                                                           provider: .claude,
                                                           model: "claude-opus-4-7",
                                                           cwd: tmp,
                                                           prompt: "stop claude"))
        await waitForAdapterSend(adapter)
        coordinator.stopRun(threadId: thread.id)

        XCTAssertEqual(adapter.interruptTurnCallCount, 1,
                       "Claude Stop must deliver the provider-native interrupt before closing its live transport")
        XCTAssertEqual(adapter.cancelCount, 0,
                       "Claude Stop must keep the transport open during the bounded provider acknowledgement window")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(adapter.cancelCount, 1,
                       "an unacknowledged Claude interrupt must cancel the active provider handle after the bounded grace period")
    }

    func test_stopRunInterruptsActiveProviderAdapterForCodexAndClaude() async throws {
        for provider in [AgentProvider.codex, .claude, .grok] {
            let tmp = NSTemporaryDirectory() + "rc2-active-stop-\(provider.rawValue)-" + UUID().uuidString
            let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
            let threadRepo = AgentThreadRepository(db: db)
            let messageRepo = AgentMessageRepository(db: db)
            let runRepo = AgentRunRepository(db: db)
            let model: String
            switch provider {
            case .codex: model = "gpt-5.5"
            case .claude: model = "claude-opus-4-7"
            case .grok: model = "grok-4.5"
            }
            let thread = AgentThread(title: "stop \(provider.rawValue)",
                                     provider: provider,
                                     model: model)
            try threadRepo.upsert(thread)
            let adapter = SpyProviderAdapter(provider: provider, finishImmediately: false)
            let coordinator = AgentRunCoordinator(runRepo: runRepo,
                                                  messageRepo: messageRepo,
                                                  threadRepo: threadRepo,
                                                  providerAdapters: [provider: adapter])
            coordinator.gracefulStopTimeout = 0.05

            _ = try await coordinator.startRun(AgentRunRequest(threadId: thread.id,
                                                               provider: provider,
                                                               model: thread.model,
                                                               cwd: tmp,
                                                               prompt: "long stop"))
            await waitForAdapterSend(adapter)
            coordinator.stopRun(threadId: thread.id)

            XCTAssertEqual(adapter.interruptTurnCallCount, 1,
                           "Stop Chat must first call the \(provider.rawValue) adapter interrupt path so provider-native work can abort cleanly")
            XCTAssertEqual(adapter.cancelCount, 0,
                           "Stop Chat must preserve the \(provider.rawValue) transport during the bounded acknowledgement window")
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertEqual(adapter.cancelCount, 1,
                           "an unacknowledged \(provider.rawValue) interrupt must cancel the active run handle after the bounded grace period")
        }
    }

    func test_stopAllProviderSessionsStopsEveryAdapterForAppShutdown() throws {
        let tmp = NSTemporaryDirectory() + "rc2-stop-all-providers-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let codex = SpyProviderAdapter(provider: .codex)
        let claude = SpyProviderAdapter(provider: .claude)
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: AgentMessageRepository(db: db),
            threadRepo: AgentThreadRepository(db: db),
            providerAdapters: [.codex: codex, .claude: claude]
        )

        coordinator.stopAllProviderSessionsForAppTermination()

        XCTAssertTrue(codex.stopAllForAppTerminationCalled,
                      "app shutdown must terminate Codex provider runtimes instead of leaving orphan app-server processes")
        XCTAssertTrue(claude.stopAllForAppTerminationCalled,
                      "app shutdown must terminate Claude provider runtimes instead of leaving orphan bridge processes")
    }

    func test_claudeCliAdapterKeepsReadableThreadHistoryAndRollsBackLocalSnapshot() async throws {
        let adapter = ClaudeCLIAdapter(runner: ScriptedClaudeRunner())
        let threadId = AgentThreadID()
        _ = try await adapter.sendTurn(AgentRunRequest(threadId: threadId,
                                                       provider: .claude,
                                                       model: "claude-opus-4-7",
                                                       cwd: NSTemporaryDirectory(),
                                                       prompt: "one")) { _ in }

        let providerThreadId = try await waitForProviderThreadId(adapter: adapter, threadId: threadId)
        _ = try await adapter.sendTurn(AgentRunRequest(threadId: threadId,
                                                       provider: .claude,
                                                       model: "claude-opus-4-7",
                                                       cwd: NSTemporaryDirectory(),
                                                       prompt: "two",
                                                       providerThreadId: providerThreadId)) { _ in }
        try await waitForReadableTurn(adapter: adapter, threadId: threadId, turnId: "turn-two")

        let cliReadTurns = try await adapter.readThread(threadId: threadId).compactMap(\.completedTurnId)
        XCTAssertEqual(cliReadTurns, ["turn-one", "turn-two"],
                       "Claude CLI sessions must expose readable turn history for Agent App reload instead of leaving readThread unsupported")

        try await adapter.rollbackThread(threadId: threadId, toTurnId: "turn-one")

        let cliRolledBackTurns = try await adapter.readThread(threadId: threadId).compactMap(\.completedTurnId)
        XCTAssertEqual(cliRolledBackTurns, ["turn-one"],
                       "Claude local rollback must trim the readable snapshot so checkpoint/revert UI does not show abandoned later turns")
    }

    func test_claudeCliAdapterKeepsReadableThreadHistoryBoundedForLongSessions() async throws {
        let adapter = ClaudeCLIAdapter(runner: ScriptedClaudeRunner(), maxReadableEvents: 4)
        let threadId = AgentThreadID()
        var providerThreadId: String?

        for prompt in ["one", "two", "three"] {
            _ = try await adapter.sendTurn(AgentRunRequest(threadId: threadId,
                                                           provider: .claude,
                                                           model: "claude-opus-4-7",
                                                           cwd: NSTemporaryDirectory(),
                                                           prompt: prompt,
                                                           providerThreadId: providerThreadId)) { _ in }
            providerThreadId = try await waitForProviderThreadId(adapter: adapter, threadId: threadId)
            try await waitForReadableTurn(adapter: adapter, threadId: threadId, turnId: "turn-\(prompt)")
        }

        let readable = try await adapter.readThread(threadId: threadId)
        XCTAssertLessThanOrEqual(readable.count, 4,
                                 "Claude CLI readable snapshots must be bounded so long-running sessions do not retain every provider event in memory")
        XCTAssertTrue(readable.contains { $0.completedTurnId == "turn-three" },
                      "retention must keep the newest Claude turn visible after pruning older events")
        XCTAssertFalse(readable.contains { $0.completedTurnId == "turn-one" },
                       "retention should prune oldest Claude events once the readable window is full")
    }

    private func waitForAdapterSend(_ adapter: SpyProviderAdapter) async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if adapter.sendTurnCount > 0 { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func waitForProviderThreadId(threadRepo: AgentThreadRepository, threadId: AgentThreadID) async throws -> String {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let providerThreadId = try threadRepo.get(id: threadId)?.providerThreadId,
               !providerThreadId.isEmpty {
                return providerThreadId
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for persisted provider thread id")
        return ""
    }

    private func waitForCompletedProviderSession(
        sessionRepo: ProviderSessionRuntimeRepository,
        threadId: AgentThreadID
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let session = try sessionRepo.get(threadId: threadId),
               session.status == .completed,
               let providerThreadId = session.resumeCursor,
               !providerThreadId.isEmpty {
                return providerThreadId
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for completed provider session with resume cursor")
        return ""
    }

    private func waitForProviderThreadId(adapter: ClaudeCLIAdapter, threadId: AgentThreadID) async throws -> String {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let providerThreadId = adapter.listSessions().first(where: { $0.threadId == threadId })?.providerThreadId,
               !providerThreadId.isEmpty {
                return providerThreadId
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for Claude CLI adapter provider thread id")
        return ""
    }

    private func waitForReadableTurn(adapter: ClaudeCLIAdapter, threadId: AgentThreadID, turnId: String) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if ((try? await adapter.readThread(threadId: threadId)) ?? []).contains(where: { $0.completedTurnId == turnId }) {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for readable Claude turn \(turnId)")
    }

    private func waitUntil(_ message: String, condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(message)")
    }

    private static func runtimePayload(_ json: String?) -> [String: Any]? {
        guard let json,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// WHY: a committed cap delete cascades SQLite rows but does not release a
    /// completed resident provider process or retry buffers held by this process.
    /// Retirement must clear those without inventing a cancelled lifecycle.
    func test_retireDeletedThreads_releasesTerminalResidentSessionAndBufferedFailureState() throws {
        let tmp = NSTemporaryDirectory() + "rc2-retire-deleted-thread-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let thread = AgentThread(title: "retire", provider: .codex, model: "m")
        try threadRepo.upsert(thread)
        let adapter = SpyProviderAdapter(provider: .codex)
        adapter.sessionSummaries = [
            AgentProviderSessionSummary(
                threadId: thread.id,
                provider: .codex,
                status: .completed,
                providerThreadId: "resident-idle"
            )
        ]
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: AgentMessageRepository(db: db),
            threadRepo: threadRepo,
            providerAdapters: [.codex: adapter]
        )
        coordinator.seedDeletedThreadRuntimeStateForTesting(thread.id)
        XCTAssertTrue(coordinator.deletedThreadRuntimeResidueForTesting.contains(thread.id))
        var lifecycleEvents = 0
        coordinator.onRunFinished = { _, _, _ in lifecycleEvents += 1 }

        try threadRepo.delete(id: thread.id)
        XCTAssertEqual(coordinator.retireDeletedThreads([thread.id])[thread.id], .retired)
        XCTAssertEqual(coordinator.retireDeletedThreads([thread.id])[thread.id], .retired)

        XCTAssertEqual(adapter.stopSessionCallCount, 1,
                       "an idle resident session must be released exactly once after its row commits deleted")
        XCTAssertFalse(coordinator.deletedThreadRuntimeResidueForTesting.contains(thread.id),
                       "deleted threads must not retain stream buffers, retry failures, or per-thread caches")
        XCTAssertEqual(lifecycleEvents, 0,
                       "retiring an already-terminal session must not emit a synthetic run lifecycle")
    }

    /// WHY: a provider stop failure leaves process ownership uncertain. Runtime
    /// state must survive for an explicit retry rather than being purged after a
    /// partially completed retirement attempt.
    func test_retireDeletedThreads_stopFailureRequiresRetryBeforePurge() throws {
        let tmp = NSTemporaryDirectory() + "rc2-retire-stop-retry-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let thread = AgentThread(title: "stop retry", provider: .codex, model: "m")
        try threadRepo.upsert(thread)
        let adapter = SpyProviderAdapter(provider: .codex)
        adapter.sessionSummaries = [AgentProviderSessionSummary(
            threadId: thread.id,
            provider: .codex,
            status: .completed,
            providerThreadId: "resident-stop-retry"
        )]
        adapter.stopSessionError = NSError(domain: "FakeRunnerTests.stopSession", code: 1)
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: AgentMessageRepository(db: db),
            threadRepo: threadRepo,
            providerAdapters: [.codex: adapter]
        )
        coordinator.seedDeletedThreadRuntimeStateForTesting(thread.id)
        try threadRepo.delete(id: thread.id)

        XCTAssertEqual(coordinator.retireDeletedThreads([thread.id])[thread.id], .retryRequired)
        XCTAssertTrue(coordinator.deletedThreadRuntimeResidueForTesting.contains(thread.id),
                      "failed provider stop must preserve all purgeable runtime state")

        adapter.stopSessionError = nil
        XCTAssertEqual(coordinator.retireDeletedThreads([thread.id])[thread.id], .retired)
        XCTAssertFalse(coordinator.deletedThreadRuntimeResidueForTesting.contains(thread.id))
        XCTAssertEqual(adapter.stopSessionCallCount, 2,
                       "the later explicit retry must repeat and complete the failed stop")
    }

    /// WHY: a late cumulative usage receipt can arrive after normal terminal
    /// cleanup has already removed active/pending state. Its run-to-thread
    /// ownership must survive long enough for a cap delete to purge both an
    /// enrichment error retry and a false/not-enriched residue, without touching
    /// a different thread's late receipt state.
    func test_retireDeletedThreads_purgesLateReceiptResidueAfterNormalTerminalCleanup() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-retire-late-receipt-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let victim = AgentThread(title: "late receipt victim", provider: .codex, model: "m")
        let foreign = AgentThread(title: "late receipt foreign", provider: .codex, model: "m")
        try threadRepo.upsert(victim)
        try threadRepo.upsert(foreign)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(scenario: .simpleAssistant(reply: "done"))]
        )
        let victimRun = try await coordinator.startRun(AgentRunRequest(
            threadId: victim.id,
            provider: .codex,
            model: "m",
            cwd: tmp,
            prompt: "finish before late usage"
        ))

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if (try? runRepo.get(id: victimRun))?.finishedAt != nil,
               coordinator.runThreadOwnershipForTesting[victimRun] == nil {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil((try? runRepo.get(id: victimRun))?.finishedAt,
                        "precondition: the victim run must finish normally")
        XCTAssertNil(coordinator.runThreadOwnershipForTesting[victimRun],
                     "normal terminal cleanup must release ownership before a late receipt re-establishes it")
        // This test isolates retry-residue ownership. Provider stop failure has
        // its own fail-closed test above, so remove the completed one-shot session.
        coordinator.replaceProviderAdapter(.codex, adapter: SpyProviderAdapter(provider: .codex))

        let foreignRun = AgentRunID()
        try runRepo.upsert(AgentRun(
            id: foreignRun,
            threadId: foreign.id,
            provider: .codex,
            model: "m",
            status: .completed,
            finishedAt: Date()
        ))
        coordinator.receiptUsageEnrichmentOverrideForTesting = { runId, _ in
            if runId == victimRun {
                throw NSError(domain: "FakeRunnerTests.lateReceipt", code: 1)
            }
            return false
        }
        coordinator.recordLateCumulativeUsageForTesting(
            runId: victimRun,
            threadId: victim.id,
            totalTokens: 13
        )
        coordinator.recordLateCumulativeUsageForTesting(
            runId: foreignRun,
            threadId: foreign.id,
            totalTokens: 17
        )

        XCTAssertEqual(coordinator.runThreadOwnershipForTesting[victimRun], victim.id)
        XCTAssertEqual(coordinator.runThreadOwnershipForTesting[foreignRun], foreign.id)
        XCTAssertTrue(coordinator.lateReceiptRunResidueForTesting.contains(victimRun),
                      "an enrichment error must retain the late usage retry until deletion or success")
        XCTAssertTrue(coordinator.lateReceiptRunResidueForTesting.contains(foreignRun),
                      "a false enrichment result must retain its late usage for a future correction")

        try threadRepo.delete(id: victim.id)
        XCTAssertEqual(coordinator.retireDeletedThreads([victim.id])[victim.id], .retired)
        XCTAssertEqual(coordinator.retireDeletedThreads([victim.id])[victim.id], .retired)

        XCTAssertFalse(coordinator.lateReceiptRunResidueForTesting.contains(victimRun),
                       "deleted-thread retirement must purge late usage, reconciliation, and retry state")
        XCTAssertNil(coordinator.runThreadOwnershipForTesting[victimRun],
                     "the deleted run's ownership index must not outlive the purge")
        XCTAssertTrue(coordinator.lateReceiptRunResidueForTesting.contains(foreignRun),
                      "retiring one thread must not clear another thread's late receipt state")
        XCTAssertEqual(coordinator.runThreadOwnershipForTesting[foreignRun], foreign.id,
                       "foreign late receipt ownership must remain intact")
    }

    /// WHY: callbacks arriving after a committed delete and completed retirement
    /// must not recreate usage or central provider-event ownership for that thread.
    func test_retiredDeletedThread_rejectsLateUsageAndProviderRuntimeEvent() throws {
        let tmp = NSTemporaryDirectory() + "rc2-retire-late-callback-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "late callback", provider: .codex, model: "m")
        let runId = AgentRunID()
        try threadRepo.upsert(thread)
        try runRepo.upsert(AgentRun(
            id: runId,
            threadId: thread.id,
            provider: .codex,
            model: "m",
            status: .completed,
            finishedAt: Date()
        ))
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: AgentMessageRepository(db: db),
            threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(scenario: .simpleAssistant(reply: "unused"))]
        )
        try threadRepo.delete(id: thread.id)
        XCTAssertEqual(coordinator.retireDeletedThreads([thread.id])[thread.id], .retired)

        coordinator.recordLateCumulativeUsageForTesting(runId: runId, threadId: thread.id, totalTokens: 21)
        coordinator.handleRunEventForTesting(
            .event(.providerRuntime(ProviderRuntimeEvent(
                provider: .codex,
                source: "test.late",
                method: "late.callback",
                payloadJSON: "{}",
                receivedAtMs: 1
            ))),
            runId: runId,
            threadId: thread.id
        )

        XCTAssertNil(try threadRepo.get(id: thread.id))
        XCTAssertNil(try runRepo.get(id: runId))
        XCTAssertNil(coordinator.runThreadOwnershipForTesting[runId])
        XCTAssertFalse(coordinator.lateReceiptRunResidueForTesting.contains(runId))
        XCTAssertFalse(coordinator.deletedThreadRuntimeResidueForTesting.contains(thread.id))
    }

    /// WHY: the first callback may fail open for a transient durable read, but a
    /// later validation proving the graph present must clear only the marker and
    /// preserve the admitted usage state without another read on its fast path.
    func test_lateUsageReadError_validationPresentClearsMarkerAndPreservesState() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-late-validation-present-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "validation present", provider: .codex, model: "m")
        let runId = AgentRunID()
        try threadRepo.upsert(thread)
        try runRepo.upsert(AgentRun(id: runId, threadId: thread.id, provider: .codex, model: "m", status: .completed))
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: AgentMessageRepository(db: db),
            threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(scenario: .simpleAssistant(reply: "unused"))]
        )
        var reads = 0
        coordinator.lateRunAdmissionPresenceOverrideForTesting = { _, _ in
            reads += 1
            if reads == 1 { throw NSError(domain: "FakeRunnerTests.lateValidation", code: 1) }
            return true
        }
        coordinator.recordLateCumulativeUsageForTesting(runId: runId, threadId: thread.id, totalTokens: 5)
        XCTAssertTrue(coordinator.pendingLateRunValidationIDsForTesting.contains(runId))

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && coordinator.pendingLateRunValidationIDsForTesting.contains(runId) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(coordinator.pendingLateRunValidationIDsForTesting.contains(runId))
        XCTAssertTrue(coordinator.lateReceiptRunResidueForTesting.contains(runId))
        let readsAfterValidation = reads
        coordinator.recordLateCumulativeUsageForTesting(runId: runId, threadId: thread.id, totalTokens: 7)
        XCTAssertEqual(reads, readsAfterValidation,
                       "owned follow-up usage must not perform a durable graph read")
    }

    /// WHY: when validation after an admitted read error proves the durable graph
    /// absent, it must purge that exact callback residue and ownership.
    func test_lateUsageReadError_validationAbsentPurgesAdmittedState() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-late-validation-absent-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let thread = AgentThread(title: "validation absent", provider: .codex, model: "m")
        let runId = AgentRunID()
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: AgentMessageRepository(db: db),
            threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(scenario: .simpleAssistant(reply: "unused"))]
        )
        var reads = 0
        coordinator.lateRunAdmissionPresenceOverrideForTesting = { _, _ in
            reads += 1
            if reads == 1 { throw NSError(domain: "FakeRunnerTests.lateValidation", code: 2) }
            return false
        }
        coordinator.recordLateCumulativeUsageForTesting(runId: runId, threadId: thread.id, totalTokens: 5)
        XCTAssertTrue(coordinator.lateReceiptRunResidueForTesting.contains(runId),
                      "the exact first callback is admitted while validation is pending")

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && coordinator.pendingLateRunValidationIDsForTesting.contains(runId) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(coordinator.pendingLateRunValidationIDsForTesting.contains(runId))
        XCTAssertFalse(coordinator.lateReceiptRunResidueForTesting.contains(runId))
        XCTAssertNil(coordinator.runThreadOwnershipForTesting[runId])
    }

    /// WHY: a persistent read failure may admit only the exact first callback.
    /// Its validation marker must remain observable and bounded; capacity
    /// exhaustion rejects new unknown callbacks instead of evicting evidence.
    func test_lateCallbackPersistentReadError_admitsOnceAndFailsClosedAtCapacity() throws {
        let tmp = NSTemporaryDirectory() + "rc2-late-validation-capacity-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let thread = AgentThread(title: "validation capacity", provider: .codex, model: "m")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: AgentMessageRepository(db: db),
            threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(scenario: .simpleAssistant(reply: "unused"))]
        )
        coordinator.lateRunAdmissionPresenceOverrideForTesting = { _, _ in
            throw NSError(domain: "FakeRunnerTests.lateValidation", code: 3)
        }
        let firstRun = AgentRunID()
        var publishedEvents = 0
        coordinator.onAssistantEvent = { _, _, _ in publishedEvents += 1 }
        let event = AgentRunEvent.event(.providerRuntime(ProviderRuntimeEvent(
            provider: .codex,
            source: "test.persistent",
            method: "persistent.callback",
            payloadJSON: "{}",
            receivedAtMs: 1
        )))

        coordinator.handleRunEventForTesting(event, runId: firstRun, threadId: thread.id)
        coordinator.handleRunEventForTesting(event, runId: firstRun, threadId: thread.id)
        XCTAssertEqual(publishedEvents, 1,
                       "the unresolved callback identity may be admitted exactly once")
        XCTAssertTrue(coordinator.pendingLateRunValidationIDsForTesting.contains(firstRun))

        for _ in 1..<64 {
            coordinator.recordLateCumulativeUsageForTesting(
                runId: AgentRunID(),
                threadId: thread.id,
                totalTokens: 1
            )
        }
        let overflowRun = AgentRunID()
        coordinator.recordLateCumulativeUsageForTesting(
            runId: overflowRun,
            threadId: thread.id,
            totalTokens: 1
        )
        XCTAssertEqual(coordinator.pendingLateRunValidationIDsForTesting.count, 64)
        XCTAssertNil(coordinator.runThreadOwnershipForTesting[overflowRun],
                     "capacity exhaustion must reject rather than admit untracked state")
        XCTAssertFalse(coordinator.lateReceiptRunResidueForTesting.contains(overflowRun))
    }

    /// WHY: deletion evidence alone cannot authorize tearing down a running or
    /// provider-mismatched session. Those may be foreign work whose identity is
    /// unavailable after the durable row has gone away.
    func test_retireDeletedThreads_preservesActiveAndForeignProviderSessions() throws {
        let tmp = NSTemporaryDirectory() + "rc2-retire-preserve-provider-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let active = AgentThread(title: "active", provider: .codex, model: "m")
        let foreign = AgentThread(title: "foreign", provider: .codex, model: "m")
        try threadRepo.upsert(active)
        try threadRepo.upsert(foreign)
        let adapter = SpyProviderAdapter(provider: .codex)
        adapter.sessionSummaries = [
            AgentProviderSessionSummary(
                threadId: active.id,
                provider: .codex,
                status: .running,
                providerThreadId: "active-session"
            ),
            AgentProviderSessionSummary(
                threadId: foreign.id,
                provider: .claude,
                status: .completed,
                providerThreadId: "foreign-session"
            )
        ]
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: AgentMessageRepository(db: db),
            threadRepo: threadRepo,
            providerAdapters: [.codex: adapter]
        )

        try threadRepo.delete(id: active.id)
        try threadRepo.delete(id: foreign.id)
        let outcomes = coordinator.retireDeletedThreads([active.id, foreign.id])

        XCTAssertEqual(outcomes[active.id], .retryRequired)
        XCTAssertEqual(outcomes[foreign.id], .retryRequired)
        XCTAssertEqual(adapter.stopSessionCallCount, 0,
                       "active or provider-mismatched sessions must remain untouched by post-delete retirement")
        XCTAssertEqual(adapter.sessionSummaries.count, 2,
                       "conservative retirement must preserve the adapter's foreign/active ownership")
    }
}

private extension AssistantEvent {
    var completedTurnId: String? {
        if case .turnCompleted(let turnId, _) = self { return turnId }
        return nil
    }
}

private final class DelayedEventRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        Task.detached {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            let turnId = UUID().uuidString
            onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            onEvent(.event(.turnStarted(turnId: turnId)))
            onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: "late")))
            onEvent(.finished(.completed, finalMessage: "late", providerThreadId: providerThreadId))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}

private final class PromptEchoRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        Task.detached {
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            let turnId = UUID().uuidString
            let answer = "OK \(request.prompt)"
            onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            onEvent(.event(.turnStarted(turnId: turnId)))
            onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: answer)))
            onEvent(.finished(.completed, finalMessage: answer, providerThreadId: providerThreadId))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}

private final class ScriptedClaudeRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .claude

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        Task.detached {
            let providerThreadId = request.providerThreadId ?? "claude-session-test"
            let turnId = "turn-\(request.prompt)"
            onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            onEvent(.event(.turnStarted(turnId: turnId)))
            onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: "OK \(request.prompt)")))
            onEvent(.finished(.completed, finalMessage: "OK \(request.prompt)", providerThreadId: providerThreadId))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}

private final class SpyProviderAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider
    let finishImmediately: Bool
    private let lock = NSLock()
    private var _sendTurnCount = 0
    private var _cancelCount = 0
    private var _stopAllCalled = false
    private var _stopAllForAppTerminationCalled = false
    private var _lastPrompt: String?
    private var _lastProviderThreadId: String?
    private var _lastPermissionMode: AgentPermissionMode?
    private var _lastServiceTier: AgentServiceTier?
    private var _lastInteractionMode: AgentInteractionMode?
    private var _lastRequestResponse: (AgentThreadID, String, AgentProviderRequestResponse)?
    private var _lastUserInputResponse: (AgentThreadID, String, String)?
    private var _interruptTurnCallCount = 0
    private var _lastRecoveredExtraArgs: [String] = []
    var readEvents: [AssistantEvent] = []
    var sessionSummaries: [AgentProviderSessionSummary] = []
    var stopSessionError: Error?
    private var _stopSessionCallCount = 0
    private var _lastRollback: (AgentThreadID, String)?

    var sendTurnCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _sendTurnCount
    }
    var cancelCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _cancelCount
    }
    var stopAllCalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _stopAllCalled
    }
    var stopAllForAppTerminationCalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _stopAllForAppTerminationCalled
    }
    var lastPrompt: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastPrompt
    }
    var lastProviderThreadId: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastProviderThreadId
    }
    var lastPermissionMode: AgentPermissionMode? {
        lock.lock(); defer { lock.unlock() }
        return _lastPermissionMode
    }
    var lastServiceTier: AgentServiceTier? {
        lock.lock(); defer { lock.unlock() }
        return _lastServiceTier
    }
    var lastInteractionMode: AgentInteractionMode? {
        lock.lock(); defer { lock.unlock() }
        return _lastInteractionMode
    }
    var lastRequestResponse: (AgentThreadID, String, AgentProviderRequestResponse)? {
        lock.lock(); defer { lock.unlock() }
        return _lastRequestResponse
    }
    var lastUserInputResponse: (AgentThreadID, String, String)? {
        lock.lock(); defer { lock.unlock() }
        return _lastUserInputResponse
    }
    var lastRollback: (AgentThreadID, String)? {
        lock.lock(); defer { lock.unlock() }
        return _lastRollback
    }
    var stopSessionCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _stopSessionCallCount
    }
    var interruptTurnCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _interruptTurnCallCount
    }
    var lastRecoveredExtraArgs: [String] {
        lock.lock(); defer { lock.unlock() }
        return _lastRecoveredExtraArgs
    }

    init(provider: AgentProvider, finishImmediately: Bool = true) {
        self.provider = provider
        self.finishImmediately = finishImmediately
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }

    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        lock.lock()
        _sendTurnCount += 1
        _lastPrompt = request.prompt
        _lastProviderThreadId = request.providerThreadId
        _lastPermissionMode = request.permissionMode
        _lastServiceTier = request.serviceTier
        _lastInteractionMode = request.interactionMode
        lock.unlock()
        if finishImmediately {
            Task.detached {
                let providerThreadId = request.providerThreadId ?? UUID().uuidString
                onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
                onEvent(.finished(.completed, finalMessage: nil, providerThreadId: providerThreadId))
            }
        }
        return AgentRunHandle(runId: request.runId, process: nil) { [weak self] in
            self?.lock.lock()
            self?._cancelCount += 1
            self?.lock.unlock()
        }
    }

    func interruptTurn(threadId: AgentThreadID) throws {
        lock.lock()
        _interruptTurnCallCount += 1
        lock.unlock()
    }
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
        lock.lock()
        _lastRequestResponse = (threadId, requestId, response)
        lock.unlock()
    }
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        lock.lock()
        _lastUserInputResponse = (threadId, requestId, text)
        lock.unlock()
    }
    func stopSession(threadId: AgentThreadID) throws {
        lock.lock()
        _stopSessionCallCount += 1
        let error = stopSessionError
        if error == nil {
            sessionSummaries.removeAll { $0.threadId == threadId }
        }
        lock.unlock()
        if let error { throw error }
    }
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {
        lock.lock()
        _lastProviderThreadId = request.providerThreadId
        _lastRecoveredExtraArgs = request.extraArgs
        sessionSummaries.append(AgentProviderSessionSummary(threadId: request.threadId, provider: provider, status: .completed, providerThreadId: request.providerThreadId))
        lock.unlock()
    }
    func listSessions() -> [AgentProviderSessionSummary] {
        lock.lock(); defer { lock.unlock() }
        return sessionSummaries
    }
    func hasSession(threadId: AgentThreadID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessionSummaries.contains { $0.threadId == threadId }
    }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { readEvents }
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {
        lock.lock()
        _lastRollback = (threadId, toTurnId)
        lock.unlock()
    }
    func stopAll() {
        lock.lock()
        _stopAllCalled = true
        lock.unlock()
    }
    func stopAllForAppTermination() {
        lock.lock()
        _stopAllForAppTerminationCalled = true
        lock.unlock()
    }
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}
}

private final class FailingProviderAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider

    init(provider: AgentProvider) {
        self.provider = provider
    }

    func listModels() async -> [AgentModelDescriptor] { [] }
    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }
    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        throw AgentProviderAdapterError.unsupported("simulated provider startup failure")
    }
    func interruptTurn(threadId: AgentThreadID) throws {}
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {}
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {}
    func stopSession(threadId: AgentThreadID) throws {}
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] { [] }
    func hasSession(threadId: AgentThreadID) -> Bool { false }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}
}

private final class PendingUserInputAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider = .claude
    private let lock = NSLock()
    private var callbacks: [AgentThreadID: @Sendable (AgentRunEvent) -> Void] = [:]

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }

    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        lock.lock()
        callbacks[request.threadId] = onEvent
        lock.unlock()
        Task.detached {
            onEvent(.event(.threadStarted(threadId: "claude-runtime-session", providerThreadId: "claude-runtime-session")))
            onEvent(.event(.turnStarted(turnId: "turn-runtime-1")))
            onEvent(.event(.userInputRequested(AssistantUserInputRequest(
                id: "ask-runtime-1",
                turnId: "turn-runtime-1",
                prompt: "Continue?",
                options: ["yes", "no"],
                createdAtMs: Int64(Date().timeIntervalSince1970 * 1000)
            ))))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }

    func interruptTurn(threadId: AgentThreadID) throws {}
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {}
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        lock.lock()
        let callback = callbacks[threadId]
        lock.unlock()
        callback?(.event(.userInputResolved(requestId: requestId, answer: text)))
    }
    func stopSession(threadId: AgentThreadID) throws {}
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] { [] }
    func hasSession(threadId: AgentThreadID) -> Bool { false }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}
}

private final class PendingApprovalAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider = .claude
    private let lock = NSLock()
    private var callbacks: [AgentThreadID: @Sendable (AgentRunEvent) -> Void] = [:]

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }

    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        lock.lock()
        callbacks[request.threadId] = onEvent
        lock.unlock()
        Task.detached {
            onEvent(.event(.threadStarted(threadId: "claude-approval-session", providerThreadId: "claude-approval-session")))
            onEvent(.event(.turnStarted(turnId: "turn-approval-1")))
            onEvent(.event(.requestOpened(AssistantPendingRequest(
                id: "approval-runtime-1",
                turnId: "turn-approval-1",
                kind: .commandExecution,
                title: "Run shell command?",
                detail: "swift test",
                createdAtMs: Int64(Date().timeIntervalSince1970 * 1000)
            ))))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }

    func interruptTurn(threadId: AgentThreadID) throws {}
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
        lock.lock()
        let callback = callbacks[threadId]
        lock.unlock()
        callback?(.event(.requestResolved(requestId: requestId, state: .approved)))
    }
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {}
    func stopSession(threadId: AgentThreadID) throws {}
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] { [] }
    func hasSession(threadId: AgentThreadID) -> Bool { false }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}
}

private final class ClaudeSessionSnapshotAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider = .claude

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }

    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        Task.detached {
            onEvent(.event(.threadStarted(threadId: "claude-sdk-session-1", providerThreadId: "claude-sdk-session-1")))
            onEvent(.event(.turnStarted(turnId: "turn-snapshot-1")))
            let startedPayload = """
            {"activeTurnId":"turn-snapshot-1","providerThreadId":"claude-sdk-session-1","resume":"claude-sdk-session-1","resumeSessionAt":"assistant-uuid-1","turnCount":0,"inFlightToolIds":["tool-1"],"pendingApprovalRequestIds":["approval-1"],"pendingUserInputRequestIds":[],"model":"claude-haiku-4-5-20251001"}
            """
            onEvent(.event(.providerRuntime(ProviderRuntimeEvent(
                provider: .claude,
                source: "claude.stream-json.session",
                method: "claude.session.snapshot",
                providerTurnId: "turn-snapshot-1",
                payloadJSON: startedPayload,
                receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
            ))))
            let completedPayload = """
            {"providerThreadId":"claude-sdk-session-1","resume":"claude-sdk-session-1","resumeSessionAt":"assistant-uuid-1","lastCompletedTurnId":"turn-snapshot-1","turnCount":1,"inFlightToolIds":[],"pendingApprovalRequestIds":[],"pendingUserInputRequestIds":[],"model":"claude-haiku-4-5-20251001"}
            """
            onEvent(.event(.providerRuntime(ProviderRuntimeEvent(
                provider: .claude,
                source: "claude.stream-json.session",
                method: "claude.session.snapshot",
                providerTurnId: "turn-snapshot-1",
                payloadJSON: completedPayload,
                receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
            ))))
            onEvent(.event(.turnCompleted(turnId: "turn-snapshot-1", finalMessage: "OK snapshot")))
            onEvent(.finished(.completed, finalMessage: "OK snapshot", providerThreadId: "claude-sdk-session-1"))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }

    func interruptTurn(threadId: AgentThreadID) throws {}
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {}
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {}
    func stopSession(threadId: AgentThreadID) throws {}
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] { [] }
    func hasSession(threadId: AgentThreadID) -> Bool { false }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}
}
