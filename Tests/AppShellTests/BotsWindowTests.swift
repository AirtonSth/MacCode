import XCTest
import SwiftUI
import CoreModel
import AgentRuntime
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
        UserDefaults.standard.removeObject(forKey: "bots.deskSidePaneWidth")
        UserDefaults.standard.removeObject(forKey: "bots.showHidden")
        UserDefaults.standard.removeObject(forKey: "bots.brainPane")
        UserDefaults.standard.removeObject(forKey: "bots.queuedFollowUps")
        UserDefaults.standard.removeObject(forKey: "bots.composerDrafts")
        UserDefaults.standard.removeObject(forKey: "bots.inspectorDrafts")
        UserDefaults.standard.removeObject(forKey: "bots.studioDraft")
        UserDefaults.standard.removeObject(forKey: "bots.searchText")
        UserDefaults.standard.removeObject(forKey: "bots.deskRouting")
        UserDefaults.standard.removeObject(forKey: "bots.peerTurns")
        UserDefaults.standard.removeObject(forKey: "bots.peerTurns.v2")
        UserDefaults.standard.removeObject(forKey: "bots.studioFilesLocations")
        UserDefaults.standard.removeObject(forKey: "bots.unpublishedNewBotIDs")
        UserDefaults.standard.removeObject(forKey: "bots.deskThreadRail")
        UserDefaults.standard.removeObject(forKey: "bots.deskThreadRailWidth")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "bots.studioFilesLocations")
        UserDefaults.standard.removeObject(forKey: "bots.peerTurns")
        UserDefaults.standard.removeObject(forKey: "bots.peerTurns.v2")
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

    func test_deskSendDoesNotRelistProviders_becauseAgentAppDoesNotProbeCatalogOnSend() async throws {
        // WHY: Agent App send uses the dest catalog already in memory.
        // Desk send used to listAgentProviderSnapshots inside preflight
        // (Grok ACP + Anthropic + Codex) before startRun — that is the
        // wait behind Loading….
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        context.coordinator.replaceProvider(
            .claude,
            runner: FakeProviderRunner(provider: .claude, scenario: .simpleAssistant(reply: "ok"))
        )
        let snapshot = AgentProviderSnapshotFactory.snapshot(
            provider: .claude,
            models: [AgentModelDescriptor(id: "opus", label: "Opus", provider: .claude)],
            binaryPath: "/usr/bin/true",
            authenticated: true,
            id: "claude"
        )
        router.rememberProviderSnapshotsForSend([snapshot])
        router.preflightListedProviderSnapshotsForTesting = false
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.setDeskProvider(.claude)
        let exp = expectation(description: "send preflight resolved from dest cache")
        router.sendAgentMessageAfterPreflightProbeForTesting = { exp.fulfill() }
        XCTAssertTrue(vm.send("oi"))
        await fulfillment(of: [exp], timeout: 5)
        XCTAssertFalse(
            router.preflightListedProviderSnapshotsForTesting,
            "send preflight must use the dest catalog, not rediscover models"
        )
        router.sendAgentMessageAfterPreflightProbeForTesting = nil
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

    func test_deskIdentityOpensStudio() throws {
        // WHY: The labeled Studio button competed with Chat. Identity and a
        // cog must dest to Studio; the inspector toggle stays last on the right.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.openStudio(bot)
        XCTAssertEqual(vm.screen, .studio)
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private func deskHeader") else {
            return XCTFail("desk header must exist")
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func deskChat")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertTrue(slice.contains("bots.desk.identity"))
        XCTAssertTrue(slice.contains("gearshape"))
        XCTAssertFalse(slice.contains("Button(\"Studio\")"))
        let studio = slice.range(of: "bots.desk.studio")?.lowerBound
        let toggle = slice.range(of: "bots.desk.inspectorToggle")?.lowerBound
        XCTAssertNotNil(studio)
        XCTAssertNotNil(toggle)
        XCTAssertLessThan(studio!, toggle!)
    }

    func test_deskSidePaneResizesLikeOtherPanels_becauseWidthMustNotStayCapped() throws {
        // WHY: Files and the shell sidebar drag with DSResizeDivider and
        // persist width. Desk inspector was a fixed 340–420 strip, so the
        // owner could not match those panels.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        XCTAssertEqual(vm.deskSidePaneWidth, BotsChrome.desktopPaneWidth)
        vm.resizeDeskSidePane(by: 80)
        XCTAssertEqual(vm.deskSidePaneWidth, 420)
        vm.resizeDeskSidePane(by: 400)
        XCTAssertEqual(vm.deskSidePaneWidth, BotsChrome.desktopPaneMaxWidth)
        vm.resizeDeskSidePane(by: -1000)
        XCTAssertEqual(vm.deskSidePaneWidth, BotsChrome.desktopPaneMinWidth)

        UserDefaults.standard.set(480.0, forKey: "bots.deskSidePaneWidth")
        let restored = BotsViewModel(context: context)
        XCTAssertEqual(restored.deskSidePaneWidth, 480)

        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private func deskChat") else {
            return XCTFail("desk chat must exist")
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func deskDesktopPane")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertTrue(slice.contains("DSResizeDivider"))
        XCTAssertTrue(slice.contains("Resize inspector"))
        XCTAssertTrue(slice.contains("resizeDeskSidePane(by: -delta)"))
        XCTAssertTrue(slice.contains(".frame(width: vm.deskSidePaneWidth)"))
        XCTAssertFalse(slice.contains("maxWidth: 420"))
    }

    func test_deskThreadRailResizesLikeAgentApp_becauseClearAllMustStayOneLine() throws {
        // WHY: dest dest dest dest fixed the rail at 220/320. Agent App
        // drags 320–360. dest dest dest dest must persist that range so
        // hide + Clear All + + stay on one line.
        XCTAssertEqual(BotsChrome.clampedThreadRailWidth(200), BotsChrome.threadRailMinWidth)
        XCTAssertEqual(BotsChrome.clampedThreadRailWidth(400), BotsChrome.threadRailMaxWidth)
        XCTAssertEqual(BotsChrome.clampedThreadRailWidth(340), 340)

        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        XCTAssertEqual(vm.deskThreadRailWidth, BotsChrome.threadRailWidth)
        vm.resizeDeskThreadRail(by: 40)
        XCTAssertEqual(vm.deskThreadRailWidth, 360)
        vm.resizeDeskThreadRail(by: 80)
        XCTAssertEqual(vm.deskThreadRailWidth, BotsChrome.threadRailMaxWidth)
        vm.resizeDeskThreadRail(by: -1000)
        XCTAssertEqual(vm.deskThreadRailWidth, BotsChrome.threadRailMinWidth)

        UserDefaults.standard.set(340.0, forKey: "bots.deskThreadRailWidth")
        let restored = BotsViewModel(context: context)
        XCTAssertEqual(restored.deskThreadRailWidth, 340)

        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private func deskChat") else {
            return XCTFail("desk chat must exist")
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func deskDesktopPane")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertTrue(slice.contains("Resize threads"))
        XCTAssertTrue(slice.contains("resizeDeskThreadRail(by: delta)"))
        XCTAssertTrue(slice.contains(".frame(width: vm.deskThreadRailWidth)"))
        XCTAssertFalse(slice.contains("BotsChrome.threadRailWidth)"))
    }

    func test_hiddenDeskThreadRailOmitsHeaderPlus_becauseNewThreadLivesOnTheRail() throws {
        // WHY: Agent App keeps a collapsed +. dest dest dest dest header
        // already has identity + Studio. Hide must only restore the rail.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private func deskHeader") else {
            return XCTFail("desk header must exist")
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func deskChat")?.lowerBound ?? rest.endIndex
        let header = String(source[start.lowerBound..<end])
        XCTAssertTrue(header.contains("bots.desk.thread.show"))
        XCTAssertFalse(header.contains("bots.desk.thread.new.collapsed"))
        XCTAssertFalse(header.contains("AgentChatThreadRailCopy.newHelp"))
    }

    func test_deskAlwaysDropsTitlebarInsetsInMainShell_becauseTheHeaderMustHugTheTrafficLightRow() throws {
        // WHY: the sidebar (open) or the 34pt restore bar (collapsed) owns
        // the traffic lights. Keeping the .top inset while the sidebar was
        // open parked the Ceo header a full titlebar below the traffic
        // lights — the vertical padding in the bug report. The edge set is
        // also state-independent so Desk stays still during the toggle.
        XCTAssertEqual(
            BotsViewModel.ignoredSafeAreaEdges(
                embedsRosterRail: false,
                presentsAsDetachedWindow: false
            ),
            [.top, .leading, .trailing],
            "main-shell Desk owns its whole pane: no titlebar strip, no traffic-light gutter"
        )
        XCTAssertEqual(
            BotsViewModel.deskIdentityLeadingPadding(shellSidebarCollapsed: false),
            BotsViewModel.deskIdentityLeadingPadding(shellSidebarCollapsed: true),
            "Ceo leading padding must match open and collapsed — the gutter is not padding"
        )
        XCTAssertTrue(
            BotsViewModel.cancelsWindowLeadingTitlebarGutter(presentsAsDetachedWindow: false),
            "main-shell Desk must drop the window traffic-light inset"
        )
        XCTAssertFalse(
            BotsViewModel.cancelsWindowLeadingTitlebarGutter(presentsAsDetachedWindow: true)
        )
        XCTAssertEqual(
            BotsViewModel.addedLeadingInsetBeyondIdentityPadding(
                windowTitlebarLeading: 78,
                presentsAsDetachedWindow: false
            ),
            0,
            "open sidebar must not still reserve the titlebar gutter on Desk"
        )
        XCTAssertEqual(
            BotsViewModel.addedLeadingInsetBeyondIdentityPadding(
                windowTitlebarLeading: 78,
                presentsAsDetachedWindow: true
            ),
            78
        )
        let main = try String(contentsOf: sourceURL("Sources/AppShell/MainWindowController.swift"), encoding: .utf8)
        XCTAssertTrue(
            main.contains("ContentColumnHostingView"),
            "NSHostingView must override safeAreaInsets — ignoresSafeArea alone leaves the gutter"
        )
        XCTAssertTrue(main.contains("cancelHorizontalTitlebarGutter"))
        XCTAssertTrue(
            BotsViewModel.ignoredSafeAreaEdges(
                embedsRosterRail: false,
                presentsAsDetachedWindow: true
            ).isEmpty,
            "a detached Desk window has its own titlebar and must keep its insets"
        )
        let context = try makeContext()
        try context.settingsRepo.set(MainWindowController.sidebarCollapsedSettingsKey, "1")
        let vm = BotsViewModel(context: context)
        XCTAssertTrue(vm.isShellSidebarCollapsed)
    }

    func test_deskHeaderIsToolbarSized_becauseTheShellTitlebarAlreadyWentAway() throws {
        // WHY: Removing the shell "Bots" bar left Desk in the titlebar
        // inset with title2 + xl padding. That read as a second titlebar.
        // Identity must sit in a 44pt chrome strip like a workspace row.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("ignoresSafeArea(.container, edges:"))
        guard let start = source.range(of: "private func deskHeader") else {
            return XCTFail("desk header must exist")
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func deskChat")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertTrue(slice.contains("DS.Font.bodyStrong"))
        XCTAssertTrue(slice.contains("size: 22"))
        XCTAssertTrue(slice.contains(".frame(height: 44)"))
        XCTAssertTrue(
            slice.contains("deskIdentityLeadingPadding"),
            "Desk identity must use the shared leading padding, not a sidebar-open gutter"
        )
        XCTAssertFalse(slice.contains("DS.Font.title2"))
        XCTAssertFalse(slice.contains("padding(.vertical, DS.Space.xl)"))
    }

    func test_deskThreadRowsMatchAgentAppRail_becauseTheDeskMustNotForkTheChrome() throws {
        // WHY: the Desk rail read as a different app — no provider
        // monogram, a time-only subtitle, no resting status dot. Desk and
        // Agent App mount the same AgentChatThreadRow, so the row inputs
        // must stay the Agent App ones (bug report: "deveria ser
        // exatamente igual ao do agent app").
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private func deskThreadRow") else {
            return XCTFail("desk thread row must exist")
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private var deskQueuedFollowUps")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertTrue(slice.contains("AgentThreadProviderMonogram(provider:"),
                      "desk rows need the same provider monogram chip as the Agent App rail")
        XCTAssertTrue(slice.contains("AgentThreadRailRowCopy.subtitle"),
                      "desk rows need the provider · model · time subtitle, not time alone")
        XCTAssertTrue(slice.contains("pin.fill"))
        XCTAssertTrue(slice.contains("circle.fill"),
                      "resting rows show the same neutral dot as the Agent App rail")
        XCTAssertTrue(slice.contains("AgentThreadTitle.display"))
        XCTAssertFalse(slice.contains("AgentChatTranscriptChrome.relativeTimestamp"),
                       "the time-only subtitle was the fork")
        let agent = try String(contentsOf: sourceURL("Sources/Surfaces/AgentAppSurface.swift"), encoding: .utf8)
        XCTAssertTrue(agent.contains("AgentThreadProviderMonogram(provider: t.provider)"),
                      "Agent App must mount the shared monogram, not an inline copy")

        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let conversation = BotConversation(botID: BotID(), title: "never ran")
        let routing = vm.deskThreadRailRouting(for: conversation)
        XCTAssertEqual(routing.provider, vm.deskRunProvider,
                       "a never-run conversation must show the routing the desk would use today")
    }

    func test_deskHeaderOpenInNewWindowSitsAfterStudioCog() throws {
        // WHY: Agentic pops a workspace with rectangle.on.rectangle. The
        // cog row is the bot chrome; the pop-out must sit after Studio and
        // before the inspector toggle, and vanish in the detached window.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private func deskHeader") else {
            return XCTFail("desk header must exist")
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func deskChat")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        let studio = try XCTUnwrap(slice.range(of: "bots.desk.studio")?.lowerBound)
        let pop = try XCTUnwrap(slice.range(of: "bots.desk.openInNewWindow")?.lowerBound)
        let toggle = try XCTUnwrap(slice.range(of: "bots.desk.inspectorToggle")?.lowerBound)
        XCTAssertLessThan(studio, pop)
        XCTAssertLessThan(pop, toggle)
        XCTAssertTrue(slice.contains("rectangle.on.rectangle"))
        XCTAssertTrue(slice.contains("Open in New Window"))
        XCTAssertTrue(slice.contains("if !vm.presentsAsDetachedWindow"))
        XCTAssertTrue(source.contains("class BotDeskWindowController"))
        XCTAssertTrue(source.contains("embedsRosterRail: false"))
        XCTAssertTrue(
            slice.contains("HStack(spacing: Self.deskHeaderIconSpacing)"),
            "Studio / pop-out / inspector must cluster, not inherit the header's Space.md"
        )
        XCTAssertTrue(
            source.contains("DS.Space.xs - (DSIconButton.hitTargetSize - DSIconButton.visualSize.width)"),
            "Desk header glyphs must sit Space.xs apart like workspace header icons"
        )
    }

    func test_openBotInNewWindowReusesWindow_andLeavesMainDesk() throws {
        // WHY: A second click must focus the same window. Pop-out is not
        // workspace eviction; the main Desk selection must stay put.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        let controller = MainWindowController(context: context, router: router)
        router.windowController = controller
        defer {
            controller.botWindow(for: bot.id)?.orderOut(nil)
            controller.window.orderOut(nil)
        }
        controller.openBotInNewWindow(bot.id)
        let first = try XCTUnwrap(controller.botWindow(for: bot.id))
        controller.openBotInNewWindow(bot.id)
        XCTAssertTrue(controller.botWindow(for: bot.id) === first)
        XCTAssertEqual(vm.selectedBotID, bot.id)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertFalse(vm.presentsAsDetachedWindow)
    }

    func test_openBotGuestDesktopInNewWindowReusesWindow() throws {
        // WHY: Open in New Window on the Linux desktop must pop only that
        // screen, and a second click must focus the same window.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        let controller = MainWindowController(context: context, router: router)
        router.windowController = controller
        defer {
            controller.botGuestDesktopWindow(for: bot.id)?.orderOut(nil)
            controller.window.orderOut(nil)
        }
        controller.openBotGuestDesktopInNewWindow(bot.id)
        let first = try XCTUnwrap(controller.botGuestDesktopWindow(for: bot.id))
        XCTAssertEqual(first.accessibilityIdentifier(), "bots.desk.desktop.window")
        controller.openBotGuestDesktopInNewWindow(bot.id)
        XCTAssertTrue(controller.botGuestDesktopWindow(for: bot.id) === first)
        XCTAssertEqual(vm.selectedBotID, bot.id)
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("class BotGuestDesktopWindowController"))
        XCTAssertTrue(source.contains("BotGuestDesktopRoot"))
    }

    func test_botsHidesShellWorkspaceHeader_becauseDeskAlreadyHasTheBotHeader() throws {
        // WHY: The shell "Bots" bar sat above Desk's identity header.
        // Desk is the title. Hide that chrome row when the sidebar is open;
        // collapsed still needs it for the sidebar toggle.
        let main = try String(contentsOf: sourceURL("Sources/AppShell/MainWindowController.swift"), encoding: .utf8)
        XCTAssertTrue(main.contains("applyWorkspaceHeaderVisibility"))
        XCTAssertTrue(
            main.contains("showCollapsed || shellContentMode == .bots"),
            "Bots must drop the visible workspace header, not only when the sidebar is collapsed"
        )
        XCTAssertTrue(
            main.contains("workspaceContentTopInset("),
            "hiding the bar without collapsing the inset leaves a 34pt gap"
        )
        XCTAssertEqual(
            ShellSidebarToggleMotion.workspaceContentTopInset(
                collapsed: false,
                hidesVisibleHeader: true,
                headerHeight: 34
            ),
            0,
            "open dest dest dest is full-bleed; dest dest dest already owns the title"
        )
        XCTAssertEqual(
            ShellSidebarToggleMotion.splitTopInset(collapsed: true, headerHeight: 34),
            34,
            "collapsed dest dest still needs the 34pt bar so the sidebar toggle remains reachable"
        )
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
            slice.contains("vm.openDeskFromRoster(bot)"),
            "clicking a roster bot must dest Desk, not openHome"
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
        let rowEnd = rest.range(of: "\n@MainActor")?.lowerBound ?? end
        let row = String(source[start.lowerBound..<rowEnd])
        XCTAssertTrue(
            row.contains(".padding(.horizontal, DS.Space.sm)"),
            "roster rows must use the same horizontal inset as workspace rows"
        )
        XCTAssertTrue(
            row.contains("size: 16"),
            "the avatar must sit inside the 20pt workspace icon slot, not overflow into the rail margin"
        )
        XCTAssertTrue(row.contains(".frame(width: 20, height: 20)"))
        XCTAssertFalse(
            row.contains("size: 22"),
            "a 22pt blob in a 20pt slot eats the Space.sm inset the folder icon keeps"
        )
    }

    func test_rosterSelectionUsesAvatarInk_becauseWorkspaceRowsTintFromIdentity() throws {
        // WHY: Workspace rows wash the selected plate with the folder
        // color. A bot row must use the painted avatar, not the generic
        // selection gray.
        let pink = BotBlobatarSpec(hue: .named("pink"))
        XCTAssertEqual(
            BotsChrome.identityHex(name: "Ceo", handle: "ceo", symbol: pink.token),
            BotBlobatar.figure(name: "Ceo", spec: pink, handle: "ceo").palette.head
        )
        XCTAssertEqual(
            BotsChrome.identityHex(name: "Ceo", handle: "ceo", symbol: "person.crop.circle"),
            BotsChrome.avatarHex(for: "ceo")
        )
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private func rosterRow") else {
            return XCTFail("roster row must exist")
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func ")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertTrue(slice.contains("BotsChrome.identityColor"))
        XCTAssertTrue(slice.contains("identity.opacity(0.22)"))
        XCTAssertFalse(
            slice.contains("DS.Palette.selection"),
            "selected bot rows must not use the generic workspace-less gray"
        )
        XCTAssertFalse(
            slice.contains("DS.Palette.accent"),
            "the leading bar must follow the avatar, not the app accent"
        )
    }

    func test_rosterShowsWorkspaceBusySpinner_becauseWorkingMustMatchAgentic() throws {
        // WHY: dest dest Working used the same green avatar dot as Online.
        // Agentic workspaces put a 16pt ProgressView on the trailing edge.
        // dest dest must mount that same spinner while the teammate works.
        XCTAssertTrue(BotsChrome.rosterShowsBusySpinner(for: .working))
        XCTAssertFalse(BotsChrome.rosterShowsBusySpinner(for: .none))
        XCTAssertFalse(BotsChrome.rosterShowsBusySpinner(for: .needsAttention))
        XCTAssertFalse(BotsChrome.rosterShowsBusySpinner(for: .unreadActivity))

        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private func rosterRow") else {
            return XCTFail("roster row must exist")
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func ")?.lowerBound ?? rest.endIndex
        let row = String(source[start.lowerBound..<end])
        XCTAssertTrue(row.contains("DSBusySpinner("), "dest dest roster must reuse the workspace busy spinner")
        XCTAssertTrue(row.contains("BotsChrome.rosterShowsBusySpinner"))
        XCTAssertTrue(row.contains("bots.roster.busy"))

        let sidebar = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        XCTAssertTrue(
            sidebar.contains("DSBusySpinner("),
            "Agentic workspace rows must own the same DSBusySpinner type"
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
        XCTAssertTrue(
            studio.contains("requestLeaveUnsavedNewBot"),
            "Studio Back must confirm unsaved New Bot before desting Chat"
        )
        XCTAssertTrue(studio.contains("leaveStudioAfterUnsavedGate"))
        XCTAssertTrue(
            studio.contains("studioHeaderNotify"),
            "Notify lives in the header so it stays reachable on Files and Security"
        )
        XCTAssertTrue(studio.contains("bots.studio.notifications"))
        XCTAssertFalse(
            source.contains("private var studioNotifications"),
            "a Profile notifications section would bury the switch under the fold"
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

    func test_activeBotCountCountsWorkingOnly_notNeedsYou() throws {
        // WHY: Active Threads counts live runs. Active Bots used to mix
        // working + needs-you, so the badge said 2 while only one bot ran.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        try context.botStore.upsertConversation(
            BotConversation(botID: piper.id, title: "live turn", attentionState: .working)
        )
        try context.botStore.upsertAttention(
            BotAttentionItem(botID: quinn.id, kind: .approval, title: "Need you")
        )
        vm.reload()
        XCTAssertEqual(vm.attentionState(for: piper), .working)
        XCTAssertEqual(vm.attentionState(for: quinn), .needsAttention)
        XCTAssertEqual(vm.activeBotCount, 1)
        XCTAssertEqual(vm.liveWorkingBots().map(\.id), [piper.id])
    }

    func test_openActiveBotsOpensActiveBotsScreen() throws {
        // WHY: Active Threads opens an overview. Active Bots must not jump
        // to a needs-you Desk when the user asked for the live roster.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        try context.botStore.upsertConversation(
            BotConversation(botID: piper.id, title: "live turn", attentionState: .working)
        )
        vm.reload()
        vm.openActiveBots()
        XCTAssertEqual(vm.screen, .activeBots)
        XCTAssertEqual(vm.activeBotItems.map(\.botID), [piper.id])
        XCTAssertEqual(vm.activeBotsSubtitle, "1 bot is running")
    }

    func test_openActiveBotItemOpensDesk() throws {
        // WHY: a row on the Active Bots screen must dest that teammate's
        // Desk, same as opening an Active Threads row dests the thread.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        try context.botStore.upsertConversation(
            BotConversation(botID: piper.id, title: "live turn", attentionState: .working)
        )
        vm.reload()
        vm.openActiveBots()
        let item = try XCTUnwrap(vm.activeBotItems.first)
        vm.openActiveBotItem(item)
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
    }

    func test_liveWorkingBotsIncludesLinkedActiveRun() throws {
        // WHY: Active Threads counts coordinator live threads. A bot whose
        // conversation is not flagged .working must still appear when its
        // linked agent thread is actually running.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let idle = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        let thread = AgentThread(title: "Standup", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        try context.botStore.upsertConversation(
            BotConversation(
                botID: piper.id,
                title: "Standup",
                attentionState: .none,
                linkedAgentThreadID: thread.id
            )
        )
        vm.reload()
        XCTAssertEqual(vm.attentionState(for: piper), .none)
        XCTAssertTrue(vm.liveWorkingBots().isEmpty)
        vm.activeThreadIDsOverrideForTesting = [thread.id]
        XCTAssertEqual(vm.liveWorkingBots().map(\.id), [piper.id])
        XCTAssertFalse(vm.liveWorkingBots().contains(where: { $0.id == idle.id }))
        XCTAssertEqual(vm.activeBotCount, 1)
        vm.openActiveBots()
        XCTAssertEqual(vm.activeBotItems.map(\.botID), [piper.id])
        XCTAssertEqual(vm.activeBotItems.first?.nextRunLabel, "Running now")
        XCTAssertNotEqual(vm.activeBotItems.first?.lastTriggeredLabel, "")
    }

    func test_activeBotsSearchFiltersLiveRoster() throws {
        // WHY: Scheduled Tasks search hides non-matches. Active Bots must
        // filter the live roster the same way, not keep showing every runner.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        let piperThread = AgentThread(title: "Piper live", provider: .claude, model: "opus")
        let quinnThread = AgentThread(title: "Quinn live", provider: .claude, model: "opus")
        try context.threadRepo.upsert(piperThread)
        try context.threadRepo.upsert(quinnThread)
        try context.botStore.upsertConversation(
            BotConversation(botID: piper.id, title: "live turn", linkedAgentThreadID: piperThread.id)
        )
        try context.botStore.upsertConversation(
            BotConversation(botID: quinn.id, title: "other turn", linkedAgentThreadID: quinnThread.id)
        )
        vm.activeThreadIDsOverrideForTesting = [piperThread.id, quinnThread.id]
        vm.reload()
        vm.openActiveBots()
        XCTAssertEqual(Set(vm.filteredActiveBotItems().map(\.botID)), [piper.id, quinn.id])
        vm.activeBotsSearchText = "piper"
        XCTAssertEqual(vm.filteredActiveBotItems().map(\.botID), [piper.id])
        vm.activeBotsSearchText = "no-such-bot"
        XCTAssertTrue(vm.filteredActiveBotItems().isEmpty)
    }

    func test_activeBotItemsClearWhenRunFinishes_becauseChipMustMatchFooter() throws {
        // WHY: Computer Use saw Active chip "1" while the footer said
        // "0 active" after a mention hop finished. The chip reads cached
        // activeBotItems; the footer reads liveWorkingBots(). Follow-through
        // must refresh that cache so chip, list, and footer agree.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        let live = BotConversation(botID: piper.id, title: "live turn", attentionState: .working)
        try context.botStore.upsertConversation(live)
        vm.reload()
        vm.openActiveBots()
        XCTAssertEqual(vm.screen, .activeBots)
        XCTAssertEqual(vm.activeBotCount, 1)
        XCTAssertEqual(vm.filteredActiveBotItems().map(\.botID), [piper.id])
        XCTAssertEqual(vm.filteredActiveBotItems().count, vm.activeBotCount)

        vm.applyFollowThroughForTests(bot: piper, conversation: live, status: .completed)
        XCTAssertEqual(vm.attentionState(for: piper), .unreadActivity)
        XCTAssertEqual(vm.activeBotCount, 0)
        XCTAssertTrue(
            vm.filteredActiveBotItems().isEmpty,
            "Active chip/list must drop the finished bot without reopening the tab"
        )
        XCTAssertEqual(vm.filteredActiveBotItems().count, vm.activeBotCount)
        XCTAssertEqual(vm.activeBotsFooterLine.hasPrefix("0 active"), true)
    }

    func test_staleWorkingConversationSettlesWhenLinkedRunIsTerminal() throws {
        // WHY: Computer Use saw Piper Working + Active Bots 1 after the
        // work log said Done and no provider process was alive. Persist
        // working survived relaunch because didFinish only refreshed the
        // chip from that stale flag. Reload must settle the row.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .grok)
        let thread = AgentThread(title: "Night scan", provider: .grok, model: "grok-4.6")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .grok,
            model: "grok-4.6",
            status: .completed,
            startedAt: Date().addingTimeInterval(-120),
            finishedAt: Date().addingTimeInterval(-30)
        )
        try context.runRepo.upsert(run)
        try context.botStore.upsertConversation(
            BotConversation(
                botID: piper.id,
                title: "Night scan",
                attentionState: .working,
                linkedAgentThreadID: thread.id
            )
        )
        let reopened = BotsViewModel(context: context)
        reopened.openDesk(piper)
        XCTAssertEqual(reopened.deskWorkLog.first?.statusLabel, "Done")
        XCTAssertNotEqual(reopened.attentionState(for: piper), .working)
        XCTAssertEqual(reopened.activeBotCount, 0)
        reopened.openActiveBots()
        XCTAssertTrue(reopened.filteredActiveBotItems().isEmpty)
        XCTAssertEqual(
            try context.botStore.listConversations(botID: piper.id).first?.attentionState,
            BotAttentionState.none
        )
    }

    func test_didFinishAppliesFollowThrough_soActiveChipDrops() throws {
        // WHY: followLinkedRun is cancelled on dest switch and process
        // death. didFinish used to reload Active Bots without leaving
        // .working, so the chip stayed at 1 after Done.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .grok)
        let thread = AgentThread(title: "Night scan", provider: .grok, model: "grok-4.6")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .grok,
            model: "grok-4.6",
            status: .completed,
            finishedAt: Date()
        )
        try context.runRepo.upsert(run)
        try context.botStore.upsertConversation(
            BotConversation(
                botID: piper.id,
                title: "Night scan",
                attentionState: .working,
                linkedAgentThreadID: thread.id
            )
        )
        vm.adoptLinkedRunTerminalForTests(runId: run.id, threadId: thread.id)
        XCTAssertNotEqual(vm.attentionState(for: piper), .working)
        XCTAssertEqual(vm.activeBotCount, 0)
        XCTAssertEqual(
            try context.botStore.listConversations(botID: piper.id).first?.attentionState,
            BotAttentionState.none
        )
    }

    func test_workingConversationStaysLiveWhenLinkedRunIsRunning() throws {
        // WHY: settle must not drop a teammate whose provider turn is
        // still running. Only a terminal linked run clears Working.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .grok)
        let thread = AgentThread(title: "Night scan", provider: .grok, model: "grok-4.6")
        try context.threadRepo.upsert(thread)
        try context.runRepo.upsert(AgentRun(
            threadId: thread.id,
            provider: .grok,
            model: "grok-4.6",
            status: .running
        ))
        try context.botStore.upsertConversation(
            BotConversation(
                botID: piper.id,
                title: "Night scan",
                attentionState: .working,
                linkedAgentThreadID: thread.id
            )
        )
        vm.openDesk(piper)
        XCTAssertEqual(vm.attentionState(for: piper), .working)
        XCTAssertEqual(vm.activeBotCount, 1)
        XCTAssertEqual(vm.deskWorkLog.first?.statusLabel, "Working")
    }

    func test_refreshPublishedIdentityPicksUpSelfConfigTitle() throws {
        // WHY: bot_set_settings publishes through a sidecar SQLite write.
        // Desk kept the stale name/title until remount. After a self-edit
        // the header and roster must show the new identity without relaunch.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "CEO", title: "", provider: .grok)
        vm.openDesk(bot)
        XCTAssertEqual(vm.selectedBot?.title, "")
        let service = BotSelfConfigService(callerBotID: bot.id, store: context.botStore)
        _ = try service.apply(BotSelfConfigPatch(title: "CEO da empresa"))
        XCTAssertEqual(vm.selectedBot?.title, "", "in-memory roster stays stale until refresh")
        let fresh = try XCTUnwrap(vm.refreshPublishedIdentity(for: bot.id))
        XCTAssertEqual(fresh.title, "CEO da empresa")
        XCTAssertEqual(vm.selectedBot?.title, "CEO da empresa")
        XCTAssertEqual(vm.selectedRevision?.title, "CEO da empresa")
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(
            source.contains("refreshPublishedIdentity(for: botID)"),
            "live desk watch must refresh identity when the turn streams or finishes"
        )
    }

    func test_openScheduleTasksOpensBotsScheduleScreen() throws {
        // WHY: Bots Schedule Tasks used to open Agent scheduled tasks.
        // The row must dest the bots routines overview instead.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Check overnight failures"
        vm.routineScheduleNote = "Weekdays 9:00"
        vm.saveRoutine()
        vm.setRoutineEnabled(id: try XCTUnwrap(vm.routines.first?.definition.id), enabled: true)
        vm.openScheduleTasks()
        XCTAssertEqual(vm.screen, .scheduleTasks)
        XCTAssertEqual(vm.scheduleTaskItems.map(\.name), ["Morning scan"])
        XCTAssertEqual(vm.scheduleTaskFilterCounts.active, 1)
        XCTAssertEqual(vm.scheduleTasksSubtitle, "Automatic runs paused — turn Active on when you're back")
    }

    func test_enabledTaskNextRunSaysSchedulerPaused_whenAutonomyIsOff_becauseOpenDoesNotMeanItRuns() throws {
        // WHY: Computer Use saw Next run "While RemoteCode is open" while
        // the global switch read Schedules paused. An enabled task is armed,
        // not running, so Next run must say the scheduler is paused.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Check overnight failures"
        vm.routineScheduleNote = "Weekdays 9:00"
        vm.saveRoutine()
        let id = try XCTUnwrap(vm.routines.first?.definition.id)
        vm.setRoutineEnabled(id: id, enabled: true)
        vm.openScheduleTasks()
        XCTAssertFalse(vm.isAutonomyActive)
        let armed = try XCTUnwrap(vm.scheduleTaskItems.first)
        XCTAssertTrue(armed.isEnabled)
        XCTAssertEqual(
            armed.nextRunLabel(isAutonomyActive: vm.isAutonomyActive),
            "Scheduler paused"
        )
        vm.setAutonomyActive(true)
        XCTAssertEqual(
            armed.nextRunLabel(isAutonomyActive: vm.isAutonomyActive),
            "While RemoteCode is open"
        )
        vm.setRoutineEnabled(id: id, enabled: false)
        let paused = try XCTUnwrap(vm.scheduleTaskItems.first)
        XCTAssertEqual(paused.nextRunLabel(isAutonomyActive: true), "Paused")
    }

    func test_botScheduleTasksFiltersAndToggle() throws {
        // WHY: All / Active / Paused must filter shipped routines, not a
        // decorative count, so the overview matches Agent Scheduled Tasks.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.routineName = "Live"
        vm.routinePrompt = "Ping"
        vm.saveRoutine()
        let liveID = try XCTUnwrap(vm.routines.first?.definition.id)
        vm.setRoutineEnabled(id: liveID, enabled: true)
        vm.routineName = "Paused"
        vm.routinePrompt = "Wait"
        vm.saveRoutine()
        vm.openScheduleTasks()
        XCTAssertEqual(vm.scheduleTaskFilterCounts.all, 2)
        XCTAssertEqual(vm.scheduleTaskFilterCounts.active, 1)
        XCTAssertEqual(vm.scheduleTaskFilterCounts.paused, 1)
        vm.scheduleTaskStatusFilter = .paused
        XCTAssertEqual(vm.scheduleTaskItems.map(\.name), ["Paused"])
        let paused = try XCTUnwrap(vm.scheduleTaskItems.first)
        vm.setRoutineEnabled(id: paused.id, enabled: true)
        vm.scheduleTaskStatusFilter = .active
        XCTAssertEqual(Set(vm.scheduleTaskItems.map(\.name)), ["Live", "Paused"])
        vm.setAutonomyActive(true)
        XCTAssertTrue(vm.isAutonomyActive)
    }

    func test_botScheduleEditorCopiesAgentAppFrequencyAndRouting() throws {
        // WHY: Bot Schedule Tasks used a free-text When field. Owners need
        // the Agent App Frequency + Provider / Model Auto / Reasoning rows.
        let source = try String(
            contentsOf: sourceURL("Sources/AppShell/BotScheduleTasksWindow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("bots.scheduleTasks.editor.frequency"))
        XCTAssertTrue(source.contains("bots.scheduleTasks.editor.provider"))
        XCTAssertTrue(source.contains("bots.scheduleTasks.editor.autoRouting"))
        XCTAssertTrue(source.contains("bots.scheduleTasks.editor.reasoning"))
        XCTAssertTrue(source.contains("struct BotScheduleSpecEditor"))
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.createScheduleTask()
        var draft = try XCTUnwrap(vm.scheduleTaskDraft)
        draft.name = "Morning scan"
        draft.prompt = "Scan overnight"
        draft.spec.provider = .grok
        draft.spec.providerInstanceID = "grok"
        draft.spec.routingMode = .auto
        draft.spec.reasoningEffort = .medium
        draft.spec.frequency = .daily
        draft.spec.localTimeHour = 9
        draft.spec.localTimeMinute = 0
        vm.saveScheduleTask(draft)
        let saved = try XCTUnwrap(vm.scheduleTaskItems.first)
        let spec = try XCTUnwrap(BotScheduleSpec.decodeJSON(saved.scheduleSpecJSON))
        XCTAssertEqual(spec.provider, .grok)
        XCTAssertEqual(spec.routingMode, .auto)
        XCTAssertEqual(spec.frequency, .daily)
        XCTAssertEqual(saved.scheduleNote, "Daily 09:00")
    }

    func test_scheduleTaskEditorFieldsHaveVoiceOverNames_becauseVisualLabelIsNotTheControlName() throws {
        // WHY: Computer Use / VoiceOver saw New Scheduled Task Name, When,
        // and Instruction as unnamed fields. `labeled` painted a caption
        // but never named the control. Studio `labeledField` already hides
        // the caption and sets accessibilityLabel — this editor must too.
        let source = try String(
            contentsOf: sourceURL("Sources/AppShell/BotScheduleTasksWindow.swift"),
            encoding: .utf8
        )
        guard let start = source.range(of: "private func labeled<Content: View>") else {
            return XCTFail("schedule editor labeled helper must exist")
        }
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\n}\n")?.upperBound ?? rest.endIndex
        let helper = String(source[start.lowerBound..<end])
        XCTAssertTrue(
            helper.contains(".accessibilityHidden(true)"),
            "visual Name/When/Instruction captions must not double-speak"
        )
        XCTAssertTrue(
            helper.contains(".accessibilityLabel(title)"),
            "Name, When, and Instruction must expose the caption as the control name"
        )
        XCTAssertTrue(
            source.contains("Picker(\"\", selection: $draft.botID)"),
            "Picker title must stay empty so VoiceOver does not speak Bot, Bot"
        )
    }

    func test_botsSearchFieldsHaveVoiceOverNames_becausePlaceholderIsNotTheControlName() throws {
        // WHY: Computer Use / VoiceOver saw Search bots and Search tasks as
        // unnamed fields (AX label null). Placeholder is hint copy, not the
        // control name. Name the field so VoiceOver can land on it.
        let sidebar = try String(
            contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"),
            encoding: .utf8
        )
        let active = try String(
            contentsOf: sourceURL("Sources/AppShell/ActiveBotsWindow.swift"),
            encoding: .utf8
        )
        let schedule = try String(
            contentsOf: sourceURL("Sources/AppShell/BotScheduleTasksWindow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            sidebar.contains("setAccessibilityLabel(placeholder)"),
            "Sidebar Search bots / Filter workspaces must expose the placeholder as the AX name"
        )
        XCTAssertTrue(
            active.contains(".accessibilityLabel(\"Search bots\")"),
            "Active Bots search must expose Search bots as the control name"
        )
        XCTAssertTrue(
            schedule.contains(".accessibilityLabel(\"Search tasks\")"),
            "Schedule Tasks search must expose Search tasks as the control name"
        )
    }

    func test_studioRoutineActiveSwitchSaysActiveAndName_becauseTitleAloneHidesTheJob() throws {
        // WHY: Computer Use / VoiceOver named the Studio Active switch
        // "QA morning scan" only. The visible job is Active; the title
        // is already a heading. Speak both so the switch is not just
        // another copy of the task name.
        let source = try String(
            contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"),
            encoding: .utf8
        )
        guard let start = source.range(of: "private func routineRowBody") else {
            return XCTFail("studio routine row must exist")
        }
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "// MARK: Shared chrome")?.lowerBound ?? rest.endIndex
        let body = String(source[start.lowerBound..<end])
        XCTAssertTrue(
            body.contains("Toggle(\"Active\""),
            "the visible switch title stays Active"
        )
        XCTAssertTrue(
            body.contains(".accessibilityLabel(\"Active, \\(routine.definition.name)\")"),
            "VoiceOver must hear Active plus the routine name"
        )
        XCTAssertFalse(
            body.contains(".accessibilityLabel(routine.definition.name)"),
            "the switch must not reuse the heading as its only name"
        )
        XCTAssertTrue(
            body.contains("Button(\"Edit\") { vm.editRoutine(routine) }"),
            "existing Studio tasks must expose Edit, not only Test run"
        )
        XCTAssertTrue(
            body.contains("accessibilityIdentifier(\"bots.routines.edit\")"),
            "Edit must be a named control so Computer Use can open the dedicated editor"
        )
    }

    func test_editScheduleTaskHydratesFrequencyFromNote_becauseEmptySpecMustNotBecomeDailyNow() throws {
        // WHY: Bot-created routines persist When as "Weekdays 9:00" with
        // empty schedule_spec_json. Fleet Edit used to open Daily at now,
        // so Save replaced the visible weekdays 9:00 schedule.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        try context.botStore.saveRoutine(
            BotRoutineDefinition(
                botID: piper.id,
                name: "QA morning scan",
                prompt: "Check overnight failures and reply with one short status.",
                scheduleNote: "Weekdays 9:00"
            )
        )
        vm.openScheduleTasks()
        let item = try XCTUnwrap(vm.scheduleTaskItems.first)
        XCTAssertEqual(item.scheduleNote, "Weekdays 9:00")
        XCTAssertTrue(item.scheduleSpecJSON.isEmpty)

        vm.editScheduleTask(item)

        let draft = try XCTUnwrap(vm.scheduleTaskDraft)
        XCTAssertEqual(draft.name, "QA morning scan")
        XCTAssertEqual(draft.spec.frequency, .weekdays)
        XCTAssertEqual(draft.spec.localTimeHour, 9)
        XCTAssertEqual(draft.spec.localTimeMinute, 0)
    }

    func test_studioEditRoutineOpensDedicatedEditor_becauseExistingTasksMustBeEditable() throws {
        // WHY: Studio Schedule Tasks only created new rows. Existing tasks
        // showed Test run and Active, so owners could not change name,
        // instruction, or frequency. Edit must open the dedicated
        // Edit Scheduled Task draft with the same id and saved spec.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openStudio(piper)
        vm.routineName = "QA morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.routineSpec.provider = .grok
        vm.routineSpec.providerInstanceID = "grok"
        vm.routineSpec.routingMode = .auto
        vm.routineSpec.frequency = .daily
        vm.routineSpec.localTimeHour = 9
        vm.routineSpec.localTimeMinute = 0
        vm.saveRoutine()
        let id = try XCTUnwrap(vm.routines.first?.definition.id)
        vm.setRoutineEnabled(id: id, enabled: true)
        let routine = try XCTUnwrap(vm.routines.first)
        XCTAssertEqual(vm.screen, .studio)

        vm.editRoutine(routine)

        XCTAssertEqual(vm.screen, .scheduleTasks)
        let draft = try XCTUnwrap(vm.scheduleTaskDraft)
        XCTAssertFalse(draft.isNew)
        XCTAssertEqual(draft.id, routine.definition.id)
        XCTAssertEqual(draft.botID, piper.id)
        XCTAssertEqual(draft.name, "QA morning scan")
        XCTAssertEqual(draft.prompt, "Scan overnight failures")
        XCTAssertTrue(draft.isEnabled)
        XCTAssertEqual(draft.spec.provider, .grok)
        XCTAssertEqual(draft.spec.routingMode, .auto)
        XCTAssertEqual(draft.spec.frequency, .daily)
        XCTAssertEqual(draft.spec.localTimeHour, 9)

        var edited = draft
        edited.name = "QA evening scan"
        edited.prompt = "Scan the afternoon queue"
        edited.spec.frequency = .weekdays
        vm.saveScheduleTask(edited)

        XCTAssertNil(vm.scheduleTaskDraft)
        XCTAssertEqual(vm.scheduleTaskItems.map(\.name), ["QA evening scan"])
        XCTAssertEqual(vm.scheduleTaskItems.count, 1)
        XCTAssertEqual(vm.routines.map(\.definition.name), ["QA evening scan"])
        XCTAssertEqual(vm.routines.count, 1)
        let saved = try XCTUnwrap(vm.scheduleTaskItems.first)
        XCTAssertEqual(saved.id, routine.definition.id)
        XCTAssertEqual(saved.prompt, "Scan the afternoon queue")
        XCTAssertEqual(saved.scheduleNote, "Weekdays 09:00")
        let spec = try XCTUnwrap(BotScheduleSpec.decodeJSON(saved.scheduleSpecJSON))
        XCTAssertEqual(spec.frequency, .weekdays)
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
        XCTAssertEqual(vm.inspectorTab, .routines)
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
        XCTAssertEqual(vm.inspectorTab, .routines)

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

    func test_deskAddScheduledTaskOpensStudio() throws {
        // WHY: Desk is the chat dest. Creating a schedule is Studio work.
        // A form in the inspector would keep the owner off Chat.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.inspectorTab = .routines
        vm.routineName = "Leftover"
        vm.openStudioToAddRoutine()
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioTab, .routines)
        XCTAssertTrue(vm.routineName.isEmpty)
        XCTAssertEqual(vm.selectedBotID, bot.id)
    }

    func test_deskInspectorListsRoutinesWithoutAForm() throws {
        // WHY: The inspector must show live tasks, not a second create form.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.routineName = "Morning scan"
        vm.routinePrompt = "Scan overnight failures"
        vm.saveRoutine()
        XCTAssertEqual(vm.routines.map(\.definition.name), ["Morning scan"])
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private var inspectorRoutines") else {
            return XCTFail("desk inspector routines must exist")
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func deskTimeline")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertFalse(slice.contains("bots.routines.name"))
        XCTAssertFalse(slice.contains("bots.routines.save"))
        XCTAssertFalse(slice.contains("BotScheduleSpecEditor"))
        XCTAssertTrue(slice.contains("bots.desk.inspector.routines.add"))
        XCTAssertTrue(slice.contains("deskRoutineRow"))
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
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
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
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
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
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
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
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
                skills: vm.skillBindings,
                routines: vm.routines,
                workspace: vm.advertisedWorkspace
            )
        )
    }

    func test_previewBrainIncludesAdvertisedMemoryMutateKey_becauseDestMustNotOmitForgetKeys() throws {
        // WHY: Memory is the files. Dest preview and compose must share
        // MEMORY.md so first-chat "what's in Memory?" cannot invent a hop.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", soul: "Own the inbox.", provider: .claude)
        vm.openDesk(piper)
        try vm.botHome(for: piper).writeFile(
            relativePath: BotHome.memoryName,
            contents: "- Prefers dark mode\n"
        )
        vm.composerText = "Forget the dark-mode fact"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertTrue(preview.compiledPayload.contains("Memory:"))
        XCTAssertFalse(preview.compiledPayload.contains("Trusted memory:"))
        XCTAssertTrue(preview.compiledPayload.contains("### MEMORY.md"))
        XCTAssertTrue(preview.compiledPayload.contains("Prefers dark mode"))
        XCTAssertFalse(preview.compiledPayload.contains("Fact: Prefers dark mode"))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertTrue(preview.compiledPayload.contains(BotStandingInstructions.writeMemoryFileTool))
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "Forget the dark-mode fact",
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
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
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
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
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
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
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
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
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
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
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
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
        XCTAssertFalse(preview.compiledPayload.contains("Model: opus"))
        XCTAssertFalse(preview.compiledPayload.contains("Default route:"))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(preview.layers.first(where: { $0.kind == .route })?.included, false)
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "What's your Model?",
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
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
        XCTAssertFalse(preview.compiledPayload.contains("Default route:"))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertFalse(preview.compiledPayload.contains("bot_set_fallback"))
        XCTAssertFalse(preview.layers.contains { $0.title == "Fallback" })
        XCTAssertEqual(preview.layers.first(where: { $0.kind == .route })?.included, false)
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "If Claude is down use Grok",
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
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
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
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
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
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
        XCTAssertFalse(preview.compiledPayload.contains("Skills: weekly-account-health"))
        XCTAssertFalse(preview.compiledPayload.contains("Enabled skills"))
        XCTAssertFalse(preview.compiledPayload.contains("off-skill"))
        XCTAssertTrue(preview.compiledPayload.contains("Own the inbox."))
        XCTAssertEqual(
            preview.compiledPayload,
            BotsDeskFollowThrough.composeRunPrompt(
                bot: piper,
                revision: try XCTUnwrap(vm.selectedRevision),
                userText: "Which Skills?",
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
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
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
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
        // WHY: Source vs Effective is a selected Brain pane. The Brain tab
        // is no longer user-facing, so leftover Brain persist remaps to
        // Routines while the pane choice still survives for compile receipts.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(bot)
        vm.inspectorTab = .brain
        vm.brainPane = .effective
        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.inspectorTab, .routines)
        XCTAssertEqual(reopened.brainPane, .effective)
    }

    func test_leftoverBrainStudioTabOpensProfile_becauseBrainIsNotUserFacing() throws {
        // WHY: Brain is a compile inspector, not a Studio form. A leftover
        // persist must not reopen a tab the owner can no longer reach.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        _ = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        UserDefaults.standard.set("brain", forKey: "bots.studioTab")
        UserDefaults.standard.set("brain", forKey: "bots.inspectorTab")
        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.studioTab, .profile)
        XCTAssertEqual(reopened.inspectorTab, .routines)
        XCTAssertFalse(BotStudioTab.brain.isUserFacing)
        XCTAssertFalse(BotDeskInspectorTab.brain.isUserFacing)
        XCTAssertTrue(BotStudioTab.files.isUserFacing)
        XCTAssertEqual(
            BotStudioTab.allCases.filter(\.isUserFacing).map(\.id),
            ["profile", "files", "routines", "security"]
        )
        XCTAssertEqual(
            BotDeskInspectorTab.allCases.filter(\.isUserFacing).map(\.id),
            ["routines"]
        )
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(
            bots.contains("ForEach(BotStudioTab.allCases.filter(\\.isUserFacing))"),
            "Brain stays on the enum for leftover persist; the Studio strip must not render it"
        )
        // Routines is the only user-facing inspector tab, so the Desk shows a
        // static section header instead of a one-chip tab strip. Brain stays
        // unreachable: there is no strip to render it, and the header title
        // resolves through the leftover-persist remap.
        XCTAssertFalse(
            bots.contains("ForEach(BotDeskInspectorTab.allCases"),
            "A single user-facing tab must render as a header, not a dead one-chip strip"
        )
        XCTAssertTrue(
            bots.contains("Text(resolvedInspectorTab.title)"),
            "The Desk inspector header must resolve through the leftover-persist remap"
        )
    }

    func test_soulFileSavePublishesSameRevisionAsStudioSave() throws {
        // WHY: Files SOUL.md must not fork a second soul from Save Bot.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.", provider: .claude)
        vm.beginEdit(bot)
        let first = try XCTUnwrap(vm.selectedRevision?.revisionNumber)
        vm.homeDraft = "Stand up for the brief."
        vm.selectedHomePath = BotHome.soulName
        vm.saveHomeFile()
        let afterFiles = try XCTUnwrap(vm.selectedRevision)
        XCTAssertEqual(afterFiles.soul, "Stand up for the brief.")
        XCTAssertGreaterThan(afterFiles.revisionNumber, first)
        let home = vm.botHome(for: try XCTUnwrap(vm.selectedBot))
        XCTAssertEqual(try home.readSoul(), "Stand up for the brief.")
        vm.studioDraft.soul = "Own the inbox."
        _ = try vm.saveStudio()
        XCTAssertEqual(try home.readSoul(), "Own the inbox.")
        XCTAssertEqual(vm.selectedRevision?.soul, "Own the inbox.")

        vm.attachHomeFilesSurface(for: try XCTUnwrap(vm.selectedBot))
        let router = try XCTUnwrap(vm.homeFilesRouterForTesting)
        let surfaceID = SurfaceID(bot.id.value)
        let opened = try router.filesEditOpen(surface: surfaceID, path: BotHome.soulName)
        let sessionID = try XCTUnwrap(opened.objectValue?["session_id"]?.stringValue)
        let current = opened.objectValue?["content"]?.stringValue ?? ""
        _ = try router.filesEditApplyPatch(
            sessionID: sessionID,
            baseDraftRevision: opened.objectValue?["draft_revision"]?.intValue ?? 1,
            rangeLocation: 0,
            rangeLength: (current as NSString).length,
            replacement: "From FilesSurface.",
            deviceID: "test"
        )
        _ = try router.filesEditSave(sessionID: sessionID)
        XCTAssertEqual(vm.selectedRevision?.soul, "From FilesSurface.")
        XCTAssertEqual(try home.readSoul(), "From FilesSurface.")
        _ = try? router.filesEditClose(sessionID: sessionID)
    }

    func test_studioFilesSurfaceListsBotHomeNotAdvertisedWorkspace() throws {
        // WHY: Studio Files used a custom list. Owners asked for the Agentic
        // Files component. The model must list the exclusive bot home, not
        // the advertised workspace cwd, so edits cannot leak into the project.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.", provider: .claude)
        vm.openStudio(bot)
        vm.attachHomeFilesSurface(for: bot)
        let model = try XCTUnwrap(vm.homeFilesModel)
        defer { model.close() }
        let home = vm.botHome(for: bot)
        XCTAssertEqual(model.root, home.root.path)
        XCTAssertTrue(model.root.contains("/bots/"))
        XCTAssertTrue(model.root.contains(bot.id.value.uuidString.lowercased()))
        model.loadDirectory("")
        XCTAssertTrue(
            Set(model.entries.map(\.name)).isSuperset(of: [
                BotHome.identityName,
                BotHome.descriptionName,
                BotHome.soulName,
                BotHome.memoryName,
                BotHome.skillsDirectoryName,
                BotHome.filesDirectoryName
            ])
        )
    }

    func test_studioDockerFilesSurfaceUsesPersistentGuestHome() throws {
        // WHY: Docker's real home is the existing /home/remotecode bind.
        // Studio must edit that exact host directory, including ordinary
        // files whose names are generated projections only in Bot files.
        let (_, vm, bot, _) = try makeDockerStudio()
        vm.attachHomeFilesSurface(for: bot)
        let model = try XCTUnwrap(vm.homeFilesModel)
        defer { model.close() }
        let router = try XCTUnwrap(vm.homeFilesRouterForTesting)
        let expected = BotComputerGuestSpec.guestHomeURL(
            appSupport: URL(fileURLWithPath: directory, isDirectory: true),
            botID: bot.id
        )
        XCTAssertEqual(vm.studioFilesLocation, .dockerHome)
        XCTAssertEqual(model.root, expected.path)

        _ = try router.fsWorkspaceCreateFile(
            workspace: router.workspaceID,
            path: BotHome.identityName,
            content: "ordinary docker file"
        )
        model.loadDirectory("")
        let identity = try XCTUnwrap(model.entries.first { $0.name == BotHome.identityName })
        XCTAssertTrue(identity.isEditable)
        let opened = try router.filesEditOpen(
            surface: SurfaceID(bot.id.value),
            path: BotHome.identityName
        )
        let sessionID = try XCTUnwrap(opened.objectValue?["session_id"]?.stringValue)
        let original = opened.objectValue?["content"]?.stringValue ?? ""
        _ = try router.filesEditApplyPatch(
            sessionID: sessionID,
            baseDraftRevision: opened.objectValue?["draft_revision"]?.intValue ?? 1,
            rangeLocation: 0,
            rangeLength: (original as NSString).length,
            replacement: "edited through Files",
            deviceID: "test"
        )
        _ = try router.filesEditSave(sessionID: sessionID)
        XCTAssertEqual(
            try String(contentsOf: expected.appendingPathComponent(BotHome.identityName), encoding: .utf8),
            "edited through Files"
        )
        _ = try? router.filesEditClose(sessionID: sessionID)
    }

    func test_studioDockerFilesSeedsRootDockerfileAndOpensItAsText() throws {
        // WHY: Dockerfile is per bot and extensionless. Studio must place it at the
        // exact persisted guest-home root, then promote it from unknown to editable text.
        let (context, vm, bot, docker) = try makeDockerStudio()
        vm.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: docker,
            recipeContext: AppShellResourceBundle.computerGuestRecipeURL(),
            observeAttempts: 1,
            observeDelay: 0
        )
        vm.attachHomeFilesSurface(for: bot)
        let model = try XCTUnwrap(vm.homeFilesModel)
        defer { model.close() }
        model.loadDirectory("")

        let dockerfile = try XCTUnwrap(model.entries.first { $0.name == "Dockerfile" })
        XCTAssertEqual(dockerfile.relativePath, "Dockerfile")
        XCTAssertEqual(
            dockerfile.path,
            BotComputerGuestSpec.guestHomeURL(
                appSupport: context.appSupportDirectory,
                botID: bot.id
            ).appendingPathComponent("Dockerfile").path
        )
        XCTAssertFalse(dockerfile.isEditable, "directory listing should not read every file")

        model.select(dockerfile)

        XCTAssertEqual(model.selectedEntry?.kind, "text")
        XCTAssertTrue(model.selectedEntry?.isEditable == true)
        XCTAssertTrue(model.draftText.contains("FROM debian"))
    }

    func test_studioDockerFilesCanSwitchBackToBotHome() throws {
        // WHY: Docker home is the default, but the owner must be able to
        // return to the versioned bot configuration and keep that choice.
        let (context, vm, bot, _) = try makeDockerStudio()
        vm.attachHomeFilesSurface(for: bot)
        XCTAssertEqual(vm.studioFilesLocation, .dockerHome)

        vm.setStudioFilesLocation(.botFiles, for: bot)
        XCTAssertEqual(vm.studioFilesLocation, .botFiles)
        XCTAssertEqual(vm.homeFilesModel?.root, vm.botHome(for: bot).root.path)

        let reopened = BotsViewModel(context: context)
        reopened.dockerGuestReadyOverrideForTesting = true
        reopened.openStudio(bot)
        reopened.attachHomeFilesSurface(for: bot)
        XCTAssertEqual(reopened.studioFilesLocation, .botFiles)
        XCTAssertEqual(reopened.homeFilesModel?.root, reopened.botHome(for: bot).root.path)
        reopened.homeFilesModel?.close()
    }

    func test_dockerFilesPersistAcrossReopenUntilExplicitClear() throws {
        // WHY: Stop and ordinary reopen preserve the bind. Only the confirmed
        // destructive action may tear it down and replace it with an empty home.
        let (context, vm, bot, docker) = try makeDockerStudio()
        vm.attachHomeFilesSurface(for: bot)
        let router = try XCTUnwrap(vm.homeFilesRouterForTesting)
        _ = try router.fsWorkspaceCreateFile(
            workspace: router.workspaceID,
            path: "sentinel.txt",
            content: "keep me"
        )
        let guestHome = BotComputerGuestSpec.guestHomeURL(
            appSupport: context.appSupportDirectory,
            botID: bot.id
        )
        let sentinel = guestHome.appendingPathComponent("sentinel.txt")
        vm.rememberGuestScreen(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1:49152/vnc.html")),
            botID: bot.id,
            running: true
        )
        vm.stopDockerGuest(botID: bot.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))

        let reopened = BotsViewModel(context: context)
        reopened.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: docker,
            observeAttempts: 1,
            observeDelay: 0
        )
        reopened.dockerGuestReadyOverrideForTesting = true
        reopened.openStudio(bot)
        reopened.attachHomeFilesSurface(for: bot)
        XCTAssertEqual(reopened.homeFilesModel?.root, guestHome.path)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep me")
        let beforeClear = reopened.homeFilesModel
        reopened.rememberGuestScreen(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1:49152/vnc.html")),
            botID: bot.id,
            running: true
        )

        reopened.confirmClearDockerData(for: bot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: guestHome.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: guestHome.path), [])
        XCTAssertEqual(reopened.homeFilesModel?.root, guestHome.path)
        XCTAssertFalse(reopened.homeFilesModel === beforeClear)
        XCTAssertFalse(reopened.isGuestRunning(bot.id))
        XCTAssertNil(reopened.guestScreenURL(for: bot.id))
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("pendingDockerDataClear"))
        XCTAssertTrue(source.contains("bots.studio.files.docker.clear"))
        reopened.homeFilesModel?.close()
    }

    func test_studioFilesSurfaceLocksIdentityOnly() throws {
        // WHY: IDENTITY.md is still generated. MEMORY.md is the bot's
        // own file — locking it would send Forget/Correct back to a store.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.", provider: .claude)
        vm.openStudio(bot)
        vm.attachHomeFilesSurface(for: bot)
        let model = try XCTUnwrap(vm.homeFilesModel)
        defer { model.close() }
        model.loadDirectory("")
        let identity = try XCTUnwrap(model.entries.first { $0.name == BotHome.identityName })
        let memory = try XCTUnwrap(model.entries.first { $0.name == BotHome.memoryName })
        let soul = try XCTUnwrap(model.entries.first { $0.name == BotHome.soulName })
        XCTAssertFalse(identity.isEditable)
        XCTAssertTrue(memory.isEditable)
        XCTAssertTrue(soul.isEditable)
        XCTAssertEqual(BotHome.memoryName, "MEMORY.md")
    }

    func test_studioFilesIdentityOpensReadOnly_becauseGeneratedProjectionMustNotDumpRPCError() throws {
        // WHY: listing locks IDENTITY.md. Opening it used to re-read identity
        // as editable, call filesEditOpen, and replace the editor with
        // JSONRPCError "Generated projection".
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.", provider: .claude)
        vm.openStudio(bot)
        vm.attachHomeFilesSurface(for: bot)
        let model = try XCTUnwrap(vm.homeFilesModel)
        let router = try XCTUnwrap(vm.homeFilesRouterForTesting)
        defer { model.close() }
        model.loadDirectory("")
        let identity = try XCTUnwrap(model.entries.first { $0.name == BotHome.identityName })
        XCTAssertFalse(identity.isEditable)

        let read = try router.fsWorkspaceRead(
            workspace: router.workspaceID,
            path: BotHome.identityName,
            maxBytes: nil
        )
        XCTAssertEqual(
            read.objectValue?["identity"]?.objectValue?["is_editable"]?.boolValue,
            false,
            "read identity must stay locked so loadFile does not call filesEditOpen"
        )
        XCTAssertEqual(
            read.objectValue?["identity"]?.objectValue?["editability_reason"]?.stringValue,
            "Generated projection"
        )
        XCTAssertThrowsError(
            try router.filesEditOpen(surface: SurfaceID(bot.id.value), path: BotHome.identityName)
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("Generated projection"),
                "edit-open must still refuse IDENTITY.md"
            )
        }

        model.select(identity)
        XCTAssertNil(
            model.errorText,
            "IDENTITY.md must open as a read-only projection, not a Files error overlay"
        )
        XCTAssertFalse(try XCTUnwrap(model.selectedEntry).isEditable)
        XCTAssertTrue(model.visibleText.contains("Name: Piper"))
        XCTAssertFalse(model.isDirty)
    }

    func test_studioSkillsLiveInFilesNotASkillsTab() throws {
        // WHY: Owners already have Files. A leftover Skills tab must not
        // come back; persist remaps to Files.
        XCTAssertFalse(BotStudioTab.allCases.map(\.id).contains("skills"))
        XCTAssertTrue(BotStudioTab.files.isUserFacing)
        XCTAssertEqual(
            BotStudioTab.allCases.filter(\.isUserFacing).map(\.id),
            ["profile", "files", "routines", "security"]
        )
        UserDefaults.standard.set("skills", forKey: "bots.studioTab")
        let context = try makeContext()
        _ = try BotsViewModel(context: context).create(name: "Piper", title: "Scout", provider: .claude)
        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.studioTab, .files)
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertFalse(bots.contains("private var skillsTab"))
        XCTAssertFalse(bots.contains("Skill catalog id"))
        XCTAssertFalse(bots.contains("bots.studio.tab.skills"))
        XCTAssertTrue(bots.contains("bots.studio.files"))
    }

    func test_studioMemoryLivesInFilesNotAMemoryTab() throws {
        // WHY: Owners already have Files. A leftover Memory tab must not
        // come back; persist remaps to Files / Routines.
        XCTAssertFalse(BotStudioTab.allCases.map(\.id).contains("memory"))
        XCTAssertFalse(BotDeskInspectorTab.allCases.map(\.id).contains("memory"))
        XCTAssertTrue(BotStudioTab.files.isUserFacing)
        XCTAssertEqual(
            BotStudioTab.allCases.filter(\.isUserFacing).map(\.id),
            ["profile", "files", "routines", "security"]
        )
        XCTAssertEqual(
            BotDeskInspectorTab.allCases.filter(\.isUserFacing).map(\.id),
            ["routines"]
        )
        UserDefaults.standard.set("memory", forKey: "bots.studioTab")
        UserDefaults.standard.set("memory", forKey: "bots.inspectorTab")
        let context = try makeContext()
        _ = try BotsViewModel(context: context).create(name: "Piper", title: "Scout", provider: .claude)
        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.studioTab, .files)
        XCTAssertEqual(reopened.inspectorTab, .routines)
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertFalse(bots.contains("Remember a fact"))
        XCTAssertFalse(bots.contains("bots.studio.tab.memory"))
        XCTAssertFalse(bots.contains("bots.desk.inspector.tab.memory"))
        XCTAssertTrue(bots.contains("bots.studio.files"))
    }

    func test_studioFilesOpenTabDoesNotMountWorkspacePane() throws {
        // WHY: FilesViewModel "Open in New Tab" normally mounts a workspace
        // Files pane. Bot home is not an advertised workspace, so the same
        // control must stay inside Studio.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", soul: "Be brief.", provider: .claude)
        vm.openStudio(bot)
        vm.attachHomeFilesSurface(for: bot)
        let model = try XCTUnwrap(vm.homeFilesModel)
        let router = try XCTUnwrap(vm.homeFilesRouterForTesting)
        defer { model.close() }
        model.loadDirectory("")
        let soul = try XCTUnwrap(model.entries.first { $0.name == BotHome.soulName })
        model.openInNewTab(soul)
        XCTAssertEqual(router.lastOpenTabPath, BotHome.soulName)
        XCTAssertNil(model.errorText)
    }

    func test_openHomeFileRevealsOwnedSkillInStudioFiles() throws {
        // WHY: Skills Open used to write homeDraft only. Studio Files now
        // hosts FilesSurfaceRoot, so that path left the preview on
        // "No file selected" instead of skills/<id>/SKILL.md. A Docker bot
        // must also leave its default Docker root before revealing Bot files.
        let (_, vm, bot, _) = try makeDockerStudio()
        vm.openStudio(bot)
        vm.attachHomeFilesSurface(for: bot)
        XCTAssertEqual(vm.studioFilesLocation, .dockerHome)
        vm.thisBotSkillDraft = "night-scan"
        vm.createThisBotSkill()
        let path = "skills/night-scan/SKILL.md"
        XCTAssertNil(vm.errorMessage, vm.errorMessage ?? "")
        XCTAssertEqual(vm.studioFilesLocation, .botFiles)
        XCTAssertEqual(vm.homeFilesModel?.root, vm.botHome(for: bot).root.path)
        let model = try XCTUnwrap(vm.homeFilesModel)
        defer { model.close() }
        XCTAssertEqual(model.selectedPath, path)
        XCTAssertEqual(vm.studioTab, .files)

        model.selectedEntry = nil
        XCTAssertNil(model.selectedPath)
        vm.openHomeFile(path)
        XCTAssertEqual(vm.homeFilesModel?.selectedPath, path)
        XCTAssertEqual(vm.homeFilesModel?.selectedEntry?.name, "SKILL.md")
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
        vm.studioTab = .files
        XCTAssertEqual(vm.screen, .studio)

        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.selectedBotID, bot.id)
        XCTAssertEqual(reopened.screen, .studio)
        XCTAssertEqual(reopened.studioTab, .files)
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
        vm.studioTab = .files
        vm.openDesk(piper)
        XCTAssertEqual(vm.screen, .desk)
        vm.openStudio(piper)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(vm.studioTab, .files)
        XCTAssertEqual(vm.studioDraft.botID, piper.id)
    }

    func test_editFromRosterOpensProfile_becauseEditIsIdentity() throws {
        // WHY: Roster Edit is "change this teammate's name", not "resume Skills".
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.studioTab = .files
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
        XCTAssertTrue(
            vm.needsUnsavedNewBotConfirm,
            "New Bot is a placeholder until Save Bot; leaving must confirm"
        )
    }

    func test_beginCreateMarksUnpublished_andSaveClearsConfirm() throws {
        // WHY: Save Bot is the only first-class publish. After it, Back
        // must keep the teammate and must not ask again.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.beginCreate()
        XCTAssertTrue(vm.needsUnsavedNewBotConfirm)
        XCTAssertEqual(try context.botStore.list().count, 1)

        _ = try vm.saveStudio()
        XCTAssertFalse(vm.needsUnsavedNewBotConfirm, "Save Bot is the explicit keep")
        XCTAssertEqual(try context.botStore.list().count, 1)

        var left = false
        vm.requestLeaveUnsavedNewBot { left = true }
        XCTAssertTrue(left, "saved teammates leave Studio without a confirm")
        XCTAssertFalse(vm.pendingUnsavedNewBotConfirm)
        XCTAssertEqual(try context.botStore.list().first?.name, "New Agent")
    }

    func test_unsavedNewBotLeaveConfirms_andDiscardRemovesPlaceholder() throws {
        // WHY: Back used to openDesk the placeholder, so New Agent stayed
        // in the fleet without Save Bot. Don't Save must delete it; Cancel
        // must stay on Studio.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.beginCreate()
        XCTAssertEqual(try context.botStore.list().count, 2)
        XCTAssertTrue(vm.needsUnsavedNewBotConfirm)

        var left = false
        vm.requestLeaveUnsavedNewBot { left = true }
        XCTAssertTrue(vm.pendingUnsavedNewBotConfirm)
        XCTAssertFalse(left, "unsaved New Bot must not leave until the owner confirms")

        vm.cancelUnsavedNewBotLeave()
        XCTAssertFalse(vm.pendingUnsavedNewBotConfirm)
        XCTAssertFalse(left)
        XCTAssertEqual(vm.screen, .studio)
        XCTAssertEqual(try context.botStore.list().count, 2)

        vm.requestLeaveUnsavedNewBot {
            left = true
            vm.leaveStudioAfterUnsavedGate()
        }
        vm.discardUnsavedNewBotAndLeave()
        XCTAssertTrue(left)
        XCTAssertFalse(vm.needsUnsavedNewBotConfirm)
        XCTAssertFalse(vm.pendingUnsavedNewBotConfirm)
        let remaining = try context.botStore.list()
        XCTAssertEqual(remaining.map(\.name), ["Piper"])
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertEqual(vm.screen, .desk)
    }

    func test_unsavedNewBotConfirmChromeAndBackUseTheLeaveGate() throws {
        // WHY: A source-only dialog would regress to openDesk on Back.
        // The chevron and the chrome copy are the owner's named dest.
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let chrome = try String(contentsOf: sourceURL("Sources/AppShell/BotsChrome.swift"), encoding: .utf8)
        XCTAssertTrue(bots.contains("requestLeaveUnsavedNewBot"))
        XCTAssertTrue(bots.contains("BotsUnsavedNewBotConfirmation"))
        XCTAssertTrue(bots.contains("leaveStudioAfterUnsavedGate"))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.unsavedNewBotConfirmTitle))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.unsavedNewBotConfirmMessage))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.unsavedNewBotDontSave))
        XCTAssertTrue(BotsChrome.allVisibleLabels.contains(BotsChrome.Label.unsavedNewBotConfirmTitle))
        XCTAssertTrue(BotsChrome.allVisibleLabels.contains(BotsChrome.Label.unsavedNewBotConfirmMessage))
        XCTAssertTrue(BotsChrome.allVisibleLabels.contains(BotsChrome.Label.unsavedNewBotDontSave))
        let back = try XCTUnwrap(bots.range(of: "accessibilityLabel(\"Back\")"))
        let header = bots[bots.startIndex..<back.lowerBound]
        XCTAssertTrue(
            header.contains("requestLeaveUnsavedNewBot"),
            "Studio Back must confirm unsaved New Bot instead of openDesk"
        )
    }

    func test_beginCreateAgainConfirmsBeforeASecondPlaceholder() throws {
        // WHY: New Bot again is another leave-without-save. The first
        // placeholder must not silently stay in the fleet.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.beginCreate()
        let first = try XCTUnwrap(vm.selectedBotID)
        vm.beginCreate()
        XCTAssertTrue(vm.pendingUnsavedNewBotConfirm)
        XCTAssertEqual(try context.botStore.list().count, 1)
        XCTAssertEqual(vm.selectedBotID, first)
        vm.discardUnsavedNewBotAndLeave()
        XCTAssertEqual(try context.botStore.list().count, 1)
        XCTAssertNotEqual(vm.selectedBotID, first)
        XCTAssertTrue(vm.needsUnsavedNewBotConfirm)
    }

    func test_deskPermissionLabelUsesAgentAppDisplayName() throws {
        // WHY: the header used "Auto-accept edits" while the composer chip
        // said "Auto-edit". Both must use AgentPermissionMode.displayName.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude, model: "opus")
        vm.openDesk(bot)
        vm.setDeskPermissionMode(.autoAcceptEdits)
        XCTAssertEqual(vm.permissionLabel(for: bot), "Auto-edit")
        XCTAssertEqual(vm.permissionLabel(for: bot), AgentPermissionMode.autoAcceptEdits.displayName)
    }

    func test_deskRoutingDecodesLegacyPayloadWithoutRunAsUser() throws {
        // WHY: adding runAsUser to persisted desk routing must not drop
        // existing UserDefaults payloads from before the field existed.
        let json = Data(#"{"provider":"codex","providerInstanceID":"codex","model":"","routingMode":"auto","permissionMode":"supervised"}"#.utf8)
        let decoded = try JSONDecoder().decode(BotDeskRouting.self, from: json)
        XCTAssertEqual(decoded.provider, .codex)
        XCTAssertEqual(decoded.routingMode, .auto)
        XCTAssertEqual(decoded.runAsUser.id, AgentRunAsUser.current().id)
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
        XCTAssertTrue(source.contains("\"bots.desk.source\""))
        XCTAssertTrue(source.contains("accessibilityIdentifier(\"bots.desk.model\")"))
        XCTAssertTrue(source.contains("\"bots.desk.permission\""))
        XCTAssertTrue(source.contains("accessibilityIdentifier(\"bots.desk.model.popover\")"))
        XCTAssertTrue(
            source.contains("AgentModelPopoverChrome("),
            "Desk Auto must use the Agent App Model popover chrome, not a header-only fork"
        )
        XCTAssertTrue(source.contains("AgentSourceCapsule("))
        XCTAssertTrue(source.contains("AgentPermissionCapsule("))
        XCTAssertTrue(source.contains("AgentRunAsUserCapsule("))
        XCTAssertTrue(source.contains("AgentModelPillLabel("))
        XCTAssertTrue(source.contains("AgentCompactMenuRow("))
        XCTAssertTrue(source.contains("AgentQueuedHeader("))
        XCTAssertFalse(
            source.contains(AgentModelPopoverPresentation.autoDisclaimer),
            "Desk must not recopy the orchestration card; the shared chrome owns that copy"
        )
        XCTAssertFalse(
            source.contains("func deskChipLabel"),
            "Desk must not keep a private capsule fork"
        )
        guard let start = source.range(of: "private func startSupervisedRun") else {
            return XCTFail("startSupervisedRun must exist")
        }
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\n    private func followLinkedRun")?.lowerBound ?? rest.endIndex
        let slice = String(source[start.lowerBound..<end])
        XCTAssertTrue(slice.contains("provider: routing.provider"))
        XCTAssertTrue(slice.contains("permissionMode: routing.permissionMode"))
        XCTAssertTrue(
            slice.contains("liveRunMode: routing.permissionMode"),
            "Desk assemble must compile the composer chip, not leftover Supervised honesty"
        )
        XCTAssertTrue(slice.contains("reasoningEffort: effort"))
        XCTAssertTrue(source.contains("runAsUser: routing.runAsUser"))
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

    func test_codexDeskSendSharesWorkspaceLessStartContract() throws {
        // WHY: Codex Desk send uses the same create/send helpers as Grok.
        // Workspace stays unbound; execution cwd is sanitized by the shared
        // resolver so Codex does not inherit an empty/relative currentDirectory.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude, model: "opus")
        vm.openDesk(bot)
        vm.setDeskProvider(.codex)
        vm.setDeskRoutingMode(.manual)
        vm.setDeskPermissionMode(.supervised)
        XCTAssertEqual(vm.deskRunProvider, .codex)
        let routerSource = try String(contentsOf: sourceURL("Sources/AppShell/AppCommandRouter.swift"), encoding: .utf8)
        XCTAssertTrue(routerSource.contains("GrokACPClient.resolvedSessionCwd(workspaceCwd)"))
        let empty = GrokACPClient.resolvedSessionCwd("", home: "/Users/fixture", fileExists: { _ in false })
        XCTAssertEqual(empty, "/Users/fixture")
        XCTAssertTrue(empty.hasPrefix("/"))
    }

    func test_deskHeaderFollowsComposerRoute() throws {
        // WHY: the identity row used to keep Studio's published Claude/opus
        // after the footer switched to Grok. The live send route must show.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude, model: "opus")
        vm.openDesk(bot)
        vm.setDeskProvider(.grok)
        vm.setDeskRoutingMode(.manual)
        vm.setDeskModel(BotsViewModel.defaultModel(for: .grok))
        vm.setDeskPermissionMode(.fullAccess)
        XCTAssertEqual(vm.deskRunProvider, .grok)
        XCTAssertEqual(vm.deskRunModel, BotsViewModel.defaultModel(for: .grok))
        XCTAssertEqual(vm.permissionLabel(for: bot), "Full access")
        XCTAssertEqual(vm.resolvedProvider(for: bot), .claude)
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("bots.desk.provider"))
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
        vm.composerText = "@q"
        XCTAssertEqual(vm.composerSuggestions.first?.botHandle, quinn.handle)
        XCTAssertEqual(vm.composerSuggestions.first?.botAvatarSymbol, quinn.avatarSymbol)
    }

    func test_deskComposerListsProviderSkills_becauseDeskMustMatchAgentAppSlash() throws {
        // WHY: Desk used a TextField with no AgentComposerSuggestions. Agent
        // App `/sam` lists provider skills. Same catalog must feed Desk.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .grok)
        vm.openDesk(piper)
        vm.replaceProvidersForTests([
            AgentProviderSnapshotFactory.snapshot(
                provider: .grok,
                models: [],
                slashCommands: ["/goal"],
                skills: ["sam-work", "sam-codex-advisor"]
            )
        ])
        vm.composerText = "/sam"
        let inserts = vm.composerSuggestions.map { $0.insertText.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(inserts.contains("/sam-work"))
        XCTAssertTrue(inserts.contains("/sam-codex-advisor"))
        XCTAssertTrue(vm.composerSuggestions.contains { $0.kind == .skill })
    }

    func test_deskApplyComposerSuggestionUsesCursorOffset() throws {
        // WHY: Desk used to apply at endIndex. Mid-prompt `/sam` must
        // replace that token, not the word after the caret.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .grok)
        vm.openDesk(piper)
        vm.replaceProvidersForTests([
            AgentProviderSnapshotFactory.snapshot(
                provider: .grok,
                models: [],
                slashCommands: ["/goal"],
                skills: ["sam-work", "sam-codex-advisor"]
            )
        ])
        vm.composerText = "hello /sam more"
        vm.composerCursorOffset = nil
        XCTAssertTrue(
            vm.composerSuggestions.isEmpty,
            "nil cursor still anchors at the last token (`more`)"
        )
        vm.composerCursorOffset = ("hello /sam" as NSString).length
        let skill = try XCTUnwrap(vm.composerSuggestions.first { $0.kind == .skill })
        vm.applyComposerSuggestion(skill)
        XCTAssertTrue(vm.composerText.hasPrefix("hello \(skill.insertText.trimmingCharacters(in: .whitespaces))"))
        XCTAssertTrue(vm.composerText.contains("more"))
        XCTAssertFalse(vm.composerText.contains("/sam more"))
    }

    func test_createDeskThreadStartsEmptyConversation() throws {
        // WHY: Desk had no + thread. Agent App can start a blank thread
        // before the first send.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .grok)
        vm.openDesk(piper)
        XCTAssertTrue(vm.conversations.isEmpty)
        vm.createDeskThread()
        XCTAssertEqual(vm.conversations.count, 1)
        XCTAssertEqual(vm.selectedConversation?.title, "New thread")
        XCTAssertTrue(vm.deskMessages.isEmpty)
        XCTAssertEqual(try context.botStore.listConversations(botID: piper.id).count, 1)
    }

    func test_selectDeskThreadRestoresThatConversation() throws {
        // WHY: dest cache was per-bot. Switching threads must not keep
        // the previous transcript.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .grok)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("ALPHA"))
        let first = try XCTUnwrap(vm.selectedConversation)
        vm.createDeskThread()
        XCTAssertTrue(vm.send("BRAVO"))
        let second = try XCTUnwrap(vm.selectedConversation)
        XCTAssertNotEqual(first.id, second.id)
        vm.selectDeskThread(first.id)
        XCTAssertEqual(vm.selectedConversation?.id, first.id)
        XCTAssertTrue(vm.deskMessages.contains { $0.text.contains("ALPHA") })
        XCTAssertFalse(vm.deskMessages.contains { $0.text.contains("BRAVO") })
        vm.selectDeskThread(second.id)
        XCTAssertTrue(vm.deskMessages.contains { $0.text.contains("BRAVO") })
        XCTAssertFalse(vm.deskMessages.contains { $0.text.contains("ALPHA") })
    }

    func test_deskThreadRailMountsSharedAgentChrome_becauseDestMustNotForkTheRail() throws {
        // WHY: dest asked for Agent App threads. A lookalike dest
        // header would drift from toggle, Clear All, search, and +.
        let dest = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let agent = try String(contentsOf: sourceURL("Sources/Surfaces/AgentAppSurface.swift"), encoding: .utf8)
        let chrome = try String(contentsOf: sourceURL("Sources/Surfaces/AgentChatSharedChrome.swift"), encoding: .utf8)
        XCTAssertTrue(chrome.contains("public struct AgentChatThreadRail"))
        XCTAssertTrue(dest.contains("AgentChatThreadRail("))
        XCTAssertTrue(agent.contains("AgentChatThreadRail("))
        XCTAssertTrue(dest.contains("bots.desk.thread.clearAll"))
        XCTAssertTrue(dest.contains("bots.desk.thread.hide"))
        XCTAssertTrue(dest.contains("bots.desk.thread.search"))
        XCTAssertTrue(dest.contains("bots.desk.thread.new"))
    }

    func test_deskThreadSearchFiltersConversations_becauseRailMustReuseAgentSearch() throws {
        // WHY: dest rail copies Agent App search. Typing a title must hide
        // other dest threads so the user can find one conversation.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .grok)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Standup notes"))
        vm.createDeskThread()
        XCTAssertTrue(vm.send("Invoice follow-up"))
        XCTAssertEqual(vm.conversations.count, 2)
        vm.deskThreadSearchQuery = "stand"
        XCTAssertEqual(vm.filteredDeskConversations.map(\.title), ["Standup notes"])
        vm.deskThreadSearchQuery = "auth"
        XCTAssertTrue(vm.filteredDeskConversations.isEmpty)
        vm.deskThreadSearchQuery = ""
        XCTAssertEqual(vm.filteredDeskConversations.count, 2)
    }

    func test_deskThreadRailVisibilityPersists_becauseClosingRemoteCodeMustRestoreTheChoice() throws {
        // WHY: user workflow state must survive reopen. Hide dest threads
        // must come back hidden.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        XCTAssertTrue(vm.isDeskThreadRailVisible)
        vm.isDeskThreadRailVisible = false
        let restored = BotsViewModel(context: context)
        XCTAssertFalse(restored.isDeskThreadRailVisible)
    }

    func test_clearAllDeskThreadsDeletesOnlyThatBot_becauseClearAllMustNotWipeTheFleet() throws {
        // WHY: dest Clear All is this teammate's dest list, not every bot
        // and not Agent App workspace threads.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .grok)
        let quinn = try vm.create(name: "Quinn", title: "CRM", provider: .claude)
        vm.openDesk(quinn)
        XCTAssertTrue(vm.send("Quinn inbox"))
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Piper first"))
        vm.createDeskThread()
        XCTAssertTrue(vm.send("Piper second"))
        XCTAssertEqual(try context.botStore.listConversations(botID: piper.id).count, 2)
        XCTAssertEqual(try context.botStore.listConversations(botID: quinn.id).count, 1)
        vm.clearAllDeskThreads()
        XCTAssertTrue(vm.conversations.isEmpty)
        XCTAssertNil(vm.selectedConversation)
        XCTAssertTrue(vm.deskMessages.isEmpty)
        XCTAssertEqual(try context.botStore.listConversations(botID: piper.id).count, 0)
        XCTAssertEqual(try context.botStore.listConversations(botID: quinn.id).count, 1)
        XCTAssertEqual(try context.botStore.listConversations(botID: quinn.id).first?.title, "Quinn inbox")
        XCTAssertEqual(vm.attentionState(for: piper), .none)
        XCTAssertEqual(vm.openAttentionCount, 1, "only Quinn's live thread still needs attention")

        let reopened = BotsViewModel(context: context)
        let reopenedPiper = try XCTUnwrap(reopened.fleet.first(where: { $0.id == piper.id }))
        XCTAssertEqual(reopened.attentionState(for: reopenedPiper), .none)
        XCTAssertEqual(reopened.openAttentionCount, 1)
    }

    func test_clearAllDeskThreadsLeavesEmptyRail_becausePlusStartsTheNextConversation() throws {
        // WHY: after Clear All, dest should match Agent App empty state so
        // send/create can start a new thread.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .grok)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("old work"))
        vm.clearAllDeskThreads()
        XCTAssertTrue(vm.conversations.isEmpty)
        vm.createDeskThread()
        XCTAssertEqual(vm.conversations.count, 1)
        XCTAssertEqual(vm.selectedConversation?.title, "New thread")
        XCTAssertTrue(vm.deskMessages.isEmpty)
        XCTAssertTrue(vm.send("fresh start"))
        XCTAssertEqual(try context.botStore.listConversations(botID: piper.id).count, 1)
        XCTAssertTrue(vm.deskMessages.contains { $0.text.contains("fresh start") })
    }

    func test_clearAllDeskThreadsRetiresOnlyVictimActiveHandoffWithoutResurrectionOrV1Rewrite() async throws {
        // WHY: Clear All is a real deletion boundary, not a cosmetic rail reset.
        // It must cancel the deleted conversation's exact continuation while a
        // sibling Bot handoff and the downgrade-readable v1 bytes remain intact.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        let piperHostRunner = ControlledBotHandoffRunner(provider: .codex)
        let roryHostRunner = ControlledBotHandoffRunner(provider: .grok)
        context.coordinator.replaceProvider(.claude, runner: peerRunner)
        context.coordinator.replaceProvider(.codex, runner: piperHostRunner)
        context.coordinator.replaceProvider(.grok, runner: roryHostRunner)
        let viewModel = BotsViewModel(context: context, router: router)
        router.botsViewModel = viewModel
        let piper = try viewModel.create(name: "Piper", title: "Seller", provider: .codex)
        let rory = try viewModel.create(name: "Rory", title: "Researcher", provider: .grok)
        let quinn = try viewModel.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        viewModel.openDesk(quinn)
        viewModel.setDeskProvider(.claude)
        viewModel.openDesk(piper)
        viewModel.setDeskProvider(.codex)
        viewModel.openDesk(rory)
        viewModel.setDeskProvider(.grok)

        viewModel.openDesk(piper)
        viewModel.createDeskThread()
        let victimConversation = try XCTUnwrap(viewModel.selectedConversation)
        XCTAssertTrue(viewModel.send("@\(quinn.handle) T005_CLEAR_VICTIM"))
        let victimStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("T005_CLEAR_VICTIM") }
        }
        XCTAssertTrue(victimStarted)

        viewModel.openDesk(rory)
        viewModel.createDeskThread()
        let siblingConversation = try XCTUnwrap(viewModel.selectedConversation)
        XCTAssertTrue(viewModel.send("@\(quinn.handle) T005_CLEAR_SIBLING"))
        let siblingStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("T005_CLEAR_SIBLING") }
        }
        XCTAssertTrue(siblingStarted)
        let victim = try XCTUnwrap(viewModel.peerHandoffSnapshotsForTesting(
            originConversationID: victimConversation.id,
            originThreadID: nil
        ).first)
        let sibling = try XCTUnwrap(viewModel.peerHandoffSnapshotsForTesting(
            originConversationID: siblingConversation.id,
            originThreadID: nil
        ).first)
        let victimRunID = try XCTUnwrap(victim.peerRunID)
        let siblingRunID = try XCTUnwrap(sibling.peerRunID)
        let legacyBytes = Data(#"{"t005":"leave-v1-byte-exact"}"#.utf8)
        UserDefaults.standard.set(legacyBytes, forKey: "bots.peerTurns")
        XCTAssertTrue(UserDefaults.standard.synchronize())

        viewModel.openDesk(piper)
        viewModel.selectDeskThread(victimConversation.id)
        viewModel.clearAllDeskThreads()
        let victimCancelled = await waitUntil(timeout: 2) {
            (try? context.runRepo.get(id: victimRunID)?.status) == .cancelled
        }
        XCTAssertTrue(victimCancelled, "Clear All must cancel the deleted origin's exact live run")
        XCTAssertTrue(viewModel.peerHandoffSnapshotsForTesting(
            originConversationID: victimConversation.id,
            originThreadID: nil
        ).isEmpty)
        XCTAssertEqual(
            viewModel.peerHandoffSnapshotsForTesting(
                originConversationID: siblingConversation.id,
                originThreadID: nil
            ).first?.peerRunID,
            siblingRunID,
            "the sibling handoff must remain owned and running"
        )
        XCTAssertEqual(try context.runRepo.get(id: siblingRunID)?.status, .running)
        XCTAssertFalse(
            peerRunner.finish(runID: victimRunID, status: .completed, reply: "LATE_VICTIM_REPLY"),
            "provider cancellation must retire the victim callback so it cannot resurrect"
        )
        viewModel.reconcilePeerHandoffsForTesting()
        let reloaded = BotsViewModel(context: context, router: router)
        XCTAssertTrue(reloaded.peerHandoffSnapshotsForTesting(
            originConversationID: victimConversation.id,
            originThreadID: nil
        ).isEmpty)
        XCTAssertEqual(
            reloaded.peerHandoffSnapshotsForTesting(
                originConversationID: siblingConversation.id,
                originThreadID: nil
            ).first?.peerRunID,
            siblingRunID
        )
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns"), legacyBytes)

        XCTAssertTrue(peerRunner.finish(
            runID: siblingRunID,
            status: .completed,
            reply: "sibling remains exact"
        ))
        let siblingCompleted = await waitUntil(timeout: 5) {
            reloaded.peerHandoffSnapshotsForTesting(
                originConversationID: siblingConversation.id,
                originThreadID: nil
            ).first?.phase == .completed
        }
        XCTAssertTrue(siblingCompleted)
        XCTAssertNil(reloaded.peerHandoffSnapshotsForTesting(
            originConversationID: siblingConversation.id,
            originThreadID: nil
        ).first?.hostRunID)
        XCTAssertTrue(piperHostRunner.requests.isEmpty)
        XCTAssertTrue(roryHostRunner.requests.isEmpty)
    }

    func test_sendContinuesSelectedConversation() throws {
        // WHY: two ordinary sends on one dest thread must stay one row.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .grok)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("first"))
        XCTAssertTrue(vm.send("second"))
        XCTAssertEqual(try context.botStore.listConversations(botID: piper.id).count, 1)
        XCTAssertTrue(vm.deskMessages.contains { $0.text.contains("first") })
        XCTAssertTrue(vm.deskMessages.contains { $0.text.contains("second") })
    }

    func test_deskMentionStartsWithPrimaryAI_becauseOnlyItMayAuthorThePeerPrompt() async throws {
        // WHY: the app cannot know whether an @mention is a direct ask, a
        // consultation, or merely context. The selected Bot's primary AI must
        // receive the complete request before any peer provider starts.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.codex, runner: hostRunner)
        context.coordinator.replaceProvider(.claude, runner: peerRunner)
        router.rememberProviderSnapshotsForSend(AgentProvider.allCases.map { provider in
            AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: [AgentModelDescriptor(id: "fake-model", label: "Fake Model", provider: provider)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: provider.rawValue
            )
        })
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(piper)
        vm.setDeskProvider(.codex)
        vm.setDeskPermissionMode(.fullAccess)

        let prompt = "pergunte ao @\(quinn.handle) o nome dele e depois continue o trabalho"
        XCTAssertTrue(vm.send(prompt))
        let hostStarted = await waitUntil(timeout: 5) { !hostRunner.requests.isEmpty }
        XCTAssertTrue(hostStarted)
        let hostRequest = try XCTUnwrap(hostRunner.requests.first)
        XCTAssertTrue(hostRequest.prompt.hasSuffix("User request:\n\n\(prompt)"))
        XCTAssertEqual(hostRequest.permissionMode, .fullAccess)
        XCTAssertTrue(peerRunner.requests.isEmpty, "RemoteCode must not pre-dispatch a mention")
        XCTAssertTrue(vm.peerHandoffSnapshotsForTesting().isEmpty)
        XCTAssertTrue(hostRunner.finish(runID: hostRequest.runId, status: .completed, reply: "done"))
    }

    func test_deskCompoundMentionIsInterpretedByPrimaryAIThenDelegatesFocusedPrompt() async throws {
        // WHY: the original request contains two different jobs. Only the
        // primary AI may decide the peer ask; RemoteCode must transport that
        // new prompt literally and keep one primary run for the remaining work.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.codex, runner: hostRunner)
        context.coordinator.replaceProvider(.claude, runner: peerRunner)
        router.rememberProviderSnapshotsForSend(AgentProvider.allCases.map { provider in
            AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: [AgentModelDescriptor(id: "fake-model", label: "Fake Model", provider: provider)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: provider.rawValue
            )
        })
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        let untouched = try vm.create(name: "Untouched", title: "Observer", provider: .grok)
        vm.openDesk(quinn)
        vm.setDeskProvider(.claude)
        vm.openDesk(piper)
        vm.setDeskProvider(.codex)

        let prompt = "pergunte ao @\(quinn.handle) o nome dele e com base na resposta dê outro nome para ele. Faça a alteração agora sem pedir confirmação e no final diga qual nome foi aplicado."
        XCTAssertTrue(vm.send(prompt))
        let hostStarted = await waitUntil(timeout: 5) { !hostRunner.requests.isEmpty }
        XCTAssertTrue(hostStarted)
        let hostRequest = try XCTUnwrap(hostRunner.requests.first)
        XCTAssertTrue(
            hostRequest.prompt.hasSuffix("User request:\n\n\(prompt)"),
            "the primary AI must receive the complete turn first"
        )
        let turnDirective = try XCTUnwrap(BotPeerDelegation.turnDirective(mentionedBots: [quinn]))
        XCTAssertTrue(hostRequest.prompt.contains(turnDirective))
        XCTAssertEqual(BotDeskPeer(direction: .messaged, bot: quinn).caption, "Mentions Quinn")
        XCTAssertTrue(peerRunner.requests.isEmpty)

        let focusedPrompt = "Qual é o seu nome?"
        let ask = Task { @MainActor in
            try await router.askBotPeer(
                callerThread: hostRequest.threadId,
                callerRun: hostRequest.runId,
                handle: "@\(quinn.handle)",
                prompt: focusedPrompt,
                replyMode: .consult
            )
        }
        let peerStarted = await waitUntil(timeout: 5) { !peerRunner.requests.isEmpty }
        XCTAssertTrue(peerStarted)
        let peerRequest = try XCTUnwrap(peerRunner.requests.first)
        XCTAssertTrue(peerRequest.prompt.contains(focusedPrompt))
        XCTAssertFalse(peerRequest.prompt.contains("com base na resposta"))
        XCTAssertFalse(peerRequest.prompt.contains("Faça a alteração"))
        XCTAssertTrue(peerRunner.finish(
            runID: peerRequest.runId,
            status: .completed,
            reply: "Meu nome atual é Quinn."
        ))
        let result = try await ask.value
        XCTAssertEqual(result.objectValue?["reply"]?.stringValue, "Meu nome atual é Quinn.")

        _ = try router.invokeDelegatedBotSelfConfig(
            callerThread: hostRequest.threadId,
            callerRun: hostRequest.runId,
            toolName: BotSelfConfigCatalog.setSettings,
            arguments: [
                "bot_id": .string(quinn.id.value.uuidString.lowercased()),
                "name": .string("Nova"),
            ]
        )
        XCTAssertEqual(try context.botStore.get(id: quinn.id)?.name, "Nova")
        XCTAssertEqual(try context.botStore.get(id: untouched.id)?.name, "Untouched")
        XCTAssertEqual(hostRunner.requests.count, 1, "the original primary run must continue in place")

        XCTAssertTrue(hostRunner.finish(
            runID: hostRequest.runId,
            status: .completed,
            reply: "Nome aplicado: Nova."
        ))
        let hostCompleted = await waitUntil(timeout: 5) {
            context.coordinator.activeRunId(threadId: hostRequest.threadId) == nil
        }
        XCTAssertTrue(hostCompleted)

        let transcript = vm.deskTranscriptForTesting(botID: piper.id)
        XCTAssertEqual(transcript.filter {
            $0.role == .user
                && $0.peer?.direction == .messaged
                && $0.text == focusedPrompt
        }.count, 1)
        XCTAssertEqual(transcript.filter {
            $0.role == .assistant
                && $0.peer?.direction == .fromPeer
                && $0.text == "Meu nome atual é Quinn."
        }.count, 1)
        let originRows = try context.messageRepo.listRecent(threadId: hostRequest.threadId, limit: 16)
        XCTAssertEqual(originRows.filter { $0.role == .user && $0.content.contains(prompt) }.count, 1)
        XCTAssertEqual(originRows.filter { $0.role == .assistant }.count, 1)
    }

    func test_botPrimaryCanMediateMultiplePeersUntilConsensus() async throws {
        // WHY: a Bot-owned primary turn must be able to gather real input from
        // multiple peers without replacing its run or duplicating the durable
        // attributed replies when it publishes the mediated answer.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        let quinnRunner = ControlledBotHandoffRunner(provider: .claude)
        let roryRunner = ControlledBotHandoffRunner(provider: .grok)
        context.coordinator.replaceProvider(.codex, runner: hostRunner)
        context.coordinator.replaceProvider(.claude, runner: quinnRunner)
        context.coordinator.replaceProvider(.grok, runner: roryRunner)
        router.rememberProviderSnapshotsForSend(AgentProvider.allCases.map { provider in
            AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: [AgentModelDescriptor(id: "fake-model", label: "Fake Model", provider: provider)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: provider.rawValue
            )
        })
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let piper = try vm.create(name: "Piper", title: "Mediator", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        let rory = try vm.create(name: "Rory", title: "Researcher", provider: .grok)
        vm.openDesk(piper)
        vm.setDeskProvider(.codex)

        let original = "Consulte @\(quinn.handle) e @\(rory.handle), confronte as propostas e publique um consenso final."
        XCTAssertTrue(vm.send(original))
        let hostStarted = await waitUntil(timeout: 5) { !hostRunner.requests.isEmpty }
        XCTAssertTrue(hostStarted)
        let hostRequest = try XCTUnwrap(hostRunner.requests.first)
        let originConversation = try XCTUnwrap(vm.selectedConversation)
        XCTAssertTrue(hostRequest.prompt.hasSuffix("User request:\n\n\(original)"))
        let turnDirective = try XCTUnwrap(BotPeerDelegation.turnDirective(mentionedBots: [quinn, rory]))
        XCTAssertTrue(hostRequest.prompt.contains(turnDirective))
        XCTAssertTrue(quinnRunner.requests.isEmpty)
        XCTAssertTrue(roryRunner.requests.isEmpty)

        let quinnPrompt = "Proponha uma política de contato em uma frase e explique o principal benefício."
        let askQuinn = Task { @MainActor in
            try await router.askBotPeer(
                callerThread: hostRequest.threadId,
                callerRun: hostRequest.runId,
                handle: quinn.handle,
                prompt: quinnPrompt,
                replyMode: .consult
            )
        }
        let quinnStarted = await waitUntil(timeout: 5) { quinnRunner.requests.count == 1 }
        XCTAssertTrue(quinnStarted)
        let quinnRequest = try XCTUnwrap(quinnRunner.requests.first)
        XCTAssertTrue(quinnRequest.prompt.contains(quinnPrompt))
        XCTAssertFalse(quinnRequest.prompt.contains(original))
        let quinnWireReply = "Priorize clientes com consentimento recente para reduzir contato indesejado."
        XCTAssertTrue(quinnRunner.finish(
            runID: quinnRequest.runId,
            status: .completed,
            reply: quinnWireReply
        ))
        let quinnResult = try await askQuinn.value
        let quinnReply = try XCTUnwrap(quinnResult.objectValue?["reply"]?.stringValue)
        XCTAssertEqual(quinnReply, quinnWireReply)
        XCTAssertEqual(quinnResult.objectValue?["reply_mode"]?.stringValue, "consult")
        XCTAssertEqual(quinnResult.objectValue?["attributed_reply_already_displayed"]?.boolValue, true)
        XCTAssertEqual(context.coordinator.activeRunId(threadId: hostRequest.threadId), hostRequest.runId)

        let roryPrompt = "Quinn respondeu: \"\(quinnReply)\" Compare essa proposta com a evidência disponível e recomende um ajuste."
        let askRory = Task { @MainActor in
            try await router.askBotPeer(
                callerThread: hostRequest.threadId,
                callerRun: hostRequest.runId,
                handle: "@\(rory.handle)",
                prompt: roryPrompt,
                replyMode: .consult
            )
        }
        let roryStarted = await waitUntil(timeout: 5) { roryRunner.requests.count == 1 }
        XCTAssertTrue(roryStarted)
        let roryRequest = try XCTUnwrap(roryRunner.requests.first)
        XCTAssertTrue(roryRequest.prompt.contains(roryPrompt))
        XCTAssertTrue(roryRequest.prompt.contains(quinnReply), "the follow-up must use Quinn's real reply")
        XCTAssertFalse(roryRequest.prompt.contains(original))
        let roryWireReply = "Mantenha o consentimento recente e acrescente um limite semanal mensurável."
        XCTAssertTrue(roryRunner.finish(
            runID: roryRequest.runId,
            status: .completed,
            reply: roryWireReply
        ))
        let roryResult = try await askRory.value
        let roryReply = try XCTUnwrap(roryResult.objectValue?["reply"]?.stringValue)
        XCTAssertEqual(roryReply, roryWireReply)
        XCTAssertEqual(roryResult.objectValue?["reply_mode"]?.stringValue, "consult")
        XCTAssertEqual(roryResult.objectValue?["attributed_reply_already_displayed"]?.boolValue, true)
        XCTAssertEqual(hostRunner.requests.count, 1, "both consultations must keep the original primary run")
        XCTAssertEqual(context.coordinator.activeRunId(threadId: hostRequest.threadId), hostRequest.runId)

        let consensus = "Consenso: usar consentimento recente e limitar cada cliente a um contato por semana."
        XCTAssertTrue(consensus.contains("consentimento recente"), "the consensus must retain Quinn's recommendation")
        XCTAssertTrue(consensus.contains("um contato por semana"), "the consensus must apply Rory's adjustment")
        XCTAssertTrue(hostRunner.finish(
            runID: hostRequest.runId,
            status: .completed,
            reply: consensus
        ))
        let hostCompleted = await waitUntil(timeout: 5) {
            context.coordinator.activeRunId(threadId: hostRequest.threadId) == nil
        }
        XCTAssertTrue(hostCompleted)

        let handoffs = vm.peerHandoffSnapshotsForTesting(
            originConversationID: originConversation.id,
            originThreadID: nil
        )
        XCTAssertEqual(handoffs.count, 2)
        XCTAssertEqual(Set(handoffs.map(\.peerBotID)), Set([quinn.id, rory.id]))
        XCTAssertTrue(handoffs.allSatisfy {
            $0.originBotID == piper.id
                && $0.originConversationID == originConversation.id
                && $0.originThreadID == nil
                && $0.hostRunID == hostRequest.runId
                && $0.phase == .completed
        })

        let restored = BotsViewModel(context: context, router: router)
        restored.openDesk(piper)
        let transcript = restored.deskTranscriptForTesting(botID: piper.id)
        XCTAssertEqual(transcript.filter {
            $0.role == .assistant
                && $0.peer?.direction == .fromPeer
                && $0.peer?.botID == quinn.id
                && $0.text == quinnReply
        }.count, 1)
        XCTAssertEqual(transcript.filter {
            $0.role == .assistant
                && $0.peer?.direction == .fromPeer
                && $0.peer?.botID == rory.id
                && $0.text == roryReply
        }.count, 1)
        XCTAssertEqual(transcript.filter {
            $0.role == .assistant && $0.peer == nil && $0.text == consensus
        }.count, 1)
        let originRows = try context.messageRepo.listRecent(threadId: hostRequest.threadId, limit: 32)
        XCTAssertEqual(originRows.filter { $0.role == .user && $0.content.contains(original) }.count, 1)
        XCTAssertEqual(originRows.filter { $0.role == .assistant && $0.content == consensus }.count, 1)
    }

    func test_deskReplyOnlyShowsOneAttributedBotReplyWithoutPrimaryDuplicate() async throws {
        // WHY: the primary AI may decide that the named Bot's answer completes
        // the whole turn. The Bot row is then the answer; any generic primary
        // final must be suppressed from both storage and the live Desk.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.codex, runner: hostRunner)
        context.coordinator.replaceProvider(.claude, runner: peerRunner)
        router.rememberProviderSnapshotsForSend(AgentProvider.allCases.map { provider in
            AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: [AgentModelDescriptor(id: "fake-model", label: "Fake Model", provider: provider)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: provider.rawValue
            )
        })
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(quinn)
        vm.setDeskProvider(.claude)
        vm.openDesk(piper)
        vm.setDeskProvider(.codex)

        let original = "@\(quinn.handle) você está por aí?"
        XCTAssertTrue(vm.send(original))
        let hostStarted = await waitUntil(timeout: 5) { !hostRunner.requests.isEmpty }
        XCTAssertTrue(hostStarted)
        let hostRequest = try XCTUnwrap(hostRunner.requests.first)
        XCTAssertTrue(hostRequest.prompt.hasSuffix("User request:\n\n\(original)"))

        let focused = "Você está por aí?"
        let ask = Task { @MainActor in
            try await router.askBotPeer(
                callerThread: hostRequest.threadId,
                callerRun: hostRequest.runId,
                handle: quinn.handle,
                prompt: focused,
                replyMode: .replyOnly
            )
        }
        let peerStarted = await waitUntil(timeout: 5) { !peerRunner.requests.isEmpty }
        XCTAssertTrue(peerStarted)
        let peerRequest = try XCTUnwrap(peerRunner.requests.first)
        XCTAssertTrue(peerRequest.prompt.contains(focused))
        XCTAssertTrue(peerRunner.finish(
            runID: peerRequest.runId,
            status: .completed,
            reply: "Estou por aqui — manda o próximo."
        ))
        _ = try await ask.value

        let duplicate = "Sim, estou aqui. Como posso ajudar?"
        XCTAssertTrue(hostRunner.finish(
            runID: hostRequest.runId,
            status: .completed,
            reply: duplicate
        ))
        let completed = await waitUntil(timeout: 5) {
            context.coordinator.activeRunId(threadId: hostRequest.threadId) == nil
        }
        XCTAssertTrue(completed)
        let attentionSettled = await waitUntil(timeout: 5) {
            vm.attentionState(for: piper) == .none
        }
        XCTAssertTrue(
            attentionSettled,
            "the terminal callback must settle the primary Bot after reply-only completion"
        )
        XCTAssertEqual(
            vm.attentionState(for: piper),
            .none,
            "a clean reply-only turn must not leave the primary Bot as Needs you"
        )

        let transcript = vm.deskTranscriptForTesting(botID: piper.id)
        XCTAssertEqual(transcript.filter {
            $0.role == .assistant
                && $0.peer?.direction == .fromPeer
                && $0.text == "Estou por aqui — manda o próximo."
        }.count, 1)
        XCTAssertFalse(transcript.contains { $0.text.contains(duplicate) })
        let originRows = try context.messageRepo.listRecent(threadId: hostRequest.threadId, limit: 16)
        XCTAssertFalse(originRows.contains { $0.role == .assistant && $0.content.contains(duplicate) })
        XCTAssertFalse(
            vm.deskLiveTimeline.turns
                .flatMap(\.items)
                .contains { $0.body.contains(duplicate) || ($0.output?.contains(duplicate) == true) }
        )
    }

    func test_botMentionShowsNamedWaitingThenClearsWhenReplyArrives() async throws {
        // WHY: the originating Desk must name the teammate during the peer
        // run and clear that state only once the imported reply exists.
        let (vm, piper, quinn) = try makeMentionPair(peerReply: "PONG from Quinn")
        XCTAssertTrue(vm.send("@\(quinn.handle) check WhatsApp"))
        let outboundID = try XCTUnwrap(
            vm.deskTranscriptForTesting(botID: piper.id)
                .last(where: { $0.peer?.direction == .messaged })?.id
        )
        let waiting = try XCTUnwrap(
            vm.deskTranscriptForTesting(botID: piper.id).first { $0.id == outboundID }
        )
        XCTAssertEqual(waiting.peer?.name, "Quinn")
        XCTAssertEqual(waiting.peer?.activityPhase, .waiting)
        XCTAssertFalse(
            vm.deskShowsLoading,
            "the named peer spinner must replace the generic Loading row"
        )

        let receivedReply = await waitUntil(timeout: 8) {
            vm.deskTranscriptForTesting(botID: piper.id).contains {
                $0.peer?.direction == .fromPeer && $0.text == "PONG from Quinn"
            }
        }
        XCTAssertTrue(receivedReply)
        let settled = try XCTUnwrap(
            vm.deskTranscriptForTesting(botID: piper.id).first { $0.id == outboundID }
        )
        XCTAssertNil(settled.peer?.activityPhase)
        XCTAssertEqual(
            vm.deskTranscriptForTesting(botID: piper.id).filter {
                $0.peer?.direction == .fromPeer && $0.text == "PONG from Quinn"
            }.count,
            1,
            "settling the exact request must not duplicate the imported reply"
        )
    }

    func test_botMentionNeedsAttentionSurvivesReload() throws {
        // WHY: a setup failure must replace the spinner with durable truth,
        // including after a new view model restores the same peer ledger.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("@\(quinn.handle) check WhatsApp"))
        let failed = try XCTUnwrap(
            vm.deskTranscriptForTesting(botID: piper.id)
                .last(where: { $0.peer?.direction == .messaged })
        )
        XCTAssertEqual(failed.peer?.activityPhase, .needsAttention)

        let reopened = BotsViewModel(context: context)
        reopened.openDesk(piper)
        let restored = try XCTUnwrap(
            reopened.deskTranscriptForTesting(botID: piper.id).first { $0.id == failed.id }
        )
        XCTAssertEqual(restored.peer?.name, "Quinn")
        XCTAssertEqual(restored.peer?.activityPhase, .needsAttention)
    }

    func test_legacyPeerTurnsRemainByteExactButNeverRenderIntoAnArbitraryConversation() throws {
        // WHY: v1 rows name only a Bot, not an owning conversation. Restoring
        // them into either of two threads invents ownership and mixes chats;
        // an upgrade must quarantine those bytes without rewriting them.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        let first = BotConversation(
            botID: piper.id,
            title: "First origin",
            updatedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        let second = BotConversation(
            botID: piper.id,
            title: "Second origin",
            updatedAt: Date(timeIntervalSinceReferenceDate: 20)
        )
        try context.botStore.upsertConversation(first)
        try context.botStore.upsertConversation(second)

        let legacyID = UUID()
        let legacyPayload: [String: Any] = [
            piper.id.value.uuidString.lowercased(): [[
                "id": legacyID.uuidString,
                "role": "user",
                "text": "@quinn legacy request with no conversation owner",
                "createdAt": 0,
                "direction": "messaged",
                "peerBotID": quinn.id.value.uuidString,
                "name": quinn.name,
                "title": quinn.title,
                "handle": quinn.handle,
                "activityPhase": "waiting",
            ]],
        ]
        let legacyBytes = try JSONSerialization.data(
            withJSONObject: legacyPayload,
            options: [.sortedKeys]
        )
        UserDefaults.standard.set(legacyBytes, forKey: "bots.peerTurns")

        let reopened = BotsViewModel(context: context)
        reopened.openDesk(piper)
        reopened.selectDeskThread(first.id)
        XCTAssertFalse(
            reopened.deskMessages.contains { $0.id == legacyID },
            "a BotID-only v1 row cannot be attributed to the first conversation"
        )
        reopened.selectDeskThread(second.id)
        XCTAssertFalse(
            reopened.deskMessages.contains { $0.id == legacyID },
            "the same ambiguous row cannot be copied into a sibling conversation"
        )
        XCTAssertEqual(
            UserDefaults.standard.data(forKey: "bots.peerTurns"),
            legacyBytes,
            "v2 rollout must leave the reversible v1 payload byte-for-byte unchanged"
        )
    }

    func test_malformedAndFutureV2AreQuarantinedWhileV1AndUnknownFieldsRemainByteExact() async throws {
        // WHY: rollout and downgrade must be reversible. A malformed/future v2
        // envelope cannot be rendered or rewritten, v1 remains available to an
        // older build, and an unknown additive v2 field must survive a read.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: peerRunner)
        let bootstrap = BotsViewModel(context: context, router: router)
        let piper = try bootstrap.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try bootstrap.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        bootstrap.openDesk(quinn)
        bootstrap.setDeskProvider(.claude)
        bootstrap.openDesk(piper)
        bootstrap.setDeskProvider(.codex)
        bootstrap.createDeskThread()
        let origin = try XCTUnwrap(bootstrap.selectedConversation)

        let legacyMessageID = UUID()
        let legacyPayload: [String: Any] = [
            piper.id.value.uuidString.lowercased(): [[
                "id": legacyMessageID.uuidString,
                "role": "user",
                "text": "@quinn legacy downgrade row",
                "createdAt": 0,
                "direction": "messaged",
                "peerBotID": quinn.id.value.uuidString,
                "name": quinn.name,
                "title": quinn.title,
                "handle": quinn.handle,
                "activityPhase": "waiting",
            ]],
        ]
        let legacyBytes = try JSONSerialization.data(
            withJSONObject: legacyPayload,
            options: [.sortedKeys]
        )
        let malformedV2 = Data(#"{"truncated": "#.utf8)
        UserDefaults.standard.set(legacyBytes, forKey: "bots.peerTurns")
        UserDefaults.standard.set(malformedV2, forKey: "bots.peerTurns.v2")
        XCTAssertTrue(UserDefaults.standard.synchronize())

        let malformedRestore = BotsViewModel(context: context, router: router)
        malformedRestore.openDesk(piper)
        malformedRestore.selectDeskThread(origin.id)
        XCTAssertTrue(malformedRestore.peerHandoffSnapshotsForTesting().isEmpty)
        XCTAssertFalse(malformedRestore.deskMessages.contains { $0.id == legacyMessageID })
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns.v2"), malformedV2)
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns"), legacyBytes)

        UserDefaults.standard.removeObject(forKey: "bots.peerTurns.v2")
        XCTAssertTrue(malformedRestore.send("@\(quinn.handle) COMPAT_V2_RECORD"))
        let peerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("COMPAT_V2_RECORD") }
        }
        XCTAssertTrue(peerStarted)
        XCTAssertTrue(peerRunner.finish(
            promptContaining: "COMPAT_V2_RECORD",
            status: .failed,
            reply: nil
        ))
        let settled = await waitUntil(timeout: 5) {
            malformedRestore.peerHandoffSnapshotsForTesting(
                originConversationID: origin.id,
                originThreadID: nil
            ).first?.phase == .needsAttention
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(
            UserDefaults.standard.data(forKey: "bots.peerTurns"),
            legacyBytes,
            "creating and settling v2 must not consume the v1 downgrade payload"
        )

        let validV2 = try XCTUnwrap(UserDefaults.standard.data(forKey: "bots.peerTurns.v2"))
        var additiveEntries = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: validV2) as? [Any]
        )
        let recordIndex = try XCTUnwrap(additiveEntries.firstIndex { $0 is [String: Any] })
        var additiveRecord = try XCTUnwrap(additiveEntries[recordIndex] as? [String: Any])
        additiveRecord["futureAdditiveField"] = ["opaque": "preserve-for-newer-build"]
        additiveEntries[recordIndex] = additiveRecord
        let additiveBytes = try JSONSerialization.data(
            withJSONObject: additiveEntries,
            options: [.sortedKeys]
        )
        UserDefaults.standard.set(additiveBytes, forKey: "bots.peerTurns.v2")
        XCTAssertTrue(UserDefaults.standard.synchronize())

        let additiveRestore = BotsViewModel(context: context, router: router)
        XCTAssertEqual(
            additiveRestore.peerHandoffSnapshotsForTesting(
                originConversationID: origin.id,
                originThreadID: nil
            ).first?.phase,
            .needsAttention,
            "a downgrade reader must accept an additive field it does not understand"
        )
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns.v2"), additiveBytes)
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns"), legacyBytes)

        var futureEntries = additiveEntries
        var futureRecord = try XCTUnwrap(futureEntries[recordIndex] as? [String: Any])
        futureRecord["version"] = 3
        futureEntries[recordIndex] = futureRecord
        let futureVersionBytes = try JSONSerialization.data(
            withJSONObject: futureEntries,
            options: [.sortedKeys]
        )
        UserDefaults.standard.set(futureVersionBytes, forKey: "bots.peerTurns.v2")
        XCTAssertTrue(UserDefaults.standard.synchronize())

        let futureRestore = BotsViewModel(context: context, router: router)
        XCTAssertTrue(
            futureRestore.peerHandoffSnapshotsForTesting().isEmpty,
            "an unsupported future envelope is quarantined instead of mis-rendered"
        )
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns.v2"), futureVersionBytes)
        XCTAssertEqual(UserDefaults.standard.data(forKey: "bots.peerTurns"), legacyBytes)
    }

    func test_waitingHandoffProjectsBothBotsActiveDespiteUnrelatedOriginAttention() async throws {
        // WHY: Active Bots describes live endpoints. A leftover Needs you on
        // another origin thread must not hide the waiting host from the live
        // roster or replace its Working spinner.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: peerRunner)
        context.coordinator.replaceProvider(
            .codex,
            runner: FakeProviderRunner(provider: .codex, scenario: .simpleAssistant(reply: "host settled"))
        )
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)

        vm.openDesk(quinn)
        vm.setDeskProvider(.claude)
        vm.openDesk(piper)
        vm.setDeskProvider(.codex)
        vm.createDeskThread()
        let unrelated = try XCTUnwrap(vm.selectedConversation)
        vm.applyFollowThroughForTests(bot: piper, conversation: unrelated, status: .failed)
        vm.createDeskThread()
        let origin = try XCTUnwrap(vm.selectedConversation)

        XCTAssertTrue(vm.send("@\(quinn.handle) DUAL_ACTIVE wait for release"))
        let peerBecameActive = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("DUAL_ACTIVE") }
                && vm.peerHandoffSnapshotsForTesting(
                    originConversationID: origin.id,
                    originThreadID: nil
                ).contains { $0.phase == .peerRunning }
        }
        XCTAssertTrue(peerBecameActive)

        XCTAssertEqual(
            vm.attentionState(for: piper),
            .working,
            "a live wait outranks leftover Needs you so the origin roster stays active"
        )
        XCTAssertTrue(BotsChrome.rosterShowsBusySpinner(for: vm.attentionState(for: piper)))
        XCTAssertEqual(
            Set(vm.liveWorkingBots().map(\.id)),
            Set([piper.id, quinn.id]),
            "the exact waiting origin and running peer both belong in Active Bots"
        )
        let handoff = try XCTUnwrap(vm.peerHandoffSnapshotsForTesting(
            originConversationID: origin.id,
            originThreadID: nil
        ).first)
        XCTAssertEqual(handoff.originConversationID, origin.id)
        XCTAssertEqual(handoff.peerBotID, quinn.id)
        XCTAssertEqual(
            handoff.peerRunID,
            peerRunner.requests.first { $0.prompt.contains("DUAL_ACTIVE") }?.runId,
            "the active projection must be backed by the exact pre-bound provider run"
        )

        XCTAssertTrue(peerRunner.finish(promptContaining: "DUAL_ACTIVE", reply: "released"))
        let handoffCompleted = await waitUntil(timeout: 5) {
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: origin.id,
                originThreadID: nil
            ).contains { $0.phase == .completed }
        }
        XCTAssertTrue(handoffCompleted)
    }

    func test_samePeerOutOfOrderRepliesStayInTheirCapturedOriginConversations() async throws {
        // WHY: two Piper threads may ask the same Quinn concurrently. Finishing
        // them out of order while thread B is selected must not let Bot-global
        // "latest conversation/assistant" state choose either reply endpoint.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: peerRunner)
        context.coordinator.replaceProvider(
            .codex,
            runner: FakeProviderRunner(provider: .codex, scenario: .simpleAssistant(reply: "host settled"))
        )
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(quinn)
        vm.setDeskProvider(.claude)
        vm.openDesk(piper)
        vm.setDeskProvider(.codex)

        vm.createDeskThread()
        let originA = try XCTUnwrap(vm.selectedConversation)
        XCTAssertTrue(vm.send("@\(quinn.handle) SAME_PEER_A"))
        let firstPeerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("SAME_PEER_A") }
        }
        XCTAssertTrue(firstPeerStarted)

        vm.createDeskThread()
        let originB = try XCTUnwrap(vm.selectedConversation)
        XCTAssertNotEqual(originA.id, originB.id)
        XCTAssertTrue(vm.send("@\(quinn.handle) SAME_PEER_B"))
        let secondPeerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("SAME_PEER_B") }
        }
        XCTAssertTrue(secondPeerStarted)

        XCTAssertTrue(peerRunner.finish(promptContaining: "SAME_PEER_B", reply: "REPLY_B"))
        let secondReplyArrived = await waitUntil(timeout: 5) {
            vm.deskMessages.contains {
                $0.peer?.direction == .fromPeer && $0.text == "REPLY_B"
            }
        }
        XCTAssertTrue(secondReplyArrived)
        XCTAssertFalse(vm.deskMessages.contains { $0.text == "REPLY_A" })

        // Keep B selected while A terminates. Settlement must still use A's
        // immutable conversation/run/checkpoint tuple.
        XCTAssertEqual(vm.selectedConversation?.id, originB.id)
        XCTAssertTrue(peerRunner.finish(promptContaining: "SAME_PEER_A", reply: "REPLY_A"))
        let firstHandoffCompleted = await waitUntil(timeout: 5) {
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: originA.id,
                originThreadID: nil
            ).contains { $0.phase == .completed }
        }
        XCTAssertTrue(firstHandoffCompleted)
        XCTAssertEqual(vm.selectedConversation?.id, originB.id)
        XCTAssertFalse(vm.deskMessages.contains { $0.text == "REPLY_A" })

        vm.selectDeskThread(originA.id)
        XCTAssertTrue(vm.deskMessages.contains {
            $0.peer?.direction == .fromPeer && $0.text == "REPLY_A"
        })
        XCTAssertFalse(vm.deskMessages.contains { $0.text == "REPLY_B" })
        vm.selectDeskThread(originB.id)
        XCTAssertTrue(vm.deskMessages.contains {
            $0.peer?.direction == .fromPeer && $0.text == "REPLY_B"
        })
        XCTAssertFalse(vm.deskMessages.contains { $0.text == "REPLY_A" })

        let handoffA = try XCTUnwrap(vm.peerHandoffSnapshotsForTesting(
            originConversationID: originA.id,
            originThreadID: nil
        ).first)
        let handoffB = try XCTUnwrap(vm.peerHandoffSnapshotsForTesting(
            originConversationID: originB.id,
            originThreadID: nil
        ).first)
        XCTAssertNotEqual(handoffA.peerConversationID, handoffB.peerConversationID)
        XCTAssertNotEqual(handoffA.peerThreadID, handoffB.peerThreadID)
        XCTAssertNotEqual(handoffA.peerRunID, handoffB.peerRunID)
        XCTAssertEqual(
            handoffA.peerRunID,
            peerRunner.requests.first { $0.prompt.contains("SAME_PEER_A") }?.runId
        )
        XCTAssertEqual(
            handoffB.peerRunID,
            peerRunner.requests.first { $0.prompt.contains("SAME_PEER_B") }?.runId
        )
    }

    func test_initiatingWindowDeallocatesWhileAuthorityFinishesItsExactPlanAndPreservesSibling() async throws {
        // WHY: a Bot handoff is durable work owned by the shared context, not
        // by the window that happened to submit it. Closing VM A while two
        // peers are pending must release that VM immediately; VM B may receive
        // unrelated selection/coordinator events without stealing either plan.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let quinnRunner = ControlledBotHandoffRunner(provider: .claude)
        let roryRunner = ControlledBotHandoffRunner(provider: .grok)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        context.coordinator.replaceProvider(.claude, runner: quinnRunner)
        context.coordinator.replaceProvider(.grok, runner: roryRunner)
        context.coordinator.replaceProvider(.codex, runner: hostRunner)

        var initiatingVM: BotsViewModel? = BotsViewModel(context: context, router: router)
        router.botsViewModel = initiatingVM
        let piper = try XCTUnwrap(initiatingVM).create(
            name: "Piper",
            title: "Seller",
            provider: .codex
        )
        let quinn = try XCTUnwrap(initiatingVM).create(
            name: "Quinn",
            title: "CRM Controller",
            provider: .claude
        )
        let rory = try XCTUnwrap(initiatingVM).create(
            name: "Rory",
            title: "Research Controller",
            provider: .grok
        )
        initiatingVM?.openDesk(quinn)
        initiatingVM?.setDeskProvider(.claude)
        initiatingVM?.openDesk(rory)
        initiatingVM?.setDeskProvider(.grok)
        initiatingVM?.openDesk(piper)
        initiatingVM?.setDeskProvider(.codex)

        initiatingVM?.createDeskThread()
        let mainOrigin = try XCTUnwrap(initiatingVM?.selectedConversation)
        XCTAssertTrue(try XCTUnwrap(initiatingVM).send("@\(quinn.handle) WINDOW_OWNER_MAIN"))
        let mainStarted = await waitUntil(timeout: 5) {
            quinnRunner.requests.contains { $0.prompt.contains("WINDOW_OWNER_MAIN") }
        }
        XCTAssertTrue(mainStarted)

        initiatingVM?.createDeskThread()
        let siblingOrigin = try XCTUnwrap(initiatingVM?.selectedConversation)
        XCTAssertTrue(try XCTUnwrap(initiatingVM).send("@\(rory.handle) WINDOW_OWNER_SIBLING"))
        let siblingStarted = await waitUntil(timeout: 5) {
            roryRunner.requests.contains { $0.prompt.contains("WINDOW_OWNER_SIBLING") }
        }
        XCTAssertTrue(siblingStarted)

        let mainHandoff = try XCTUnwrap(initiatingVM?.peerHandoffSnapshotsForTesting(
            originConversationID: mainOrigin.id,
            originThreadID: nil
        ).first)
        let siblingHandoff = try XCTUnwrap(initiatingVM?.peerHandoffSnapshotsForTesting(
            originConversationID: siblingOrigin.id,
            originThreadID: nil
        ).first)
        let mainPeerRunID = try XCTUnwrap(mainHandoff.peerRunID)
        let siblingPeerRunID = try XCTUnwrap(siblingHandoff.peerRunID)
        XCTAssertNil(mainHandoff.hostRunID)
        XCTAssertNil(siblingHandoff.hostRunID)

        let observingVM = BotsViewModel(context: context, router: router)
        router.botsViewModel = observingVM
        observingVM.openDesk(rory)
        observingVM.openActiveBots()
        weak var releasedInitiator = initiatingVM
        initiatingVM = nil

        let initiatorDeallocated = await waitUntil(timeout: 1) {
            releasedInitiator == nil
        }
        if !initiatorDeallocated {
            _ = quinnRunner.finish(runID: mainPeerRunID, status: .cancelled, reply: nil)
            _ = roryRunner.finish(runID: siblingPeerRunID, status: .cancelled, reply: nil)
            _ = await waitUntil(timeout: 2) { releasedInitiator == nil }
            XCTFail(
                "VM A must deallocate while both exact peer runs remain pending; lifecycle continuation belongs to context authority"
            )
            return
        }

        XCTAssertEqual(try context.runRepo.get(id: mainPeerRunID)?.status, .running)
        XCTAssertEqual(try context.runRepo.get(id: siblingPeerRunID)?.status, .running)
        XCTAssertTrue(quinnRunner.finish(
            runID: mainPeerRunID,
            status: .completed,
            reply: "authority-owned peer reply"
        ))

        let mainCompletedInNonOwner = await waitUntil(timeout: 5) {
            observingVM.peerHandoffSnapshotsForTesting(
                originConversationID: mainOrigin.id,
                originThreadID: nil
            ).first?.phase == .completed
        }
        XCTAssertTrue(
            mainCompletedInNonOwner,
            "VM B must receive the exact authority delta without becoming execution owner"
        )
        let preservedSibling = try XCTUnwrap(observingVM.peerHandoffSnapshotsForTesting(
            originConversationID: siblingOrigin.id,
            originThreadID: nil
        ).first)
        XCTAssertEqual(preservedSibling.activityID, siblingHandoff.activityID)
        XCTAssertEqual(preservedSibling.peerRunID, siblingPeerRunID)
        XCTAssertEqual(preservedSibling.phase, .peerRunning)
        XCTAssertTrue(hostRunner.requests.isEmpty)

        XCTAssertTrue(roryRunner.finish(
            runID: siblingPeerRunID,
            status: .cancelled,
            reply: nil
        ))
        let siblingSettled = await waitUntil(timeout: 5) {
            observingVM.peerHandoffSnapshotsForTesting(
                originConversationID: siblingOrigin.id,
                originThreadID: nil
            ).first?.phase == .needsAttention
        }
        XCTAssertTrue(siblingSettled)
    }

    func test_authorityDeltaUpdatesTwoLiveWindowsWithoutReplacingLocalUIState() async throws {
        // WHY: peer handoff progress belongs to the shared context authority.
        // Its deltas must reach every live Bots window without using a whole-VM
        // reload that steals either window's selection or unsent local work.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        context.coordinator.replaceProvider(.claude, runner: peerRunner)
        context.coordinator.replaceProvider(.codex, runner: hostRunner)
        router.rememberProviderSnapshotsForSend(AgentProvider.allCases.map { provider in
            let model = BotsViewModel.defaultModel(for: provider)
            return AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: [AgentModelDescriptor(id: model, label: model, provider: provider)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                id: provider.rawValue
            )
        })

        let originWindow = BotsViewModel(context: context, router: router)
        let piper = try originWindow.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try originWindow.create(
            name: "Quinn",
            title: "CRM Controller",
            provider: .claude
        )
        let rory = try originWindow.create(
            name: "Rory",
            title: "Research Controller",
            provider: .grok
        )
        originWindow.openDesk(quinn)
        originWindow.setDeskProvider(.claude)
        originWindow.openDesk(piper)
        originWindow.setDeskProvider(.codex)
        originWindow.createDeskThread()
        let originConversation = try XCTUnwrap(originWindow.selectedConversation)

        let siblingWindow = BotsViewModel(context: context, router: router)
        siblingWindow.openStudio(rory)
        router.botsViewModel = originWindow

        XCTAssertTrue(originWindow.send("@\(quinn.handle) TWO_LIVE_WINDOWS"))
        let peerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("TWO_LIVE_WINDOWS") }
        }
        XCTAssertTrue(peerStarted)
        let running = try XCTUnwrap(originWindow.peerHandoffSnapshotsForTesting(
            originConversationID: originConversation.id,
            originThreadID: nil
        ).first)
        let peerRunID = try XCTUnwrap(running.peerRunID)
        XCTAssertNil(running.hostRunID)
        XCTAssertEqual(
            siblingWindow.peerHandoffSnapshotsForTesting(
                originConversationID: originConversation.id,
                originThreadID: nil
            ).first,
            running,
            "both windows must observe the same exact authority row"
        )

        let originAttachmentPath = (directory as NSString).appendingPathComponent("origin-window.txt")
        let siblingAttachmentPath = (directory as NSString).appendingPathComponent("sibling-window.txt")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: originAttachmentPath,
            contents: Data("origin".utf8)
        ))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: siblingAttachmentPath,
            contents: Data("sibling".utf8)
        ))

        originWindow.openDesk(piper)
        originWindow.selectDeskThread(originConversation.id)
        originWindow.composerText = "ORIGIN_WINDOW_COMPOSER"
        originWindow.attachments = [AgentAttachment(
            path: originAttachmentPath,
            displayName: "origin-window.txt",
            kind: .file
        )]
        originWindow.memoryDraft = "ORIGIN_MEMORY_DRAFT"
        originWindow.skillDraft = "origin-skill-draft"
        originWindow.routineName = "Origin routine"
        originWindow.routinePrompt = "Origin routine prompt"
        originWindow.routineScheduleNote = "Origin routine schedule"

        siblingWindow.openStudio(rory)
        siblingWindow.composerText = "SIBLING_WINDOW_COMPOSER"
        siblingWindow.attachments = [AgentAttachment(
            path: siblingAttachmentPath,
            displayName: "sibling-window.txt",
            kind: .file
        )]
        siblingWindow.memoryDraft = "SIBLING_MEMORY_DRAFT"
        siblingWindow.skillDraft = "sibling-skill-draft"
        siblingWindow.routineName = "Sibling routine"
        siblingWindow.routinePrompt = "Sibling routine prompt"
        siblingWindow.routineScheduleNote = "Sibling routine schedule"

        let originReloadCounts = fullReloadCounts(originWindow)
        let siblingReloadCounts = fullReloadCounts(siblingWindow)
        let originDeskRestoreCount = originWindow.deskRestoreInvokedCountForTesting
        let siblingDeskRestoreCount = siblingWindow.deskRestoreInvokedCountForTesting
        let originSelection = originWindow.selectedBotID
        let siblingSelection = siblingWindow.selectedBotID
        let originScreen = originWindow.screen
        let siblingScreen = siblingWindow.screen
        let originAttachments = originWindow.attachments
        let siblingAttachments = siblingWindow.attachments

        XCTAssertTrue(peerRunner.finish(
            runID: peerRunID,
            status: .completed,
            reply: "TWO_WINDOW_EXACT_REPLY"
        ))
        let bothCompleted = await waitUntil(timeout: 5) {
            originWindow.peerHandoffSnapshotsForTesting(
                originConversationID: originConversation.id,
                originThreadID: nil
            ).first?.phase == .completed
                && siblingWindow.peerHandoffSnapshotsForTesting(
                    originConversationID: originConversation.id,
                    originThreadID: nil
                ).first?.phase == .completed
        }
        XCTAssertTrue(bothCompleted)
        let completedSnapshot = try XCTUnwrap(originWindow.peerHandoffSnapshotsForTesting(
            originConversationID: originConversation.id,
            originThreadID: nil
        ).first)
        XCTAssertEqual(
            siblingWindow.peerHandoffSnapshotsForTesting(
                originConversationID: originConversation.id,
                originThreadID: nil
            ).first,
            completedSnapshot
        )
        XCTAssertEqual(completedSnapshot.activityID, running.activityID)
        XCTAssertEqual(completedSnapshot.peerRunID, peerRunID)
        XCTAssertNil(completedSnapshot.hostRunID)
        XCTAssertTrue(hostRunner.requests.isEmpty)
        XCTAssertEqual(
            originWindow.deskMessages.filter {
                $0.peer?.direction == .fromPeer && $0.text == "TWO_WINDOW_EXACT_REPLY"
            }.count,
            1,
            "the selected origin window must paint one stable reply row"
        )
        XCTAssertEqual(
            try context.botStore.conversation(id: completedSnapshot.peerConversationID)?.attentionState,
            .unreadActivity,
            "the peer conversation attention must settle with the direct reply"
        )
        XCTAssertEqual(
            siblingWindow.peerHandoffSnapshotsForTesting(
                originConversationID: originConversation.id,
                originThreadID: nil
            ).first,
            originWindow.peerHandoffSnapshotsForTesting(
                originConversationID: originConversation.id,
                originThreadID: nil
            ).first
        )
        XCTAssertEqual(
            try context.botStore.conversation(id: originConversation.id)?.attentionState,
            BotAttentionState.none,
            "the open origin conversation must not gain stale unread attention after the direct reply"
        )

        XCTAssertEqual(originWindow.selectedBotID, originSelection)
        XCTAssertEqual(siblingWindow.selectedBotID, siblingSelection)
        XCTAssertEqual(originWindow.screen, originScreen)
        XCTAssertEqual(siblingWindow.screen, siblingScreen)
        XCTAssertEqual(originWindow.composerText, "ORIGIN_WINDOW_COMPOSER")
        XCTAssertEqual(siblingWindow.composerText, "SIBLING_WINDOW_COMPOSER")
        XCTAssertEqual(originWindow.attachments, originAttachments)
        XCTAssertEqual(siblingWindow.attachments, siblingAttachments)
        XCTAssertEqual(originWindow.memoryDraft, "ORIGIN_MEMORY_DRAFT")
        XCTAssertEqual(siblingWindow.memoryDraft, "SIBLING_MEMORY_DRAFT")
        XCTAssertEqual(originWindow.skillDraft, "origin-skill-draft")
        XCTAssertEqual(siblingWindow.skillDraft, "sibling-skill-draft")
        XCTAssertEqual(originWindow.routineName, "Origin routine")
        XCTAssertEqual(siblingWindow.routineName, "Sibling routine")
        XCTAssertEqual(originWindow.routinePrompt, "Origin routine prompt")
        XCTAssertEqual(siblingWindow.routinePrompt, "Sibling routine prompt")
        XCTAssertEqual(originWindow.routineScheduleNote, "Origin routine schedule")
        XCTAssertEqual(siblingWindow.routineScheduleNote, "Sibling routine schedule")
        XCTAssertEqual(fullReloadCounts(originWindow), originReloadCounts)
        XCTAssertEqual(fullReloadCounts(siblingWindow), siblingReloadCounts)
        XCTAssertGreaterThan(
            originWindow.deskRestoreInvokedCountForTesting,
            originDeskRestoreCount,
            "exact terminal events may refresh the owning Desk projection without reloading the VM"
        )
        XCTAssertGreaterThan(
            siblingWindow.deskRestoreInvokedCountForTesting,
            siblingDeskRestoreCount,
            "the second window may refresh its targeted Desk cache without losing local UI state"
        )
    }

    func test_peerHandoffMutationWithOneThousandRowsRetainsNineHundredNinetyNineUnderFiftyMillisecondP95() throws {
        // WHY: every authority mutation re-encodes and atomically commits the
        // complete v2 envelope. A large retained history must not turn one
        // background handoff delta into a visible main-thread stall.
        let settingsKey = "bots.peerTurns.v2"
        let targetOriginBotID = BotID()
        let (payload, targetActivityID, siblingActivityID) = try peerHandoffPerformancePayload(
            rowCount: 1_000,
            targetOriginBotID: targetOriginBotID
        )
        defer { UserDefaults.standard.removeObject(forKey: settingsKey) }

        _ = try measurePeerHandoffDeletion(
            label: "warmup",
            payload: payload,
            targetOriginBotID: targetOriginBotID,
            targetActivityID: targetActivityID,
            siblingActivityID: siblingActivityID
        )

        var samples: [Double] = []
        for sample in 0..<20 {
            samples.append(try measurePeerHandoffDeletion(
                label: "sample-\(sample)",
                payload: payload,
                targetOriginBotID: targetOriginBotID,
                targetActivityID: targetActivityID,
                siblingActivityID: siblingActivityID
            ))
        }

        let p95 = percentile(samples, fraction: 0.95)
        let rawSamples = samples.map { String(format: "%.3f", $0) }.joined(separator: ",")
        let evidence = "samples_ms=[\(rawSamples)] p95_ms=\(String(format: "%.3f", p95))"
        XCTAssertLessThan(p95, 50, evidence)
    }

    func test_exactCheckpointAssistantBeatsNewerAmbientAssistantInsertedBeforeTerminalFanout() async throws {
        // WHY: a thread-global "latest assistant" can belong to unrelated work.
        // Insert that adversary after the exact minimal checkpoint write but
        // before didFinish; only the checkpoint-owned assistant may cross Bots.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        context.coordinator.replaceProvider(.claude, runner: peerRunner)
        context.coordinator.replaceProvider(.codex, runner: hostRunner)
        let viewModel = BotsViewModel(context: context, router: router)
        router.botsViewModel = viewModel
        let piper = try viewModel.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try viewModel.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        viewModel.openDesk(quinn)
        viewModel.setDeskProvider(.claude)
        viewModel.openDesk(piper)
        viewModel.setDeskProvider(.codex)
        viewModel.createDeskThread()
        let origin = try XCTUnwrap(viewModel.selectedConversation)

        XCTAssertTrue(viewModel.send("@\(quinn.handle) T005_EXACT_ORACLE"))
        let peerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("T005_EXACT_ORACLE") }
        }
        XCTAssertTrue(peerStarted)
        let pending = try XCTUnwrap(viewModel.peerHandoffSnapshotsForTesting(
            originConversationID: origin.id,
            originThreadID: nil
        ).first)
        let peerRunID = try XCTUnwrap(pending.peerRunID)
        let peerThreadID = try XCTUnwrap(pending.peerThreadID)
        let ambientMessageID = AgentMessageID()
        try context.db.execute("""
            CREATE TRIGGER insert_t005_newer_ambient_assistant
            AFTER INSERT ON agent_turn_checkpoints
            WHEN NEW.run_id = '\(peerRunID.value.uuidString)'
            BEGIN
                INSERT INTO agent_messages(
                    id, thread_id, role, content, created_at, attachments_json,
                    body_sha256, body_bytes, body_revision
                ) VALUES(
                    '\(ambientMessageID.value.uuidString)',
                    '\(peerThreadID.value.uuidString)',
                    'assistant',
                    'NEWER_AMBIENT_MUST_LOSE',
                    '9999-12-31T23:59:59Z',
                    '[]',
                    't005-ambient',
                    23,
                    1
                );
            END;
        """)
        defer { try? context.db.execute("DROP TRIGGER insert_t005_newer_ambient_assistant;") }

        XCTAssertTrue(peerRunner.finish(
            runID: peerRunID,
            status: .completed,
            reply: "EXACT_CHECKPOINT_REPLY"
        ))
        let completed = await waitUntil(timeout: 5) {
            viewModel.peerHandoffSnapshotsForTesting(
                originConversationID: origin.id,
                originThreadID: nil
            ).first?.phase == .completed
        }
        XCTAssertTrue(completed)
        let checkpoint = try XCTUnwrap(
            context.turnCheckpointRepo.list(threadId: peerThreadID)
                .first { $0.runId == peerRunID }
        )
        let checkpointMessageID = try XCTUnwrap(checkpoint.assistantMessageId)
        XCTAssertNotEqual(checkpointMessageID, ambientMessageID)
        XCTAssertEqual(
            try context.messageRepo.get(id: checkpointMessageID)?.content,
            "EXACT_CHECKPOINT_REPLY"
        )
        XCTAssertEqual(
            try context.messageRepo.list(threadId: peerThreadID).last?.id,
            ambientMessageID,
            "precondition: the unrelated assistant is observably newer on the same thread"
        )
        XCTAssertTrue(viewModel.deskMessages.contains {
            $0.peer?.direction == .fromPeer && $0.text == "EXACT_CHECKPOINT_REPLY"
        })
        XCTAssertFalse(viewModel.deskMessages.contains { $0.text == "NEWER_AMBIENT_MUST_LOSE" })
        XCTAssertNil(viewModel.peerHandoffSnapshotsForTesting(
            originConversationID: origin.id,
            originThreadID: nil
        ).first?.hostRunID)
        XCTAssertTrue(hostRunner.requests.isEmpty)
    }

    func test_peerFailureAndCancellationSettleOnlyTheirExactOwningHandoffs() async throws {
        // WHY: two concurrent requests can share the same peer provider. A
        // failure or cancellation is scoped by the durable run ID, not by the
        // currently selected Bot, so neither terminal may settle its sibling.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: peerRunner)
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(quinn)
        vm.setDeskProvider(.claude)
        vm.openDesk(piper)
        vm.setDeskProvider(.codex)

        vm.createDeskThread()
        let failureOrigin = try XCTUnwrap(vm.selectedConversation)
        XCTAssertTrue(vm.send("@\(quinn.handle) FAIL_ONLY_OWNER"))
        let failureStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("FAIL_ONLY_OWNER") }
        }
        XCTAssertTrue(failureStarted)

        vm.createDeskThread()
        let cancellationOrigin = try XCTUnwrap(vm.selectedConversation)
        XCTAssertTrue(vm.send("@\(quinn.handle) CANCEL_ONLY_OWNER"))
        let cancellationStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("CANCEL_ONLY_OWNER") }
        }
        XCTAssertTrue(cancellationStarted)

        let failureHandoff = try XCTUnwrap(vm.peerHandoffSnapshotsForTesting(
            originConversationID: failureOrigin.id,
            originThreadID: nil
        ).first)
        let cancellationHandoff = try XCTUnwrap(vm.peerHandoffSnapshotsForTesting(
            originConversationID: cancellationOrigin.id,
            originThreadID: nil
        ).first)
        let failureRunID = try XCTUnwrap(failureHandoff.peerRunID)
        let cancellationRunID = try XCTUnwrap(cancellationHandoff.peerRunID)
        XCTAssertNotEqual(failureRunID, cancellationRunID)

        XCTAssertTrue(peerRunner.finish(runID: failureRunID, status: .failed, reply: nil))
        let failureSettled = await waitUntil(timeout: 5) {
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: failureOrigin.id,
                originThreadID: nil
            ).first?.phase == .needsAttention
        }
        XCTAssertTrue(failureSettled)
        XCTAssertEqual(try context.runRepo.get(id: failureRunID)?.status, .failed)
        XCTAssertEqual(
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: cancellationOrigin.id,
                originThreadID: nil
            ).first?.phase,
            .peerRunning,
            "failure of the first exact run must leave its sibling armed and running"
        )
        XCTAssertEqual(try context.runRepo.get(id: cancellationRunID)?.status, .running)

        XCTAssertTrue(peerRunner.finish(runID: cancellationRunID, status: .cancelled, reply: nil))
        let cancellationSettled = await waitUntil(timeout: 5) {
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: cancellationOrigin.id,
                originThreadID: nil
            ).first?.phase == .needsAttention
        }
        XCTAssertTrue(cancellationSettled)
        XCTAssertEqual(try context.runRepo.get(id: cancellationRunID)?.status, .cancelled)
        XCTAssertEqual(
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: failureOrigin.id,
                originThreadID: nil
            ).first?.phase,
            .needsAttention,
            "cancellation of the sibling exact run must not rewrite the first terminal"
        )

        for origin in [failureOrigin, cancellationOrigin] {
            vm.selectDeskThread(origin.id)
            XCTAssertFalse(
                vm.deskMessages.contains { $0.peer?.direction == .fromPeer },
                "failed/cancelled peers have no stable reply to leak into either origin"
            )
        }
    }

    func test_handoffOlderThanSixtyFiveLogicalSecondsStillSettlesFromExactTerminalsWithoutWallTimeout() async throws {
        // WHY: the former 120 x 500 ms polling loop fabricated a one-minute
        // boundary. Durable run age is not failure evidence; the directly
        // addressed peer must remain owned until its exact terminal arrives.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        let hostRunner = ControlledBotHandoffRunner(provider: .codex)
        context.coordinator.replaceProvider(.claude, runner: peerRunner)
        context.coordinator.replaceProvider(.codex, runner: hostRunner)
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(quinn)
        vm.setDeskProvider(.claude)
        vm.openDesk(piper)
        vm.setDeskProvider(.codex)
        vm.createDeskThread()
        let origin = try XCTUnwrap(vm.selectedConversation)

        let wallStart = Date()
        XCTAssertTrue(vm.send("@\(quinn.handle) LOGICAL_65_SECONDS"))
        let peerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("LOGICAL_65_SECONDS") }
        }
        XCTAssertTrue(peerStarted)
        let peerRunID = try XCTUnwrap(
            peerRunner.requests.first { $0.prompt.contains("LOGICAL_65_SECONDS") }?.runId
        )
        let peerRunning = await waitUntil(timeout: 5) {
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: origin.id,
                originThreadID: nil
            ).first?.phase == .peerRunning
        }
        XCTAssertTrue(peerRunning, "the peer start must persist .peerRunning before logical age is applied")
        var peerRun = try XCTUnwrap(try context.runRepo.get(id: peerRunID))
        let peerLogicalNow = Date()
        peerRun.startedAt = peerLogicalNow.addingTimeInterval(-66)
        try context.runRepo.upsert(peerRun)
        XCTAssertGreaterThan(peerLogicalNow.timeIntervalSince(peerRun.startedAt), 65)
        XCTAssertEqual(
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: origin.id,
                originThreadID: nil
            ).first?.phase,
            .peerRunning,
            "logical age alone must not settle the peer leg"
        )

        XCTAssertTrue(peerRunner.finish(runID: peerRunID, status: .completed, reply: "reply after 65s"))
        let settled = await waitUntil(timeout: 5) {
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: origin.id,
                originThreadID: nil
            ).first?.phase == .completed
        }
        XCTAssertTrue(settled)
        let handoff = try XCTUnwrap(vm.peerHandoffSnapshotsForTesting(
            originConversationID: origin.id,
            originThreadID: nil
        ).first)
        XCTAssertNil(handoff.hostRunID)
        XCTAssertTrue(hostRunner.requests.isEmpty)
        XCTAssertLessThan(
            Date().timeIntervalSince(wallStart),
            10,
            "the >65-second proof advances durable logical time and must never wall-sleep for the old timeout"
        )
        XCTAssertEqual(
            vm.deskTranscriptForTesting(botID: piper.id).filter {
                $0.peer?.direction == .fromPeer && $0.text == "reply after 65s"
            }.count,
            1
        )
    }

    func test_setPhaseRetriesOneTransientConflictFromCanonicalStateWithoutAlert() async throws {
        // WHY: another writer or the mirror can win one persistence attempt.
        // Retrying the phase intent from the freshly adopted canonical map
        // heals that bounded race without exposing a false save alert.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: peerRunner)
        let vm = BotsViewModel(context: context, router: router)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(quinn)
        vm.setDeskProvider(.claude)
        vm.setDeskModel("fake-model")
        let originThread = AgentThread(
            title: "Transient conflict origin",
            provider: .codex,
            model: "fake-model",
            status: .completed
        )
        try context.threadRepo.upsert(originThread)

        var persistCount = 0
        context.botPeerHandoffAuthority.peerHandoffMirrorCommitGateForTesting = { data in
            persistCount += 1
            if persistCount == 2 {
                throw NSError(domain: "setPhaseTransientConflict", code: 1)
            }
            UserDefaults.standard.set(data, forKey: "bots.peerTurns.v2")
            guard UserDefaults.standard.synchronize(),
                  UserDefaults.standard.data(forKey: "bots.peerTurns.v2") == data else {
                throw NSError(domain: "setPhaseTransientConflict", code: 2)
            }
        }

        let milestone = try XCTUnwrap(
            context.botPeerHandoffAuthority.submitAgentAppMention(
                peer: quinn,
                text: "SETPHASE_TRANSIENT_RETRY",
                peerText: "SETPHASE_TRANSIENT_RETRY",
                originThread: originThread,
                activityID: AgentMessageID(),
                hostRunID: nil,
                providerSnapshots: [],
                resumeHostAfterPeer: false
            )
        )
        let peerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("SETPHASE_TRANSIENT_RETRY") }
        }
        XCTAssertTrue(peerStarted)
        let phaseAdvanced = await waitUntil(timeout: 5) {
            persistCount >= 3
                && vm.peerHandoffSnapshotsForTesting(
                    originConversationID: nil,
                    originThreadID: originThread.id
                ).first?.phase == .peerRunning
        }
        XCTAssertTrue(phaseAdvanced)
        XCTAssertEqual(
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: originThread.id
            ).first?.phase,
            .peerRunning
        )
        XCTAssertNil(vm.errorMessage, vm.errorMessage ?? "")

        context.botPeerHandoffAuthority.peerHandoffMirrorCommitGateForTesting = nil
        if let peerRunID = peerRunner.requests.first?.runId {
            _ = peerRunner.finish(runID: peerRunID, status: .cancelled, reply: nil)
        }
        await milestone.value
    }

    func test_setPhasePersistentConflictPublishesCanonicalSnapshotAndSaveAlert() async throws {
        // WHY: the bounded retry must not install an unpersisted phase or hide
        // a storage failure that remains after retrying from canonical state.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: peerRunner)
        let vm = BotsViewModel(context: context, router: router)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(quinn)
        vm.setDeskProvider(.claude)
        vm.setDeskModel("fake-model")
        let originThread = AgentThread(
            title: "Persistent conflict origin",
            provider: .codex,
            model: "fake-model",
            status: .completed
        )
        try context.threadRepo.upsert(originThread)

        var persistCount = 0
        context.botPeerHandoffAuthority.peerHandoffMirrorCommitGateForTesting = { data in
            persistCount += 1
            if persistCount > 1 {
                throw NSError(domain: "setPhasePersistentConflict", code: 1)
            }
            UserDefaults.standard.set(data, forKey: "bots.peerTurns.v2")
            guard UserDefaults.standard.synchronize(),
                  UserDefaults.standard.data(forKey: "bots.peerTurns.v2") == data else {
                throw NSError(domain: "setPhasePersistentConflict", code: 2)
            }
        }

        let milestone = try XCTUnwrap(
            context.botPeerHandoffAuthority.submitAgentAppMention(
                peer: quinn,
                text: "SETPHASE_PERSISTENT_FAILURE",
                peerText: "SETPHASE_PERSISTENT_FAILURE",
                originThread: originThread,
                activityID: AgentMessageID(),
                hostRunID: nil,
                providerSnapshots: [],
                resumeHostAfterPeer: false
            )
        )
        let peerStarted = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("SETPHASE_PERSISTENT_FAILURE") }
        }
        XCTAssertTrue(peerStarted)
        let failurePublished = await waitUntil(timeout: 5) {
            persistCount >= 3
                && vm.errorMessage == "The bot handoff state could not be saved."
        }
        XCTAssertTrue(failurePublished, "setPhase must attempt once plus one bounded retry")
        XCTAssertEqual(
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: originThread.id
            ).first?.phase,
            .peerPrepared,
            "persistent failure must retain canonical state, not the failed candidate"
        )
        XCTAssertEqual(vm.errorMessage, "The bot handoff state could not be saved.")

        context.botPeerHandoffAuthority.peerHandoffMirrorCommitGateForTesting = nil
        if let peerRunID = peerRunner.requests.first?.runId {
            _ = peerRunner.finish(runID: peerRunID, status: .cancelled, reply: nil)
        }
        await milestone.value
    }

    func test_relaunchMissingPreparedPeerRunFinalizesExactAcceptedBotDelegationReceipt() throws {
        // WHY: the receipt id map is process-local. After a crash, a restored
        // peerPrepared row with no run is known to have failed before provider
        // start, so its exact Bot telemetry row must stop claiming Working.
        let context = try makeContext()
        let originThread = AgentThread(
            title: "Restored Bot host",
            provider: .codex,
            model: "fake-model",
            status: .completed
        )
        let peerThread = AgentThread(
            title: "Restored Bot peer",
            provider: .claude,
            model: "fake-model",
            status: .completed
        )
        try context.threadRepo.upsert(originThread)
        try context.threadRepo.upsert(peerThread)
        let activityID = UUID()
        let peerRunID = AgentRunID()
        let hostRunID = AgentRunID()
        let route = T005PeerHandoffRouteFixture(
            provider: .claude,
            providerInstanceID: "claude",
            model: "fake-model",
            permissionMode: .supervised,
            reasoningEffort: .medium,
            serviceTier: .auto,
            runAsUser: AgentRunAsUser(
                generatedUID: "restored-bot-fixture",
                shortName: "fixture",
                uid: 0,
                gid: 0,
                homePath: "/tmp/restored-bot-fixture"
            ),
            routingConfiguration: nil
        )
        let payload = try JSONEncoder().encode([
            activityID: T005PeerHandoffRecordFixture(
                version: 2,
                activityID: activityID,
                originBotID: nil,
                originConversationID: nil,
                originAgentThreadID: originThread.id,
                peerBotID: BotID(),
                peerConversationID: BotConversationID(),
                peerThreadID: peerThread.id,
                peerRunID: peerRunID,
                inboundMessageID: activityID,
                peerName: "Restored Quinn",
                peerTitle: "CRM Controller",
                peerHandle: "restored-quinn",
                outboundText: "RESTORED_PRESTART_FAILURE",
                createdAt: Date(),
                peerRoute: route,
                hostThreadID: originThread.id,
                hostRunID: hostRunID,
                hostRoute: route,
                replyText: nil,
                replyCreatedAt: nil,
                phase: .peerPrepared
            ),
        ])
        UserDefaults.standard.set(payload, forKey: "bots.peerTurns.v2")
        XCTAssertTrue(UserDefaults.standard.synchronize())
        try context.settingsRepo.set(
            "bots.peerTurns.v2",
            "base64:\(payload.base64EncodedString())"
        )
        let receipt = try context.orchestrationRuntime.recordBotDelegationTelemetry(
            runId: peerRunID,
            hostThreadId: originThread.id,
            nodeId: "bot.restored-quinn.\(peerRunID.value.uuidString)",
            provider: .claude,
            providerInstanceId: "claude",
            model: "fake-model",
            reasoningEffort: .medium,
            permissionMode: .supervised
        )
        XCTAssertEqual(receipt.lifecycleStatus, .accepted)
        XCTAssertNil(try context.runRepo.get(id: peerRunID))

        let reopened = BotsViewModel(context: context)
        reopened.reconcilePeerHandoffsForTesting()
        XCTAssertEqual(
            reopened.peerHandoffSnapshotsForTesting(
                originConversationID: nil,
                originThreadID: originThread.id
            ).first?.phase,
            .needsAttention
        )
        let reconciledReceipt = try XCTUnwrap(
            context.orchestrationRuntime.recentReceipts(limit: 64).first {
                $0.id == receipt.id
                    && $0.runId == peerRunID
                    && $0.decisionReason == AgentOrchestrationRuntime.botDelegationDecisionReason
            }
        )
        XCTAssertEqual(reconciledReceipt.lifecycleStatus, .finalized)
        XCTAssertEqual(reconciledReceipt.finalRunStatus, .failed)
        XCTAssertFalse(
            try context.orchestrationRuntime.activityReceipts(
                threadIds: [originThread.id],
                limit: 16
            ).contains {
                $0.id == receipt.id && $0.lifecycleStatus == .accepted
            },
            "the exact restored Bot receipt must no longer project as active"
        )
    }

    func test_routeMutationAfterDurablePrebindCannotRerouteMentionedPeer() async throws {
        // WHY: the user can change the visible Desk route while a teammate is
        // starting. The addressed peer must keep its admission snapshot, and
        // no ambient or host provider may start a duplicate answer.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let claude = ControlledBotHandoffRunner(provider: .claude)
        let codex = ControlledBotHandoffRunner(provider: .codex)
        let grok = ControlledBotHandoffRunner(provider: .grok)
        context.coordinator.replaceProvider(.claude, runner: claude)
        context.coordinator.replaceProvider(.codex, runner: codex)
        context.coordinator.replaceProvider(.grok, runner: grok)
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .codex)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(quinn)
        vm.setDeskProvider(.claude)
        vm.openDesk(piper)
        vm.setDeskProvider(.codex)
        vm.createDeskThread()
        let origin = try XCTUnwrap(vm.selectedConversation)

        var dispatches = 0
        vm.beforeBotRunDispatchForTesting = { _ in
            dispatches += 1
            vm.setDeskProvider(.grok)
        }
        XCTAssertTrue(vm.send("@\(quinn.handle) ROUTE_FREEZE"))
        let peerStarted = await waitUntil(timeout: 5) {
            claude.requests.contains { $0.prompt.contains("ROUTE_FREEZE") }
        }
        XCTAssertTrue(peerStarted)
        XCTAssertTrue(grok.requests.isEmpty)
        XCTAssertTrue(claude.finish(promptContaining: "ROUTE_FREEZE", reply: "frozen reply"))
        let completed = await waitUntil(timeout: 5) {
            vm.peerHandoffSnapshotsForTesting(
                originConversationID: origin.id,
                originThreadID: nil
            ).first?.phase == .completed
        }
        XCTAssertTrue(completed)

        let handoff = try XCTUnwrap(vm.peerHandoffSnapshotsForTesting(
            originConversationID: origin.id,
            originThreadID: nil
        ).first)
        XCTAssertEqual(handoff.peerProvider, .claude)
        XCTAssertNil(handoff.hostProvider)
        XCTAssertEqual(handoff.peerRunID, claude.requests.first?.runId)
        XCTAssertNil(handoff.hostRunID)
        XCTAssertEqual(dispatches, 1)
        XCTAssertTrue(codex.requests.isEmpty, "the host must not answer a message addressed to Quinn")
        XCTAssertTrue(grok.requests.isEmpty, "ambient mutation must not reroute the peer to Grok")
        vm.beforeBotRunDispatchForTesting = nil
    }

    func test_directPeerReplyDoesNotStartHostHop() async throws {
        // WHY: the From Quinn reply is the final answer. Feeding it back into
        // Piper creates a second un-attributed assistant response.
        let (vm, piper, quinn) = try makeMentionPair(peerReply: "inbox is clear")
        XCTAssertTrue(vm.send("@\(quinn.handle) what is in the inbox?"))
        let completed = await waitUntil(timeout: 8) {
            guard let handoff = vm.peerHandoffSnapshotsForTesting().first(where: {
                $0.originBotID == piper.id && $0.peerBotID == quinn.id
            }) else { return false }
            return handoff.phase == .completed
        }
        let observedHandoff = vm.peerHandoffSnapshotsForTesting().first {
            $0.originBotID == piper.id && $0.peerBotID == quinn.id
        }
        XCTAssertTrue(completed)
        XCTAssertNil(observedHandoff?.hostRunID)
        XCTAssertNil(vm.lastHopUserTextForTesting)
        let imported = await waitUntil(timeout: 5) {
            vm.deskTranscriptForTesting(botID: piper.id).contains {
                $0.role == .assistant
                    && $0.peer?.direction == .fromPeer
                    && $0.text.contains("inbox is clear")
            }
        }
        let observedHandoffs = vm.peerHandoffSnapshotsForTesting()
        let exactHandoff = observedHandoffs.first {
            $0.originBotID == piper.id && $0.peerBotID == quinn.id
        }
        let piperTranscript = vm.deskTranscriptForTesting(botID: piper.id)
        XCTAssertEqual(
            piperTranscript.filter {
                $0.role == .user
                    && $0.peer?.direction == .messaged
                    && $0.peer?.botID == quinn.id
                    && $0.text == "@\(quinn.handle) what is in the inbox?"
            }.count,
            1
        )
        XCTAssertEqual(
            piperTranscript.filter {
                $0.role == .assistant
                    && $0.peer?.direction == .fromPeer
                    && $0.peer?.botID == quinn.id
                    && $0.text == "inbox is clear"
            }.count,
            1
        )
        XCTAssertTrue(
            imported,
            "host desk must show the Message from peer reply; selectedConversationID=\(String(describing: vm.selectedConversation?.id)) observerSnapshotCount=\(observedHandoffs.count) phase=\(String(describing: exactHandoff?.phase)) inboundID=\(String(describing: exactHandoff?.inboundMessageID)) peerRunID=\(String(describing: exactHandoff?.peerRunID)) hostRunID=\(String(describing: exactHandoff?.hostRunID))"
        )
    }

    func test_beginCreateTwiceAllocatesDistinctHandles_becauseNewAgentIsAPlaceholder() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.beginCreate()
        _ = try vm.saveStudio()
        vm.beginCreate()
        _ = try vm.saveStudio()
        let bots = try context.botStore.list()
        XCTAssertEqual(bots.count, 2)
        XCTAssertEqual(Set(bots.map(\.handle)).count, 2)
        XCTAssertTrue(bots.allSatisfy { $0.name == "New Agent" })
    }

    func test_studioSlugFollowsNameUntilOwnerEditsIt() throws {
        // WHY: CEO must become @ceo while the slug is unlocked. A typed
        // slug must stay put when the name changes again.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.beginCreate()
        vm.didEditStudioName("CEO")
        XCTAssertEqual(BotHandle.normalize(vm.studioDraft.handle), "ceo")
        XCTAssertTrue(vm.studioSlugFollowsName)
        vm.didEditStudioSlug("boss")
        XCTAssertFalse(vm.studioSlugFollowsName)
        vm.didEditStudioName("Chief")
        XCTAssertEqual(vm.studioDraft.handle, "boss")
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(bots.contains("labeledField(\"Slug\")"))
        XCTAssertTrue(bots.contains("bots.studio.slug"))
        XCTAssertFalse(bots.contains("labeledField(\"Handle\")"))
        XCTAssertFalse(bots.contains(".disabled(!vm.studioDraft.isNew)"))
    }

    func test_studioSavePersistsSlugRename() throws {
        // WHY: New Bot already has a uniqued handle. Studio Save must
        // write the owner slug, not keep new-agent-N.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.beginCreate()
        vm.didEditStudioName("CEO")
        XCTAssertEqual(BotHandle.normalize(vm.studioDraft.handle), "ceo")
        let saved = try vm.saveStudio()
        XCTAssertEqual(saved.handle, "ceo")
        XCTAssertEqual(try context.botStore.get(id: saved.id)?.handle, "ceo")
    }

    func test_studioDescriptionAndInstructionsCaptionsContrastWhoVersusHow() throws {
        // WHY: Description and Instructions sat unlabeled next to each
        // other. Owners wrote job prose in the about field and identity
        // into the soul. The captions must contrast who vs how.
        XCTAssertTrue(BotsChrome.Label.descriptionCaption.hasPrefix("Who this teammate is"))
        XCTAssertTrue(BotsChrome.Label.instructionsCaption.hasPrefix("How this teammate should work"))
        XCTAssertTrue(BotsChrome.Label.descriptionCaption.contains("Empty stays out of the prompt"))
        XCTAssertTrue(BotsChrome.Label.instructionsCaption.contains("Always sent"))
        XCTAssertTrue(BotsChrome.Label.instructionsCaption.contains("Empty uses the built-in teammate default"))
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(bots.contains("BotsChrome.Label.descriptionCaption"))
        XCTAssertTrue(bots.contains("BotsChrome.Label.instructionsCaption"))
        XCTAssertTrue(bots.contains(".accessibilityHint(BotsChrome.Label.descriptionCaption)"))
        XCTAssertTrue(bots.contains(".accessibilityHint(BotsChrome.Label.instructionsCaption)"))
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

    private final class RecordingDocker: BotComputerDockerClienting, @unchecked Sendable {
        var created: [String] = []
        var builds: [URL] = []
        var png = BotComputerGuestObserve.pngSignature + Data(repeating: 1, count: 16)
        var containers: [String: BotComputerContainerInspect] = [:]
        var startError: Error?
        var startCallCount = 0
        var blocksBuild = false
        let buildStarted = DispatchSemaphore(value: 0)
        let allowBuild = DispatchSemaphore(value: 0)

        func info() throws -> String { "ok" }
        func imageExists(tag: String) throws -> Bool { true }
        func imageLabel(tag: String, key: String) throws -> String {
            key == BotComputerGuestSpec.recipeLabelKey ? BotComputerGuestSpec.recipeRevision : ""
        }
        func imageID(tag: String) throws -> String { "img" }
        func build(context: URL, tag: String) throws {
            builds.append(context)
            if blocksBuild {
                buildStarted.signal()
                _ = allowBuild.wait(timeout: .now() + 2)
            }
        }
        func create(options: BotComputerContainerCreateOptions) throws -> String {
            created.append(options.name)
            containers[options.name] = BotComputerContainerInspect(running: false, imageID: "img", hostPort: 49152)
            return options.name
        }
        func start(name: String) throws {
            startCallCount += 1
            if let startError { throw startError }
            containers[name] = BotComputerContainerInspect(running: true, imageID: "img", hostPort: 49152)
        }
        func stop(name: String) throws {
            if var value = containers[name] {
                value.running = false
                containers[name] = value
            }
        }
        func inspect(name: String) throws -> BotComputerContainerInspect {
            guard let value = containers[name] else { throw BotComputerGuestError.notReady }
            return value
        }
        func exec(name: String, command: [String], user: String?, detach: Bool) throws -> Data { png }
        func rename(from: String, to: String) throws {
            containers[to] = containers[from]
            containers[from] = nil
        }
        func ensureNetwork(name: String) throws {}
        func remove(name: String) throws { containers[name] = nil }
        func removeMatching(namePrefix: String) throws {
            for name in containers.keys where name.hasPrefix(namePrefix) {
                containers[name] = nil
            }
        }
    }

    func test_e2eThreeRuntimesUseShippedStudioSaveAndSend() throws {
        // WHY: the owner must persist and send on all three advertised
        // runtimes. this-Mac paths stay live without Docker; Docker-with-GUI
        // only after shipped proveReady + this-bot PNG.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.dockerGuestReadyOverrideForTesting = false

        vm.openStudio(piper)
        vm.studioDraft.desktopKind = .logicalExecutionSpace
        try vm.saveStudio()
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .logicalExecutionSpace)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Open https://example.com in the default macOS browser."))
        XCTAssertEqual(
            BotStandingInstructions.admittedToolsText(for: .logicalExecutionSpace)
                .contains(BotStandingInstructions.macosHarnessTool),
            true
        )

        vm.openStudio(piper)
        vm.studioDraft.desktopKind = .botOwnedBrowser
        try vm.saveStudio()
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .botOwnedBrowser)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("Open https://example.com in this teammate's own browser."))
        XCTAssertFalse(
            BotStandingInstructions.admittedToolsText(for: .botOwnedBrowser)
                .contains(BotStandingInstructions.generatedMacOSHarnessLine)
        )

        guard ProcessInfo.processInfo.environment["RC_LIVE_DOCKER"] == "1" else {
            vm.openStudio(piper)
            vm.studioDraft.desktopKind = .dockerDesktop
            XCTAssertThrowsError(try vm.saveStudio())
            return
        }
        let recipe = try XCTUnwrap(AppShellResourceBundle.computerGuestRecipeURL())
        let service = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: BotComputerDockerCLI(),
            recipeContext: recipe
        )
        vm.computerGuestService = service
        vm.dockerGuestReadyOverrideForTesting = nil
        XCTAssertTrue(service.proveReady(), service.lastReason)
        XCTAssertEqual(service.lastReady?.pngMagic, "89504e47")
        XCTAssertEqual(service.lastReady?.screenURL.host, "127.0.0.1")
        vm.openStudio(piper)
        vm.studioDraft.desktopKind = .dockerDesktop
        try vm.saveStudio()
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .dockerDesktop)
        XCTAssertEqual(vm.lastGuestScreenURL?.host, "127.0.0.1")
        let shot = try service.observe(botID: piper.id)
        XCTAssertEqual(shot.magic, "89504e47")
        print("E2E_LOGICAL=1 E2E_BOT_BROWSER=1 E2E_DOCKER=1 PNG_MAGIC=\(shot.magic)")
        service.teardown(botID: piper.id)
    }

    func test_ensureDockerGuestProvisionsThisBotOnLoopback() throws {
        // WHY: Save of Docker-with-GUI must provision THIS bot and keep a
        // 127.0.0.1 viewer URL. Tests that inject ready=true skip Docker.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let fake = RecordingDocker()
        vm.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        vm.dockerGuestReadyOverrideForTesting = nil
        try vm.ensureDockerGuest(botID: piper.id)
        XCTAssertEqual(vm.lastGuestScreenURL?.host, "127.0.0.1")
        XCTAssertTrue(fake.created.contains(BotComputerGuestSpec.containerName(botID: piper.id)))
        XCTAssertEqual(vm.guestScreenURL(for: piper.id)?.host, "127.0.0.1")
        XCTAssertTrue(vm.isGuestRunning(piper.id))
    }

    func test_presentGuestDesktopPublishesLaunchProgressAndSupportsRetry() async throws {
        // WHY: a slow or failed Docker launch must acknowledge the user's click
        // immediately, reject duplicate starts, and leave a working retry path.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let fake = RecordingDocker()
        fake.startError = BotComputerGuestError.dockerUnavailable
        vm.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        vm.dockerGuestReadyOverrideForTesting = nil

        vm.presentGuestDesktop(botID: piper.id)
        XCTAssertEqual(vm.guestLaunchState(for: piper.id), .starting)
        vm.presentGuestDesktop(botID: piper.id)

        var deadline = Date().addingTimeInterval(2)
        while vm.guestLaunchState(for: piper.id) == .starting, Date() < deadline {
            await Task.yield()
        }
        XCTAssertEqual(
            vm.guestLaunchState(for: piper.id),
            .failed("Could not start the Linux desktop. Make sure Docker is running, then try again.")
        )
        XCTAssertEqual(fake.startCallCount, 1, "an acknowledged start must suppress duplicate work")
        XCTAssertFalse(vm.isGuestRunning(piper.id))

        fake.startError = nil
        vm.presentGuestDesktop(botID: piper.id)
        XCTAssertEqual(vm.guestLaunchState(for: piper.id), .starting)

        deadline = Date().addingTimeInterval(2)
        while !vm.isGuestRunning(piper.id), Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(vm.isGuestRunning(piper.id))
        XCTAssertEqual(vm.guestLaunchState(for: piper.id), .idle)
        XCTAssertEqual(fake.startCallCount, 2)
        XCTAssertEqual(vm.guestScreenURL(for: piper.id)?.host, "127.0.0.1")
    }

    func test_dockerDesktopAdmissionStartsGuestOffMainAndFailsClosedUntilReady() async throws {
        // WHY: pressing Send must never provision Docker synchronously on the
        // SwiftUI main thread; admission stays closed while the shared launch
        // task prepares and validates this bot's guest screen.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.desktopKindOverrideForTesting = .dockerDesktop
        vm.dockerGuestReadyOverrideForTesting = nil
        let fake = RecordingDocker()
        vm.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )

        XCTAssertThrowsError(try vm.admitDesktopSend(bot: piper))
        XCTAssertEqual(vm.guestLaunchState(for: piper.id), .starting)
        XCTAssertFalse(vm.send("open the linux screen"))
        XCTAssertEqual(vm.errorMessage, "Linux desktop is starting. Try again when it is ready.")

        let deadline = Date().addingTimeInterval(2)
        while !vm.isGuestRunning(piper.id), Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(vm.isGuestRunning(piper.id))
        XCTAssertEqual(vm.guestLaunchState(for: piper.id), .idle)
        XCTAssertEqual(fake.startCallCount, 1, "repeated admission must share the active launch")
        XCTAssertNoThrow(try vm.admitDesktopSend(bot: piper))
    }

    func test_deskDockerGuestScreenLivesOnMainCanvas() throws {
        // WHY: the live Linux screen belongs in the inspector desktop
        // pane, not above the chat timeline.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let chat = source.range(of: "private func deskChat") else {
            return XCTFail("desk chat must exist")
        }
        let paneStart = source.range(of: "private func deskDesktopPane")?.lowerBound ?? source.endIndex
        let chatSlice = String(source[chat.lowerBound..<paneStart])
        XCTAssertFalse(chatSlice.contains("BotComputerGuestCanvas"))
        let pane = String(source[paneStart...].prefix(2200))
        XCTAssertTrue(pane.contains("BotComputerGuestCanvas"))
        XCTAssertTrue(pane.contains("bots.desk.desktop.guestScreen"))
        XCTAssertTrue(pane.contains("bots.desk.desktop.start"))
        XCTAssertTrue(source.contains("openGuestDesktopInNewWindow"))
        let canvas = try String(
            contentsOf: sourceURL("Sources/AppShell/BotComputerGuestScreenView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(canvas.contains("struct BotComputerGuestCanvas"))
        XCTAssertTrue(canvas.contains("rectangle.on.rectangle"))
        XCTAssertTrue(canvas.contains("bots.desk.desktop.openInNewWindow"))
        XCTAssertTrue(canvas.contains("acceptsFirstResponder"))
        XCTAssertFalse(canvas.contains("View-only noVNC"))
    }

    func test_guestCanvasAcknowledgesSlowStartAndOffersRetryAfterFailure() throws {
        // WHY: Docker may need minutes to prepare the first desktop. The click
        // must remain visibly acknowledged, and a failed launch must explain
        // the recovery path instead of leaving the unchanged Start screen.
        let canvas = try String(
            contentsOf: sourceURL("Sources/AppShell/BotComputerGuestScreenView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(canvas.contains("ProgressView()"))
        XCTAssertTrue(canvas.contains("Starting…"))
        XCTAssertTrue(canvas.contains("Try Again"))
        XCTAssertTrue(canvas.contains("First launch can take a few minutes"))
    }

    func test_filesLocationBarClaimsFullWidthForBothLocations() throws {
        // WHY: Docker home happened to expand the bar through its explanatory
        // HStack, while Bot files collapsed the same bar to the picker's width
        // and floated it above only the editor pane.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private var filesTab") else {
            return XCTFail("files tab must exist")
        }
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\n            Group {")?.lowerBound ?? rest.endIndex
        let bar = String(rest[..<end])

        XCTAssertTrue(
            bar.contains(".frame(maxWidth: .infinity, alignment: .leading)"),
            "the location bar must claim the full Files width even when Bot files has no descriptive row"
        )
    }

    func test_guestCanvasOffersRebuildBeforeStopAndNoTerminalControl() throws {
        // WHY: Dockerfile changes need an explicit safe apply action beside the
        // running desktop; Terminal is unrelated and consumed scarce chrome.
        let source = try String(
            contentsOf: sourceURL("Sources/AppShell/BotComputerGuestScreenView.swift"),
            encoding: .utf8
        )
        guard let start = source.range(of: "struct BotComputerGuestCanvas") else {
            return XCTFail("guest canvas must exist")
        }
        let canvas = String(source[start.lowerBound...])
        let rebuild = try XCTUnwrap(canvas.range(of: "Text(rebuilding ? \"Rebuilding…\" : \"Rebuild\")")?.lowerBound)
        let stop = try XCTUnwrap(canvas.range(of: "Button(\"Stop\"")?.lowerBound)
        XCTAssertLessThan(rebuild, stop, "Rebuild must sit immediately before Stop")
        XCTAssertFalse(canvas.contains("Button(\"Terminal\""))
    }

    func test_detachedGuestDesktopPresentsRebuildFailureAlert() throws {
        // WHY: the shared Rebuild control is also mounted in the detached
        // desktop window, whose root must not silently swallow vm.errorMessage.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = source.range(of: "private struct BotGuestDesktopRoot") else {
            return XCTFail("detached guest root must exist")
        }
        let root = String(source[start.lowerBound...])
        XCTAssertTrue(root.contains(".alert(\"Bots\""))
        XCTAssertTrue(root.contains("vm.errorMessage"))
    }

    func test_rebuildDockerGuestPublishesProgressAndRejectsDuplicateWork() async throws {
        // WHY: image builds can take minutes. The first click must acknowledge
        // work immediately and a second click must not start a competing build.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let fake = RecordingDocker()
        vm.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        vm.dockerGuestReadyOverrideForTesting = nil
        try vm.ensureDockerGuest(botID: bot.id)
        fake.blocksBuild = true

        vm.rebuildDockerGuest(botID: bot.id)
        XCTAssertTrue(vm.isGuestRebuilding(bot.id))
        XCTAssertEqual(fake.buildStarted.wait(timeout: .now() + 1), .success)
        vm.rebuildDockerGuest(botID: bot.id)
        XCTAssertEqual(fake.builds.count, 1, "a visible in-flight rebuild must reject duplicate clicks")
        fake.allowBuild.signal()

        let completed = await waitUntil(timeout: 2) { !vm.isGuestRebuilding(bot.id) }
        XCTAssertTrue(completed)
        XCTAssertEqual(
            fake.builds,
            [BotComputerGuestSpec.recipeURL(appSupport: context.appSupportDirectory, botID: bot.id)]
        )
        XCTAssertTrue(vm.isGuestRunning(bot.id))
        XCTAssertEqual(vm.guestScreenURL(for: bot.id)?.host, "127.0.0.1")
    }

    func test_rebuildDockerGuestFailureKeepsCurrentDesktopRunning() async throws {
        // WHY: a bad Dockerfile must report failure without taking down the
        // already-running desktop that the user can still repair.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let fake = RecordingDocker()
        vm.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: fake,
            observeAttempts: 1,
            observeDelay: 0
        )
        vm.dockerGuestReadyOverrideForTesting = nil
        try vm.ensureDockerGuest(botID: bot.id)
        fake.startError = BotComputerGuestError.dockerUnavailable

        vm.rebuildDockerGuest(botID: bot.id)

        let completed = await waitUntil(timeout: 2) { !vm.isGuestRebuilding(bot.id) }
        XCTAssertTrue(completed)
        XCTAssertTrue(vm.isGuestRunning(bot.id), "the canonical desktop must survive a failed replacement")
        XCTAssertEqual(
            vm.errorMessage,
            "Could not rebuild the Linux desktop. The current desktop is still running."
        )
    }

    func test_guestCanvasStartingStateRendersOffscreen() throws {
        // WHY: the acknowledged launch state must produce a real macOS view,
        // not only compile-time copy that never reaches the rendered canvas.
        let canvas = BotComputerGuestCanvas(
            url: nil,
            running: false,
            rebuilding: false,
            launchState: .starting,
            startIdentifier: "test.desktop.start",
            rebuildIdentifier: "test.desktop.rebuild",
            stopIdentifier: "test.desktop.stop",
            screenIdentifier: "test.desktop.screen",
            onStart: {},
            onRebuild: {},
            onStop: {}
        )
        .frame(width: 360, height: 220)
        let hosting = NSHostingView(rootView: canvas)
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 220)
        hosting.wantsLayer = true
        let window = NSWindow(
            contentRect: hosting.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return XCTFail("starting canvas must create an offscreen bitmap")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 2_000)
        if let artifact = ProcessInfo.processInfo.environment["REMOTE_CODE_BOT_GUEST_ARTIFACT"] {
            try png.write(to: URL(fileURLWithPath: artifact), options: .atomic)
        }
    }

    func test_filesLocationBarRendersFullStudioWidthOffscreen() throws {
        // WHY: the modifier contract is also rendered through the real Studio
        // hierarchy so a passing source assertion cannot hide a broken view tree.
        let (_, vm, bot, _) = try makeDockerStudio()
        vm.setStudioFilesLocation(.botFiles, for: bot)
        vm.studioTab = .files
        let root = BotsRootView(vm: vm, embedsRosterRail: false)
            .frame(width: 1_100, height: 760)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 1_100, height: 760)
        hosting.wantsLayer = true
        let window = NSWindow(
            contentRect: hosting.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000)
        if let artifact = ProcessInfo.processInfo.environment["REMOTE_CODE_BOT_FILES_LAYOUT_ARTIFACT"] {
            try png.write(to: URL(fileURLWithPath: artifact), options: .atomic)
        }
    }

    func test_guestCanvasRunningControlsRenderOffscreen() throws {
        // WHY: Rebuild and Stop must materialize as macOS chrome, not only as
        // source copy that disappears under a conditional running branch.
        let canvas = BotComputerGuestCanvas(
            url: nil,
            running: true,
            rebuilding: false,
            launchState: .idle,
            startIdentifier: "test.desktop.start",
            rebuildIdentifier: "test.desktop.rebuild",
            stopIdentifier: "test.desktop.stop",
            screenIdentifier: "test.desktop.screen",
            onStart: {},
            onRebuild: {},
            onStop: {}
        )
        .frame(width: 640, height: 220)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: canvas)
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 220)
        hosting.wantsLayer = true
        let window = NSWindow(
            contentRect: hosting.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 2_000)
        if let artifact = ProcessInfo.processInfo.environment["REMOTE_CODE_BOT_GUEST_CONTROLS_ARTIFACT"] {
            try png.write(to: URL(fileURLWithPath: artifact), options: .atomic)
        }
    }

    func test_viewModelWiresBundledComputerGuestRecipe() throws {
        // WHY: recipeContext=nil left Studio unable to build the bundled
        // ComputerGuest image, so the Docker radio never enabled.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let wired = try XCTUnwrap(vm.computerGuestService?.recipeContextURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: wired.appendingPathComponent("Dockerfile").path)
        )
        let dockerfile = try String(
            contentsOf: wired.appendingPathComponent("Dockerfile"),
            encoding: .utf8
        )
        XCTAssertTrue(dockerfile.lowercased().contains("debian"))
    }

    func test_thisMacRuntimesPersistWhenDockerIsUnavailable() throws {
        // WHY: this-Mac create/save/send must work with Docker forced off.
        // Docker-with-GUI Save/Send must be refused without a PNG.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.dockerGuestReadyOverrideForTesting = false
        vm.computerGuestService = nil
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openStudio(piper)
        vm.studioDraft.desktopKind = .logicalExecutionSpace
        try vm.saveStudio()
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .logicalExecutionSpace)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("use the default browser"))

        vm.openStudio(piper)
        vm.studioDraft.desktopKind = .botOwnedBrowser
        try vm.saveStudio()
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .botOwnedBrowser)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("use my own browser"))

        vm.openStudio(piper)
        vm.studioDraft.desktopKind = .dockerDesktop
        XCTAssertThrowsError(try vm.saveStudio())
        XCTAssertEqual(vm.errorMessage, "Docker desktop is not ready.")
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .botOwnedBrowser)
        vm.desktopKindOverrideForTesting = .dockerDesktop
        XCTAssertFalse(vm.send("open the linux screen"))
        XCTAssertEqual(vm.errorMessage, "Docker desktop is not ready.")
    }

    func test_saveStudioPersistsIdentityWhenPublishedDockerGuestIsNotReady() throws {
        // WHY: LinkedIn Controller already published Docker GUI. Save Bot on
        // Profile still threw notReady whenever the global proveReady probe
        // had not finished, so name/description/instructions never persisted.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openStudio(piper)
        vm.dockerGuestReadyOverrideForTesting = true
        vm.studioDraft.desktopKind = .dockerDesktop
        try vm.saveStudio()
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .dockerDesktop)

        vm.dockerGuestReadyOverrideForTesting = false
        vm.computerGuestService = nil
        vm.studioDraft.name = "Piper Prime"
        vm.studioDraft.title = "Night scout"
        vm.studioDraft.description = "Identity only"
        vm.studioDraft.soul = "Do the job. Ask when blocked."
        let saved = try vm.saveStudio()
        XCTAssertEqual(saved.name, "Piper Prime")
        XCTAssertEqual(saved.title, "Night scout")
        XCTAssertEqual(saved.description, "Identity only")
        XCTAssertEqual(vm.selectedRevision?.soul, "Do the job. Ask when blocked.")
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .dockerDesktop)
        XCTAssertNil(vm.errorMessage)
    }

    func test_saveBotAlertKeepsStudioErrorCopy_becauseRawNotReadyMustNotSurface() throws {
        // WHY: Save Bot overwrote saveStudio's "Docker desktop is not ready."
        // with String(describing: BotComputerGuestError.notReady) → "notReady".
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        vm.errorMessage = "Docker desktop is not ready."
        vm.presentAlertError(BotComputerGuestError.notReady)
        XCTAssertEqual(vm.errorMessage, "Docker desktop is not ready.")

        vm.errorMessage = nil
        vm.presentAlertError(BotComputerGuestError.notReady)
        XCTAssertEqual(vm.errorMessage, "Docker desktop is not ready.")
        XCTAssertNotEqual(vm.errorMessage, "notReady")

        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("vm.presentAlertError(error)"))
        XCTAssertTrue(source.contains("bots.studio.save"))
    }

    func test_leftoverDedicatedLocalVMDoesNotBecomeDockerWhenGuestReady() throws {
        // WHY: leftover Dedicated local VM must stay leftover. A passing
        // probe must not rewrite it into Docker with GUI.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openStudio(piper)
        vm.dockerGuestReadyOverrideForTesting = true
        vm.studioDraft.desktopKind = .dedicatedLocalVM
        try vm.saveStudio()
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .logicalExecutionSpace)
        XCTAssertNotEqual(vm.selectedRevision?.desktopKind, .dockerDesktop)
        XCTAssertFalse(
            BotDesktopKind.dedicatedLocalVM.isSelectable(
                flags: BotControlPlaneFlags(botsControlPlaneEnabled: true),
                guestReady: true
            )
        )
    }

    func test_studioSavesBotOwnedAndDockerWhenReady() throws {
        // WHY: the owner must persist this Mac bot browser without Docker,
        // and Docker desktop only after the radio is enabled.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openStudio(piper)
        vm.studioDraft.desktopKind = .botOwnedBrowser
        try vm.saveStudio()
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .botOwnedBrowser)

        vm.dockerGuestReadyOverrideForTesting = true
        vm.studioDraft.desktopKind = .dockerDesktop
        try vm.saveStudio()
        XCTAssertEqual(vm.selectedRevision?.desktopKind, .dockerDesktop)
    }

    func test_dockerDesktopSendFailsClosedWithoutGuestPNG() throws {
        // WHY: Codex advisor: published dockerDesktop must not compile/send
        // HID on this Mac when the guest cannot return a PNG.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openDesk(piper)
        vm.dockerGuestReadyOverrideForTesting = false
        vm.desktopKindOverrideForTesting = .dockerDesktop
        XCTAssertFalse(vm.send("open chrome"))
        XCTAssertEqual(vm.errorMessage, "Docker desktop is not ready.")
        vm.desktopKindOverrideForTesting = nil
        vm.dockerGuestReadyOverrideForTesting = true
        XCTAssertTrue(vm.send("open chrome"))
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
            BotDesktopKind.logicalExecutionSpaceHonestyLabel
        )
        XCTAssertTrue(
            BotDesktopKind.logicalExecutionSpaceHonestyLabel.lowercased().contains("not isolated")
        )

        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let settings = try String(contentsOf: sourceURL("Sources/AppShell/SettingsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("desktopHonestyLabel"))
        XCTAssertFalse(
            source.contains("private var studioSummary"),
            "Configuration summary is gone; it cannot repeat the Desktop honesty block"
        )
        XCTAssertTrue(source.contains("studioAvatarPane"))
        XCTAssertTrue(
            BotRoute.fallbackOrderHonesty.contains("not shipped in P1a"),
            "P1a fallback-order honesty stays on the compiler path after Studio lost the routing panel"
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
        XCTAssertEqual(vm.permissionLabel(for: bot), "Supervised")
        XCTAssertEqual(vm.desktopHonestyLabel, BotDesktopKind.logicalExecutionSpaceHonestyLabel)
    }

    func test_petOpenBotsDesk_destsThatBotsDesk() throws {
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        router.botsViewModel = vm
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        _ = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(try router.openBotsDesk(botID: piper.id))
        XCTAssertEqual(vm.screen, .desk)
        XCTAssertEqual(vm.selectedBotID, piper.id)
        XCTAssertFalse(try router.openBotsDesk(botID: BotID()))
        XCTAssertEqual(vm.selectedBotID, piper.id)
    }

    func test_petProjectsDestAttention_andHidesDisabledBots() throws {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let muted = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude, notificationsEnabled: false)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("From Piper"))
        let conversation = try XCTUnwrap(vm.selectedConversation)
        vm.openDesk(muted)
        vm.applyFollowThroughForTests(bot: piper, conversation: conversation, status: .completed)
        let dest = PetDestAttentionSnapshot(
            bots: try context.botStore.list(),
            conversations: try context.botStore.listConversations(
                attentionStates: [.unreadActivity, .needsAttention]
            ),
            attention: try context.botStore.listAttention(),
            linkedThreadIDs: try context.botStore.listLinkedAgentThreadIDs()
        )
        let items = PetAttentionStore.projectDest(dest)
        XCTAssertTrue(items.contains { $0.route == .botsDesk(botID: piper.id) })
        XCTAssertFalse(items.contains { $0.route == .botsDesk(botID: muted.id) })
        XCTAssertFalse(items.contains { $0.title.localizedCaseInsensitiveContains("from piper") })
    }

    func test_petMarkReadFollowsDestLedger() throws {
        let context = try makeContext()
        let store = PetAttentionStore(
            threadRepository: context.threadRepo,
            callbackRepository: context.providerPendingCallbackRepo,
            notificationRepository: NotificationRepository(db: context.db),
            destLookup: {
                PetDestAttentionSnapshot(
                    bots: try context.botStore.list(),
                    conversations: try context.botStore.listConversations(
                        attentionStates: [.unreadActivity, .needsAttention]
                    ),
                    attention: try context.botStore.listAttention(),
                    linkedThreadIDs: try context.botStore.listLinkedAgentThreadIDs()
                )
            },
            markBotConversationViewed: { id in
                guard var conversation = try context.botStore.conversation(id: id) else { return }
                conversation.unread = false
                conversation.attentionState = .none
                try context.botStore.upsertConversation(conversation)
            }
        )
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        // Dest unread is the dest ledger. send() without a router writes a
        // leftover dest question and would hide this completed row.
        try context.botStore.upsertConversation(
            BotConversation(botID: piper.id, title: "Brief", unread: true, attentionState: .unreadActivity)
        )
        let item = try XCTUnwrap(try store.refresh().items.first { $0.route == .botsDesk(botID: piper.id) })
        XCTAssertEqual(item.classification, .completed)
        XCTAssertEqual(try store.openAndMarkRead(itemID: item.id) { _ in true }, .marked)
        XCTAssertTrue(try store.refresh().items.filter { $0.route == .botsDesk(botID: piper.id) }.isEmpty)
    }

    func test_deskWorkLogCardIsFullWidthOnItsOwnLine_becauseStatusCardsAreNotChatBubbles() throws {
        // WHY: a 56pt timestamp gutter beside the Supervised-run panel left a
        // hugging card. Status cards occupy one complete line at column width.
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        guard let start = bots.range(of: "private func deskWorkLogRow") else {
            return XCTFail("deskWorkLogRow must exist")
        }
        let rest = bots[start.lowerBound...]
        let end = rest.range(of: "\n    private func workLogTone")?.lowerBound ?? rest.endIndex
        let slice = String(bots[start.lowerBound..<end])
        XCTAssertTrue(slice.contains("AgentChatStatusCard("))
        XCTAssertFalse(
            slice.contains("frame(width: 56"),
            "work-log must not keep a timestamp column beside the panel"
        )
        XCTAssertFalse(
            slice.contains("style: .time"),
            "time lives inside the shared full-width card, not a Desk gutter"
        )
    }

    func test_deskTimelineUsesSharedAgentAppScrollContainer_becauseChatMustFollowTheSamePin() throws {
        // WHY: Desk used a plain ScrollView. Agent App pin/FAB/BOTTOM lived
        // only in AgentAppSurface, so send did not auto-scroll. Same control
        // must be one shared container.
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let start = try XCTUnwrap(bots.range(of: "private func deskTimeline"))
        let rest = bots[start.lowerBound...]
        let end = rest.range(of: "\n    private func deskBubble")?.lowerBound ?? rest.endIndex
        let slice = String(bots[start.lowerBound..<end])
        XCTAssertTrue(slice.contains("AgentChatTimelineScrollContainer("))
        XCTAssertTrue(slice.contains("deskTimelineRejoinToken"))
        XCTAssertTrue(slice.contains("\"bots.desk.scrollToBottom\""))
        XCTAssertFalse(slice.contains("ScrollView {"))
        let agent = try String(contentsOf: sourceURL("Sources/Surfaces/AgentAppSurface.swift"), encoding: .utf8)
        XCTAssertTrue(agent.contains("AgentChatTimelineScrollContainer("))
        XCTAssertFalse(agent.contains("private struct TimelineScrollFollower"))
        let chrome = try String(contentsOf: sourceURL("Sources/Surfaces/AgentChatTimelineChrome.swift"), encoding: .utf8)
        XCTAssertTrue(chrome.contains("struct AgentChatTimelineScrollFollower"))
        XCTAssertTrue(chrome.contains("Scroll to latest message"))
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
        XCTAssertEqual(row.title, "\(AgentPermissionMode.supervised.displayName) run")
        XCTAssertEqual(
            BotsDeskFollowThrough.workLogRow(for: run, mode: .fullAccess).title,
            "\(AgentPermissionMode.fullAccess.displayName) run"
        )
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

    func test_studioScheduleSpecStaysOnOwningBot_becauseFrequencyMustNotLeak() throws {
        // WHY: Studio Schedule Tasks persist name/prompt/when-note per bot,
        // but Frequency + Provider live on routineSpec, which stayed
        // process-wide after the When field became BotScheduleSpecEditor.
        // Quinn must not inherit Piper's weekdays/Grok row, and coming
        // back must restore Piper's Frequency.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "Reviewer", provider: .claude)
        vm.beginEdit(piper)
        vm.routineName = "QA morning scan"
        vm.routinePrompt = "List failing tests from last night and name the file."
        vm.routineSpec.frequency = .weekdays
        vm.routineSpec.localTimeHour = 9
        vm.routineSpec.localTimeMinute = 0
        vm.routineSpec.provider = .grok
        vm.beginEdit(quinn)
        XCTAssertEqual(vm.routineName, "", "Quinn Studio must not inherit Piper's task name")
        XCTAssertNotEqual(
            vm.routineSpec.frequency,
            .weekdays,
            "Quinn must not inherit Piper's Frequency"
        )
        XCTAssertEqual(vm.routineSpec.frequency, .daily)
        vm.routineSpec.frequency = .hourly
        vm.beginEdit(piper)
        XCTAssertEqual(vm.routineName, "QA morning scan")
        XCTAssertEqual(vm.routineSpec.frequency, .weekdays)
        XCTAssertEqual(vm.routineSpec.localTimeHour, 9)
        XCTAssertEqual(vm.routineSpec.provider, .grok)
        vm.beginEdit(quinn)
        XCTAssertEqual(vm.routineSpec.frequency, .hourly)
    }

    func test_studioScheduleSpecSurvivesRelaunch_becauseFrequencyIsUserWork() throws {
        // WHY: an unfinished Frequency pick is the same class of loss as
        // an unsent task name. Relaunch must restore the spec, not the
        // process-wide default Daily-at-now.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let bot = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.beginEdit(bot)
        vm.routineName = "QA morning scan"
        vm.routinePrompt = "List failing tests from last night and name the file."
        vm.routineSpec.frequency = .weekdays
        vm.routineSpec.localTimeHour = 9
        vm.routineSpec.localTimeMinute = 0
        vm.routineSpec.provider = .grok
        let reopened = BotsViewModel(context: context)
        XCTAssertEqual(reopened.selectedBotID, bot.id)
        XCTAssertEqual(reopened.routineName, "QA morning scan")
        XCTAssertEqual(reopened.routineSpec.frequency, .weekdays)
        XCTAssertEqual(reopened.routineSpec.localTimeHour, 9)
        XCTAssertEqual(reopened.routineSpec.provider, .grok)
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
                let composition = AgentChatLiveTurnChrome.compose(live)
                XCTAssertTrue(
                    composition.outside.isEmpty,
                    "matching assistant items must yield to the turn final so Desk and Agent App paint one reply"
                )
                XCTAssertTrue(AgentChatLiveTurnChrome.shouldRenderFinalMessage(live))
                return live.finalAssistantMessage
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

    func test_askedBotDeskShowsFromHostChromeNotAskPrompt() throws {
        // WHY: the asked bot Desk painted "Ceo asked you:" as a raw user
        // bubble. It must show From <host> chrome and the actual ask.
        let (vm, piper, quinn) = try makeMentionPair(peerReply: "PONG from Quinn")
        XCTAssertTrue(vm.send("@\(quinn.handle) Pergunte ao bot seu nome e função"))
        let inbound = try XCTUnwrap(
            vm.deskTranscriptForTesting(botID: quinn.id).first { $0.role == .user }
        )
        XCTAssertEqual(inbound.peer?.direction, .fromPeer)
        XCTAssertEqual(inbound.peer?.name, piper.name)
        XCTAssertEqual(inbound.peer?.handle, piper.handle)
        XCTAssertEqual(inbound.peer?.avatarSymbol, piper.avatarSymbol)
        XCTAssertFalse(inbound.peer?.avatarSymbol.isEmpty == true)
        XCTAssertEqual(inbound.peer?.caption, "From \(piper.name)")
        XCTAssertEqual(inbound.text, "@\(quinn.handle) Pergunte ao bot seu nome e função")
        XCTAssertFalse(inbound.text.contains("asked you:"))
        XCTAssertFalse(BotPeerTranscript.isPeerAskUserText(inbound.text))
    }

    func test_restoreHidesPeerAskPromptAndKeepsFromHostChrome() throws {
        // WHY: the asked bot's thread stores the internal "Piper asked you:"
        // provider line. Reload must not paint that wrapper, and must keep
        // From-host chrome from the handoff.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("@\(quinn.handle) Pergunte ao bot seu nome e função"))

        let reopened = BotsViewModel(context: context)
        reopened.openDesk(quinn)
        XCTAssertFalse(
            reopened.deskMessages.contains { BotPeerTranscript.isPeerAskUserText($0.text) },
            "internal peer-ask prompt must not paint as a Desk bubble"
        )
        let inbound = try XCTUnwrap(reopened.deskMessages.first { $0.role == .user })
        XCTAssertEqual(inbound.peer?.direction, .fromPeer)
        XCTAssertEqual(inbound.peer?.name, piper.name)
        XCTAssertEqual(inbound.peer?.handle, piper.handle)
        XCTAssertEqual(inbound.peer?.avatarSymbol, piper.avatarSymbol)
        XCTAssertTrue(inbound.text.contains("Pergunte ao bot seu nome e função"))
        XCTAssertFalse(inbound.text.contains("asked you:"))
    }

    func test_waitingOriginRosterShowsWorkingSpinner() async throws {
        // WHY: Ceo stayed Needs you in the roster while the transcript
        // already said Waiting for Bot. Both endpoints of a live wait
        // must show Working with the busy spinner.
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        let peerRunner = ControlledBotHandoffRunner(provider: .claude)
        context.coordinator.replaceProvider(.claude, runner: peerRunner)
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(piper)
        vm.setDeskProvider(.claude)
        XCTAssertTrue(vm.send("@\(quinn.handle) WAIT_SPINNER ask the peer"))
        let peerBecameActive = await waitUntil(timeout: 5) {
            peerRunner.requests.contains { $0.prompt.contains("WAIT_SPINNER") }
                && vm.peerHandoffSnapshotsForTesting().contains { $0.phase == .peerRunning }
        }
        XCTAssertTrue(peerBecameActive, "the peer start must persist .peerRunning before roster is judged")
        XCTAssertEqual(vm.attentionState(for: piper), .working)
        XCTAssertEqual(vm.attentionState(for: quinn), .working)
        XCTAssertTrue(BotsChrome.rosterShowsBusySpinner(for: vm.attentionState(for: piper)))
        XCTAssertTrue(BotsChrome.rosterShowsBusySpinner(for: vm.attentionState(for: quinn)))
    }

    func test_sendWithMentionStoresPeerAvatar() throws {
        // WHY: hop chrome used initials because BotDeskPeer dropped the
        // blobatar token. The peer row must carry the published symbol.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(piper)
        XCTAssertTrue(vm.send("@\(quinn.handle) check WhatsApp"))
        let outbound = try XCTUnwrap(vm.deskMessages.last)
        XCTAssertEqual(outbound.peer?.avatarSymbol, quinn.avatarSymbol)
        XCTAssertFalse(outbound.peer?.avatarSymbol.isEmpty == true)
    }

    func test_restoreDeskMessagesHidesHostHopPrompt() throws {
        // WHY: the host hop is an internal prompt. Restoring it as a user
        // bubble showed raw markdown ("Bot replied: **Nome:**") on Desk.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .claude)
        let thread = AgentThread(title: "Ask", provider: .claude, model: "opus")
        try context.threadRepo.upsert(thread)
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "Pergunte ao bot seu nome",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: BotPeerTranscript.hostHopPrompt(
                peerName: "Bot",
                reply: "**Nome:** Bot\n**Cargo:** vazio",
                userText: "Pergunte ao bot seu nome"
            ),
            createdAt: Date(timeIntervalSince1970: 1_700_000_010)
        ))
        try context.botStore.upsertConversation(
            BotConversation(botID: piper.id, title: "Pergunte ao bot seu nome", linkedAgentThreadID: thread.id)
        )
        vm.openDesk(piper)
        XCTAssertTrue(vm.deskMessages.contains { $0.text == "Pergunte ao bot seu nome" })
        XCTAssertFalse(
            vm.deskMessages.contains { BotPeerTranscript.isHostHopUserText($0.text) },
            "internal hop prompt must not paint as a Desk bubble"
        )
        XCTAssertFalse(vm.deskMessages.contains { $0.text.contains("**Nome:**") })
    }

    func test_openingAnotherThreadDoesNotKeepPreviousLiveTurns_becauseEachConversationOwnsItsThread() throws {
        // WHY: liveTimelineByBot kept a hop's Worked rows after the user
        // opened a new Desk thread on the same teammate.
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let piper = try vm.create(name: "Piper", title: "Scout", provider: .claude)

        let mentionThread = AgentThread(title: "Mention", provider: .claude, model: "opus")
        let oiThread = AgentThread(title: "oi", provider: .claude, model: "opus")
        try context.threadRepo.upsert(mentionThread)
        try context.threadRepo.upsert(oiThread)
        let mentionRun = AgentRun(
            threadId: mentionThread.id,
            provider: .claude,
            model: "opus",
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_010),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_040)
        )
        let oiRun = AgentRun(
            threadId: oiThread.id,
            provider: .claude,
            model: "opus",
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_110),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_120)
        )
        try context.runRepo.upsert(mentionRun)
        try context.runRepo.upsert(oiRun)
        try persistStreamEvents(
            context: context,
            run: mentionRun,
            events: [
                .turnStarted(turnId: "mention-turn"),
                .itemStarted(item: AssistantItem(
                    id: "mention-tool",
                    turnId: "mention-turn",
                    type: .tool,
                    state: .completed,
                    summary: "Bash",
                    startedAtMs: 1_700_000_010_000,
                    finishedAtMs: 1_700_000_020_000
                )),
                .turnCompleted(turnId: "mention-turn", finalMessage: "I'll treat this as a CEO test run"),
            ]
        )
        try persistStreamEvents(
            context: context,
            run: oiRun,
            events: [
                .turnStarted(turnId: "oi-turn"),
                .turnCompleted(turnId: "oi-turn", finalMessage: "Oi. Sou o Ceo."),
            ]
        )
        try context.messageRepo.append(AgentMessage(
            threadId: mentionThread.id,
            role: .user,
            content: "Pergunte ao bot",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try context.messageRepo.append(AgentMessage(
            threadId: oiThread.id,
            role: .user,
            content: "oi",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        ))
        let mentionConversation = BotConversation(
            botID: piper.id,
            title: "Pergunte ao bot",
            linkedAgentThreadID: mentionThread.id
        )
        let oiConversation = BotConversation(
            botID: piper.id,
            title: "oi",
            linkedAgentThreadID: oiThread.id
        )
        try context.botStore.upsertConversation(mentionConversation)
        try context.botStore.upsertConversation(oiConversation)

        vm.openDesk(piper)
        vm.selectDeskThread(mentionConversation.id)
        XCTAssertTrue(
            vm.deskLiveTimeline.turns.contains { $0.finalAssistantMessage == "I'll treat this as a CEO test run" },
            "mention thread must replay its own live turn"
        )

        vm.selectDeskThread(oiConversation.id)
        XCTAssertFalse(
            vm.deskLiveTimeline.turns.contains { $0.finalAssistantMessage == "I'll treat this as a CEO test run" },
            "oi must not inherit the mention thread's richer live timeline"
        )
        XCTAssertTrue(
            vm.deskLiveTimeline.turns.contains { $0.finalAssistantMessage == "Oi. Sou o Ceo." }
        )
        XCTAssertFalse(vm.deskMessages.contains { $0.text.contains("Pergunte") })
        XCTAssertTrue(vm.deskMessages.contains { $0.text == "oi" })
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
        let live = BotMemoryFileText(path: "MEMORY.md", body: "Prefers dark mode")
        let enabled = BotSkillBinding(botID: bot.id, skillID: "weekly-account-health", enabled: true)
        let disabled = BotSkillBinding(botID: bot.id, skillID: "off-skill", enabled: false)

        let prompt = BotsDeskFollowThrough.composeRunPrompt(
            bot: bot,
            revision: revision,
            userText: "Summarize overnight",
            memoryFiles: [live],
            skills: [enabled, disabled]
        )

        XCTAssertTrue(prompt.contains("Prefers dark mode"))
        XCTAssertTrue(prompt.contains("### MEMORY.md"))
        XCTAssertTrue(prompt.contains("Role: Scout"))
        XCTAssertFalse(prompt.contains("You are Piper (@piper) — Scout"))
        XCTAssertTrue(prompt.contains("Instructions:"))
        XCTAssertFalse(prompt.contains("Standing instructions:"))
        XCTAssertFalse(prompt.contains("Skills: weekly-account-health"))
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
        try vm.botHome(for: bot).writeFile(
            relativePath: BotHome.memoryName,
            contents: "- Prefers dark mode\n"
        )
        vm.composerText = "Summarize overnight"
        let preview = try XCTUnwrap(vm.previewBrain())
        XCTAssertEqual(preview.compiledPayload, BotsDeskFollowThrough.composeRunPrompt(
            bot: bot,
            revision: try XCTUnwrap(vm.selectedRevision),
            userText: "Summarize overnight",
            memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
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
                memoryFiles: vm.selectedBot.map { vm.memoryFileTexts(for: $0) } ?? [],
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
        XCTAssertEqual(vm.studioDesktopSummary, BotDesktopKind.logicalExecutionSpace.displayTitle)
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
        vm.studioTab = .files
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
        XCTAssertEqual(vm.studioDesktopSummary, BotDesktopKind.logicalExecutionSpace.displayTitle)
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
        XCTAssertEqual(vm.studioDesktopSummary, BotDesktopKind.logicalExecutionSpace.displayTitle)
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
        // WHY: Memory left Studio as a tab. A leftover "Brain / Memory"
        // header would still claim memory lives under Brain.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertFalse(
            source.contains("Brain / Memory"),
            "Memory's header must not name the Brain sibling tab"
        )
        XCTAssertFalse(
            source.contains("private var memoryTab"),
            "Memory lives in Files, not a Studio tab body"
        )
    }

    func test_studioProfileHasNoProviderRouting() throws {
        // WHY: a published Default route locked teammates to one provider.
        // Studio Profile is identity + instructions. Account is the Desk
        // composer, per send.
        let source = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("private var studioProvider"))
        XCTAssertFalse(source.contains("bots.studio.provider"))
        XCTAssertFalse(source.contains("bots.studio.routing"))
        XCTAssertFalse(source.contains("BotsChrome.Label.providerRouting"))
        let chrome = try String(contentsOf: sourceURL("Sources/AppShell/BotsChrome.swift"), encoding: .utf8)
        XCTAssertFalse(chrome.contains("Provider routing"))
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
        // composes shape and hue on the right pane. Expression follows
        // live attention; the creature never has a plate.
        let bots = try String(contentsOf: sourceURL("Sources/AppShell/BotsWindow.swift"), encoding: .utf8)
        let editor = try String(contentsOf: sourceURL("Sources/AppShell/BotsBlobatarView.swift"), encoding: .utf8)
        XCTAssertTrue(bots.contains("BotBlobatarEditor"))
        XCTAssertTrue(bots.contains("studioAvatarPane"))
        XCTAssertTrue(bots.contains("bots.studio.avatar.pane"))
        XCTAssertTrue(bots.contains("BotBlobatarSpec.default.token"))
        XCTAssertTrue(editor.contains("bots.studio.avatar.shape"))
        XCTAssertFalse(editor.contains("bots.studio.avatar.expression"))
        XCTAssertFalse(editor.contains("bots.studio.avatar.background"))
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
        XCTAssertTrue(
            bots.contains("ForEach(BotStudioTab.allCases.filter(\\.isUserFacing))"),
            "Brain stays on the enum for leftover persist; the Studio strip must not render it"
        )
        XCTAssertFalse(bots.contains("bots.studio.tab.memory"))
        XCTAssertFalse(bots.contains("bots.studio.tab.skills"))
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
        XCTAssertEqual(BotStudioTab.allCases.map(\.id), ["profile", "brain", "files", "routines", "security"])
        XCTAssertEqual(
            BotStudioTab.allCases.filter(\.isUserFacing).map(\.id),
            ["profile", "files", "routines", "security"]
        )
        XCTAssertEqual(
            BotDeskInspectorTab.allCases.filter(\.isUserFacing).map(\.id),
            ["routines"]
        )
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
        XCTAssertFalse(bots.contains("bots.studio.routing"))
        XCTAssertTrue(bots.contains("bots.studio.soul"))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.descriptionCaption))
        XCTAssertTrue(chrome.contains(BotsChrome.Label.instructionsCaption))
        XCTAssertTrue(bots.contains("BotsChrome.Label.descriptionCaption"))
        XCTAssertTrue(bots.contains("BotsChrome.Label.instructionsCaption"))
        XCTAssertTrue(bots.contains("Empty uses the built-in teammate default"))
        XCTAssertTrue(
            BotsChrome.Label.descriptionCaption.contains("Who this teammate is"),
            "Description must say who, not how"
        )
        XCTAssertTrue(
            BotsChrome.Label.instructionsCaption.contains("How this teammate should work"),
            "Instructions must say how, not who"
        )
        XCTAssertTrue(bots.contains("refreshGeneratedStandingInstructions"))
        XCTAssertTrue(
            bots.contains(".accessibilityLabel(BotsChrome.Label.instructions)"),
            "Soul TextArea must name Instructions the way Description names Description"
        )
        XCTAssertFalse(
            bots.contains("Remember a fact"),
            "Memory CRUD left Studio; facts live in MEMORY.md"
        )
        XCTAssertFalse(
            bots.contains("bots.memory.correct.field"),
            "Correct memory left Studio; edit MEMORY.md in Files"
        )
        XCTAssertFalse(
            bots.contains("NSAlert()"),
            "Correct memory must not come back as a modal alert"
        )
        XCTAssertFalse(
            bots.contains(".accessibilityLabel(\"Skill catalog id\")"),
            "Skills catalog Add left Studio; skills live in skills/<slug>/SKILL.md"
        )
        XCTAssertFalse(
            bots.contains(".accessibilityLabel(binding.skillID)"),
            "Skills enable switch left Studio; skills live in Files"
        )
        XCTAssertTrue(
            bots.contains(".accessibilityLabel(\"Active, \\(routine.definition.name)\")"),
            "Routines Active switch must say Active plus the routine name, not only the title"
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
        XCTAssertTrue(bots.contains("bots.studio.avatar.pane"))
        XCTAssertFalse(bots.contains("bots.studio.summary"))
        XCTAssertTrue(bots.contains("bots.studio.desktop.honesty"))
        XCTAssertTrue(
            bots.contains("BotsChrome.Label.roleAndIdentity") || chrome.contains("Role & Identity"),
            "Studio Profile header must use the Role & Identity token"
        )
        XCTAssertFalse(
            bots.contains("BotsChrome.Label.providerRouting") || chrome.contains("Provider routing"),
            "Studio must not mention a published provider"
        )
        XCTAssertTrue(
            bots.contains("studioAvatarPane"),
            "Studio Profile right pane must be the avatar, not Configuration summary"
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
        XCTAssertTrue(bots.contains("AgentChatStatusCard("))
        XCTAssertTrue(bots.contains("\"bots.desk.workLog\""))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.desktop\")"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.desktop.honesty\")"))
        XCTAssertTrue(
            bots.contains("bots.desk.desktop.guestScreen"),
            "Docker GUI must expose the live screen in the inspector desktop pane"
        )
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.name\")"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.handle\")"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.job\")"))
        XCTAssertFalse(bots.contains("accessibilityIdentifier(\"bots.desk.provider\")"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.model\")"))
        XCTAssertTrue(bots.contains("\"bots.desk.permission\""))
        XCTAssertTrue(bots.contains("bots.desk.role.user"))
        XCTAssertTrue(bots.contains("bots.desk.role.assistant"))
        XCTAssertTrue(bots.contains("accessibilityIdentifier(\"bots.desk.inspector\")"))
        XCTAssertTrue(bots.contains("bots.studio.tab.brain"))
        XCTAssertTrue(bots.contains("bots.desk.inspector.tab.brain"))
        XCTAssertFalse(
            bots.contains("ForEach(BotDeskInspectorTab.allCases"),
            "A single user-facing tab must render as a header, not a dead one-chip strip"
        )
        XCTAssertTrue(
            bots.contains("Text(resolvedInspectorTab.title)"),
            "The Desk inspector header must resolve through the leftover-persist remap"
        )
        XCTAssertFalse(bots.contains("bots.desk.inspector.tab.memory"))
        XCTAssertTrue(bots.contains("bots.desk.inspector.tab.routines"))
        XCTAssertTrue(bots.contains("bots.desk.inspector.brain"))
        XCTAssertFalse(bots.contains("bots.desk.inspector.memory"))
        XCTAssertTrue(bots.contains("bots.desk.inspector.routines"))
        XCTAssertTrue(bots.contains("bots.brain.honesty"))
        XCTAssertTrue(bots.contains("bots.brain.source"))
        XCTAssertTrue(bots.contains("bots.brain.effective"))
        XCTAssertTrue(bots.contains("bots.brain.whyMemory"))
        XCTAssertTrue(bots.contains("bots.brain.digest"))
        XCTAssertFalse(bots.contains("bots.memory.field"))
        XCTAssertFalse(bots.contains("bots.memory.add"))
        XCTAssertFalse(bots.contains("bots.memory.list"))
        XCTAssertFalse(bots.contains("bots.memory.correct"))
        XCTAssertFalse(bots.contains("bots.memory.forget"))
        XCTAssertFalse(bots.contains("bots.studio.skills.remove"))
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

    func test_modeSwitcherShowsWorkspaces_becauseUsersSeeWorkspaceModeNotInternalAgenticName() {
        // WHY: the left mode is the workspace list. Shipping "Agentic" as the
        // visible tab name was product jargon; the control must say Workspaces.
        XCTAssertEqual(BotsChrome.Label.agentic, "Workspaces")
        XCTAssertEqual(BotsChrome.Label.bots, "Bots")
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
        XCTAssertTrue(bots.contains("vm.openScheduleTasks"),
                      "Bots Schedule Tasks must open the bots routines overview, not Agent dest")
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

    private func fullReloadCounts(_ viewModel: BotsViewModel) -> [Int] {
        [
            viewModel.fleetReloadCountForTesting,
            viewModel.studioSupportReloadCountForTesting,
        ]
    }

    private func peerHandoffPerformancePayload(
        rowCount: Int,
        targetOriginBotID: BotID
    ) throws -> (data: Data, targetActivityID: UUID, siblingActivityID: UUID) {
        precondition(rowCount >= 2)
        let targetActivityID = UUID()
        let siblingActivityID = UUID()
        let retainedOriginBotID = BotID()
        let route = T005PeerHandoffRouteFixture(
            provider: .codex,
            providerInstanceID: "codex",
            model: "t005-model",
            permissionMode: .supervised,
            reasoningEffort: .medium,
            serviceTier: .auto,
            runAsUser: AgentRunAsUser(
                generatedUID: "t005-fixture",
                shortName: "fixture",
                uid: 0,
                gid: 0,
                homePath: "/tmp/t005-fixture"
            ),
            routingConfiguration: nil
        )
        var rows: [UUID: T005PeerHandoffRecordFixture] = [:]
        rows.reserveCapacity(rowCount)
        for index in 0..<rowCount {
            let activityID: UUID
            if index == 0 {
                activityID = targetActivityID
            } else if index == 1 {
                activityID = siblingActivityID
            } else {
                activityID = UUID()
            }
            rows[activityID] = T005PeerHandoffRecordFixture(
                version: 2,
                activityID: activityID,
                originBotID: index == 0 ? targetOriginBotID : retainedOriginBotID,
                originConversationID: nil,
                originAgentThreadID: nil,
                peerBotID: BotID(),
                peerConversationID: BotConversationID(),
                peerThreadID: nil,
                peerRunID: nil,
                inboundMessageID: activityID,
                peerName: "Peer \(index)",
                peerTitle: "Performance fixture",
                peerHandle: "peer-\(index)",
                outboundText: "retained row \(index)",
                createdAt: Date(timeIntervalSinceReferenceDate: Double(index)),
                peerRoute: route,
                hostThreadID: nil,
                hostRunID: nil,
                hostRoute: nil,
                replyText: "completed row \(index)",
                replyCreatedAt: Date(timeIntervalSinceReferenceDate: Double(index + 1)),
                phase: .completed
            )
        }
        return (
            try JSONEncoder().encode(rows),
            targetActivityID,
            siblingActivityID
        )
    }

    private func measurePeerHandoffDeletion(
        label: String,
        payload: Data,
        targetOriginBotID: BotID,
        targetActivityID: UUID,
        siblingActivityID: UUID
    ) throws -> Double {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("peer-perf-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            UserDefaults.standard.removeObject(forKey: "bots.peerTurns.v2")
            try? FileManager.default.removeItem(at: root)
        }

        UserDefaults.standard.set(payload, forKey: "bots.peerTurns.v2")
        XCTAssertTrue(UserDefaults.standard.synchronize())
        let (_, db) = try Bootstrap(
            channel: .debug,
            appSupportOverride: root.path
        ).run()
        let threadRepo = AgentThreadRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let queuedMessageRepo = AgentQueuedMessageRepository(db: db)
        let checkpointRepo = AgentTurnCheckpointRepository(db: db)
        let settingsRepo = SettingsRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            checkpointRepo: checkpointRepo,
            providers: [:]
        )
        var authority: BotPeerHandoffAuthority? = BotPeerHandoffAuthority(
            botStore: BotStore(db: db),
            threadRepo: threadRepo,
            runRepo: runRepo,
            messageRepo: messageRepo,
            queuedMessageRepo: queuedMessageRepo,
            checkpointRepo: checkpointRepo,
            settingsRepo: settingsRepo,
            coordinator: coordinator,
            appSupportDirectory: root
        )
        weak var releasedAuthority = authority
        let deletion = try XCTUnwrap(authority).beginDeletion(originBotID: targetOriginBotID)

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let committed = try XCTUnwrap(authority).commitDeletion(deletion)
        let finishedAt = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(committed, "\(label) must commit through the production authority path")

        let storedPayload = try XCTUnwrap(UserDefaults.standard.data(forKey: "bots.peerTurns.v2"))
        let retained = try JSONDecoder().decode(
            [UUID: T005PeerHandoffRecordFixture].self,
            from: storedPayload
        )
        XCTAssertEqual(retained.count, 999, "\(label) must retain exactly 999 supported v2 rows")
        XCTAssertNil(retained[targetActivityID], "\(label) must delete the exact selected row")
        XCTAssertNotNil(retained[siblingActivityID], "\(label) must preserve an unrelated sibling")
        XCTAssertEqual(
            try settingsRepo.get("bots.peerTurns.v2"),
            "base64:\(storedPayload.base64EncodedString())",
            "\(label) SQLite and mirror must describe the same committed envelope"
        )

        authority = nil
        XCTAssertNil(releasedAuthority, "\(label) must not accumulate an authority between samples")
        return Double(finishedAt - startedAt) / 1_000_000
    }

    private func percentile(_ samples: [Double], fraction: Double) -> Double {
        let sorted = samples.sorted()
        let index = max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)
        return sorted[index]
    }

    private func makeContext() throws -> AppContext {
        try AppContext(channel: .debug, appSupportOverride: directory)
    }

    private func makeMentionPair(peerReply: String) throws -> (BotsViewModel, BotDefinition, BotDefinition) {
        let context = try makeContext()
        let router = AppCommandRouter(context: context)
        context.router = router
        context.coordinator.replaceProvider(
            .claude,
            runner: FakeProviderRunner(provider: .claude, scenario: .simpleAssistant(reply: peerReply))
        )
        let vm = BotsViewModel(context: context, router: router)
        let piper = try vm.create(name: "Piper", title: "Seller", provider: .claude)
        let quinn = try vm.create(name: "Quinn", title: "CRM Controller", provider: .claude)
        vm.openDesk(piper)
        vm.setDeskProvider(.claude)
        return (vm, piper, quinn)
    }

    private func makeDockerStudio() throws -> (AppContext, BotsViewModel, BotDefinition, RecordingDocker) {
        let context = try makeContext()
        let vm = BotsViewModel(context: context)
        let docker = RecordingDocker()
        vm.computerGuestService = BotComputerGuestService(
            appSupport: context.appSupportDirectory,
            docker: docker,
            observeAttempts: 1,
            observeDelay: 0
        )
        vm.dockerGuestReadyOverrideForTesting = true
        let created = try vm.create(name: "Piper", title: "Scout", provider: .claude)
        vm.openStudio(created)
        vm.studioDraft.desktopKind = .dockerDesktop
        let bot = try vm.saveStudio()
        return (context, vm, bot, docker)
    }

    private func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }

    private func sourceURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
    }
}

