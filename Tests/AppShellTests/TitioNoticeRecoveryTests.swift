import XCTest
import CoreModel
import SocketServer
@testable import AppShell
@testable import Persistence

/// Review fixes for the notice hub: repeat occurrences, the kill switch on
/// the hub's own producers, startup recovery of rows no live task owns,
/// retention of open cards, startup catch-up, the fail-loud fallback, the
/// attention backlog, latest-wins inbox snapshots and the iOS bot route.
final class TitioNoticeRecoveryTests: XCTestCase {
    private struct Fixture {
        let db: SQLiteDB
        let path: String
        let repo: TitioNoticeRepository
        let messages: AgentMessageRepository
        let store: BotStore
        let target: TitioInboxTarget
        let scheduler: ManualTitioScheduler
        let recorder: TitioHookRecorder
        let actions: TitioActionRecorder
        let center: TitioNoticeCenter
    }

    private let requestThread = AgentThreadID()

    private func makeFixture(
        path existing: String? = nil,
        available: Bool = true,
        onPosted: (@Sendable (TitioNoticePostedMessage) -> Void)? = nil
    ) throws -> Fixture {
        let path = existing ?? NSTemporaryDirectory() + "titio-recovery-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: path).run()
        let store = BotStore(db: db)
        let repo = TitioNoticeRepository(db: db)
        let target: TitioInboxTarget
        if let raw = try repo.inboxState().conversationID, let uuid = UUID(uuidString: raw),
           let conversation = try store.conversation(id: BotConversationID(uuid)),
           let thread = conversation.linkedAgentThreadID {
            target = TitioInboxTarget(botID: conversation.botID, conversationID: conversation.id, threadID: thread)
        } else {
            let bot = try store.create(name: "Titio", title: "", description: "", handle: "titio")
            let thread = AgentThread(title: "Notifications", provider: .distill, model: "m")
            try AgentThreadRepository(db: db).upsert(thread)
            let conversation = BotConversation(botID: bot.id, title: "Notifications", linkedAgentThreadID: thread.id)
            try store.upsertConversation(conversation)
            try repo.updateInboxState { $0.conversationID = conversation.id.value.uuidString.lowercased() }
            target = TitioInboxTarget(botID: bot.id, conversationID: conversation.id, threadID: thread.id)
        }
        let recorder = TitioHookRecorder()
        recorder.target = available ? target : nil
        var hooks = recorder.hooks()
        if let onPosted {
            let base = hooks.messagePosted
            hooks.messagePosted = { posted in
                await base(posted)
                onPosted(posted)
            }
        }
        let scheduler = ManualTitioScheduler()
        let center = TitioNoticeCenter(
            db: db, botStore: store, hooks: hooks, scheduler: scheduler,
            voice: FakeTitioVoice.fixture,
            now: { scheduler.now }, timeZone: TimeZone(identifier: "UTC")!
        )
        let actions = TitioActionRecorder()
        center.installActions(actions.hooks())
        return Fixture(db: db, path: path, repo: repo, messages: AgentMessageRepository(db: db), store: store,
                       target: target, scheduler: scheduler, recorder: recorder, actions: actions, center: center)
    }

    private func approval(_ request: String, run: String = "R1", _ f: Fixture) -> TitioNoticeFact {
        let facts = TitioNoticeFacts(title: "Deploy", workspaceName: "api", detail: "rm -rf build", requestKind: "commandExecution")
        return TitioNoticeFact(
            key: TitioNoticeIDs.threadAttention(threadId: requestThread.value.uuidString, requestId: request, runId: run),
            kind: .approval,
            source: TitioNoticeSource(threadId: requestThread.value.uuidString, runId: run, requestId: request),
            facts: facts,
            actions: TitioNoticeAction.defaultActions(kind: .approval, facts: facts),
            occurredAt: f.scheduler.now
        )
    }

    private func sshEvent(_ seq: Int64, surface: String, status: String, reason: String? = nil, _ f: Fixture) -> EventBus.Event {
        var payload: [String: JSONValue] = ["surface_id": .string(surface), "status": .string(status), "name": .string("prod")]
        if let reason { payload["reason"] = .string(reason) }
        return EventBus.Event(seq: seq, kind: "ssh.session.updated", payload: .object(payload),
                              ts: f.scheduler.now.timeIntervalSince1970)
    }

