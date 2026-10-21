import XCTest
import AgentRuntime
import CoreModel
import SocketServer
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
        botsVM.dockerGuestReadyOverrideForTesting = true
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

    func test_vmHeldByARebuildQueuesFreshThreadInsteadOfRunning() async throws {
        // WHY: a rebuild or stop holding the VM replaces its container; a send must wait, not start a run.
        let f = try makeFixture()
        f.vm.botExecutionTargetProvider = { _ in .vm }
        let holder = BotVMRunRegistry.Entry(
            threadID: AgentThreadID(), runID: AgentRunID(), title: "Tarefa A", workspace: f.workspaceCwd, exclusive: true
        )
        XCTAssertNil(BotVMRunRegistry.shared.tryBegin(botID: f.bot.id, entry: holder))
        defer { _ = BotVMRunRegistry.shared.releaseAndNextWaiting(runID: holder.runID) }
        f.vm.setRunActor(.bot(f.bot.id))
        f.vm.prompt = "second task"
        await f.vm.send()
        XCTAssertTrue(f.runner.requests.isEmpty, "no run while another thread holds the VM")
        XCTAssertTrue(f.vm.statusMessage.contains("The VM is busy in Tarefa A"), f.vm.statusMessage)
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
            threadID: AgentThreadID(), runID: AgentRunID(), title: "Tarefa A", workspace: f.workspaceCwd, exclusive: true
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
        XCTAssertEqual(f.vm.statusMessage, "Bot Quinn has been deleted. Use \"Continue without bot\".")
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
        XCTAssertEqual(f.vm.statusMessage, "Bot Quinn has been deleted. Use \"Continue without bot\".")
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

    // MARK: - D12: the VM claim is taken before the start and its result honoured

    private func otherThreadHolder(_ f: Fixture, title: String) -> BotVMRunRegistry.Entry {
        BotVMRunRegistry.Entry(
            threadID: AgentThreadID(), runID: AgentRunID(), title: title, workspace: f.workspaceCwd, exclusive: true
        )
    }

    /// Links and locks the fixture thread to the bot's VM, as a VM-bot thread is stored.
    private func lockThreadToVM(_ f: Fixture) throws {
        try XCTUnwrap(f.vm.botThreadLinker)(f.bot.id, f.thread.id)
        XCTAssertTrue(try f.ctx.threadRepo.setActor(
            id: f.thread.id, actor: .bot(f.bot.id), lockedAt: Date(), executionTarget: .vm
        ))
    }

    func test_vmBotRunHoldsTheVMFromBeforeItsStartUntilItFinishes() async throws {
        // WHY (D12): a claim taken only after the provider started leaves a window
        // where a second thread starts on the same VM; a claim never freed keeps
        // the bot "busy" forever.
        let f = try makeFixture()
        f.vm.botExecutionTargetProvider = { _ in .vm }
        f.vm.botVMPreflight = { _, _, _ in nil }
        let compile = try XCTUnwrap(f.vm.botPromptTransform)
        var claimBeforeStart: BotVMRunRegistry.Entry?
        f.vm.botPromptTransform = { botID, text, threadID, runID in
            claimBeforeStart = BotVMRunRegistry.shared.active(botID: botID)
            return try await compile(botID, text, threadID, runID)
        }
        f.vm.setRunActor(.bot(f.bot.id))
        f.vm.prompt = "vm task"
        await f.vm.send()
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started, f.vm.statusMessage)
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertEqual(claimBeforeStart?.threadID, f.thread.id, "claimed before the provider start")
        XCTAssertEqual(claimBeforeStart?.runID, request.runId)
        XCTAssertEqual(BotVMRunRegistry.shared.active(botID: f.bot.id)?.runID, request.runId)

        XCTAssertTrue(f.runner.finish(runID: request.runId, status: .completed, reply: "done"))
        let freed = await waitUntil { BotVMRunRegistry.shared.active(botID: f.bot.id) == nil }
        XCTAssertTrue(freed, "the run's finish frees the VM")
    }

    func test_vmBotRunsASecondConversationWhileAnotherRunsOnItsVM() async throws {
        // WHY: a bot VM has no parallelism limit. Another conversation running
        // on the VM must not make this send fail with "The VM is busy".
        let f = try makeFixture()
        f.vm.botExecutionTargetProvider = { _ in .vm }
        f.vm.botVMPreflight = { _, _, _ in nil }
        let other = BotVMRunRegistry.Entry(
            threadID: AgentThreadID(), runID: AgentRunID(), title: "Tarefa A", workspace: f.workspaceCwd
        )
        XCTAssertNil(BotVMRunRegistry.shared.tryBegin(botID: f.bot.id, entry: other))
        defer { BotVMRunRegistry.shared.endRun(runID: other.runID) }
        f.vm.setRunActor(.bot(f.bot.id))
        f.vm.prompt = "parallel task"
        await f.vm.send()
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started, f.vm.statusMessage)
        XCTAssertFalse(f.vm.statusMessage.contains("The VM is busy"), f.vm.statusMessage)
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertEqual(BotVMRunRegistry.shared.claim(botID: f.bot.id, threadID: f.thread.id)?.runID, request.runId)
        XCTAssertTrue(f.runner.finish(runID: request.runId, status: .completed, reply: "done"))
        let freed = await waitUntil { BotVMRunRegistry.shared.claim(botID: f.bot.id, threadID: f.thread.id) == nil }
        XCTAssertTrue(freed)
        XCTAssertEqual(BotVMRunRegistry.shared.active(botID: f.bot.id), other, "the other run keeps the VM")
    }

    func test_vmTakenAfterTheBusyCheckQueuesThenStartsWhenTheHolderFinishes() async throws {
        // WHY: the busy check in send() and the start are separated by awaits
        // (VM preflight). A thread that takes the VM in between must win: this
        // send queues with the notice, and starts once the holder is done.
        let f = try makeFixture()
        f.vm.botExecutionTargetProvider = { _ in .vm }
        let holder = otherThreadHolder(f, title: "Tarefa B")
        defer { BotVMRunRegistry.shared.endRun(runID: holder.runID) }
        f.vm.botVMPreflight = { botID, _, _ in
            XCTAssertNil(BotVMRunRegistry.shared.tryBegin(botID: botID, entry: holder))
            return nil
        }
        f.vm.setRunActor(.bot(f.bot.id))
        f.vm.prompt = "racing task"
        await f.vm.send()
        XCTAssertTrue(f.runner.requests.isEmpty, "no overlapping run on the VM")
        XCTAssertTrue(f.vm.statusMessage.contains("The VM is busy in Tarefa B"), f.vm.statusMessage)
        XCTAssertEqual(BotVMRunRegistry.shared.active(botID: f.bot.id)?.runID, holder.runID, "holder keeps the VM")
        XCTAssertEqual(BotVMRunRegistry.shared.waitingThreads(botID: f.bot.id), [f.thread.id])
        let queued = try f.ctx.queuedMessageRepo.list(threadId: f.thread.id)
        XCTAssertEqual(queued.map(\.text), ["racing task"])
        XCTAssertEqual(f.vm.prompt, "", "queued, so the composer is not refilled")

        // Eventual completion: freeing the holder's claim hands the VM to this
        // (never-run) thread and starts its queued message.
        f.router.releaseBotVMRun(holder.runID)
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started, f.vm.statusMessage)
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertEqual(request.runId, AgentRunID(try XCTUnwrap(queued.first).id.value))
        XCTAssertEqual(BotVMRunRegistry.shared.active(botID: f.bot.id)?.threadID, f.thread.id)
        XCTAssertEqual(BotVMRunRegistry.shared.active(botID: f.bot.id)?.runID, request.runId)
        // The row is acknowledged after the provider accepted the start.
        let drained = await waitUntil { (try? f.ctx.queuedMessageRepo.list(threadId: f.thread.id).isEmpty) == true }
        XCTAssertTrue(drained)
        f.runner.finish(runID: request.runId, status: .completed, reply: "done")
    }

    func test_vmClaimIsFreedWhenTheStartFailsBeforeTheProvider() async throws {
        // WHY: a send that fails after claiming (bot brain failed) must not keep
        // the VM, or every other thread of the bot queues behind a run that never ran.
        let f = try makeFixture()
        f.vm.botExecutionTargetProvider = { _ in .vm }
        f.vm.botVMPreflight = { _, _, _ in nil }
        var claimDuringStart: BotVMRunRegistry.Entry?
        f.vm.botPromptTransform = { botID, _, _, _ in
            claimDuringStart = BotVMRunRegistry.shared.active(botID: botID)
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "brain failed"])
        }
        f.vm.setRunActor(.bot(f.bot.id))
        f.vm.prompt = "doomed task"
        await f.vm.send()
        XCTAssertTrue(f.runner.requests.isEmpty)
        XCTAssertTrue(f.vm.statusMessage.contains("brain failed"), f.vm.statusMessage)
        XCTAssertEqual(claimDuringStart?.threadID, f.thread.id, "the VM was claimed for the start")
        XCTAssertNil(BotVMRunRegistry.shared.active(botID: f.bot.id), "an unstarted run frees its claim")
    }

    func test_routerSendToABusyVMBotThreadQueuesWithTheNoticeThenStarts() async throws {
        // WHY: desk, peer and remote sends reach a VM bot thread through the
        // router. Before, they started at once and claimed the VM after the fact
        // (result discarded), so two threads ran on one VM.
        let f = try makeFixture()
        try lockThreadToVM(f)
        SurfaceRegistry.shared.register(f.surface)
        defer { SurfaceRegistry.shared.unregister(f.surface.descriptor.id) }
        let holder = otherThreadHolder(f, title: "Tarefa A")
        XCTAssertNil(BotVMRunRegistry.shared.tryBegin(botID: f.bot.id, entry: holder))
        defer { BotVMRunRegistry.shared.endRun(runID: holder.runID) }

        let result = try await f.router.sendAgentMessage(
            thread: f.thread.id, text: "router task", provider: .codex, model: "fake-model",
            permissionMode: .supervised, reasoningEffort: .medium
        )
        XCTAssertEqual(result.status, .queued)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(f.runner.requests.isEmpty, "no overlapping run on the VM")
        XCTAssertEqual(BotVMRunRegistry.shared.waitingThreads(botID: f.bot.id), [f.thread.id])
        XCTAssertEqual(BotVMRunRegistry.shared.active(botID: f.bot.id)?.runID, holder.runID)
        XCTAssertTrue(f.vm.statusMessage.contains("The VM is busy in Tarefa A"), f.vm.statusMessage)
        let queued = try f.ctx.queuedMessageRepo.list(threadId: f.thread.id)
        XCTAssertEqual(queued.map(\.text), ["router task"])
        XCTAssertEqual(queued.first?.durableState, .queued, "the drain left it queued, not prepared")

        f.router.releaseBotVMRun(holder.runID)
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started, "the hand-off drains the never-run thread")
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertEqual(request.prompt.components(separatedBy: Self.soulMarker).count - 1, 1,
                       "the raw queued text is compiled into the bot brain exactly once, at drain")
        XCTAssertEqual(request.userMessageContent, "router task", "the transcript keeps what the user typed")
        XCTAssertEqual(BotVMRunRegistry.shared.active(botID: f.bot.id)?.runID, request.runId)
        f.runner.finish(runID: request.runId, status: .completed, reply: "done")
        let freed = await waitUntil { BotVMRunRegistry.shared.active(botID: f.bot.id) == nil }
        XCTAssertTrue(freed)
    }

    func test_routerQueuedDispatchThatFailsBeforeTheProviderFreesTheVM() async throws {
        // WHY: the drain claims the VM before preparing the dispatch; a dispatch
        // that never reaches the provider must hand the VM back.
        let f = try makeFixture()
        try lockThreadToVM(f)
        var claimDuringDispatch: BotVMRunRegistry.Entry?
        let botID = f.bot.id
        f.router.botThreadPromptTransform = { _, _, _ in
            claimDuringDispatch = BotVMRunRegistry.shared.active(botID: botID)
            throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "brain failed"])
        }
        _ = try f.ctx.queuedMessageRepo.enqueue(
            threadId: f.thread.id, text: "doomed queued task", attachments: [], interactionMode: .default
        )
        do {
            try await f.router.drainNextQueuedAgentMessage(thread: f.thread.id, botVMHandOff: true)
            XCTFail("the failed dispatch must surface its error")
        } catch {}
        XCTAssertTrue(f.runner.requests.isEmpty)
        XCTAssertEqual(claimDuringDispatch?.threadID, f.thread.id, "the drain claimed the VM for the dispatch")
        XCTAssertNil(BotVMRunRegistry.shared.active(botID: f.bot.id), "an unstarted dispatch frees its claim")
    }

    // MARK: - T3a review fixes

    func test_deskOrPeerSendWithACompiledPromptToABusyVMIsRefusedWithoutQueueingIt() async throws {
        // WHY: desk, peer and hop sends carry the compiled bot brain. Queued, it
        // showed as the user's message (Mac and iOS) and was compiled a second
        // time at drain; the caller also took the queued result for a started run.
        let f = try makeFixture()
        try lockThreadToVM(f)
        let holder = otherThreadHolder(f, title: "Tarefa A")
        XCTAssertNil(BotVMRunRegistry.shared.tryBegin(botID: f.bot.id, entry: holder))
        defer { BotVMRunRegistry.shared.endRun(runID: holder.runID) }

        do {
            _ = try await f.router.sendAgentMessage(
                thread: f.thread.id, text: "COMPILED BRAIN + user words", provider: .codex, model: "fake-model",
                permissionMode: .supervised, reasoningEffort: .medium, requestedRunID: AgentRunID()
            )
            XCTFail("a compiled send to a busy VM must be refused")
        } catch {
            XCTAssertEqual(String(describing: error), "The VM is busy in Tarefa A", "the desk shows the notice")
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(f.runner.requests.isEmpty, "no overlapping run on the VM")
        XCTAssertTrue(try f.ctx.queuedMessageRepo.list(threadId: f.thread.id).isEmpty, "the compiled text is never queued")
        XCTAssertTrue(BotVMRunRegistry.shared.waitingThreads(botID: f.bot.id).isEmpty)
        XCTAssertEqual(BotVMRunRegistry.shared.active(botID: f.bot.id)?.runID, holder.runID, "holder keeps the VM")
    }

    func test_aNeverRunThreadQueuedBehindTheVMStartsOnceAfterARelaunch() async throws {
        // WHY: the wait list lives in memory. After a relaunch, launch recovery
        // must start the never-run thread's first message, or it sits queued
        // until the user sends again and then runs out of order.
        let f = try makeFixture()
        try lockThreadToVM(f)
        let holder = otherThreadHolder(f, title: "Tarefa A")
        XCTAssertNil(BotVMRunRegistry.shared.tryBegin(botID: f.bot.id, entry: holder))
        let result = try await f.router.sendAgentMessage(
            thread: f.thread.id, text: "first task", provider: .codex, model: "fake-model",
            permissionMode: .supervised, reasoningEffort: .medium
        )
        XCTAssertEqual(result.status, .queued)
        // Simulated relaunch: the holder is gone and so is the in-memory wait.
        XCTAssertEqual(BotVMRunRegistry.shared.releaseAndNextWaiting(runID: holder.runID), f.thread.id)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(f.runner.requests.isEmpty)

        await f.router.reconcileQueuedAgentMessagesOnLaunch()
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started, "launch recovery starts the never-run thread")
        await f.router.reconcileQueuedAgentMessagesOnLaunch()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(f.runner.requests.count, 1, "exactly once")
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertEqual(request.userMessageContent, "first task")
        let drained = await waitUntil { (try? f.ctx.queuedMessageRepo.list(threadId: f.thread.id).isEmpty) == true }
        XCTAssertTrue(drained)
        f.runner.finish(runID: request.runId, status: .completed, reply: "done")
        let freed = await waitUntil { BotVMRunRegistry.shared.active(botID: f.bot.id) == nil }
        XCTAssertTrue(freed)
    }

    func test_switchingThreadsWhileTheVMIsTakenQueuesOnTheSentThreadOnly() async throws {
        // WHY (destination safety): the VM refusal arrives after awaits. The
        // message belongs to the thread it was sent from; the thread the user
        // switched to must not get it, lose its draft, or be locked to the bot.
        let f = try makeFixture()
        f.vm.botExecutionTargetProvider = { _ in .vm }
        let other = try f.router.createAgentThread(
            workspace: f.vm.workspaceID, title: "Other thread", provider: .codex,
            model: "fake-model", permissionMode: .supervised, reasoningEffort: .medium
        )
        let holder = otherThreadHolder(f, title: "Tarefa B")
        defer { BotVMRunRegistry.shared.endRun(runID: holder.runID) }
        let vm = f.vm
        vm.botVMPreflight = { botID, _, _ in
            XCTAssertNil(BotVMRunRegistry.shared.tryBegin(botID: botID, entry: holder))
            vm.selectThread(other.id)
            vm.prompt = "draft on the other thread"
            return nil
        }
        vm.setRunActor(.bot(f.bot.id))
        vm.prompt = "racing task"
        await vm.send()

        XCTAssertTrue(f.runner.requests.isEmpty)
        XCTAssertEqual(try f.ctx.queuedMessageRepo.list(threadId: f.thread.id).map(\.text), ["racing task"])
        XCTAssertTrue(try f.ctx.queuedMessageRepo.list(threadId: other.id).isEmpty, "nothing queued on the other thread")
        let storedOther = try XCTUnwrap(try f.ctx.threadRepo.get(id: other.id))
        XCTAssertNil(storedOther.actorLockedAt, "the other thread is not locked to the bot")
        XCTAssertEqual(vm.prompt, "draft on the other thread", "the other thread's draft is untouched")
        XCTAssertEqual(BotVMRunRegistry.shared.waitingThreads(botID: f.bot.id), [f.thread.id])
        XCTAssertFalse(vm.statusMessage.contains("The VM is busy"), "the notice is not painted on the other thread")
        let storedSent = try XCTUnwrap(try f.ctx.threadRepo.get(id: f.thread.id))
        XCTAssertEqual(storedSent.actor, .bot(f.bot.id), "the sent thread is the one locked to the bot")
    }

    func test_aHandOffTheNextThreadDoesNotTakePassesTheVMOnAndQueueEventsSayWhy() async throws {
        // WHY: a hand-off to a waiter that does not start (its queue emptied)
        // left the VM free and every later waiter stranded. iOS must see why a
        // queued message is not starting.
        let f = try makeFixture()
        try lockThreadToVM(f)
        let holder = otherThreadHolder(f, title: "Tarefa A")
        XCTAssertNil(BotVMRunRegistry.shared.tryBegin(botID: f.bot.id, entry: holder))
        defer { BotVMRunRegistry.shared.endRun(runID: holder.runID) }
        let threadID = f.thread.id.value.uuidString
        let payloads = LockedPayloads()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "agent.message.queued" || event.kind == "agent.message.queue.updated",
                  let object = event.payload.objectValue,
                  object["thread_id"]?.stringValue == threadID else { return }
            payloads.append(object["waiting_for_bot_vm"]?.objectValue)
        }
        defer { EventBus.shared.unsubscribe(subscription) }

        BotVMRunRegistry.shared.addWaiting(botID: f.bot.id, threadID: AgentThreadID()) // gone thread, first in line
        _ = try await f.router.sendAgentMessage(
            thread: f.thread.id, text: "router task", provider: .codex, model: "fake-model",
            permissionMode: .supervised, reasoningEffort: .medium
        )
        let reported = await waitUntil { payloads.values.contains { $0 != nil } }
        XCTAssertTrue(reported, "the queued row carries the wait reason")
        let wait = try XCTUnwrap(payloads.values.compactMap { $0 }.first)
        XCTAssertEqual(wait["bot_id"]?.stringValue, f.bot.id.value.uuidString)
        XCTAssertEqual(wait["holder_thread_id"]?.stringValue, holder.threadID.value.uuidString)
        XCTAssertEqual(wait["holder_title"]?.stringValue, "Tarefa A")
        XCTAssertEqual(wait["notice"]?.stringValue, "The VM is busy in Tarefa A")

        f.router.releaseBotVMRun(holder.runID)
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started, "the VM passes past the waiter that did not take it")
        let request = try XCTUnwrap(f.runner.requests.first)
        f.runner.finish(runID: request.runId, status: .completed, reply: "done")
        let freed = await waitUntil { BotVMRunRegistry.shared.active(botID: f.bot.id) == nil }
        XCTAssertTrue(freed)
    }

    func test_autoContinuationClaimIsRefusedWhileAnotherThreadHoldsTheVM() throws {
        // WHY (D12): the coordinator's auto-nudge starts a run after the VM was
        // handed on; it must not overlap the other thread's run.
        let f = try makeFixture()
        try lockThreadToVM(f)
        let holder = otherThreadHolder(f, title: "Tarefa A")
        XCTAssertNil(BotVMRunRegistry.shared.tryBegin(botID: f.bot.id, entry: holder))
        XCTAssertFalse(f.router.claimBotVMForAutoContinuation(thread: f.thread.id, runID: AgentRunID()))
        BotVMRunRegistry.shared.endRun(runID: holder.runID)
        let runID = AgentRunID()
        XCTAssertTrue(f.router.claimBotVMForAutoContinuation(thread: f.thread.id, runID: runID))
        XCTAssertEqual(BotVMRunRegistry.shared.active(botID: f.bot.id)?.runID, runID)
        f.router.releaseBotVMRun(runID)
        XCTAssertNil(BotVMRunRegistry.shared.active(botID: f.bot.id))
        XCTAssertTrue(f.router.claimBotVMForAutoContinuation(thread: AgentThreadID(), runID: AgentRunID()),
                      "a thread not on a bot VM is not gated")
    }
}

private final class LockedPayloads: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String: JSONValue]?] = []
    func append(_ value: [String: JSONValue]?) { lock.withLock { stored.append(value) } }
    var values: [[String: JSONValue]?] { lock.withLock { stored } }
}
