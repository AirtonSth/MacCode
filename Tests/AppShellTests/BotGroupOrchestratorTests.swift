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
        let support: String
        @MainActor var orchestrator: BotGroupOrchestrator { ctx.botGroupOrchestrator }
    }

    private func makeFixture(anaDesktop: BotDesktopKind = .logicalExecutionSpace) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2BotGroup-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true).path
        let (ctx, router, runner) = try openContext(support: support)
        let ana = try ctx.botStore.create(
            name: "Ana", title: "Writer", description: "", handle: "ana", soul: "ANA-SOUL", desktopKind: anaDesktop
        )
        let bob = try ctx.botStore.create(name: "Bob", title: "Critic", description: "", handle: "bob", soul: "BOB-SOUL")
        let cid = try ctx.botStore.create(name: "Cid", title: "", description: "", handle: "cid", soul: "CID-SOUL")
        return Fixture(ctx: ctx, router: router, runner: runner, ana: ana, bob: bob, cid: cid, support: support)
    }

    /// An app context on `support` with a controllable Codex runner. A second
    /// call on the same `support` is a relaunch (or a helper) on the same DB.
    private func openContext(
        support: String,
        performLaunchRunReconciliation: Bool = true
    ) throws -> (AppContext, AppCommandRouter, ControlledBotHandoffRunner) {
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: support,
            performLaunchRunReconciliation: performLaunchRunReconciliation
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
        return (ctx, router, runner)
    }

    /// A previous launch's state: Ana's turn was running (its run is gone)
    /// and Bob's was planned, each with its waiting row.
    private func seedInterruptedRound(
        _ f: Fixture, _ group: BotGroupConversation
    ) throws -> (wasRunning: BotGroupTurn, planned: BotGroupTurn) {
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
        return (wasRunning, planned)
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
            // iOS and agent.message.get must agree on the replaced row's revision.
            let revisions = log.events
                .filter { $0.payload["id"]?.objectValue?["value"]?.stringValue == turn.roomMessageID.value.uuidString }
                .compactMap { $0.payload["body_revision"]?.intValue }
            XCTAssertEqual(revisions, [1, 2], "the reply event carries the stored revision of the replaced row")
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

    /// WHY: the VM hand-off starts the next thread (Docker preflight, guest
    /// launch) and can take minutes. The run that just ended must publish its
    /// terminal events at once, so iOS and the desk never keep showing it as
    /// running while the next thread's VM start is still in flight.
    func test_aFinishedRunPublishesItsTerminalEventsBeforeTheVMHandOffFinishes() async throws {
        let f = try makeFixture(anaDesktop: .dockerDesktop)
        let gate = PreflightGate()
        f.orchestrator.vmPreflight = { _ in await gate.wait() }
        let group = try await makeGroup(f, bots: [f.ana])
        let holderThread = AgentThreadID()
        let holder = BotVMRunRegistry.Entry(threadID: holderThread, runID: AgentRunID(), title: "Tarefa A", workspace: "")
        XCTAssertNil(BotVMRunRegistry.shared.tryBegin(botID: f.ana.id, entry: holder))
        defer { BotVMRunRegistry.shared.endRun(runID: holder.runID) }

        try f.orchestrator.send(groupID: group.id, text: "Check the VM")
        let waiting = await waitUntil { (try? self.turns(f, group).first?.state) == .waitingForBot }
        XCTAssertTrue(waiting, "a busy VM makes the turn wait")

        let finished = EventLog()
        let runID = holder.runID.value.uuidString.lowercased()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "agent.run.finished" || event.kind == "agent.run.completed",
                  event.payload.objectValue?["run_id"]?.stringValue == runID else { return }
            finished.append(event.kind, [:])
        }
        defer { EventBus.shared.unsubscribe(subscription) }

        f.ctx.coordinator.onRunFinished?(holderThread, holder.runID, .completed)
        let handOffStarted = await waitUntil { gate.entered }
        XCTAssertTrue(handOffStarted, "the freed VM is handed to the waiting group turn")
        let published = await waitUntil(timeout: 2) { finished.events.count == 2 }
        XCTAssertTrue(published, "the finished run's terminal events never wait on the next thread's VM start")

        gate.release()
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started, "the hand-off still starts the waiting turn")
        if let request = f.runner.requests.first {
            f.runner.finish(runID: request.runId, status: .completed, reply: "VM ok")
            _ = await waitUntil { (try? self.turns(f, group).first?.state) == .completed }
        }
    }

    @MainActor
    private final class PreflightGate {
        private(set) var entered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async -> String? {
            entered = true
            if !released {
                await withCheckedContinuation { continuation = $0 }
            }
            return nil
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    // MARK: - Relaunch

    func test_relaunchInterruptsTheRunningTurnAndResumesPlannedOnes() async throws {
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana, f.bob])
        let (wasRunning, _) = try seedInterruptedRound(f, group)

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

    func test_aRetriedTurnReadsTheMessagesItsFailedRunNeverAnswered() async throws {
        // WHY: the watermark marks what the bot has answered. A failed run
        // answered nothing, so Retry must show the user's message again instead
        // of "no new messages"; only a completed turn moves the watermark.
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana])
        let receipt = try f.orchestrator.send(groupID: group.id, text: "Summarize the launch plan")
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started)
        f.runner.finish(runID: try XCTUnwrap(f.runner.requests.first).runId, status: .failed, reply: nil)
        let failed = await waitUntil { (try? f.ctx.botStore.groupTurn(id: receipt.turns[0].id)?.state) == .failed }
        XCTAssertTrue(failed)

        try f.orchestrator.retry(turnID: receipt.turns[0].id, groupID: group.id)

        let retried = await waitUntil { f.runner.requests.count == 2 }
        XCTAssertTrue(retried)
        let retryPrompt = try XCTUnwrap(f.runner.requests.last).prompt
        XCTAssertTrue(retryPrompt.contains("Summarize the launch plan"), "the retry still sees the unanswered message")
        XCTAssertFalse(retryPrompt.contains("There are no new messages in the group since your last turn."))

        f.runner.finish(runID: try XCTUnwrap(f.runner.requests.last).runId, status: .completed, reply: "Here it is")
        let done = await waitUntil { (try? f.ctx.botStore.groupTurn(id: receipt.turns[0].id)?.state) == .completed }
        XCTAssertTrue(done)
        try f.orchestrator.send(groupID: group.id, text: "Thanks, now the budget")
        let next = await waitUntil { f.runner.requests.count == 3 }
        XCTAssertTrue(next)
        let nextPrompt = try XCTUnwrap(f.runner.requests.last).prompt
        XCTAssertTrue(nextPrompt.contains("now the budget"))
        XCTAssertFalse(nextPrompt.contains("Summarize the launch plan"), "a completed turn moves the watermark")
        f.runner.finish(runID: try XCTUnwrap(f.runner.requests.last).runId, status: .completed, reply: "Budget")
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

    // MARK: - Shared-DB helper and restart ordering

    func test_aSharedDatabaseHelperNeverInterruptsOrStartsGroupTurns() async throws {
        // WHY: the Scheduled Task Agent opens the same SQLite on its own. If it
        // reconciled, it would interrupt the app's live turn (losing its reply)
        // and run the planned ones in a process that is not the app.
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana, f.bob])
        let (wasRunning, planned) = try seedInterruptedRound(f, group)

        let (helper, _, helperRunner) = try openContext(support: f.support, performLaunchRunReconciliation: false)
        helper.reconcileBotGroupsAfterLaunch()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(try f.ctx.botStore.groupTurn(id: wasRunning.id)?.state, .running, "the app still owns it")
        XCTAssertEqual(try f.ctx.botStore.groupTurn(id: planned.id)?.state, .planned)
        XCTAssertEqual(
            BotPeerTranscript.parseActivity(try XCTUnwrap(try f.ctx.messageRepo.get(id: wasRunning.roomMessageID)).content)?.phase,
            .waiting
        )
        XCTAssertTrue(helperRunner.requests.isEmpty, "the helper starts no group turn")
        XCTAssertTrue(f.runner.requests.isEmpty)
    }

    func test_aRestartReconcilesOnlyAfterTheEventLogIsRestoredAndPersistsItsEvents() async throws {
        // WHY: iOS resumes from its event cursor. Reconcile events published
        // before the log is wired are lost, or numbered below what iOS saw.
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana, f.bob])
        let (wasRunning, planned) = try seedInterruptedRound(f, group)

        let (relaunched, _, runner) = try openContext(support: f.support)
        XCTAssertEqual(
            try relaunched.botStore.groupTurn(id: wasRunning.id)?.state, .running,
            "assigning the router reconciles nothing: the event log is not wired yet"
        )

        let bus = EventBus.shared
        let previousRetain = bus.shouldRetainRecentEvent
        let previousStandIn = bus.recentReplayStandIn
        AppDelegate.wireEventPersistence(context: relaunched)
        defer {
            bus.persister = nil
            bus.persistenceCommitFence = nil
            bus.shouldRetainRecentEvent = previousRetain
            bus.recentReplayStandIn = previousStandIn
        }
        // The previous session numbered its events past this process's bus.
        let previousSessionSeq = bus.currentSeq + 500
        try relaunched.eventLog.appendBatch([
            EventLogRepository.PendingRow(seq: previousSessionSeq, kind: "test.previous.session", payloadJSON: "{}")
        ])
        let restored = try relaunched.eventLog.lastSeq()
        bus.reloadFromPersistence(lastSeq: restored, recent: [])

        relaunched.reconcileBotGroupsAfterLaunch()
        relaunched.flushEventPersistence()

        XCTAssertEqual(try relaunched.botStore.groupTurn(id: wasRunning.id)?.state, .interrupted)
        let rows = try relaunched.eventLog.read(since: restored, limit: 1_000)
        let turnRow = try XCTUnwrap(rows.first { row in
            row.kind == "bot.group.turn.updated"
                && row.payloadJSON.contains(wasRunning.id.value.uuidString.lowercased())
                && row.payloadJSON.contains("interrupted")
        }, "the interrupted turn event is in the persisted log")
        XCTAssertGreaterThan(turnRow.seq, restored)
        let roomRow = try XCTUnwrap(rows.first { row in
            row.kind == "agent.message.appended" && row.payloadJSON.contains(wasRunning.roomMessageID.value.uuidString)
        }, "the needs-attention row event is in the persisted log")
        XCTAssertGreaterThan(roomRow.seq, restored)

        let resumed = await waitUntil { runner.requests.count == 1 }
        XCTAssertTrue(resumed, "the planned turn resumes in the relaunched app")
        runner.finish(runID: try XCTUnwrap(runner.requests.first).runId, status: .completed, reply: "Back")
        let done = await waitUntil { (try? relaunched.botStore.groupTurn(id: planned.id)?.state) == .completed }
        XCTAssertTrue(done)
    }

    // MARK: - Bot deleted mid-round

    func test_deletingABotMidRoundLetsTheNextParticipantAnswerAndLeavesNoWaitingRow() async throws {
        // WHY: deleting a bot drops its member conversation. Its running turn
        // must not stay running forever (that blocks the whole group), and its
        // unstarted turns must not keep spinning rows.
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana, f.bob, f.cid])
        let (log, subscription) = recordEvents(roomThreadID: group.roomThreadID)
        defer { EventBus.shared.unsubscribe(subscription) }
        let receipt = try f.orchestrator.send(groupID: group.id, text: "Who goes first?")
        let anaStarted = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(anaStarted)

        try f.ctx.botStore.delete(id: f.ana.id)

        let bobStarted = await waitUntil { f.runner.requests.count == 2 }
        XCTAssertTrue(bobStarted, "the next participant answers")
        XCTAssertEqual(f.runner.requests.last?.threadId, try memberThread(f, group, f.bob))
        XCTAssertEqual(try f.ctx.botStore.groupTurn(id: receipt.turns[0].id)?.state, .cancelled)

        try f.ctx.botStore.delete(id: f.cid.id)
        let cidSettled = await waitUntil {
            (try? f.ctx.messageRepo.get(id: receipt.turns[2].roomMessageID))??.role == .system
        }
        XCTAssertTrue(cidSettled, "a deleted bot's planned turn settles its row")

        f.runner.finish(runID: try XCTUnwrap(f.runner.requests.last).runId, status: .completed, reply: "Me.")
        let done = await waitUntil { (try? f.ctx.botStore.groupTurn(id: receipt.turns[1].id)?.state) == .completed }
        XCTAssertTrue(done)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(f.runner.requests.count, 2, "no deleted bot runs")
        for row in try room(f, group) {
            XCTAssertNotEqual(BotPeerTranscript.parseActivity(row.content)?.phase, .waiting, "no row keeps spinning")
        }
        XCTAssertEqual(try room(f, group).first { $0.id == receipt.turns[0].roomMessageID }?.content.contains("Ana"), true)
        XCTAssertEqual(turnStates(log, receipt.turns[0]), ["planned", "running", "cancelled"])
        XCTAssertEqual(turnStates(log, receipt.turns[2]), ["planned", "cancelled"])
    }

    // MARK: - Atomic writes

    func test_aSendWhoseRoomWriteFailsLeavesNoTurnsBehind() async throws {
        // WHY: turns persisted without the user's line would make the bots
        // answer, after a relaunch, a message the room never showed.
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana])
        try f.ctx.db.execute("""
            CREATE TRIGGER test_fail_user_row BEFORE INSERT ON agent_messages
            WHEN NEW.role = 'user' BEGIN SELECT RAISE(ABORT, 'disk full'); END;
            """)
        XCTAssertThrowsError(try f.orchestrator.send(groupID: group.id, text: "Lost?"))
        XCTAssertTrue(try turns(f, group).isEmpty, "the turns rolled back with the row")
        XCTAssertTrue(try room(f, group).isEmpty)

        try f.ctx.db.execute("DROP TRIGGER test_fail_user_row;")
        let receipt = try f.orchestrator.send(groupID: group.id, text: "Now it works")
        XCTAssertEqual(try room(f, group).map(\.id), [receipt.userMessageID, receipt.turns[0].roomMessageID])
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started)
        f.runner.finish(runID: try XCTUnwrap(f.runner.requests.first).runId, status: .completed, reply: "ok")
    }

    func test_aSettleWhoseRowWriteFailsKeepsTheTurnAndRowTogetherUntilReconcile() async throws {
        // WHY: a turn shown as answered must have its reply row. When the row
        // cannot be written, the turn keeps running with its waiting row, and
        // the next launch interrupts both together instead of losing the row.
        let f = try makeFixture()
        let group = try await makeGroup(f, bots: [f.ana])
        let receipt = try f.orchestrator.send(groupID: group.id, text: "Hello")
        let started = await waitUntil { f.runner.requests.count == 1 }
        XCTAssertTrue(started)
        try f.ctx.db.execute("""
            CREATE TRIGGER test_fail_row_update BEFORE UPDATE ON agent_messages
            BEGIN SELECT RAISE(ABORT, 'disk full'); END;
            """)
        f.runner.finish(runID: try XCTUnwrap(f.runner.requests.first).runId, status: .completed, reply: "Hi")
        let finished = await waitUntil {
            f.ctx.coordinator.activeRunId(threadId: (try? self.memberThread(f, group, f.ana)) ?? AgentThreadID()) == nil
        }
        XCTAssertTrue(finished)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(try f.ctx.botStore.groupTurn(id: receipt.turns[0].id)?.state, .running)
        XCTAssertEqual(
            BotPeerTranscript.parseActivity(try XCTUnwrap(try f.ctx.messageRepo.get(id: receipt.turns[0].roomMessageID)).content)?.phase,
            .waiting
        )

        try f.ctx.db.execute("DROP TRIGGER test_fail_row_update;")
        f.orchestrator.reconcileAfterRelaunch()
        XCTAssertEqual(try f.ctx.botStore.groupTurn(id: receipt.turns[0].id)?.state, .interrupted)
        XCTAssertEqual(
            BotPeerTranscript.parseActivity(try XCTUnwrap(try f.ctx.messageRepo.get(id: receipt.turns[0].roomMessageID)).content)?.phase,
            .needsAttention
        )
    }

    // MARK: - Plan A guest

    func test_aDistillBotOnItsVMAnswersInsideItsGuest() async throws {
        // WHY (plan A): a Docker-desktop bot on Distill runs inside its own
        // Linux guest from its first group turn, with the guest's rules.
        AgentProvider.selectableForTesting = [.distill] + AgentProvider.allCases.filter { $0 != .distill }
        defer { AgentProvider.selectableForTesting = AgentProvider.allCases }
        let f = try makeFixture(anaDesktop: .dockerDesktop)
        let distill = ControlledBotHandoffRunner(provider: .distill)
        f.ctx.coordinator.replaceProviderAdapter(.distill, adapter: TerminalRetiringOneShotAdapter(runner: distill))
        f.router.rememberProviderSnapshotsForSend([
            AgentProviderSnapshotFactory.snapshot(
                provider: .distill,
                models: [AgentModelDescriptor(id: "main-a", label: "Main A", provider: .distill)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: "distill"
            )
        ])
        let group = try await makeGroup(f, bots: [f.ana])
        try f.orchestrator.send(groupID: group.id, text: "Check the guest")
        let started = await waitUntil { distill.requests.count == 1 }
        XCTAssertTrue(started)

        let thread = try XCTUnwrap(try memberThread(f, group, f.ana))
        let placement = try XCTUnwrap(try f.ctx.threadRepo.guestPlacement(of: thread))
        XCTAssertEqual(placement.executionTarget, .vm)
        XCTAssertTrue(placement.runsInGuest, "the plan-A guest marker is set on the member thread")
        let request = try XCTUnwrap(distill.requests.first)
        XCTAssertEqual(request.threadId, thread)
        XCTAssertTrue(request.prompt.contains(BotStandingInstructions.guestThreadRules), "the guest's rules, not the VM-shell ones")
        XCTAssertTrue(f.runner.requests.isEmpty)
        distill.finish(runID: request.runId, status: .completed, reply: "Guest ok")
        let done = await waitUntil { (try? self.turns(f, group).first?.state) == .completed }
        XCTAssertTrue(done)
    }
}
