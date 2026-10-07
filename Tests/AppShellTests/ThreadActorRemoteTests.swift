import XCTest
import AgentRuntime
import CoreModel
import RemoteCodeTreaty
@testable import SocketServer
@testable import AppShell
@testable import Persistence
@testable import Surfaces

/// WHY: the iPhone must show the same "Bot · VM" badge the Mac composer
/// shows, run a thread as a bot under the same lock rules, and answer a bot's
/// "run on the Mac?" request exactly once, whoever answers first (the Mac
/// banner, another device or a parallel tap). Every thread payload carries one
/// shape so the phone never has to guess which path built the row.
@MainActor
final class ThreadActorRemoteTests: XCTestCase {
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
        let botsVM: BotsViewModel
        /// Logical desktop: runs on the Mac, has a compiled soul.
        let macBot: BotDefinition
        /// Docker desktop: its default target is the VM.
        let vmBot: BotDefinition
        let workspace: Workspace
        let workspaceCwd: String
        let thread: AgentThread
        let snapshots: [AgentProviderSnapshot]
    }

    private static let soulMarker = "THREAD-ACTOR-SOUL-7731"
    private var surfaces: [AgentAppSurface] = []

    override func tearDown() async throws {
        for surface in surfaces { SurfaceRegistry.shared.unregister(surface.descriptor.id) }
        surfaces.removeAll()
        try await super.tearDown()
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2ThreadActorRemote-\(UUID().uuidString)", isDirectory: true)
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
        // The Bots window installs the router's link and bot-turn hooks.
        let botsVM = BotsViewModel(context: ctx, router: router)
        router.botsViewModel = botsVM
        let macBot = try botsVM.create(name: "Quinn", title: "Scout", soul: Self.soulMarker)
        let vmBot = try ctx.botStore.create(
            name: "Vera", title: "Ops", description: "", handle: "vera", desktopKind: .dockerDesktop
        )
        let workspace = try router.createWorkspace(name: "actor-ws", cwd: workspaceDir.path)
        let thread = try newThread(router, workspace: workspace.id, title: "Actor thread")
        return Fixture(
            ctx: ctx, router: router, runner: runner, botsVM: botsVM, macBot: macBot, vmBot: vmBot,
            workspace: workspace, workspaceCwd: workspaceDir.path, thread: thread, snapshots: snapshots
        )
    }

    private func newThread(
        _ router: AppCommandRouter,
        workspace: WorkspaceID,
        title: String,
        provider: AgentProvider = .codex
    ) throws -> AgentThread {
        try router.createAgentThread(
            workspace: workspace,
            title: title,
            provider: provider,
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium
        )
    }

    private func macSurface(_ f: Fixture) -> AgentAppViewModel {
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
        // Registered like an open tab, so host-side changes reach its view model.
        SurfaceRegistry.shared.register(surface)
        f.router.configureAgentAppBotMentions(surface)
        let vm = surface.viewModel
        vm.providerSnapshots = f.snapshots
        vm.providerLaunchConfig = { _, _ in ("/usr/bin/true", [:]) }
        vm.selectThread(f.thread.id)
        return vm
    }

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
        private var events: [(kind: String, payload: [String: JSONValue])] = []
        func append(_ kind: String, _ payload: [String: JSONValue]) { lock.withLock { events.append((kind, payload)) } }
        func payloads(_ kind: String, thread: AgentThreadID) -> [[String: JSONValue]] {
            lock.withLock {
                events.filter {
                    $0.kind == kind && $0.payload["thread_id"]?.stringValue == thread.value.uuidString
                }.map(\.payload)
            }
        }
    }

    private func recordEvents() -> (EventLog, UUID) {
        let log = EventLog()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard let object = event.payload.objectValue else { return }
            log.append(event.kind, object)
        }
        return (log, subscription)
    }

    private func context(_ name: String) -> MutationRequestContext {
        MutationRequestContext(ownerFingerprint: "owner-\(name)", hostId: "host-actor", bootEpoch: 1)
    }

    private func mutation(_ method: String, _ params: [String: JSONValue], requestID: String = UUID().uuidString) -> JSONRPCRequest {
        var all = params
        all["client_request_id"] = .string(requestID)
        all["connection_id"] = .string("conn")
        all["expected_host_id"] = .string("host-actor")
        all["expected_boot_epoch"] = .number(1)
        return JSONRPCRequest(jsonrpc: "2.0", id: .string(requestID), method: method, params: all)
    }

    private func setActor(
        _ f: Fixture,
        thread: AgentThreadID? = nil,
        bot: BotID?,
        target: String? = nil,
        requestID: String = UUID().uuidString
    ) async -> JSONRPCResponse {
        var actor: [String: JSONValue] = ["kind": .string(bot == nil ? "none" : "bot")]
        if let bot { actor["bot_id"] = .string(bot.value.uuidString) }
        var params: [String: JSONValue] = [
            "thread_id": .string((thread ?? f.thread.id).value.uuidString),
            "actor": .object(actor),
        ]
        if let target { params["execution_target"] = .string(target) }
        return await JSONRPCDispatcher(router: f.router)
            .dispatch(mutation("agent.thread.actor.set", params, requestID: requestID), mutationContext: context("phone"))
    }

    private func resolveMac(_ f: Fixture, approve: Bool, device: String = "phone") async -> JSONRPCResponse {
        await JSONRPCDispatcher(router: f.router).dispatch(mutation("agent.mac_execution.resolve", [
            "thread_id": .string(f.thread.id.value.uuidString),
            "approve": .bool(approve),
        ]), mutationContext: context(device))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func listRow(_ f: Fixture, thread: AgentThreadID? = nil) async throws -> [String: JSONValue] {
        let response = await JSONRPCDispatcher(router: f.router).dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "agent.thread.list",
            params: ["workspace_id": .string(f.workspace.id.value.uuidString)]
        ))
        let id = (thread ?? f.thread.id).value.uuidString
        let rows = try XCTUnwrap(response.result?.arrayValue)
        return try XCTUnwrap(rows.compactMap(\.objectValue).first {
            $0["id"]?.objectValue?["value"]?.stringValue == id || $0["id"]?.stringValue == id
        })
    }

    private func snapshotRow(_ f: Fixture) async throws -> [String: JSONValue] {
        let state = try await f.router.readConnectionSnapshotState()
        let rows = state.agentThreads.flatMap(\.items)
        return try XCTUnwrap(rows.compactMap(\.objectValue).first {
            $0["id"]?.stringValue == f.thread.id.value.uuidString
        })
    }

    private func requestMacExecution(_ f: Fixture, reason: String = "preciso do Xcode") async {
        NotificationCenter.default.post(
            name: .botMacExecutionRequested, object: nil,
            userInfo: [
                BotHostNotificationKey.botID: f.vmBot.id,
                BotHostNotificationKey.threadID: f.thread.id,
                BotHostNotificationKey.reason: reason,
            ]
        )
        _ = await waitUntil { f.router.pendingMacExecution[f.thread.id] != nil }
    }

    // MARK: - Payload shape

    /// One shape everywhere: the list, the thread event, the snapshot and the
    /// actor.set result agree, before and after the lock, and the guest marker
    /// of a Distill VM thread is visible.
    func test_everyThreadPayloadCarriesTheSameActorFields() async throws {
        let f = try makeFixture()
        let (log, subscription) = recordEvents()
        defer { EventBus.shared.unsubscribe(subscription) }

        let unlocked = try decode(AgentThreadActorFields.self, .object(try await listRow(f)))
        XCTAssertEqual(unlocked.actor, .none)
        XCTAssertNil(unlocked.actorLockedAt)
        XCTAssertNil(unlocked.executionTarget)
        XCTAssertNil(unlocked.guestRuntime)
        XCTAssertFalse(unlocked.runsInGuest)
        XCTAssertNil(unlocked.pendingMacExecution)
        let snapshotUnlocked = try await snapshotRow(f)
        XCTAssertEqual(try decode(AgentThreadActorFields.self, .object(snapshotUnlocked)), unlocked)

        // A Distill thread of a Docker-desktop bot runs inside the guest.
        let distill = try newThread(f.router, workspace: f.workspace.id, title: "Distill", provider: .distill)
        let response = await setActor(f, thread: distill.id, bot: f.vmBot.id)
        XCTAssertNil(response.error)
        let result = try decode(AgentThreadActorSet.Result.self, try XCTUnwrap(response.result))
        XCTAssertEqual(result.threadID, distill.id.value.uuidString)
        XCTAssertEqual(result.fields.actor, .bot(f.vmBot.id.value.uuidString.lowercased()))
        XCTAssertNotNil(result.fields.actorLockedAt)
        XCTAssertEqual(result.fields.executionTarget, "vm")
        XCTAssertEqual(result.fields.guestRuntime, BotGuestRuntime.distillV1)
        XCTAssertTrue(result.fields.runsInGuest)

        let listed = try await listRow(f, thread: distill.id)
        XCTAssertEqual(try decode(AgentThreadActorFields.self, .object(listed)), result.fields)
        XCTAssertEqual(listed["actor"]?.objectValue?["botId"], listed["actor"]?.objectValue?["bot_id"],
                       "the Codable key stays so the row still decodes as an AgentThread")
        let event = try XCTUnwrap(log.payloads("agent.thread.updated", thread: distill.id).last)
        XCTAssertEqual(try decode(AgentThreadActorFields.self, .object(event)), result.fields,
                       "the event the Mac and the phone mirror carries the same fields")
    }

    // MARK: - agent.thread.actor.set

    /// The phone locks an empty thread to a VM bot the way the Mac's first
    /// send does: linked conversation, bot default target, durable row, and the
    /// open Mac composer shows the locked chip at once.
    func test_actorSet_locksAnEmptyThreadLikeTheComposerAndSurvivesRestart() async throws {
        let f = try makeFixture()
        let vm = macSurface(f)

        let response = await setActor(f, bot: f.vmBot.id)

        XCTAssertNil(response.error)
        let stored = try XCTUnwrap(try AgentThreadRepository(db: f.ctx.db).get(id: f.thread.id),
                                   "a fresh repository reads what a restart would")
        XCTAssertEqual(stored.actor, .bot(f.vmBot.id))
        XCTAssertNotNil(stored.actorLockedAt)
        XCTAssertEqual(stored.executionTarget, .vm, "absent execution_target is the bot's default")
        XCTAssertNil(try f.ctx.threadRepo.guestPlacement(of: f.thread.id)?.guestRuntime,
                     "a Codex thread is not a guest Distill thread")
        XCTAssertEqual(try f.ctx.botStore.conversationLinked(to: f.thread.id)?.botID, f.vmBot.id)
        XCTAssertEqual(vm.selectedRunActor, .bot(f.vmBot.id), "the Mac chip shows the bot")
        XCTAssertTrue(vm.runActorLocked, "and is locked, as after a first send")
        XCTAssertEqual(vm.executionTarget(for: f.vmBot.id), .vm)
    }

    /// Same lock rules as the Mac chip: a thread with messages or a locked
    /// actor never changes; asking for what it already is changes nothing.
    func test_actorSet_refusesLockedThreadsAndIsIdempotent() async throws {
        let f = try makeFixture()
        do { let response = await setActor(f, bot: f.macBot.id); XCTAssertNil(response.error) }
        let lockedAt = try XCTUnwrap(try f.ctx.threadRepo.get(id: f.thread.id)?.actorLockedAt)

        let same = await setActor(f, bot: f.macBot.id)
        XCTAssertNil(same.error, "the actor the thread already has is a no-op success")
        let other = await setActor(f, bot: f.vmBot.id)
        XCTAssertEqual(other.error?.code, ThreadActorWire.lockedCode)
        XCTAssertEqual(other.error?.data?.objectValue?["kind"]?.stringValue, "locked")
        let none = await setActor(f, bot: nil)
        XCTAssertEqual(none.error?.code, ThreadActorWire.lockedCode)
        let stored = try XCTUnwrap(try f.ctx.threadRepo.get(id: f.thread.id))
        XCTAssertEqual(stored.actor, .bot(f.macBot.id))
        XCTAssertEqual(stored.actorLockedAt, lockedAt)
        XCTAssertEqual(stored.executionTarget, .mac)

        // A thread with a message is locked even without an actor.
        let used = try newThread(f.router, workspace: f.workspace.id, title: "Used")
        try f.ctx.messageRepo.append(AgentMessage(threadId: used.id, role: .user, content: "oi"))
        let refused = await setActor(f, thread: used.id, bot: f.macBot.id)
        XCTAssertEqual(refused.error?.code, ThreadActorWire.lockedCode)
        XCTAssertEqual(try f.ctx.threadRepo.get(id: used.id)?.actor, RunActor.none)
        XCTAssertNil(try f.ctx.threadRepo.get(id: used.id)?.actorLockedAt)
        do { let response = await setActor(f, thread: used.id, bot: nil); XCTAssertNil(response.error, "none on a none thread changes nothing") }
    }

    /// The target follows the bot: `vm` needs a VM; `mac` is the user's choice
    /// for a VM bot and never gets a guest marker.
    func test_actorSet_targetRulesAndUnknownBot() async throws {
        let f = try makeFixture()
        let noVM = await setActor(f, bot: f.macBot.id, target: "vm")
        XCTAssertEqual(noVM.error?.code, ThreadActorWire.targetUnavailableCode)
        XCTAssertEqual(noVM.error?.data?.objectValue?["kind"]?.stringValue, "target_unavailable")
        let unknown = await setActor(f, bot: BotID(UUID()))
        XCTAssertEqual(unknown.error?.code, ManualActionWire.notFoundCode)
        XCTAssertEqual(unknown.error?.data?.objectValue?["domain"]?.stringValue, "thread_actor")
        XCTAssertNil(try f.ctx.threadRepo.get(id: f.thread.id)?.actorLockedAt, "refusals change nothing")

        let distill = try newThread(f.router, workspace: f.workspace.id, title: "On Mac", provider: .distill)
        let onMac = await setActor(f, thread: distill.id, bot: f.vmBot.id, target: "mac")
        XCTAssertNil(onMac.error)
        let fields = try decode(AgentThreadActorSet.Result.self, try XCTUnwrap(onMac.result)).fields
        XCTAssertEqual(fields.executionTarget, "mac")
        XCTAssertNil(fields.guestRuntime)
        XCTAssertFalse(fields.runsInGuest)
    }

    /// A retried tap replays its receipt: one lock, one event.
    func test_actorSetRetryWithSameRequestID_replays() async throws {
        let f = try makeFixture()
        let (log, subscription) = recordEvents()
        defer { EventBus.shared.unsubscribe(subscription) }
        let first = await setActor(f, bot: f.macBot.id, requestID: "actor-retry-1")
        let retry = await setActor(f, bot: f.macBot.id, requestID: "actor-retry-1")
        XCTAssertNil(first.error)
        XCTAssertEqual(first.result, retry.result)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(log.payloads("agent.thread.updated", thread: f.thread.id).count, 1)
    }

    /// WHY: a thread the phone locked to a bot must run as that bot, as the
    /// Mac composer's sends do; a plain thread keeps its plain text.
    func test_phoneSendOnABotLockedThread_runsTheBotTurn() async throws {
        let f = try makeFixture()
        do { let response = await setActor(f, bot: f.macBot.id); XCTAssertNil(response.error) }

        _ = try await f.router.sendAgentMessageRouting(
            thread: f.thread.id, text: "faça o relatório", provider: nil, model: nil, permissionMode: nil,
            reasoningEffort: nil, serviceTier: nil, interactionMode: nil, modelSelection: nil,
            providerInstanceId: nil, attachments: [], routing: nil
        )
        _ = await waitUntil { f.runner.requests.count >= 1 }
        let run = try XCTUnwrap(f.runner.requests.first)
        XCTAssertTrue(run.prompt.contains(Self.soulMarker), "the compiled bot brain reaches the provider")
        XCTAssertEqual(run.userMessageContent, "faça o relatório", "the transcript shows the user's text")
        f.runner.finish(runID: run.runId, status: .completed, reply: "ok")

        let plain = try newThread(f.router, workspace: f.workspace.id, title: "Plain")
        _ = try await f.router.sendAgentMessageRouting(
            thread: plain.id, text: "oi", provider: nil, model: nil, permissionMode: nil,
            reasoningEffort: nil, serviceTier: nil, interactionMode: nil, modelSelection: nil,
            providerInstanceId: nil, attachments: [], routing: nil
        )
        _ = await waitUntil { f.runner.requests.count >= 2 }
        XCTAssertEqual(f.runner.requests.count >= 2 ? f.runner.requests[1].prompt : nil, "oi")
    }

    // MARK: - Mac execution

    /// The request reaches the phone as an event and in every thread payload.
    func test_macExecutionRequest_isPublishedAndInThePayloads() async throws {
        let f = try makeFixture()
        let (log, subscription) = recordEvents()
        defer { EventBus.shared.unsubscribe(subscription) }
        do { let response = await setActor(f, bot: f.vmBot.id); XCTAssertNil(response.error) }

        await requestMacExecution(f)

        let published = await waitUntil { !log.payloads("agent.mac_execution.requested", thread: f.thread.id).isEmpty }
        XCTAssertTrue(published)
        let event = try decode(
            AgentMacExecutionRequestedEvent.self,
            .object(try XCTUnwrap(log.payloads("agent.mac_execution.requested", thread: f.thread.id).first))
        )
        XCTAssertEqual(event.reason, "preciso do Xcode")
        XCTAssertEqual(event.pendingMacExecution.reason, "preciso do Xcode")
        let listed = try decode(AgentThreadActorFields.self, .object(try await listRow(f)))
        XCTAssertEqual(listed.pendingMacExecution?.reason, "preciso do Xcode")
        let snapshot = try await snapshotRow(f)
        XCTAssertEqual(try decode(AgentThreadActorFields.self, .object(snapshot)).pendingMacExecution,
                       listed.pendingMacExecution)
    }

    /// Two devices answer at once: one wins, the other learns it lost, the bot
    /// hears once, and the thread event clears the row on every client.
    func test_parallelMacExecutionResolve_exactlyOneWinner() async throws {
        let f = try makeFixture()
        let (log, subscription) = recordEvents()
        defer { EventBus.shared.unsubscribe(subscription) }
        do { let response = await setActor(f, bot: f.vmBot.id); XCTAssertNil(response.error) }
        await requestMacExecution(f)

        async let first = resolveMac(f, approve: true, device: "phone")
        async let second = resolveMac(f, approve: true, device: "ipad")
        let responses = await [first, second]

        let winners = responses.filter { $0.error == nil }
        let losers = responses.filter { $0.error != nil }
        XCTAssertEqual(winners.count, 1)
        XCTAssertEqual(losers.first?.error?.code, ThreadActorWire.notPendingCode)
        XCTAssertEqual(losers.first?.error?.data?.objectValue?["domain"]?.stringValue, "mac_execution")
        let result = try decode(AgentMacExecutionResolve.Result.self, try XCTUnwrap(winners.first?.result))
        XCTAssertTrue(result.approved)
        XCTAssertEqual(result.fields.executionTarget, "mac")
        XCTAssertNil(result.fields.pendingMacExecution)
        XCTAssertEqual(result.followUp.delivered, true)
        XCTAssertEqual(try f.ctx.threadRepo.get(id: f.thread.id)?.executionTarget, .mac)

        _ = await waitUntil { f.runner.requests.count >= 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(f.runner.requests.count, 1, "the bot gets exactly one follow-up")
        XCTAssertEqual(f.runner.requests.first?.userMessageContent, AppCommandRouter.macExecutionApprovedFollowUp)
        let cleared = log.payloads("agent.thread.updated", thread: f.thread.id).last
        XCTAssertEqual(cleared?["pending_mac_execution"], .null)
        XCTAssertEqual(cleared?["execution_target"]?.stringValue, "mac")
    }

    /// The Mac banner answers first: the phone's late answer loses and the
    /// Mac's answer still reaches the phone.
    func test_macBannerAnswerWins_andIsPublished() async throws {
        let f = try makeFixture()
        let vm = macSurface(f)
        let (log, subscription) = recordEvents()
        defer { EventBus.shared.unsubscribe(subscription) }
        do { let response = await setActor(f, bot: f.vmBot.id); XCTAssertNil(response.error) }
        await requestMacExecution(f)
        _ = await waitUntil { vm.pendingMacExecutionReason != nil }

        vm.resolveMacExecution(approve: false)
        let answered = await waitUntil {
            log.payloads("agent.thread.updated", thread: f.thread.id).last?["pending_mac_execution"] == .null
                && f.router.pendingMacExecution[f.thread.id] == nil
        }
        XCTAssertTrue(answered)
        let phone = await resolveMac(f, approve: true)

        XCTAssertEqual(phone.error?.code, ThreadActorWire.notPendingCode)
        XCTAssertEqual(try f.ctx.threadRepo.get(id: f.thread.id)?.executionTarget, .vm, "the decline stands")
        _ = await waitUntil { f.runner.requests.count >= 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(f.runner.requests.count, 1)
        XCTAssertEqual(f.runner.requests.first?.userMessageContent, AppCommandRouter.macExecutionDeclinedFollowUp)
    }

    func test_macExecutionResolve_unknownThreadAndNothingPending() async throws {
        let f = try makeFixture()
        let unknown = await JSONRPCDispatcher(router: f.router).dispatch(mutation("agent.mac_execution.resolve", [
            "thread_id": .string(UUID().uuidString), "approve": .bool(true),
        ]), mutationContext: context("phone"))
        XCTAssertEqual(unknown.error?.code, ManualActionWire.notFoundCode)
        let nothing = await resolveMac(f, approve: true)
        XCTAssertEqual(nothing.error?.code, ThreadActorWire.notPendingCode)
        XCTAssertEqual(nothing.error?.data?.objectValue?["kind"]?.stringValue, "not_pending")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(f.runner.requests.count, 0)
    }
}
