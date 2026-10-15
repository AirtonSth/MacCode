import XCTest
@testable import AgentRuntime
import CoreModel
import SocketServer
@testable import AppShell
@testable import Persistence

/// Titio's Notifications conversation (hub spec §8): one dedicated
/// conversation whose thread is the desk's own, so the host's notice
/// messages and the user's free-text chat share one transcript.
@MainActor
final class TitioInboxThreadTests: XCTestCase {
    private var directory: String!

    override func setUpWithError() throws {
        AgentProvider.selectableForTesting = nil
        directory = NSTemporaryDirectory() + "rc-titio-inbox-\(UUID().uuidString)"
        UserDefaults.standard.removeObject(forKey: "bots.deskThreadRouting")
        UserDefaults.standard.removeObject(forKey: "bots.selectedBotID")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "bots.deskThreadRouting")
        UserDefaults.standard.removeObject(forKey: "bots.selectedBotID")
        if let directory { try? FileManager.default.removeItem(atPath: directory) }
        directory = nil
    }

    private func makeFixture() throws -> (AppContext, AppCommandRouter, BotsViewModel) {
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .distill,
            models: [AgentModelDescriptor(id: "main-a", label: "Main A", provider: .distill)],
            binaryPath: "/usr/bin/true",
            authenticated: true,
            id: "distill-acp"
        )
        router.rememberProviderSnapshotsForSend([snapshot])
        router.preflightListedProviderSnapshotsForTesting = false
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        vm.replaceProvidersForTests([snapshot])
        return (context, router, vm)
    }

    func test_inboxIsCreatedOnceWithFrozenRoutingAndItsThreadIsReusedNotReplaced() throws {
        // WHY: notices and the user's replies must stay one transcript; a new
        // thread per post would scatter the inbox and lose the provider session.
        let (context, router, vm) = try makeFixture()
        defer { withExtendedLifetime(vm) {} } // router.botsViewModel is weak
        let first = try XCTUnwrap(router.resolveTitioInbox(language: .en))
        let second = try XCTUnwrap(router.resolveTitioInbox(language: .ptBR))
        XCTAssertEqual(first, second, "same conversation and same thread on the next resolution")

        let conversation = try XCTUnwrap(context.botStore.conversation(id: first.conversationID))
        XCTAssertEqual(conversation.title, "Notifications", "title by language at creation")
        XCTAssertEqual(conversation.linkedAgentThreadID, first.threadID)
        let bot = try XCTUnwrap(context.botStore.get(id: first.botID))
        XCTAssertEqual(bot.handle, TitioBot.handle)
        let thread = try XCTUnwrap(context.threadRepo.get(id: first.threadID))
        XCTAssertEqual(thread.permissionMode, .fullAccess, "Titio threads always run with full access")
        XCTAssertEqual(
            try TitioNoticeRepository(db: context.db).inboxState().conversationID,
            first.conversationID.value.uuidString.lowercased(),
            "the inbox id survives restarts in titio_inbox_state"
        )
        XCTAssertEqual(try context.botStore.listConversations(botID: bot.id).count, 1, "no duplicate inbox")
    }

    func test_deletedInboxIsRecreatedWithTheLanguageTitle() throws {
        // WHY: the user may delete the conversation; the next notice must still land.
        let (context, router, vm) = try makeFixture()
        defer { withExtendedLifetime(vm) {} } // router.botsViewModel is weak
        let first = try XCTUnwrap(router.resolveTitioInbox(language: .en))
        try context.botStore.deleteConversations(botID: first.botID)
        let recreated = try XCTUnwrap(router.resolveTitioInbox(language: .ptBR))
        XCTAssertNotEqual(recreated.conversationID, first.conversationID)
        XCTAssertEqual(try context.botStore.conversation(id: recreated.conversationID)?.title, "Notificações")
    }

    func test_hostAssistantMessageRepaintsTheDeskAndARewriteReplacesTheBubble() throws {
        // WHY: the desk shows a notice the moment it posts, and a resolution
        // rewrite must update that bubble, never add a second one.
        let (_, router, vm) = try makeFixture()
        let target = try XCTUnwrap(router.resolveTitioInbox(language: .en))
        try openInbox(vm, router: router, target: target)
        let id = AgentMessageID(TitioNoticeIDs.messageID(forKey: "run.R1.failed"))
        var conversation = try XCTUnwrap(router.context?.botStore.conversation(id: target.conversationID))
        conversation.unread = true
        conversation.attentionState = .needsAttention
        let message = AgentMessage(id: id, threadId: target.threadID, role: .assistant, content: "Uh-oh, **Build** failed.")
        vm.appendHostAssistantMessage(botID: target.botID, conversationID: target.conversationID,
                                      message: message, conversation: conversation)
        let rewritten = AgentMessage(id: id, threadId: target.threadID, role: .assistant,
                                     content: "Uh-oh, **Build** failed.\n\n_Seen._", createdAt: message.createdAt)
        vm.appendHostAssistantMessage(botID: target.botID, conversationID: target.conversationID,
                                      message: rewritten, conversation: conversation)
        let bubbles = vm.deskMessages.filter { $0.agentMessageID == id }
        XCTAssertEqual(bubbles.count, 1, "a rewrite never duplicates the bubble")
        XCTAssertEqual(bubbles.first?.text, rewritten.content)
        let bot = try XCTUnwrap(router.context?.botStore.get(id: target.botID))
        XCTAssertEqual(vm.attentionState(for: bot), .needsAttention, "an open decision keeps the roster on needs-you")
    }

    private func openInbox(_ vm: BotsViewModel, router: AppCommandRouter, target: TitioInboxTarget) throws {
        let bot = try XCTUnwrap(router.context?.botStore.get(id: target.botID))
        vm.reload()
        vm.openDesk(bot)
        vm.selectDeskThread(target.conversationID)
    }

    func test_openChatFromThePetLandsOnAMountedTitioConversation() throws {
        // WHY: the pet's "Open Chat" (router.openTitio) must show a usable
        // Titio chat. With only the Notifications inbox, the desk stayed on
        // "Loading…" because no Agent App view model was mounted.
        let (_, router, vm) = try makeFixture()
        let target = try XCTUnwrap(router.resolveTitioInbox(language: .en))
        vm.reload()
        _ = try router.openTitio()
        XCTAssertEqual(vm.selectedBotID, target.botID)
        let conversation = try XCTUnwrap(vm.selectedConversation, "a Titio conversation is selected")
        if conversation.linkedAgentThreadID != nil {
            XCTAssertNotNil(vm.deskAgentVM, "a linked conversation mounts its chat")
        }
    }

    func test_openChatFromThePetMountsTheChatWithCacheFirstNavigation() async throws {
        // WHY: the shell enables cache-first navigation; the pet's "Open Chat"
        // must still end on a mounted Titio chat after the freshness pass,
        // never on a "Loading…" strip.
        let (_, router, vm) = try makeFixture()
        vm.enableNavigationFirstFrameDeferral()
        let target = try XCTUnwrap(router.resolveTitioInbox(language: .en))
        _ = try router.openTitio()
        await vm.waitForNavigationFreshnessForTesting()
        XCTAssertEqual(vm.selectedBotID, target.botID)
        let conversation = try XCTUnwrap(vm.selectedConversation, "a Titio conversation is selected")
        if conversation.linkedAgentThreadID != nil {
            XCTAssertNotNil(vm.deskAgentVM, "a linked conversation mounts its chat")
        }
    }

    func test_openChatAfterTheHubPostedMountsTheInboxChat() async throws {
        // WHY: in the running app the hub is started and has posted into the
        // inbox before the user taps "Open Chat"; the desk must mount the chat.
        let (context, router, vm) = try makeFixture()
        vm.enableNavigationFirstFrameDeferral()
        vm.reload()
        _ = try XCTUnwrap(router.resolveTitioInbox(language: .en))
        context.titioNoticeCenter.start(subscribeToEvents: true)
        context.titioNoticeCenter.ingest(TitioNoticeFact(
            key: "notification.e2e-1", kind: .external, source: TitioNoticeSource(),
            facts: TitioNoticeFacts(title: "Deploy do elephant", body: "terminou")
        ))
        await context.titioNoticeCenter.idle()
        for _ in 0..<20 { await Task.yield() }
        _ = try router.openTitio()
        await vm.waitForNavigationFreshnessForTesting()
        await context.titioNoticeCenter.idle()
        for _ in 0..<20 { await Task.yield() }
        await vm.waitForNavigationFreshnessForTesting()
        let conversation = try XCTUnwrap(vm.selectedConversation, "a Titio conversation is selected")
        XCTAssertNotNil(conversation.linkedAgentThreadID)
        XCTAssertNotNil(vm.deskAgentVM, "the inbox chat is mounted, not a Loading strip")
    }

    func test_aBotWithNoConversationOffersTheComposerInsteadOfLoadingForever() async throws {
        // WHY: Titio (and any new Bot) starts with no conversation. The desk
        // used to sit on "Loading…" forever; it must offer the composer,
        // whose first send creates the conversation.
        let (_, router, vm) = try makeFixture()
        vm.enableNavigationFirstFrameDeferral()
        let titio = try TitioBot.ensure(store: try XCTUnwrap(router.context).botStore,
                                        appSupportDirectory: try XCTUnwrap(router.context).appSupportDirectory)
        vm.reload()
        _ = try router.openBotsDesk(botID: titio.id)
        await vm.waitForNavigationFreshnessForTesting()
        XCTAssertNil(vm.selectedConversation)
        XCTAssertTrue(vm.deskShowsNewConversationComposer)
    }

    func test_anInboxCreatedWhileTitiosEmptyDeskIsOpenBecomesTheOpenChat() async throws {
        // WHY: the user opened Titio before any notice; the first notice
        // creates the inbox and the open desk must show it, not stay empty.
        let (_, router, vm) = try makeFixture()
        vm.enableNavigationFirstFrameDeferral()
        let titio = try TitioBot.ensure(store: try XCTUnwrap(router.context).botStore,
                                        appSupportDirectory: try XCTUnwrap(router.context).appSupportDirectory)
        vm.reload()
        _ = try router.openBotsDesk(botID: titio.id)
        await vm.waitForNavigationFreshnessForTesting()
        let target = try XCTUnwrap(router.resolveTitioInbox(language: .en))
        let conversation = try XCTUnwrap(try router.context?.botStore.conversation(id: target.conversationID))
        vm.appendHostAssistantMessage(
            botID: target.botID, conversationID: target.conversationID,
            message: AgentMessage(threadId: target.threadID, role: .assistant, content: "Heads up: deploy done."),
            conversation: conversation
        )
        XCTAssertEqual(vm.selectedConversation?.id, target.conversationID)
        XCTAssertNotNil(vm.deskAgentVM, "the inbox chat mounts")
        XCTAssertFalse(vm.deskShowsNewConversationComposer)
    }

    func test_selectingTheInboxMarksItRead() throws {
        // WHY: opening the inbox on the Mac clears its unread count (§8 "Read state").
        let (_, router, vm) = try makeFixture()
        let target = try XCTUnwrap(router.resolveTitioInbox(language: .en))
        var selected: [BotConversationID] = []
        vm.onTitioInboxSelected = { selected.append($0) }
        try openInbox(vm, router: router, target: target)
        XCTAssertEqual(selected, [target.conversationID], "once per selection, not per repaint")
    }

    /// Posts a free-text question notice into the real inbox and taps
    /// "Reply here", so the hub holds a live arm.
    private func armReplyHere(_ context: AppContext, target: TitioInboxTarget) async throws -> String {
        let thread = AgentThreadID()
        let facts = TitioNoticeFacts(title: "Deploy", workspaceName: "api", prompt: "Which environment?")
        let key = TitioNoticeIDs.threadAttention(threadId: thread.value.uuidString, requestId: "Q1")
        context.titioNoticeCenter.ingest(TitioNoticeFact(
            key: key, kind: .userInput,
            source: TitioNoticeSource(threadId: thread.value.uuidString, requestId: "Q1"),
            facts: facts, actions: TitioNoticeAction.defaultActions(kind: .userInput, facts: facts)
        ))
        await context.titioNoticeCenter.idle()
        let messageID = TitioNoticeIDs.messageID(forKey: key).uuidString
        let outcome = await context.titioNoticeCenter.act(messageID: messageID, optionIndex: 0)
        XCTAssertEqual(outcome, .accepted)
        await context.titioNoticeCenter.settleActs()
        await context.titioNoticeCenter.idle()
        XCTAssertEqual(try TitioNoticeRepository(db: context.db).get(key: key)?.state, .awaitingReply)
        return key
    }

    func test_inboxDeskHooksTakeTheArmedReplyAndCardTapsWithoutStartingARun() async throws {
        // WHY: on the Mac the desk composer and the card bypass
        // enqueueHostMessage; without these hooks an armed answer or a card tap
        // would start a Titio LLM run instead of reaching the request.
        let (context, router, vm) = try makeFixture()
        let target = try XCTUnwrap(router.resolveTitioInbox(language: .en))
        let key = try await armReplyHere(context, target: target)
        try openInbox(vm, router: router, target: target)
        let desk = try XCTUnwrap(vm.deskAgentVM)
        XCTAssertNotNil(desk.embedding?.noticeChoiceHandler, "only the inbox desk acts on notice cards")
        XCTAssertNotNil(desk.embedding?.hostReplyHandler)

        desk.prompt = "use staging"
        await desk.send()
        XCTAssertEqual(desk.prompt, "", "the host took the text: the composer clears")
        await context.titioNoticeCenter.settleActs()
        await context.titioNoticeCenter.idle()
        XCTAssertNil(try context.runRepo.latestActive(for: target.threadID), "no Titio run started")
        let row = try XCTUnwrap(TitioNoticeRepository(db: context.db).get(key: key))
        XCTAssertEqual(row.state, .resolved, "the armed notice was answered (or honestly failed), never left armed")
        let texts = try context.messageRepo.list(threadId: target.threadID).map(\.content)
        XCTAssertTrue(texts.contains("use staging"), "the user's words stay in the inbox transcript")
    }

    func test_otherConversationsGetNoNoticeHooks() throws {
        // WHY: only the host's own inbox may route taps to the ledger; any
        // other Titio chat keeps today's text cards and composer.
        let (context, router, vm) = try makeFixture()
        let target = try XCTUnwrap(router.resolveTitioInbox(language: .en))
        let bot = try XCTUnwrap(context.botStore.get(id: target.botID))
        var chat = BotConversation(botID: bot.id, title: "Chat")
        try context.botStore.upsertConversation(chat)
        chat = try vm.ensureLinkedThread(
            bot: bot, conversation: chat, routing: vm.frozenDeskRouting(for: chat), router: router, markStarted: false
        ).conversation
        vm.reload()
        vm.openDesk(bot)
        vm.selectDeskThread(chat.id)
        let desk = try XCTUnwrap(vm.deskAgentVM)
        XCTAssertNil(desk.embedding?.noticeChoiceHandler)
        XCTAssertNil(desk.embedding?.hostReplyHandler)
        XCTAssertNil(vm.titioNoticeTurnDirective(conversationID: chat.id, threadID: target.threadID, userText: "oi"),
                     "the notice directive is for the inbox only")
    }

    func test_pairedSendIntoTheInboxIsTakenByAnArmAndStartsNoRun() async throws {
        // WHY: iOS `bot.send` goes through enqueueHostMessage; an armed reply
        // must answer the request there too instead of running Titio.
        let (context, router, vm) = try makeFixture()
        let target = try XCTUnwrap(router.resolveTitioInbox(language: .en))
        let key = try await armReplyHere(context, target: target)
        let receipt = try vm.enqueueHostMessage(botID: target.botID, text: "use staging", conversationID: target.conversationID,
                                                origin: .pairedClient(tapsNoticeCards: false))
        XCTAssertEqual(receipt.objectValue?["host_consumed"]?.boolValue, true)
        XCTAssertNil(receipt.objectValue?["run_id"], "no run id: nothing was started")
        await context.titioNoticeCenter.settleActs()
        await context.titioNoticeCenter.idle()
        XCTAssertNil(try context.runRepo.latestActive(for: target.threadID))
        XCTAssertEqual(try TitioNoticeRepository(db: context.db).get(key: key)?.state, .resolved)
    }

    func test_aClientThatTapsCardsNeverHasItsTextTakenAsAnOption() async throws {
        // WHY: current iOS taps cards through bot.notice.act. If its plain text
        // were still matched against option labels, the user typing a word
        // that equals a label (or an LLM's plain list echoed back) would act on
        // a notice. Only builds without the capability keep that fallback.
        let (context, router, vm) = try makeFixture()
        let target = try XCTUnwrap(router.resolveTitioInbox(language: .en))
        let thread = AgentThreadID()
        let facts = TitioNoticeFacts(title: "Deploy", workspaceName: "api", prompt: "Which environment?",
                                     options: ["staging", "production"])
        let key = TitioNoticeIDs.threadAttention(threadId: thread.value.uuidString, requestId: "Q2")
        context.titioNoticeCenter.ingest(TitioNoticeFact(
            key: key, kind: .userInput,
            source: TitioNoticeSource(threadId: thread.value.uuidString, requestId: "Q2"),
            facts: facts, actions: TitioNoticeAction.defaultActions(kind: .userInput, facts: facts)
        ))
        await context.titioNoticeCenter.idle()
        XCTAssertEqual(try TitioNoticeRepository(db: context.db).get(key: key)?.state, .posted)

        let receipt = try vm.enqueueHostMessage(botID: target.botID, text: "staging", conversationID: target.conversationID,
                                                origin: .pairedClient(tapsNoticeCards: true))
        XCTAssertNil(receipt.objectValue?["host_consumed"], "a card-tapping client's text is ordinary chat")
        await context.titioNoticeCenter.settleActs()
        XCTAssertEqual(try TitioNoticeRepository(db: context.db).get(key: key)?.state, .posted, "the notice stays open")
    }

    func test_agentHostToolsCannotAnswerANoticeOrWriteIntoTheInbox() async throws {
        // WHY (§0.2): `rc_bot_send` / `rc_bot_delegate` reach enqueueHostMessage
        // with any conversation id. An LLM (or a prompt injection) sending an
        // option's text, or any text while "Reply here" is armed, approved or
        // answered a request for the user.
        let (context, router, vm) = try makeFixture()
        let target = try XCTUnwrap(router.resolveTitioInbox(language: .en))
        let key = try await armReplyHere(context, target: target)
        XCTAssertThrowsError(try vm.enqueueHostMessage(botID: target.botID, text: "use staging",
                                                       conversationID: target.conversationID))
        await context.titioNoticeCenter.settleActs()
        await context.titioNoticeCenter.idle()
        XCTAssertEqual(try TitioNoticeRepository(db: context.db).get(key: key)?.state, .awaitingReply,
                       "the arm is still the user's")
        XCTAssertFalse(try context.messageRepo.list(threadId: target.threadID).map(\.content).contains("use staging"),
                       "nothing was written into the inbox as the user")
    }

    func test_aDeskRestoredOntoTheInboxAtLaunchMountsWithItsNoticeHooks() throws {
        // WHY: the inbox id was in memory only and set when the hub resolved
        // the inbox, after the restored desk had mounted. That desk drew the
        // notice as a plain card and sent "Approve" to Titio's LLM as text.
        let (context, router, firstVM) = try makeFixture()
        let target = try XCTUnwrap(router.resolveTitioInbox(language: .en))
        withExtendedLifetime(firstVM) {}
        let relaunched = BotsViewModel(context: context, router: router)
        router.botsViewModel = relaunched
        XCTAssertEqual(relaunched.titioInboxConversationID, target.conversationID, "seeded from the ledger")
        try openInbox(relaunched, router: router, target: target)
        let desk = try XCTUnwrap(relaunched.deskAgentVM)
        XCTAssertNotNil(desk.embedding?.noticeChoiceHandler, "the restored inbox desk acts on notice cards")
        XCTAssertNotNil(desk.embedding?.hostReplyHandler)
    }

    func test_theInboxRouteIsLockedAgainstAPairedProviderChange() throws {
        // WHY: a new provider would replace the inbox thread that holds every
        // notice (§16); the host answers the route it keeps.
        let (context, router, vm) = try makeFixture()
        defer { withExtendedLifetime(vm) {} }
        let target = try XCTUnwrap(router.resolveTitioInbox(language: .en))
        let conversation = try XCTUnwrap(context.botStore.conversation(id: target.conversationID))
        let frozen = vm.frozenDeskRouting(for: conversation)
        var other = frozen
        other.provider = .claude
        other.providerInstanceID = "claude"
        let adopted = try vm.adoptRemoteDeskRouting(other, botID: target.botID, conversationID: target.conversationID)
        XCTAssertEqual(adopted.provider, frozen.provider)
        XCTAssertEqual(try router.resolveTitioInbox(language: .en)?.threadID, target.threadID, "same thread afterwards")
    }

    func test_freeTextInTheInboxCarriesTheNoticeDirective() async throws {
        // WHY: the provider session never saw the rows the host wrote; the
        // directive lists them and forbids Titio from approving on its own.
        let (context, router, vm) = try makeFixture()
        let target = try XCTUnwrap(router.resolveTitioInbox(language: .en))
        context.titioNoticeCenter.ingest(TitioNoticeFact(
            key: "run.R1.failed", kind: .runFailed,
            facts: TitioNoticeFacts(title: "Build", workspaceName: "api"), actions: [.openThread, .ack]
        ))
        await context.titioNoticeCenter.idle()
        let directive = try XCTUnwrap(vm.titioNoticeTurnDirective(
            conversationID: target.conversationID, threadID: target.threadID, userText: "what failed?"
        ))
        XCTAssertTrue(directive.contains("run.R1.failed"))
        XCTAssertTrue(directive.hasSuffix(TitioNoticeDirective.closingRule))
        XCTAssertEqual(
            BotsViewModel.combinedTurnDirective("peer", nil, " ", directive),
            "peer\n\n" + directive,
            "the peer directive keeps its place before the inbox directive"
        )
    }

    func test_petCountsSkipTheInboxConversation() {
        // WHY: no BotAttentionItem is created for notices and the pet must not
        // count the inbox's unread state on top of its own speech bubble.
        let bot = BotDefinition(handle: "titio", name: "Titio", title: "", description: "")
        let inbox = BotConversation(botID: bot.id, title: "Notifications", unread: true, attentionState: .needsAttention)
        let other = BotConversation(botID: bot.id, title: "Chat", unread: true, attentionState: .unreadActivity)
        let items = PetAttentionStore.projectDest(PetDestAttentionSnapshot(
            bots: [bot], conversations: [inbox, other], attention: [],
            excludedConversationIDs: [inbox.id]
        ))
        XCTAssertEqual(items.map(\.id), ["bot.conversation:\(other.id.value.uuidString)"])
    }
}
