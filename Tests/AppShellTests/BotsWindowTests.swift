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
        UserDefaults.standard.removeObject(forKey: "bots.deskSidePane")
        UserDefaults.standard.removeObject(forKey: "bots.showHidden")
        UserDefaults.standard.removeObject(forKey: "bots.brainPane")
        UserDefaults.standard.removeObject(forKey: "bots.queuedFollowUps")
        UserDefaults.standard.removeObject(forKey: "bots.composerDrafts")
        UserDefaults.standard.removeObject(forKey: "bots.inspectorDrafts")
        UserDefaults.standard.removeObject(forKey: "bots.studioDraft")
        UserDefaults.standard.removeObject(forKey: "bots.searchText")
        UserDefaults.standard.removeObject(forKey: "bots.deskRouting")
        UserDefaults.standard.removeObject(forKey: "bots.peerTurns")
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

    func test_deskSendLoadingSurvivesRosterReopen_becauseSendMustStayAcknowledged() throws {
        // WHY: openDesk reloads the selected bot. That used to clear
        // deskSendInFlight, so Loading… vanished while sendAgentMessage was
        // still starting — dead time on the same click that should keep status.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("keep loading visible"))
        XCTAssertTrue(vm.deskShowsLoading, "send must acknowledge before the provider run exists")
        vm.openDesk(piper)
        XCTAssertTrue(
            vm.deskShowsLoading,
            "re-opening the sending Desk must not drop Loading… mid-start"
        )
        vm.openDesk(quinn)
        XCTAssertFalse(
            vm.deskShowsLoading,
            "Quinn's Desk must not inherit Piper's in-flight Loading…"
        )
        vm.openDesk(piper)
        XCTAssertTrue(
            vm.deskShowsLoading,
            "returning to Piper must restore Loading… until that send settles"
        )
    }

    func test_openStudioDoesNotRefetchDeskStream_becauseStudioMustNotWaitOnChatReplay() throws {
        // WHY: Studio dest is Profile/Brain/Desktop. Clicking Studio used to
        // force-replay the linked chat stream before the dest could paint —
        // dead time on a dest that does not show the timeline.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        try seedLinkedTurn(context: context, bot: bot, extraReasoning: 8)
        vm.openDesk(bot)
        XCTAssertTrue(vm.deskPaintsLiveTurnChrome)
        let afterDesk = vm.deskLiveReplayFetchCountForTesting
        XCTAssertGreaterThan(afterDesk, 0, "first Desk open must fetch the stream once")
        vm.openStudio(bot)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioDraft.name, "Piper")
        XCTAssertEqual(
            vm.deskLiveReplayFetchCountForTesting,
            afterDesk,
            "Studio dest must not refetch the desk stream"
        )
    }

    func test_reopeningDeskUsesCachedLiveTurn_becauseRosterSwitchMustNotReplayUnchangedStream() throws {
        // WHY: switching away and back used to force-replay the same stream
        // before Chat could paint. Cached timeline with unchanged event count
        // is already the honest desk.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        try seedLinkedTurn(context: context, bot: piper, extraReasoning: 8)
        vm.openDesk(piper)
        XCTAssertTrue(vm.deskPaintsLiveTurnChrome)
        let afterFirst = vm.deskLiveReplayFetchCountForTesting
        vm.openDesk(quinn)
        XCTAssertEqual(vm.deskLiveReplayFetchCountForTesting, afterFirst)
        vm.openDesk(piper)
        XCTAssertTrue(vm.deskPaintsLiveTurnChrome)
        XCTAssertEqual(
            vm.deskLiveReplayFetchCountForTesting,
            afterFirst,
            "reopening Piper must reuse the cached live turn when the stream did not grow"
        )
    }

    func test_reopeningDeskUsesCachedMessages_becauseRosterSwitchMustNotRereadTheThread() throws {
        // WHY: openDesk used to listRecent the linked thread on every roster
        // click even when messagesByBot already had the honest Desk. Warm
        // cache is the dest; first open and remount still read the store.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        try seedLinkedTurn(context: context, bot: piper, extraReasoning: 2)
        vm.openDesk(piper)
        XCTAssertFalse(vm.deskMessages.isEmpty)
        let afterFirst = vm.deskMessageRestoreCountForTesting
        XCTAssertGreaterThan(afterFirst, 0, "first Desk open must read the thread once")
        vm.openDesk(quinn)
        vm.openDesk(piper)
        XCTAssertFalse(vm.deskMessages.isEmpty)
        XCTAssertEqual(
            vm.deskMessageRestoreCountForTesting,
            afterFirst,
            "reopening Piper must not reread the thread when the cache is warm"
        )
    }

    func test_reopeningDeskDoesNotRescanFinishedRuns_becauseRosterSwitchMustNotListEveryRun() throws {
        // WHY: restoreDeskWorkLog fell through to listRecentFinished(80) on
        // every dest click when lastLinkedRunID was unset. The first lookup
        // must remember the run so roster switch does not rescan.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        try seedLinkedTurn(context: context, bot: piper, extraReasoning: 2)
        vm.openDesk(piper)
        let afterFirst = vm.deskFinishedRunScanCountForTesting
        XCTAssertGreaterThan(afterFirst, 0, "first Desk open must look up the finished run")
        vm.openDesk(quinn)
        vm.openDesk(piper)
        XCTAssertEqual(
            vm.deskFinishedRunScanCountForTesting,
            afterFirst,
            "reopening Piper must reuse lastLinkedRunID instead of listing finished runs"
        )
    }

    func test_reopeningDeskDoesNotReloadStudioSupport_becauseRosterSwitchMustNotRereadInspector() throws {
        // WHY: openDesk used to list conversations, revision, skills,
        // memory, routines, and the last brain receipt on every roster
        // click. Warm inspector is already the dest; first open still reads.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        let afterPiper = vm.studioSupportReloadCountForTesting
        XCTAssertGreaterThan(afterPiper, 0, "first Desk open must read inspector once")
        vm.openDesk(quinn)
        let afterQuinn = vm.studioSupportReloadCountForTesting
        XCTAssertEqual(afterQuinn, afterPiper + 1, "first Quinn dest must read inspector once")
        vm.openDesk(piper)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(
            vm.studioSupportReloadCountForTesting,
            afterQuinn,
            "reopening Piper must not reread inspector when the cache is warm"
        )
    }

    func test_openStudioUsesCachedRevision_becauseStudioDestMustNotRereadTheBrain() throws {
        // WHY: Studio dest called getRevision before the draft could paint
        // even when Desk chips already cached that immutable revision.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .grok)
        vm.openDesk(bot)
        _ = vm.providerLabel(for: bot)
        let afterDesk = vm.rosterRevisionFetchCountForTesting
        XCTAssertGreaterThan(afterDesk, 0, "first Desk dest must read the revision once")
        vm.openStudio(bot)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioDraft.name, "Piper")
        XCTAssertEqual(vm.studioDraft.provider, .grok)
        XCTAssertEqual(
            vm.rosterRevisionFetchCountForTesting,
            afterDesk,
            "Studio dest must reuse the cached revision"
        )
    }

    func test_openStudioUsesCachedStudioSupport_becauseStudioDestMustNotRereadInspector() throws {
        // WHY: Studio dest needs the same inspector rows Desk already
        // loaded. Clicking Studio must paint from that cache, not wait on
        // another six store reads.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        let afterDesk = vm.studioSupportReloadCountForTesting
        XCTAssertGreaterThan(afterDesk, 0)
        vm.openStudio(bot)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioDraft.name, "Piper")
        XCTAssertEqual(
            vm.studioSupportReloadCountForTesting,
            afterDesk,
            "Studio dest must reuse the warm inspector snapshot"
        )
    }

    func test_saveStudioDoesNotReloadFleet_becauseSaveMustNotScanEveryRow() throws {
        // WHY: Save Bot dest used to reloadFleet (every teammate's
        // conversations + recent messages) before Studio could settle.
        // Publish already wrote this row; dest must not list every row.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.beginEdit(piper)
        let afterOpen = vm.fleetReloadCountForTesting
        vm.studioDraft.title = "Night scout"
        _ = try vm.saveStudio()
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(
            vm.fleetReloadCountForTesting,
            afterOpen,
            "Save dest must not rescan the fleet"
        )
    }

    func test_saveStudioUpdatesRosterRow_becauseStaleNameMustNotLookCurrent() throws {
        // WHY: cache-first dest is honest only when Save Bot still
        // replaces the roster name/title the fleet would show.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.beginEdit(piper)
        vm.studioDraft.name = "Piper Night"
        vm.studioDraft.title = "Night scout"
        let saved = try vm.saveStudio()
        XCTAssertEqual(saved.name, "Piper Night")
        XCTAssertEqual(saved.title, "Night scout")
        let row = try XCTUnwrap(vm.fleet.first(where: { $0.id == piper.id }))
        XCTAssertEqual(row.name, "Piper Night")
        XCTAssertEqual(row.title, "Night scout")
        XCTAssertTrue(vm.fleet.contains(where: { $0.name == "Quinn" }))
    }

    func test_saveStudioDoesNotReloadStudioSupport_becauseSaveDestMustNotRereadInspector() throws {
        // WHY: Save dest used to force-reload studio support after
        // publish already returned this revision. Dest must not reread
        // conversations, skills, memory, or routines.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        let afterOpen = vm.studioSupportReloadCountForTesting
        XCTAssertGreaterThan(afterOpen, 0)
        vm.studioDraft.title = "Night scout"
        _ = try vm.saveStudio()
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.selectedRevision?.title, "Night scout")
        XCTAssertEqual(
            vm.studioSupportReloadCountForTesting,
            afterOpen,
            "Save dest must not reread inspector"
        )
    }

    func test_saveStudioKeepsExistingInspector_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first save is honest only when older inspector
        // rows stay visible and the new revision paints.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.memoryDraft = "Keeps the overnight brief"
        vm.addMemory()
        vm.skillDraft = "weekly-account-health"
        vm.addSkill()
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.saveRoutine()
        let afterInspector = vm.studioSupportReloadCountForTesting
        vm.studioDraft.title = "Night scout"
        _ = try vm.saveStudio()
        XCTAssertEqual(vm.selectedRevision?.title, "Night scout")
        XCTAssertEqual(vm.memoryItems.map(\.content), ["Keeps the overnight brief"])
        XCTAssertEqual(vm.skillBindings.map(\.skillID), ["weekly-account-health"])
        XCTAssertEqual(vm.routines.map(\.definition.name), ["Morning scan"])
        XCTAssertEqual(vm.studioSupportReloadCountForTesting, afterInspector)
        XCTAssertEqual(vm.screen, .studio)
    }

    func test_reopeningDeskAfterMemoryAddUsesUpdatedCache_becauseStaleMemoryMustNotLookCurrent() throws {
        // WHY: write-behind dest cache must not resurrect forgotten
        // inspector rows. Adding memory then switching teammates must
        // still show the new note.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        vm.memoryDraft = "Piper keeps the overnight brief"
        vm.addMemory()
        XCTAssertEqual(vm.liveMemoryCount, 1)
        vm.openDesk(quinn)
        vm.openDesk(piper)
        XCTAssertEqual(vm.liveMemoryCount, 1)
        XCTAssertEqual(vm.memoryItems.first?.content, "Piper keeps the overnight brief")
    }

    func test_addMemoryDoesNotListMemory_becauseAddDestMustNotRereadFacts() throws {
        // WHY: Add dest used to listMemory after putMemory before the
        // new fact could paint. The store already returned the row.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        let afterDesk = vm.memoryListCountForTesting
        XCTAssertGreaterThan(afterDesk, 0)
        vm.memoryDraft = "Prefers dark mode"
        vm.addMemory()
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.memoryItems.map(\.content), ["Prefers dark mode"])
        XCTAssertTrue(vm.memoryDraft.isEmpty)
        XCTAssertEqual(
            vm.memoryListCountForTesting,
            afterDesk,
            "add dest must not reread every memory row"
        )
        vm.memoryDraft = "Keeps the overnight brief"
        vm.addMemory()
        XCTAssertEqual(
            vm.memoryItems.map(\.content),
            ["Keeps the overnight brief", "Prefers dark mode"]
        )
        XCTAssertEqual(vm.memoryListCountForTesting, afterDesk)
    }

    func test_addMemoryKeepsExistingFacts_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first add is honest only when older facts stay
        // visible and the new row paints first.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try context.botStore.putMemory(
            botID: piper.id,
            content: "Older overnight brief",
            provenance: "user",
            trusted: true,
            source: "studio"
        )
        vm.openDesk(piper)
        XCTAssertEqual(vm.memoryItems.map(\.content), ["Older overnight brief"])
        let afterDesk = vm.memoryListCountForTesting
        vm.memoryDraft = "Newer desk fact"
        vm.addMemory()
        XCTAssertEqual(vm.memoryItems.first?.content, "Newer desk fact")
        XCTAssertEqual(
            Set(vm.memoryItems.map(\.content)),
            Set(["Newer desk fact", "Older overnight brief"])
        )
        XCTAssertEqual(vm.liveMemoryCount, 2)
        XCTAssertEqual(vm.memoryListCountForTesting, afterDesk)
        XCTAssertEqual(
            Set(try context.botStore.listMemory(botID: piper.id).map(\.content)),
            Set(["Newer desk fact", "Older overnight brief"])
        )
    }

    func test_correctMemoryDoesNotListMemory_becauseCorrectDestMustNotRereadFacts() throws {
        // WHY: Correct dest used to listMemory after the store returned
        // the revised row. Dest must not reread every fact.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.memoryDraft = "Prefers dark mode"
        vm.addMemory()
        let afterAdd = vm.memoryListCountForTesting
        let item = try XCTUnwrap(vm.memoryItems.first)
        vm.correctMemory(id: item.id, content: "Prefers light mode")
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.memoryItems.map(\.content), ["Prefers light mode"])
        XCTAssertEqual(
            vm.memoryListCountForTesting,
            afterAdd,
            "correct dest must not reread every memory row"
        )
    }

    func test_forgetMemoryDoesNotListMemory_becauseForgetDestMustNotRereadFacts() throws {
        // WHY: Forget dest used to listMemory after the store marked the
        // row forgotten. Dest must drop the row locally.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.memoryDraft = "Prefers dark mode"
        vm.addMemory()
        let afterAdd = vm.memoryListCountForTesting
        vm.forgetMemory(id: try XCTUnwrap(vm.memoryItems.first).id)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertTrue(vm.memoryItems.isEmpty)
        XCTAssertEqual(vm.liveMemoryCount, 0)
        XCTAssertEqual(
            vm.memoryListCountForTesting,
            afterAdd,
            "forget dest must not reread every memory row"
        )
    }

    func test_reopeningDeskAfterMemoryCorrectUsesUpdatedCache_becauseStaleFactMustNotLookCurrent() throws {
        // WHY: dest-first correct is honest only when the old wording
        // cannot come back from the inspector cache.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        vm.memoryDraft = "Prefers dark mode"
        vm.addMemory()
        vm.correctMemory(id: try XCTUnwrap(vm.memoryItems.first).id, content: "Prefers light mode")
        vm.openDesk(quinn)
        vm.openDesk(piper)
        XCTAssertEqual(vm.memoryItems.map(\.content), ["Prefers light mode"])
        XCTAssertEqual(vm.liveMemoryCount, 1)
    }

    func test_deskRefetchesLiveTurnWhenStreamGrows_becauseStaleThoughtMustNotLookCurrent() throws {
        // WHY: cache-first reopen is honest only when a newer stream still
        // replaces the cached Thought. A grown event count must refetch.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let seed = try seedLinkedTurn(context: context, bot: bot, extraReasoning: 2)
        vm.openDesk(bot)
        let afterFirst = vm.deskLiveReplayFetchCountForTesting
        try persistStreamEvents(
            context: context,
            run: seed.run,
            events: [
                .itemDelta(itemId: "r-desk", bodyAppend: " plus a later thought", outputAppend: nil, summary: nil),
            ],
            startSeq: seed.eventCount + 1
        )
        vm.openDesk(bot)
        XCTAssertEqual(vm.deskLiveReplayFetchCountForTesting, afterFirst + 1)
        let reasoning = try XCTUnwrap(vm.deskLiveTimeline.turns.first?.items.first { $0.type == .reasoning })
        XCTAssertTrue(
            AgentChatLiveTurnChrome.reasoningText(reasoning).contains("plus a later thought"),
            "grown stream must replace the cached Thought"
        )
    }

    func test_openStudioAnnouncesDestImmediately_becauseDestChangeIsTheAcknowledgement() throws {
        // WHY: Studio dest is a sync screen change. The acknowledgement is
        // the dest itself, not a spinner. Reduced-motion stays an instant
        // swap because nothing is animated.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.openStudio(bot)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioDraft.name, "Piper")
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(bots.contains("bots.desk.studio"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.studio"))
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

    func test_deskHeaderHasNoBack_becauseHomeIsGoneAndRosterIsTheSwitcher() throws {
        // WHY: Chat Back used to return to Fleet Home. Home is gone, so the
        // chevron called openDesk on the same bot — a visible no-op next to
        // the sidebar roster. Studio Back still returns to Chat.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let deskStart = source.range(of: "private func deskHeader") else {
            return XCTFail("desk header must exist")
        }
        let deskRest = source[deskStart.upperBound...]
        let deskEnd = deskRest.range(of: "\n    private func ")?.lowerBound ?? deskRest.endIndex
        let desk = String(source[deskStart.lowerBound..<deskEnd])
        XCTAssertFalse(
            desk.contains("backButton"),
            "Chat must not paint a Back chevron that re-opens the same desk"
        )
        XCTAssertFalse(
            desk.contains("openDesk(bot)"),
            "desk header must not treat Back as a dest after Home was removed"
        )
        guard let studioStart = source.range(of: "private var studioHeader") else {
            return XCTFail("studio header must exist")
        }
        let studioRest = source[studioStart.upperBound...]
        let studioEnd = studioRest.range(of: "\n    private var studioTabs")?.lowerBound ?? studioRest.endIndex
        let studio = String(source[studioStart.lowerBound..<studioEnd])
        XCTAssertTrue(
            studio.contains("backButton"),
            "Studio Back is the real dest back to Chat"
        )
        XCTAssertTrue(studio.contains("vm.openDesk(bot)"))
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

    func test_showHiddenSurvivesRelaunch_becauseShowHiddenIsUserWorkflowState() throws {
        // WHY: Hide is only recoverable from Show hidden. Closing RemoteCode
        // used to drop that toggle, so hidden teammates vanished again.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.setHidden(id: piper.id, hidden: true)
        XCTAssertTrue(vm.fleet.isEmpty)
        vm.showHidden = true
        XCTAssertEqual(vm.fleet.map(\.id), [piper.id])

        let reopened = BotsViewModel(context: context)
        XCTAssertTrue(reopened.showHidden)
        XCTAssertEqual(reopened.fleet.map(\.id), [piper.id])
        XCTAssertTrue(try XCTUnwrap(reopened.fleet.first).hidden)
    }

    func test_showHiddenDoesNotReloadFleet_becauseShowHiddenDestMustNotScanEveryRow() throws {
        // WHY: Show hidden dest used to reloadFleet (every teammate's
        // conversations + recent messages) before the roster could paint
        // Hidden rows. Off filters locally; on lists hidden teammates
        // without scanning every conversation.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        vm.setHidden(id: quinn.id, hidden: true)
        let afterHide = vm.fleetReloadCountForTesting
        vm.showHidden = true
        XCTAssertTrue(vm.fleet.contains(where: { $0.id == quinn.id }))
        XCTAssertTrue(try XCTUnwrap(vm.fleet.first { $0.id == quinn.id }).hidden)
        XCTAssertEqual(
            vm.fleetReloadCountForTesting,
            afterHide,
            "Show hidden dest must not rescan the fleet"
        )
        vm.showHidden = false
        XCTAssertEqual(vm.fleet.map(\.id), [piper.id])
        XCTAssertEqual(vm.fleetReloadCountForTesting, afterHide)
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

    func test_setHiddenDoesNotReloadFleet_becauseHideDestMustNotScanEveryRow() throws {
        // WHY: Hide dest used to reloadFleet (every teammate's conversations
        // + recent messages) before the roster could drop the row. The store
        // already wrote this row; dest must not list every row.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        let afterDesk = vm.fleetReloadCountForTesting
        vm.setHidden(id: quinn.id, hidden: true)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.fleet.map(\.id), [piper.id])
        XCTAssertEqual(
            vm.fleetReloadCountForTesting,
            afterDesk,
            "Hide dest must not rescan the fleet"
        )
    }

    func test_hidingSelectedBotOpensTheNextTeammate_becauseEmptyDeskIsNotADestinationWhenTheRosterStillHasRows() throws {
        // WHY: Hide of the open teammate used to clear selectedBotID and set
        // screen=.fleet. Home is gone, so Chat became "Select a teammate"
        // while other rows stayed in the sidebar.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(quinn)
        XCTAssertEqual(vm.selectedBotID, quinn.id)
        vm.setHidden(id: quinn.id, hidden: true)
        XCTAssertEqual(vm.fleet.map(\.id), [piper.id])
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertFalse(vm.fleet.contains(where: { $0.id == quinn.id }))
    }

    func test_deleteDoesNotListInbox_becauseDeleteDestMustNotRereadQueue() throws {
        // WHY: Delete dest used to listAttention after dest already dested
        // the next row. Dest already dropped this teammate's inbox rows.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Please look at the failing test"))
        XCTAssertEqual(vm.openAttentionCount, 1)
        let afterDest = vm.attentionListCountForTesting
        XCTAssertGreaterThan(afterDest, 0)
        vm.delete(id: quinn.id)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(
            vm.attentionListCountForTesting,
            afterDest,
            "delete dest must not reread the inbox"
        )
    }

    func test_deleteKeepsDestInbox_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first delete is honest only when dest still shows
        // this teammate's inbox after the other row is gone.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Please look at the failing test"))
        XCTAssertEqual(vm.attentionItems.first?.botID, piper.id)
        vm.delete(id: quinn.id)
        XCTAssertEqual(vm.fleet.map(\.id), [piper.id])
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.openAttentionCount, 1)
        XCTAssertEqual(vm.attentionItems.first?.title, "Needs you")
        XCTAssertEqual(vm.attentionItems.first?.botID, piper.id)
        XCTAssertEqual(try context.botStore.listAttention().count, 1)
        XCTAssertEqual(vm.deskMessages.first?.text, "Please look at the failing test")
    }

    func test_deleteDoesNotReloadFleet_becauseDeleteDestMustNotScanEveryRow() throws {
        // WHY: Delete dest used to reloadFleet (every teammate's
        // conversations + recent messages) before Chat could dest the next
        // row. The store already removed this teammate; dest must not list
        // every remaining row.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        let afterDesk = vm.fleetReloadCountForTesting
        vm.delete(id: quinn.id)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.fleet.map(\.id), [piper.id])
        XCTAssertEqual(
            vm.fleetReloadCountForTesting,
            afterDesk,
            "Delete dest must not rescan the fleet"
        )
    }

    func test_deletingSelectedBotOpensTheNextTeammate_becauseEmptyDeskIsNotADestinationWhenTheRosterStillHasRows() throws {
        // WHY: Delete of the open teammate shared Hide's empty-desk latch.
        // After confirm, Chat must land on a remaining row, not a blank dest.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(quinn)
        vm.delete(id: quinn.id)
        XCTAssertEqual(vm.fleet.map(\.id), [piper.id])
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.screen, .desk)
    }

    func test_hidingTheLastVisibleBotKeepsEmptyDesk_becauseTheRosterHasNoRemainingRow() throws {
        // WHY: empty desk is honest only when Hide leaves zero visible teammates.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.setHidden(id: piper.id, hidden: true)
        XCTAssertTrue(vm.fleet.isEmpty)
        XCTAssertNil(vm.selectedBotID)
        XCTAssertEqual(vm.screen, .desk)
    }

    func test_setPinnedDoesNotReloadFleet_becausePinDestMustNotScanEveryRow() throws {
        // WHY: Pin dest used to reloadFleet (every teammate's conversations
        // + recent messages) before the roster could resort. The store
        // already wrote this row; dest must not list every row.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        let afterDesk = vm.fleetReloadCountForTesting
        vm.setPinned(id: piper.id, pinned: true)
        XCTAssertEqual(
            vm.fleetReloadCountForTesting,
            afterDesk,
            "Pin dest must not rescan the fleet"
        )
        XCTAssertTrue(try XCTUnwrap(vm.fleet.first).pinned)
    }

    func test_setPinnedStillSortsPinnedFirst_becauseStaleOrderMustNotLookCurrent() throws {
        // WHY: cache-first dest is honest only when Pin still jumps the
        // teammate to the top and Unpin puts them back with the live rows.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(quinn)
        vm.setPinned(id: piper.id, pinned: true)
        XCTAssertEqual(vm.fleet.first?.id, piper.id)
        XCTAssertTrue(try XCTUnwrap(vm.fleet.first).pinned)
        vm.setPinned(id: piper.id, pinned: false)
        XCTAssertFalse(try XCTUnwrap(vm.fleet.first { $0.id == piper.id }).pinned)
        XCTAssertEqual(vm.fleet.first?.id, quinn.id)
    }

    func test_rosterPinShowsOnTheRow_becausePinMustNotBeASilentSort() throws {
        // WHY: Pin already sorts the fleet. Without a pin mark the user cannot
        // tell a pinned teammate from whoever happens to be first.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.setPinned(id: piper.id, pinned: true)
        XCTAssertEqual(vm.fleet.first?.id, piper.id)
        XCTAssertTrue(try XCTUnwrap(vm.fleet.first).pinned)
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("if bot.pinned"))
        XCTAssertTrue(source.contains("pin.fill"))
        XCTAssertTrue(
            source.contains("bot.pinned ? \"Pinned. \""),
            "VoiceOver must hear Pinned so Pin is not sort-only"
        )
    }

    func test_rosterHiddenShowsOnTheRow_becauseShowHiddenMustNotLookLikeLiveTeammates() throws {
        // WHY: Show hidden puts hidden teammates back on the list. Without a
        // Hidden mark they look live, so Unhide is the only way to tell.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.setHidden(id: piper.id, hidden: true)
        vm.showHidden = true
        XCTAssertEqual(vm.fleet.first?.id, piper.id)
        XCTAssertTrue(try XCTUnwrap(vm.fleet.first).hidden)
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("if bot.hidden"))
        XCTAssertTrue(source.contains("eye.slash"))
        XCTAssertTrue(
            source.contains("bot.hidden ? \"Hidden. \""),
            "VoiceOver must hear Hidden so Show hidden is not a silent list"
        )
    }

    func test_beginCreateDoesNotReloadFleet_becauseNewTeammateMustNotScanEveryRow() throws {
        // WHY: New Agent dest used to reloadFleet (every teammate's
        // conversations + recent messages) before Chat could paint. The
        // store already returned the row; dest inserts it locally.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        let afterPiper = vm.fleetReloadCountForTesting
        XCTAssertGreaterThan(afterPiper, 0)
        vm.beginCreate()
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(try XCTUnwrap(vm.selectedBot).name, "New Agent")
        XCTAssertTrue(vm.fleet.contains(where: { $0.id == vm.selectedBotID }))
        XCTAssertTrue(vm.fleet.contains(where: { $0.id == piper.id }))
        XCTAssertEqual(
            vm.fleetReloadCountForTesting,
            afterPiper,
            "create dest must not rescan the fleet"
        )
    }

    func test_duplicateFromRosterDoesNotReloadFleet_becauseCopyDestMustNotScanEveryRow() throws {
        // WHY: roster copy dest used to reloadFleet before Chat painted.
        // The store already returned the copy; dest must not list every row.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        let afterPiper = vm.fleetReloadCountForTesting
        vm.duplicateFromRoster(piper)
        let copy = try XCTUnwrap(vm.selectedBot)
        XCTAssertNotEqual(copy.id, piper.id)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(
            vm.fleetReloadCountForTesting,
            afterPiper,
            "copy dest must not rescan the fleet"
        )
    }

    func test_duplicateFromRosterKeepsSourceAndCopy_becauseStaleRosterMustNotHideTheNewTeammate() throws {
        // WHY: cache-first dest is honest only when the new teammate
        // appears in the roster and the source row stays put.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.duplicateFromRoster(piper)
        let copy = try XCTUnwrap(vm.selectedBot)
        XCTAssertNotEqual(copy.id, piper.id)
        XCTAssertTrue(vm.fleet.contains(where: { $0.id == piper.id }))
        XCTAssertTrue(vm.fleet.contains(where: { $0.id == copy.id }))
        XCTAssertEqual(vm.rosterPreview(for: piper), "Scout")
        XCTAssertEqual(vm.rosterPreview(for: copy), "Scout")
    }

    func test_openAttentionDestsBeforeAcknowledge_becauseAttentionRowMustNotWaitOnStore() throws {
        // WHY: clicking an Attention row used to acknowledge and list the
        // queue before dest. Chat must paint first; store work follows.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(piper)
        XCTAssertEqual(vm.screen, .studio)
        vm.send("Please look at the failing test")
        let item = try XCTUnwrap(context.botStore.listAttention().first)
        vm.openAttention(item)
        XCTAssertEqual(
            vm.lastAttentionAcknowledgedOnScreenForTesting,
            .desk,
            "Attention dest must already be Chat when acknowledge runs"
        )
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.deskMessages.first?.text, "Please look at the failing test")
    }

    func test_openAttentionStillAcknowledges_becauseStaleInboxMustNotLookCurrent() throws {
        // WHY: dest-first dest is honest only when the inbox item is still
        // marked read after Chat paints.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(piper)
        vm.send("Please look at the failing test")
        let item = try XCTUnwrap(context.botStore.listAttention().first)
        vm.openAttention(item)
        XCTAssertTrue(vm.attentionItems.isEmpty)
        XCTAssertEqual(try context.botStore.listAttention().count, 0)
    }

    func test_openAttentionDoesNotListInbox_becauseAcknowledgeDestMustNotRereadQueue() throws {
        // WHY: Acknowledge dest used to listAttention after dest already
        // painted Chat. Dest already has this inbox row.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.beginEdit(piper)
        vm.send("Please look at the failing test")
        let item = try XCTUnwrap(context.botStore.listAttention().first)
        let afterDest = vm.attentionListCountForTesting
        XCTAssertGreaterThan(afterDest, 0)
        vm.openAttention(item)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(
            vm.attentionListCountForTesting,
            afterDest,
            "acknowledge dest must not reread the inbox"
        )
    }

    func test_openAttentionStillClearsInbox_becauseStaleBellMustNotLookCurrent() throws {
        // WHY: dest-first acknowledge is honest only when dest still
        // hides this row after the store write.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(piper)
        vm.send("Please look at the failing test")
        let item = try XCTUnwrap(context.botStore.listAttention().first)
        XCTAssertEqual(vm.openAttentionCount, 1)
        vm.openAttention(item)
        XCTAssertTrue(vm.attentionItems.isEmpty)
        XCTAssertEqual(vm.openAttentionCount, 0)
        XCTAssertEqual(try context.botStore.listAttention().count, 0)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.deskMessages.first?.text, "Please look at the failing test")
    }

    func test_openAttentionDoesNotListInbox_becauseBellDestMustNotRereadQueue() throws {
        // WHY: Bell dest used to listAttention (and then list every
        // teammate's conversations) before dest dested Chat. Dest
        // already has dest inbox from send dest.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.beginEdit(piper)
        vm.send("Please look at the failing test")
        XCTAssertEqual(vm.openAttentionCount, 1)
        let afterDest = vm.attentionListCountForTesting
        XCTAssertGreaterThan(afterDest, 0)
        vm.openAttention()
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(
            vm.attentionListCountForTesting,
            afterDest,
            "bell dest must not reread the inbox"
        )
        XCTAssertTrue(vm.attentionItems.isEmpty)
        XCTAssertEqual(vm.deskMessages.first?.text, "Please look at the failing test")
    }

    func test_emptyAttentionStaysOnStudio_becauseTheBellIsNotADestWhenNothingNeedsYou() throws {
        // WHY: Home/Attention is gone. openAttention with an empty queue
        // used to call openDesk and yank the user out of Studio.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(piper)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.openAttentionCount, 0)
        vm.openAttention()
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.selectedBotID, piper.id)
    }

    func test_openActiveBotsOpensNeedsYouBot_becauseBadgeAndClickMustAgree() throws {
        // WHY: Active Bots replaced the attention bell. The badge counts
        // working/needs-you teammates; the row must dest that teammate,
        // not sit inert while the count is non-zero.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Please look at the failing test"))
        XCTAssertGreaterThan(vm.activeBotCount, 0)
        vm.openDesk(quinn)
        XCTAssertEqual(vm.selectedBotID, quinn.id)
        vm.openActiveBots()
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.screen, .desk)
    }

    func test_searchKeepsSelectedVisible_becauseChatMustMatchTheRoster() throws {
        // WHY: searching "copy" hid the open teammate while Desk still painted
        // their chat. Keep the selected row in the list so dest and roster agree.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        vm.searchText = "quinn"
        XCTAssertTrue(vm.fleet.contains(where: { $0.id == piper.id }))
        XCTAssertTrue(vm.fleet.contains(where: { $0.id == quinn.id }))
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.screen, .desk)
    }

    func test_searchTextSurvivesRelaunch_becauseSearchIsUserWorkflowState() throws {
        // WHY: Show hidden and selected tabs persist. Roster search used to
        // vanish on remount, so the user re-typed the filter and the list
        // jumped back to the full fleet. Restore must keep the open
        // teammate even when the query does not match their name.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let copy = try vm.create(name: "New Agent copy", title: "", provider: .claude)
        vm.openDesk(piper)
        vm.searchText = "copy"
        XCTAssertEqual(vm.searchText, "copy")
        XCTAssertTrue(vm.fleet.contains(where: { $0.id == piper.id }))
        XCTAssertTrue(vm.fleet.contains(where: { $0.id == copy.id }))
        XCTAssertEqual(vm.fleet.count, 2)

        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.searchText, "copy")
        XCTAssertTrue(reopened.fleet.contains(where: { $0.id == piper.id }))
        XCTAssertTrue(reopened.fleet.contains(where: { $0.id == copy.id }))
        XCTAssertEqual(reopened.fleet.count, 2)

        reopened.searchText = ""
        let cleared = BotsViewModel(context: context)
        XCTAssertEqual(cleared.searchText, "")
        XCTAssertEqual(Set(cleared.fleet.map(\.id)), Set([piper.id, copy.id]))
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

    func test_saveRoutineDoesNotListRoutines_becauseSaveDestMustNotRereadSchedules() throws {
        // WHY: Save dest used to listRoutines after the store wrote this
        // schedule. Dest must not reread every routine.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(piper)
        let afterStudio = vm.routineListCountForTesting
        XCTAssertGreaterThan(afterStudio, 0)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.routineScheduleNote = "Weekdays 9:00"
        vm.saveRoutine()
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.routines.first?.definition.name, "Morning scan")
        XCTAssertEqual(vm.routines.first?.definition.prompt, "Scan overnight failures")
        XCTAssertEqual(vm.routines.first?.definition.scheduleNote, "Weekdays 9:00")
        XCTAssertFalse(try XCTUnwrap(vm.routines.first).activation.isEnabled)
        XCTAssertTrue(vm.routineName.isEmpty)
        XCTAssertEqual(
            vm.routineListCountForTesting,
            afterStudio,
            "save dest must not reread every routine"
        )
    }

    func test_previewBrainIncludesAdvertisedWorkspace_becauseDestMustNotOmitTheRepo() throws {
        // WHY: Studio already shows Workspace. Brain compile never sent
        // name/cwd, so first-chat "which repo?" invented a folder. Dest
        // preview and compose must share the advertised workspace.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "macos-app", cwd: "/tmp/macos-app")
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "Which repo is this?"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertEqual(vm.advertisedWorkspace?.name, "macos-app")
        XCTAssertEqual(vm.advertisedWorkspace?.cwd, "/tmp/macos-app")
        XCTAssertEqual(vm.studioWorkspaceLabel, "macos-app")
        XCTAssertTrue(preview.compiledPayload.contains("Workspace: macos-app (/tmp/macos-app)."))
        XCTAssertFalse(preview.compiledPayload.contains("Working space:"))
        XCTAssertTrue(preview.compiledPayload.contains("Desktop: \(BotDesktopKind.logicalExecutionSpace.displayTitle). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertTrue(preview.compiledPayload.contains(BotBrainCompiler.workspaceHostAssignedHonesty))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "Which repo is this?",
                memory: vm.memoryItems,
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
        XCTAssertEqual(piper.workspaceID, workspace.id)
    }

    func test_previewBrainIncludesAdvertisedDesktop_becauseDestMustNotInviteAHop() throws {
        // WHY: Studio already says Desktop. Compile folded isolation into
        // Workspace, so first-chat "which Desktop?" invented a hop. Dest
        // preview and compose must share that advertised name.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "Which Desktop?"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertEqual(vm.studioDesktopSummary, BotDesktopKind.logicalExecutionSpace.displayTitle)
        XCTAssertTrue(preview.compiledPayload.contains("Desktop: \(BotDesktopKind.logicalExecutionSpace.displayTitle). \(BotDesktopKind.logicalExecutionSpaceHonestyLabel)"))
        XCTAssertFalse(preview.compiledPayload.contains("Working space:"))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "Which Desktop?",
                memory: vm.memoryItems,
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesAdvertisedBrowser_becauseDestMustNotOmitTheLastWebsite() throws {
        // WHY: Tools already persist last website. Dest preview never sent
        // URL/title, so first-chat "what's open?" invented a hop. Dest
        // preview and compose must share the advertised last website.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        let store = BotBrowserStore(appSupportDirectory: context.appSupportDirectory)
        try store.persistTarget(
            BotBrowserTarget(url: "https://github.com/remotecode", title: "GitHub"),
            botID: piper.id
        )
        vm.composerText = "What's open?"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertEqual(vm.advertisedBrowser?.url, "https://github.com/remotecode")
        XCTAssertEqual(vm.advertisedBrowser?.title, "GitHub")
        XCTAssertTrue(preview.compiledPayload.contains("Browser: GitHub (https://github.com/remotecode)"))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(preview.compiledPayload.contains("secret-token"), "cookies stay out")
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "What's open?",
                memory: vm.memoryItems,
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace,
                browser: vm.advertisedBrowser
            )
        )
        XCTAssertEqual(
            preview.layers.first(where: { $0.kind == .browser })?.text,
            "Browser: GitHub (https://github.com/remotecode)"
        )
    }

    func test_previewBrainIncludesAdvertisedNotifications_becauseDestMustNotOmitAlerts() throws {
        // WHY: Studio already shows Notifications On/Off. Brain compile never
        // sent that toggle, so first-chat "will you notify me?" invented
        // alerts. Dest preview and compose must share the advertised state.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "Will you notify me?"
        let onPreview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(onPreview.compiledPayload.contains("Notifications: On. Alerts stay on this Mac; not an isolated Desktop."))
        XCTAssertTrue(onPreview.compiledPayload.contains("Own the inbox."))
        vm.openStudio(piper)
        vm.studioDraft.notificationsEnabled = false
        let draftPreview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(draftPreview.compiledPayload.contains("Notifications: Off. This Mac will not alert the owner."))
        XCTAssertFalse(draftPreview.compiledPayload.contains("Notifications: On."))
        _ = try vm.saveStudio()
        vm.openDesk(try XCTUnwrap(vm.selectedBot))
        vm.composerText = "Will you notify me?"
        let offPreview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(offPreview.compiledPayload.contains("Notifications: Off. This Mac will not alert the owner."))
        XCTAssertEqual(
            offPreview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: try XCTUnwrap(vm.selectedBot),
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "Will you notify me?",
                memory: vm.memoryItems,
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesAdvertisedMemoryMutateKey_becauseDestMustNotOmitForgetKeys() throws {
        // WHY: Studio already says Memory. Compile headed facts with
        // Trusted memory, so first-chat "what's in Memory?" invented a hop.
        // Dest preview and compose must share the advertised heading.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.memoryDraft = "Prefers dark mode"
        vm.addMemory()
        let item = try XCTUnwrap(vm.memoryItems.first)
        vm.composerText = "Forget the dark-mode fact"
        let preview = try XCTUnwrap(vm.previewBrain())
        let key = item.id.value.uuidString.lowercased()
        XCTAssertTrue(preview.compiledPayload.contains("Memory:"))
        XCTAssertFalse(preview.compiledPayload.contains("Trusted memory:"))
        XCTAssertTrue(preview.compiledPayload.contains("Fact: Prefers dark mode"))
        XCTAssertTrue(preview.compiledPayload.contains(key))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "Forget the dark-mode fact",
                memory: vm.memoryItems,
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesAdvertisedApprovalMode_becauseDestMustNotInviteAHop() throws {
        // WHY: Studio already says Approval mode. Compile listed Permission,
        // so first-chat "what's your Approval mode?" invented a hop. Dest
        // preview and compose must share that advertised name. Dest Source
        // title stays Permission.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "What's your Approval mode?"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertEqual(vm.studioApprovalLabel, "Supervised")
        XCTAssertTrue(preview.compiledPayload.contains("Approval mode: \(BotPermission.honestyLabel) \(BotBrainCompiler.approvalsHonesty) \(BotBrainCompiler.approvalModeHostAssignedHonesty)"))
        XCTAssertTrue(preview.compiledPayload.contains(BotBrainCompiler.approvalModeHostAssignedHonesty))
        XCTAssertTrue(preview.compiledPayload.contains(BotBrainCompiler.approvalsHonesty))
        XCTAssertFalse(preview.compiledPayload.contains("Permission:"))
        XCTAssertEqual(preview.layers.first(where: { $0.kind == .permission })?.title, "Permission")
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "What's your Approval mode?",
                memory: vm.memoryItems,
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesAdvertisedApprovals_becauseDestMustNotInviteAHop() throws {
        // WHY: Studio Security already says Approvals. Compile listed
        // Approval mode only, so first-chat "Allow once" invented a grant.
        // Dest preview and compose must share that advertised name. Dest
        // Source title stays Permission.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "Allow once"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(preview.compiledPayload.contains(BotBrainCompiler.approvalsHonesty))
        XCTAssertTrue(preview.compiledPayload.contains("Allow once / Deny stay off until P1b"))
        XCTAssertTrue(preview.compiledPayload.contains("Approval mode: \(BotPermission.honestyLabel) \(BotBrainCompiler.approvalsHonesty) \(BotBrainCompiler.approvalModeHostAssignedHonesty)"))
        XCTAssertFalse(preview.compiledPayload.contains("Permission:"))
        XCTAssertEqual(preview.layers.first(where: { $0.kind == .permission })?.title, "Permission")
        XCTAssertEqual(
            preview.layers.first(where: { $0.kind == .permission })?.text,
            "\(BotPermission.honestyLabel) \(BotBrainCompiler.approvalsHonesty) \(BotBrainCompiler.approvalModeHostAssignedHonesty)"
        )
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "Allow once",
                memory: vm.memoryItems,
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesAdvertisedHandleCreateOnlyHonesty_becauseDestMustNotInviteAWrite() throws {
        // WHY: Studio Handle is create-only after first save. Compile already
        // showed @handle next to Role, so first-chat "change your handle"
        // invented a write. Dest preview and compose must share that honesty.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "Change your handle"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(preview.compiledPayload.contains("@\(piper.handle)"))
        XCTAssertTrue(preview.compiledPayload.contains(BotBrainCompiler.handleCreateOnlyHonesty))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "Change your handle",
                memory: vm.memoryItems,
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesAdvertisedRole_becauseDestMustNotLeaveTheJobUnlabeled() throws {
        // WHY: Studio already says Role. Compile put the job unlabeled after
        // an em-dash, so first-chat "what's your Role?" invented a hop. Dest
        // preview and compose must share the advertised name. Empty stays out.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "What's your Role?"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(preview.compiledPayload.contains("Role: Scout"))
        XCTAssertFalse(preview.compiledPayload.contains("You are Piper (@piper) — Scout"))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "What's your Role?",
                memory: vm.memoryItems,
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesAdvertisedInstructions_becauseDestMustNotSayStandingInstructions() throws {
        // WHY: Studio already says Instructions. Compile headed the soul
        // with Standing instructions, so first-chat "what are your
        // Instructions?" invented a hop. Dest preview and compose must
        // share the advertised name. Custom soul still wins the body.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "What are your Instructions?"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(preview.compiledPayload.contains("Instructions:"))
        XCTAssertFalse(preview.compiledPayload.contains("Standing instructions:"))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "What are your Instructions?",
                memory: vm.memoryItems,
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesAdvertisedModel_becauseDestMustNotInviteAHop() throws {
        // WHY: Studio already says Model. Compile listed it unlabeled after
        // · on Default route, so first-chat "what's your Model?" invented a
        // hop. Dest preview and compose must share the advertised name.
        // Empty stays out. Dest Source title stays Route.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "What's your Model?"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(preview.compiledPayload.contains("Model: opus"))
        XCTAssertTrue(preview.compiledPayload.contains("Default route: Claude · opus"))
        XCTAssertTrue(preview.compiledPayload.contains(BotRoute.fallbackOrderHonesty))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(preview.layers.first(where: { $0.kind == .route })?.title, "Route")
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "What's your Model?",
                memory: vm.memoryItems,
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesAdvertisedFallbackOrder_becauseDestMustNotInviteAHop() throws {
        // WHY: Studio already says Fallback order is not shipped. Compile
        // listed Default route only, so first-chat "if Claude is down use
        // Grok" invented a second route. Dest preview and compose must
        // share that advertised honesty. Dest Source title stays Route.
        // Schema does not grow a fallback tool.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "If Claude is down use Grok"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(preview.compiledPayload.contains(BotRoute.fallbackOrderHonesty))
        XCTAssertTrue(preview.compiledPayload.contains("Default route: Claude · opus. \(BotRoute.fallbackOrderHonesty)"))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(preview.compiledPayload.contains("bot_set_fallback"))
        XCTAssertFalse(preview.layers.contains { $0.title == "Fallback" })
        XCTAssertEqual(preview.layers.first(where: { $0.kind == .route })?.title, "Route")
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "If Claude is down use Grok",
                memory: vm.memoryItems,
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesAdvertisedRoutines_becauseDestMustNotSayActiveRoutines() throws {
        // WHY: Studio already says Routines. Compile listed Active routines,
        // so first-chat "what are your Routines?" invented a hop. Dest
        // preview and compose must share the advertised name. Active stays
        // on each live line. Dest Source title stays Routine.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.routineScheduleNote = "Weekdays 9:00"
        vm.saveRoutine()
        let id = try XCTUnwrap(vm.routines.first?.definition.id)
        vm.setRoutineEnabled(id: id, enabled: true)
        vm.composerText = "What are your Routines?"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(preview.compiledPayload.contains("Routines (not while the app is closed):"))
        XCTAssertTrue(preview.compiledPayload.contains("Morning scan: Instruction: Scan overnight failures. When: Weekdays 9:00. Active."))
        XCTAssertFalse(preview.compiledPayload.contains("Active routines"))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(preview.layers.contains { $0.title == "Routines" })
        XCTAssertEqual(preview.layers.first(where: { $0.kind == .routine })?.title, "Routine")
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "What are your Routines?",
                memory: vm.memoryItems,
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesAdvertisedTestRun_becauseDestMustNotInviteAHop() throws {
        // WHY: Studio already says Test run. Compile listed Active routines
        // only, so first-chat "test this routine" invented a hop or a
        // schedule fire. Dest preview and compose must share the advertised
        // name. Dest Source title stays Routine. Schema does not grow a
        // test tool.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.routineScheduleNote = "Weekdays 9:00"
        vm.saveRoutine()
        let id = try XCTUnwrap(vm.routines.first?.definition.id)
        vm.setRoutineEnabled(id: id, enabled: true)
        vm.composerText = "Test this routine"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(preview.compiledPayload.contains("Test run: do the Instruction now. Does not set Active."))
        XCTAssertTrue(preview.compiledPayload.contains(BotRoutineCopy.testRunHonestyCaption))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(preview.compiledPayload.contains("bot_test_routine"))
        XCTAssertFalse(preview.layers.contains { $0.title == "Test run" })
        XCTAssertEqual(preview.layers.first(where: { $0.kind == .routine })?.title, "Routine")
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "Test this routine",
                memory: vm.memoryItems,
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesAdvertisedSkills_becauseDestMustNotSayEnabledSkills() throws {
        // WHY: Studio already says Skills. Compile listed Enabled skills, so
        // first-chat "which Skills?" invented a hop. Dest preview and compose
        // must share the advertised name. Off stays out.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        vm.skillDraft = "weekly-account-health"
        vm.addSkill()
        vm.skillDraft = "off-skill"
        vm.addSkill()
        vm.setSkillEnabled(skillID: "off-skill", enabled: false)
        vm.composerText = "Which Skills?"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(preview.compiledPayload.contains("Skills: weekly-account-health"))
        XCTAssertFalse(preview.compiledPayload.contains("Enabled skills"))
        XCTAssertFalse(preview.compiledPayload.contains("off-skill"))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "Which Skills?",
                memory: vm.memoryItems,
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesEnabledRoutine_becauseDestMustNotOmitSchedules() throws {
        // WHY: Brain Inspector / Desk send used dest memory+skills and
        // skipped dest routines. Owner-authored Morning scan never reached
        // the model unless it called get_settings.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.", provider: .claude)
        vm.openDesk(piper)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.routineScheduleNote = "Weekdays 9:00"
        vm.saveRoutine()
        let id = try XCTUnwrap(vm.routines.first?.definition.id)
        let listsBefore = vm.routineListCountForTesting
        vm.setRoutineEnabled(id: id, enabled: true)
        vm.composerText = "What do you run?"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(preview.compiledPayload.contains("Morning scan: Instruction: Scan overnight failures. When: Weekdays 9:00"))
        XCTAssertTrue(preview.compiledPayload.contains("not while the app is closed"))
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "What do you run?",
                memory: vm.memoryItems,
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
        XCTAssertEqual(
            vm.routineListCountForTesting,
            listsBefore,
            "preview dest must use dest-cached routines"
        )
    }

    func test_saveRoutineKeepsExistingRoutines_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first save is honest only when older schedules stay
        // visible and the new row paints first.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        try context.botStore.saveRoutine(
            BotRoutineDefinition(
                botID: piper.id,
                name: "Older scan",
                prompt: "Scan last night",
                scheduleNote: "Daily"
            )
        )
        vm.beginEdit(piper)
        XCTAssertEqual(vm.routines.map(\.definition.name), ["Older scan"])
        let afterStudio = vm.routineListCountForTesting
        vm.routineName = "Newer scan"
        vm.routinePrompt = "Scan this morning"
        vm.saveRoutine()
        XCTAssertEqual(vm.routines.first?.definition.name, "Newer scan")
        XCTAssertEqual(
            Set(vm.routines.map(\.definition.name)),
            Set(["Newer scan", "Older scan"])
        )
        XCTAssertEqual(vm.routineListCountForTesting, afterStudio)
        XCTAssertEqual(
            Set(try context.botStore.listRoutines(botID: piper.id).map(\.definition.name)),
            Set(["Newer scan", "Older scan"])
        )
    }

    func test_setRoutineEnabledDoesNotListRoutines_becauseEnableDestMustNotRereadSchedules() throws {
        // WHY: Enable dest used to listRoutines after the store wrote this
        // activation. Dest must not reread every schedule.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(piper)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.saveRoutine()
        let routine = try XCTUnwrap(vm.routines.first)
        XCTAssertFalse(routine.activation.isEnabled)
        let afterSave = vm.routineListCountForTesting
        vm.setRoutineEnabled(id: routine.definition.id, enabled: true)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.routines.first?.definition.name, "Morning scan")
        XCTAssertTrue(try XCTUnwrap(vm.routines.first).activation.isEnabled)
        XCTAssertEqual(vm.enabledRoutineCount, 1)
        XCTAssertEqual(
            vm.routineListCountForTesting,
            afterSave,
            "enable dest must not reread every routine"
        )
        XCTAssertTrue(
            try XCTUnwrap(context.botStore.listRoutines(botID: piper.id).first).activation.isEnabled
        )
    }

    func test_setRoutineEnabledKeepsExistingRoutines_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first enable is honest only when older schedules stay
        // visible and only this row flips Active.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        try context.botStore.saveRoutine(
            BotRoutineDefinition(
                botID: piper.id,
                name: "Older scan",
                prompt: "Scan last night",
                scheduleNote: "Daily"
            )
        )
        vm.beginEdit(piper)
        vm.routineName = "Newer scan"
        vm.routinePrompt = "Scan this morning"
        vm.saveRoutine()
        let newer = try XCTUnwrap(vm.routines.first { $0.definition.name == "Newer scan" })
        let afterSave = vm.routineListCountForTesting
        vm.setRoutineEnabled(id: newer.definition.id, enabled: true)
        XCTAssertEqual(
            Set(vm.routines.map(\.definition.name)),
            Set(["Newer scan", "Older scan"])
        )
        XCTAssertTrue(try XCTUnwrap(vm.routines.first { $0.definition.name == "Newer scan" }).activation.isEnabled)
        XCTAssertFalse(try XCTUnwrap(vm.routines.first { $0.definition.name == "Older scan" }).activation.isEnabled)
        XCTAssertEqual(vm.enabledRoutineCount, 1)
        XCTAssertEqual(vm.routineListCountForTesting, afterSave)
        vm.setRoutineEnabled(id: newer.definition.id, enabled: false)
        XCTAssertFalse(try XCTUnwrap(vm.routines.first { $0.definition.name == "Newer scan" }).activation.isEnabled)
        XCTAssertEqual(vm.enabledRoutineCount, 0)
        XCTAssertEqual(vm.routineListCountForTesting, afterSave)
        XCTAssertEqual(vm.screen, .studio)
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

    func test_routineTestRunAcknowledgesBeforeDeskReload_becauseStudioMustNotWaitOnChat() throws {
        // WHY: Studio Test run used to openDesk (mark-read + transcript
        // restore) before send, so first feedback waited on dest work.
        // The click must acknowledge on Studio; Desk is where the turn lives.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.saveRoutine()
        let routine = try XCTUnwrap(vm.routines.first)
        XCTAssertEqual(vm.screen, .studio)

        vm.requestRoutineTestRun(id: routine.definition.id)

        XCTAssertEqual(
            vm.lastSendAcknowledgedOnScreenForTesting,
            .studio,
            "Test run must acknowledge before dest reload"
        )
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.deskMessages.first?.text, "Scan overnight failures")
    }

    func test_requestRoutineTestRunDoesNotListRoutines_becauseTestRunDestMustNotRereadSchedules() throws {
        // WHY: Test run dest used to listRoutines after the store stamped
        // this request. Dest must not reread every schedule.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(piper)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.saveRoutine()
        let routine = try XCTUnwrap(vm.routines.first)
        XCTAssertNil(routine.activation.lastTestRunRequestedAt)
        let afterSave = vm.routineListCountForTesting
        vm.requestRoutineTestRun(id: routine.definition.id)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.routines.first?.definition.name, "Morning scan")
        XCTAssertNotNil(try XCTUnwrap(vm.routines.first).activation.lastTestRunRequestedAt)
        XCTAssertFalse(try XCTUnwrap(vm.routines.first).activation.isEnabled)
        XCTAssertEqual(
            vm.routineListCountForTesting,
            afterSave,
            "test run dest must not reread every routine"
        )
        XCTAssertNotNil(
            try XCTUnwrap(context.botStore.listRoutines(botID: piper.id).first).activation.lastTestRunRequestedAt
        )
    }

    func test_requestRoutineTestRunKeepsExistingRoutines_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first test run is honest only when older schedules stay
        // visible and only this row stamps the request.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        try context.botStore.saveRoutine(
            BotRoutineDefinition(
                botID: piper.id,
                name: "Older scan",
                prompt: "Scan last night",
                scheduleNote: "Daily"
            )
        )
        vm.beginEdit(piper)
        vm.routineName = "Newer scan"
        vm.routinePrompt = "Scan this morning"
        vm.saveRoutine()
        let newer = try XCTUnwrap(vm.routines.first { $0.definition.name == "Newer scan" })
        let afterSave = vm.routineListCountForTesting
        vm.requestRoutineTestRun(id: newer.definition.id)
        XCTAssertEqual(
            Set(vm.routines.map(\.definition.name)),
            Set(["Newer scan", "Older scan"])
        )
        XCTAssertNotNil(try XCTUnwrap(vm.routines.first { $0.definition.name == "Newer scan" }).activation.lastTestRunRequestedAt)
        XCTAssertNil(try XCTUnwrap(vm.routines.first { $0.definition.name == "Older scan" }).activation.lastTestRunRequestedAt)
        XCTAssertFalse(try XCTUnwrap(vm.routines.first { $0.definition.name == "Newer scan" }).activation.isEnabled)
        XCTAssertEqual(vm.routineListCountForTesting, afterSave)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.deskMessages.first?.text, "Scan this morning")
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

    func test_brainPaneSurvivesRelaunch_becauseSelectedTabsAreUserWorkflowState() throws {
        // WHY: Source vs Effective is a selected Brain pane. Relaunch used
        // to drop Effective back to Source while inspectorTab stayed Brain.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.inspectorTab = .brain
        vm.brainPane = .effective
        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.inspectorTab, .brain)
        XCTAssertEqual(reopened.brainPane, .effective)
    }

    func test_previewBrainReusesUnchangedAssembly_becauseBrainDestMustNotRecompile() throws {
        // WHY: Studio Brain dest called assemble on every SwiftUI body.
        // An unchanged bot/memory/composer is already the honest preview.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.", provider: .claude)
        vm.beginEdit(bot)
        XCTAssertNotNil(vm.previewBrain())
        let afterFirst = vm.previewBrainAssembleCountForTesting
        XCTAssertGreaterThan(afterFirst, 0)
        XCTAssertNotNil(vm.previewBrain())
        XCTAssertEqual(
            vm.previewBrainAssembleCountForTesting,
            afterFirst,
            "Brain dest must not reassemble when inputs did not change"
        )
    }

    func test_previewBrainReassemblesWhenComposerChanges_becauseStalePreviewMustNotLookCurrent() throws {
        // WHY: cache-first preview is honest only when a new composer line
        // still replaces the compiled payload.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.", provider: .claude)
        vm.beginEdit(bot)
        XCTAssertNotNil(vm.previewBrain())
        let afterFirst = vm.previewBrainAssembleCountForTesting
        vm.composerText = "What did you see last night?"
        let next = try XCTUnwrap(vm.previewBrain())
        XCTAssertEqual(vm.previewBrainAssembleCountForTesting, afterFirst + 1)
        XCTAssertTrue(next.compiledPayload.contains("What did you see last night?"))
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

    func test_reloadingDeskDoesNotListFleetConversations_becauseRemountDestMustNotScanEveryTeammate() throws {
        // WHY: leaving Bots and coming back calls reload() on the same dest.
        // Remount dest used to list every teammate's conversations before
        // dest dested Chat. Dest already has dest cache and dest inbox.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Summarize overnight"))
        let afterDest = vm.conversationListCountForTesting
        XCTAssertGreaterThan(afterDest, 0)
        vm.reload()
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.deskMessages.first?.text, "Summarize overnight")
        XCTAssertEqual(
            vm.conversationListCountForTesting,
            afterDest,
            "remount dest must not scan every teammate"
        )
    }

    func test_reloadingDeskKeepsChatAndRoster_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first remount is honest only when dest still dests this
        // teammate's bubble and the roster dest already dested.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Summarize overnight"))
        let destPreview = vm.rosterPreview(for: piper)
        XCTAssertFalse(destPreview.isEmpty)
        vm.reload()
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.deskMessages.first?.text, "Summarize overnight")
        XCTAssertEqual(
            vm.rosterPreview(for: piper),
            destPreview,
            "remount dest must keep dest roster preview dest already dested"
        )
        XCTAssertEqual(Set(vm.fleet.map(\.id)), [piper.id, quinn.id])
        XCTAssertEqual(vm.fleet.map(\.name).sorted(), ["Piper", "Quinn"])
    }

    func test_reloadingDeskStillListsInbox_becauseStaleBellMustNotLookCurrent() throws {
        // WHY: remount dest skips the fleet conversation scan, but dest
        // inbox must still refresh so a new needs-you cannot look empty.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Summarize overnight"))
        try context.botStore.upsertAttention(
            BotAttentionItem(botID: piper.id, kind: .approval, title: "Approve vendor brief")
        )
        XCTAssertFalse(vm.attentionItems.contains(where: { $0.title == "Approve vendor brief" }))
        vm.reload()
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.deskMessages.first?.text, "Summarize overnight")
        XCTAssertTrue(
            vm.attentionItems.contains(where: { $0.title == "Approve vendor brief" }),
            "remount dest must still dest dest inbox"
        )
        XCTAssertEqual(vm.attentionState(for: piper), .needsAttention)
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

    func test_openingBotsDoesNotListOtherTeammateConversations_becauseFirstPaintDestMustDestChat() throws {
        // WHY: first paint of Bots is a new dest. Dest used to list every
        // teammate's conversations before dest dested the open Chat.
        // Dest dests this teammate; dest dests the others when dest dests them.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("From Piper"))
        vm.openDesk(quinn)
        XCTAssertTrue(vm.send("From Quinn"))
        vm.openDesk(piper)
        let dest = BotsViewModel(context: context)
        XCTAssertEqual(dest.screen, .desk)
        XCTAssertEqual(dest.selectedBotID, piper.id)
        XCTAssertEqual(dest.deskMessages.first?.text, "From Piper")
        let afterDest = dest.conversationListCountForTesting
        XCTAssertGreaterThan(afterDest, 0)
        dest.openDesk(quinn)
        XCTAssertEqual(dest.selectedBotID, quinn.id)
        XCTAssertEqual(dest.deskMessages.first?.text, "From Quinn")
        XCTAssertGreaterThan(
            dest.conversationListCountForTesting,
            afterDest,
            "dest dests Quinn when dest dests that row"
        )
    }

    func test_openingBotsKeepsSelectedChat_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first first paint is honest only when dest dests this
        // teammate's bubble and dest dests the roster dest already dested.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("From Piper"))
        vm.openDesk(quinn)
        XCTAssertTrue(vm.send("From Quinn"))
        vm.openDesk(piper)
        let dest = BotsViewModel(context: context)
        XCTAssertEqual(dest.screen, .desk)
        XCTAssertEqual(dest.selectedBotID, piper.id)
        XCTAssertEqual(dest.deskMessages.first?.text, "From Piper")
        XCTAssertEqual(Set(dest.fleet.map(\.id)), [piper.id, quinn.id])
        XCTAssertEqual(dest.fleet.map(\.name).sorted(), ["Piper", "Quinn"])
        XCTAssertFalse(dest.rosterPreview(for: piper).isEmpty)
        XCTAssertNotEqual(dest.rosterPreview(for: piper), "No job yet")
        XCTAssertTrue(
            dest.rosterPreview(for: piper).contains("From Piper")
                || dest.deskMessages.contains(where: { $0.text == "From Piper" })
        )
    }

    func test_openingBotsStillDestsTheOtherTeammate_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: first paint dest skips Quinn's conversation scan, but dest
        // dests Quinn's thread when dest dests that row so dest cannot
        // look empty after dest dested Quinn.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("From Piper"))
        vm.openDesk(quinn)
        XCTAssertTrue(vm.send("From Quinn"))
        vm.openDesk(piper)
        let dest = BotsViewModel(context: context)
        XCTAssertEqual(dest.deskMessages.first?.text, "From Piper")
        dest.openDesk(quinn)
        XCTAssertEqual(dest.screen, .desk)
        XCTAssertEqual(dest.selectedBotID, quinn.id)
        XCTAssertEqual(dest.deskMessages.first?.text, "From Quinn")
        XCTAssertTrue(dest.deskMessages.contains(where: { $0.text == "From Quinn" }))
    }

    func test_openingBotsRestoresChatBeforeInspector_becauseFirstPaintDestMustDestChat() throws {
        // WHY: first paint dest used to dest inspector (six store
        // reads) before dest dested Chat. Dest dests this bubble
        // first; dest dests inspector after dest dested Chat.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("From Piper"))
        vm.openDesk(quinn)
        XCTAssertTrue(vm.send("From Quinn"))
        vm.openDesk(piper)
        let dest = BotsViewModel(context: context)
        XCTAssertEqual(dest.screen, .desk)
        XCTAssertEqual(dest.selectedBotID, piper.id)
        XCTAssertEqual(dest.deskMessages.first?.text, "From Piper")
        XCTAssertGreaterThan(dest.deskRestoreInvokedCountForTesting, 0)
        XCTAssertEqual(
            dest.lastDeskRestoreStudioSupportCountForTesting,
            0,
            "dest dests Chat before dest dests inspector"
        )
        XCTAssertGreaterThan(
            dest.studioSupportReloadCountForTesting,
            dest.lastDeskRestoreStudioSupportCountForTesting,
            "dest dests inspector after dest dested Chat"
        )
    }

    func test_openingBotsStillDestsInspector_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first Chat is honest only when dest dests Brain
        // after dest dested this bubble. Dest dests inspector so
        // Memory/Skills cannot look empty after dest dested Chat.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("From Piper"))
        _ = try context.botStore.putMemory(
            botID: piper.id,
            content: "Prefers dark mode",
            provenance: "user",
            trusted: true,
            source: "studio"
        )
        try context.botStore.setSkillBinding(
            BotSkillBinding(botID: piper.id, skillID: "weekly-account-health", enabled: true)
        )
        let dest = BotsViewModel(context: context)
        XCTAssertEqual(dest.deskMessages.first?.text, "From Piper")
        XCTAssertEqual(dest.liveMemoryCount, 1)
        XCTAssertEqual(dest.enabledSkillCount, 1)
    }

    func test_openingBotsRestoresChatBeforeInbox_becauseFirstPaintDestMustDestChat() throws {
        // WHY: first paint dest used to dest inbox (listAttention)
        // before dest dested Chat. Dest dests this bubble first;
        // dest dests inbox after dest dested Chat.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("From Piper"))
        try context.botStore.upsertAttention(
            BotAttentionItem(botID: piper.id, kind: .approval, title: "Approve vendor brief")
        )
        let dest = BotsViewModel(context: context)
        XCTAssertEqual(dest.screen, .desk)
        XCTAssertEqual(dest.selectedBotID, piper.id)
        XCTAssertEqual(dest.deskMessages.first?.text, "From Piper")
        XCTAssertGreaterThan(dest.deskRestoreInvokedCountForTesting, 0)
        XCTAssertEqual(
            dest.lastDeskRestoreAttentionListCountForTesting,
            0,
            "dest dests Chat before dest dests inbox"
        )
        XCTAssertGreaterThan(
            dest.attentionListCountForTesting,
            dest.lastDeskRestoreAttentionListCountForTesting,
            "dest dests inbox after dest dested Chat"
        )
    }

    func test_openingBotsStillDestsInbox_becauseStaleBellMustNotLookCurrent() throws {
        // WHY: dest-first Chat is honest only when dest dests inbox
        // after dest dested this bubble. Dest dests the bell so a
        // needs-you cannot look empty after dest dested Chat.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("From Piper"))
        try context.botStore.upsertAttention(
            BotAttentionItem(botID: piper.id, kind: .approval, title: "Approve vendor brief")
        )
        XCTAssertFalse(vm.attentionItems.contains(where: { $0.title == "Approve vendor brief" }))
        let dest = BotsViewModel(context: context)
        XCTAssertEqual(dest.deskMessages.first?.text, "From Piper")
        XCTAssertTrue(
            dest.attentionItems.contains(where: { $0.title == "Approve vendor brief" }),
            "first paint dest must still dest dest inbox"
        )
        XCTAssertEqual(dest.attentionState(for: piper), .needsAttention)
    }

    func test_openingBotsRestoresChatBeforeRosterPreview_becauseFirstPaintDestMustDestChat() throws {
        // WHY: first paint dest used to dest dest preview
        // (listConversations + listRecent) before dest dested Chat.
        // Dest dests this bubble first; dest dests dest preview
        // from dest Chat.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("From Piper"))
        let dest = BotsViewModel(context: context)
        XCTAssertEqual(dest.screen, .desk)
        XCTAssertEqual(dest.selectedBotID, piper.id)
        XCTAssertEqual(dest.deskMessages.first?.text, "From Piper")
        XCTAssertGreaterThan(dest.deskRestoreInvokedCountForTesting, 0)
        XCTAssertEqual(
            dest.lastDeskRestoreConversationListCountForTesting,
            0,
            "dest dests Chat before dest dests dest preview"
        )
        XCTAssertGreaterThan(
            dest.conversationListCountForTesting,
            dest.lastDeskRestoreConversationListCountForTesting,
            "dest dests dest preview after dest dested Chat"
        )
        XCTAssertTrue(
            dest.rosterPreview(for: piper).contains("From Piper")
                || dest.deskMessages.contains(where: { $0.text == "From Piper" }),
            "dest dests dest preview from dest Chat"
        )
    }

    func test_openingBotsRestoresChatBeforeThread_becauseFirstPaintDestMustDestChat() throws {
        // WHY: first paint dest used to dest dest thread (listRecent)
        // before dest dested Chat. Dest dests dest title first;
        // dest dests dest thread after dest dested Chat.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        try seedLinkedTurn(context: context, bot: piper, extraReasoning: 2)
        vm.openDesk(piper)
        XCTAssertTrue(vm.deskMessages.contains(where: { $0.text == "Summarize overnight" }))
        let dest = BotsViewModel(context: context)
        XCTAssertEqual(dest.screen, .desk)
        XCTAssertEqual(dest.selectedBotID, piper.id)
        XCTAssertTrue(
            dest.deskMessages.contains(where: { $0.text == "Summarize overnight" }),
            "dest dests dest thread after dest dested dest title"
        )
        XCTAssertGreaterThan(dest.deskRestoreInvokedCountForTesting, 0)
        XCTAssertEqual(
            dest.lastDeskRestoreMessageListCountForTesting,
            0,
            "dest dests Chat from dest title before dest dests dest thread"
        )
        XCTAssertGreaterThan(
            dest.deskMessageRestoreCountForTesting,
            dest.lastDeskRestoreMessageListCountForTesting,
            "dest dests dest thread after dest dested Chat"
        )
    }

    func test_unpublishedStudioDraftSurvivesRelaunch_becauseDraftIsUserWorkflowState() throws {
        // WHY: composer and inspector drafts persist. Studio title/soul used
        // to vanish on remount because loadStudioDraft always reloaded the
        // published revision. Unpublished Brain is user workflow state.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(
            name: "Piper",
            title: "Scout",
            soul: "Be brief.",
            provider: .claude
        )
        vm.beginEdit(bot)
        vm.studioDraft.title = "Research lead"
        vm.studioDraft.soul = "Stand up for the brief."
        XCTAssertTrue(vm.studioHasUnpublishedChanges)

        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.screen, .studio)
        XCTAssertEqual(reopened.studioDraft.botID, bot.id)
        XCTAssertEqual(reopened.studioDraft.title, "Research lead")
        XCTAssertEqual(reopened.studioDraft.soul, "Stand up for the brief.")
        XCTAssertTrue(reopened.studioHasUnpublishedChanges)

        reopened.openDesk(bot)
        let fromDesk = BotsViewModel(context: context)
        fromDesk.openStudio(bot)
        XCTAssertEqual(fromDesk.studioDraft.title, "Research lead")
        XCTAssertEqual(fromDesk.studioDraft.soul, "Stand up for the brief.")
        XCTAssertTrue(fromDesk.studioHasUnpublishedChanges)
    }

    func test_unpublishedStudioDraftStaysOnOwningBot_becauseBrainEditsMustNotLeak() throws {
        // WHY: composer/inspector drafts are keyed by BotID. A single
        // studioDraft persist used to overwrite teammate A's Role when the
        // user typed on teammate B Studio.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", soul: "Be kind.", provider: .claude)
        vm.beginEdit(piper)
        vm.studioDraft.title = "Fire14 lead A"
        vm.openStudio(quinn)
        vm.studioDraft.title = "Fire14 lead B"
        XCTAssertEqual(vm.studioDraft.title, "Fire14 lead B")

        vm.openStudio(piper)
        XCTAssertEqual(vm.studioDraft.botID, piper.id)
        XCTAssertEqual(vm.studioDraft.title, "Fire14 lead A")
        XCTAssertEqual(vm.studioDraft.soul, "Be brief.")

        vm.openStudio(quinn)
        XCTAssertEqual(vm.studioDraft.botID, quinn.id)
        XCTAssertEqual(vm.studioDraft.title, "Fire14 lead B")
        XCTAssertEqual(vm.studioDraft.soul, "Be kind.")

        let reopened = BotsViewModel(context: context)
        reopened.openStudio(piper)
        XCTAssertEqual(reopened.studioDraft.title, "Fire14 lead A")
        reopened.openStudio(quinn)
        XCTAssertEqual(reopened.studioDraft.title, "Fire14 lead B")
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

    func test_studioDestKeepsLastTab_becauseStudioIsNotProfile() throws {
        // WHY: Chat's Studio button called beginEdit, which forced Profile.
        // Skills/Memory are selected tabs. Returning to Studio must keep them.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openStudio(piper)
        vm.studioTab = .skills
        vm.openDesk(piper)
        XCTAssertEqual(vm.screen, .desk)
        vm.openStudio(piper)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioTab, .skills)
        XCTAssertEqual(vm.studioDraft.botID, piper.id)
    }

    func test_editFromRosterOpensProfile_becauseEditIsIdentity() throws {
        // WHY: Roster Edit is "change this teammate's name", not "resume Skills".
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.studioTab = .skills
        vm.beginEdit(piper)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioTab, .profile)
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

    func test_beginCreateOpensStudio_becauseNewBotIsAConfigureDest() throws {
        // WHY: New Bot used to skip Studio and land on Chat. Users need
        // Profile first so name, role, and provider are set before talking.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.beginCreate()

        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioTab, .profile)
        XCTAssertEqual(vm.studioDraft.botID, vm.selectedBotID)
        XCTAssertEqual(try context.botStore.list().count, 1)
        XCTAssertEqual(try context.botStore.list().first?.name, "New Agent")
        XCTAssertTrue(try context.threadRepo.list().isEmpty)
    }

    func test_deskRoutingSeedsFromPublishedRoute_becauseComposerStartsOnTheStudioDefault() throws {
        // WHY: Desk must not invent Codex when Studio published Claude.
        // The published route is the seed, not a later lock.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude, model: "opus")
        vm.openDesk(bot)
        XCTAssertEqual(vm.deskRunProvider, .claude)
        XCTAssertEqual(vm.deskRunModel, "opus")
        XCTAssertEqual(vm.deskRunPermissionMode, .supervised)
        XCTAssertEqual(vm.resolvedProvider(for: bot), .claude)
    }

    func test_deskSendUsesComposerProvider_notPublishedRoute() throws {
        // WHY: Bots were locked to the published revision provider. Desk
        // must send with the composer chips so a teammate can use Codex
        // after Studio published Claude.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude, model: "opus")
        vm.openDesk(bot)
        vm.setDeskProvider(.grok)
        vm.setDeskRoutingMode(.auto)
        vm.setDeskPermissionMode(.fullAccess)
        XCTAssertEqual(vm.deskRunProvider, .grok)
        XCTAssertEqual(vm.deskRunModel, BotsViewModel.defaultModel(for: .grok))
        XCTAssertEqual(vm.deskRunPermissionMode, .fullAccess)
        XCTAssertEqual(vm.resolvedProvider(for: bot), .claude)
        vm.setDeskReasoningEffort(.high)
        XCTAssertEqual(vm.deskRunReasoning, .high)
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("accessibilityIdentifier(\"bots.desk.source\")"))
        XCTAssertTrue(source.contains("accessibilityIdentifier(\"bots.desk.model\")"))
        XCTAssertTrue(source.contains("accessibilityIdentifier(\"bots.desk.permission\")"))
        XCTAssertTrue(source.contains("accessibilityIdentifier(\"bots.desk.model.popover\")"))
        guard let start = source.range(of: "private func startSupervisedRun") else {
            return XCTFail("startSupervisedRun must exist")
        }
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\n    private func followLinkedRun")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertTrue(slice.contains("provider: deskRouting.provider"))
        XCTAssertTrue(slice.contains("permissionMode: deskRouting.permissionMode"))
        XCTAssertTrue(slice.contains("reasoningEffort: effort"))
        XCTAssertTrue(slice.contains("workspace: nil"))
        XCTAssertFalse(
            slice.contains("provider: revision.provider"),
            "Desk send must not stay locked to the published Studio route"
        )
        XCTAssertFalse(
            slice.contains("reasoningEffort: revision.reasoningEffort"),
            "Desk send must use the composer reasoning chip"
        )
    }

    func test_deskHeaderFollowsComposerRoute() throws {
        // WHY: the identity row used to keep Studio's published Claude/opus
        // after the footer switched to Grok. The live send route must show.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude, model: "opus")
        vm.openDesk(bot)
        XCTAssertEqual(vm.providerLabel(for: bot), "Claude")
        XCTAssertEqual(vm.modelLabel(for: bot), "opus")
        vm.setDeskProvider(.grok)
        vm.setDeskRoutingMode(.manual)
        vm.setDeskModel(BotsViewModel.defaultModel(for: .grok))
        vm.setDeskPermissionMode(.fullAccess)
        XCTAssertEqual(vm.providerLabel(for: bot), "Grok")
        XCTAssertEqual(vm.modelLabel(for: bot), BotsViewModel.defaultModel(for: .grok))
        XCTAssertEqual(vm.permissionLabel(for: bot), "Full access")
        XCTAssertEqual(vm.resolvedProvider(for: bot), .claude)
    }

    func test_botMentionParserResolvesHandle_excludingOpenTeammate() throws {
        // WHY: @ in Desk must pick another teammate. Mentioning yourself
        // would loop the same run instead of starting a peer turn.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(piper)
        XCTAssertEqual(
            BotMentionParser.mentionedBots(in: "@quinn ping the inbox", bots: vm.bots, excluding: piper.id).map(\.id),
            [quinn.id]
        )
        XCTAssertTrue(
            BotMentionParser.mentionedBots(in: "@piper stay here", bots: vm.bots, excluding: piper.id).isEmpty
        )
        vm.composerText = "@q"
        XCTAssertEqual(vm.botMentionSuggestions.map(\.id), [quinn.id])
        vm.applyBotMention(quinn)
        XCTAssertTrue(vm.composerText.contains("@\(quinn.handle)"))
        XCTAssertNil(BotMentionParser.activeQuery(in: vm.composerText))
    }

    func test_sendWithMentionTargetsPeer_notOnlyHost() throws {
        // WHY: "@quinn do X" from Piper's Desk must run Quinn and paint
        // Messaged Quinn on Piper's transcript. A host-only send would
        // never let teammates talk to each other.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(piper)
        vm.composerText = "@quinn check WhatsApp"
        XCTAssertTrue(vm.send())
        XCTAssertEqual(vm.lastMentionedBotIDForTesting, quinn.id)
        let outbound = try XCTUnwrap(vm.deskMessages.last)
        XCTAssertEqual(outbound.role, .user)
        XCTAssertEqual(outbound.peer?.direction, .messaged)
        XCTAssertEqual(outbound.peer?.botID, quinn.id)
        XCTAssertEqual(outbound.peer?.caption, "Messaged Quinn - CRM Controller - \(quinn.handle)")
        XCTAssertTrue(outbound.text.contains("@quinn"))
    }

    func test_runMentionedPromptTargetsPeerFromAgentApp() async throws {
        // WHY: Agent App mentions call this entry. It must mark the peer
        // and persist onto that teammate without stealing the open Desk.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(piper)
        let reply = await vm.runMentionedPrompt(peer: quinn, text: "@quinn check WhatsApp")
        XCTAssertEqual(vm.lastMentionedBotIDForTesting, quinn.id)
        XCTAssertNil(reply, "no provider is wired in this harness, so the peer run cannot finish")
        XCTAssertEqual(vm.selectedBotID, piper.id)
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

    func test_beginCreateSeedsStandingInstructions_becauseHermesDoesNotStartSoulless() throws {
        // WHY: Live Studio/Desk New Agent compiled with "No standing
        // instructions." Hermes seeds SOUL.md; we persist the starter so
        // first chat and Studio both show a replaceable default.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.beginCreate()
        let bot = try XCTUnwrap(try context.botStore.list().first)
        let revision = try XCTUnwrap(
            bot.currentRevisionID.flatMap { try context.botStore.getRevision(id: $0) }
        )
        XCTAssertTrue(BotStandingInstructions.looksGenerated(revision.soul))
        XCTAssertTrue(revision.soul.contains(BotStandingInstructions.generatedSignature))
        XCTAssertFalse(revision.soul.contains(BotStandingInstructions.rememberFactTool), "tools layer owns remember")
        XCTAssertFalse(revision.soul.contains(BotStandingInstructions.openBrowserTool), "tools layer owns browser")
        let preview = try XCTUnwrap(vm.previewBrain(userText: "Remember this"))
        XCTAssertTrue(preview.compiledPayload.contains(BotStandingInstructions.admittedToolsText))
        XCTAssertTrue(preview.compiledPayload.contains(BotStandingInstructions.getBrowserTool))
        vm.beginEdit(bot)
        XCTAssertEqual(vm.studioDraft.soul, revision.soul)
        vm.studioDraft.title = "Reviews PRs"
        vm.refreshGeneratedStandingInstructions()
        XCTAssertTrue(vm.studioDraft.soul.contains(BotStandingInstructions.generatedSignature))
        XCTAssertFalse(vm.studioDraft.soul.contains(BotStandingInstructions.changeJobTool), "tools layer owns job tool")
        XCTAssertFalse(vm.studioDraft.soul.contains("You are"), "Role must not rewrite identity into Instructions")
        vm.studioDraft.soul = "Speak plainly."
        vm.studioDraft.title = "Other job"
        vm.refreshGeneratedStandingInstructions()
        XCTAssertEqual(vm.studioDraft.soul, "Speak plainly.", "custom soul is the expert escape hatch")
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
        XCTAssertTrue(
            source.contains("BotRoute.fallbackOrderHonesty") || source.contains("not shipped in P1a"),
            "Studio must keep the P1a fallback-order honesty on the routing panel"
        )
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

    func test_reopeningDeskDoesNotRefetchRosterRevisions_becauseDestMustNotRereadEveryChip() throws {
        // WHY: dest paint called getRevision for every roster chip on every
        // click. Revisions are immutable by id; warm dest must reuse them.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .grok)
        vm.openDesk(piper)
        for bot in vm.fleet {
            _ = vm.providerLabel(for: bot)
            _ = vm.modelLabel(for: bot)
        }
        let afterFirstPaint = vm.rosterRevisionFetchCountForTesting
        XCTAssertGreaterThan(afterFirstPaint, 0, "first dest paint must read revisions once")
        XCTAssertEqual(vm.providerLabel(for: piper), "Claude")
        XCTAssertEqual(vm.providerLabel(for: quinn), "Grok")
        vm.openDesk(quinn)
        for bot in vm.fleet {
            _ = vm.providerLabel(for: bot)
            _ = vm.modelLabel(for: bot)
        }
        XCTAssertEqual(
            vm.rosterRevisionFetchCountForTesting,
            afterFirstPaint,
            "switching dest must not reread every teammate revision"
        )
        vm.openDesk(piper)
        for bot in vm.fleet {
            _ = vm.providerLabel(for: bot)
            _ = vm.modelLabel(for: bot)
        }
        XCTAssertEqual(vm.rosterRevisionFetchCountForTesting, afterFirstPaint)
    }

    func test_saveStudioRefetchesRevision_becauseStaleProviderChipMustNotLookCurrent() throws {
        // WHY: cache-first chips are honest only when Save Bot still
        // replaces the published route the roster would show.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .grok)
        vm.openDesk(bot)
        XCTAssertEqual(vm.providerLabel(for: bot), "Grok")
        let afterOpen = vm.rosterRevisionFetchCountForTesting
        vm.beginEdit(bot)
        vm.studioDraft.provider = .claude
        vm.applyDefaultModel(for: .claude)
        _ = try vm.saveStudio()
        let saved = try XCTUnwrap(vm.selectedBot)
        XCTAssertEqual(vm.providerLabel(for: saved), "Claude")
        XCTAssertEqual(vm.selectedRevision?.provider, .claude)
        XCTAssertEqual(
            vm.rosterRevisionFetchCountForTesting,
            afterOpen,
            "Save dest must not reread the revision it just published"
        )
    }

    func test_reopeningDeskDoesNotRereadMarkRead_becauseRosterSwitchMustNotListConversations() throws {
        // WHY: openDesk listed conversations and attention on every roster
        // click even when that teammate was already read. Warm dest must
        // skip the store; first dest still marks unread.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        let afterPiper = vm.deskMarkReadStoreCountForTesting
        XCTAssertGreaterThan(afterPiper, 0, "first Desk open must mark-read from the store")
        vm.openDesk(quinn)
        let afterQuinn = vm.deskMarkReadStoreCountForTesting
        XCTAssertEqual(afterQuinn, afterPiper + 1, "first Quinn dest must mark-read from the store")
        vm.openDesk(piper)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(
            vm.deskMarkReadStoreCountForTesting,
            afterQuinn,
            "reopening a read Piper must not list conversations again"
        )
    }

    func test_openDeskDoesNotListInbox_becauseMarkReadDestMustNotRereadQueue() throws {
        // WHY: Mark-read dest used to listAttention after dest already
        // dested Chat. Dest already has dest inbox.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        let piperConversation = BotConversation(botID: piper.id, title: "From Piper")
        try context.botStore.upsertConversation(piperConversation)
        vm.openDesk(quinn)
        vm.applyFollowThroughForTests(bot: piper, conversation: piperConversation, status: .completed)
        let afterDest = vm.attentionListCountForTesting
        XCTAssertGreaterThan(afterDest, 0)
        vm.openDesk(piper)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(
            vm.attentionListCountForTesting,
            afterDest,
            "mark-read dest must not reread the inbox"
        )
        XCTAssertEqual(vm.attentionState(for: piper), .none)
    }

    func test_openDeskStillMarksUnread_becauseStaleUnreadMustNotLookCurrent() throws {
        // WHY: cache-first dest is honest only when a completed turn on a
        // background teammate still clears unread when that Desk opens.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        let piperConversation = BotConversation(botID: piper.id, title: "From Piper")
        try context.botStore.upsertConversation(piperConversation)
        vm.openDesk(quinn)
        let afterSwitch = vm.deskMarkReadStoreCountForTesting
        vm.applyFollowThroughForTests(bot: piper, conversation: piperConversation, status: .completed)
        XCTAssertEqual(vm.attentionState(for: piper), .unreadActivity)
        vm.openDesk(piper)
        XCTAssertEqual(
            vm.deskMarkReadStoreCountForTesting,
            afterSwitch + 1,
            "dest must reread mark-read when unread arrived in the background"
        )
        XCTAssertEqual(vm.attentionState(for: piper), .none)
        XCTAssertFalse(try XCTUnwrap(context.botStore.listConversations(botID: piper.id).first).unread)
    }

    func test_openDeskDoesNotReloadFleet_becauseRosterSwitchMustNotScanEveryTeammate() throws {
        // WHY: openDesk used to reloadFleet (every teammate's conversations
        // and recent messages) before Chat could paint. Mark-read is this
        // bot only; hide/pin/delete still reload the fleet.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        let afterCreate = vm.fleetReloadCountForTesting
        XCTAssertGreaterThan(afterCreate, 0)
        vm.openDesk(piper)
        XCTAssertEqual(
            vm.fleetReloadCountForTesting,
            afterCreate,
            "opening Piper must not rescan the fleet"
        )
        vm.openDesk(quinn)
        XCTAssertEqual(
            vm.fleetReloadCountForTesting,
            afterCreate,
            "switching to Quinn must not rescan the fleet"
        )
        XCTAssertEqual(vm.selectedBotID, quinn.id)
        XCTAssertEqual(vm.screen, .desk)
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
        XCTAssertTrue(prompt.contains("Role: Scout"))
        XCTAssertFalse(prompt.contains("You are Piper (@piper) — Scout"))
        XCTAssertTrue(prompt.contains("Instructions:"))
        XCTAssertFalse(prompt.contains("Standing instructions:"))
        XCTAssertTrue(prompt.contains("Skills: weekly-account-health"))
        XCTAssertFalse(prompt.contains("Enabled skills"))
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
            skills: vm.skillBindings,
            workspace: vm.advertisedWorkspace
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

    func test_sendDoesNotListInbox_becauseNeedsYouDestMustNotRereadQueue() throws {
        // WHY: Needs-you dest used to listAttention after dest already
        // painted the bubble. Dest already has this inbox row.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        let afterDest = vm.attentionListCountForTesting
        XCTAssertGreaterThan(afterDest, 0)
        XCTAssertTrue(vm.send("Please look at the failing test"))
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.deskMessages.first?.text, "Please look at the failing test")
        XCTAssertEqual(
            vm.attentionListCountForTesting,
            afterDest,
            "needs-you dest must not reread the inbox"
        )
    }

    func test_sendKeepsNeedsYouInbox_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first needs-you is honest only when dest still
        // shows this inbox row after the store write.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Please look at the failing test"))
        XCTAssertEqual(vm.openAttentionCount, 1)
        XCTAssertEqual(vm.attentionItems.first?.title, "Needs you")
        XCTAssertEqual(vm.attentionItems.first?.detail, "Please look at the failing test")
        XCTAssertEqual(try context.botStore.listAttention().count, 1)
        XCTAssertEqual(vm.deskMessages.last?.text, BotsViewModel.assistantPlaceholder)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
    }

    func test_sendDoesNotListMemoryOrSkills_becauseSendDestMustNotRereadBrain() throws {
        // WHY: Send dest used to listMemory/listSkillBindings after dest
        // painted the bubble. Dest already has this teammate's brain.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.memoryDraft = "Prefers dark mode"
        vm.addMemory()
        vm.skillDraft = "weekly-account-health"
        vm.addSkill()
        let afterDest = vm.memoryListCountForTesting
        let afterSkills = vm.skillListCountForTesting
        XCTAssertGreaterThan(afterDest, 0)
        XCTAssertGreaterThan(afterSkills, 0)
        XCTAssertTrue(vm.send("Summarize overnight"))
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.deskMessages.first?.text, "Summarize overnight")
        XCTAssertTrue(vm.lastSendUsedDestBrainForTesting)
        XCTAssertEqual(
            vm.memoryListCountForTesting,
            afterDest,
            "send dest must not reread memory"
        )
        XCTAssertEqual(
            vm.skillListCountForTesting,
            afterSkills,
            "send dest must not reread skills"
        )
    }

    func test_sendAssemblesFromDestCache_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first send is honest only when dest facts compile
        // into the same payload preview already showed.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.memoryDraft = "Prefers dark mode"
        vm.addMemory()
        vm.composerText = "Summarize overnight"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(preview.compiledPayload.contains("Prefers dark mode"))
        XCTAssertTrue(vm.send("Summarize overnight"))
        XCTAssertTrue(vm.lastSendUsedDestBrainForTesting)
        XCTAssertEqual(vm.deskMessages.first?.text, "Summarize overnight")
        XCTAssertEqual(
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "Summarize overnight",
                memory: vm.memoryItems,
                skills: vm.skillBindings,
                workspace: vm.advertisedWorkspace
            ),
            preview.compiledPayload
        )
    }

    func test_sendDoesNotListConversations_becausePersistDestMustNotRereadThreads() throws {
        // WHY: Persist dest used to listConversations after dest painted
        // the bubble. Dest already has this teammate's thread.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        let afterDest = vm.conversationListCountForTesting
        XCTAssertGreaterThan(afterDest, 0)
        XCTAssertTrue(vm.send("Summarize overnight"))
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.deskMessages.first?.text, "Summarize overnight")
        XCTAssertEqual(vm.selectedConversation?.botID, piper.id)
        XCTAssertEqual(
            vm.conversationListCountForTesting,
            afterDest,
            "persist dest must not reread every thread"
        )
    }

    func test_sendKeepsDestConversation_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first persist is honest only when dest still shows
        // this teammate's thread after the store write.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("First brief"))
        let thread = try XCTUnwrap(vm.selectedConversation)
        let afterFirst = vm.conversationListCountForTesting
        XCTAssertTrue(vm.send("Second brief"))
        XCTAssertEqual(vm.selectedConversation?.id, thread.id)
        XCTAssertEqual(vm.conversations.map(\.id), [thread.id])
        XCTAssertEqual(vm.deskMessages.first?.text, "First brief")
        XCTAssertTrue(vm.deskMessages.contains(where: { $0.text == "Second brief" }))
        XCTAssertEqual(vm.conversationListCountForTesting, afterFirst)
        XCTAssertEqual(vm.screen, .desk)
    }

    func test_followThroughDoesNotReloadFleet_becauseSettleDestMustNotScanEveryTeammate() throws {
        // WHY: Follow-through dest used to reloadFleet (every teammate's
        // conversations + recent messages) after dest already painted the
        // completed turn. Dest already has this thread.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("From Piper"))
        let conversation = try XCTUnwrap(vm.selectedConversation)
        XCTAssertEqual(conversation.botID, piper.id)
        XCTAssertEqual(vm.fleet.map(\.name).sorted(), ["Piper", "Quinn"])
        let afterDest = vm.fleetReloadCountForTesting
        XCTAssertGreaterThan(afterDest, 0)
        vm.applyFollowThroughForTests(bot: piper, conversation: conversation, status: .completed)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.selectedConversation?.id, conversation.id)
        XCTAssertEqual(vm.selectedConversation?.botID, piper.id)
        XCTAssertEqual(
            vm.fleetReloadCountForTesting,
            afterDest,
            "settle dest must not scan every teammate"
        )
        XCTAssertEqual(vm.fleet.map(\.name).sorted(), ["Piper", "Quinn"])
    }

    func test_followThroughKeepsDestConversation_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first settle is honest only when dest still shows
        // this teammate's thread, and a background teammate's store
        // row stays the dest thread dest already wrote.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("First brief"))
        let destThread = try XCTUnwrap(vm.selectedConversation)
        XCTAssertEqual(destThread.botID, piper.id)
        vm.openDesk(quinn)
        let afterSwitch = vm.fleetReloadCountForTesting
        vm.applyFollowThroughForTests(bot: piper, conversation: destThread, status: .completed)
        XCTAssertEqual(vm.selectedBotID, quinn.id)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertNotEqual(vm.selectedConversation?.botID, piper.id)
        XCTAssertTrue(
            try context.botStore.listConversations(botID: piper.id)
                .contains(where: { $0.id == destThread.id }),
            "dest-first settle must keep the dest thread dest already wrote"
        )
        XCTAssertEqual(
            vm.fleetReloadCountForTesting,
            afterSwitch,
            "background settle dest must not scan every teammate"
        )
    }

    func test_followThroughDoesNotListConversations_becauseSettleDestMustNotRereadThreads() throws {
        // WHY: Settle dest used to listConversations after dest already
        // dested Chat — including when dest dested another teammate.
        // Dest already has this thread from persist dest.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("From Piper"))
        let destThread = try XCTUnwrap(vm.selectedConversation)
        XCTAssertEqual(destThread.botID, piper.id)
        vm.openDesk(quinn)
        let afterDest = vm.conversationListCountForTesting
        XCTAssertGreaterThan(afterDest, 0)
        vm.applyFollowThroughForTests(bot: piper, conversation: destThread, status: .completed)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, quinn.id)
        XCTAssertNotEqual(vm.selectedConversation?.botID, piper.id)
        XCTAssertEqual(
            vm.conversationListCountForTesting,
            afterDest,
            "settle dest must not reread dest threads"
        )
        XCTAssertTrue(
            try context.botStore.listConversations(botID: piper.id)
                .contains(where: { $0.id == destThread.id })
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

    func test_addSkillRejectsPathWithStudioCopy_becauseStoreErrorMustNotReachTheUser() throws {
        // WHY: BotStore already rejects "/", but Add showed "Invalid bot row: …"
        // instead of the Studio caption the tab already paints.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.skillDraft = "/tmp/not-a-skill.md"
        vm.addSkill()
        XCTAssertEqual(
            vm.errorMessage,
            "Catalog ids only. A skill id is not a filesystem path."
        )
        XCTAssertTrue(vm.skillBindings.isEmpty)
        XCTAssertEqual(vm.skillDraft, "/tmp/not-a-skill.md")
        XCTAssertTrue(try context.botStore.listSkillBindings(botID: bot.id).isEmpty)
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

    func test_addSkillDoesNotListSkills_becauseAddDestMustNotRereadBindings() throws {
        // WHY: Add dest used to listSkillBindings after the store wrote
        // this binding. Dest must not reread every skill.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(piper)
        let afterStudio = vm.skillListCountForTesting
        XCTAssertGreaterThan(afterStudio, 0)
        vm.skillDraft = "weekly-account-health"
        vm.addSkill()
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.skillBindings.first?.skillID, "weekly-account-health")
        XCTAssertTrue(try XCTUnwrap(vm.skillBindings.first).enabled)
        XCTAssertTrue(vm.skillDraft.isEmpty)
        XCTAssertEqual(vm.enabledSkillCount, 1)
        XCTAssertEqual(
            vm.skillListCountForTesting,
            afterStudio,
            "add dest must not reread every skill"
        )
        XCTAssertEqual(
            try context.botStore.listSkillBindings(botID: piper.id).map(\.skillID),
            ["weekly-account-health"]
        )
    }

    func test_addSkillKeepsExistingSkills_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first add is honest only when older bindings stay
        // visible and the new row paints first.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        try context.botStore.setSkillBinding(
            BotSkillBinding(botID: piper.id, skillID: "older-skill", enabled: true)
        )
        vm.beginEdit(piper)
        XCTAssertEqual(vm.skillBindings.map(\.skillID), ["older-skill"])
        let afterStudio = vm.skillListCountForTesting
        vm.skillDraft = "newer-skill"
        vm.addSkill()
        XCTAssertEqual(vm.skillBindings.first?.skillID, "newer-skill")
        XCTAssertEqual(
            Set(vm.skillBindings.map(\.skillID)),
            Set(["newer-skill", "older-skill"])
        )
        XCTAssertTrue(try XCTUnwrap(vm.skillBindings.first { $0.skillID == "older-skill" }).enabled)
        XCTAssertEqual(vm.skillListCountForTesting, afterStudio)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertTrue(vm.skillDraft.isEmpty)
    }

    func test_setSkillEnabledDoesNotListSkills_becauseEnableDestMustNotRereadBindings() throws {
        // WHY: Enable dest used to listSkillBindings after the store wrote
        // this binding. Dest must not reread every skill.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(piper)
        vm.skillDraft = "weekly-account-health"
        vm.addSkill()
        XCTAssertTrue(try XCTUnwrap(vm.skillBindings.first).enabled)
        let afterAdd = vm.skillListCountForTesting
        XCTAssertGreaterThan(afterAdd, 0)
        vm.setSkillEnabled(skillID: "weekly-account-health", enabled: false)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.skillBindings.first?.skillID, "weekly-account-health")
        XCTAssertFalse(try XCTUnwrap(vm.skillBindings.first).enabled)
        XCTAssertEqual(vm.enabledSkillCount, 0)
        XCTAssertEqual(
            vm.skillListCountForTesting,
            afterAdd,
            "enable dest must not reread every skill"
        )
        XCTAssertEqual(
            try context.botStore.listSkillBindings(botID: piper.id).first?.enabled,
            false
        )
    }

    func test_setSkillEnabledKeepsExistingSkills_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first enable is honest only when older bindings stay
        // visible and only this row flips On/Off.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        try context.botStore.setSkillBinding(
            BotSkillBinding(botID: piper.id, skillID: "older-skill", enabled: true)
        )
        vm.beginEdit(piper)
        vm.skillDraft = "newer-skill"
        vm.addSkill()
        let afterAdd = vm.skillListCountForTesting
        vm.setSkillEnabled(skillID: "newer-skill", enabled: false)
        XCTAssertEqual(
            Set(vm.skillBindings.map(\.skillID)),
            Set(["newer-skill", "older-skill"])
        )
        XCTAssertFalse(try XCTUnwrap(vm.skillBindings.first { $0.skillID == "newer-skill" }).enabled)
        XCTAssertTrue(try XCTUnwrap(vm.skillBindings.first { $0.skillID == "older-skill" }).enabled)
        XCTAssertEqual(vm.enabledSkillCount, 1)
        XCTAssertEqual(vm.skillListCountForTesting, afterAdd)
        vm.setSkillEnabled(skillID: "newer-skill", enabled: true)
        XCTAssertTrue(try XCTUnwrap(vm.skillBindings.first { $0.skillID == "newer-skill" }).enabled)
        XCTAssertEqual(vm.enabledSkillCount, 2)
        XCTAssertEqual(vm.skillListCountForTesting, afterAdd)
        XCTAssertEqual(vm.screen, .studio)
    }

    func test_studioSkillToggleHidesTitle_becauseRowCaptionAlreadySaysOff() throws {
        // WHY: After Remove landed, the Skills row painted Off as a caption
        // and again as the Toggle title next to the switch. Hide the title;
        // keep the caption and VoiceOver name.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private var skillsTab") else {
            return XCTFail("skillsTab must exist")
        }
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\n    private func memoryRow")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertTrue(slice.contains("Toggle(binding.enabled ? \"On\" : \"Off\""))
        XCTAssertTrue(
            slice.contains(".labelsHidden()"),
            "Skills Off/On must not paint twice beside Remove"
        )
        XCTAssertTrue(slice.contains("Text(binding.enabled ? \"On\" : \"Off\")"))
    }

    func test_removeSkillDoesNotListSkills_becauseRemoveDestMustNotRereadBindings() throws {
        // WHY: Remove dest must drop the row without listing every skill,
        // or the Skills tab looks current only after a reread.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(piper)
        vm.skillDraft = "weekly-account-health"
        vm.addSkill()
        let afterAdd = vm.skillListCountForTesting
        vm.removeSkill(skillID: "weekly-account-health")
        XCTAssertTrue(vm.skillBindings.isEmpty)
        XCTAssertEqual(vm.enabledSkillCount, 0)
        XCTAssertEqual(
            vm.skillListCountForTesting,
            afterAdd,
            "remove dest must not reread every skill"
        )
        XCTAssertTrue(try context.botStore.listSkillBindings(botID: piper.id).isEmpty)
    }

    func test_removeSkillKeepsExistingSkills_becauseStaleEmptyMustNotLookCurrent() throws {
        // WHY: dest-first remove is honest only when the other bindings stay
        // visible after this catalog id leaves the list.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        try context.botStore.setSkillBinding(
            BotSkillBinding(botID: piper.id, skillID: "keep-me", enabled: true)
        )
        vm.beginEdit(piper)
        vm.skillDraft = "drop-me"
        vm.addSkill()
        let afterAdd = vm.skillListCountForTesting
        vm.removeSkill(skillID: "drop-me")
        XCTAssertEqual(vm.skillBindings.map(\.skillID), ["keep-me"])
        XCTAssertTrue(try XCTUnwrap(vm.skillBindings.first).enabled)
        XCTAssertEqual(vm.skillListCountForTesting, afterAdd)
        XCTAssertEqual(
            try context.botStore.listSkillBindings(botID: piper.id).map(\.skillID),
            ["keep-me"]
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
        XCTAssertFalse(vm.studioHasUnpublishedChanges)
    }

    func test_leftoverStudioDraftDesktopDoesNotKeepDraftPill_becauseDedicatedLocalVMIsNotAdvertised() throws {
        // WHY: Persist used to keep dedicatedLocalVM on the draft after Save
        // published logical space, so Studio showed Draft with no user edit.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.studioDraft.desktopKind = .dedicatedLocalVM
        XCTAssertFalse(vm.studioHasUnpublishedChanges)
        _ = try vm.saveStudio()
        XCTAssertEqual(vm.studioDraft.desktopKind, .logicalExecutionSpace)
        XCTAssertFalse(vm.studioHasUnpublishedChanges)

        let reopened = BotsViewModel(context: context)
        reopened.openStudio(bot)
        XCTAssertEqual(reopened.studioDraft.desktopKind, .logicalExecutionSpace)
        XCTAssertFalse(reopened.studioHasUnpublishedChanges)
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

    func test_memoryTabHeaderSaysMemory_becauseMemoryMustNotNameTheBrainSiblingTab() throws {
        // WHY: Brain and Memory are sibling Studio tabs and the tab strip
        // already says Memory. A "Brain / Memory" body header is leftover
        // from before the split and claims Memory lives under Brain.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertFalse(
            source.contains("Brain / Memory"),
            "Memory's header must not name the Brain sibling tab"
        )
        guard let start = source.range(of: "private var memoryTab") else {
            return XCTFail("memory tab must exist")
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private var ")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertTrue(
            slice.contains("studioSectionHeader(BotsChrome.Label.memory)"),
            "Memory keeps a section title like every sibling Studio tab, titled by the shared chrome token"
        )
    }

    func test_studioProviderPickerHidesTitle_becauseDefaultRouteAlreadyLabelsTheRow() throws {
        // WHY: The Profile row is already "Default route". A visible
        // Picker title "Provider" looks like leftover chrome beside
        // Claude/Codex/Grok. Scheduled Tasks already hides the same title.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private var studioProvider") else {
            return XCTFail("studioProvider must exist")
        }
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\n    private var studioSoul")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertTrue(slice.contains("Picker(\"Provider\""))
        XCTAssertTrue(
            slice.contains(".labelsHidden()"),
            "Default route already names the row; Provider must not paint beside the segments"
        )
    }

    func test_avatarSymbolNameIsHuman_becauseStudioMustNotAnnounceSFSymbolPaths() {
        XCTAssertEqual(
            BotsChrome.avatarSymbolName("person.crop.circle"),
            "Person",
            "VoiceOver on a leftover SF chip must say Person, not person.crop.circle"
        )
        XCTAssertEqual(
            BotsChrome.avatarSymbolName("blobatar:v1:cloud:idle:none:auto"),
            "Cloud",
            "VoiceOver on a blobatar must say Cloud, not the token"
        )
        for symbol in BotsChrome.avatarSymbols {
            XCTAssertFalse(
                BotsChrome.avatarSymbolName(symbol).contains("."),
                "\(symbol) must not leak an SF Symbol path into the Avatar name"
            )
        }
    }

    func test_studioAvatarPickerIsBlobatar_becauseStudioLetsTheUserComposeTheCreature() throws {
        // WHY: Studio Avatar used to be eight SF chips. The owner now
        // composes shape / expression / background / hue, matching the
        // blobatar editor. A leftover symbol row would hide that.
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let editor = try String(contentsOf: sourceURL("Sources/AppShell/BotsBlobatarView.swift"), encoding: .utf8)
        XCTAssertTrue(bots.contains("BotBlobatarEditor"))
        XCTAssertTrue(bots.contains("BotBlobatarSpec.default.token"))
        XCTAssertTrue(editor.contains("bots.studio.avatar.shape"))
        XCTAssertTrue(editor.contains("bots.studio.avatar.expression"))
        XCTAssertTrue(editor.contains("bots.studio.avatar.background"))
        XCTAssertTrue(editor.contains("bots.studio.avatar.hue"))
        XCTAssertTrue(editor.contains("BotBlobatarShape.allCases"))
        XCTAssertTrue(editor.contains("bots.studio.avatar.shape.\\(shape.rawValue)"))
        XCTAssertFalse(
            bots.contains("studioField(placeholder: \"person.crop.circle\""),
            "users must not type person.crop.circle to set an Avatar"
        )
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
        XCTAssertTrue(
            sidebar.contains("attachDeleteConfirmation: true"),
            "sidebar roster is a sibling hosting view; Delete must attach confirm here"
        )
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
        XCTAssertFalse(
            bots.contains("bots.studio.tab.desktop"),
            "Desktop merged into the Security tab; a seventh tab must not come back"
        )
        XCTAssertTrue(bots.contains("bots.studio.tab.security"))
        XCTAssertTrue(
            bots.contains("bots.studio.desktop"),
            "the read-only Desktop card still ships inside the Security tab"
        )
        XCTAssertTrue(bots.contains("bots.chrome.agentic"))
        XCTAssertFalse(bots.contains("bots.home.goal"))
        XCTAssertTrue(bots.contains("accessibilityAddTraits(selected ? .isSelected : [])"))
        XCTAssertTrue(bots.contains("BotsChrome.hitTarget"))
        XCTAssertEqual(BotStudioTab.allCases.map(\.id), ["profile", "brain", "memory", "skills", "routines", "security"])
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
        XCTAssertTrue(bots.contains("Empty uses the built-in teammate default"))
        XCTAssertTrue(bots.contains("refreshGeneratedStandingInstructions"))
        XCTAssertTrue(
            bots.contains(".accessibilityLabel(BotsChrome.Label.instructions)"),
            "Soul TextArea must name Instructions the way Description names Description"
        )
        XCTAssertTrue(
            bots.contains("studioMultiline(text: $vm.memoryDraft, minHeight: 56, maxHeight: 72)"),
            "Studio Memory still uses the unlabeled multiline path"
        )
        XCTAssertTrue(
            bots.contains(".accessibilityLabel(\"Remember a fact\")"),
            "Studio Memory TextArea must name the fact field the way Desk inspector does"
        )
        XCTAssertTrue(
            bots.contains("bots.memory.correct.field"),
            "Correct memory edits inline; the editing field must be identifiable"
        )
        XCTAssertFalse(
            bots.contains("NSAlert()"),
            "Correct memory must edit inline, not through a modal alert"
        )
        XCTAssertTrue(
            bots.contains("studioField(placeholder: \"Remember a fact\", text: $vm.memoryDraft)"),
            "Desk inspector Memory still uses studioField"
        )
        XCTAssertGreaterThanOrEqual(
            bots.components(separatedBy: ".accessibilityLabel(\"Remember a fact\")").count - 1,
            2,
            "Desk inspector Memory field must be named Remember a fact, not sit unlabeled"
        )
        XCTAssertTrue(
            bots.contains(".accessibilityLabel(\"Skill catalog id\")"),
            "Studio Skills field must name the catalog id, not sit unlabeled beside Add"
        )
        XCTAssertTrue(
            bots.contains(".accessibilityLabel(binding.skillID)"),
            "Studio Skills enable switch must name the catalog id, not sit unlabeled beside On"
        )
        XCTAssertTrue(
            bots.contains(".accessibilityLabel(routine.definition.name)"),
            "Routines Active switch must name the routine, not sit unlabeled beside Active"
        )
        XCTAssertTrue(
            bots.contains(
                """
                Text(label)
                                .font(DS.Font.caption.weight(.medium))
                                .foregroundColor(DS.Palette.textSecondary)
                                .accessibilityHidden(true)
                            content()
                                .accessibilityLabel(label)
                """
            ),
            "labeledField must name the control the way studioFormRow does"
        )
        XCTAssertTrue(bots.contains("bots.studio.summary"))
        XCTAssertTrue(bots.contains("bots.studio.desktop.honesty"))
        XCTAssertTrue(
            bots.contains("BotsChrome.Label.roleAndIdentity") || chrome.contains("Role & Identity"),
            "Studio Profile header must use the Role & Identity token"
        )
        XCTAssertTrue(
            bots.contains("BotsChrome.Label.providerRouting") || chrome.contains("Provider routing"),
            "Studio routing header must use the Provider routing token"
        )
        XCTAssertTrue(
            bots.contains("BotsChrome.Label.configurationSummary") || chrome.contains("Configuration summary"),
            "Studio summary header must use the Configuration summary token"
        )
        XCTAssertTrue(bots.contains("AgentChatUserBubble"))
        XCTAssertTrue(bots.contains("AgentChatAssistantReply"))
        XCTAssertTrue(bots.contains("AgentChatComposerBar"))
        XCTAssertTrue(
            bots.contains("placeholder: \"Message \\(bot.name)…\""),
            "Desk composer must invite messaging the teammate, not Ask Claude for changes"
        )
        XCTAssertFalse(
            bots.contains("AgentChatTranscriptChrome.composerPlaceholder("),
            "Bots Desk must not reuse the Agent App Ask <provider> for changes placeholder"
        )
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
        XCTAssertTrue(
            bots.contains(".accessibilityElement(children: .ignore)"),
            "Desk desktop pane must be one VoiceOver name, not the honesty line four times"
        )
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
        XCTAssertTrue(bots.contains("bots.studio.skills.remove"))
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
        XCTAssertTrue(
            bots.contains("BotBlobatarEditor"),
            "Studio Avatar is the blobatar composer, not a leftover SF chip row"
        )
        XCTAssertFalse(
            bots.contains("studioField(placeholder: \"person.crop.circle\""),
            "users must not type person.crop.circle to set an Avatar"
        )

        let scheduleTasks = try XCTUnwrap(sidebar.range(of: "accessibilityIdentifier(\"sidebar.scheduleTasks\")"))
        let reportBug = try XCTUnwrap(sidebar.range(of: "accessibilityIdentifier(\"sidebar.reportBug\")"))
        XCTAssertLessThan(reportBug.lowerBound, scheduleTasks.lowerBound,
                          "Report Bug is a header icon, not a dest row under Schedule Tasks")
        XCTAssertTrue(
            sidebar.contains("BotsModeSwitcher"),
            "Bots is entered from the Agentic/Bots switcher, not a dest row"
        )
    }

    func test_botsRosterMenusMatchAgentic_becauseBotsChromeMirrorsWorkspaceActions() throws {
        // WHY: Bots used a New Bot + bell strip. Agentic is New Workspace,
        // Active Threads, Schedule Tasks. The Bots session must offer the
        // same three-row menu so the mode switch does not change chrome.
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let sidebar = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        let newBot = try XCTUnwrap(bots.range(of: "accessibilityIdentifier(\"bots.new\")"))
        let activeBots = try XCTUnwrap(bots.range(of: "accessibilityIdentifier(\"bots.active\")"))
        let scheduleTasks = try XCTUnwrap(bots.range(of: "accessibilityIdentifier(\"bots.scheduleTasks\")"))
        XCTAssertLessThan(newBot.lowerBound, activeBots.lowerBound)
        XCTAssertLessThan(activeBots.lowerBound, scheduleTasks.lowerBound)
        XCTAssertTrue(bots.contains("SidebarActionRow("),
                      "Bots action rows must reuse Agentic sidebar chrome")
        XCTAssertTrue(bots.contains("BotsChrome.Label.activeBots"))
        XCTAssertTrue(bots.contains("BotsChrome.Label.scheduleTasks"))
        XCTAssertTrue(sidebar.contains("onOpenScheduledTasks: onOpenScheduledTasks"),
                      "sidebar Bots roster must open the same Schedule Tasks dest")
        XCTAssertFalse(bots.contains("bots.roster.attention"),
                       "the attention bell is replaced by the Active Bots row")
    }

    func test_modeSwitcherSitsOnGlass_andBotSearchMatchesWorkspaceFilter() throws {
        // WHY: opaque surfaceRaised / surfaceOverlay on Agentic | Bots punches
        // a dark slab through the sidebar NSVisualEffectView. Search bots used
        // the 44pt Bots hit target and sat taller than Filter workspaces.
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let sidebar = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        guard let start = bots.range(of: "public struct BotsModeSwitcher") else {
            return XCTFail("BotsModeSwitcher must exist")
        }
        let rest = bots[start.lowerBound...]
        let end = rest.range(of: "\npublic struct BotsRosterList")?.lowerBound ?? rest.endIndex
        let switcher = String(bots[start.lowerBound..<end])

        XCTAssertFalse(
            switcher.contains("DS.Palette.surfaceRaised"),
            "mode switcher track must not paint an opaque raised slab on glass"
        )
        XCTAssertFalse(
            switcher.contains("DS.Palette.surfaceOverlay"),
            "selected segment must not use opaque surfaceOverlay on glass"
        )
        XCTAssertTrue(
            switcher.contains(".background(DS.Palette.hover)"),
            "mode switcher track must be a translucent hover wash so sidebar glass shows through"
        )
        XCTAssertTrue(
            switcher.contains("selected ? Color.white.opacity(0.12) : Color.clear"),
            "selected segment must be a frost wash, not a solid raised surface"
        )
        XCTAssertTrue(
            bots.contains("SidebarSearchField("),
            "Search bots must use the same SidebarSearchField as Filter workspaces"
        )
        XCTAssertTrue(
            sidebar.contains("SidebarSearchField("),
            "Filter workspaces must use the same SidebarSearchField as Search bots"
        )
        XCTAssertTrue(
            sidebar.contains("placeholder: \"Filter workspaces\""),
            "workspace filter keeps its own placeholder"
        )
        XCTAssertTrue(
            bots.contains("placeholder: BotsChrome.Label.search"),
            "bots filter keeps Search bots as the only copy difference"
        )
    }

    private struct SeededDeskTurn {
        let run: AgentRun
        let eventCount: Int
    }

    @discardableResult
    private func seedLinkedTurn(
        context: AppContext,
        bot: BotDefinition,
        extraReasoning: Int
    ) throws -> SeededDeskTurn {
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
        var events: [AssistantEvent] = [
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
        ]
        for index in 0..<extraReasoning {
            events.append(.itemDelta(
                itemId: "r-desk",
                bodyAppend: " chunk-\(index)",
                outputAppend: nil,
                summary: nil
            ))
        }
        events.append(contentsOf: [
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
        ])
        try persistStreamEvents(context: context, run: run, events: events)
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "Summarize overnight",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Summarize overnight", linkedAgentThreadID: thread.id)
        )
        return SeededDeskTurn(run: run, eventCount: events.count)
    }

    private func persistStreamEvents(
        context: AppContext,
        run: AgentRun,
        events: [AssistantEvent],
        startSeq: Int = 1
    ) throws {
        for (index, event) in events.enumerated() {
            let data = try JSONEncoder().encode(event)
            let json = try XCTUnwrap(String(data: data, encoding: .utf8))
            try context.runRepo.appendStreamEvent(
                runId: run.id,
                seq: startSeq + index,
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
