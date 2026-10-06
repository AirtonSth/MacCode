import XCTest
import AgentRuntime
import CoreModel
@testable import AppShell
@testable import Persistence
@testable import Surfaces

/// WHY: a workspace thread run as a bot must keep the workspace cwd and thread model while the
/// bot brain reaches the prompt; with no bot the request must stay exactly what it was before.
@MainActor
final class AgentAppBotRunActorTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    private static let soulMarker = "ZEBRA-SOUL-MARKER-7731"

    private struct Fixture {
        let ctx: AppContext
        let router: AppCommandRouter
        let botsVM: BotsViewModel
        let surface: AgentAppSurface
        let runner: ControlledBotHandoffRunner
        let bot: BotDefinition
        let thread: AgentThread
        let workspaceCwd: String
        @MainActor var vm: AgentAppViewModel { surface.viewModel }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2BotRunActor-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = ControlledBotHandoffRunner(provider: .codex)
        ctx.coordinator.replaceProviderAdapter(.codex, adapter: TerminalRetiringOneShotAdapter(runner: runner))
        let snapshots = [
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex,
                models: [AgentModelDescriptor(id: "fake-model", label: "Fake Model", provider: .codex)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "codex"
            )
        ]
        router.rememberProviderSnapshotsForSend(snapshots)
        let botsVM = BotsViewModel(context: ctx, router: router)
        router.botsViewModel = botsVM
        let bot = try botsVM.create(name: "Quinn", title: "Scout", soul: Self.soulMarker)
        let workspace = try router.createWorkspace(name: "actor-ws", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "Actor thread",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        let surface = AgentAppSurface(
            workspaceID: workspace.id,
            cwd: workspaceDir.path,
            coordinator: ctx.coordinator,
            threadRepo: ctx.threadRepo,
            messageRepo: ctx.messageRepo,
            queuedMessageRepo: ctx.queuedMessageRepo,
            providerSessionRepo: ctx.providerSessionRuntimeRepo,
            checkpointRepo: ctx.turnCheckpointRepo,
            initialThreadId: thread.id
        )
        router.configureAgentAppBotMentions(surface)
        surface.viewModel.providerSnapshots = snapshots
        surface.viewModel.providerLaunchConfig = { _, _ in ("/usr/bin/true", ["ACTOR_TEST_ENV": "kept"]) }
        surface.viewModel.selectThread(thread.id)
        return Fixture(
            ctx: ctx, router: router, botsVM: botsVM, surface: surface, runner: runner,
            bot: bot, thread: thread, workspaceCwd: workspaceDir.path
        )
    }

    private func waitUntil(timeout: TimeInterval = 6, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    func test_botOnMacKeepsWorkspaceCwdAndThreadModelAndLinksSingleThread() async throws {
        let f = try makeFixture()
        let threadsBefore = try f.ctx.threadRepo.list(workspaceId: f.vm.workspaceID).map(\.id)
        f.vm.setRunActor(.bot(f.bot.id))
        f.vm.prompt = "hello bot"
        await f.vm.send()
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started, "run must start: \(f.vm.statusMessage ?? "no status")")
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertEqual(request.cwd, f.workspaceCwd, "bot on Mac runs in the workspace, not the bot home")
        XCTAssertEqual(request.model, "fake-model", "model comes from the thread, not the bot")
        XCTAssertTrue(request.prompt.contains(Self.soulMarker), "prompt carries the compiled bot instructions")
        XCTAssertTrue(request.prompt.contains("hello bot"))
        XCTAssertEqual(request.userMessageContent, "hello bot", "transcript keeps the raw user text")

        let stored = try XCTUnwrap(try f.ctx.threadRepo.get(id: f.thread.id))
        XCTAssertEqual(stored.actor, .bot(f.bot.id))
        XCTAssertNotNil(stored.actorLockedAt)
        XCTAssertEqual(stored.executionTarget, .mac)
        let painted = try XCTUnwrap(f.vm.threads.first(where: { $0.id == f.thread.id }))
        XCTAssertEqual(painted.actor, .bot(f.bot.id))
        XCTAssertNotNil(painted.actorLockedAt)

        let conversations = try f.ctx.botStore.listConversations(botID: f.bot.id)
            .filter { $0.linkedAgentThreadID == f.thread.id }
        XCTAssertEqual(conversations.count, 1, "exactly one conversation links the workspace thread")
        XCTAssertEqual(
            try f.ctx.threadRepo.list(workspaceId: f.vm.workspaceID).map(\.id), threadsBefore,
            "single thread: no AgentThread is created for the bot"
        )
    }

    func test_vmBotBusyOnOtherThreadQueuesFreshThreadInsteadOfRunning() async throws {
        // WHY: one VM runs one thread at a time; a second thread must wait, not start a run.
        let f = try makeFixture()
        f.vm.botExecutionTargetProvider = { _ in .vm }
        let holder = BotVMRunRegistry.Entry(
            threadID: AgentThreadID(), runID: AgentRunID(), title: "Tarefa A", workspace: f.workspaceCwd
        )
        XCTAssertNil(BotVMRunRegistry.shared.tryBegin(botID: f.bot.id, entry: holder))
        defer { _ = BotVMRunRegistry.shared.releaseAndNextWaiting(runID: holder.runID) }
        f.vm.setRunActor(.bot(f.bot.id))
        f.vm.prompt = "second task"
        await f.vm.send()
        XCTAssertTrue(f.runner.requests.isEmpty, "no run while another thread holds the VM")
        XCTAssertTrue(f.vm.statusMessage.contains("bot ocupado em Tarefa A"), f.vm.statusMessage)
        XCTAssertEqual(BotVMRunRegistry.shared.waitingThreads(botID: f.bot.id), [f.thread.id])
        XCTAssertEqual(try f.ctx.queuedMessageRepo.list(threadId: f.thread.id).count, 1)
    }

    /// Locks `thread` to the bot through the busy-VM path (lock, then queue)
    /// so no provider starts; returns the stored guest marker.
    private func lockOnBusyVM(_ f: Fixture, thread: AgentThread) async throws -> String? {
        f.vm.botExecutionTargetProvider = { _ in .vm }
        let snapshots = f.vm.providerSnapshots + [
            AgentProviderSnapshotFactory.snapshot(
                provider: .distill,
                models: [AgentModelDescriptor(id: "claude/claude-sonnet-4-5", label: "Sonnet", provider: .distill)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "distill"
            )
        ]
        f.router.rememberProviderSnapshotsForSend(snapshots)
        f.vm.providerSnapshots = snapshots
        f.vm.selectThread(thread.id)
        let holder = BotVMRunRegistry.Entry(
            threadID: AgentThreadID(), runID: AgentRunID(), title: "Tarefa A", workspace: f.workspaceCwd
        )
        XCTAssertNil(BotVMRunRegistry.shared.tryBegin(botID: f.bot.id, entry: holder))
        defer { _ = BotVMRunRegistry.shared.releaseAndNextWaiting(runID: holder.runID) }
        f.vm.setRunActor(.bot(f.bot.id))
        f.vm.prompt = "task"
        await f.vm.send()
        XCTAssertTrue(f.runner.requests.isEmpty)
        let stored = try XCTUnwrap(try f.ctx.threadRepo.get(id: thread.id))
        XCTAssertEqual(stored.actor, .bot(f.bot.id), f.vm.statusMessage)
        XCTAssertEqual(stored.executionTarget, .vm)
        return try XCTUnwrap(try f.ctx.threadRepo.guestPlacement(of: thread.id)).guestRuntime
    }

    func test_aNewDistillWorkspaceThreadOfADockerBotIsMarkedToRunInTheGuest() async throws {
        // WHY (plan A B3, owner decision 5): the guest marker is what routes a
        // run into the bot's Linux VM. Without it a new Distill thread of a
        // Docker-desktop bot would run on the Mac for good.
        let f = try makeFixture()
        let thread = try f.router.createAgentThread(
            workspace: f.vm.workspaceID, title: "Distill thread", provider: .distill,
            model: "claude/claude-sonnet-4-5", permissionMode: .supervised, reasoningEffort: .medium
        )
        let marker = try await lockOnBusyVM(f, thread: thread)
        XCTAssertEqual(marker, BotGuestRuntime.distillV1)
    }

    func test_aCodexThreadOrADistillThreadWithAMacSessionIsNotMarked() async throws {
        // WHY: only Distill runs in the guest (B4: a marked Codex thread fails
        // closed), and a thread whose Distill session lives on the Mac keeps
        // running there (D5); the guest could not load that session.
        let f = try makeFixture()
        let codexMarker = try await lockOnBusyVM(f, thread: f.thread)
        XCTAssertNil(codexMarker)

        var withMacSession = try f.router.createAgentThread(
            workspace: f.vm.workspaceID, title: "Old distill", provider: .distill,
            model: "claude/claude-sonnet-4-5", permissionMode: .supervised, reasoningEffort: .medium
        )
        withMacSession.providerThreadId = "mac-session-1"
        try f.ctx.threadRepo.upsert(withMacSession)
        f.vm.reloadThreads()
        let sessionMarker = try await lockOnBusyVM(f, thread: withMacSession)
        XCTAssertNil(sessionMarker)
    }

    func test_noActorRequestMatchesPreChangeValuesFieldByField() async throws {
        let f = try makeFixture()
        f.vm.prompt = "plain question"
        await f.vm.send()
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started)
        let r = try XCTUnwrap(f.runner.requests.first)
        XCTAssertEqual(r.threadId, f.thread.id)
        XCTAssertEqual(r.provider, .codex)
        XCTAssertEqual(r.model, "fake-model")
        XCTAssertEqual(r.cwd, f.workspaceCwd)
        XCTAssertEqual(r.prompt, "plain question")
        XCTAssertEqual(r.userMessageContent, "plain question")
        XCTAssertTrue(r.attachments.isEmpty)
        XCTAssertEqual(r.permissionMode, .supervised)
        XCTAssertEqual(r.reasoningEffort, .medium)
        XCTAssertEqual(r.interactionMode, .default)
        XCTAssertEqual(r.providerBinary, "/usr/bin/true")
        XCTAssertEqual(r.environment["ACTOR_TEST_ENV"], "kept")
        XCTAssertNil(r.environment["RC_REMOTE_CODE_BOT_ID"], "no bot identity leaks into a plain thread")
        XCTAssertTrue(r.extraArgs.isEmpty)
        XCTAssertEqual(r.runAsUser, AgentRunAsUser.current())
        let stored = try XCTUnwrap(try f.ctx.threadRepo.get(id: f.thread.id))
        XCTAssertEqual(stored.actor, .none)
        XCTAssertNil(stored.actorLockedAt)
        XCTAssertNil(stored.executionTarget)
        XCTAssertTrue(try f.ctx.botStore.listConversations(botID: f.bot.id).isEmpty)
    }

    func test_queuedFollowUpOnBotThreadUsesBotBrainAndKeepsWorkspaceCwdAfterChipChangeAttempt() async throws {
        let f = try makeFixture()
        f.vm.setRunActor(.bot(f.bot.id))
        f.vm.prompt = "first"
        await f.vm.send()
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started)
        let first = try XCTUnwrap(f.runner.requests.first)
        XCTAssertTrue(f.runner.finish(runID: first.runId, status: .completed, reply: "done"))
        let settled = await waitUntil {
            (try? f.ctx.threadRepo.get(id: f.thread.id))?.status == .completed
        }
        XCTAssertTrue(settled)

        f.vm.setRunActor(.none)
        XCTAssertEqual(f.vm.selectedRunActor, .bot(f.bot.id), "a locked thread refuses the chip change")

        let raw = "queued follow-up"
        _ = try f.ctx.queuedMessageRepo.enqueue(
            threadId: f.thread.id, text: raw, attachments: [], interactionMode: .default
        )
        try await f.router.drainNextQueuedAgentMessage(thread: f.thread.id)
        XCTAssertEqual(f.runner.requests.count, 2)
        let queued = try XCTUnwrap(f.runner.requests.last)
        XCTAssertTrue(queued.prompt.contains(Self.soulMarker), "queued send keeps the bot brain")
        XCTAssertEqual(queued.userMessageContent, raw)
        XCTAssertEqual(queued.cwd, f.workspaceCwd, "workspace thread keeps the workspace cwd, not the bot home")
    }

    func test_deletedBotBlocksSendWithRecoveryMessage() async throws {
        let f = try makeFixture()
        f.vm.setRunActor(.bot(f.bot.id))
        try f.ctx.botStore.delete(id: f.bot.id)
        f.vm.prompt = "anyone there?"
        await f.vm.send()
        XCTAssertEqual(f.vm.statusMessage, "Bot Quinn foi apagado. Use \"Continuar sem bot\".")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(f.runner.requests.isEmpty, "a deleted bot must not run")
        let stored = try XCTUnwrap(try f.ctx.threadRepo.get(id: f.thread.id))
        XCTAssertEqual(stored.actor, .none)
        XCTAssertNil(stored.actorLockedAt)
    }

    private func runFirstBotTurn(_ f: Fixture) async throws {
        f.vm.setRunActor(.bot(f.bot.id))
        f.vm.prompt = "first question"
        await f.vm.send()
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started, "run must start: \(f.vm.statusMessage ?? "no status")")
        let first = try XCTUnwrap(f.runner.requests.first)
        XCTAssertTrue(f.runner.finish(runID: first.runId, status: .completed, reply: "first answer"))
        let settled = await waitUntil {
            (try? f.ctx.threadRepo.get(id: f.thread.id))?.status == .completed
        }
        XCTAssertTrue(settled)
    }

    func test_lockedThreadWithDeletedBotIsReadOnlyAndRefusesSend() async throws {
        let f = try makeFixture()
        try await runFirstBotTurn(f)
        XCTAssertFalse(f.vm.selectedThreadBotUnavailable)
        try f.ctx.botStore.delete(id: f.bot.id)
        XCTAssertTrue(f.vm.selectedThreadBotUnavailable, "banner shows once the bot is gone")
        f.vm.prompt = "still there?"
        await f.vm.send()
        XCTAssertEqual(f.vm.statusMessage, "Bot Quinn foi apagado. Use \"Continuar sem bot\".")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(f.runner.requests.count, 1, "no second run for a deleted bot")
    }

    func test_handoffCreatesUnlockedThreadWithSummaryDraftAndLeavesOldThreadUntouched() async throws {
        let f = try makeFixture()
        try await runFirstBotTurn(f)
        let oldBefore = try XCTUnwrap(try f.ctx.threadRepo.get(id: f.thread.id))
        let newId = try XCTUnwrap(f.vm.startHandoffThread(from: f.thread.id, actor: .none))
        XCTAssertNotEqual(newId, f.thread.id)
        XCTAssertEqual(f.vm.selectedThreadId, newId)
        XCTAssertEqual(f.vm.selectedRunActor, .none)
        XCTAssertFalse(f.vm.runActorLocked, "new thread locks only on first send")
        XCTAssertTrue(f.vm.prompt.hasPrefix("Continuação da thread \"Actor thread\" (id \(f.thread.id.value.uuidString.lowercased()))"))
        XCTAssertTrue(f.vm.prompt.contains("first question"))
        XCTAssertTrue(f.vm.prompt.contains("first answer"))
        let oldAfter = try XCTUnwrap(try f.ctx.threadRepo.get(id: f.thread.id))
        XCTAssertEqual(oldAfter.actor, oldBefore.actor)
        XCTAssertEqual(oldAfter.actorLockedAt, oldBefore.actorLockedAt)
        XCTAssertEqual(oldAfter.executionTarget, oldBefore.executionTarget)
        let newStored = try XCTUnwrap(try f.ctx.threadRepo.get(id: newId))
        XCTAssertEqual(newStored.workspaceId, f.thread.workspaceId)
        XCTAssertEqual(newStored.actor, .none)
        XCTAssertNil(newStored.actorLockedAt)
    }

    func test_handoffToAnotherBotOpensUnlockedThreadForNewBotAndKeepsOldBotLock() async throws {
        // WHY: switching bots must never rewrite the locked thread; it forks a fresh one.
        let f = try makeFixture()
        try await runFirstBotTurn(f)
        let other = try f.botsVM.create(name: "Rhea", title: "Scout", soul: "other soul")
        let newId = try XCTUnwrap(f.vm.startHandoffThread(from: f.thread.id, actor: .bot(other.id)))
        XCTAssertEqual(f.vm.selectedThreadId, newId)
        XCTAssertEqual(f.vm.selectedRunActor, .bot(other.id))
        XCTAssertFalse(f.vm.runActorLocked, "new thread locks only on first send")
        XCTAssertTrue(f.vm.prompt.contains("Actor thread"))
        XCTAssertTrue(f.vm.prompt.contains(f.thread.id.value.uuidString.lowercased()))
        let oldRow = try XCTUnwrap(f.vm.threads.first(where: { $0.id == f.thread.id }))
        XCTAssertEqual(oldRow.actor, .bot(f.bot.id))
        XCTAssertNotNil(oldRow.actorLockedAt)
    }

    func test_handoffSummaryIsDeterministicLastSixTurnsTruncated() {
        let tid = AgentThreadID()
        var messages: [AgentMessage] = []
        for i in 0..<10 {
            messages.append(AgentMessage(threadId: tid, role: i % 2 == 0 ? .user : .assistant, content: "m\(i)"))
        }
        messages.append(AgentMessage(threadId: tid, role: .system, content: "SYSTEM-NOTE"))
        messages[9] = AgentMessage(threadId: tid, role: .assistant, content: String(repeating: "x", count: 500))
        let a = AgentAppViewModel.handoffSummary(title: "T", threadId: tid, messages: messages)
        XCTAssertEqual(a, AgentAppViewModel.handoffSummary(title: "T", threadId: tid, messages: messages))
        XCTAssertFalse(a.contains("SYSTEM-NOTE"))
        XCTAssertFalse(a.contains("m3"), "only the last six user/assistant messages")
        XCTAssertTrue(a.contains("m4"))
        let long = a.split(separator: "\n").first { $0.hasPrefix("Assistente: x") }
        XCTAssertEqual(long?.count, "Assistente: ".count + 300 + 1, "300 chars plus ellipsis")
        XCTAssertEqual(a.split(separator: "\n").count, 7)
    }

    func test_freshViewModelRestoresActorLockAndExecutionTarget() async throws {
        let f = try makeFixture()
        try await runFirstBotTurn(f)
        let fresh = AgentAppSurface(
            workspaceID: f.vm.workspaceID,
            cwd: f.workspaceCwd,
            coordinator: f.ctx.coordinator,
            threadRepo: f.ctx.threadRepo,
            messageRepo: f.ctx.messageRepo,
            queuedMessageRepo: f.ctx.queuedMessageRepo,
            providerSessionRepo: f.ctx.providerSessionRuntimeRepo,
            checkpointRepo: f.ctx.turnCheckpointRepo,
            initialThreadId: nil
        )
        f.router.configureAgentAppBotMentions(fresh)
        let vm = fresh.viewModel
        vm.selectThread(f.thread.id)
        XCTAssertEqual(vm.selectedRunActor, .bot(f.bot.id))
        XCTAssertTrue(vm.runActorLocked)
        let row = try XCTUnwrap(vm.threads.first(where: { $0.id == f.thread.id }))
        XCTAssertNotNil(row.actorLockedAt)
        XCTAssertEqual(row.executionTarget, .mac)
        XCTAssertEqual(vm.executionTarget(for: f.bot.id), .mac)
        vm.setRunActor(.none)
        XCTAssertEqual(vm.selectedRunActor, .bot(f.bot.id), "restored lock still refuses chip changes")
    }

    func test_botSendWithMissingProviderSnapshotIsBlockedBeforeAnyRequest() async throws {
        let f = try makeFixture()
        f.vm.providerSnapshotLoader = { [] }
        f.vm.providerSnapshots = []
        f.router.rememberProviderSnapshotsForSend([])
        f.vm.setRunActor(.bot(f.bot.id))
        f.vm.prompt = "hello"
        await f.vm.send()
        let message = try XCTUnwrap(f.vm.statusMessage, "send must explain why it is blocked")
        XCTAssertFalse(message.isEmpty)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(f.runner.requests.isEmpty, "no provider request without a provider snapshot")
    }
}
