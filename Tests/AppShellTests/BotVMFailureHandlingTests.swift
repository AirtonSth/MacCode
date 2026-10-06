import XCTest
import AgentRuntime
import CoreModel
@testable import AppShell
@testable import Persistence
@testable import Surfaces

/// WHY: a bot VM failure or a Mac-execution request must never move a thread to the Mac without the user's click.
@MainActor
final class BotVMFailureHandlingTests: XCTestCase {
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
        let botsVM: BotsViewModel
        let surface: AgentAppSurface
        let runner: ControlledBotHandoffRunner
        let bot: BotDefinition
        let thread: AgentThread
        let workspaceDir: URL
        @MainActor var vm: AgentAppViewModel { surface.viewModel }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2BotVMFail-\(UUID().uuidString)", isDirectory: true)
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
        let bot = try botsVM.create(name: "Vera", title: "Scout", soul: "soul")
        let workspace = try router.createWorkspace(name: "vm-ws", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "VM thread",
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
        surface.viewModel.botExecutionTargetProvider = { _ in .vm }
        surface.viewModel.providerSnapshots = snapshots
        surface.viewModel.providerLaunchConfig = { _, _ in ("/usr/bin/true", [:]) }
        surface.viewModel.selectThread(thread.id)
        return Fixture(
            ctx: ctx, router: router, botsVM: botsVM, surface: surface, runner: runner,
            bot: bot, thread: thread, workspaceDir: workspaceDir
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

    private func lockOnVM(_ f: Fixture) throws {
        XCTAssertTrue(try f.ctx.threadRepo.setActor(
            id: f.thread.id, actor: .bot(f.bot.id), lockedAt: Date(), executionTarget: .vm
        ))
        f.vm.selectThread(f.thread.id)
    }

    private func requestMacExecution(_ f: Fixture) async {
        NotificationCenter.default.post(
            name: .botMacExecutionRequested, object: nil,
            userInfo: [
                BotHostNotificationKey.botID: f.bot.id,
                BotHostNotificationKey.threadID: f.thread.id,
                BotHostNotificationKey.reason: "preciso do Xcode",
            ]
        )
        _ = await waitUntil { f.router.pendingMacExecution[f.thread.id] != nil }
    }

    func test_approveMacExecutionSwitchesTargetKeepsActorAndSendsOneFollowUp() async throws {
        let f = try makeFixture()
        try lockOnVM(f)
        let before = try XCTUnwrap(try f.ctx.threadRepo.get(id: f.thread.id))
        await requestMacExecution(f)
        XCTAssertEqual(f.router.pendingMacExecution[f.thread.id], "preciso do Xcode")
        XCTAssertEqual(try f.ctx.threadRepo.get(id: f.thread.id)?.executionTarget, .vm, "request alone never switches")

        await f.router.resolveMacExecution(thread: f.thread.id, approve: true)
        let after = try XCTUnwrap(try f.ctx.threadRepo.get(id: f.thread.id))
        XCTAssertEqual(after.executionTarget, .mac)
        XCTAssertEqual(after.actor, before.actor)
        XCTAssertEqual(after.actorLockedAt, before.actorLockedAt)
        XCTAssertNil(f.router.pendingMacExecution[f.thread.id])
        let sent = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertEqual(f.runner.requests.first?.userMessageContent, "Execução no Mac aprovada pelo usuário. Continue.")
    }

    func test_declineMacExecutionKeepsVMAndSendsDeclineFollowUp() async throws {
        let f = try makeFixture()
        try lockOnVM(f)
        await requestMacExecution(f)
        await f.router.resolveMacExecution(thread: f.thread.id, approve: false)
        XCTAssertEqual(try f.ctx.threadRepo.get(id: f.thread.id)?.executionTarget, .vm)
        let sent = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertEqual(
            f.runner.requests.first?.userMessageContent,
            "O usuário recusou a execução no Mac. Continue na VM ou pare e explique."
        )
        await f.router.resolveMacExecution(thread: f.thread.id, approve: true)
        XCTAssertEqual(try f.ctx.threadRepo.get(id: f.thread.id)?.executionTarget, .vm, "no pending request, no switch")
    }

    func test_preflightFailureBlocksSendWithoutFallbackThenRunOnMacSwitches() async throws {
        let f = try makeFixture()
        f.vm.botVMPreflight = { _, _ in "docker parado" }
        f.vm.setRunActor(.bot(f.bot.id))
        f.vm.prompt = "oi"
        await f.vm.send()
        XCTAssertTrue(f.vm.statusMessage.contains("docker parado"), f.vm.statusMessage)
        XCTAssertEqual(f.vm.vmUnavailableBotID, f.bot.id)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(f.runner.requests.isEmpty, "no request while the VM is down")
        let blocked = try XCTUnwrap(try f.ctx.threadRepo.get(id: f.thread.id))
        XCTAssertNil(blocked.executionTarget, "no silent fallback to the Mac")
        XCTAssertNil(blocked.actorLockedAt)

        f.vm.runSelectedThreadOnMac()
        let moved = try XCTUnwrap(try f.ctx.threadRepo.get(id: f.thread.id))
        XCTAssertEqual(moved.executionTarget, .mac)
        XCTAssertEqual(moved.actor, .bot(f.bot.id))
        XCTAssertNil(f.vm.vmUnavailableBotID)
    }

    func test_removedWorkspaceRefusesBotSend() async throws {
        let f = try makeFixture()
        try FileManager.default.removeItem(at: f.workspaceDir)
        f.vm.setRunActor(.bot(f.bot.id))
        f.vm.prompt = "oi"
        await f.vm.send()
        XCTAssertEqual(f.vm.statusMessage, "Workspace removido")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(f.runner.requests.isEmpty)
    }

    func test_ensureWorkspaceMountedDropsStoredBindsWhoseDirectoryIsGone() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-prune-\(UUID().uuidString)", isDirectory: true)
        let live = support.appendingPathComponent("live", isDirectory: true)
        let fresh = support.appendingPathComponent("fresh", isDirectory: true)
        let gone = support.appendingPathComponent("gone", isDirectory: true)
        for dir in [live, fresh] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let botID = BotID()
        let url = BotComputerGuestSpec.workspacesURL(appSupport: support, botID: botID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode([live.path, gone.path]).write(to: url)
        let service = BotComputerGuestService(
            appSupport: support,
            docker: BotComputerDockerCLI(run: { _ in throw BotComputerGuestError.dockerUnavailable }),
            observeAttempts: 1,
            observeDelay: 0
        )
        try? service.ensureWorkspaceMounted(
            botID: botID, workspace: fresh.path, registered: [live.path, fresh.path, gone.path]
        )
        let saved = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
        XCTAssertEqual(saved, [fresh.path, live.path].sorted())
        XCTAssertFalse(saved.contains(gone.path), "a removed workspace must not break container create")
    }

    private final class RecordingDockerRun: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        var calls: [[String]] { lock.withLock { recorded } }
        func run(_ args: [String]) throws -> Data {
            lock.withLock { recorded.append(args) }
            switch args.first {
            case "inspect":
                if args.contains(where: { $0.contains("Config.Labels\"") }) {
                    return Data(BotComputerGuestSpec.recipeRevision.utf8)
                }
                if args.contains("{{.Id}}") { return Data("img".utf8) }
                return Data("true img 49152  {}".utf8)
            case "create": return Data("cid".utf8)
            case "exec": return BotComputerGuestObserve.pngSignature + Data(repeating: 1, count: 16)
            default: return Data()
            }
        }
    }

    /// WHY: a thread's workspace must be bind-mounted in the bot VM before the send is allowed, or the bot edits nothing.
    func test_preflightMountsRunWorkspaceBeforeAllowingSend() async throws {
        let f = try makeFixture()
        let docker = RecordingDockerRun()
        f.router.botVMDocker = BotComputerDockerCLI(run: { try docker.run($0) })
        let failure = await f.router.botVMPreflight(f.bot.id, workspace: f.workspaceDir.path)
        XCTAssertNil(failure)
        let create = try XCTUnwrap(docker.calls.first { $0.first == "create" })
        let ws = f.workspaceDir.path
        XCTAssertTrue(create.contains("\(ws):\(ws)"), "missing bind in \(create)")
    }

    /// WHY: the guest distill build is ~224 MB; a bot VM preflight with Docker up
    /// must start its download in the background for the daemon's architecture,
    /// so the first in-guest run (or the first after a host update) does not wait for it.
    func test_preflightPrefetchesGuestDistillForTheDockerArchitecture() async throws {
        let f = try makeFixture()
        let docker = RecordingDockerRun()
        f.router.botVMDocker = BotComputerDockerCLI(run: { args in
            args.first == "info" ? Data(" OSType: linux\n Architecture: aarch64\n".utf8) : try docker.run(args)
        })
        try f.ctx.settingsRepo.set("cli.distill.path", "/usr/bin/true")
        let requested = LockedURLs()
        f.ctx.distillGuestBinaries = DistillGuestBinaryProvisioner(
            guestToolsRoot: f.workspaceDir.appendingPathComponent("guest-tools"),
            fetch: { url, _ in
                requested.append(url)
                throw DistillGuestBinaryError.downloadFailed(url: url.absoluteString, status: 404)
            },
            versionProbe: { _ in "distill 2.0.31 (test)" }
        )
        let failure = await f.router.botVMPreflight(f.bot.id, workspace: f.workspaceDir.path)
        XCTAssertNil(failure, "a prefetch must never block or fail the send")
        let deadline = Date().addingTimeInterval(5)
        while requested.urls.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(
            requested.urls.first?.absoluteString,
            "https://github.com/samuelfaj/distill/releases/download/v2.0.31/SHA256SUMS"
        )
    }

    private final class LockedURLs: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URL] = []
        var urls: [URL] { lock.withLock { stored } }
        func append(_ url: URL) { lock.withLock { stored.append(url) } }
    }

    /// WHY: an unregistered path must block the send instead of mounting arbitrary host directories.
    func test_preflightRefusesUnregisteredWorkspace() async throws {
        let f = try makeFixture()
        let docker = RecordingDockerRun()
        f.router.botVMDocker = BotComputerDockerCLI(run: { try docker.run($0) })
        let failure = await f.router.botVMPreflight(f.bot.id, workspace: "/tmp/rc-not-registered/x")
        XCTAssertNotNil(failure)
        XCTAssertFalse(docker.calls.contains { $0.first == "create" })
    }

    func test_deletingBotClosesManualRequestsAndForgetsControl() async throws {
        let f = try makeFixture()
        let request = ManualActionRequest(botID: f.bot.id, threadID: f.thread.id, kind: .login, reason: "Entre")
        try f.router.manualActionStore.upsert(request)
        BotComputerControl.shared.requestHelp(request)
        BotComputerControl.shared.take(f.bot.id)
        XCTAssertNotNil(f.router.manualActionStore.open(threadID: f.thread.id))
        f.botsVM.delete(id: f.bot.id, navigate: false)
        XCTAssertNil(f.router.manualActionStore.open(threadID: f.thread.id), "deleted bot leaves no open request")
        XCTAssertNil(BotComputerControl.shared.openRequest(f.bot.id))
        XCTAssertFalse(BotComputerControl.shared.isControlledByUser(f.bot.id))
    }

    private final class TopDocker: BotComputerDockerClienting, @unchecked Sendable {
        var tops: [String: String] = [:]
        var execs: [(name: String, command: [String], user: String?)] = []
        func info() throws -> String { "" }
        func imageExists(tag: String) throws -> Bool { true }
        func imageLabel(tag: String, key: String) throws -> String { "" }
        func imageID(tag: String) throws -> String { "" }
        func build(context: URL, tag: String) throws {}
        func create(options: BotComputerContainerCreateOptions) throws -> String { "" }
        func start(name: String) throws {}
        func stop(name: String) throws {}
        func inspect(name: String) throws -> BotComputerContainerInspect { throw BotComputerGuestError.notReady }
        func exec(name: String, command: [String], user: String?, detach: Bool, workdir: String?, environment: [String: String]) throws -> Data {
            execs.append((name, command, user))
            return Data()
        }
        func rename(from: String, to: String) throws {}
        func ensureNetwork(name: String) throws {}
        func remove(name: String) throws {}
        func removeMatching(namePrefix: String) throws {}
        func top(name: String) throws -> String { tops[name] ?? "" }
    }

    /// WHY: a restart must not leave an unowned `bash -lc` driving a bot VM, and idle VMs must stay untouched.
    func test_orphanScan_reapsOnlyContainersWithBashLc() {
        let docker = TopDocker()
        docker.tops["busy"] = "PID CMD\n42 bash -lc sleep 999"
        docker.tops["idle"] = "PID CMD\n1 supervisord"
        let found = BotVMOrphanScan.reap(docker: docker, names: ["busy", "idle"])
        XCTAssertEqual(found, ["busy"])
        XCTAssertEqual(docker.execs.count, 1)
        XCTAssertEqual(docker.execs.first?.name, "busy")
        XCTAssertEqual(docker.execs.first?.command, ["pkill", "-f", "bash -lc"])
        XCTAssertEqual(docker.execs.first?.user, "root")
    }
}
