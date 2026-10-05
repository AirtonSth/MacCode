import XCTest
import AgentRuntime
import CoreModel
@testable import AppShell
@testable import Persistence
@testable import Surfaces

/// WHY: a bot that pauses for a manual action must survive restarts as a card, and the user's
/// answer must reach the bot exactly once no matter how many surfaces or taps race.
@MainActor
final class ManualActionCardTests: XCTestCase {
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
        let workspaceCwd: String
        @MainActor var vm: AgentAppViewModel { surface.viewModel }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2ManualAction-\(UUID().uuidString)", isDirectory: true)
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
        let bot = try botsVM.create(name: "Quinn", title: "Scout", soul: "soul")
        let workspace = try router.createWorkspace(name: "manual-ws", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "Manual thread",
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


    private func makeSurface(_ f: Fixture, control: BotComputerControl = BotComputerControl()) -> AgentAppViewModel {
        let surface = AgentAppSurface(
            workspaceID: f.vm.workspaceID,
            cwd: f.workspaceCwd,
            coordinator: f.ctx.coordinator,
            threadRepo: f.ctx.threadRepo,
            messageRepo: f.ctx.messageRepo,
            queuedMessageRepo: f.ctx.queuedMessageRepo,
            providerSessionRepo: f.ctx.providerSessionRuntimeRepo,
            checkpointRepo: f.ctx.turnCheckpointRepo,
            initialThreadId: f.thread.id
        )
        f.router.configureAgentAppBotMentions(surface)
        surface.viewModel.providerSnapshots = f.vm.providerSnapshots
        surface.viewModel.providerLaunchConfig = { _, _ in ("/usr/bin/true", [:]) }
        surface.viewModel.botComputerControl = control
        surface.viewModel.selectThread(f.thread.id)
        extraSurfaces.append(surface)
        return surface.viewModel
    }

    private var extraSurfaces: [AgentAppSurface] = []

    private func post(_ f: Fixture, control: BotComputerControl) -> ManualActionRequest {
        let request = ManualActionRequest(botID: f.bot.id, threadID: f.thread.id, kind: .login, reason: "Entre na conta")
        control.requestHelp(request)
        NotificationCenter.default.post(
            name: .botManualActionRequested, object: nil,
            userInfo: [BotHostNotificationKey.request: request]
        )
        return request
    }

    func test_manualAction_1_requestOpensCardAndThreadAwaits() async throws {
        let f = try makeFixture()
        let control = BotComputerControl()
        f.vm.botComputerControl = control
        XCTAssertNil(f.vm.openManualAction)
        let request = post(f, control: control)
        let opened = await waitUntil { f.vm.openManualAction?.id == request.id }
        XCTAssertTrue(opened, "card must open for the thread the request names")
        XCTAssertEqual(f.vm.statusLabel, "Aguardando você")
    }

    func test_manualAction_2_continueSendsSingleFollowUpWithNote() async throws {
        let f = try makeFixture()
        let control = BotComputerControl()
        f.vm.botComputerControl = control
        _ = post(f, control: control)
        _ = await waitUntil { f.vm.openManualAction != nil }
        async let first: Void = f.vm.continueManualAction(note: "logado")
        async let second: Void = f.vm.continueManualAction(note: "logado")
        _ = await (first, second)
        await f.vm.continueManualAction(note: "logado")
        _ = await waitUntil { f.runner.requests.count >= 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(f.runner.requests.count, 1, "double tap must produce exactly one follow-up")
        let prompt = try XCTUnwrap(f.runner.requests.first).prompt
        XCTAssertTrue(prompt.contains("logado"))
        XCTAssertTrue(prompt.contains("login"))
        XCTAssertNil(f.vm.openManualAction)
        XCTAssertEqual(f.vm.resolvedManualActions.first?.state, .continued)
        XCTAssertNil(control.openRequest(f.bot.id))
    }

    func test_manualAction_4_declineSendsDeclineFollowUp() async throws {
        let f = try makeFixture()
        let control = BotComputerControl()
        f.vm.botComputerControl = control
        _ = post(f, control: control)
        _ = await waitUntil { f.vm.openManualAction != nil }
        await f.vm.declineManualAction()
        _ = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertEqual(f.runner.requests.first?.prompt, ManualActionRequest.declineFollowUp)
        XCTAssertEqual(f.vm.resolvedManualActions.first?.state, .declined)
    }

    func test_manualAction_5_restartKeepsCardAndResetsControl() async throws {
        let f = try makeFixture()
        let control = BotComputerControl()
        f.vm.botComputerControl = control
        let request = post(f, control: control)
        _ = await waitUntil { f.vm.openManualAction != nil }
        f.vm.takeManualControl()
        XCTAssertTrue(control.isControlledByUser(f.bot.id))
        XCTAssertEqual(f.vm.openManualAction?.state, .taken)
        let restartedControl = BotComputerControl()
        let restarted = makeSurface(f, control: restartedControl)
        XCTAssertEqual(restarted.openManualAction?.id, request.id, "card survives restart")
        XCTAssertFalse(restartedControl.isControlledByUser(f.bot.id), "control is not persisted")
        XCTAssertEqual(restarted.openManualAction?.state, .open, "taken request is handed back after restart")
    }

    func test_manualAction_7_deskAndWorkspaceShareOneFollowUp() async throws {
        let f = try makeFixture()
        let control = BotComputerControl()
        f.vm.botComputerControl = control
        let other = makeSurface(f, control: control)
        _ = post(f, control: control)
        _ = await waitUntil { f.vm.openManualAction != nil && other.openManualAction != nil }
        XCTAssertNotNil(other.openManualAction)
        await f.vm.continueManualAction(note: "ok")
        await other.continueManualAction(note: "ok")
        _ = await waitUntil { f.runner.requests.count >= 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(f.runner.requests.count, 1, "second surface must see the request already resolved")
    }

    private func lockToBotVM(_ f: Fixture) throws {
        let lockedAt = Date()
        XCTAssertTrue(try f.ctx.threadRepo.setActor(
            id: f.thread.id, actor: .bot(f.bot.id), lockedAt: lockedAt, executionTarget: .vm
        ))
        let index = try XCTUnwrap(f.vm.threads.firstIndex(where: { $0.id == f.thread.id }))
        f.vm.threads[index].actor = .bot(f.bot.id)
        f.vm.threads[index].actorLockedAt = lockedAt
        f.vm.mirrorExecutionTarget(.vm, thread: f.thread.id)
    }

    /// WHY: the user must be able to take the VM screen and hand it back; handing back mid-request resumes the bot once.
    func test_botScreen_takeThenDevolverWithOpenRequestContinuesOnce() async throws {
        let f = try makeFixture()
        let control = BotComputerControl()
        f.vm.botComputerControl = control
        try lockToBotVM(f)
        f.vm.botVMPreflight = { _ in nil }
        f.vm.botThreadLinker = { _, _ in }
        f.vm.botPromptTransform = { _, text, _, _ in text }
        f.vm.botRunStarted = { _, _, _ in }
        XCTAssertEqual(f.vm.botScreenBotID, f.bot.id)
        var opened: [BotID] = []
        f.vm.openBotScreen = { opened.append($0) }
        f.vm.viewBotScreen()
        XCTAssertEqual(opened, [f.bot.id])

        await f.vm.toggleBotScreenControl()
        XCTAssertTrue(control.isControlledByUser(f.bot.id))
        XCTAssertTrue(f.vm.botScreenControlled)

        _ = post(f, control: control)
        _ = await waitUntil { f.vm.openManualAction != nil }
        await f.vm.toggleBotScreenControl()
        XCTAssertFalse(control.isControlledByUser(f.bot.id))
        XCTAssertFalse(f.vm.botScreenControlled)
        _ = await waitUntil { f.runner.requests.count >= 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(f.runner.requests.count, 1)
        XCTAssertEqual(f.vm.resolvedManualActions.first?.state, .continued)
    }

    func test_manualAction_8_unwritableStoreDoesNotContinueOrFollowUp() async throws {
        // WHY: continuing without a durable resolve would resend the follow-up after restart.
        let f = try makeFixture()
        let control = BotComputerControl()
        f.vm.botComputerControl = control
        let request = post(f, control: control)
        _ = await waitUntil { f.vm.openManualAction != nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualActionBroken-\(UUID().uuidString)", isDirectory: true)
        let broken = ManualActionRequestStore(appSupportDirectory: dir)
        try broken.upsert(request)
        let actions = dir.appendingPathComponent("ManualActions")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: actions.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: actions.path) }
        f.vm.manualActionStore = broken
        f.vm.openManualAction = request
        await f.vm.continueManualAction(note: "ok")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(f.runner.requests.count, 0, "no follow-up when the resolve was not persisted")
        XCTAssertFalse(f.vm.statusMessage.isEmpty)
        XCTAssertNotNil(control.openRequest(f.bot.id), "control request stays open")
        XCTAssertEqual(broken.open(threadID: f.thread.id)?.state, .open, "request stays open on disk")
    }

    func test_manualAction_9_staleSecondSurfaceTakeIsRefusedAfterContinue() async throws {
        // WHY: a stale card on another surface must not revive a continued request or add a follow-up.
        let f = try makeFixture()
        let control = BotComputerControl()
        f.vm.botComputerControl = control
        let other = makeSurface(f, control: control)
        _ = post(f, control: control)
        _ = await waitUntil { f.vm.openManualAction != nil && other.openManualAction != nil }
        let stale = try XCTUnwrap(other.openManualAction)
        await f.vm.continueManualAction(note: "ok")
        _ = await waitUntil { f.runner.requests.count >= 1 }
        other.openManualAction = stale
        other.takeManualControl()
        XCTAssertEqual(f.router.manualActionStore.all(threadID: f.thread.id).first?.state, .continued)
        XCTAssertFalse(control.isControlledByUser(f.bot.id))
        await other.continueManualAction(note: "ok")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(f.runner.requests.count, 1)
        let refreshed = await waitUntil { other.openManualAction == nil }
        XCTAssertTrue(refreshed, "stale card refreshes via state-change notification or take refresh")
    }
}
