import XCTest
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
        let vm = AgentAppViewModel(workspaceID: WorkspaceID(), cwd: tmp,
                                   coordinator: coord, threadRepo: threadRepo,
                                   messageRepo: messageRepo)
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

    func test_persistThreadConfig_writesProviderModelToThread() throws {
        let (vm, repo) = try makeVM()
        vm.createThread(title: "t")
        let id = vm.selectedThreadId!
        vm.provider = .claude
        vm.model = "claude-opus-4-7"
        vm.persistThreadConfig()
        let t = try repo.get(id: id)
        XCTAssertEqual(t?.provider, .claude)
        XCTAssertEqual(t?.model, "claude-opus-4-7", "model change must persist for resume")
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
        vm.runCoordinator(vm.coordinator, didFinish: runId, status: .completed,
                          finalMessage: "final answer", providerThreadId: "session-1")
        await waitAsync("assistant reply persisted") {
            ((try? vm.messageRepo.list(threadId: id)) ?? []).contains {
                $0.role == .assistant && $0.content == "final answer"
            }
        }
        vm.runCoordinator(vm.coordinator, didFinish: runId, status: .completed,
                          finalMessage: "final answer", providerThreadId: "session-1")
        await waitAsync("assistant reply remains deduplicated") {
            (((try? vm.messageRepo.list(threadId: id)) ?? []).filter {
                $0.role == .assistant && $0.content == "final answer"
            }.count) == 1
        }
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

    // MARK: B3 — composer attachments

    func test_attachments_addDedupesAndRemove() throws {
        let (vm, _) = try makeVM()
        vm.addAttachments(["/a.txt", "/b.txt", "/a.txt"])
        XCTAssertEqual(vm.attachments, ["/a.txt", "/b.txt"], "duplicate paths must not stack")
        vm.removeAttachment("/a.txt")
        XCTAssertEqual(vm.attachments, ["/b.txt"])
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
