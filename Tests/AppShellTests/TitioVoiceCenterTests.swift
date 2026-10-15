import XCTest
import CoreModel
import SocketServer
@testable import AppShell
@testable import Persistence

/// A scripted Titio writer: records every request, answers from `respond`,
/// and can hold calls mid-flight (a notice "composing").
final class FakeTitioVoice: TitioVoiceWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var requestsValue: [TitioVoiceRequest] = []
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private let respond: @Sendable (TitioVoiceRequest) throws -> String

    init(_ respond: @escaping @Sendable (TitioVoiceRequest) throws -> String) {
        self.respond = respond
    }

    var requests: [TitioVoiceRequest] { lock.withLock { requestsValue } }

    func hold() { lock.withLock { holding = true } }

    func release() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            holding = false
            defer { held = [] }
            return held
        }
        waiting.forEach { $0.resume() }
    }

    func write(_ request: TitioVoiceRequest, timeout: TimeInterval) async throws -> String {
        let mustWait: Bool = lock.withLock {
            requestsValue.append(request)
            return holding
        }
        if mustWait {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    guard holding else { return true }
                    held.append(waiter)
                    return false
                }
                if resumeNow { waiter.resume() }
            }
        }
        return try respond(request)
    }

    func waitForRequests(_ count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while requests.count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// Titio writes his notices himself (voice contract §2) and the user can
/// clear any of them (§3). These run the real center and ledger with a fake
/// writer: no provider CLI is ever spawned.
final class TitioVoiceCenterTests: XCTestCase {
    private struct Fixture {
        let db: SQLiteDB
        let repo: TitioNoticeRepository
        let messages: AgentMessageRepository
        let store: BotStore
        let target: TitioInboxTarget
        let scheduler: ManualTitioScheduler
        let recorder: TitioHookRecorder
        let actions: TitioActionRecorder
        let center: TitioNoticeCenter
    }

    private static let fast = TitioVoiceTiming(retryDelays: [0, 0, 0], callTimeout: 5, urgentDeadline: 5, infoDeadline: 5, lineDeadline: 5)
    private let requestThread = AgentThreadID()

    private func makeFixture(
        voice: TitioVoiceWriting?,
        db existing: SQLiteDB? = nil,
        userTexts: [String] = ["roda os testes de novo, por favor"]
    ) throws -> Fixture {
        let db: SQLiteDB
        if let existing {
            db = existing
        } else {
            let path = NSTemporaryDirectory() + "titio-voice-" + UUID().uuidString
            db = try Bootstrap(channel: .debug, appSupportOverride: path).run().1
        }
        let store = BotStore(db: db)
        let repo = TitioNoticeRepository(db: db)
        let target: TitioInboxTarget
        if existing == nil {
            let bot = try store.create(name: "Titio", title: "", description: "", handle: "titio")
            let thread = AgentThread(title: "Notifications", provider: .distill, model: "m")
            try AgentThreadRepository(db: db).upsert(thread)
            let conversation = BotConversation(botID: bot.id, title: "Notifications", linkedAgentThreadID: thread.id)
            try store.upsertConversation(conversation)
            try repo.updateInboxState { $0.conversationID = conversation.id.value.uuidString.lowercased() }
            target = TitioInboxTarget(botID: bot.id, conversationID: conversation.id, threadID: thread.id)
        } else {
            let conversationID = try XCTUnwrap(repo.inboxState().conversationID.flatMap(UUID.init(uuidString:)))
            let conversation = try XCTUnwrap(store.conversation(id: BotConversationID(conversationID)))
            target = TitioInboxTarget(botID: conversation.botID, conversationID: conversation.id,
                                      threadID: try XCTUnwrap(conversation.linkedAgentThreadID))
        }
        let recorder = TitioHookRecorder()
        recorder.target = target
        var hooks = recorder.hooks()
        hooks.languageInputs = {
            TitioNoticeLanguageInputs(recentUserTexts: userTexts, cardLabels: [], preferredLanguages: ["en-US"])
        }
        let scheduler = ManualTitioScheduler()
        let center = TitioNoticeCenter(
            db: db, botStore: store, hooks: hooks, scheduler: scheduler,
            voice: voice, voiceTiming: Self.fast,
            now: { scheduler.now }, timeZone: TimeZone(identifier: "UTC")!
        )
        let actions = TitioActionRecorder()
        center.installActions(actions.hooks())
        return Fixture(db: db, repo: repo, messages: AgentMessageRepository(db: db), store: store, target: target,
                       scheduler: scheduler, recorder: recorder, actions: actions, center: center)
    }

    private func failure(_ run: String, _ f: Fixture) -> TitioNoticeFact {
        let facts = TitioNoticeFacts(title: "Elephant - Task do elephant", workspaceName: "elephant",
                                     summary: "Implemented DEV-5277. **[Draft PR #3109](https://github.com/o/r/pull/3109)** is open.")
        return TitioNoticeFact(
            key: TitioNoticeIDs.runOutcome(runId: run, outcome: .failed),
            kind: .runFailed,
            source: TitioNoticeSource(threadId: "T-\(run)", runId: run, workspaceId: "W", activityItemId: "run:\(run.lowercased())"),
            facts: facts,
            actions: TitioNoticeAction.defaultActions(kind: .runFailed, facts: facts),
            occurredAt: f.scheduler.now
        )
    }

    private func completion(_ run: String, title: String, _ f: Fixture) -> TitioNoticeFact {
        TitioNoticeFact(
            key: TitioNoticeIDs.runOutcome(runId: run, outcome: .completed),
            kind: .runCompleted,
            source: TitioNoticeSource(threadId: "T-\(run)", runId: run, workspaceId: "W"),
            facts: TitioNoticeFacts(title: title, workspaceName: "api", durationMs: 9 * 60_000),
            occurredAt: f.scheduler.now
        )
    }

    private func approval(_ request: String, _ f: Fixture) -> TitioNoticeFact {
        let facts = TitioNoticeFacts(title: "Deploy", workspaceName: "api", detail: "export OPENAI_API_KEY=sk-live-123",
                                     requestKind: "commandExecution")
        return TitioNoticeFact(
            key: TitioNoticeIDs.threadAttention(threadId: requestThread.value.uuidString, requestId: request),
            kind: .approval,
            source: TitioNoticeSource(threadId: requestThread.value.uuidString, requestId: request),
            facts: facts,
            actions: TitioNoticeAction.defaultActions(kind: .approval, facts: facts),
            occurredAt: f.scheduler.now
        )
    }

    private func transcript(_ f: Fixture) throws -> [AgentMessage] {
        try f.messages.list(threadId: f.target.threadID)
    }

    private func waitForPushes(_ f: Fixture, count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while f.recorder.pushes.count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: Writer text becomes the message

    func test_theWritersTextIsTheMessageAndItsFirstSentenceTheBanner() async throws {
        // WHY: the owner wants no canned text at all. What Titio's model
        // wrote is what the inbox, banner, push and roster carry, in plain
        // text where Markdown cannot render.
        let voice = FakeTitioVoice { request in
            request.expectsJSON
                ? #"{"message":"A **Elephant - Task do elephant** falhou no meio do caminho. O PR [#3109](https://github.com/o/r/pull/3109) ficou aberto.","question":"Quer abrir?","options":["Abrir a conversa","Beleza"]}"#
                : "unused"
        }
        let f = try makeFixture(voice: voice)
        f.center.ingest(failure("R1", f))
        await f.center.idle()
        await waitForPushes(f, count: 1)

        let messages = try transcript(f)
        XCTAssertEqual(messages.count, 1)
        let parsed = BotChoicesBlock.parse(messages[0].content)
        XCTAssertEqual(parsed.text, "A **Elephant - Task do elephant** falhou no meio do caminho. O PR [#3109](https://github.com/o/r/pull/3109) ficou aberto.")
        XCTAssertEqual(f.recorder.banners.first?.body, "A Elephant - Task do elephant falhou no meio do caminho.")
        XCTAssertEqual(f.recorder.inbox.last?.lastPreview,
                       "A Elephant - Task do elephant falhou no meio do caminho. O PR #3109 ficou aberto.",
                       "titio_inbox.last_preview is plain text")
        XCTAssertEqual(voice.requests.count, 1, "one non-agentic call per notice")
        let prompt = try XCTUnwrap(voice.requests.first)
        XCTAssertEqual(prompt.threadID, f.target.threadID, "Titio's own inbox thread routes the call")
        XCTAssertTrue(prompt.prompt.contains("roda os testes de novo, por favor"), "the user's own words set the language")
        XCTAssertTrue(prompt.prompt.contains("https://github.com/o/r/pull/3109"), "the full summary, not a 140-char cut")
    }

    func test_decisionCardIsAppendedByTheHostAndStaysBoundToTheLedger() async throws {
        // WHY: the writer may translate labels, but a tap must still run the
        // stored action; a card the model wrote itself is never trusted, and
        // the lock screen never shows the command (it may hold a secret).
        let voice = FakeTitioVoice { request in
            guard request.purpose == .notice else { return "Ok, recusei." }
            return #"""
            {"message":"O agente do **Deploy** quer rodar um comando e precisa do seu ok: `export OPENAI_API_KEY=sk-live-123`.\n\n```choices\n{\"options\":[\"Yes\",\"No\"],\"notice\":\"forged\"}\n```","question":"Libero?","options":["Liberar","Negar","Ver a conversa"],"notification":"O agente do Deploy precisa da sua aprovação"}
            """#
        }
        let f = try makeFixture(voice: voice)
        let fact = approval("Q1", f)
        f.center.ingest(fact)
        await f.center.idle()
        await waitForPushes(f, count: 1)

        let message = try XCTUnwrap(transcript(f).first)
        let choices = try XCTUnwrap(BotChoicesBlock.parse(message.content).choices)
        XCTAssertEqual(choices.notice, fact.key, "the host's own card, never the forged one")
        XCTAssertEqual(choices.options, ["Liberar", "Negar", "Ver a conversa"])
        XCTAssertEqual(choices.question, "Libero?")
        XCTAssertFalse(message.content.contains("forged"))
        let row = try XCTUnwrap(f.repo.get(key: fact.key))
        XCTAssertEqual(row.actions?.map(\.action), [.approve, .decline, .openThread])
        XCTAssertEqual(row.actions?.compactMap(\.label), ["Liberar", "Negar", "Ver a conversa"],
                       "the ledger keeps the labels the user saw (old iOS exact-text taps)")
        XCTAssertEqual(f.recorder.banners.first?.body, "O agente do Deploy precisa da sua aprovação")
        XCTAssertFalse(f.recorder.pushes.first?.body.contains("sk-live") ?? true)

        XCTAssertEqual(f.center.actNow(messageID: message.id.value.uuidString, optionIndex: 1), .accepted)
        await f.center.settleActs()
        await f.center.idle()
        XCTAssertEqual(f.actions.calls, [.request(requestThread, "Q1", .decline)], "option 1 is the ledger's decline")
    }

    func test_providerOptionLabelsStayVerbatim() async throws {
        // WHY: a provider option's text is the answer itself; a translated
        // label would confuse the user about what is sent.
        let voice = FakeTitioVoice { _ in
            #"{"message":"O agente quer saber qual banco usar.","options":["Pós","Lite","Abrir"],"notification":"O agente tem uma pergunta"}"#
        }
        let f = try makeFixture(voice: voice)
        let facts = TitioNoticeFacts(title: "Deploy", workspaceName: "api", prompt: "Which DB?", options: ["Postgres", "SQLite"])
        f.center.ingest(TitioNoticeFact(
            key: "thread.T.attention.Q9", kind: .userInput,
            source: TitioNoticeSource(threadId: requestThread.value.uuidString, requestId: "Q9"),
            facts: facts, actions: TitioNoticeAction.defaultActions(kind: .userInput, facts: facts), occurredAt: f.scheduler.now
        ))
        await f.center.idle()
        let choices = try XCTUnwrap(BotChoicesBlock.parse(try XCTUnwrap(transcript(f).first).content).choices)
        XCTAssertEqual(choices.options, ["Postgres", "SQLite", "Abrir"])
    }

    // MARK: Fallback

    func test_withoutAnLLMTheNoticeStillPostsAMinimalFactualSentenceInTime() async throws {
        // WHY (contract §2): no provider/binary must never lose a failure or a
        // decision; the fallback is the facts only, with no canned opener.
        let voice = FakeTitioVoice { _ in throw TitioVoiceError.unavailable("no provider route") }
        let f = try makeFixture(voice: voice, userTexts: [])
        let started = Date()
        f.center.ingest(failure("R2", f))
        await f.center.idle()
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "an unavailable writer is not retried")
        let message = try XCTUnwrap(transcript(f).first)
        XCTAssertEqual(BotChoicesBlock.parse(message.content).text,
                       "**Elephant - Task do elephant** in **elephant** failed.")
        XCTAssertEqual(voice.requests.count, 1)
        XCTAssertEqual(BotChoicesBlock.parse(message.content).choices?.options, ["Open thread", "Got it"])
    }

    func test_aFailingWriterFallsBackAfterItsRetries() async throws {
        // WHY: retries are bounded; the notice posts with the fallback.
        let voice = FakeTitioVoice { _ in throw TitioVoiceError.failed("exit 1") }
        let f = try makeFixture(voice: voice)
        f.center.ingest(failure("R3", f))
        await f.center.idle()
        XCTAssertEqual(voice.requests.count, 4, "one try and three retries")
        XCTAssertEqual(try transcript(f).count, 1)
        XCTAssertEqual(try f.repo.get(key: "run.R3.failed")?.state, .posted)
    }

    // MARK: Exactly once

    func test_aRetryWhileComposingStartsNoSecondCallAndARestartNeverDuplicates() async throws {
        // WHY: the row stays pending while Titio writes. A replayed ingest or
        // a retry must not start a second call, and a restart that writes it
        // again must still leave exactly one message (deterministic id).
        let slow = FakeTitioVoice { _ in #"{"message":"Primeira versão."}"# }
        slow.hold()
        let first = try makeFixture(voice: slow)
        let fact = failure("R4", first)
        first.center.ingest(fact)
        await slow.waitForRequests(1)
        first.center.ingest(fact)
        await first.center.commandsDrained()
        XCTAssertEqual(slow.requests.count, 1, "a replay while composing is not a second call")
        XCTAssertEqual(try first.repo.get(key: fact.key)?.state, .pending, "nothing posts before the text exists")
        XCTAssertTrue(try transcript(first).isEmpty)

        // The app restarts while the first call still runs.
        let second = try makeFixture(voice: FakeTitioVoice { _ in #"{"message":"Segunda versão."}"# }, db: first.db)
        second.center.start(subscribeToEvents: false)
        await second.center.idle()
        XCTAssertEqual(try transcript(second).map(\.content).map { BotChoicesBlock.parse($0).text }, ["Segunda versão."])

        // The first call returns late: its commit finds the row posted.
        slow.release()
        await first.center.idle()
        let messages = try transcript(first)
        XCTAssertEqual(messages.count, 1, "exactly one message")
        XCTAssertEqual(messages.first?.id.value, TitioNoticeIDs.messageID(forKey: fact.key))
        XCTAssertTrue(messages.first?.content.hasPrefix("Segunda versão.") == true, "a late writer never overwrites")
    }

    func test_aDigestIsOneCallAndARowResolvedMeanwhileIsLeftOut() async throws {
        // WHY: one LLM call per flushed batch; and the text must not mention
        // a notice that resolved while Titio was writing.
        let voice = FakeTitioVoice { request in
            request.prompt.contains("\"count\" : 3") ? "Três coisas aconteceram." : "Duas coisas aconteceram."
        }
        voice.hold()
        let f = try makeFixture(voice: voice)
        f.center.ingest(completion("A", title: "Build", f))
        f.center.ingest(completion("B", title: "Lint", f))
        f.center.ingest(completion("C", title: "Docs", f))
        await f.scheduler.advance(by: 0, center: f.center)
        await f.center.commandsDrained()
        // Fire the 8 s window without waiting for the held call.
        let advance = Task { await f.scheduler.advance(by: TitioNoticeTiming.infoWindow, center: f.center) }
        await voice.waitForRequests(1)
        XCTAssertEqual(voice.requests.first?.purpose, .digest)
        f.center.sourceResolved(key: "run.C.completed", reason: .elsewhere)
        await f.center.commandsDrained()
        voice.release()
        await advance.value
        await f.center.idle()

        XCTAssertEqual(voice.requests.count, 2, "re-written once without the resolved row")
        let messages = try transcript(f)
        XCTAssertEqual(messages.map(\.content), ["Duas coisas aconteceram."])
        XCTAssertEqual(messages.first?.id.value, TitioNoticeIDs.digestMessageID(forKeys: ["run.A.completed", "run.B.completed"]))
        XCTAssertEqual(try f.repo.get(key: "run.C.completed")?.state, .dropped)
    }

    // MARK: Result and status lines

    func test_resultAndStatusLinesAreWrittenByTheVoice() async throws {
        // WHY: lines after an act are Titio's words too; the card still goes
        // at once, and only the facts of what happened reach the writer.
        let voice = FakeTitioVoice { request in
            switch request.purpose {
            case .notice, .digest:
                return #"{"message":"O Deploy precisa do seu ok.","options":["Ok","Não","Ver"],"notification":"O Deploy precisa do seu ok"}"#
            case .result:
                return "Pronto, liberei pro agente seguir."
            case .status:
                return "liberado por você"
            }
        }
        let f = try makeFixture(voice: voice)
        let fact = approval("Q5", f)
        f.center.ingest(fact)
        await f.center.idle()
        let id = TitioNoticeIDs.messageID(forKey: fact.key).uuidString
        XCTAssertEqual(f.center.actNow(messageID: id, optionIndex: 0), .accepted)
        await f.center.settleActs()
        await f.center.idle()

        let rows = try transcript(f)
        XCTAssertEqual(rows.map(\.content).suffix(2), ["Ok", "Pronto, liberei pro agente seguir."])
        XCTAssertEqual(rows.first?.content, "O Deploy precisa do seu ok.\n\n_liberado por você_")
        XCTAssertNil(BotChoicesBlock.parse(rows.first?.content ?? "").choices)
        let resultPrompt = try XCTUnwrap(voice.requests.first { $0.purpose == .result }?.prompt)
        XCTAssertTrue(resultPrompt.contains("You approved the agent's request in the workspace “api”"))
    }

    // MARK: Language setting

    func test_theLanguageSettingReachesThePromptAndSurvivesARestart() async throws {
        // WHY: the Settings choice must be what Titio writes in, also after
        // relaunching the app (it lives in the persisted AppSettings).
        let voice = FakeTitioVoice { _ in #"{"message":"Listo."}"# }
        let f = try makeFixture(voice: voice)
        SettingsStore(db: f.db).update { $0.titioLanguage = "es" }
        XCTAssertEqual(SettingsStore(db: f.db).load().titioLanguage, "es", "a new store (relaunch) reads it back")
        f.center.ingest(failure("R6", f))
        await f.center.idle()
        XCTAssertTrue(try XCTUnwrap(voice.requests.first).prompt.contains("Write in Spanish (es)"))
    }

    // MARK: Clear (contract §3)

    func test_clearRemovesTheMessageAcksItsSourceAndUpdatesTheInbox() async throws {
        // WHY: the clear button must really clear: the message leaves every
        // client, the Activity item is acknowledged, the preview falls back
        // to what is left, and no card stays open.
        let f = try makeFixture(voice: nil, userTexts: [])
        f.center.ingest(failure("R7", f))
        await f.scheduler.advance(by: 60, center: f.center)
        f.center.ingest(failure("R8", f))
        await f.center.idle()
        let keep = TitioNoticeIDs.messageID(forKey: "run.R7.failed")
        let gone = TitioNoticeIDs.messageID(forKey: "run.R8.failed")
        XCTAssertEqual(f.recorder.inbox.last?.unreadCount, 2)

        let outcome = await f.center.clear(messageID: gone.uuidString)
        XCTAssertEqual(outcome, .cleared(threadID: f.target.threadID))
        await f.center.settleActs()
        await f.center.idle()

        XCTAssertEqual(try transcript(f).map(\.id.value), [keep])
        XCTAssertEqual(try f.repo.get(key: "run.R8.failed")?.resolution, .cleared)
        XCTAssertEqual(try f.repo.get(key: "run.R7.failed")?.state, .posted, "only that message's notices")
        XCTAssertEqual(f.actions.calls, [.ackActivity("run:r8")])
        XCTAssertEqual(f.recorder.removed, [[AgentMessageID(gone)]], "agent.messages.removed goes out")
        let inbox = try XCTUnwrap(f.recorder.inbox.last)
        XCTAssertEqual(inbox.unreadCount, 1)
        XCTAssertEqual(inbox.lastPreview, "Elephant - Task do elephant in elephant failed.")
    }

    func test_clearingADecisionLeavesTheProviderRequestPending() async throws {
        // WHY: clearing hides the notice; it must not approve or decline
        // anything. The request stays answerable in its own thread.
        let f = try makeFixture(voice: nil)
        let fact = approval("Q8", f)
        f.center.ingest(fact)
        await f.center.idle()
        XCTAssertEqual(f.recorder.inbox.last?.openDecisions, 1)
        let id = TitioNoticeIDs.messageID(forKey: fact.key)
        let outcome = await f.center.clear(messageID: id.uuidString)
        XCTAssertEqual(outcome, .cleared(threadID: f.target.threadID))
        await f.center.settleActs()
        await f.center.idle()
        XCTAssertEqual(f.actions.calls, [], "no respondRequest: the provider request stays pending")
        XCTAssertEqual(try f.repo.get(key: fact.key)?.resolution, .cleared)
        XCTAssertEqual(f.recorder.inbox.last?.openDecisions, 0)
        XCTAssertEqual(f.center.actNow(messageID: id.uuidString, optionIndex: 0), .alreadyResolved,
                       "a stale card tap after clearing sends nothing")
        // A later resolution elsewhere finds nothing to rewrite.
        f.center.sourceResolved(key: fact.key)
        await f.center.idle()
        XCTAssertTrue(try transcript(f).filter { $0.role == .assistant && $0.id.value == id }.isEmpty, "never resurrected")
    }

    func test_clearAcksExternalNotificationsAndBotAttention() async throws {
        // WHY: each source is acknowledged where it lives, so it does not
        // come back as unread elsewhere.
        let f = try makeFixture(voice: nil)
        f.center.ingest(TitioNoticeFact(key: "notification.N1", kind: .external,
                                        source: TitioNoticeSource(notificationId: "N1"),
                                        facts: TitioNoticeFacts(title: "Build", body: "done"), occurredAt: f.scheduler.now))
        await f.scheduler.advance(by: TitioNoticeTiming.infoWindow, center: f.center)
        let item = BotAttentionItemID(UUID())
        f.center.ingest(TitioNoticeFact(key: "bot.attention.\(item.value.uuidString)", kind: .botBlocked,
                                        source: TitioNoticeSource(attentionItemId: item.value.uuidString),
                                        facts: TitioNoticeFacts(botName: "Scout", detail: "VM down"),
                                        actions: [.openBot, .ack], occurredAt: f.scheduler.now))
        await f.center.idle()
        for key in ["notification.N1", "bot.attention.\(item.value.uuidString)"] {
            _ = await f.center.clear(messageID: TitioNoticeIDs.messageID(forKey: key).uuidString)
        }
        await f.center.settleActs()
        await f.center.idle()
        XCTAssertEqual(f.actions.calls.count, 2)
        XCTAssertTrue(f.actions.calls.contains(.dismissNotification("N1")), "notification.dismiss for an external notice")
        XCTAssertTrue(f.actions.calls.contains(.ackBot(item)), "the Bot attention item is acknowledged")
        XCTAssertTrue(try transcript(f).isEmpty)
        XCTAssertNil(f.recorder.inbox.last?.lastPreview, "nothing left to preview")
    }

    func test_onlyAssistantMessagesOfTheInboxClear() async throws {
        // WHY: `bot.notice.clear` is a paired-device mutation; it must never
        // delete the user's own words or any other thread's message.
        let f = try makeFixture(voice: nil)
        let user = AgentMessage(threadId: f.target.threadID, role: .user, content: "oi")
        let otherThread = AgentThread(title: "Other", provider: .distill, model: "m")
        try AgentThreadRepository(db: f.db).upsert(otherThread)
        let elsewhere = AgentMessage(threadId: otherThread.id, role: .assistant, content: "x")
        try f.messages.append(user)
        try f.messages.append(elsewhere)
        f.center.ingest(failure("R9", f))
        await f.center.idle()
        XCTAssertEqual(f.center.clearNow(messageID: user.id.value.uuidString), .invalid)
        XCTAssertEqual(f.center.clearNow(messageID: elsewhere.id.value.uuidString), .invalid)
        XCTAssertEqual(f.center.clearNow(messageID: UUID().uuidString), .invalid)
        XCTAssertEqual(f.center.clearNow(messageID: "not-a-uuid"), .invalid)
        XCTAssertNotNil(try f.messages.get(id: user.id))

        // The RPC path answers at once and removes in command order.
        let notice = TitioNoticeIDs.messageID(forKey: "run.R9.failed").uuidString.lowercased()
        XCTAssertEqual(f.center.clearNow(messageID: notice), .cleared(threadID: f.target.threadID))
        await f.center.idle()
        XCTAssertNil(try f.messages.get(id: AgentMessageID(UUID(uuidString: notice)!)))
    }
}
