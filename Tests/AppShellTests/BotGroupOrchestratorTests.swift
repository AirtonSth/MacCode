import XCTest
import AgentRuntime
import CoreModel
import SocketServer
@testable import AppShell
@testable import Persistence

/// WHY: a group conversation is one room where several bots answer in turn,
/// each on its own thread and runtime. The user must see their line and who is
/// about to answer at once; replies must replace those rows exactly once, in
/// order; a stale finish, a Stop or a relaunch must never leave a row spinning
/// or a turn running twice; and iOS must get every change as an event.
@MainActor
final class BotGroupOrchestratorTests: XCTestCase {
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
        let ana: BotDefinition
        let bob: BotDefinition
        let cid: BotDefinition
        @MainActor var orchestrator: BotGroupOrchestrator { ctx.botGroupOrchestrator }
    }

    private func makeFixture(anaDesktop: BotDesktopKind = .logicalExecutionSpace) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2BotGroup-\(UUID().uuidString)", isDirectory: true)
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support", isDirectory: true).path
        )
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let runner = ControlledBotHandoffRunner(provider: .codex)
        ctx.coordinator.replaceProviderAdapter(.codex, adapter: TerminalRetiringOneShotAdapter(runner: runner))
        let model = BotsViewModel.defaultModel(for: .codex)
        router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex,
                models: [AgentModelDescriptor(id: model, label: model, provider: .codex)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "codex"
            )
        ])
        ctx.botGroupOrchestrator.vmPreflight = { _ in nil }
        let ana = try ctx.botStore.create(
            name: "Ana", title: "Writer", description: "", handle: "ana", soul: "ANA-SOUL", desktopKind: anaDesktop
        )
        let bob = try ctx.botStore.create(name: "Bob", title: "Critic", description: "", handle: "bob", soul: "BOB-SOUL")
        let cid = try ctx.botStore.create(name: "Cid", title: "", description: "", handle: "cid", soul: "CID-SOUL")
        return Fixture(ctx: ctx, router: router, runner: runner, ana: ana, bob: bob, cid: cid)
    }

    private func makeGroup(
        _ f: Fixture,
        bots: [BotDefinition],
        policy: BotGroupPolicy = .roundtable,
        lead: BotID? = nil,
        hops: Int = BotGroupConversation.defaultMaxAutoHops
    ) async throws -> BotGroupConversation {
        try await f.orchestrator.createGroup(
            title: "Launch room",
            policy: policy,
            leadBotID: lead,
            maxAutoHops: hops,
            participantBotIDs: bots.map(\.id)
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

    private func turns(_ f: Fixture, _ group: BotGroupConversation) throws -> [BotGroupTurn] {
        try f.ctx.botStore.listGroupTurns(groupID: group.id)
    }

    private func room(_ f: Fixture, _ group: BotGroupConversation) throws -> [AgentMessage] {
        try f.ctx.messageRepo.list(threadId: group.roomThreadID)
    }

    private func memberThread(_ f: Fixture, _ group: BotGroupConversation, _ bot: BotDefinition) throws -> AgentThreadID? {
        let participant = try XCTUnwrap(
            try f.ctx.botStore.listGroupParticipants(groupID: group.id, includeLeft: true).first { $0.botID == bot.id }
        )
        return try f.ctx.botStore.conversation(id: participant.memberConversationID)?.linkedAgentThreadID
    }

    private func request(_ f: Fixture, onThreadOf bot: BotDefinition, in group: BotGroupConversation) throws -> AgentRunRequest {
        let thread = try XCTUnwrap(try memberThread(f, group, bot))
        return try XCTUnwrap(f.runner.requests.last { $0.threadId == thread })
    }

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(kind: String, payload: [String: JSONValue])] = []
        func append(_ kind: String, _ payload: [String: JSONValue]) { lock.withLock { stored.append((kind, payload)) } }
        var events: [(kind: String, payload: [String: JSONValue])] { lock.withLock { stored } }
    }

    /// Room `agent.message.appended` ids and `bot.group.turn.updated` states.
    private func recordEvents(roomThreadID: AgentThreadID) -> (EventLog, UUID) {
        let log = EventLog()
        let room = roomThreadID.value.uuidString
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard let object = event.payload.objectValue else { return }
            if event.kind == "agent.message.appended",
               object["threadId"]?.objectValue?["value"]?.stringValue == room {
                log.append(event.kind, object)
            } else if event.kind == "bot.group.turn.updated",
                      object["room_thread_id"]?.stringValue == room.lowercased() {
                log.append(event.kind, object)
            }
        }
        return (log, subscription)
    }

    private func appendedIDs(_ log: EventLog) -> [String] {
        log.events.filter { $0.kind == "agent.message.appended" }
            .compactMap { $0.payload["id"]?.objectValue?["value"]?.stringValue }
    }

    private func turnStates(_ log: EventLog, _ turn: BotGroupTurn) -> [String] {
        log.events.filter {
            $0.kind == "bot.group.turn.updated"
                && $0.payload["turn_id"]?.stringValue == turn.id.value.uuidString.lowercased()
        }.compactMap { $0.payload["state"]?.stringValue }
    }

    // MARK: - Immediate path, order, projection, events

    func test_sendShowsUserAndWaitingRowsAtOnceThenBotsAnswerInOrderReplacingTheirRows() async throws {
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana, f.bob])
        let (log, subscription) = recordEvents(roomThreadID: group.roomThreadID)
        defer { EventBus.shared.unsubscribe(subscription) }

        let started = Date()
        let receipt = try f.orchestrator.send(groupID: group.id, text: "Plan the launch", submitKey: "k1")
        let acknowledged = Date().timeIntervalSince(started)

        // Immediate path: on the calling turn, before any provider work.
        let rows = try room(f, group)
        XCTAssertEqual(rows.map(\.role), [.user, .assistant, .assistant])
        XCTAssertEqual(rows.first?.content, "Plan the launch")
        XCTAssertEqual(rows.dropFirst().compactMap { BotPeerTranscript.parseActivity($0.content)?.handle }, ["ana", "bob"])
        XCTAssertEqual(rows.dropFirst().map(\.id), receipt.turns.map(\.roomMessageID), "each turn owns its row")
        XCTAssertTrue(f.runner.requests.isEmpty, "the provider start is off the interaction turn")
        XCTAssertLessThan(acknowledged, 0.1, "user row plus waiting rows within 100 ms")

        // Sequential: Ana first, Bob only after Ana answered.
        let anaStarted = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(anaStarted)
        let anaRequest = try request(f, onThreadOf: f.ana, in: group)
        XCTAssertTrue(anaRequest.prompt.contains("ANA-SOUL"), "the bot's own brain compiles the turn")
        XCTAssertTrue(anaRequest.prompt.contains("Plan the launch"))
        XCTAssertNotEqual(anaRequest.threadId, group.roomThreadID, "the room never runs a provider")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(f.runner.requests.count, 1, "Bob waits for Ana")

        XCTAssertTrue(f.runner.finish(runID: anaRequest.runId, status: .completed, reply: "Ship it on Monday."))
        let bobStarted = await waitUntil { f.runner.requests.count == 2 }
        XCTAssertTrue(bobStarted)
        let bobRequest = try request(f, onThreadOf: f.bob, in: group)
        XCTAssertTrue(bobRequest.prompt.contains("Ship it on Monday."), "later bots see earlier replies of the round")
        XCTAssertTrue(bobRequest.prompt.contains("BOB-SOUL"))
        XCTAssertFalse(bobRequest.prompt.contains("ANA-SOUL"), "never another bot's brain")

        XCTAssertTrue(f.runner.finish(runID: bobRequest.runId, status: .completed, reply: "Monday is too soon."))
        let done = await waitUntil { (try? self.turns(f, group).allSatisfy { $0.state == .completed }) == true }
        XCTAssertTrue(done)

        // Replies replace the waiting rows in place: same ids, same positions.
        let settled = try room(f, group)
        XCTAssertEqual(settled.map(\.id), rows.map(\.id))
        XCTAssertEqual(settled.map(\.createdAt), rows.map(\.createdAt))
        XCTAssertEqual(BotPeerTranscript.parse(settled[1].content)?.body, "Ship it on Monday.")
        XCTAssertEqual(BotPeerTranscript.parse(settled[1].content)?.handle, "ana")
        XCTAssertEqual(BotPeerTranscript.parse(settled[2].content)?.body, "Monday is too soon.")

        // Exactly once: one event per room write, one per turn change.
        let eventsDone = await waitUntil { self.appendedIDs(log).count >= 5 }
        XCTAssertTrue(eventsDone)
        let ids = appendedIDs(log)
        XCTAssertEqual(ids.filter { $0 == receipt.userMessageID.value.uuidString }.count, 1)
        for turn in receipt.turns {
            XCTAssertEqual(ids.filter { $0 == turn.roomMessageID.value.uuidString }.count, 2, "waiting, then reply")
            XCTAssertEqual(turnStates(log, turn), ["planned", "running", "completed"])
        }

        // Member threads: locked to their bot, on the Mac for a non-VM bot.
        let anaThread = try XCTUnwrap(try f.ctx.threadRepo.get(id: try XCTUnwrap(try memberThread(f, group, f.ana))))
        XCTAssertEqual(anaThread.actor, .bot(f.ana.id))
        XCTAssertNotNil(anaThread.actorLockedAt)
        XCTAssertEqual(anaThread.executionTarget, .mac)
        XCTAssertNil(anaThread.workspaceId)
        XCTAssertTrue(try f.ctx.botStore.listConversations(botID: f.ana.id).isEmpty, "never in the bot's desk list")
    }

    // MARK: - D12

    func test_vmBotBusyInAnotherThreadWaitsPersistedThenStartsWhenTheVMIsFreed() async throws {
        let f = try makeFixture(anaDesktop: .dockerDesktop)
        let group = try await makeGroup(f, bots: [f.ana])
        let holder = BotVMRunRegistry.Entry(threadID: AgentThreadID(), runID: AgentRunID(), title: "Tarefa A", workspace: "")
        XCTAssertNil(BotVMRunRegistry.shared.tryBegin(botID: f.ana.id, entry: holder))
        defer { BotVMRunRegistry.shared.endRun(runID: holder.runID) }

        try f.orchestrator.send(groupID: group.id, text: "Check the VM")
        let waiting = await waitUntil { (try? self.turns(f, group).first?.state) == .waitingForBot }
        XCTAssertTrue(waiting, "a busy VM makes the turn wait, persisted")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(f.runner.requests.isEmpty, "no overlapping run on the VM")
        let thread = try XCTUnwrap(try memberThread(f, group, f.ana))
        XCTAssertEqual(try f.ctx.threadRepo.get(id: thread)?.executionTarget, .vm, "a Docker desktop bot runs on its VM")
        XCTAssertEqual(BotVMRunRegistry.shared.waitingThreads(botID: f.ana.id), [thread])
        XCTAssertEqual(BotVMRunRegistry.shared.active(botID: f.ana.id)?.runID, holder.runID)

        f.router.releaseBotVMRun(holder.runID)
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started, "the freed VM is handed to the waiting group turn")
        let request = try XCTUnwrap(f.runner.requests.first)
        XCTAssertEqual(request.threadId, thread)
        XCTAssertEqual(BotVMRunRegistry.shared.active(botID: f.ana.id)?.runID, request.runId, "the turn holds the VM")
        XCTAssertEqual(try turns(f, group).first?.state, .running)

        f.runner.finish(runID: request.runId, status: .completed, reply: "VM ok")
        let freed = await waitUntil { BotVMRunRegistry.shared.active(botID: f.ana.id) == nil }
        XCTAssertTrue(freed)
        let completed = await waitUntil { (try? self.turns(f, group).first?.state) == .completed }
        XCTAssertTrue(completed)
    }

    // MARK: - Relaunch

    func test_relaunchInterruptsTheRunningTurnAndResumesPlannedOnes() async throws {
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana, f.bob])
        let round = BotGroupRoundID()
        let user = AgentMessage(threadId: group.roomThreadID, role: .user, content: "Before the restart")
        try f.ctx.messageRepo.append(user)
        let wasRunning = BotGroupTurn(
            groupID: group.id, roundID: round, triggerMessageID: user.id, botID: f.ana.id, ordinal: 1, memberRunID: AgentRunID()
        )
        let planned = BotGroupTurn(groupID: group.id, roundID: round, triggerMessageID: user.id, botID: f.bob.id, ordinal: 2)
        try f.ctx.botStore.insertGroupTurns([wasRunning, planned])
        try f.ctx.botStore.transitionGroupTurn(
            id: wasRunning.id, from: [.planned], to: .running, memberRunID: try XCTUnwrap(wasRunning.memberRunID)
        )
        for (turn, bot) in [(wasRunning, f.ana), (planned, f.bob)] {
            try f.ctx.messageRepo.append(AgentMessage(
                id: turn.roomMessageID, threadId: group.roomThreadID, role: .assistant,
                content: BotPeerTranscript.encodeActivity(peer: bot, phase: .waiting)
            ))
        }

        f.orchestrator.reconcileAfterRelaunch()

        let interrupted = try XCTUnwrap(try f.ctx.botStore.groupTurn(id: wasRunning.id))
        XCTAssertEqual(interrupted.state, .interrupted, "never re-run automatically")
        XCTAssertEqual(
            BotPeerTranscript.parseActivity(try XCTUnwrap(try f.ctx.messageRepo.get(id: wasRunning.roomMessageID)).content)?.phase,
            .needsAttention
        )
        let resumed = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(resumed, "the planned turn resumes")
        XCTAssertEqual(try request(f, onThreadOf: f.bob, in: group).threadId, f.runner.requests.first?.threadId)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(f.runner.requests.count, 1, "the interrupted turn did not run")
        XCTAssertEqual(try f.ctx.botStore.groupTurn(id: wasRunning.id)?.state, .interrupted)
    }

    // MARK: - Stop

    func test_stopCancelsTheRunningAndPlannedTurnsAndALateFinishChangesNothing() async throws {
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana, f.bob])
        let (log, subscription) = recordEvents(roomThreadID: group.roomThreadID)
        defer { EventBus.shared.unsubscribe(subscription) }
        let receipt = try f.orchestrator.send(groupID: group.id, text: "Long task")
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started)

        f.orchestrator.stop(groupID: group.id)

        let all = try turns(f, group)
        XCTAssertEqual(all.map(\.state), [.cancelled, .cancelled])
        for turn in all {
            let row = try XCTUnwrap(try f.ctx.messageRepo.get(id: turn.roomMessageID))
            XCTAssertEqual(row.role, .system, "no waiting row keeps spinning")
            XCTAssertNil(BotPeerTranscript.parseActivity(row.content))
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(f.runner.requests.count, 1, "Bob never starts")
        XCTAssertEqual(try turns(f, group).map(\.state), [.cancelled, .cancelled], "the stopped run's finish settles nothing")
        XCTAssertEqual(turnStates(log, receipt.turns[0]), ["planned", "running", "cancelled"])
        XCTAssertEqual(turnStates(log, receipt.turns[1]), ["planned", "cancelled"])
    }

    // MARK: - Stale finish

    func test_aFinishOfAnotherRunOnTheMemberThreadChangesNothing() async throws {
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana])
        let receipt = try f.orchestrator.send(groupID: group.id, text: "Hello")
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started)
        let thread = try XCTUnwrap(try memberThread(f, group, f.ana))
        let rowBefore = try f.ctx.messageRepo.get(id: receipt.turns[0].roomMessageID)

        f.orchestrator.settle(runID: AgentRunID(), threadID: thread, status: .completed, finalMessage: "stale reply")

        XCTAssertEqual(try turns(f, group).first?.state, .running)
        XCTAssertEqual(try f.ctx.messageRepo.get(id: receipt.turns[0].roomMessageID), rowBefore)
        f.runner.finish(runID: try XCTUnwrap(f.runner.requests.first).runId, status: .completed, reply: "real reply")
        let done = await waitUntil { (try? self.turns(f, group).first?.state) == .completed }
        XCTAssertTrue(done)
        XCTAssertEqual(
            BotPeerTranscript.parse(try XCTUnwrap(try f.ctx.messageRepo.get(id: receipt.turns[0].roomMessageID)).content)?.body,
            "real reply"
        )
    }

    // MARK: - Failure

    func test_aFailedTurnShowsNeedsAttentionAndTheRoundContinues() async throws {
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana, f.bob])
        let receipt = try f.orchestrator.send(groupID: group.id, text: "Try it")
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started)
        f.runner.finish(runID: try XCTUnwrap(f.runner.requests.first).runId, status: .failed, reply: nil)

        let next = await waitUntil { f.runner.requests.count == 2 }
        XCTAssertTrue(next, "the next bot still answers")
        let failed = try XCTUnwrap(try f.ctx.botStore.groupTurn(id: receipt.turns[0].id))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertNotNil(failed.error, "the failure keeps its reason")
        XCTAssertEqual(
            BotPeerTranscript.parseActivity(try XCTUnwrap(try f.ctx.messageRepo.get(id: failed.roomMessageID)).content)?.phase,
            .needsAttention
        )
        f.runner.finish(runID: try XCTUnwrap(f.runner.requests.last).runId, status: .completed, reply: "done")
    }

    // MARK: - Supersede (A -> B)

    func test_aNewMessageCancelsTheOldRoundsUnstartedTurnsAndRunsAfterTheRunningOne() async throws {
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana, f.bob])
        let first = try f.orchestrator.send(groupID: group.id, text: "First question")
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started)

        let second = try f.orchestrator.send(groupID: group.id, text: "@bob only you, second question")

        XCTAssertEqual(try f.ctx.botStore.groupTurn(id: first.turns[1].id)?.state, .cancelled, "Bob's old turn is dropped")
        XCTAssertEqual(try f.ctx.botStore.groupTurn(id: first.turns[0].id)?.state, .running, "Ana finishes first")
        XCTAssertEqual(second.turns.map(\.botID), [f.bob.id])
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(f.runner.requests.count, 1, "the new round waits for the running turn")

        f.runner.finish(runID: try XCTUnwrap(f.runner.requests.first).runId, status: .completed, reply: "Answer one")
        let bobStarted = await waitUntil { f.runner.requests.count == 2 }
        XCTAssertTrue(bobStarted)
        let bobRequest = try XCTUnwrap(f.runner.requests.last)
        XCTAssertTrue(bobRequest.prompt.contains("second question"), "the newest round runs, not the stale one")
        f.runner.finish(runID: bobRequest.runId, status: .completed, reply: "Answer two")
        let done = await waitUntil { (try? f.ctx.botStore.groupTurn(id: second.turns[0].id)?.state) == .completed }
        XCTAssertTrue(done)
        XCTAssertEqual(f.runner.requests.count, 2, "the cancelled turn never runs")
    }

    func test_theSameBotAnswersBackToBackTurnsOnItsOneMemberThread() async throws {
        // WHY: a new round right after the bot's previous turn reuses its member
        // thread; it must start, not be refused as busy or queued as user text.
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana, f.bob])
        try f.orchestrator.send(groupID: group.id, text: "Round one")
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started)
        let again = try f.orchestrator.send(groupID: group.id, text: "@ana once more")

        f.runner.finish(runID: try XCTUnwrap(f.runner.requests.first).runId, status: .completed, reply: "One")
        let second = await waitUntil { f.runner.requests.count == 2 }
        XCTAssertTrue(second, "the next turn of the same bot starts right after its finish")
        let requests = f.runner.requests
        XCTAssertEqual(requests[0].threadId, requests[1].threadId, "one member thread per bot and group")
        XCTAssertTrue(requests[1].prompt.contains("once more"))
        XCTAssertEqual(try f.ctx.botStore.groupTurn(id: again.turns[0].id)?.state, .running)
        let threadID = try XCTUnwrap(requests.first?.threadId)
        XCTAssertTrue(try f.ctx.queuedMessageRepo.list(threadId: threadID).isEmpty, "nothing queued as user text")
        f.runner.finish(runID: requests[1].runId, status: .completed, reply: "Two")
        let done = await waitUntil { (try? f.ctx.botStore.groupTurn(id: again.turns[0].id)?.state) == .completed }
        XCTAssertTrue(done)
    }

    // MARK: - Hand-offs

    func test_aReplyMentioningParticipantsHandsThemTheFloorUpToTheHopBudget() async throws {
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana, f.bob, f.cid], policy: .lead, lead: f.ana.id, hops: 1)
        try f.orchestrator.send(groupID: group.id, text: "Kick off")
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(f.runner.requests.first?.threadId, try memberThread(f, group, f.ana), "lead answers alone")

        f.runner.finish(
            runID: try XCTUnwrap(f.runner.requests.first).runId,
            status: .completed,
            reply: "@bob please review, then @cid."
        )
        let bobStarted = await waitUntil { f.runner.requests.count == 2 }
        XCTAssertTrue(bobStarted)
        XCTAssertEqual(f.runner.requests.last?.threadId, try memberThread(f, group, f.bob))
        let handOff = try XCTUnwrap(try turns(f, group).first { $0.botID == f.bob.id })
        XCTAssertEqual(handOff.hop, 1)
        XCTAssertFalse(try turns(f, group).contains { $0.botID == f.cid.id }, "over the budget")
        let note = try room(f, group).last { $0.role == .system }
        XCTAssertTrue(note?.content.contains("@cid did not answer") == true, note?.content ?? "no paused note")
        f.runner.finish(runID: try XCTUnwrap(f.runner.requests.last).runId, status: .completed, reply: "Reviewed.")
    }

    // MARK: - Idempotency and refusals

    func test_aRetriedSendWithTheSameSubmitKeyReturnsTheFirstReceipt() async throws {
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana])
        let first = try f.orchestrator.send(groupID: group.id, text: "Once", submitKey: "same")
        let retry = try f.orchestrator.send(groupID: group.id, text: "Once", submitKey: "same")
        XCTAssertEqual(retry.roundID, first.roundID)
        XCTAssertEqual(retry.userMessageID, first.userMessageID)
        XCTAssertEqual(retry.turns.map(\.id), first.turns.map(\.id))
        XCTAssertEqual(try room(f, group).filter { $0.role == .user }.count, 1)
        XCTAssertEqual(try turns(f, group).count, 1)
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started)
        f.runner.finish(runID: try XCTUnwrap(f.runner.requests.first).runId, status: .completed, reply: "ok")
    }

    func test_refusedSendsWriteNothing() async throws {
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana, f.bob], policy: .mentionsOnly)
        XCTAssertThrowsError(try f.orchestrator.send(groupID: group.id, text: "no mention")) { error in
            XCTAssertEqual(error as? BotGroupOrchestrator.SendError, .rejected(BotGroupTurnPlanner.Rejection.mentionRequired.message))
        }
        let attachment = AgentAttachment(path: "/tmp/a.txt", kind: .file)
        XCTAssertThrowsError(try f.orchestrator.send(groupID: group.id, text: "@ana see file", attachments: [attachment])) { error in
            XCTAssertEqual(error as? BotGroupOrchestrator.SendError, .attachmentsUnsupported)
        }
        XCTAssertTrue(try room(f, group).isEmpty)
        XCTAssertTrue(try turns(f, group).isEmpty)
    }

    func test_theRoomThreadRefusesProviderSends() async throws {
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana])
        do {
            _ = try await f.router.sendAgentMessage(
                thread: group.roomThreadID, text: "direct", provider: .codex,
                model: BotsViewModel.defaultModel(for: .codex), permissionMode: .supervised, reasoningEffort: .medium
            )
            XCTFail("a room send must go through the group")
        } catch {}
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(f.runner.requests.isEmpty)
        XCTAssertTrue(try room(f, group).isEmpty)
    }
}
