import XCTest
import CoreModel
@testable import AppShell
@testable import Persistence
import Surfaces

@MainActor
final class BotsWindowTests: XCTestCase {
    private var directory: String!

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "rc-bots-window-\(UUID().uuidString)"
        UserDefaults.standard.removeObject(forKey: "bots.inspectorTab")
        UserDefaults.standard.removeObject(forKey: "bots.selectedBotID")
        UserDefaults.standard.removeObject(forKey: "bots.screen")
        UserDefaults.standard.removeObject(forKey: "bots.studioTab")
        UserDefaults.standard.removeObject(forKey: "bots.queuedFollowUps")
        UserDefaults.standard.removeObject(forKey: "bots.composerDrafts")
        UserDefaults.standard.removeObject(forKey: "bots.inspectorDrafts")
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(atPath: directory)
        }
        directory = nil
    }

    func test_deskSendAdmitsAndClearsAttachments_becauseAnexosMustReachTheTurn() async throws {
        // WHY: Desk must stage, preview, remove, and send files through the
        // real bot send path — not a decorative chip list. sendAgentMessage
        // only accepts blobs already in the managed agent-attachments store.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        let file = (directory as NSString).appendingPathComponent("brief.pdf")
        FileManager.default.createFile(atPath: file, contents: Data("hi".utf8))
        vm.addAttachments([file])
        XCTAssertEqual(vm.attachments.map(\.displayName), ["brief.pdf"])
        let staged = try XCTUnwrap(vm.attachments.first)
        XCTAssertNotEqual(staged.path, file, "raw user paths must be copied into the managed store")
        XCTAssertNotNil(staged.id)
        XCTAssertNotNil(staged.sha256)
        let store = AgentAttachmentStore(
            root: context.appSupportDirectory.appendingPathComponent("agent-attachments", isDirectory: true)
        )
        XCTAssertEqual(try store.validatedForRetry(staged), staged)

        vm.removeAttachment(staged)
        XCTAssertTrue(vm.attachments.isEmpty)
        vm.addAttachments([file])
        vm.composerText = ""
        XCTAssertTrue(vm.deskSendEnabled)

        let exp = expectation(description: "sendAgentMessage resolved attachments")
        var received: [AgentAttachment] = []
        router.sendAgentMessageResolvedAttachmentsProbeForTesting = { attachments in
            received = attachments
            exp.fulfill()
        }
        vm.send()
        XCTAssertTrue(vm.deskShowsLoading,
                      "Agent App shows Loading… the instant the user sends, before sendAgentMessage returns")
        XCTAssertTrue(vm.attachments.isEmpty, "send must consume staged files")
        XCTAssertEqual(vm.deskMessages.first?.text, "📎 brief.pdf")
        await fulfillment(of: [exp], timeout: 3)
        XCTAssertEqual(received.count, 1, "Bots send must call sendAgentMessage with the staged file")
        let sent = try XCTUnwrap(received.first)
        XCTAssertEqual(try store.validatedForRetry(sent), sent)
        XCTAssertTrue(sent.path.hasPrefix(store.root.path + "/"))
        router.sendAgentMessageResolvedAttachmentsProbeForTesting = nil
    }

    func test_deskWorkingLabelFollowsALiveWorkLog_becauseDeskMustShowWorking() throws {
        // WHY: a supervised run in Working must surface the Agent App thinking
        // label on Desk, not only the work-log status pill.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        try context.runRepo.upsert(AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: started
        ))
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Standup", linkedAgentThreadID: thread.id)
        )
        vm.openDesk(bot)
        XCTAssertTrue(vm.deskRunIsLive)
        XCTAssertEqual(
            vm.deskWorkingLabel(now: started.addingTimeInterval(9)),
            AgentWorkingStripPresentation.label(phase: .thinking, elapsedSeconds: 9)
        )
    }

    func test_deskReplaysStreamEventsOnOpen_becauseThinkingMustSurviveClose() throws {
        // WHY: Desk is not a second Agent App window, but it must replay the
        // linked thread's persisted stream events so Thought / Worked remain
        // after close/reopen. A Working… bubble cannot do that.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_010),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_040)
        )
        try context.runRepo.upsert(run)
        try persistStreamEvents(
            context: context,
            run: run,
            events: [
                .turnStarted(turnId: "t-desk"),
                .itemStarted(item: AssistantItem(
                    id: "r-desk",
                    turnId: "t-desk",
                    type: .reasoning,
                    state: .streaming,
                    body: "",
                    startedAtMs: 1_700_000_010_000
                )),
                .itemDelta(itemId: "r-desk", bodyAppend: "Checking overnight failures", outputAppend: nil, summary: nil),
                .itemCompleted(itemId: "r-desk", finalState: .completed),
                .itemStarted(item: AssistantItem(
                    id: "tool-desk",
                    turnId: "t-desk",
                    type: .tool,
                    state: .completed,
                    summary: "Bash",
                    body: #"{"command":"swift test"}"#,
                    startedAtMs: 1_700_000_020_000,
                    finishedAtMs: 1_700_000_030_000
                )),
                .turnCompleted(turnId: "t-desk", finalMessage: "Three failing tests remain."),
            ]
        )
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "Summarize overnight",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Summarize overnight", linkedAgentThreadID: thread.id)
        )

        vm.openDesk(bot)
        XCTAssertTrue(vm.deskPaintsLiveTurnChrome, "reopen must paint Work so far / Thought, not only bubbles")
        let turn = try XCTUnwrap(vm.deskLiveTimeline.turns.first)
        let reasoning = try XCTUnwrap(turn.items.first { $0.type == .reasoning })
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningTitle(isStreaming: reasoning.state == .streaming), "Thought")
        XCTAssertTrue(AgentChatLiveTurnChrome.reasoningText(reasoning).contains("Checking overnight"))
        XCTAssertTrue(AgentChatLiveTurnChrome.workItems(in: turn).contains { $0.type == .tool })
        XCTAssertEqual(turn.finalAssistantMessage, "Three failing tests remain.")
        XCTAssertFalse(
            vm.deskTimeline.contains { if case .workLog = $0 { return true }; return false },
            "Work so far replaces the generic Supervised-run card in the chat column"
        )
        XCTAssertTrue(vm.deskTimeline.contains { if case .liveTurn = $0 { return true }; return false })

        let reopened = BotsViewModel(context: context)
        reopened.openDesk(bot)
        XCTAssertTrue(reopened.deskPaintsLiveTurnChrome)
        XCTAssertEqual(reopened.deskLiveTimeline.turns.first?.finalAssistantMessage, "Three failing tests remain.")
        XCTAssertEqual(reopened.deskStreamEventCount, vm.deskStreamEventCount)
    }

    func test_deskWorkingStripSeesStreamingTools_becauseComposerMustNotHardcodeThinking() throws {
        // WHY: a live tool stream must flip the composer phase to Tools. The old
        // Desk path always passed hasStreamingTools:false, so thinking never
        // looked like Agent App even while commands ran.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let run = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: started
        )
        try context.runRepo.upsert(run)
        try persistStreamEvents(
            context: context,
            run: run,
            events: [
                .turnStarted(turnId: "t-live"),
                .itemStarted(item: AssistantItem(
                    id: "r-live",
                    turnId: "t-live",
                    type: .reasoning,
                    state: .completed,
                    body: "Need to run tests",
                    startedAtMs: 1,
                    finishedAtMs: 2
                )),
                .itemStarted(item: AssistantItem(
                    id: "tool-live",
                    turnId: "t-live",
                    type: .tool,
                    state: .streaming,
                    summary: "Bash",
                    body: #"{"command":"swift test"}"#,
                    startedAtMs: 3
                )),
            ]
        )
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Standup", linkedAgentThreadID: thread.id)
        )
        vm.openDesk(bot)
        XCTAssertTrue(vm.deskHasStreamingTools)
        XCTAssertTrue(vm.deskPaintsLiveTurnChrome)
        XCTAssertEqual(
            vm.deskWorkingLabel(now: started.addingTimeInterval(9)),
            AgentWorkingStripPresentation.label(phase: .tools, elapsedSeconds: 9)
        )
        let live = try XCTUnwrap(vm.deskLiveTimeline.turns.first)
        let composition = AgentChatLiveTurnChrome.compose(live)
        XCTAssertEqual(composition.reasoning.map(\.type), [.reasoning])
        XCTAssertEqual(composition.work.map(\.type), [.tool])
        XCTAssertTrue(composition.outside.isEmpty)
    }

    func test_refreshDeskLiveTurnPicksUpNewStreamEvents_becauseThinkingMustAppearLive() throws {
        // WHY: followLinkedRun used to poll only run status. Thinking cannot
        // appear unless Desk also hydrates new stream events on the linked thread.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: Date()
        )
        try context.runRepo.upsert(run)
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Standup", linkedAgentThreadID: thread.id)
        )
        vm.openDesk(bot)
        XCTAssertFalse(vm.deskPaintsLiveTurnChrome)

        try persistStreamEvents(
            context: context,
            run: run,
            events: [
                .turnStarted(turnId: "t-new"),
                .itemStarted(item: AssistantItem(
                    id: "r-new",
                    turnId: "t-new",
                    type: .reasoning,
                    state: .streaming,
                    body: "Looking at the brief",
                    startedAtMs: 10
                )),
            ]
        )
        vm.refreshDeskLiveTurn()
        XCTAssertTrue(vm.deskPaintsLiveTurnChrome)
        let reasoning = try XCTUnwrap(
            vm.deskLiveTimeline.turns.first?.items.first { $0.type == .reasoning }
        )
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningTitle(isStreaming: reasoning.state == .streaming), "Thinking…")
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningText(reasoning), "Looking at the brief")
        XCTAssertTrue(
            vm.deskTimeline.contains { if case .liveTurn = $0 { return true }; return false },
            "a reasoning-only turn must still paint Thinking… in the transcript"
        )
    }

    func test_deskAppliesLiveCoordinatorEvents_becauseThinkingMustNotWaitForSQLite() throws {
        // WHY: Agent App paints from didReceive events. Polling latestStreamEvents
        // waits for the 250ms flush, so a live Thinking… row never appears on Desk.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        try context.runRepo.upsert(AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: Date()
        ))
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Standup", linkedAgentThreadID: thread.id)
        )
        vm.openDesk(bot)
        XCTAssertFalse(vm.deskPaintsLiveTurnChrome)

        vm.applyDeskLiveEventForTesting(.turnStarted(turnId: "t-live"), threadId: thread.id)
        vm.applyDeskLiveEventForTesting(.itemStarted(item: AssistantItem(
            id: "r-live",
            turnId: "t-live",
            type: .reasoning,
            state: .streaming,
            body: "Considering the failing test",
            startedAtMs: 10
        )), threadId: thread.id)

        XCTAssertTrue(vm.deskPaintsLiveTurnChrome, "live didReceive must paint Thinking… without a persist")
        let reasoning = try XCTUnwrap(
            vm.deskLiveTimeline.turns.first?.items.first { $0.type == .reasoning }
        )
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningTitle(isStreaming: true), "Thinking…")
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningText(reasoning), "Considering the failing test")
        XCTAssertTrue(vm.deskTimeline.contains { if case .liveTurn = $0 { return true }; return false })

        vm.refreshDeskLiveTurn()
        XCTAssertEqual(
            AgentChatLiveTurnChrome.reasoningText(
                try XCTUnwrap(vm.deskLiveTimeline.turns.first?.items.first { $0.type == .reasoning })
            ),
            "Considering the failing test",
            "a lagging SQLite replay must not erase the live Thought row"
        )
    }

    func test_currentGoalAndActivityDriveHomeFromRealConversations() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.send("Ship the beta brief")
        XCTAssertEqual(vm.currentGoal(for: bot), "Ship the beta brief")
        XCTAssertFalse(vm.activityRows(for: bot).isEmpty)
        XCTAssertEqual(BotsChrome.hitTarget, 44)
        XCTAssertEqual(BotsChrome.Label.openChat, "Open Chat")
    }

    func test_openHomeShowsChat_becauseHomeIsNotADestination() throws {
        // WHY: Home/overview is gone. openHome is leftover API and must
        // land on Chat so roster/create never park on Goal cards.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        XCTAssertEqual(vm.screen, .desk)
        vm.openHome(bot)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.screen, BotsScreen.fleet.resolvedDestination)
        XCTAssertEqual(vm.selectedBotID, bot.id)
        XCTAssertEqual(vm.providerLabel(for: bot), "Claude")
        XCTAssertEqual(try XCTUnwrap(vm.selectedBot).title, "Scout")
    }

    func test_rosterRowOpensDesk_becauseSidebarClickIsTheChat() throws {
        // WHY: the sidebar list is the conversation switcher. A tap must
        // open Desk, not park on Fleet Home.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openHome(bot)
        XCTAssertEqual(vm.screen, .desk)
        vm.openDesk(bot)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, bot.id)
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private func rosterRow") else {
            return XCTFail("roster row must exist")
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func ")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertTrue(
            slice.contains("vm.openDesk(bot)"),
            "clicking a roster bot must call openDesk, not openHome"
        )
        XCTAssertFalse(
            slice.contains("vm.openHome(bot)"),
            "roster tap must not land on Home"
        )
        XCTAssertTrue(
            slice.contains(".contextMenu"),
            "right-click must expose teammate actions on the roster row"
        )
        XCTAssertTrue(
            slice.contains("botManagementButtons"),
            "roster menu must share Fleet's Pin/Hide/Duplicate/Edit/Delete, not a one-off Delete"
        )
    }

    func test_rosterDeleteUsesPendingConfirmation_becauseDeleteRemovesTheTeammate() throws {
        // WHY: right-click Delete is irreversible. It must go through the same
        // pendingDeleteID dialog as the Fleet overflow, not call delete(id:) now.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("bots.menu.delete"))
        XCTAssertTrue(source.contains("attachDeleteConfirmation"))
        XCTAssertTrue(
            source.contains("BotsRosterList(vm: vm)"),
            "the rail inside BotsRootView must not attach a second confirm dialog"
        )
        XCTAssertTrue(
            source.contains("BotsDeleteConfirmation(vm: vm, enabled: embedsRosterRail)"),
            "main-shell BotsRootView must not stack a second delete dialog beside the sidebar roster"
        )
    }

    func test_hidingFromRosterStaysRecoverable_becauseShowHiddenLivesOnTheList() throws {
        // WHY: Hide from the sidebar would vanish the row while Show hidden
        // only lived on the empty Fleet header. The roster toggle is the exit.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        vm.setHidden(id: quinn.id, hidden: true)
        XCTAssertEqual(vm.fleet.map(\.id), [piper.id])
        XCTAssertFalse(vm.showHidden)
        vm.showHidden = true
        XCTAssertEqual(Set(vm.fleet.map(\.id)), Set([piper.id, quinn.id]))
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(
            source.contains("bots.roster.showHidden"),
            "Hide on the roster is only safe if Show hidden is on the same list"
        )
    }

    func test_duplicateFromRosterOpensTheCopy_becauseStudioMustNotSaveTheSource() throws {
        // WHY: Fleet Duplicate runs on the no-selection list. Roster Duplicate
        // from Studio would leave studioDraft on the source; Save would publish
        // the original teammate.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(piper)
        XCTAssertEqual(vm.screen, .studio)
        vm.duplicateFromRoster(piper)
        let copy = try XCTUnwrap(vm.selectedBot)
        XCTAssertNotEqual(copy.id, piper.id)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioDraft.botID, copy.id)
        vm.openDesk(piper)
        vm.duplicateFromRoster(piper)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertNotEqual(vm.selectedBotID, piper.id)
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
        XCTAssertEqual(vm.screen, .desk)
    }

    func test_reloadOnFleetSelectsFirstTeammate_becauseSidebarOpenMustLandOnChat() throws {
        // WHY: first paint of Bots is reload(). A leftover Home screen must
        // not stay Home; Chat is the only default destination.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.selectedBotID = nil
        vm.screen = .fleet
        vm.reload()
        XCTAssertEqual(vm.selectedBotID, bot.id)
        XCTAssertEqual(vm.screen, .desk)
    }

    func test_openChatFromHomeOpensDesk_becauseConversationLivesOnDeskNotFleet() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openHome(bot)
        XCTAssertEqual(vm.screen, .desk)
        vm.openDesk(bot)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.inspectorTab, .memory)
    }

    func test_deskInspectorKeepsChatVisible_becauseMemoryMustNotReplaceTheConversation() throws {
        // WHY: Grok keeps Memory beside the chat. Swapping the timeline out
        // for a Memory tab teaches the user the teammate conversation is gone.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.send("Summarize overnight")
        XCTAssertEqual(vm.deskMessages.first?.text, "Summarize overnight")
        XCTAssertEqual(vm.inspectorTab, .memory)

        vm.inspectorTab = .routines
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.deskMessages.first?.text, "Summarize overnight")
        XCTAssertEqual(vm.inspectorTab, .routines)

        vm.memoryDraft = "Prefers dark mode"
        vm.addMemory()
        XCTAssertEqual(vm.memoryItems.map(\.content), ["Prefers dark mode"])
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.deskMessages.first?.text, "Summarize overnight")
        XCTAssertTrue(vm.memoryDraft.isEmpty)
    }

    func test_routineTestRunSendsTheInstruction_becauseTestRunsAreRealWork() throws {
        // WHY: Test run is a live supervised turn, not a fake schedule fire.
        // Enabling Active still must not imply the app runs while closed.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.routineScheduleNote = "Weekdays 9:00"
        vm.saveRoutine()
        let routine = try XCTUnwrap(vm.routines.first)
        XCTAssertFalse(routine.activation.isEnabled)
        XCTAssertNil(routine.activation.lastTestRunRequestedAt)

        vm.requestRoutineTestRun(id: routine.definition.id)

        XCTAssertEqual(vm.screen, .desk, "a test run is desk work, not a hidden schedule")
        XCTAssertEqual(vm.deskMessages.first?.text, "Scan overnight failures")
        XCTAssertEqual(vm.deskMessages.last?.text, BotsViewModel.assistantPlaceholder)
        let updated = try XCTUnwrap(vm.routines.first)
        XCTAssertNotNil(updated.activation.lastTestRunRequestedAt)
        XCTAssertFalse(updated.activation.isEnabled, "Test run must not silently enable a schedule")
        XCTAssertFalse(vm.isAutonomyActive)
        XCTAssertTrue(BotRoutineCopy.testRunHonestyCaption.contains("App-closed schedules stay off"))
    }

    func test_inspectorTabSurvivesRelaunch_becauseSelectedTabsAreUserWorkflowState() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.inspectorTab = .routines
        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.inspectorTab, .routines)
    }

    func test_reloadKeepsDesk_becauseRemountMustNotNavigateHome() throws {
        // WHY: installBotsContent remounts with reload() only. reload must
        // refresh the open Desk, not convert a paint into Fleet navigation.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.send("Summarize overnight")
        vm.reload()
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, bot.id)
        XCTAssertEqual(vm.deskMessages.first?.text, "Summarize overnight")
    }

    func test_deskScreenSurvivesRelaunch_becauseLeavingBotsMustNotDropTheChat() throws {
        // WHY: installBotsContent remounts after Agentic/workspace. Forcing
        // Fleet Home there (or on a new VM) throws away the open Desk turn.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.send("Summarize overnight")
        XCTAssertEqual(vm.screen, .desk)

        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.selectedBotID, bot.id)
        XCTAssertEqual(reopened.screen, .desk)
        XCTAssertEqual(reopened.deskMessages.first?.text, "Summarize overnight")
    }

    func test_studioScreenAndTabSurviveRelaunch_becauseSelectedTabsAreUserWorkflowState() throws {
        // WHY: Studio Memory/Skills are selected tabs. A remount that lands
        // on Fleet + Profile makes the user re-find the Brain they were editing.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.studioTab = .memory
        XCTAssertEqual(vm.screen, .studio)

        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.selectedBotID, bot.id)
        XCTAssertEqual(reopened.screen, .studio)
        XCTAssertEqual(reopened.studioTab, .memory)
        XCTAssertEqual(reopened.studioDraft.name, "Piper")
    }

    func test_leftoverHomePersistOpensChat_becauseHomeIsNotADestination() throws {
        // WHY: UserDefaults may still store fleet/Home. Dropping that raw
        // value without remap would leave Bots stuck on a removed screen.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.openHome(bot)
        XCTAssertEqual(vm.screen, .desk)
        UserDefaults.standard.set(BotsScreen.fleet.rawValue, forKey: "bots.screen")

        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.selectedBotID, bot.id)
        XCTAssertEqual(reopened.screen, .desk)
        XCTAssertEqual(BotsScreen(rawValue: "fleet")?.resolvedDestination, .desk)
    }

    func test_botsShellDestinationSurvivesRelaunch_becauseAgenticBotsIsUserWorkflowState() throws {
        // WHY: bots.screen already restores Fleet/Studio/Desk. The Agentic |
        // Bots switcher still dumped the user on the workspace after relaunch.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let first = MainWindowController(context: context, router: router)
        router.windowController = first
        first.presentBotsInMainContent()
        XCTAssertEqual(first.window.title, "Bots")
        XCTAssertEqual(
            try context.settingsRepo.get(MainWindowController.botsShellSettingsKey) ?? "",
            "bots"
        )

        let reopened = MainWindowController(context: context, router: router)
        XCTAssertEqual(reopened.window.title, "Bots", "relaunch must reopen the Bots destination")

        first.presentWorkspaceContent()
        XCTAssertEqual(
            try context.settingsRepo.get(MainWindowController.botsShellSettingsKey) ?? "",
            "workspace"
        )
        let workspace = MainWindowController(context: context, router: router)
        XCTAssertNotEqual(workspace.window.title, "Bots")
        XCTAssertNotEqual(workspace.window.title, "Schedule Tasks")
        XCTAssertNotEqual(workspace.window.title, "Active Threads")
    }

    func test_legacyBotsShellFlagStillRestoresBots_becauseOlderSettingsMustNotDropTheSwitcher() throws {
        // WHY: v72-era rows stored "1"/"0". A dest-string persist cannot
        // leave those users on the workspace after an upgrade.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        try context.settingsRepo.set(MainWindowController.botsShellSettingsKey, "1")
        let restored = MainWindowController(context: context, router: router)
        XCTAssertEqual(restored.window.title, "Bots")
    }

    func test_scheduleTasksDestinationSurvivesRelaunch_becauseShellDestIsUserWorkflowState() throws {
        // WHY: persist used to write "not Bots" for Schedule Tasks, so
        // relaunch dumped the user on the workspace.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let first = MainWindowController(context: context, router: router)
        router.windowController = first
        first.presentScheduledTasksInMainContent()
        XCTAssertEqual(first.window.title, "Schedule Tasks")
        XCTAssertEqual(
            try context.settingsRepo.get(MainWindowController.botsShellSettingsKey) ?? "",
            "scheduledTasks"
        )

        let reopened = MainWindowController(context: context, router: router)
        XCTAssertEqual(reopened.window.title, "Schedule Tasks")
    }

    func test_activeThreadsDestinationSurvivesRelaunch_becauseShellDestIsUserWorkflowState() throws {
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let first = MainWindowController(context: context, router: router)
        router.windowController = first
        first.presentActiveThreadsInMainContent()
        XCTAssertEqual(first.window.title, "Active Threads")
        XCTAssertEqual(
            try context.settingsRepo.get(MainWindowController.botsShellSettingsKey) ?? "",
            "activeThreads"
        )

        let reopened = MainWindowController(context: context, router: router)
        XCTAssertEqual(reopened.window.title, "Active Threads")
    }

    func test_deletedBotDoesNotRestoreItsDesk_becauseTheTeammateIsGone() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        vm.delete(id: piper.id)

        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.selectedBotID, quinn.id)
        XCTAssertEqual(reopened.screen, .desk)
    }

    func test_memoryCorrectAndForgetStayOnDesk_becauseTheInspectorOwnsBrainEdits() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.send("Keep chatting")
        vm.memoryDraft = "Prefers dark mode"
        vm.addMemory()
        let item = try XCTUnwrap(vm.memoryItems.first)
        vm.correctMemory(id: item.id, content: "Prefers light mode")
        XCTAssertEqual(vm.memoryItems.map(\.content), ["Prefers light mode"])
        vm.forgetMemory(id: try XCTUnwrap(vm.memoryItems.first).id)
        XCTAssertTrue(vm.memoryItems.isEmpty)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.deskMessages.first?.text, "Keep chatting")
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
        let settings = try String(contentsOf: sourceURL("Sources/AppShell/SettingsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("desktopHonestyLabel"))
        if let start = source.range(of: "private var studioSummary") {
            let rest = source[start.upperBound...]
            let end = rest.range(of: "\n    private func studioSummaryRow")?.lowerBound ?? rest.endIndex
            let slice = String(source[start.lowerBound..<end])
            XCTAssertFalse(
                slice.contains("desktopHonestyLabel"),
                "Configuration summary must not repeat the Desktop honesty block"
            )
        } else {
            XCTFail("studio summary must exist")
        }
        XCTAssertTrue(source.contains("not shipped in P1a"))
        XCTAssertFalse(
            source.contains("Guest not running"),
            "Studio must not advertise a Dedicated local VM guest control"
        )
        XCTAssertFalse(
            source.contains("Managed remote Mac Desktop"),
            "Studio must not advertise Managed remote Mac"
        )
        XCTAssertFalse(source.contains("bots.studio.desktop.remote"))
        XCTAssertFalse(source.contains("bots.studio.desktop.vm"))
        XCTAssertFalse(source.contains("Dedicated local VM Desktop"))
        XCTAssertFalse(source.contains("Isolated / Dedicated VM"))
        XCTAssertFalse(source.contains("Isolated network"))
        XCTAssertFalse(source.contains("Take over"))
        XCTAssertFalse(source.contains("bots.desktop.vm.start"))
        XCTAssertFalse(source.contains("bots.desktop.vm.stop"))
        XCTAssertFalse(source.contains("bots.desktop.vm.identity"))
        XCTAssertFalse(settings.contains("settings.bots.desktopVM.toggle"))
        XCTAssertFalse(settings.contains("Dedicated local VM Desktop"))
        XCTAssertFalse(settings.contains("setBotsDesktopVMEnabled"))
        XCTAssertFalse(
            source.contains("Running • macOS VM"),
            "Fleet Home must not paint the concept's fake dedicated VM"
        )
        XCTAssertFalse(
            source.contains("Active now in macOS VM"),
            "select/persist must not claim a running guest"
        )
        XCTAssertFalse(
            source.contains("Dedicated Desktop"),
            "P1a has no dedicated Desktop; the concept screenshot is not the contract"
        )
        XCTAssertFalse(
            source.contains("bots.home.desktop.honesty"),
            "Home desktop honesty is gone with the Home screen"
        )
        XCTAssertTrue(source.contains("bots.studio.desktop.honesty") || source.contains("bots.desk.desktop"))
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
        vm.beginEdit(bot)
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

    func test_deskIdentityExposesJobProviderModelAndSupervised() throws {
        // WHY: Desk is the live teammate, not a generic chat. The header must
        // show who is talking, their job, the real route, and supervised mode.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        XCTAssertEqual(try XCTUnwrap(vm.selectedBot).name, "Piper")
        XCTAssertEqual(try XCTUnwrap(vm.selectedBot).handle, "piper")
        XCTAssertEqual(try XCTUnwrap(vm.selectedBot).title, "Scout")
        XCTAssertEqual(vm.providerLabel(for: bot), "Claude")
        XCTAssertEqual(vm.modelLabel(for: bot), "opus")
        XCTAssertEqual(vm.permissionLabel(for: bot), "Supervised")
        XCTAssertEqual(vm.desktopHonestyLabel, BotDesktopKind.logicalExecutionSpaceHonestyLabel)
    }

    func test_deskTimelineUsesUserAssistantLabelsAndTimestamps() {
        // WHY: Grok Desk is a conversation log. A bubble without a time or
        // speaker turns the teammate into a generic agent transcript.
        let userAt = Date(timeIntervalSince1970: 1_700_000_000)
        let assistantAt = Date(timeIntervalSince1970: 1_700_000_030)
        let items = BotsDeskFollowThrough.timeline(
            messages: [
                BotDeskMessage(role: .user, text: "Summarize overnight", createdAt: userAt),
                BotDeskMessage(role: .assistant, text: "Three failing tests remain.", createdAt: assistantAt),
            ],
            workLog: []
        )
        XCTAssertEqual(items.count, 2)
        guard case .message(let user) = items[0] else {
            return XCTFail("first row must be the user line")
        }
        guard case .message(let assistant) = items[1] else {
            return XCTFail("second row must be the assistant line")
        }
        XCTAssertEqual(user.role, .user)
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertEqual(user.createdAt, userAt)
        XCTAssertEqual(assistant.createdAt, assistantAt)
        XCTAssertEqual(
            AgentChatTranscriptChrome.relativeTimestamp(userAt, now: userAt),
            "just now",
            "Desk timestamps must use the Agent App 'just now' window"
        )
    }

    func test_deskWorkLogAppearsOnlyWhenALinkedRunExists() {
        // WHY: work-log rows are the linked provider turn. Inventing Desktop
        // clicks or showing a row with no run would fake computer-use.
        let started = Date(timeIntervalSince1970: 1_700_000_010)
        let user = BotDeskMessage(
            role: .user,
            text: "Summarize overnight",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let assistant = BotDeskMessage(
            role: .assistant,
            text: "Three failing tests remain.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_030)
        )
        XCTAssertTrue(
            BotsDeskFollowThrough.timeline(messages: [user, assistant], workLog: []).allSatisfy {
                if case .workLog = $0 { return false }
                return true
            }
        )
        let run = AgentRun(
            threadId: AgentThreadID(),
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: started
        )
        let withRun = BotsDeskFollowThrough.timeline(
            messages: [user, assistant],
            workLog: BotsDeskFollowThrough.workLogRows(for: run)
        )
        XCTAssertEqual(withRun.count, 3)
        guard case .workLog(let row) = withRun[1] else {
            return XCTFail("linked run must insert a work-log between You and the assistant")
        }
        XCTAssertEqual(row.title, "Supervised run")
        XCTAssertEqual(row.detail, "Claude · opus")
        XCTAssertEqual(row.statusLabel, "Working")
        XCTAssertEqual(BotsDeskFollowThrough.workLogStatusLabel(for: .completed), "Done")
        XCTAssertTrue(BotsDeskFollowThrough.workLogRows(for: nil).isEmpty)
    }

    func test_openDeskRestoresTimelineAndWorkLogFromLinkedRun_becauseReopenMustNotLoseTheTurn() throws {
        // WHY: closing and reopening RemoteCode must keep the Desk conversation
        // and the honest work-log for the linked run — not an empty chat.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        let finishedAt = Date(timeIntervalSince1970: 1_700_000_040)
        let run = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_010),
            finishedAt: finishedAt
        )
        try context.runRepo.upsert(run)
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "You are Piper — Scout.\n\nUser request:\n\nSummarize overnight",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .assistant,
            content: "Three failing tests remain.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_030)
        ))
        try context.botStore.upsertConversation(
            BotConversation(
                botID: bot.id,
                title: "Summarize overnight",
                linkedAgentThreadID: thread.id
            )
        )

        vm.openDesk(bot)
        XCTAssertEqual(vm.deskMessages.map(\.role), [.user, .assistant])
        XCTAssertEqual(vm.deskMessages.first?.text, "Summarize overnight")
        XCTAssertEqual(vm.deskMessages.last?.text, "Three failing tests remain.")
        XCTAssertEqual(vm.deskWorkLog.count, 1)
        XCTAssertEqual(vm.deskWorkLog.first?.statusLabel, "Done")
        XCTAssertEqual(vm.deskWorkLog.first?.detail, "Claude · opus")
        XCTAssertEqual(vm.deskWorkLog.first?.runID, run.id)
        XCTAssertEqual(vm.deskTimeline.count, 3)

        let reopened = BotsViewModel(context: context)
        reopened.openDesk(bot)
        XCTAssertEqual(reopened.deskMessages.map(\.text), vm.deskMessages.map(\.text))
        XCTAssertEqual(reopened.deskWorkLog.map(\.runID), [run.id])
        XCTAssertEqual(reopened.deskWorkLog.first?.statusLabel, "Done")

        let context2 = try AppContext(channel: .debug, appSupportOverride: directory)
        let vm2 = BotsViewModel(context: context2)
        let listed = try XCTUnwrap(vm2.fleet.first(where: { $0.id == bot.id }))
        vm2.openDesk(listed)
        XCTAssertEqual(vm2.deskMessages.last?.text, "Three failing tests remain.")
        XCTAssertEqual(vm2.deskWorkLog.first?.statusLabel, "Done")
        XCTAssertEqual(vm2.permissionLabel(for: listed), "Supervised")
    }

    func test_followThroughWorkLogStaysOnOwningConversation() throws {
        // WHY: a finished run on Piper must not paint Quinn's open Desk.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        let thread = AgentThread(title: "From Piper", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .completed,
            finishedAt: Date()
        )
        try context.runRepo.upsert(run)
        var piperConversation = BotConversation(
            botID: piper.id,
            title: "From Piper",
            linkedAgentThreadID: thread.id
        )
        try context.botStore.upsertConversation(piperConversation)
        vm.openDesk(quinn)
        XCTAssertTrue(vm.deskWorkLog.isEmpty)

        piperConversation.linkedAgentThreadID = thread.id
        vm.applyFollowThroughForTests(bot: piper, conversation: piperConversation, status: .completed)

        XCTAssertEqual(vm.selectedBotID, quinn.id)
        XCTAssertTrue(vm.deskWorkLog.isEmpty, "Quinn's Desk must not inherit Piper's work-log")
        vm.openDesk(piper)
        XCTAssertEqual(vm.deskWorkLog.first?.runID, run.id)
        XCTAssertEqual(vm.deskWorkLog.first?.statusLabel, "Done")
    }

    func test_queuedFollowUpStaysOnOwningBot_becauseDrainMustNotSendToAnotherDesk() throws {
        // WHY: send-while-live queues the follow-up. Completing Piper's run
        // used selectedBot, so a switch to Quinn delivered Piper's words
        // to the wrong teammate. The queue is per Desk and only drains
        // onto the bot that accepted it.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        let thread = AgentThread(title: "From Piper", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        let piperRun = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: Date()
        )
        try context.runRepo.upsert(piperRun)
        let piperConversation = BotConversation(
            botID: piper.id,
            title: "From Piper",
            linkedAgentThreadID: thread.id
        )
        try context.botStore.upsertConversation(piperConversation)
        vm.openDesk(piper)
        XCTAssertTrue(vm.deskRunIsLive)
        vm.composerText = "follow up for Piper"
        vm.send()
        XCTAssertEqual(vm.queuedFollowUps.map(\.text), ["follow up for Piper"])
        XCTAssertFalse(
            vm.deskMessages.contains { $0.text == "follow up for Piper" },
            "queued follow-ups wait in the queue, not as a sent bubble"
        )

        vm.openDesk(quinn)
        XCTAssertTrue(
            vm.queuedFollowUps.isEmpty,
            "Quinn's Desk must not inherit Piper's queue"
        )
        var finished = piperRun
        finished.status = .completed
        finished.finishedAt = Date()
        try context.runRepo.upsert(finished)
        vm.applyFollowThroughForTests(bot: piper, conversation: piperConversation, status: .completed)
        XCTAssertFalse(
            vm.deskMessages.contains { $0.text == "follow up for Piper" },
            "Piper's drained follow-up must not land on Quinn"
        )
        XCTAssertFalse(
            (try context.botStore.listConversations(botID: quinn.id))
                .contains { $0.title.contains("follow up for Piper") }
        )

        vm.openDesk(piper)
        XCTAssertTrue(
            vm.queuedFollowUps.isEmpty,
            "returning to idle Piper drains the follow-up onto Piper, not Quinn"
        )
        XCTAssertTrue(
            vm.deskMessages.contains { $0.text == "follow up for Piper" },
            "Piper must receive the words that were queued on Piper"
        )
        XCTAssertEqual(vm.selectedBotID, piper.id)
    }

    func test_queuedFollowUpCanBeRemoved_becauseAHiddenQueueIsNotASend() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        try context.runRepo.upsert(AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: Date()
        ))
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Standup", linkedAgentThreadID: thread.id)
        )
        vm.openDesk(bot)
        XCTAssertTrue(vm.deskRunIsLive)
        vm.composerText = "keep this off the wire"
        vm.send()
        let queued = try XCTUnwrap(vm.queuedFollowUps.first)
        vm.removeQueuedFollowUp(queued)
        XCTAssertTrue(vm.queuedFollowUps.isEmpty)
        vm.reload()
        XCTAssertTrue(vm.queuedFollowUps.isEmpty, "reload must not resurrect a cancelled follow-up")
        XCTAssertFalse(vm.deskMessages.contains { $0.text == "keep this off the wire" })
    }

    func test_queuedFollowUpSurvivesRelaunch_becauseTypedWordsMustNotVanish() throws {
        // WHY: a follow-up typed during a live turn is user work. Closing
        // RemoteCode used to drop the in-memory queue.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        try context.runRepo.upsert(AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: Date()
        ))
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Standup", linkedAgentThreadID: thread.id)
        )
        vm.openDesk(bot)
        XCTAssertTrue(vm.deskRunIsLive)
        vm.composerText = "keep after relaunch"
        vm.send()
        XCTAssertEqual(vm.queuedFollowUps.map(\.text), ["keep after relaunch"])

        let reopened = BotsViewModel(context: context)
        reopened.openDesk(bot)
        XCTAssertTrue(reopened.deskRunIsLive, "the run is still live after relaunch")
        XCTAssertEqual(reopened.queuedFollowUps.map(\.text), ["keep after relaunch"])
        XCTAssertFalse(
            reopened.deskMessages.contains { $0.text == "keep after relaunch" },
            "relaunch must restore the queue, not send it onto a still-live turn"
        )
    }

    func test_deletedBotDropsItsQueuedFollowUp_becauseTheTeammateIsGone() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        try context.runRepo.upsert(AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: Date()
        ))
        try context.botStore.upsertConversation(
            BotConversation(botID: piper.id, title: "Standup", linkedAgentThreadID: thread.id)
        )
        vm.openDesk(piper)
        vm.composerText = "orphan this"
        vm.send()
        vm.delete(id: piper.id)

        let reopened = BotsViewModel(context: context)
        reopened.openDesk(quinn)
        XCTAssertTrue(reopened.queuedFollowUps.isEmpty)
        XCTAssertFalse(reopened.deskMessages.contains { $0.text == "orphan this" })
    }

    func test_composerDraftStaysOnOwningBot_becauseDeskMustNotLeakUnsentWords() throws {
        // WHY: composerText was process-wide. Typing on Piper then opening
        // Quinn sent Piper's unsent line to the wrong teammate.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "only Piper should see this"
        vm.openDesk(quinn)
        XCTAssertEqual(vm.composerText, "", "Quinn's Desk must not inherit Piper's unsent draft")
        XCTAssertTrue(vm.attachments.isEmpty)
        vm.composerText = "only Quinn should see this"
        vm.openDesk(piper)
        XCTAssertEqual(vm.composerText, "only Piper should see this")
        vm.openDesk(quinn)
        XCTAssertEqual(vm.composerText, "only Quinn should see this")
    }

    func test_composerDraftSurvivesRelaunch_becauseTypedWordsMustNotVanish() throws {
        // WHY: an unsent Desk line is user work. Closing RemoteCode used
        // to drop the in-memory composer, same class of loss as follow-ups.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.composerText = "keep after relaunch"
        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.selectedBotID, bot.id)
        XCTAssertEqual(reopened.screen, .desk)
        XCTAssertEqual(reopened.composerText, "keep after relaunch")
        XCTAssertFalse(
            reopened.deskMessages.contains { $0.text == "keep after relaunch" },
            "relaunch must restore the draft, not send it"
        )
    }

    func test_sendClearsComposerDraft_becauseSentWordsAreNotADraft() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.composerText = "send then forget"
        XCTAssertTrue(vm.send())
        XCTAssertEqual(vm.composerText, "")
        let reopened = BotsViewModel(context: context)
        reopened.openDesk(bot)
        XCTAssertEqual(reopened.composerText, "", "a sent line must not come back as a draft")
        XCTAssertTrue(reopened.deskMessages.contains { $0.text == "send then forget" })
    }

    func test_inspectorDraftsStayOnOwningBot_becauseMemorySkillsRoutinesMustNotLeak() throws {
        // WHY: memory/skill/routine fields were process-wide. A fact typed
        // for New Agent appeared on Batatilson's Memory inspector.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.beginEdit(piper)
        vm.memoryDraft = "only-piper-memory-draft"
        vm.skillDraft = "only-piper-skill"
        vm.routineName = "Piper scan"
        vm.routinePrompt = "Scan Piper"
        vm.routineScheduleNote = "Weekdays 9:00"
        vm.beginEdit(quinn)
        XCTAssertEqual(vm.memoryDraft, "", "Quinn Studio must not inherit Piper's memory draft")
        XCTAssertEqual(vm.skillDraft, "", "Quinn Studio must not inherit Piper's skill draft")
        XCTAssertEqual(vm.routineName, "")
        XCTAssertEqual(vm.routinePrompt, "")
        XCTAssertEqual(vm.routineScheduleNote, "")
        vm.memoryDraft = "only-quinn-memory-draft"
        vm.skillDraft = "only-quinn-skill"
        vm.openDesk(piper)
        XCTAssertEqual(vm.memoryDraft, "only-piper-memory-draft")
        XCTAssertEqual(vm.skillDraft, "only-piper-skill")
        XCTAssertEqual(vm.routineName, "Piper scan")
        XCTAssertEqual(vm.routinePrompt, "Scan Piper")
        XCTAssertEqual(vm.routineScheduleNote, "Weekdays 9:00")
        vm.openDesk(quinn)
        XCTAssertEqual(vm.memoryDraft, "only-quinn-memory-draft")
        XCTAssertEqual(vm.skillDraft, "only-quinn-skill")
        XCTAssertEqual(vm.routineName, "")
    }

    func test_inspectorDraftSurvivesRelaunch_becauseUnsentFactsMustNotVanish() throws {
        // WHY: an unsent Memory/Skills/Routines field is user work, same
        // class of loss as an unsent Desk composer line.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.memoryDraft = "keep inspector after relaunch"
        vm.skillDraft = "weekly-account-health"
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight"
        vm.routineScheduleNote = "Weekdays 9:00"
        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.selectedBotID, bot.id)
        XCTAssertEqual(reopened.memoryDraft, "keep inspector after relaunch")
        XCTAssertEqual(reopened.skillDraft, "weekly-account-health")
        XCTAssertEqual(reopened.routineName, "Morning scan")
        XCTAssertEqual(reopened.routinePrompt, "Scan overnight")
        XCTAssertEqual(reopened.routineScheduleNote, "Weekdays 9:00")
        XCTAssertTrue(reopened.memoryItems.isEmpty, "relaunch must restore the draft, not save it")
    }

    func test_savingInspectorFieldsClearsOnlyThatBotDraft_becauseSentFactsAreNotDrafts() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.beginEdit(piper)
        vm.memoryDraft = "Prefers dark mode"
        vm.addMemory()
        XCTAssertTrue(vm.memoryDraft.isEmpty)
        vm.beginEdit(quinn)
        vm.memoryDraft = "Quinn-only fact"
        vm.beginEdit(piper)
        XCTAssertEqual(vm.memoryDraft, "", "saved memory must not return as a draft")
        XCTAssertEqual(vm.memoryItems.map(\.content), ["Prefers dark mode"])
        vm.beginEdit(quinn)
        XCTAssertEqual(vm.memoryDraft, "Quinn-only fact")
    }

    func test_deletedBotDropsItsInspectorDraft_becauseTheTeammateIsGone() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.beginEdit(piper)
        vm.memoryDraft = "orphan this inspector draft"
        vm.delete(id: piper.id)
        let reopened = BotsViewModel(context: context)
        reopened.beginEdit(quinn)
        XCTAssertEqual(reopened.memoryDraft, "")
    }

    func test_deletedBotDropsItsComposerDraft_becauseTheTeammateIsGone() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "orphan this draft"
        vm.delete(id: piper.id)
        let reopened = BotsViewModel(context: context)
        reopened.openDesk(quinn)
        XCTAssertEqual(reopened.composerText, "")
        XCTAssertFalse(reopened.deskMessages.contains { $0.text == "orphan this draft" })
    }

    func test_deskTimelineHidesPersistedAssistantThatDuplicatesTheTurn_becauseRepliesMustNotDouble() {
        // WHY: Desk hydrates messageRepo AND replays stream events. The same
        // greeting must not appear as a bubble and again as the turn final.
        let user = BotDeskMessage(
            role: .user,
            text: "Qual seu nome?",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let assistant = BotDeskMessage(
            role: .assistant,
            text: "Meu nome é Batatilson da Silva — Gerente de Marketing.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_030)
        )
        let turn = AssistantTurnSnapshot(
            turnId: "t-name",
            items: [
                AssistantItem(
                    id: "r1",
                    turnId: "t-name",
                    type: .reasoning,
                    state: .completed,
                    body: "Introducing myself",
                    startedAtMs: 1_700_000_010_000,
                    finishedAtMs: 1_700_000_020_000
                ),
            ],
            finalAssistantMessage: "Meu nome é Batatilson da Silva — Gerente de Marketing.",
            finished: true
        )
        let items = BotsDeskFollowThrough.timeline(
            messages: [user, assistant],
            workLog: [],
            turns: [turn],
            hideWorkLog: true
        )
        let assistantRows = items.filter { item in
            if case .message(let message) = item, message.role == .assistant { return true }
            return false
        }
        XCTAssertTrue(assistantRows.isEmpty, "the persisted bubble must yield to the turn-owned answer")
        XCTAssertEqual(items.filter { if case .liveTurn = $0 { return true }; return false }.count, 1)
    }

    func test_deskTimelineHidesRepeatedTurnFinal_becauseTwoWorkedRowsMustNotRepeatTheAnswer() {
        // WHY: two finished turns with the same final would stack the greeting.
        // Keep each Worked disclosure; paint the answer once.
        let first = AssistantTurnSnapshot(
            turnId: "t1",
            items: [
                AssistantItem(
                    id: "tool1",
                    turnId: "t1",
                    type: .tool,
                    state: .completed,
                    summary: "Bash",
                    startedAtMs: 1,
                    finishedAtMs: 2
                ),
            ],
            finalAssistantMessage: "Oi! Como posso ajudar?",
            finished: true
        )
        let second = AssistantTurnSnapshot(
            turnId: "t2",
            items: [
                AssistantItem(
                    id: "tool2",
                    turnId: "t2",
                    type: .tool,
                    state: .completed,
                    summary: "Bash",
                    startedAtMs: 3,
                    finishedAtMs: 4
                ),
            ],
            finalAssistantMessage: "Oi! Como posso ajudar?",
            finished: true
        )
        let items = BotsDeskFollowThrough.timeline(
            messages: [],
            workLog: [],
            turns: [first, second],
            hideWorkLog: true
        )
        let hidden = items.compactMap { item -> Bool? in
            if case .liveTurn(_, let hide) = item { return hide }
            return nil
        }
        XCTAssertEqual(hidden, [false, true])
    }

    func test_deskTimelinePaintsOneReplyWhenClaudeEmitsStreamAndSnapshot() {
        // WHY: live Batatilson turns persist one assistant row but Claude's
        // stream also writes two assistantMessage items. The teammate must
        // answer once.
        let answer = "Sou Batatilson da Silva, Gerente de Marketing, e não alterei nenhum arquivo."
        let user = BotDeskMessage(
            role: .user,
            text: "Brain inspector proof. Reply one short sentence. Do not change files.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let persisted = BotDeskMessage(
            role: .assistant,
            text: answer,
            createdAt: Date(timeIntervalSince1970: 1_700_000_007)
        )
        let turn = AssistantTurnSnapshot(
            turnId: "t-brain",
            items: [
                AssistantItem(
                    id: "stream",
                    turnId: "t-brain",
                    type: .assistantMessage,
                    state: .completed,
                    body: answer,
                    startedAtMs: 1_700_000_004_000,
                    finishedAtMs: 1_700_000_006_000
                ),
                AssistantItem(
                    id: "snapshot",
                    turnId: "t-brain",
                    type: .assistantMessage,
                    state: .completed,
                    body: answer,
                    startedAtMs: 1_700_000_005_000,
                    finishedAtMs: 1_700_000_006_000
                ),
            ],
            finalAssistantMessage: answer,
            finished: true
        )
        let items = BotsDeskFollowThrough.timeline(
            messages: [user, persisted],
            workLog: [],
            turns: [turn],
            hideWorkLog: true
        )
        let answers = items.compactMap { item -> String? in
            switch item {
            case .message(let message) where message.role == .assistant:
                return message.text
            case .liveTurn(let live, let hide):
                XCTAssertFalse(hide)
                let outside = AgentChatLiveTurnChrome.compose(live).outside
                XCTAssertEqual(outside.map(\.body), [answer])
                return outside.first?.body
            default:
                return nil
            }
        }
        XCTAssertEqual(answers, [answer])
    }

    func test_openingAnotherBotDoesNotKeepPreviousLiveTurns_becauseEachDeskOwnsItsThread() throws {
        // WHY: applyDeskLiveReplay used the previous bot's deskLiveTimeline as
        // "current". isRicher then kept Batatilson's Worked rows on New Agent.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)

        let piperThread = AgentThread(title: "Piper", provider: .claude, model: "opus")
        let quinnThread = AgentThread(title: "Quinn", provider: .claude, model: "opus")
        try context.threadRepo.upsert(piperThread)
        try context.threadRepo.upsert(quinnThread)
        let piperRun = AgentRun(
            threadId: piperThread.id,
            provider: .claude,
            model: "opus",
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_010),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_040)
        )
        let quinnRun = AgentRun(
            threadId: quinnThread.id,
            provider: .claude,
            model: "opus",
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_110),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_120)
        )
        try context.runRepo.upsert(piperRun)
        try context.runRepo.upsert(quinnRun)
        try persistStreamEvents(
            context: context,
            run: piperRun,
            events: [
                .turnStarted(turnId: "piper-turn"),
                .itemStarted(item: AssistantItem(
                    id: "piper-tool",
                    turnId: "piper-turn",
                    type: .tool,
                    state: .completed,
                    summary: "Bash",
                    startedAtMs: 1_700_000_010_000,
                    finishedAtMs: 1_700_000_020_000
                )),
                .turnCompleted(turnId: "piper-turn", finalMessage: "Piper only answer"),
            ]
        )
        try persistStreamEvents(
            context: context,
            run: quinnRun,
            events: [
                .turnStarted(turnId: "quinn-turn"),
                .itemStarted(item: AssistantItem(
                    id: "quinn-r",
                    turnId: "quinn-turn",
                    type: .reasoning,
                    state: .completed,
                    body: "Quinn thought",
                    startedAtMs: 1_700_000_110_000,
                    finishedAtMs: 1_700_000_111_000
                )),
                .turnCompleted(turnId: "quinn-turn", finalMessage: "Quinn only answer"),
            ]
        )
        try context.messageRepo.append(AgentMessage(
            threadId: piperThread.id,
            role: .user,
            content: "Piper ask",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try context.messageRepo.append(AgentMessage(
            threadId: quinnThread.id,
            role: .user,
            content: "P1a desk send check",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        ))
        try context.botStore.upsertConversation(
            BotConversation(botID: piper.id, title: "Piper ask", linkedAgentThreadID: piperThread.id)
        )
        try context.botStore.upsertConversation(
            BotConversation(botID: quinn.id, title: "P1a desk send check", linkedAgentThreadID: quinnThread.id)
        )

        vm.openDesk(piper)
        XCTAssertTrue(
            vm.deskLiveTimeline.turns.contains { $0.finalAssistantMessage == "Piper only answer" },
            "Piper's Desk must replay Piper's thread"
        )

        vm.openDesk(quinn)
        XCTAssertFalse(
            vm.deskLiveTimeline.turns.contains { $0.finalAssistantMessage == "Piper only answer" },
            "Quinn must not inherit Piper's richer live timeline"
        )
        XCTAssertTrue(
            vm.deskLiveTimeline.turns.contains { $0.finalAssistantMessage == "Quinn only answer" }
        )
        XCTAssertFalse(
            vm.deskMessages.contains { $0.text.contains("Piper") },
            "Quinn's persisted bubbles must stay on Quinn's thread"
        )
        XCTAssertTrue(vm.deskMessages.contains { $0.text == "P1a desk send check" })
    }

    func test_deskTimelineKeepsEachTurnBesideItsUser_becauseChatIsNotTwoColumns() {
        // WHY: replay used Date() as turnStarted, so every Worked row sorted
        // to now and all user bubbles stacked on the right.
        let userName = BotDeskMessage(
            role: .user,
            text: "Qual seu nome?",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let userJob = BotDeskMessage(
            role: .user,
            text: "Qual sua função?",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let nameTurn = AssistantTurnSnapshot(
            turnId: "t-name",
            items: [
                AssistantItem(
                    id: "r-name",
                    turnId: "t-name",
                    type: .reasoning,
                    state: .completed,
                    body: "intro",
                    startedAtMs: 1_700_000_001_000,
                    finishedAtMs: 1_700_000_002_000
                ),
            ],
            finalAssistantMessage: "Meu nome é Batatilson.",
            finished: true,
            startedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        let jobTurn = AssistantTurnSnapshot(
            turnId: "t-job",
            items: [
                AssistantItem(
                    id: "r-job",
                    turnId: "t-job",
                    type: .reasoning,
                    state: .completed,
                    body: "role",
                    startedAtMs: 1_700_000_101_000,
                    finishedAtMs: 1_700_000_102_000
                ),
            ],
            finalAssistantMessage: "Gerente de Marketing.",
            finished: true,
            startedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        let items = BotsDeskFollowThrough.timeline(
            messages: [userName, userJob],
            workLog: [],
            turns: [nameTurn, jobTurn],
            hideWorkLog: true
        )
        XCTAssertEqual(items.count, 4)
        guard case .message(let first) = items[0], first.text == "Qual seu nome?" else {
            return XCTFail("first row must be the name question")
        }
        guard case .liveTurn(let firstTurn, _) = items[1], firstTurn.turnId == "t-name" else {
            return XCTFail("name turn must follow its user bubble, not sink to the bottom")
        }
        guard case .message(let second) = items[2], second.text == "Qual sua função?" else {
            return XCTFail("job question must come after the name turn")
        }
        guard case .liveTurn(let secondTurn, _) = items[3], secondTurn.turnId == "t-job" else {
            return XCTFail("job turn must follow its user bubble")
        }
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

    func test_previewBrainMatchesSendReceipt_becauseSourceEffectiveMustBeTheAdapterPayload() throws {
        // WHY: owner-readable Brain Inspector is false if Studio preview
        // compiles a different envelope than Desk send persists.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            soul: "Be brief.",
            provider: .claude
        )
        vm.openDesk(bot)
        vm.memoryDraft = "Prefers dark mode"
        vm.addMemory()
        vm.composerText = "Summarize overnight"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertEqual(preview.compiledPayload, BotsDeskFollowThrough.composeRunPrompt(
            bot: bot,
            revision: try XCTUnwrap(vm.selectedRevision),
            userText: "Summarize overnight",
            memory: vm.memoryItems,
            skills: vm.skillBindings
        ))
        XCTAssertTrue(preview.compiledPayload.contains("Prefers dark mode"))
        XCTAssertEqual(preview.layers.first(where: { $0.kind == .user })?.text, "Summarize overnight")
        XCTAssertEqual(preview.payloadDigest.count, 64)
        try context.botStore.insertContextReceipt(preview)
        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(
            reopened.lastContextReceipt?.payloadDigest,
            preview.payloadDigest,
            "Brain receipts are workflow state and must survive remount"
        )
        XCTAssertEqual(reopened.lastContextReceipt?.compiledPayload, preview.compiledPayload)

        reopened.beginEdit(bot)
        reopened.studioDraft.soul = "Stand up for the brief."
        let studioPreview = try XCTUnwrap(reopened.inspectedBrain)
        XCTAssertTrue(reopened.inspectedBrainIsPreview)
        XCTAssertFalse(reopened.inspectedBrainIsLastCall)
        XCTAssertTrue(
            studioPreview.layers.contains { $0.kind == .soul && $0.text == "Stand up for the brief." },
            "Studio Brain must compile the draft, not the last Desk send"
        )
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

    func test_saveStudioPublishesOneRevision_becauseBrainEditsAreVersioned() throws {
        // WHY: Studio Save is a publish, not a silent profile mutate. A second
        // updateProfile revision would make the digest history unreadable.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(
            name: "Piper",
            title: "Scout",
            description: "Looks around",
            soul: "Be brief.",
            provider: .claude
        )
        let first = try XCTUnwrap(bot.currentRevisionID)
        vm.beginEdit(bot)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioTab, .profile)
        vm.studioDraft.title = "Research lead"
        vm.studioDraft.soul = "Stand up for the brief."
        vm.studioDraft.provider = .grok
        vm.applyDefaultModel(for: .grok)
        vm.studioDraft.notificationsEnabled = false

        let saved = try vm.saveStudio()

        XCTAssertEqual(vm.screen, .studio, "Save stays in Studio so Brain tabs remain reachable")
        XCTAssertNotEqual(saved.currentRevisionID, first)
        XCTAssertEqual(vm.studioDraft.expectedRevisionID, saved.currentRevisionID)
        let revision = try XCTUnwrap(vm.selectedRevision)
        XCTAssertEqual(revision.revisionNumber, 2)
        XCTAssertEqual(revision.title, "Research lead")
        XCTAssertEqual(revision.soul, "Stand up for the brief.")
        XCTAssertEqual(revision.provider, .grok)
        XCTAssertEqual(revision.desktopKind, .logicalExecutionSpace)
        XCTAssertEqual(saved.notificationsEnabled, false)
        XCTAssertEqual(vm.studioRouteLabel, "Grok")
        XCTAssertEqual(vm.studioDesktopSummary, "Logical execution space")
        XCTAssertEqual(vm.studioApprovalLabel, "Supervised")
    }

    func test_grokEmptyModelUsesCurrentFallbackBeforeProviderCatalogLoads() throws {
        // WHY: Bots can be created or saved before the asynchronous provider
        // catalog arrives. Every empty-model path must use the same current
        // Grok default instead of silently pinning a new Bot to 4.5.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        XCTAssertTrue(vm.providers.isEmpty)

        let created = try vm.create(
            name: "Quinn",
            provider: .grok,
            model: "   "
        )
        let createdRevision = try XCTUnwrap(
            try context.botStore.getRevision(id: try XCTUnwrap(created.currentRevisionID))
        )
        XCTAssertEqual(createdRevision.model, "grok-4.6")

        vm.beginEdit(created)
        vm.studioDraft.model = ""
        let saved = try vm.saveStudio()
        let savedRevision = try XCTUnwrap(
            try context.botStore.getRevision(id: try XCTUnwrap(saved.currentRevisionID))
        )
        XCTAssertEqual(savedRevision.model, "grok-4.6")

        vm.studioDraft.model = ""
        vm.applyDefaultModel(for: .grok)
        XCTAssertEqual(vm.studioDraft.model, "grok-4.6")
    }

    func test_studioSkillsPersistAsCatalogBindings_becauseStudioOwnsTheBrain() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.studioTab = .skills
        vm.skillDraft = "weekly-account-health"
        vm.addSkill()

        XCTAssertEqual(vm.skillBindings.map(\.skillID), ["weekly-account-health"])
        XCTAssertEqual(vm.enabledSkillCount, 1)
        vm.setSkillEnabled(skillID: "weekly-account-health", enabled: false)
        XCTAssertEqual(vm.enabledSkillCount, 0)
        XCTAssertEqual(
            try context.botStore.listSkillBindings(botID: bot.id).first?.enabled,
            false
        )
    }

    func test_studioDoesNotPersistDedicatedLocalVM_becauseItIsNotAdvertised() throws {
        // WHY: Product must not advertise Dedicated local VM. A leftover draft
        // kind must fall back to logical space instead of publishing a hidden mode.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.studioDraft.desktopKind = .dedicatedLocalVM
        XCTAssertEqual(vm.displayedDesktopKind, .logicalExecutionSpace)
        XCTAssertEqual(vm.studioDesktopSummary, "Logical execution space")
        XCTAssertEqual(vm.desktopHonestyLabel, BotDesktopKind.logicalExecutionSpaceHonestyLabel)

        let saved = try vm.saveStudio()
        let revision = try XCTUnwrap(
            saved.currentRevisionID.flatMap { try context.botStore.getRevision(id: $0) }
        )
        XCTAssertEqual(revision.desktopKind, .logicalExecutionSpace)
        XCTAssertEqual(vm.displayedDesktopKind, .logicalExecutionSpace)
        XCTAssertEqual(vm.desktopHonestyLabel, BotDesktopKind.logicalExecutionSpaceHonestyLabel)

        vm.openDesk(saved)
        XCTAssertEqual(vm.displayedDesktopKind, .logicalExecutionSpace)
        XCTAssertTrue(vm.desktopHonestyLabel.localizedCaseInsensitiveContains("not isolated"))
    }

    func test_leftoverStoredDedicatedLocalVMDisplaysAndPublishesAsLogical() throws {
        // WHY: Existing revisions may still store dedicatedLocalVM. Opening and
        // saving must not keep that kind as the live desktop.
        let context = try makeContext()
        let leftover = try context.botStore.create(
            name: "Piper",
            title: "Scout",
            description: "",
            provider: .claude,
            desktopKind: .dedicatedLocalVM
        )
        let stored = try XCTUnwrap(
            leftover.currentRevisionID.flatMap { try context.botStore.getRevision(id: $0) }
        )
        XCTAssertEqual(stored.desktopKind, .dedicatedLocalVM)

        let vm = BotsViewModel(context: context)
        vm.openDesk(leftover)
        XCTAssertEqual(vm.displayedDesktopKind, .logicalExecutionSpace)
        XCTAssertEqual(vm.desktopHonestyLabel, BotDesktopKind.logicalExecutionSpaceHonestyLabel)
        XCTAssertEqual(vm.desktopStatusPill, BotDesktopKind.logicalExecutionSpace.statusPill)

        vm.beginEdit(leftover)
        XCTAssertEqual(vm.displayedDesktopKind, .logicalExecutionSpace)
        let saved = try vm.saveStudio()
        let published = try XCTUnwrap(
            saved.currentRevisionID.flatMap { try context.botStore.getRevision(id: $0) }
        )
        XCTAssertEqual(published.desktopKind, .logicalExecutionSpace)
    }

    func test_newStudioBotDesktopIsLogicalExecutionSpace() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.studioDraft.name = "Nova"
        vm.studioDraft.title = "Scout"
        vm.studioDraft.provider = .claude
        vm.applyDefaultModel(for: .claude)

        let created = try vm.saveStudio()
        let revision = try XCTUnwrap(
            created.currentRevisionID.flatMap { try context.botStore.getRevision(id: $0) }
        )
        XCTAssertEqual(revision.desktopKind, .logicalExecutionSpace)
        XCTAssertEqual(vm.displayedDesktopKind, .logicalExecutionSpace)
        XCTAssertEqual(vm.studioDesktopSummary, "Logical execution space")
    }

    func test_studioDoesNotPersistManagedRemoteMac_becauseItIsNotAdvertised() throws {
        // WHY: Product must not advertise Managed remote Mac. A leftover draft
        // kind must fall back to logical space instead of publishing a hidden mode.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.studioDraft.desktopKind = .managedRemoteMac
        XCTAssertEqual(vm.displayedDesktopKind, .logicalExecutionSpace)

        let saved = try vm.saveStudio()
        let revision = try XCTUnwrap(
            saved.currentRevisionID.flatMap { try context.botStore.getRevision(id: $0) }
        )
        XCTAssertEqual(revision.desktopKind, .logicalExecutionSpace)
        XCTAssertEqual(vm.displayedDesktopKind, .logicalExecutionSpace)
    }

    func test_botsOpensInMainContent_andSidebarSitsUnderScheduleTasks() throws {
        let main = try String(contentsOf: sourceURL("Sources/AppShell/MainWindowController.swift"), encoding: .utf8)
        let sidebar = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let chrome = try String(contentsOf: sourceURL("Sources/AppShell/BotsChrome.swift"), encoding: .utf8)
        let types = try String(contentsOf: sourceURL("Sources/CoreModel/BotTypes.swift"), encoding: .utf8)
        let chatChrome = try String(contentsOf: sourceURL("Sources/Surfaces/AgentChatTranscriptChrome.swift"), encoding: .utf8)

        XCTAssertTrue(main.contains("presentBotsInMainContent"))
        XCTAssertTrue(main.contains("installBotsContent"))
        XCTAssertTrue(main.contains("shell.botsSelected"))
        XCTAssertTrue(main.contains("restoreBotsShellDestinationIfNeeded"))
        XCTAssertFalse(
            main.contains("vm.openFleet()"),
            "remounting Bots must keep Desk/Studio, not force Fleet Home"
        )
        XCTAssertTrue(main.contains("embedsRosterRail: false"))
        XCTAssertTrue(main.contains("case bots"))
        XCTAssertTrue(main.contains("visibleWorkspaceLabel.stringValue = \"Bots\""))
        XCTAssertTrue(sidebar.contains("onPresentBots"))
        XCTAssertTrue(sidebar.contains("isBotsSelected"))
        XCTAssertTrue(sidebar.contains("setBotsSelected"))
        XCTAssertTrue(sidebar.contains("accessibilityIdentifier(\"sidebar.bots\")"))
        XCTAssertFalse(sidebar.contains("title: \"Bots\""))
        XCTAssertTrue(sidebar.contains("BotsModeSwitcher"))
        XCTAssertTrue(sidebar.contains("BotsRosterList"))
        XCTAssertTrue(bots.contains("bots.chrome.agentic"))
        XCTAssertTrue(bots.contains("bots.chrome.bots"))
        XCTAssertTrue(sidebar.contains("if vm.isBotsSelected"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.new\")"))
        XCTAssertFalse(bots.contains("bots.fleet.row."), "Fleet Home row is not a destination")
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.roster\")"))
        XCTAssertTrue(bots.contains("bots.roster.row."))
        XCTAssertFalse(bots.contains("accessibilityIdentifier(\"bots.home\")"))
        XCTAssertFalse(bots.contains("bots.home.chat"))
        XCTAssertFalse(bots.contains("bots.home.studio"))
        XCTAssertFalse(bots.contains("bots.home.desktop"))
        XCTAssertFalse(bots.contains("bots.home.activity"))
        XCTAssertFalse(bots.contains("bots.home.memory"))
        XCTAssertFalse(bots.contains("bots.home.skills"))
        XCTAssertFalse(bots.contains("bots.home.routines"))
        XCTAssertFalse(bots.contains("bots.home.approvals"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.studio\")"))
        XCTAssertTrue(bots.contains("bots.studio.tab.profile"))
        XCTAssertTrue(bots.contains("bots.studio.tab.brain"))
        XCTAssertTrue(bots.contains("bots.studio.tab.memory"))
        XCTAssertTrue(bots.contains("bots.studio.tab.skills"))
        XCTAssertTrue(bots.contains("bots.studio.tab.routines"))
        XCTAssertTrue(bots.contains("bots.studio.tab.desktop"))
        XCTAssertTrue(bots.contains("bots.studio.tab.security"))
        XCTAssertTrue(bots.contains("bots.chrome.agentic"))
        XCTAssertFalse(bots.contains("bots.home.goal"))
        XCTAssertTrue(bots.contains("accessibilityAddTraits(selected ? .isSelected : [])"))
        XCTAssertTrue(bots.contains("BotsChrome.hitTarget"))
        XCTAssertEqual(BotStudioTab.allCases.map(\.id), ["profile", "brain", "memory", "skills", "routines", "security", "desktop"])
        XCTAssertTrue(chrome.contains(BotsChrome.Label.agentic))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.currentGoal))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.todaysActivity))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.nextRoutine))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.myBots))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.openChat))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.saveBot))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.instructions))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.security))
        XCTAssertTrue(bots.contains("bots.studio.identity"))
        XCTAssertTrue(bots.contains("bots.studio.routing"))
        XCTAssertTrue(bots.contains("bots.studio.soul"))
        XCTAssertTrue(bots.contains("bots.studio.summary"))
        XCTAssertTrue(bots.contains("bots.studio.desktop.honesty"))
        XCTAssertTrue(bots.contains("Role & Identity"))
        XCTAssertTrue(bots.contains("Provider routing"))
        XCTAssertTrue(bots.contains("Configuration summary"))
        XCTAssertTrue(bots.contains("AgentChatUserBubble"))
        XCTAssertTrue(bots.contains("AgentChatAssistantReply"))
        XCTAssertTrue(bots.contains("AgentChatComposerBar"))
        XCTAssertTrue(bots.contains("AgentChatLiveTurnView"))
        XCTAssertTrue(bots.contains("applyIncomingDeskEvent"))
        let liveChrome = try String(contentsOf: sourceURL("Sources/Surfaces/AgentChatLiveTurnChrome.swift"), encoding: .utf8)
        XCTAssertTrue(liveChrome.contains("bots.desk.thought"))
        XCTAssertTrue(liveChrome.contains("Thinking…"))
        XCTAssertTrue(liveChrome.contains("Work so far"))
        XCTAssertTrue(bots.contains("onAttach"))
        XCTAssertTrue(bots.contains("stopDeskRun"))
        XCTAssertTrue(bots.contains("attachments: attached") || bots.contains("attachments: attached,"))
        XCTAssertTrue(bots.contains("attachmentStore().stage"))
        XCTAssertTrue(chatChrome.contains("agent.attach"))
        XCTAssertTrue(chatChrome.contains("agent.workingPhase"))
        XCTAssertTrue(chatChrome.contains("agent.composer.stop"))
        XCTAssertTrue(bots.contains("bots.desk.queued"))
        XCTAssertTrue(bots.contains("bots.desk.queued.header"))
        XCTAssertTrue(bots.contains("bots.desk.queued.remove"))
        XCTAssertTrue(bots.contains("bots.desk.composer"))
        XCTAssertTrue(chatChrome.contains("accessibilityIdentifier(composerIdentifier)"))
        XCTAssertTrue(chatChrome.contains("\"bots.desk.composer\""))
        XCTAssertTrue(chatChrome.contains("arrow.up"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk\")"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.timeline\")"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.workLog\")"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.desktop\")"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.desktop.honesty\")"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.name\")"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.handle\")"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.job\")"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.provider\")"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.model\")"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.permission\")"))
        XCTAssertTrue(bots.contains("bots.desk.role.user"))
        XCTAssertTrue(bots.contains("bots.desk.role.assistant"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.inspector\")"))
        XCTAssertTrue(bots.contains("bots.studio.tab.brain"))
        XCTAssertTrue(bots.contains("bots.desk.inspector.tab.brain"))
        XCTAssertTrue(bots.contains("bots.desk.inspector.tab.memory"))
        XCTAssertTrue(bots.contains("bots.desk.inspector.tab.routines"))
        XCTAssertTrue(bots.contains("bots.desk.inspector.brain"))
        XCTAssertTrue(bots.contains("bots.desk.inspector.memory"))
        XCTAssertTrue(bots.contains("bots.desk.inspector.routines"))
        XCTAssertTrue(bots.contains("bots.brain.honesty"))
        XCTAssertTrue(bots.contains("bots.brain.source"))
        XCTAssertTrue(bots.contains("bots.brain.effective"))
        XCTAssertTrue(bots.contains("bots.brain.whyMemory"))
        XCTAssertTrue(bots.contains("bots.brain.digest"))
        XCTAssertTrue(bots.contains("bots.memory.field"))
        XCTAssertTrue(bots.contains("bots.memory.add"))
        XCTAssertTrue(bots.contains("bots.memory.list"))
        XCTAssertTrue(bots.contains("bots.memory.correct"))
        XCTAssertTrue(bots.contains("bots.memory.forget"))
        XCTAssertTrue(bots.contains("bots.routines.name"))
        XCTAssertTrue(bots.contains("bots.routines.instruction"))
        XCTAssertTrue(bots.contains("bots.routines.when"))
        XCTAssertTrue(bots.contains("bots.routines.active"))
        XCTAssertTrue(bots.contains("bots.routines.test"))
        XCTAssertTrue(bots.contains("bots.routines.honesty"))
        XCTAssertFalse(bots.contains("BotDetailTab"))
        XCTAssertFalse(bots.contains("detailTab = .desk"))
        XCTAssertTrue(bots.contains("BOT ROSTER") || chrome.contains("BOT ROSTER"))
        XCTAssertTrue(bots.contains(BotsChrome.Label.agentic) || chrome.contains(BotsChrome.Label.agentic))
        XCTAssertTrue(bots.contains(BotsChrome.Label.currentGoal) || chrome.contains(BotsChrome.Label.currentGoal))
        XCTAssertTrue(bots.contains(BotsChrome.Label.todaysActivity) || chrome.contains(BotsChrome.Label.todaysActivity))
        XCTAssertTrue(bots.contains(BotsChrome.Label.nextRoutine) || chrome.contains(BotsChrome.Label.nextRoutine))
        for label in BotsChrome.allVisibleLabels {
            XCTAssertTrue(
                chrome.contains(label) || bots.contains(label) || types.contains(label),
                "shipped Bots chrome must show \(label)"
            )
        }
        XCTAssertFalse(bots.contains("Take over"))
        XCTAssertFalse(bots.contains("Dedicated macOS VM"))
        XCTAssertFalse(bots.contains("Active now in macOS VM"))
        XCTAssertFalse(bots.contains("Managed remote Mac Desktop"))
        let settings = try String(contentsOf: sourceURL("Sources/AppShell/SettingsWindow.swift"), encoding: .utf8)
        XCTAssertFalse(settings.contains("Managed remote Mac Desktop"))
        XCTAssertFalse(settings.contains("settings.bots.desktopRemote.toggle"))
        XCTAssertFalse(main.contains("SurfaceType.bot"))
        XCTAssertFalse(bots.contains("SurfaceType.bot"))

        let scheduleTasks = try XCTUnwrap(sidebar.range(of: "accessibilityIdentifier(\"sidebar.scheduleTasks\")"))
        let reportBug = try XCTUnwrap(sidebar.range(of: "accessibilityIdentifier(\"sidebar.reportBug\")"))
        XCTAssertLessThan(scheduleTasks.lowerBound, reportBug.lowerBound)
        XCTAssertTrue(
            sidebar.contains("BotsModeSwitcher"),
            "Bots is entered from the Agentic/Bots switcher, not a dest row"
        )
    }

    private func persistStreamEvents(
        context: AppContext,
        run: AgentRun,
        events: [AssistantEvent]
    ) throws {
        for (index, event) in events.enumerated() {
            let data = try JSONEncoder().encode(event)
            let json = try XCTUnwrap(String(data: data, encoding: .utf8))
            try context.runRepo.appendStreamEvent(
                runId: run.id,
                seq: index + 1,
                kind: event.debugDescription,
                payloadJSON: json
            )
        }
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