    private func gitFailure(_ seq: Int64, workspace: String = UUID().uuidString, _ f: Fixture) -> EventBus.Event {
        EventBus.Event(seq: seq, kind: "git.push",
                       payload: .object(["workspace_id": .string(workspace), "ok": .bool(false)]),
                       ts: f.scheduler.now.timeIntervalSince1970)
    }

    private func transcript(_ f: Fixture) throws -> [AgentMessage] {
        try f.messages.list(threadId: f.target.threadID)
    }

    private func settle(_ f: Fixture) async {
        await f.center.settleActs()
        await f.center.idle()
    }

    private func setHub(_ enabled: Bool, _ f: Fixture, mute workspace: String? = nil) {
        let store = SettingsStore(db: f.db)
        var settings = store.load()
        settings.titioNotificationsEnabled = enabled
        if let workspace { settings.notificationMutedWorkspaceIDs = [workspace] }
        store.save(settings)
    }

    // MARK: 1. Repeat occurrences

    func test_aSecondSSHDropAfterAFlapPostsAgain() async throws {
        // WHY: a finished row is frozen. Keyed by the surface alone, a real
        // outage an hour after a 3 s flap hit the dropped row and posted
        // nothing for 30 days.
        let f = try makeFixture()
        let surface = UUID().uuidString
        f.center.handleEvent(sshEvent(10, surface: surface, status: "disconnected", reason: "unexpected_child_exit", f))
        await f.scheduler.advance(by: 3, center: f.center)
        f.center.handleEvent(sshEvent(11, surface: surface, status: "connected", f))
        await f.scheduler.advance(by: 10, center: f.center)
        XCTAssertTrue(try transcript(f).isEmpty, "the flap stays silent")

        f.center.handleEvent(sshEvent(20, surface: surface, status: "disconnected", reason: "connection_failed", f))
        await f.scheduler.advance(by: TitioNoticeTiming.flapHold, center: f.center)
        XCTAssertEqual(try transcript(f).count, 1, "the real drop posts")
        XCTAssertEqual(f.recorder.banners.count, 1)

        // A reconnect resolves the posted occurrence by its source key, and a
        // third drop posts again.
        f.center.handleEvent(sshEvent(21, surface: surface, status: "connected", f))
        await f.center.idle()
        let base = TitioNoticeIDs.petSSHDisconnect(surfaceId: surface)
        XCTAssertTrue(try f.repo.openKeys(prefix: base).isEmpty, "the reconnect resolved it")
        f.center.handleEvent(sshEvent(30, surface: surface, status: "disconnected", reason: "connection_failed", f))
        await f.scheduler.advance(by: TitioNoticeTiming.flapHold, center: f.center)
        XCTAssertEqual(f.recorder.banners.count, 2)
    }

    // MARK: 13. Recycled request ids

    func test_aRecycledRequestIdExpiresTheOldCardAndPostsTheNewRequest() async throws {
        // WHY: provider request ids restart after a provider or app restart.
        // Keyed by thread + id alone, the new request was silently dropped
        // (no message, banner or push) and a tap on the old card approved it.
        let f = try makeFixture()
        let old = approval("2", run: "RUN-A", f)
        f.center.ingest(old)
        await f.center.idle()
        let fresh = approval("2", run: "RUN-B", f)
        f.center.ingest(fresh)
        await f.center.idle()

        XCTAssertEqual(try f.repo.get(key: old.key)?.state, .resolved)
        XCTAssertEqual(try f.repo.get(key: old.key)?.resolution, .expired)
        XCTAssertEqual(try f.repo.get(key: fresh.key)?.state, .posted, "the new request reaches the user")
        let oldMessage = try XCTUnwrap(f.messages.get(id: AgentMessageID(TitioNoticeIDs.messageID(forKey: old.key))))
        XCTAssertNil(BotChoicesBlock.parse(oldMessage.content).choices, "the stale card is gone")
        let staleTap = f.center.actNow(messageID: TitioNoticeIDs.messageID(forKey: old.key).uuidString, optionIndex: 0)
        XCTAssertEqual(staleTap, .alreadyResolved)
        await settle(f)
        XCTAssertEqual(f.actions.calls, [], "the old card never answers the new request")

        // A resolution names the request, not the occurrence.
        f.center.sourceResolved(key: TitioNoticeIDs.threadAttention(threadId: requestThread.value.uuidString, requestId: "2"))
        await f.center.idle()
        XCTAssertEqual(try f.repo.get(key: fresh.key)?.state, .resolved)
    }