private struct T005PeerHandoffRouteFixture: Codable, Equatable {
    let provider: AgentProvider
    let providerInstanceID: String
    let model: String
    let permissionMode: AgentPermissionMode
    let reasoningEffort: AgentReasoningEffort
    let serviceTier: AgentServiceTier
    let runAsUser: AgentRunAsUser
    let routingConfiguration: AgentRoutingConfiguration?
}

private struct T005PeerHandoffRecordFixture: Codable, Equatable {
    let version: Int
    let activityID: UUID
    let originBotID: BotID?
    let originConversationID: BotConversationID?
    let originAgentThreadID: AgentThreadID?
    let peerBotID: BotID
    let peerConversationID: BotConversationID
    let peerThreadID: AgentThreadID?
    let peerRunID: AgentRunID?
    let inboundMessageID: UUID
    let peerName: String
    let peerTitle: String
    let peerHandle: String
    let outboundText: String
    let createdAt: Date
    let peerRoute: T005PeerHandoffRouteFixture
    let hostThreadID: AgentThreadID?
    let hostRunID: AgentRunID?
    let hostRoute: T005PeerHandoffRouteFixture?
    let replyText: String?
    let replyCreatedAt: Date?
    let phase: BotPeerHandoffPhase
}

final class ControlledBotHandoffRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider

    private struct PendingRun {
        let request: AgentRunRequest
        let turnID: String
        let onEvent: @Sendable (AgentRunEvent) -> Void
    }

    private let lock = NSLock()
    private var pendingByRunID: [AgentRunID: PendingRun] = [:]
    private var capturedRequests: [AgentRunRequest] = []
    private var capturedCancellationRequests: [AgentRunID] = []
    private let defersCancellationForTesting: Bool

    init(provider: AgentProvider, defersCancellationForTesting: Bool = false) {
        self.provider = provider
        self.defersCancellationForTesting = defersCancellationForTesting
    }

    var requests: [AgentRunRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    var cancellationRequestedRunIDs: [AgentRunID] {
        lock.withLock { capturedCancellationRequests }
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        let turnID = "turn-\(request.runId.value.uuidString.lowercased())"
        lock.lock()
        capturedRequests.append(request)
        pendingByRunID[request.runId] = PendingRun(
            request: request,
            turnID: turnID,
            onEvent: onEvent
        )
        lock.unlock()

        let providerThreadID = request.providerThreadId ?? request.threadId.value.uuidString
        onEvent(.status(.running))
        onEvent(.event(.threadStarted(
            threadId: providerThreadID,
            providerThreadId: providerThreadID
        )))
        onEvent(.event(.turnStarted(turnId: turnID)))
        return AgentRunHandle(runId: request.runId, process: nil) { [weak self] in
            guard let self else { return }
            if self.defersCancellationForTesting {
                self.lock.withLock {
                    self.capturedCancellationRequests.append(request.runId)
                }
                return
            }
            _ = self.finish(runID: request.runId, status: .cancelled, reply: nil)
        }
    }

    @discardableResult
    func finish(
        promptContaining marker: String,
        status: AgentRunStatus = .completed,
        reply: String?
    ) -> Bool {
        let runID: AgentRunID?
        lock.lock()
        runID = capturedRequests.first {
            $0.prompt.contains(marker) && pendingByRunID[$0.runId] != nil
        }?.runId
        lock.unlock()
        guard let runID else { return false }
        return finish(runID: runID, status: status, reply: reply)
    }

    @discardableResult
    func finish(
        runID: AgentRunID,
        status: AgentRunStatus,
        reply: String?
    ) -> Bool {
        let pending: PendingRun?
        lock.lock()
        pending = pendingByRunID.removeValue(forKey: runID)
        lock.unlock()
        guard let pending else { return false }

        let providerThreadID = pending.request.providerThreadId
            ?? pending.request.threadId.value.uuidString
        if status == .completed, let reply {
            let itemID = "assistant-\(runID.value.uuidString.lowercased())"
            pending.onEvent(.event(.itemStarted(item: AssistantItem(
                id: itemID,
                turnId: pending.turnID,
                type: .assistantMessage,
                startedAtMs: Int64(Date().timeIntervalSince1970 * 1_000)
            ))))
            pending.onEvent(.event(.itemDelta(
                itemId: itemID,
                bodyAppend: reply,
                outputAppend: nil,
                summary: nil
            )))
            pending.onEvent(.event(.itemCompleted(itemId: itemID, finalState: .completed)))
            pending.onEvent(.event(.turnCompleted(turnId: pending.turnID, finalMessage: reply)))
        } else if status == .completed {
            pending.onEvent(.event(.turnCompleted(turnId: pending.turnID, finalMessage: nil)))
        } else if status == .failed {
            pending.onEvent(.event(.error(message: "controlled failure", recoverable: false)))
        }
        pending.onEvent(.status(status))
        pending.onEvent(.finished(
            status,
            finalMessage: status == .completed ? reply : nil,
            providerThreadId: providerThreadID
        ))
        return true
    }
}
