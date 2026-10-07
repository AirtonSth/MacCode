import XCTest
import AgentRuntime
import CoreModel
import RemoteCodeTreaty
@testable import SocketServer
@testable import AppShell
@testable import Persistence
@testable import Surfaces

/// WHY: a bot paused for a login or captcha must be answerable from the iPhone
/// exactly like from the Mac card. Whoever answers first wins (the Mac card,
/// another device or a parallel tap), the bot gets exactly one follow-up, the
/// loser is told it lost without changing anything, and every change reaches
/// the paired devices as an event so their card never goes stale.
@MainActor
final class ManualActionRemoteTests: XCTestCase {
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
        let runner: ControlledBotHandoffRunner
        let bot: BotDefinition
        let thread: AgentThread
        let workspace: Workspace
        let workspaceCwd: String
        let snapshots: [AgentProviderSnapshot]
        let control: BotComputerControl
    }

    private var surfaces: [AgentAppSurface] = []

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2ManualActionRemote-\(UUID().uuidString)", isDirectory: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let control = BotComputerControl()
        router.botComputerControl = control
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
        let bot = try ctx.botStore.create(name: "Quinn", title: "Scout", description: "", handle: "quinn", soul: "soul")
        let workspace = try router.createWorkspace(name: "manual-remote-ws", cwd: workspaceDir.path)
        let thread = try router.createAgentThread(
            workspace: workspace.id,
            title: "Manual remote thread",
            provider: .codex,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
        return Fixture(
            ctx: ctx, router: router, runner: runner, bot: bot, thread: thread,
            workspace: workspace, workspaceCwd: workspaceDir.path, snapshots: snapshots, control: control
        )
    }

    // MARK: - Helpers

    private func waitUntil(timeout: TimeInterval = 6, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [[String: JSONValue]] = []
        func append(_ payload: [String: JSONValue]) { lock.withLock { events.append(payload) } }
        /// States of `agent.manual_action.updated` events for one request, in publish order.
        func states(_ id: UUID) -> [String] {
            lock.withLock {
                events.compactMap { event in
                    guard let row = event["manual_action"]?.objectValue,
                          row["id"]?.stringValue == id.uuidString else { return nil }
                    return row["state"]?.stringValue
                }
            }
        }
        func last(_ id: UUID) -> [String: JSONValue]? {
            lock.withLock {
                events.last { $0["manual_action"]?.objectValue?["id"]?.stringValue == id.uuidString }
            }
        }
    }

    private func recordEvents() -> (EventLog, UUID) {
        let log = EventLog()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "agent.manual_action.updated", let object = event.payload.objectValue else { return }
            log.append(object)
        }
        return (log, subscription)
    }

    /// The bot asks for help the way the host does: in-memory request plus notification.
    @discardableResult
    private func openRequest(_ f: Fixture, kind: ManualActionKind = .login) async -> ManualActionRequest {
        let request = ManualActionRequest(botID: f.bot.id, threadID: f.thread.id, kind: kind, reason: "Entre na conta")
        f.control.requestHelp(request)
        NotificationCenter.default.post(
            name: .botManualActionRequested, object: nil,
            userInfo: [BotHostNotificationKey.request: request]
        )
        _ = await waitUntil { f.router.manualActionStore.open(threadID: f.thread.id) != nil }
        return request
    }

    private func context(_ name: String) -> MutationRequestContext {
        MutationRequestContext(ownerFingerprint: "owner-\(name)", hostId: "host-manual", bootEpoch: 1)
    }

    private func resolveRequest(
        _ f: Fixture,
        _ request: ManualActionRequest,
        action: String,
        note: String? = nil,
        requestID: String = UUID().uuidString
    ) -> JSONRPCRequest {
        var params: [String: JSONValue] = [
            "client_request_id": .string(requestID),
            "connection_id": .string("conn"),
            "expected_host_id": .string("host-manual"),
            "expected_boot_epoch": .number(1),
            "thread_id": .string(f.thread.id.value.uuidString),
            "manual_action_id": .string(request.id.uuidString),
            "action": .string(action),
        ]
        if let note { params["note"] = .string(note) }
        return JSONRPCRequest(jsonrpc: "2.0", id: .string(requestID), method: "agent.manual_action.resolve", params: params)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func refusalKind(_ response: JSONRPCResponse) -> String? {
        response.error?.data?.objectValue?["kind"]?.stringValue
    }

    // MARK: - Single winner

    /// Two devices tap Continue at once: one wins, the other is refused with
    /// the current state, and the bot is told exactly once.
    func test_parallelResolve_exactlyOneWinnerAndOneFollowUp() async throws {
        let f = try makeFixture()
        let (log, subscription) = recordEvents()
        defer { EventBus.shared.unsubscribe(subscription) }
        let request = await openRequest(f)
        let dispatcher = JSONRPCDispatcher(router: f.router)
        let phone = context("phone")
        let ipad = context("ipad")

        async let first = dispatcher.dispatch(resolveRequest(f, request, action: "continue", note: "logado"), mutationContext: phone)
        async let second = dispatcher.dispatch(resolveRequest(f, request, action: "continue", note: "logado"), mutationContext: ipad)
        let responses = await [first, second]

        let winners = responses.filter { $0.error == nil }
        let losers = responses.filter { $0.error != nil }
        XCTAssertEqual(winners.count, 1, "exactly one resolve wins")
        XCTAssertEqual(losers.count, 1)
        XCTAssertEqual(losers.first?.error?.code, ManualActionWire.stateConflictCode)
        XCTAssertEqual(refusalKind(try XCTUnwrap(losers.first)), "state_conflict")
        XCTAssertEqual(losers.first?.error?.data?.objectValue?["state"]?.stringValue, "continued",
                       "the loser learns what happened instead of a generic failure")
        let kind = RemoteCodeError(
            code: try XCTUnwrap(losers.first?.error?.code),
            message: "",
            data: try decode(RemoteCodeJSONValue.self, try XCTUnwrap(losers.first?.error?.data))
        ).kind
        XCTAssertEqual(kind, .manualActionStateConflict)

        let result = try decode(AgentManualActionResolve.Result.self, try XCTUnwrap(winners.first?.result))
        XCTAssertEqual(result.manualAction.state, "continued")
        XCTAssertEqual(result.manualAction.note, "logado")
        XCTAssertNil(result.pendingManualAction)
        XCTAssertEqual(result.followUp?.delivered, true)
        XCTAssertNotNil(result.followUp?.runID)

        _ = await waitUntil { f.runner.requests.count >= 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(f.runner.requests.count, 1, "the bot gets exactly one follow-up")
        let prompt = try XCTUnwrap(f.runner.requests.first).prompt
        XCTAssertTrue(prompt.contains("logado"), "the user's note reaches the bot")
        XCTAssertTrue(prompt.contains("login"))
        XCTAssertNil(f.control.openRequest(f.bot.id), "the bot can ask for help again")
        XCTAssertEqual(f.router.manualActionStore.all(threadID: f.thread.id).first?.state, .continued)
        XCTAssertEqual(log.states(request.id), ["open", "continued"], "open and resolved each published once")
    }

    /// The Mac card and the iPhone answer the same request: still one winner,
    /// one follow-up, and the Mac card's own answer reaches the iPhone.
    func test_macCardAndPhoneRace_oneFollowUpAndMacAnswerIsPublished() async throws {
        let f = try makeFixture()
        let (log, subscription) = recordEvents()
        defer { EventBus.shared.unsubscribe(subscription) }
        let surface = AgentAppSurface(
            workspaceID: f.workspace.id,
            cwd: f.workspaceCwd,
            coordinator: f.ctx.coordinator,
            threadRepo: f.ctx.threadRepo,
            messageRepo: f.ctx.messageRepo,
            queuedMessageRepo: f.ctx.queuedMessageRepo,
            providerSessionRepo: f.ctx.providerSessionRuntimeRepo,
            checkpointRepo: f.ctx.turnCheckpointRepo,
            initialThreadId: f.thread.id
        )
        surfaces.append(surface)
        f.router.configureAgentAppBotMentions(surface)
        let vm = surface.viewModel
        vm.providerSnapshots = f.snapshots
        vm.providerLaunchConfig = { _, _ in ("/usr/bin/true", [:]) }
        vm.selectThread(f.thread.id)
        let request = await openRequest(f)
        _ = await waitUntil { vm.openManualAction != nil }
        XCTAssertNotNil(vm.openManualAction)
        // The card may save the request before the host's own hop: the open event still goes out.
        let announced = await waitUntil { log.states(request.id) == ["open"] }
        XCTAssertTrue(announced, "a request the Mac card saved first is still announced to iOS")

        await vm.continueManualAction(note: "pelo mac")
        let phone = await JSONRPCDispatcher(router: f.router)
            .dispatch(resolveRequest(f, request, action: "decline"), mutationContext: context("phone"))

        XCTAssertEqual(phone.error?.code, ManualActionWire.stateConflictCode, "the phone's late answer loses")
        _ = await waitUntil { f.runner.requests.count >= 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(f.runner.requests.count, 1)
        XCTAssertEqual(log.states(request.id), ["open", "continued"], "the Mac card's answer is published for iOS")
        XCTAssertEqual(log.last(request.id)?["pending_manual_action"], .null)
    }

    /// A retry after a lost response reuses its client_request_id: same answer,
    /// no second follow-up, no second event.
    func test_resolveRetryWithSameRequestID_replaysWithoutSecondFollowUp() async throws {
        let f = try makeFixture()
        let (log, subscription) = recordEvents()
        defer { EventBus.shared.unsubscribe(subscription) }
        let request = await openRequest(f)
        let dispatcher = JSONRPCDispatcher(router: f.router)
        let call = resolveRequest(f, request, action: "decline", requestID: "decline-1")

        let first = await dispatcher.dispatch(call, mutationContext: context("phone"))
        let retry = await dispatcher.dispatch(call, mutationContext: context("phone"))

        XCTAssertNil(first.error)
        XCTAssertEqual(first.result, retry.result)
        _ = await waitUntil { f.runner.requests.count >= 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(f.runner.requests.count, 1)
        XCTAssertEqual(f.runner.requests.first?.prompt.contains(ManualActionRequest.declineFollowUp), true)
        XCTAssertEqual(log.states(request.id), ["open", "declined"])
    }

    // MARK: - Take

    /// Take hands the bot's computer to the user and says nothing to the bot;
    /// a second take loses because the request is already taken.
    func test_take_givesUserTheComputerAndSendsNothing() async throws {
        let f = try makeFixture()
        let (log, subscription) = recordEvents()
        defer { EventBus.shared.unsubscribe(subscription) }
        let request = await openRequest(f)
        let dispatcher = JSONRPCDispatcher(router: f.router)

        let taken = await dispatcher.dispatch(resolveRequest(f, request, action: "take"), mutationContext: context("phone"))
        let again = await dispatcher.dispatch(resolveRequest(f, request, action: "take"), mutationContext: context("phone"))

        XCTAssertNil(taken.error)
        let result = try decode(AgentManualActionResolve.Result.self, try XCTUnwrap(taken.result))
        XCTAssertEqual(result.manualAction.state, "taken")
        XCTAssertEqual(result.pendingManualAction?.id, request.id.uuidString, "a taken request is still pending")
        XCTAssertNil(result.followUp)
        XCTAssertTrue(f.control.isControlledByUser(f.bot.id), "BotComputerControl.take ran")
        XCTAssertEqual(again.error?.code, ManualActionWire.stateConflictCode)
        XCTAssertEqual(again.error?.data?.objectValue?["state"]?.stringValue, "taken")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(f.runner.requests.count, 0, "take never messages the bot")
        XCTAssertEqual(log.states(request.id), ["open", "taken"])

        // Continue after take hands control back and messages the bot once.
        let done = await dispatcher.dispatch(resolveRequest(f, request, action: "continue"), mutationContext: context("phone"))
        XCTAssertNil(done.error)
        XCTAssertFalse(f.control.isControlledByUser(f.bot.id))
        _ = await waitUntil { f.runner.requests.count >= 1 }
        XCTAssertEqual(f.runner.requests.count, 1)
    }

    /// A thread that runs on the Mac has no bot computer: take is refused
    /// (the Mac card hides it too) and nothing changes.
    func test_takeOnMacThread_isRefusedAndChangesNothing() async throws {
        let f = try makeFixture()
        XCTAssertTrue(try f.ctx.threadRepo.setActor(
            id: f.thread.id, actor: .bot(f.bot.id), lockedAt: Date(), executionTarget: .mac
        ))
        let request = await openRequest(f)
        let response = await JSONRPCDispatcher(router: f.router)
            .dispatch(resolveRequest(f, request, action: "take"), mutationContext: context("phone"))

        XCTAssertEqual(response.error?.code, ManualActionWire.takeUnavailableCode)
        XCTAssertEqual(refusalKind(response), "take_unavailable")
        XCTAssertFalse(f.control.isControlledByUser(f.bot.id))
        XCTAssertEqual(f.router.manualActionStore.open(threadID: f.thread.id)?.state, .open)
        XCTAssertEqual(try f.router.listManualActions(thread: f.thread.id).first?.canTake, false)
    }

    /// After a host restart nobody holds the computer: a request saved as
    /// taken reads as open and can be taken again, as on the Mac card.
    func test_takenRequestWithoutControl_readsOpenAndCanBeTakenAgain() async throws {
        let f = try makeFixture()
        var stale = ManualActionRequest(botID: f.bot.id, threadID: f.thread.id, kind: .captcha, reason: "Resolva")
        stale.state = .taken
        try f.router.manualActionStore.upsert(stale)

        XCTAssertEqual(try f.router.listManualActions(thread: f.thread.id).first?.request.state, .open)
        let response = await JSONRPCDispatcher(router: f.router)
            .dispatch(resolveRequest(f, stale, action: "take"), mutationContext: context("phone"))
        XCTAssertNil(response.error)
        XCTAssertTrue(f.control.isControlledByUser(f.bot.id))
    }

    // MARK: - Reads and payloads

    /// The phone opening the thread sees the card from the thread payload and
    /// the list, and it disappears from both once answered.
    func test_listAndThreadPayloadCarryPendingManualAction() async throws {
        let f = try makeFixture()
        let request = await openRequest(f)
        let dispatcher = JSONRPCDispatcher(router: f.router)

        func listed() async throws -> AgentManualActionList.Result {
            let response = await dispatcher.dispatch(JSONRPCRequest(
                jsonrpc: "2.0", id: .number(1), method: "agent.manual_action.list",
                params: ["thread_id": .string(f.thread.id.value.uuidString)]
            ))
            XCTAssertNil(response.error)
            return try decode(AgentManualActionList.Result.self, try XCTUnwrap(response.result))
        }
        func threadPending() async throws -> JSONValue? {
            let response = await dispatcher.dispatch(JSONRPCRequest(
                jsonrpc: "2.0", id: .number(2), method: "agent.thread.list",
                params: ["workspace_id": .string(f.workspace.id.value.uuidString)]
            ))
            let rows = try XCTUnwrap(response.result?.arrayValue)
            let row = rows.first { $0.objectValue?["title"]?.stringValue == f.thread.title }
            return row?.objectValue?["pending_manual_action"]
        }

        let open = try await listed()
        XCTAssertEqual(open.pendingManualAction?.id, request.id.uuidString)
        XCTAssertEqual(open.pendingManualAction?.kind, "login")
        XCTAssertEqual(open.pendingManualAction?.botName, "Quinn")
        XCTAssertEqual(open.pendingManualAction?.canTake, true)
        let pendingValue = try await threadPending()
        let pendingRow = try XCTUnwrap(pendingValue)
        XCTAssertEqual(try decode(AgentManualActionRow.self, pendingRow).id, request.id.uuidString)
        XCTAssertTrue(JSONRPCDispatcher.isReadOnlyBatchMethod("agent.manual_action.list"))

        _ = await dispatcher.dispatch(resolveRequest(f, request, action: "decline"), mutationContext: context("phone"))
        let closed = try await listed()
        XCTAssertNil(closed.pendingManualAction)
        XCTAssertEqual(closed.manualActions.map(\.state), ["declined"], "history stays readable")
        let afterValue = try await threadPending()
        XCTAssertEqual(afterValue, .null, "the key is always present")
    }

    func test_unknownRequest_isRefusedAsNotFoundAndChangesNothing() async throws {
        let f = try makeFixture()
        let request = await openRequest(f)
        let other = ManualActionRequest(botID: f.bot.id, threadID: f.thread.id, kind: .login, reason: "x")
        let response = await JSONRPCDispatcher(router: f.router)
            .dispatch(resolveRequest(f, other, action: "continue"), mutationContext: context("phone"))

        XCTAssertEqual(response.error?.code, ManualActionWire.notFoundCode)
        XCTAssertEqual(refusalKind(response), "not_found")
        XCTAssertEqual(f.router.manualActionStore.open(threadID: f.thread.id)?.id, request.id)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(f.runner.requests.count, 0)
    }

    /// A follow-up that cannot be sent is reported, never hidden: the request
    /// stays answered (the user did answer) and the phone shows the error.
    func test_followUpFailure_isReportedAndRequestStaysResolved() async throws {
        let f = try makeFixture()
        let request = await openRequest(f)
        f.router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex,
                models: [AgentModelDescriptor(id: "fake-model", label: "Fake Model", provider: .codex)],
                binaryPath: "/usr/bin/true",
                authenticated: false,
                id: "codex"
            )
        ])
        let response = await JSONRPCDispatcher(router: f.router)
            .dispatch(resolveRequest(f, request, action: "continue"), mutationContext: context("phone"))

        XCTAssertNil(response.error, "the answer itself was saved")
        let result = try decode(AgentManualActionResolve.Result.self, try XCTUnwrap(response.result))
        XCTAssertEqual(result.manualAction.state, "continued")
        XCTAssertEqual(result.followUp?.delivered, false)
        XCTAssertFalse((result.followUp?.error ?? "").isEmpty)
        XCTAssertEqual(f.runner.requests.count, 0)
    }
}