    // MARK: 2 / 37. Kill switch and gates on the hub's own producers

    func test_killSwitchOffSilencesPetEventsAndHookRacesPostTodaysBanner() async throws {
        // WHY (§0.5): with "Titio delivers notifications" off, a failed git
        // push used to still post a Titio message, banner and push.
        let f = try makeFixture()
        setHub(false, f)
        f.center.handleEvent(gitFailure(42, f))
        await f.center.idle()
        XCTAssertNil(try f.repo.get(key: "pet.event.42"))
        XCTAssertTrue(f.recorder.banners.isEmpty)

        // A hook that checked the switch just before it flipped: today's banner, as is.
        let legacy = RemoteCodeNotificationContent(
            identifier: "run.X.failed", title: "Run failed", body: "A run failed.",
            categoryIdentifier: "", threadIdentifier: "", userInfo: [:], soundEnabled: true
        )
        f.center.ingest(TitioNoticeFact(key: "run.X.failed", kind: .runFailed),
                        legacy: TitioNoticeLegacyDelivery(content: legacy, pushes: false))
        await f.center.idle()
        XCTAssertNil(try f.repo.get(key: "run.X.failed"))
        XCTAssertEqual(f.recorder.banners.map(\.identifier), ["run.X.failed"])
        XCTAssertEqual(f.recorder.banners.first?.title, "Run failed")
    }

    func test_mutedWorkspaceSilencesPetEvents() async throws {
        // WHY (§2): workspace mutes gate every notice before ingest.
        let f = try makeFixture()
        let workspace = UUID().uuidString
        setHub(true, f, mute: workspace)
        f.center.handleEvent(gitFailure(7, workspace: workspace, f))
        await f.center.idle()
        XCTAssertNil(try f.repo.get(key: "pet.event.7"))
    }

    func test_killSwitchOffStopsBotAttentionNotices() async throws {
        // WHY (§0.5): Bot questions must not also arrive as Titio notices
        // (banner + push) next to today's Bot attention path.
        let f = try makeFixture()
        setHub(false, f)
        let bot = try f.store.create(name: "Scout", title: "", description: "", handle: "scout")
        try f.store.upsertAttention(BotAttentionItem(botID: bot.id, kind: .blocked, title: "Stuck", detail: "VM down"))
        f.center.handleEvent(EventBus.Event(seq: 1, kind: "bots.attention.changed", payload: .object([:]),
                                            ts: f.scheduler.now.timeIntervalSince1970))
        await f.scheduler.advance(by: 1, center: f.center)
        XCTAssertTrue(try f.repo.openKeys(prefix: "bot.attention.").isEmpty)
        XCTAssertTrue(f.recorder.banners.isEmpty)
    }

    // MARK: 3 / 17 / 23 / 33 / 39. Rows left in `acting`

    func test_startupGivesBackActingCardsAndExpiresOnesWhoseRequestIsGone() async throws {
        // WHY: the act runs in an in-memory task. A quit or crash mid-act left
        // the row `acting` forever: a dead card, every tap silent, and the
        // inbox stuck in needs-attention.
        let path = NSTemporaryDirectory() + "titio-recovery-" + UUID().uuidString
        let first = try makeFixture(path: path)
        let stuck = approval("Q1", first)
        first.center.ingest(stuck)
        await first.center.idle()
        XCTAssertTrue(try first.repo.claim(key: stuck.key), "the act claimed it, then the app quit")

        // Relaunch with the request still open: the card works again.
        let open = try makeFixture(path: path)
        open.actions.requestOpen = true
        open.center.start(subscribeToEvents: false)
        await open.center.idle()
        XCTAssertEqual(try open.repo.get(key: stuck.key)?.state, .posted)
        XCTAssertEqual(open.center.actNow(messageID: TitioNoticeIDs.messageID(forKey: stuck.key).uuidString, optionIndex: 0),
                       .accepted, "a tap acts again")
        await settle(open)

        // Another stuck act whose request is gone after the restart: expired.
        let second = approval("Q2", open)
        open.center.ingest(second)
        await open.center.idle()
        XCTAssertTrue(try open.repo.claim(key: second.key))
        let gone = try makeFixture(path: path)
        gone.actions.requestOpen = false
        gone.center.start(subscribeToEvents: false)
        await gone.center.idle()
        XCTAssertEqual(try gone.repo.get(key: second.key)?.resolution, .expired)
        XCTAssertEqual(try gone.repo.openDecisionCount(), 0, "needs-attention can clear")
    }

