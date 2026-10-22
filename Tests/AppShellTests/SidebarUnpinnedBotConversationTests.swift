import XCTest
import CoreModel
@testable import AppShell
import Persistence

/// A workspace Bot's plain conversations (no context pin) must list under the workspace
/// it can read, whoever started them. These drive `SidebarViewModel.loadSidebarTree` directly.
@MainActor
final class SidebarUnpinnedBotConversationTests: XCTestCase {
    private func make(_ name: String) throws -> (context: AppContext, directory: String) {
        let directory = NSTemporaryDirectory() + "RC2SidebarUnpinned-\(name)-" + UUID().uuidString
        return (try AppContext(channel: .debug, appSupportOverride: directory), directory)
    }

    /// Thread with no workspace, actor-locked to the Bot, and its Bot conversation with no context pin.
    @discardableResult
    private func unpinnedConversation(_ context: AppContext, bot: BotDefinition, title: String, hidden: Bool = false) throws -> AgentThreadID {
        let thread = AgentThread(workspaceId: nil, title: title, provider: .distill, model: "fixture", actor: .bot(bot.id), actorLockedAt: Date())
        try context.threadRepo.upsert(thread)
        var conversation = BotConversation(botID: bot.id, title: title, linkedAgentThreadID: thread.id)
        conversation.hidden = hidden
        try context.botStore.upsertConversation(conversation)
        return thread.id
    }

    private func rows(_ context: AppContext, _ workspace: WorkspaceID) throws -> [SidebarViewModel.WorkspaceConversationRow] {
        let tree = SidebarViewModel.loadSidebarTree(
            botStore: context.botStore, threadRepo: context.threadRepo,
            hostID: context.liveActivityHostIdentity.serverId, expanded: [workspace]
        )
        return try XCTUnwrap(tree?.conversations[workspace])
    }

    func test_emptyThreadsStayOutOfTheSidebarUntilTheyHaveAMessageOrAreOpen() throws {
        // WHY: opening "New conversation" or a Bot must not leave empty "New thread" rows behind.
        let (context, directory) = try make("empty")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let workspace = WorkspaceID(UUID())
        let empty = AgentThread(workspaceId: workspace, title: "", provider: .distill, model: "fixture", actor: .bot(BotID()), actorLockedAt: Date())
        let used = AgentThread(workspaceId: workspace, title: "Used", provider: .distill, model: "fixture")
        try context.threadRepo.upsert(empty)
        try context.threadRepo.upsert(used)
        let load = { (keep: Set<AgentThreadID>) in
            SidebarViewModel.loadSidebarTree(
                botStore: context.botStore, threadRepo: context.threadRepo,
                hostID: context.liveActivityHostIdentity.serverId, expanded: [workspace],
                keepUntitled: keep, hasMessages: { $0 == used.id }
            )?.conversations[workspace]?.map(\.threadID) ?? []
        }
        XCTAssertEqual(load([]), [used.id], "an empty thread is hidden")
        XCTAssertEqual(Set(load([empty.id])), [empty.id, used.id], "the open or running thread still shows")
    }

    func test_unpinnedBotConversationListsUnderTheBotsReadableWorkspaceNotItsStaleWorkspaceID() throws {
        // WHY: a Desk-first send or scheduled run never gets a pin; the sidebar must still show it under the Bot's live binding.
        let (context, directory) = try make("listed")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let bound = WorkspaceID(UUID()), stale = WorkspaceID(UUID())
        let bot = try context.botStore.create(name: "Star", title: "", description: "", handle: "star", workspaceID: stale)
        _ = try context.botStore.grantContext(hostID: context.liveActivityHostIdentity.serverId, botID: bot.id, context: .workspace(bound), actions: [.read, .send], expectedRevision: 0)
        let threadID = try unpinnedConversation(context, bot: bot, title: "Desk first send")

        XCTAssertEqual(try rows(context, bound).map(\.threadID), [threadID])
        XCTAssertEqual(try rows(context, bound).first?.botID, bot.id)
    }

    func test_revokedBindingHidesUnpinnedBotConversation() throws {
        // WHY: revoking a Bot's read grant must remove its conversations from that workspace's list.
        let (context, directory) = try make("revoked")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let workspace = WorkspaceID(UUID())
        let bot = try context.botStore.create(name: "Star", title: "", description: "", handle: "star")
        let grant = try context.botStore.grantContext(hostID: context.liveActivityHostIdentity.serverId, botID: bot.id, context: .workspace(workspace), actions: [.read], expectedRevision: 0)
        try unpinnedConversation(context, bot: bot, title: "Scheduled run")
        XCTAssertEqual(try rows(context, workspace).count, 1)

        _ = try context.botStore.revokeContext(hostID: context.liveActivityHostIdentity.serverId, botID: bot.id, context: .workspace(workspace), expectedRevision: grant.policyRevision)
        XCTAssertTrue(try rows(context, workspace).isEmpty, "a revoked Bot must not keep listing its conversations")
    }

