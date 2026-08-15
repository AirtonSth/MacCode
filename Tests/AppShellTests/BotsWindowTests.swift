import XCTest
import CoreModel
@testable import AppShell
@testable import Persistence

@MainActor
final class BotsWindowTests: XCTestCase {
    private var directory: String!

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "rc-bots-window-\(UUID().uuidString)"
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(atPath: directory)
        }
        directory = nil
    }

    func test_openHomeShowsFleetOverview_becauseThePlanSeparatesRosterFromChat() throws {
        // WHY: Fleet Home is the selected-bot overview. Opening it must not
        // dump the user into Desk, or roster selection becomes a fake chat.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        XCTAssertEqual(vm.screen, .desk)
        vm.openHome(bot)
        XCTAssertEqual(vm.screen, .fleet)
        XCTAssertEqual(vm.selectedBotID, bot.id)
        XCTAssertEqual(vm.providerLabel(for: bot), "Claude")
        XCTAssertEqual(try XCTUnwrap(vm.selectedBot).title, "Scout")
    }

    func test_providerChipFollowsThePublishedRevision_becauseHomeMustNotHardcodeClaude() throws {
        // WHY: a Grok teammate shown as "Claude" teaches the user the
        // overview is decorative. The chip is the live route, not a mock.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let grok = try vm.create(name: "Quinn", title: "Reviewer", provider: .grok)
        XCTAssertEqual(vm.providerLabel(for: grok), "Grok")
        vm.openHome(grok)
        XCTAssertEqual(vm.providerLabel(for: grok), "Grok")
        XCTAssertEqual(vm.resolvedProvider(for: grok), .grok)
    }

    func test_openFleetSelectsFirstTeammate_becauseHomeNeedsASelectedBot() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.selectedBotID = nil
        vm.openFleet()
        XCTAssertEqual(vm.selectedBotID, bot.id)
        XCTAssertEqual(vm.screen, .fleet)
    }

    func test_reloadOnFleetSelectsFirstTeammate_becauseSidebarOpenMustLandOnOverview() throws {
        // WHY: first paint of Bots is reload(), not openFleet(). A nil
        // selection would show the empty list instead of the selected overview.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.selectedBotID = nil
        vm.screen = .fleet
        vm.reload()
        XCTAssertEqual(vm.selectedBotID, bot.id)
        XCTAssertEqual(vm.screen, .fleet)
    }

    func test_openChatFromHomeOpensDesk_becauseConversationLivesOnDeskNotFleet() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openHome(bot)
        XCTAssertEqual(vm.screen, .fleet)
        vm.openDesk(bot)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.detailTab, .desk)
    }

    func test_studioFromHomeOpensStudio_becauseBrainEditsStayOffTheOverview() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openHome(bot)
        vm.beginEdit(bot)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioDraft.botID, bot.id)
    }

    func test_fleetHomeCountsAreLive_becauseOverviewMustNotInventCapacity() throws {
        // WHY: Memory/Skills/Routines/Approvals are owner-facing truth.
        // Hardcoded 87% / 12 skills / "Running • macOS VM" would be a lie.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try context.botStore.putMemory(
            botID: bot.id,
            content: "Prefers dark mode",
            provenance: "user",
            trusted: true,
            source: "studio"
        )
        let forgotten = try context.botStore.putMemory(
            botID: bot.id,
            content: "Old secret",
            provenance: "user",
            trusted: true,
            source: "studio"
        )
        try context.botStore.forgetMemory(id: forgotten.id)
        try context.botStore.setSkillBinding(
            BotSkillBinding(botID: bot.id, skillID: "weekly-account-health", enabled: true)
        )
        try context.botStore.setSkillBinding(
            BotSkillBinding(botID: bot.id, skillID: "off-skill", enabled: false)
        )
        try context.botStore.saveRoutine(
            BotRoutineDefinition(
                botID: bot.id,
                name: "Morning scan",
                prompt: "Scan overnight failures",
                scheduleNote: "Weekdays 9:00"
            )
        )
        let routine = try XCTUnwrap(context.botStore.listRoutines(botID: bot.id).first)
        try context.botStore.setRoutineEnabled(id: routine.definition.id, enabled: true)
        try context.botStore.upsertAttention(
            BotAttentionItem(botID: bot.id, kind: .approval, title: "Approve vendor brief")
        )

        vm.openHome(bot)

        XCTAssertEqual(vm.liveMemoryCount, 1, "forgotten facts must not inflate Memory")
        XCTAssertEqual(vm.enabledSkillCount, 1, "disabled skills must not inflate Skills")
        XCTAssertEqual(vm.enabledRoutineCount, 1)
        XCTAssertEqual(vm.pendingApprovalCount, 1)
        XCTAssertFalse(vm.isAutonomyActive, "P1a routines stay app-closed off")
    }

    func test_beginCreateOpensDeskImmediately_becauseATeammateShouldNotRequireStudioFirst() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.beginCreate()

        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(try context.botStore.list().count, 1)
        XCTAssertEqual(try context.botStore.list().first?.name, "New Agent")
        XCTAssertTrue(try context.threadRepo.list().isEmpty)
    }

    func test_beginCreateTwiceAllocatesDistinctHandles_becauseNewAgentIsAPlaceholder() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.beginCreate()
        vm.beginCreate()
        let bots = try context.botStore.list()
        XCTAssertEqual(bots.count, 2)
        XCTAssertEqual(Set(bots.map(\.handle)).count, 2)
        XCTAssertTrue(bots.allSatisfy { $0.name == "New Agent" })
    }

    func test_openDeskMarksUnreadConversationRead_becauseOpeningTheChatClearsFleetAttention() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Standup", unread: true, attentionState: .unreadActivity)
        )
        vm.reload()
        vm.openDesk(bot)

        let conversation = try XCTUnwrap(context.botStore.listConversations(botID: bot.id).first)
        XCTAssertFalse(conversation.unread)
        XCTAssertEqual(conversation.attentionState, .none)
    }

    func test_createViaVM_persistsThroughBotStoreList_becauseATeammateIsNotAnAgentThread() throws {
        // WHY: a durable teammate must be creatable without becoming an AgentThread.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)

        let bot = try vm.create(
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            handle: "piper",
            soul: "Be brief.",
            provider: .claude
        )

        let listed = try context.botStore.list()
        XCTAssertEqual(listed.map(\.id), [bot.id])
        XCTAssertEqual(listed.first?.name, "Piper")
        XCTAssertEqual(listed.first?.handle, "piper")
        XCTAssertTrue(try context.threadRepo.list().isEmpty, "creating a Bot must not open an AgentThread")
        XCTAssertNotEqual(bot.id.value, AgentThreadID().value)
    }

    func test_duplicateDoesNotCopyConversationsOrMemory_becauseCopiesAreNewTeammates() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try context.botStore.putMemory(
            botID: bot.id,
            content: "Prefers dark mode",
            provenance: "user",
            trusted: true,
            source: "chat"
        )
        try context.botStore.upsertConversation(BotConversation(botID: bot.id, title: "Standup"))

        let copy = try vm.duplicate(id: bot.id)

        XCTAssertNotEqual(copy.id, bot.id)
        XCTAssertEqual(copy.name, "Piper copy")
        XCTAssertTrue(try context.botStore.listMemory(botID: copy.id).isEmpty)
        XCTAssertTrue(try context.botStore.listConversations(botID: copy.id).isEmpty)
        XCTAssertEqual(try context.botStore.listMemory(botID: bot.id).count, 1)
        XCTAssertEqual(try context.botStore.listConversations(botID: bot.id).count, 1)
    }

    func test_desktopLabelContainsNotIsolated_becauseP1aMustNotClaimAVM() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        XCTAssertTrue(
            vm.desktopHonestyLabel.lowercased().contains("not isolated"),
            "Studio must repeat the logical-space honesty label"
        )
        XCTAssertEqual(
            vm.desktopHonestyLabel,
            "Same macOS account; not isolated. Not a dedicated Desktop."
        )
        XCTAssertTrue(
            BotDesktopKind.logicalExecutionSpaceHonestyLabel.lowercased().contains("not isolated")
        )

        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("desktopHonestyLabel"))
        XCTAssertTrue(source.contains("Not shipped"))
        XCTAssertFalse(source.contains("Isolated / Dedicated VM"))
        XCTAssertFalse(
            source.contains("Running • macOS VM"),
            "Fleet Home must not paint the concept's fake dedicated VM"
        )
        XCTAssertFalse(
            source.contains("Dedicated Desktop"),
            "P1a has no dedicated Desktop; the concept screenshot is not the contract"
        )
        XCTAssertTrue(source.contains("bots.home.desktop.honesty"))
        XCTAssertTrue(source.contains("BotRoutineCopy.testRunHonestyCaption"))
        XCTAssertTrue(source.contains("no app-closed runs"))
        XCTAssertFalse(
            source.contains("isAutonomyActive ? \"active\""),
            "autonomy-on must not imply app-closed execution"
        )
    }

    func test_attentionItemAppearsAfterSendThatNeedsTheUser() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.send("Please look at the failing test")

        let attention = try context.botStore.listAttention()
        XCTAssertEqual(attention.count, 1, "a send that cannot start a provider run must land in Attention")
        XCTAssertEqual(attention.first?.botID, bot.id)
        XCTAssertEqual(attention.first?.kind, .question)
        XCTAssertEqual(try context.botStore.listConversations(botID: bot.id).count, 1)
        XCTAssertEqual(vm.deskMessages.first?.text, "Please look at the failing test")
        XCTAssertEqual(vm.deskMessages.last?.text, BotsViewModel.assistantPlaceholder)
        XCTAssertFalse(vm.lastSendStartedProviderRun)
    }

    func test_followThroughLeavesWorkingWhenRunCompletes_becauseTheDeskMustShowAResult() {
        // WHY: Grok Bot keeps the user in the same conversation until work
        // finishes; a started run that never leaves "Working…" is not a teammate.
        XCTAssertEqual(BotsDeskFollowThrough.conversationState(for: .running), .working)
        XCTAssertEqual(BotsDeskFollowThrough.conversationState(for: .completed), .unreadActivity)
        XCTAssertEqual(BotsDeskFollowThrough.conversationState(for: .failed), .needsAttention)
        XCTAssertEqual(
            BotsDeskFollowThrough.conversationState(for: .completed, viewingDesk: true),
            .none,
            "the open Desk is already being read; Unread is for the rest of the fleet"
        )
        XCTAssertEqual(
            BotsDeskFollowThrough.conversationState(for: .completed, viewingDesk: false),
            .unreadActivity
        )
        XCTAssertNil(BotsDeskFollowThrough.attentionKind(for: .completed))
        XCTAssertEqual(BotsDeskFollowThrough.attentionKind(for: .failed), .blocked)
        XCTAssertTrue(BotsDeskFollowThrough.isTerminal(.completed))
        XCTAssertFalse(BotsDeskFollowThrough.isTerminal(.running))
    }

    func test_rosterPreviewPrefersLastDeskLine_becauseGrokShowsTheLastLine() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.send("Say hello in one short sentence.")
        XCTAssertEqual(vm.rosterPreview(for: bot), BotsViewModel.assistantPlaceholder)
    }

    func test_openDeskHidesUnreadOnTheViewedBot_becauseYouAreAlreadyReadingIt() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Standup", unread: true, attentionState: .unreadActivity)
        )
        vm.reload()
        XCTAssertEqual(vm.attentionState(for: bot), .unreadActivity)
        vm.openDesk(bot)
        XCTAssertEqual(vm.attentionState(for: bot), .none)
    }

    func test_studioDoesNotHideUnread_becauseOnlyTheOpenDeskIsBeingRead() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Standup", unread: true, attentionState: .unreadActivity)
        )
        vm.reload()
        vm.beginEdit(bot)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.attentionState(for: bot), .unreadActivity)
    }

    func test_markingDeskReadDoesNotRewriteActivityTimestamp() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)
        try context.botStore.upsertConversation(
            BotConversation(
                botID: bot.id,
                title: "Standup",
                unread: true,
                attentionState: .unreadActivity,
                createdAt: stamped,
                updatedAt: stamped
            )
        )
        vm.openDesk(bot)
        let stored = try XCTUnwrap(context.botStore.listConversations(botID: bot.id).first)
        XCTAssertEqual(stored.updatedAt, stamped)
        XCTAssertFalse(stored.unread)
    }

    func test_followThroughOnBackgroundBotDoesNotOverwriteOpenDesk() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        let piperConversation = BotConversation(botID: piper.id, title: "From Piper")
        try context.botStore.upsertConversation(piperConversation)
        vm.openDesk(quinn)
        let quinnMessages = vm.deskMessages

        vm.applyFollowThroughForTests(bot: piper, conversation: piperConversation, status: .completed)

        XCTAssertEqual(vm.selectedBotID, quinn.id)
        XCTAssertEqual(vm.deskMessages, quinnMessages)
        XCTAssertEqual(
            try context.botStore.listConversations(botID: piper.id).first?.attentionState,
            .unreadActivity
        )
        XCTAssertEqual(vm.attentionState(for: piper), .unreadActivity)
        XCTAssertEqual(vm.attentionState(for: quinn), .none)
    }

    func test_visibleDeskMessagesPrefersPersistedAssistantOverWorkingCache() {
        // WHY: follow-through must replace the local "Working…" bubble with
        // the linked thread's assistant reply or the user cannot review the result.
        let cached = [
            BotDeskMessage(role: .user, text: "Summarize overnight"),
            BotDeskMessage(role: .assistant, text: BotsDeskFollowThrough.workingPlaceholder),
        ]
        let persisted = [
            BotDeskMessage(role: .user, text: "Summarize overnight"),
            BotDeskMessage(role: .assistant, text: "Three failing tests remain."),
        ]
        let visible = BotsDeskFollowThrough.visibleDeskMessages(cached: cached, persisted: persisted)
        XCTAssertEqual(visible.last?.text, "Three failing tests remain.")
        XCTAssertFalse(visible.contains { $0.text == BotsDeskFollowThrough.workingPlaceholder })
    }

    func test_displayUserTextStripsProviderEnvelope_becauseTheDeskMustShowTheTeammateLine() {
        let envelope = """
        You are Piper — Scout.

        User request:

        Summarize overnight
        """
        XCTAssertEqual(BotsDeskFollowThrough.displayUserText(from: envelope), "Summarize overnight")
        XCTAssertEqual(BotsDeskFollowThrough.displayUserText(from: "Just the ask"), "Just the ask")
    }

    func test_composeRunPromptIncludesTrustedMemoryAndEnabledSkills() {
        let bot = BotDefinition(handle: "piper", name: "Piper", title: "Scout", description: "Looks around")
        let revision = BotRevision(
            botID: bot.id,
            revisionNumber: 1,
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            soul: "Be brief.",
            provider: .claude,
            providerInstanceID: "claude",
            model: "opus",
            reasoningEffort: .medium,
            compatibleRouteSet: ["default"],
            permissionMode: .supervised,
            desktopKind: .logicalExecutionSpace,
            digest: "x"
        )
        let live = BotMemoryItem(
            botID: bot.id,
            currentRevisionID: UUID(),
            content: "Prefers dark mode",
            provenance: "user",
            trusted: true,
            source: "chat"
        )
        var forgotten = live
        forgotten.content = "Old secret"
        forgotten.forgottenAt = Date()
        let enabled = BotSkillBinding(botID: bot.id, skillID: "weekly-account-health", enabled: true)
        let disabled = BotSkillBinding(botID: bot.id, skillID: "off-skill", enabled: false)

        let prompt = BotsDeskFollowThrough.composeRunPrompt(
            bot: bot,
            revision: revision,
            userText: "Summarize overnight",
            memory: [live, forgotten],
            skills: [enabled, disabled]
        )

        XCTAssertTrue(prompt.contains("Prefers dark mode"))
        XCTAssertFalse(prompt.contains("Old secret"))
        XCTAssertTrue(prompt.contains("weekly-account-health"))
        XCTAssertFalse(prompt.contains("off-skill"))
        XCTAssertTrue(prompt.contains("Summarize overnight"))
    }

    func test_hiddenBotsAreExcludedFromDefaultFleet() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", handle: "piper", provider: .claude)
        XCTAssertEqual(vm.fleet.map(\.id), [bot.id])

        vm.setHidden(id: bot.id, hidden: true)

        XCTAssertTrue(vm.fleet.isEmpty, "hidden bots must not appear in the default fleet")
        XCTAssertTrue(try context.botStore.list().isEmpty)
        XCTAssertEqual(try context.botStore.list(includeHidden: true).map(\.id), [bot.id])

        vm.showHidden = true
        XCTAssertEqual(vm.fleet.map(\.id), [bot.id])
    }

    func test_botsOpensInMainContent_andSidebarSitsUnderScheduleTasks() throws {
        let main = try String(contentsOf: sourceURL("Sources/AppShell/MainWindowController.swift"), encoding: .utf8)
        let sidebar = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)

        XCTAssertTrue(main.contains("presentBotsInMainContent"))
        XCTAssertTrue(main.contains("installBotsContent"))
        XCTAssertTrue(main.contains("vm.openFleet()"))
        XCTAssertTrue(main.contains("case bots"))
        XCTAssertTrue(main.contains("visibleWorkspaceLabel.stringValue = \"Bots\""))
        XCTAssertTrue(sidebar.contains("onPresentBots"))
        XCTAssertTrue(sidebar.contains("isBotsSelected"))
        XCTAssertTrue(sidebar.contains("setBotsSelected"))
        XCTAssertTrue(sidebar.contains("accessibilityIdentifier(\"sidebar.bots\")"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.new\")"))
        XCTAssertTrue(bots.contains("bots.fleet.row."))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.roster\")"))
        XCTAssertTrue(bots.contains("bots.roster.row."))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.home\")"))
        XCTAssertTrue(bots.contains("bots.home.chat"))
        XCTAssertTrue(bots.contains("bots.home.studio"))
        XCTAssertTrue(bots.contains("bots.home.desktop"))
        XCTAssertTrue(bots.contains("bots.home.activity"))
        XCTAssertTrue(bots.contains("bots.home.memory"))
        XCTAssertTrue(bots.contains("bots.home.skills"))
        XCTAssertTrue(bots.contains("bots.home.routines"))
        XCTAssertTrue(bots.contains("bots.home.approvals"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.composer\")"))
        XCTAssertFalse(main.contains("SurfaceType.bot"))
        XCTAssertFalse(bots.contains("SurfaceType.bot"))

        let scheduleTasks = try XCTUnwrap(sidebar.range(of: "accessibilityIdentifier(\"sidebar.scheduleTasks\")"))
        let botsRow = try XCTUnwrap(sidebar.range(of: "accessibilityIdentifier(\"sidebar.bots\")"))
        let reportBug = try XCTUnwrap(sidebar.range(of: "accessibilityIdentifier(\"sidebar.reportBug\")"))
        XCTAssertLessThan(scheduleTasks.lowerBound, botsRow.lowerBound)
        XCTAssertLessThan(botsRow.lowerBound, reportBug.lowerBound)
    }

    private func makeContext() throws -> AppContext {
        try AppContext(channel: .debug, appSupportOverride: directory)
    }

    private func sourceURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }
}