    // MARK: 4 / 17. Stale provider callbacks after a restart

    func test_startupExpiresOpenRequestCardsWhoseProviderCallbackIsGone() async throws {
        // WHY: launch marks every open provider callback stale without a
        // resolution event, so approval/question cards stayed open and kept the
        // inbox (and iOS open_decisions) in needs-attention indefinitely.
        let path = NSTemporaryDirectory() + "titio-recovery-" + UUID().uuidString
        let before = try makeFixture(path: path)
        let fact = approval("Q1", before)
        before.center.ingest(fact)
        await before.center.idle()
        XCTAssertEqual(try before.repo.openDecisionCount(), 1)

        let after = try makeFixture(path: path)
        after.actions.requestOpen = false
        after.center.start(subscribeToEvents: false)
        await after.center.idle()
        XCTAssertEqual(try after.repo.get(key: fact.key)?.resolution, .expired)
        XCTAssertEqual(try after.repo.openDecisionCount(), 0)
        let message = try XCTUnwrap(after.messages.get(id: AgentMessageID(TitioNoticeIDs.messageID(forKey: fact.key))))
        XCTAssertTrue(message.content.hasSuffix("_Written status._"), message.content)
    }

    // MARK: 5 / 30 / 40. Transcript retention

    func test_anOpenNoticeMessageSurvivesTheHundredMessageCap() async throws {
        // WHY: every inbox write prunes the thread to 100 messages. An open
        // decision's message went with it: no card to tap while the ledger kept
        // the inbox in needs-attention.
        let f = try makeFixture()
        let fact = approval("Q1", f)
        f.center.ingest(fact)
        await f.center.idle()
        let id = AgentMessageID(TitioNoticeIDs.messageID(forKey: fact.key))
        for index in 0..<(AgentMessageRepository.maxMessagesPerThread + 20) {
            try f.messages.append(AgentMessage(threadId: f.target.threadID, role: .assistant, content: "line \(index)",
                                               createdAt: f.scheduler.now.addingTimeInterval(Double(index + 1))))
        }
        XCTAssertNotNil(try f.messages.get(id: id), "the open card stays")

        // Once resolved, retention may take it like any other message.
        f.center.sourceResolved(key: TitioNoticeIDs.threadAttention(threadId: requestThread.value.uuidString, requestId: "Q1"))
        await f.center.idle()
        try f.messages.append(AgentMessage(threadId: f.target.threadID, role: .assistant, content: "later",
                                           createdAt: f.scheduler.now.addingTimeInterval(1_000)))
        XCTAssertNil(try f.messages.get(id: id))
    }

    func test_startupSettlesAnOpenNoticeWhoseMessageIsGone() async throws {
        // WHY: a card whose message is gone (retention before this fix, or a
        // deleted inbox) can never be tapped: it must not stay an open decision.
        let path = NSTemporaryDirectory() + "titio-recovery-" + UUID().uuidString
        let before = try makeFixture(path: path)
        let fact = approval("Q1", before)
        before.center.ingest(fact)
        await before.center.idle()
        try before.db.execute("DELETE FROM agent_messages WHERE id = '\(TitioNoticeIDs.messageID(forKey: fact.key).uuidString)';")

        let after = try makeFixture(path: path)
        after.center.start(subscribeToEvents: false)
        await after.center.idle()
        XCTAssertEqual(try after.repo.get(key: fact.key)?.resolution, .expired)
        XCTAssertEqual(try after.repo.openDecisionCount(), 0)
    }

    // MARK: 6. Startup catch-up keeps alert cards

