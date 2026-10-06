import XCTest
import AgentRuntime
import CoreModel
@testable import AppShell
@testable import Persistence
@testable import Surfaces

/// WHY (plan A S9): a new Bots Desk conversation of a Docker-desktop bot on
/// Distill must run inside the bot's Linux guest from its first send, while
/// every desk thread that already ran (D5) and every other provider keep
/// running where they ran. A desk thread on the VM never falls back to the
/// Mac: a VM that is down shows the D11 banner and starts no run.
@MainActor
final class BotDeskGuestThreadTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    private struct Fixture {
        let ctx: AppContext
        let router: AppCommandRouter
        let vm: BotsViewModel
        let distill: ControlledBotHandoffRunner
        let claude: ControlledBotHandoffRunner
        let snapshots: [AgentProviderSnapshot]
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2BotDeskGuest-\(UUID().uuidString)", isDirectory: true)
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        // Fake runners stand in for the providers: the guest launch itself is
        // BotGuestRunResolver's (covered by its own tests).
        let distill = ControlledBotHandoffRunner(provider: .distill)
        let claude = ControlledBotHandoffRunner(provider: .claude)
        ctx.coordinator.replaceProvider(.distill, runner: distill)
        ctx.coordinator.replaceProvider(.claude, runner: claude)
        let snapshots = [
            AgentProviderSnapshotFactory.snapshot(
                provider: .distill,
                models: [AgentModelDescriptor(id: "main-a", label: "Main A", provider: .distill)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "distill",
                capabilitiesOverride: AgentProviderCapabilities(supportsDistillMainEffortAuto: true)
            ),
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "claude"
            ),
        ]
        router.rememberProviderSnapshotsForSend(snapshots)
        router.preflightListedProviderSnapshotsForTesting = false
        let vm = BotsViewModel(context: ctx, router: router)
        router.botsViewModel = vm
        vm.replaceProvidersForTests(snapshots)
        let suiteName = "rc2-desk-guest-" + UUID().uuidString
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { suite.removePersistentDomain(forName: suiteName) }
        vm.lastModelStore = AgentLastModelStore(defaults: suite)
        vm.dockerGuestReadyOverrideForTesting = true
        return Fixture(ctx: ctx, router: router, vm: vm, distill: distill, claude: claude, snapshots: snapshots)
    }

    private func makeBot(_ f: Fixture, docker: Bool) throws -> BotDefinition {
        let created = try f.vm.create(name: "Piper", title: "Scout")
        guard docker else { return created }
        f.vm.openStudio(created)
        f.vm.studioDraft.desktopKind = .dockerDesktop
        return try f.vm.saveStudio()
    }

    /// First send on a new desk conversation; returns its linked thread.
    private func firstSend(
        _ f: Fixture, bot: BotDefinition, provider: AgentProvider, text: String = "first words"
    ) async throws -> AgentThread {
        f.vm.openDesk(bot)
        XCTAssertTrue(f.vm.createDeskThread())
        f.vm.setDeskProvider(provider)
        XCTAssertTrue(f.vm.send(text), f.vm.errorMessage ?? "")
        let runner = provider == .distill ? f.distill : f.claude
        let started = await waitUntil { runner.requests.contains { $0.prompt.contains(text) } }
        XCTAssertTrue(started, f.vm.errorMessage ?? "no run")
        let threadID = try XCTUnwrap(f.vm.selectedConversation?.linkedAgentThreadID)
        return try XCTUnwrap(try f.ctx.threadRepo.get(id: threadID))
    }

    private func finishAll(_ f: Fixture) async {
        for runner in [f.distill, f.claude] {
            for request in runner.requests {
                runner.finish(runID: request.runId, status: .completed, reply: "ok")
            }
        }
        _ = await waitUntil { !f.vm.deskSendInFlight }
        _ = await waitUntil {
            ((try? f.ctx.threadRepo.list()) ?? []).allSatisfy {
                f.ctx.coordinator.activeRunId(threadId: $0.id) == nil
            }
        }
        // The fake runner's one-shot adapter keeps every finished session listed
        // as live, which would queue each later send; real adapters end it.
        f.ctx.coordinator.replaceProvider(.distill, runner: f.distill)
        f.ctx.coordinator.replaceProvider(.claude, runner: f.claude)
    }

    private func waitUntil(timeout: TimeInterval = 6, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    func test_aNewDistillDeskThreadOfADockerBotIsLockedToTheGuestBeforeItsFirstRun() async throws {
        let f = try makeFixture()
        let bot = try makeBot(f, docker: true)
        let thread = try await firstSend(f, bot: bot, provider: .distill)
        XCTAssertEqual(thread.actor, .bot(bot.id))
        XCTAssertNotNil(thread.actorLockedAt)
        XCTAssertEqual(thread.executionTarget, .vm)
        XCTAssertEqual(
            try f.ctx.threadRepo.guestPlacement(of: thread.id)?.runsInGuest, true,
            "the marker is what routes the run into the guest; without it run 1 would run on the Mac"
        )
        let request = try XCTUnwrap(f.distill.requests.first)
        XCTAssertTrue(
            request.prompt.hasSuffix(BotStandingInstructions.vmThreadRules),
            "the agent must be told it runs in a Linux VM"
        )
        await finishAll(f)
    }

    func test_otherProvidersAndOtherDesktopsKeepAnUnlockedMacDeskThread() async throws {
        // Only Distill runs in the guest (B4): a marked Claude thread would fail every send.
        let f = try makeFixture()
        let docker = try makeBot(f, docker: true)
        let claude = try await firstSend(f, bot: docker, provider: .claude)
        XCTAssertNil(claude.actorLockedAt)
        XCTAssertNil(claude.executionTarget)
        XCTAssertNil(try f.ctx.threadRepo.guestPlacement(of: claude.id)?.guestRuntime)
        XCTAssertFalse(try XCTUnwrap(f.claude.requests.first).prompt.contains(BotStandingInstructions.vmThreadRules))
        await finishAll(f)

        let plain = try makeBot(f, docker: false)
        let distill = try await firstSend(f, bot: plain, provider: .distill, text: "plain words")
        XCTAssertNil(distill.executionTarget)
        XCTAssertNil(try f.ctx.threadRepo.guestPlacement(of: distill.id)?.guestRuntime)
        await finishAll(f)
    }

    func test_aDeskThreadThatAlreadyRanOnTheMacKeepsRunningThere() async throws {
        // D5: a desk thread from before plan A (unlocked, with a Mac Distill
        // session) keeps that session; the guest could not load it.
        let f = try makeFixture()
        let bot = try makeBot(f, docker: true)
        let thread = try await firstSend(f, bot: bot, provider: .distill)
        await finishAll(f)
        // What such a thread looks like: never locked, its session on the Mac.
        XCTAssertTrue(try f.ctx.threadRepo.setActor(id: thread.id, actor: .none, lockedAt: nil, executionTarget: nil))
        try f.ctx.threadRepo.setGuestRuntime(id: thread.id, nil)
        try f.ctx.threadRepo.updateProviderThreadId(id: thread.id, providerThreadId: "mac-session-1")

        XCTAssertTrue(f.vm.send("second words"), f.vm.errorMessage ?? "")
        let started = await waitUntil { f.distill.requests.contains { $0.prompt.contains("second words") } }
        XCTAssertTrue(started, f.vm.errorMessage ?? "")
        XCTAssertEqual(f.vm.selectedConversation?.linkedAgentThreadID, thread.id, "the same thread is reused")
        let stored = try XCTUnwrap(try f.ctx.threadRepo.get(id: thread.id))
        XCTAssertNil(stored.actorLockedAt)
        XCTAssertNil(stored.executionTarget)
        XCTAssertNil(try f.ctx.threadRepo.guestPlacement(of: thread.id)?.guestRuntime)
        let request = try XCTUnwrap(f.distill.requests.last)
        XCTAssertEqual(request.providerThreadId, "mac-session-1", "the Mac session keeps resuming")
        XCTAssertFalse(request.prompt.contains(BotStandingInstructions.vmThreadRules))
        await finishAll(f)
    }

    func test_embeddedDeskSendOnAGuestThreadIsGatedOnTheVMWithoutAWorkspace() async throws {
        // B5 + D11: the desk gate must not try to mount BotHome (it always failed),
        // must start no run while the VM is down (no Mac fallback), and must let the
        // send through once the VM is up.
        let f = try makeFixture()
        let bot = try makeBot(f, docker: true)
        let thread = try await firstSend(f, bot: bot, provider: .distill)
        await finishAll(f)
        // Reopen the conversation so its embedded Agent App mounts on the idle
        // thread (the one mounted during run 1 tracks that run's own chrome).
        let conversationID = try XCTUnwrap(f.vm.selectedConversation?.id)
        XCTAssertTrue(f.vm.createDeskThread())
        f.vm.selectDeskThread(conversationID)
        let agent = try XCTUnwrap(f.vm.deskAgentVM, "the linked desk conversation mounts the embedded Agent App")
        XCTAssertEqual(agent.selectedThreadId, thread.id)
        agent.providerSnapshots = f.snapshots
        agent.providerLaunchConfig = { _, _ in ("/usr/bin/true", [:]) }
        let runsBefore = f.distill.requests.count

        f.vm.dockerGuestReadyOverrideForTesting = false
        agent.prompt = "while down"
        await agent.send()
        XCTAssertEqual(agent.vmUnavailableBotID, bot.id, agent.statusMessage)
        XCTAssertTrue(agent.statusMessage.hasPrefix("VM indisponível"), agent.statusMessage)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(f.distill.requests.count, runsBefore, "no run while the VM is down")
        XCTAssertEqual(try f.ctx.threadRepo.get(id: thread.id)?.executionTarget, .vm, "no silent fallback")

        var workspaces: [String?] = []
        let gate = agent.botVMPreflight
        agent.botVMPreflight = { botID, workspace in
            workspaces.append(workspace)
            return await gate?(botID, workspace)
        }
        f.vm.dockerGuestReadyOverrideForTesting = true
        agent.prompt = "while up"
        await agent.send()
        let started = await waitUntil { f.distill.requests.contains { $0.prompt.contains("while up") } }
        XCTAssertTrue(started, agent.statusMessage)
        XCTAssertEqual(workspaces, [nil], "a desk thread has no workspace to mount")
        XCTAssertNil(agent.vmUnavailableBotID)
        XCTAssertTrue(try XCTUnwrap(f.distill.requests.last).prompt.contains(BotStandingInstructions.vmThreadRules))
        await finishAll(f)
    }

    func test_deskGateAsksDockerInsteadOfTrustingACachedRunningDesktop() async throws {
        // WHY (D11): the cached "desktop running" flag only knows the app's own
        // launches and stops. A container stopped outside the app (`docker stop`,
        // OrbStack quit, a crash) still reads running; trusting it let the send
        // through to fail inside the guest resolver, with no banner and no way
        // to recover. The gate must ask Docker, and fail fast without
        // provisioning inline (AGENTS.md loading rules).
        let f = try makeFixture()
        let bot = try makeBot(f, docker: true)
        let thread = try await firstSend(f, bot: bot, provider: .distill)
        await finishAll(f)
        let conversationID = try XCTUnwrap(f.vm.selectedConversation?.id)
        XCTAssertTrue(f.vm.createDeskThread())
        f.vm.selectDeskThread(conversationID)
        let agent = try XCTUnwrap(f.vm.deskAgentVM)
        XCTAssertEqual(agent.selectedThreadId, thread.id)
        agent.providerSnapshots = f.snapshots
        agent.providerLaunchConfig = { _, _ in ("/usr/bin/true", [:]) }
        let runsBefore = f.distill.requests.count

        // The real machine state: the app once started this desktop; Docker now
        // reports the container stopped.
        let docker = ScriptedDocker(containerRunning: false)
        f.vm.computerGuestService = BotComputerGuestService(
            appSupport: f.ctx.appSupportDirectory,
            docker: BotComputerDockerCLI(run: { try docker.run($0) })
        )
        f.vm.dockerGuestReadyOverrideForTesting = nil
        f.vm.desktopKindOverrideForTesting = .dockerDesktop
        f.vm.guestRunningByBot[bot.id.value] = true

        agent.prompt = "after docker stop"
        await agent.send()
        XCTAssertEqual(agent.vmUnavailableBotID, bot.id, agent.statusMessage)
        XCTAssertTrue(agent.statusMessage.hasPrefix("VM indisponível"), agent.statusMessage)
        XCTAssertTrue(docker.calls.contains { $0.first == "inspect" }, "the gate must ask Docker: \(docker.calls)")
        XCTAssertFalse(f.vm.isGuestRunning(bot.id), "the desk stops claiming a desktop Docker says is down")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(f.distill.requests.count, runsBefore, "no run while the container is down")

        // The background start the gate kicked fails too (Docker refuses it).
        let settled = await waitUntil {
            if case .failed = f.vm.guestLaunchState(for: bot.id) { return true }
            return false
        }
        XCTAssertTrue(settled)
        // Positive control: Docker reports it running, the same send goes through.
        docker.containerRunning = true
        f.vm.guestRunningByBot[bot.id.value] = true
        agent.prompt = "container up"
        await agent.send()
        let started = await waitUntil { f.distill.requests.contains { $0.prompt.contains("container up") } }
        XCTAssertTrue(started, agent.statusMessage)
        XCTAssertNil(agent.vmUnavailableBotID)
        await finishAll(f)
    }

    func test_aDeskConversationRunAsAnotherMacUserIsNotLockedToTheGuest() async throws {
        // WHY (M9): the guest only ever gets the app user's own accounts, and the
        // guest resolver refuses a run meant for another macOS user. Locking such a
        // conversation to the guest would make every send fail with no way out,
        // so it stays an unlocked Mac thread run as that user.
        let f = try makeFixture()
        let bot = try makeBot(f, docker: true)
        f.vm.openDesk(bot)
        XCTAssertTrue(f.vm.createDeskThread())
        f.vm.setDeskProvider(.distill)
        var other = AgentRunAsUser.current()
        other.uid = getuid() + 1
        other.generatedUID = "other-\(other.uid)"
        other.shortName = "someoneelse"
        f.vm.setDeskRunAsUser(other)
        XCTAssertTrue(f.vm.send("as another user"), f.vm.errorMessage ?? "")
        let threadID = try XCTUnwrap(f.vm.selectedConversation?.linkedAgentThreadID)
        let thread = try XCTUnwrap(try f.ctx.threadRepo.get(id: threadID))
        XCTAssertEqual(thread.runAsUser?.uid, other.uid)
        XCTAssertNil(thread.actorLockedAt)
        XCTAssertNil(thread.executionTarget)
        XCTAssertNil(try f.ctx.threadRepo.guestPlacement(of: threadID)?.guestRuntime)
        let started = await waitUntil { f.distill.requests.contains { $0.prompt.contains("as another user") } }
        XCTAssertTrue(started, f.vm.errorMessage ?? "no run")
        await finishAll(f)
    }

    /// `docker` stand-in for the desk gate: `inspect` reports the bot container's
    /// state; every other call fails as when the daemon cannot start it.
    private final class ScriptedDocker: @unchecked Sendable {
        private let lock = NSLock()
        private var running: Bool
        private var recorded: [[String]] = []
        init(containerRunning: Bool) { running = containerRunning }
        var containerRunning: Bool {
            get { lock.withLock { running } }
            set { lock.withLock { running = newValue } }
        }
        var calls: [[String]] { lock.withLock { recorded } }
        func run(_ args: [String]) throws -> Data {
            let running = lock.withLock { () -> Bool in
                recorded.append(args)
                return self.running
            }
            guard args.first == "inspect" else { throw BotComputerGuestError.dockerUnavailable }
            return Data("\(running) sha256:img 6080 bridge, {}".utf8)
        }
    }

    func test_vmRulesFollowTheBrainButNeverARawDistillSlashCommand() {
        let rules = BotStandingInstructions.vmThreadRules
        XCTAssertEqual(
            BotsViewModel.supervisedRunPrompt(userText: "hi", compiledPayload: "BRAIN", provider: .distill, executionTarget: .vm),
            "BRAIN\n\n" + rules
        )
        XCTAssertEqual(
            BotsViewModel.supervisedRunPrompt(userText: "/goal x", compiledPayload: "BRAIN", provider: .distill, executionTarget: .vm),
            "/goal x", "the rules would become the slash command's arguments"
        )
        XCTAssertEqual(
            BotsViewModel.supervisedRunPrompt(userText: "hi", compiledPayload: "BRAIN", provider: .distill, executionTarget: .mac),
            "BRAIN"
        )
    }
}
