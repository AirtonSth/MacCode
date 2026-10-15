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

    func test_selectingTheInboxMarksItRead() throws {
        // WHY: opening the inbox on the Mac clears its unread count (§8 "Read state").
        let (_, router, vm) = try makeFixture()
        let target = try XCTUnwrap(router.resolveTitioInbox(language: .en))
        var selected: [BotConversationID] = []
        vm.onTitioInboxSelected = { selected.append($0) }
        try openInbox(vm, router: router, target: target)
        XCTAssertEqual(selected, [target.conversationID], "once per selection, not per repaint")
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