    func test_startupPostsPendingAlertsOneByOneWithTheirOwnCards() async throws {
        // WHY: folding an interrupted run into the catch-up digest dropped its
        // "Continue" card and left a navigation-only card nothing resolves.
        let f = try makeFixture()
        let facts = TitioNoticeFacts(title: "Build", workspaceName: "api")
        try f.repo.ingest(TitioNoticeFact(key: "run.I.interrupted", kind: .runInterrupted,
                                          source: TitioNoticeSource(threadId: requestThread.value.uuidString, runId: "I"),
                                          facts: facts, actions: TitioNoticeAction.defaultActions(kind: .runInterrupted, facts: facts),
                                          occurredAt: f.scheduler.now))
        for run in ["A", "B"] {
            try f.repo.ingest(TitioNoticeFact(key: "run.\(run).completed", kind: .runCompleted, facts: facts, occurredAt: f.scheduler.now))
        }
        f.center.start(subscribeToEvents: false)
        await f.center.idle()

        let interrupted = try XCTUnwrap(f.repo.get(key: "run.I.interrupted"))
        XCTAssertNil(interrupted.batchID, "its own message")
        XCTAssertEqual(interrupted.actions?.first?.action, .continue)
        let messages = try transcript(f)
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages.contains { $0.content == "Written digest." })
    }

    // MARK: 8. Fail-loud fallback, then recovery

    func test_aLegacyFallbackIsNotAnnouncedAgainWhenTheInboxRecoversAfterARestart() async throws {
        // WHY: the fallback banner already alerted the user. After a restart
        // SystemNotifier's in-memory dedupe is empty, so the recovered flush
        // showed a second banner (and push) for the same notice.
        let path = NSTemporaryDirectory() + "titio-recovery-" + UUID().uuidString
        let down = try makeFixture(path: path, available: false)
        let fact = approval("Q1", down)
        let legacy = RemoteCodeNotificationContent(
            identifier: "thread.T.attention.Q1", title: "Action needed", body: "A run needs your attention.",
            categoryIdentifier: "", threadIdentifier: "", userInfo: [:], soundEnabled: true
        )
        down.center.ingest(fact, legacy: TitioNoticeLegacyDelivery(content: legacy, pushes: true))
        await down.scheduler.advance(by: TitioNoticeTiming.legacyFallbackAfter, center: down.center)
        XCTAssertEqual(down.recorder.banners.map(\.title), ["Action needed"], "fail loud")
        XCTAssertNotNil(try down.repo.get(key: fact.key)?.bannerAt)

        let up = try makeFixture(path: path)
        up.center.start(subscribeToEvents: false)
        await up.center.idle()
        XCTAssertEqual(try up.repo.get(key: fact.key)?.state, .posted, "the message is still posted to the inbox")
        XCTAssertTrue(up.recorder.banners.isEmpty, "no second banner")
        XCTAssertTrue(up.recorder.pushes.isEmpty, "no second push")
    }

    // MARK: 9. Attention backlog

    func test_attentionPlanSkipsABacklogOlderThanADay() {
        // WHY: the first pass after an upgrade turned every weeks-old
        // unacknowledged Bot item into its own message, banner and push.
        let bot = BotDefinition(handle: "scout", name: "Scout", title: "", description: "")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = BotAttentionItem(botID: bot.id, kind: .question, title: "Old", createdAt: now.addingTimeInterval(-3 * 86_400))
        let oldPosted = BotAttentionItem(botID: bot.id, kind: .blocked, title: "Old, already posted",
                                         createdAt: now.addingTimeInterval(-3 * 86_400))
        let recent = BotAttentionItem(botID: bot.id, kind: .question, title: "New", createdAt: now.addingTimeInterval(-60))
        let plan = TitioNoticeCenter.attentionPlan(
            items: [old, oldPosted, recent], bots: [bot.id: bot],
            openBotKeys: [TitioNoticeIDs.botAttention(itemId: oldPosted.id.value.uuidString)],
            openThreadKeys: [], linkedThread: { _ in nil }, now: now
        )
        XCTAssertEqual(plan.ingest.map(\.key), [TitioNoticeIDs.botAttention(itemId: recent.id.value.uuidString)])
        XCTAssertEqual(plan.resolved, [], "an old item that already has a notice still counts as live")
    }

    // MARK: 11. Latest-wins inbox snapshot

    func test_aFlushThatResumesAfterANewerResultLineDoesNotPublishTheOlderPreview() async throws {
        // WHY: the flush awaits the desk hop; an act's result line can commit a
        // newer preview meanwhile. Publishing the flush's older snapshot last
        // left iOS showing the stale preview.
        let newer = Date(timeIntervalSince1970: 4_000_000_000)
        let box = TitioNoticeLockedBox<TitioNoticeRepository?>(nil)
        let f = try makeFixture(onPosted: { _ in
            _ = try? box.value?.updateInboxState { $0.lastPreview = "Newer result"; $0.lastAt = newer }
        })
        box.value = f.repo
        f.center.ingest(approval("Q1", f))
        await f.center.idle()
        XCTAssertEqual(f.recorder.inbox.last?.lastPreview, "Newer result")
        XCTAssertEqual(f.center.inboxSnapshot?.lastPreview, "Newer result")
    }

    // MARK: 18 / 22. Open <Bot> on iOS

    func test_openBotRouteCarriesWhatAnIOSBotRouteNeedsAndChangesNoState() async throws {
        // WHY: iOS resolves a bot route only with profileId, hostId and an
        // attention item id; with botId + conversationId alone "Abrir o <Bot>"
        // did nothing on the phone. Opening must not acknowledge anything.
        let f = try makeFixture()
        let bot = UUID().uuidString.lowercased()
        let conversation = UUID().uuidString.lowercased()
        let item = UUID().uuidString.lowercased()
        let facts = TitioNoticeFacts(botName: "Scout", detail: "VM down")
        f.center.ingest(TitioNoticeFact(
            key: "bot.attention.\(item)", kind: .botBlocked,
            source: TitioNoticeSource(botId: bot, conversationId: conversation, attentionItemId: item),
            facts: facts, actions: TitioNoticeAction.defaultActions(kind: .botBlocked, facts: facts),
            occurredAt: f.scheduler.now
        ))
        await f.center.idle()
        let messageID = TitioNoticeIDs.messageID(forKey: "bot.attention.\(item)").uuidString
        guard case .navigate(let route) = f.center.actNow(messageID: messageID, optionIndex: 0) else {
            return XCTFail("Open <Bot> navigates")
        }
        XCTAssertEqual(route["botId"], bot)
        XCTAssertEqual(route["conversationId"], conversation)
        XCTAssertEqual(route["profileId"], "profile-1")
        XCTAssertEqual(route["hostId"], "host-1")
        XCTAssertEqual(route["attentionItemId"], item)
        XCTAssertEqual(route["acknowledgeBotOnOpen"], "false")
        XCTAssertEqual(try f.repo.get(key: "bot.attention.\(item)")?.state, .posted)
    }

    // MARK: 7. Scheduled failure keeps its Run again card

    func test_theRunHookPostsTheScheduledFailureSoTheLaterSchedulerIngestIsANoOp() async throws {
        // WHY: the run hook posted a generic run failure first; the scheduler's
        // scheduledFailed (with "Run again") arrived a tick later against the
        // frozen row and was dropped. The run hook now posts the rich notice.
        let f = try makeFixture()
        let run = AgentRunID()
        let task = UUID()
        let fact = AppContext.scheduledRunFailureFact(
            runId: run, threadId: requestThread, workspaceId: nil, workspaceName: "api", finalMessageId: nil,
            scheduled: AppContext.TitioScheduledRunFacts(scheduledRunID: UUID(), taskID: task, taskTitle: "Nightly"),
            occurredAt: f.scheduler.now
        )
        XCTAssertEqual(fact.key, TitioNoticeIDs.runOutcome(runId: run.value.uuidString, outcome: .failed),
                       "the scheduler's own ingest uses this key, so the two merge")
        f.center.ingest(fact)
        await f.center.idle()
        f.center.ingest(TitioNoticeFact(key: fact.key, kind: .scheduledFailed, facts: TitioNoticeFacts(title: "Nightly")))
        await f.center.idle()
        let row = try XCTUnwrap(f.repo.get(key: fact.key))
        XCTAssertEqual(row.kind, .scheduledFailed)
        XCTAssertEqual(row.actions?.map(\.action), [.rerun, .openActivity])
        XCTAssertEqual(row.source.scheduledTaskId, task.uuidString.lowercased())
        XCTAssertEqual(try transcript(f).count, 1)
    }
}