    func test_hiddenUnpinnedBotConversationIsNotListed() throws {
        // WHY: a conversation the user hid must stay out of the sidebar even though it is unpinned.
        let (context, directory) = try make("hidden")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let workspace = WorkspaceID(UUID())
        let bot = try context.botStore.create(name: "Star", title: "", description: "", handle: "star")
        _ = try context.botStore.grantContext(hostID: context.liveActivityHostIdentity.serverId, botID: bot.id, context: .workspace(workspace), actions: [.read], expectedRevision: 0)
        try unpinnedConversation(context, bot: bot, title: "Hidden run", hidden: true)

        XCTAssertTrue(try rows(context, workspace).isEmpty)
    }

    func test_unpinnedBotConversationIsNotListedUnderAWorkspaceTheBotIsNotBoundTo() throws {
        // WHY: a Bot's conversations must never leak into a workspace it has no read grant for.
        let (context, directory) = try make("foreign")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let bound = WorkspaceID(UUID()), foreign = WorkspaceID(UUID())
        let bot = try context.botStore.create(name: "Star", title: "", description: "", handle: "star")
        _ = try context.botStore.grantContext(hostID: context.liveActivityHostIdentity.serverId, botID: bot.id, context: .workspace(bound), actions: [.read], expectedRevision: 0)
        try unpinnedConversation(context, bot: bot, title: "Bound only")

        XCTAssertTrue(try rows(context, foreign).isEmpty)
    }

    func test_sidebarWorkspacePrefersTheBotsOwnBoundWorkspace() throws {
        // WHY: when the Bot's own workspace is readable it wins; otherwise the choice must be stable.
        let (context, directory) = try make("resolver")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let first = WorkspaceID(UUID()), second = WorkspaceID(UUID()), unbound = WorkspaceID(UUID())
        let hostID = context.liveActivityHostIdentity.serverId
        func binding(_ workspace: WorkspaceID, state: BotContextBindingState = .active, actions: Set<BotContextAction> = [.read]) -> BotContextBinding {
            BotContextBinding(hostID: hostID, botID: BotID(), context: .workspace(workspace), state: state, policyRevision: 1, actions: actions)
        }
        let bot = try context.botStore.create(name: "Star", title: "", description: "", handle: "star", workspaceID: second)
        let bindings = [binding(first), binding(second)]

        XCTAssertEqual(SidebarViewModel.sidebarWorkspace(for: bot, bindings: bindings), second)
        let unboundOwn = try context.botStore.create(name: "Other", title: "", description: "", handle: "other", workspaceID: unbound)
        let expected = [first, second].min { $0.value.uuidString < $1.value.uuidString }
        XCTAssertEqual(SidebarViewModel.sidebarWorkspace(for: unboundOwn, bindings: bindings), expected)
        XCTAssertNil(SidebarViewModel.sidebarWorkspace(for: bot, bindings: [binding(first, state: .revoked), binding(second, actions: [.send])]),
                     "revoked or send-only bindings give no sidebar workspace")
    }

    func test_scheduleWorkspaceFollowsTheSidebarBindingNotTheStaleOwner() throws {
        // WHY: Schedule Tasks (Mac list, scheduled_task.list, Titio) must group a Bot's schedules
        // under the workspace the sidebar lists the Bot in, which is where its runs pin.
        let (context, directory) = try make("schedule")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let owner = WorkspaceID(UUID()), bound = WorkspaceID(UUID())
        let hostID = context.liveActivityHostIdentity.serverId
        let bot = try context.botStore.create(name: "Star", title: "", description: "", handle: "star", workspaceID: owner)
        XCTAssertEqual(SidebarViewModel.scheduleWorkspace(for: bot, botStore: context.botStore, hostID: hostID), owner,
                       "without bindings the Bot's own workspace is used")
        try context.botStore.grantContext(hostID: hostID, botID: bot.id, context: .workspace(bound), actions: [.read, .send], expectedRevision: nil)
        XCTAssertEqual(SidebarViewModel.scheduleWorkspace(for: bot, botStore: context.botStore, hostID: hostID), bound)

        let routine = BotRoutine(
            definition: BotRoutineDefinition(botID: bot.id, name: "r", prompt: "p", scheduleNote: "Daily"),
            activation: BotRoutineActivation(routineID: BotRoutineID(), botID: bot.id, isEnabled: true))
        let wire = ScheduledTaskRemoteWire.encodeRoutine(routine, bot: bot, workspaceID: bound)
        guard case .object(let fields) = wire, case .string(let wired)? = fields["workspace_id"] else {
            return XCTFail("scheduled_task.list Bot rows must carry workspace_id")
        }
        XCTAssertEqual(wired, bound.value.uuidString.lowercased())
    }
}
