import XCTest
import AppKit
@testable import Surfaces
import CoreModel
import Persistence
import AgentRuntime

/// Behavioural coverage for thread rename/delete in the agent app view
/// model. Proves the sidebar contract: rename trims + persists, deleting
/// the selected thread never strands the UI on a dead selection.
@MainActor
final class AgentAppViewModelTests: XCTestCase {

    private func makeVM() throws -> (AgentAppViewModel, AgentThreadRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coord = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                        threadRepo: threadRepo,
                                        providers: [.codex: FakeProviderRunner(provider: .codex),
                                                    .claude: FakeProviderRunner(provider: .claude)])
        let workspaceID = WorkspaceID()
        let vm = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                   coordinator: coord, threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   promptHistoryStore: PromptHistoryStore(db: db))
        return (vm, threadRepo)
    }

    func test_renameThread_trimsUpdatesAndPersists() throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "first")
        let id = vm.selectedThreadId!
        vm.renameThread(id, to: "  Renamed Thread  ")
        XCTAssertEqual(vm.threads.first(where: { $0.id == id })?.title, "Renamed Thread",
                       "rename must trim and update the in-memory list")
        XCTAssertEqual(try repo.get(id: id)?.title, "Renamed Thread",
                       "rename must persist to the repository, not just the view")
    }

    func test_providerLocked_onlyAfterConversationStarts() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        XCTAssertFalse(vm.providerLocked, "an empty thread can still switch source")
        let id = vm.selectedThreadId!
        vm.messages.append(AgentMessage(threadId: id, role: .user, content: "hi"))
        XCTAssertTrue(vm.providerLocked, "once it has a message the source is fixed")
    }

    func test_persistThreadConfig_writesProviderModelPermissionAndReasoningToThread() throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "t")
        let id = vm.selectedThreadId!
        vm.provider = .claude
        vm.model = "claude-opus-4-7"
        vm.permissionMode = .fullAccess
        vm.reasoningEffort = .high
        vm.persistThreadConfig()
        let t = try repo.get(id: id)
        XCTAssertEqual(t?.provider, .claude)
        XCTAssertEqual(t?.model, "claude-opus-4-7", "model change must persist for resume")
        XCTAssertEqual(t?.permissionMode, .fullAccess)
        XCTAssertEqual(t?.reasoningEffort, .high)

        vm.permissionMode = .supervised
        vm.reasoningEffort = .low
        vm.selectThread(id)
        XCTAssertEqual(vm.permissionMode, .fullAccess,
                       "reopening an existing thread must restore its saved permission mode")
        XCTAssertEqual(vm.reasoningEffort, .high,
                       "reopening an existing thread must restore its saved reasoning effort")
    }

    func test_settingPermissionPersistsImmediatelyBeforeAnyMessageIsSent() throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "t")
        let id = vm.selectedThreadId!

        vm.setPermissionMode(.fullAccess)
        vm.permissionMode = .supervised
        vm.selectThread(id)

        XCTAssertEqual(try repo.get(id: id)?.permissionMode, .fullAccess,
                       "permission changes must persist immediately so app restart does not reset to supervised")
        XCTAssertEqual(vm.permissionMode, .fullAccess,
                       "reopening the thread must restore the saved permission mode before any message is sent")
    }

    func test_createThreadCopiesCurrentConfigFromLastThread() throws {
        let (vm, repo) = try makeVM()
        vm.provider = .codex
        vm.model = "gpt-5.5"
        vm.permissionMode = .fullAccess
        vm.reasoningEffort = .medium
        vm.createThread(title: "next")

        let id = try XCTUnwrap(vm.selectedThreadId)
        let t = try repo.get(id: id)
        XCTAssertEqual(t?.model, "gpt-5.5")
        XCTAssertEqual(t?.permissionMode, .fullAccess,
                       "new threads must inherit the last active permission mode")
        XCTAssertEqual(t?.reasoningEffort, .medium,
                       "new threads must inherit the last active reasoning effort")
    }

    func test_setThreadColor_persistsAndClears() throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "t")
        let id = vm.selectedThreadId!
        vm.setThreadColor(id, "purple")
        XCTAssertEqual(try repo.get(id: id)?.color, "purple")
        vm.setThreadColor(id, "")
        XCTAssertNil(try repo.get(id: id)?.color, "empty selection clears the color")
    }

    func test_renameThread_blankIsNoOp() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "keep")
        let id = vm.selectedThreadId!
        vm.renameThread(id, to: "   ")
        XCTAssertEqual(vm.threads.first(where: { $0.id == id })?.title, "keep",
                       "a blank rename must not wipe an existing title")
    }

    func test_deleteSelectedThread_reselectsRemaining() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "a")
        let a = vm.selectedThreadId!
        vm.createThread(title: "b")
        let b = vm.selectedThreadId!
        XCTAssertNotEqual(a, b)
        vm.selectThread(a)
        vm.deleteThread(a)
        XCTAssertFalse(vm.threads.contains { $0.id == a }, "deleted thread must be gone")
        XCTAssertEqual(vm.selectedThreadId, b,
                       "deleting the selected thread must fall back to a remaining one")
    }

    func test_deleteLastThread_clearsSelectionAndMessages() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "only")
        let id = vm.selectedThreadId!
        vm.messages.append(AgentMessage(threadId: id, role: .user, content: "hi"))
        vm.deleteThread(id)
        XCTAssertNil(vm.selectedThreadId, "deleting the last thread must clear selection")
        XCTAssertTrue(vm.messages.isEmpty, "stale messages must not linger after the thread is gone")
    }

    // MARK: B5 — draft title derivation

    func test_deriveTitle_takesFirstLineTrimsClipsAndStripsPunctuation() {
        XCTAssertEqual(AgentAppViewModel.deriveTitle(from: "  Fix the login bug.\nmore detail"),
                       "Fix the login bug",
                       "title must be the first line, trimmed, sans trailing period")
        XCTAssertEqual(AgentAppViewModel.deriveTitle(from: "### Heading"),
                       "Heading", "leading markdown punctuation must be stripped")
        XCTAssertEqual(AgentAppViewModel.deriveTitle(from: "   \n  "),
                       "New thread", "an empty prompt must fall back, never be blank")
        XCTAssertEqual(AgentAppViewModel.deriveTitle(from: String(repeating: "x", count: 80)).count, 48,
                       "the title must be clipped to 48 characters")
    }

    func test_send_firstMessage_derivesThreadTitleFromDefault() async throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "New thread")
        let id = vm.selectedThreadId!
        vm.prompt = "Refactor the auth module please"
        await vm.send()
        XCTAssertEqual(try repo.get(id: id)?.title, "Refactor the auth module please",
                       "the first message must rename a still-default thread")
        XCTAssertTrue(vm.messages.contains { $0.role == .user && $0.content == "Refactor the auth module please" })
    }

    func test_finishCallback_persistsAssistantReplyForRestart() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        let id = vm.selectedThreadId!
        let runId = AgentRunID()
        vm.runCoordinator(vm.coordinator, didFinish: runId, threadId: id, status: .completed,
                          finalMessage: "final answer", providerThreadId: "session-1")
        await waitAsync("assistant reply persisted") {
            ((try? vm.messageRepo.list(threadId: id)) ?? []).contains {
                $0.role == .assistant && $0.content == "final answer"
            }
        }
        vm.runCoordinator(vm.coordinator, didFinish: runId, threadId: id, status: .completed,
                          finalMessage: "final answer", providerThreadId: "session-1")
        await waitAsync("assistant reply remains deduplicated") {
            (((try? vm.messageRepo.list(threadId: id)) ?? []).filter {
                $0.role == .assistant && $0.content == "final answer"
            }.count) == 1
        }
    }

    func test_finishCallback_marksCompletedThreadUnreadUntilOpened() async throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "done")
        let id = vm.selectedThreadId!
        vm.runCoordinator(vm.coordinator, didFinish: AgentRunID(), threadId: id, status: .completed,
                          finalMessage: "done", providerThreadId: nil)

        await waitAsync("completed thread marked unread") {
            (try? repo.get(id: id)?.hasUnread) == true
        }
        vm.reloadThreads()
        XCTAssertTrue(vm.threads.first { $0.id == id }?.hasUnread ?? false,
                      "completed work must leave a visible unread indicator even for the currently selected thread")

        vm.selectThread(id)
        XCTAssertEqual(try repo.get(id: id)?.hasUnread, false,
                       "clicking/opening the completed thread must clear the indicator")
    }

    func test_runningThreadClearsPriorCompletedUnreadIndicator() async throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "rerun")
        let id = vm.selectedThreadId!
        vm.runCoordinator(vm.coordinator, didFinish: AgentRunID(), threadId: id, status: .completed,
                          finalMessage: "done", providerThreadId: nil)
        await waitAsync("completed thread marked unread") {
            (try? repo.get(id: id)?.hasUnread) == true
        }

        vm.runCoordinator(vm.coordinator, didChangeStatus: .running, runId: AgentRunID(), threadId: id)

        await waitAsync("running thread clears completed dot") {
            (try? repo.get(id: id)?.hasUnread) == false
        }
        XCTAssertFalse(vm.threads.first { $0.id == id }?.hasUnread ?? true,
                       "starting a new spinner must hide the prior completed dot until this run completes again")
    }

    func test_threadRowSelectionCheckNeverAppearsForClickedThread() {
        XCTAssertFalse(AgentThreadRowPresentation.showsSelectionCheck(
            threadStatus: .running,
            selected: false,
            surfaceStatus: .pending,
            multiSelected: true
        ), "running work must show the spinner without also implying completion")

        XCTAssertFalse(AgentThreadRowPresentation.showsSelectionCheck(
            threadStatus: .pending,
            selected: true,
            surfaceStatus: .running,
            multiSelected: true
        ), "the selected thread must suppress the check while its run is still active")

        XCTAssertFalse(AgentThreadRowPresentation.showsSelectionCheck(
            threadStatus: .completed,
            selected: true,
            surfaceStatus: .completed,
            multiSelected: true
        ), "clicking a thread selects it via highlight only; no trailing check icon")

        XCTAssertTrue(AgentThreadRowPresentation.showsSelectionCheck(
            threadStatus: .completed,
            selected: false,
            surfaceStatus: .completed,
            multiSelected: true
        ), "bulk-selected, non-open rows can still show the selection check")
    }

    func test_completedUnreadThreadShowsOnlyTrailingDot() {
        XCTAssertFalse(AgentThreadRowPresentation.showsLeadingStatus(
            threadStatus: .completed,
            selected: true,
            surfaceStatus: .completed,
            hasUnread: true,
            pinned: false
        ), "completed unread work must use the trailing dot only, without a second idle dot on the left")

        XCTAssertTrue(AgentThreadRowPresentation.showsLeadingStatus(
            threadStatus: .completed,
            selected: true,
            surfaceStatus: .completed,
            hasUnread: true,
            pinned: true
        ), "pinned rows keep their pin because it is not a completion indicator")
    }

    func test_runningStatusTracksRunIdBeforeStartRunReturnsSoStopWorks() async throws {
        let (vm, _) = try makeVM()
        let runner = SlowStartRunner()
        vm.coordinator.replaceProvider(.codex, runner: runner)
        vm.createThread(title: "slow")
        vm.prompt = "start slow run"

        Task { await vm.send() }
        await waitAsync("running status carries run id") {
            vm.status == .running && vm.currentRunId != nil
        }
        vm.stop()

        await waitAsync("pending stop cancels after handle registration") {
            runner.cancelled
        }
    }

    func test_streamEventsFanOutToEveryAgentSurfaceViewingTheThread() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-fanout-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: HoldOpenStreamRunner()]
        )
        let workspaceID = WorkspaceID()
        let firstSurface = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                             coordinator: coordinator, threadRepo: threadRepo,
                                             messageRepo: messageRepo)
        let secondSurface = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                              coordinator: coordinator, threadRepo: threadRepo,
                                              messageRepo: messageRepo)
        firstSurface.createThread(title: "shared")
        let threadId = firstSurface.selectedThreadId!
        secondSurface.reloadThreads()
        secondSurface.selectThread(threadId)

        firstSurface.prompt = "stream please"
        await firstSurface.send()

        await waitAsync("sender surface receives live partial stream") {
            firstSurface.timeline.turns.flatMap(\.items).contains {
                $0.type == .assistantMessage && $0.body.contains("partial stream")
            }
        }
        await waitAsync("second surface viewing same thread receives live partial stream") {
            secondSurface.timeline.turns.flatMap(\.items).contains {
                $0.type == .assistantMessage && $0.body.contains("partial stream")
            }
        }
    }

    func test_promptComposerEnterSendsAndShiftEnterInsertsNewline() {
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "\r", charactersIgnoringModifiers: "\r",
                                     isARepeat: false, keyCode: 36)!
        let shiftEnter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift],
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          characters: "\r", charactersIgnoringModifiers: "\r",
                                          isARepeat: false, keyCode: 36)!

        XCTAssertEqual(PromptComposerKeyAction.action(for: enter), .send,
                       "plain Enter must send the prompt")
        XCTAssertEqual(PromptComposerKeyAction.action(for: shiftEnter), .insertNewline,
                       "Shift+Enter must keep editing and insert a line break")
    }

    func test_promptComposerArrowKeysRequestHistoryNavigation() {
        let up = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                  timestamp: 0, windowNumber: 0, context: nil,
                                  characters: "", charactersIgnoringModifiers: "",
                                  isARepeat: false, keyCode: 126)!
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: 0, windowNumber: 0, context: nil,
                                    characters: "", charactersIgnoringModifiers: "",
                                    isARepeat: false, keyCode: 125)!

        XCTAssertEqual(PromptComposerKeyAction.action(for: up), .previousHistory,
                       "Up arrow must behave like Terminal history when the composer is empty")
        XCTAssertEqual(PromptComposerKeyAction.action(for: down), .nextHistory,
                       "Down arrow must walk back toward the empty composer after history recall")
    }

    func test_emptyPromptRecallsSubmittedCommandHistoryLikeTerminal() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "history")
        vm.prompt = "/status"
        await vm.send()
        vm.prompt = "/model none"
        await vm.send()

        XCTAssertTrue(vm.recallPreviousPrompt())
        XCTAssertEqual(vm.prompt, "/model none",
                       "an empty composer Up arrow must restore the last submitted command")
        XCTAssertTrue(vm.recallPreviousPrompt())
        XCTAssertEqual(vm.prompt, "/status",
                       "a second Up arrow must continue through older submitted commands")
        XCTAssertTrue(vm.recallNextPrompt())
        XCTAssertEqual(vm.prompt, "/model none",
                       "Down arrow must move forward through recalled command history")
        XCTAssertTrue(vm.recallNextPrompt())
        XCTAssertEqual(vm.prompt, "",
                       "Down arrow after the newest recalled command must return to an empty composer")
    }

    func test_promptHistoryDoesNotOverwriteTypedDraft() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "history")
        vm.prompt = "/status"
        await vm.send()
        vm.prompt = "typed draft"

        XCTAssertFalse(vm.recallPreviousPrompt())

        XCTAssertEqual(vm.prompt, "typed draft",
                       "history recall must not replace text the user is already typing")
    }

    func test_typingAfterHistoryRecallTurnsRecalledPromptIntoEditableDraft() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "history")
        vm.prompt = "/status"
        await vm.send()

        XCTAssertTrue(vm.recallPreviousPrompt())
        vm.prompt += " now"
        vm.promptWasEdited()

        XCTAssertEqual(vm.prompt, "/status now",
                       "after history recall the restored command must remain editable")
        XCTAssertFalse(vm.recallNextPrompt(),
                       "typing after recall must stop history navigation from owning the draft")
        XCTAssertEqual(vm.prompt, "/status now",
                       "history navigation must not clear or replace a recalled prompt after the user edits it")
    }

    func test_promptHistoryPersistsPerWorkspaceAndReloads() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-history-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coord = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                        threadRepo: threadRepo,
                                        providers: [.codex: FakeProviderRunner(provider: .codex)])
        let store = PromptHistoryStore(db: db)
        let firstWorkspace = WorkspaceID()
        let secondWorkspace = WorkspaceID()
        let first = AgentAppViewModel(workspaceID: firstWorkspace, cwd: tmp,
                                      coordinator: coord, threadRepo: threadRepo,
                                      messageRepo: messageRepo, promptHistoryStore: store)
        let second = AgentAppViewModel(workspaceID: secondWorkspace, cwd: tmp,
                                       coordinator: coord, threadRepo: threadRepo,
                                       messageRepo: messageRepo, promptHistoryStore: store)

        first.createThread(title: "first")
        first.prompt = "/status first"
        await first.send()
        second.createThread(title: "second")
        second.prompt = "/status second"
        await second.send()

        let reloadedFirst = AgentAppViewModel(workspaceID: firstWorkspace, cwd: tmp,
                                              coordinator: coord, threadRepo: threadRepo,
                                              messageRepo: messageRepo, promptHistoryStore: store)
        XCTAssertTrue(reloadedFirst.recallPreviousPrompt())
        XCTAssertEqual(reloadedFirst.prompt, "/status first",
                       "prompt history must persist by workspace and must not leak another workspace's commands")
    }

    func test_promptHistoryKeepsOnlyNewestTwentyEntries() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "history")
        for index in 1...21 {
            vm.prompt = "/status \(index)"
            await vm.send()
        }

        for _ in 0..<20 {
            XCTAssertTrue(vm.recallPreviousPrompt())
        }
        XCTAssertEqual(vm.prompt, "/status 2",
                       "prompt history must retain the newest 20 entries and evict the oldest command")
        XCTAssertTrue(vm.recallPreviousPrompt())
        XCTAssertEqual(vm.prompt, "/status 2",
                       "pressing Up past the retained history must stay on the oldest retained command")
    }

    // MARK: B2 — slash commands

    func test_send_slashCommand_neverBecomesAUserMessageOrRun() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "keep")
        let before = vm.threads.count
        vm.prompt = "/clear"
        await vm.send()
        XCTAssertEqual(vm.prompt, "", "the composer must clear after a slash command")
        XCTAssertFalse(vm.messages.contains { $0.role == .user && $0.content == "/clear" },
                       "/clear must not be sent to the provider as a user message")
        XCTAssertEqual(vm.threads.count, before + 1, "/clear must open a fresh thread")
    }

    func test_slashFork_copiesHistoryIntoNewThread() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "source")
        let src = vm.selectedThreadId!
        try? vm.messageRepo.append(AgentMessage(threadId: src, role: .user, content: "q1"))
        try? vm.messageRepo.append(AgentMessage(threadId: src, role: .assistant, content: "a1"))
        XCTAssertTrue(vm.handleSlashCommand("/fork"))
        let forkedId = vm.selectedThreadId!
        XCTAssertNotEqual(forkedId, src, "/fork must select the new thread")
        XCTAssertEqual(vm.threads.first(where: { $0.id == forkedId })?.title, "source (fork)")
        let copied = (try? vm.messageRepo.list(threadId: forkedId)) ?? []
        XCTAssertEqual(copied.map(\.content), ["q1", "a1"],
                       "/fork must copy the source thread's history verbatim")
    }

    func test_slashModel_setsModelOnMatchAndListsOtherwise() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        vm.availableModels = [AgentModelDescriptor(id: "gpt-5", label: "GPT-5", provider: .codex),
                              AgentModelDescriptor(id: "o4", label: "O4 Mini", provider: .codex)]
        vm.handleSlashCommand("/model o4")
        XCTAssertEqual(vm.model, "o4", "/model <arg> must switch to the matching model")
        vm.handleSlashCommand("/model")
        XCTAssertTrue(vm.messages.last?.content.contains("GPT-5") ?? false,
                      "bare /model must list available models as a system note")
        XCTAssertEqual(vm.messages.last?.role, .system)
    }

    func test_slashStatus_appendsSystemSummary() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        vm.handleSlashCommand("/status")
        XCTAssertEqual(vm.messages.last?.role, .system)
        XCTAssertTrue(vm.messages.last?.content.contains("provider=") ?? false,
                      "/status must surface the run configuration")
    }

    func test_slashUnknown_failsLoudAsSystemNote() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        vm.handleSlashCommand("/wat")
        XCTAssertTrue(vm.messages.last?.content.contains("Unknown command") ?? false,
                      "an unknown slash command must report, not silently vanish")
    }

    // MARK: B4 — read/unread, active count, provider-model coherence

    /// Async wait — `Task.sleep` yields the main-actor executor so the
    /// coordinator's observer callbacks (`Task { @MainActor … }`) run.
    /// RunLoop pumping does NOT service Swift concurrency, hence this.
    private func waitAsync(_ desc: String, timeout: TimeInterval = 6, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(cond(), "timed out waiting for: \(desc)")
    }

    func test_selectThread_marksItRead() throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "a")
        let a = vm.selectedThreadId!
        vm.createThread(title: "b")
        let b = vm.selectedThreadId!
        // Mark a unread out-of-band (as a background completion would).
        var ta = try repo.get(id: a)!; ta.hasUnread = true; try repo.upsert(ta)
        vm.reloadThreads()
        XCTAssertTrue(vm.threads.first { $0.id == a }?.hasUnread ?? false)
        vm.selectThread(b)
        vm.selectThread(a)
        XCTAssertEqual(try repo.get(id: a)?.hasUnread, false,
                       "opening a thread must clear its unread flag in the store")
        XCTAssertFalse(vm.threads.first { $0.id == a }?.hasUnread ?? true,
                       "the rail must drop the unread dot without a full requery")
    }

    func test_activeThreadCount_countsRunningThreads() throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "idle")
        vm.createThread(title: "busy")
        let busy = vm.selectedThreadId!
        var t = try repo.get(id: busy)!; t.status = .running; try repo.upsert(t)
        vm.reloadThreads()
        XCTAssertEqual(vm.activeThreadCount, 1, "only running threads are 'active'")
    }

    func test_loadModels_keepsModelValidForProvider() async throws {
        let (vm, _) = try makeVM()
        vm.provider = .codex
        vm.model = "bogus-not-a-real-model"
        await vm.loadModels()
        if !vm.availableModels.isEmpty {
            XCTAssertTrue(vm.availableModels.contains { $0.id == vm.model },
                          "a provider switch must leave a model valid for that provider")
        }
    }

    // MARK: B4 — bounded message window

    func test_messageWindow_capsThenLoadsEarlier() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "long")
        let tid = vm.selectedThreadId!
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<60 {
            try vm.messageRepo.append(AgentMessage(threadId: tid, role: .user,
                content: "m\(i)", createdAt: base.addingTimeInterval(Double(i))))
        }
        vm.selectThread(tid)
        XCTAssertEqual(vm.messages.count, AgentAppViewModel.baseMessageWindow,
                       "the initial load must be capped to the base window")
        XCTAssertEqual(vm.messages.last?.content, "m59", "newest message must be in the window")
        XCTAssertEqual(vm.messages.first?.content, "m10", "window is the most-recent N, oldest→newest")
        XCTAssertTrue(vm.hasMoreOlder, "60 messages > window of 50 → older remain")
        vm.loadEarlierMessages()
        XCTAssertEqual(vm.messages.count, 60, "expanding the window reveals the rest")
        XCTAssertEqual(vm.messages.first?.content, "m0")
        XCTAssertFalse(vm.hasMoreOlder, "nothing older remains once all are loaded")
    }

    func test_loadWindowClipsHugePersistedMessagesBeforeRendering() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "huge")
        let tid = vm.selectedThreadId!
        try vm.messageRepo.append(AgentMessage(
            threadId: tid,
            role: .assistant,
            content: String(repeating: "x", count: AssistantTimelineState.liveTextLimit + 10)
        ))

        vm.selectThread(tid)

        XCTAssertEqual(vm.messages.first?.content.count, AssistantTimelineState.liveTextLimit,
                       "a huge persisted transcript must be clipped before SwiftUI renders it")
    }

    // MARK: B3 — composer attachments

    func test_attachments_addDedupesAndRemove() throws {
        let (vm, _) = try makeVM()
        vm.addAttachments(["/a.txt", "/b.txt", "/a.txt"])
        XCTAssertEqual(vm.attachments, ["/a.txt", "/b.txt"], "duplicate paths must not stack")
        vm.removeAttachment("/a.txt")
        XCTAssertEqual(vm.attachments, ["/b.txt"])
    }

    func test_droppedFilePaths_insertIntoPromptWithoutAttaching() throws {
        let (vm, _) = try makeVM()
        vm.prompt = "review"

        vm.insertDroppedFilePaths(["/tmp/plain.txt", "/tmp/has space.txt"])

        XCTAssertEqual(vm.prompt, "review /tmp/plain.txt /tmp/has space.txt",
                       "dragging files into the composer must fill the input with file paths")
        XCTAssertTrue(vm.attachments.isEmpty,
                      "drop-to-input is text insertion, not the attachment-chip flow")
    }

    func test_send_withAttachments_composesPromptAndClears() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "t")
        let tid = vm.selectedThreadId!
        vm.prompt = "review these"
        vm.addAttachments(["/tmp/x.swift"])
        await vm.send()
        XCTAssertTrue(vm.attachments.isEmpty, "attachments must clear after send")
        let user = ((try? vm.messageRepo.list(threadId: tid)) ?? []).first { $0.role == .user }
        XCTAssertTrue(user?.content.contains("[Attached files]") ?? false,
                      "the persisted prompt must carry attachment paths for the agent")
        XCTAssertTrue(user?.content.contains("/tmp/x.swift") ?? false)
        XCTAssertTrue(vm.messages.contains { $0.role == .user && $0.content.contains("📎") },
                      "the transcript shows a friendly attachment summary, not raw paths")
    }

    func test_send_persistsExactlyOneUserAndOneAssistantMessage() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "convo")
        let tid = vm.selectedThreadId!
        vm.prompt = "hello there"
        await vm.send()
        // Deterministic: the coordinator persists the user message inside
        // (awaited) startRun; the VM must NOT also persist it.
        let afterSend = (try? vm.messageRepo.list(threadId: tid)) ?? []
        XCTAssertEqual(afterSend.filter { $0.role == .user && $0.content == "hello there" }.count, 1,
                       "the user message must be persisted exactly once (coordinator is the single writer)")
        await waitAsync("fake run completes") { vm.status == .completed }
        let assistants = ((try? vm.messageRepo.list(threadId: tid)) ?? []).filter { $0.role == .assistant }
        XCTAssertEqual(assistants.count, 1, "the assistant reply must be persisted exactly once, not double-written")
    }

    func test_completedSelectedRunKeepsLiveTimelineVisible() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-completed-timeline-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: HoldOpenStreamRunner()]
        )
        let vm = AgentAppViewModel(workspaceID: WorkspaceID(), cwd: tmp,
                                   coordinator: coordinator, threadRepo: threadRepo,
                                   messageRepo: messageRepo)
        vm.createThread(title: "live")
        vm.prompt = "stream please"
        await vm.send()

        await waitAsync("run completes") { vm.status == .completed }

        XCTAssertTrue(vm.timeline.turns.flatMap(\.items).contains {
            $0.type == .assistantMessage && $0.body.contains("partial stream")
        }, "the completed selected run must keep live stream/history items visible instead of collapsing to the final answer only")
    }

    func test_secondSendKeepsPriorTimelineHistoryVisible() async throws {
        let (vm, _) = try makeVM()
        vm.coordinator.replaceProvider(.codex, runner: FakeProviderRunner(
            provider: .codex,
            scenario: .withTool(toolName: "Bash", output: "tool output", reply: "first answer")
        ))
        vm.createThread(title: "convo")

        vm.prompt = "first prompt"
        await vm.send()
        await waitAsync("first answer completes") { vm.status == .completed }
        XCTAssertTrue(vm.timeline.turns.flatMap(\.items).contains {
            $0.type == .tool && $0.output == "tool output"
        }, "after completion the selected thread may keep tools and updates in the live timeline")

        vm.coordinator.replaceProvider(.codex, runner: FakeProviderRunner(provider: .codex, scenario: .simpleAssistant(reply: "second answer")))
        vm.prompt = "second prompt"
        await vm.send()

        XCTAssertTrue(vm.timeline.turns.flatMap(\.items).contains {
            $0.type == .tool && $0.output == "tool output"
        }, "sending a follow-up must not clear prior agent timeline history such as tool calls and outputs")
        XCTAssertTrue(vm.messages.contains { $0.role == .user && $0.content == "first prompt" })
        XCTAssertTrue(vm.messages.contains { $0.role == .user && $0.content == "second prompt" })
        XCTAssertFalse(vm.messages.contains { $0.role == .assistant && $0.content == "first answer" },
                       "the final assistant bubble must not duplicate the replayed assistant timeline")
    }

    func test_selectThreadReplaysPersistedStreamHistoryWithoutDuplicatingFinalAnswer() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-agent-replay-timeline-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: HoldOpenStreamRunner()]
        )
        let workspaceID = WorkspaceID()
        let vm = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                   coordinator: coordinator, threadRepo: threadRepo,
                                   messageRepo: messageRepo)
        vm.createThread(title: "live")
        let streamedThread = vm.selectedThreadId!
        vm.prompt = "stream please"
        await vm.send()
        await waitAsync("run completes") { vm.status == .completed }

        vm.createThread(title: "other")
        let reloadedVM = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                           coordinator: coordinator, threadRepo: threadRepo,
                                           messageRepo: messageRepo)
        reloadedVM.selectThread(streamedThread)

        XCTAssertTrue(reloadedVM.timeline.turns.flatMap(\.items).contains {
            $0.type == .assistantMessage && $0.body.contains("partial stream")
        }, "reopening a thread must replay persisted stream items, not just show the final answer")
        XCTAssertEqual(reloadedVM.messages.filter { $0.role == .assistant && $0.content == "partial stream final" }.count, 0,
                       "the persisted final answer must not duplicate the replayed assistant stream")
    }

    /// Regression: the VM defaulted to "gpt-5" — a dead id on codex
    /// 0.130.0, so a brand-new Codex thread's first run failed with no
    /// output. The default must be a model the CLI actually accepts.
    func test_defaultModel_isARealCodexModel() async throws {
        let (vm, _) = try makeVM()
        XCTAssertEqual(vm.model, "gpt-5.5", "fresh threads must start on a live codex model")
        await vm.loadModels()
        XCTAssertTrue(vm.availableModels.contains { $0.id == vm.model },
                      "the default model must be one the picker actually offers")
    }
}

private final class SlowStartRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let lock = NSLock()
    private var _cancelled = false
    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        onEvent(.status(.running))
        try? await Task.sleep(nanoseconds: 100_000_000)
        return AgentRunHandle(runId: request.runId, process: nil) { [weak self] in
            self?.lock.lock()
            self?._cancelled = true
            self?.lock.unlock()
        }
    }
}

private final class HoldOpenStreamRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        Task.detached {
            let turnId = UUID().uuidString
            let itemId = UUID().uuidString
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            onEvent(.status(.running))
            onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            onEvent(.event(.turnStarted(turnId: turnId)))
            onEvent(.event(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .assistantMessage, startedAtMs: now))))
            onEvent(.event(.itemDelta(itemId: itemId, bodyAppend: "partial stream", outputAppend: nil, summary: nil)))
            try? await Task.sleep(nanoseconds: 500_000_000)
            onEvent(.event(.itemCompleted(itemId: itemId, finalState: .completed)))
            onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: "partial stream final")))
            onEvent(.status(.completed))
            onEvent(.finished(.completed, finalMessage: "partial stream final", providerThreadId: providerThreadId))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}
