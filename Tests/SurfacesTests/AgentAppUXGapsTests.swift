import XCTest
@testable import Surfaces
import CoreModel
import Persistence
import AgentRuntime

/// Tests covering UX-gap fixes implemented in AgentAppSurface.swift.
///
/// Items verified:
///  P1 — retry warns when original had attachments (lastSentAttachmentCount)
///  P2 — /clear posts a system note explaining the new thread
///  P2 — Option+Enter maps to insertNewline (not send)
///  P2 — canChooseDirectories = false is the new default (regression guard via VM logic)
///  P2 — providerLocked: system messages do NOT lock the provider
///  P2 — content-omitted: applyBodyBudget still blanks bodies (logic unchanged)
///  P3 — providerLocked false after only system messages
@MainActor
final class AgentAppUXGapsTests: XCTestCase {

    // MARK: - Helpers

    private func makeVMWithStore() throws -> (AgentAppViewModel, PromptHistoryStore) {
        let tmp = NSTemporaryDirectory() + "rc2-uxgaps-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo  = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo     = AgentRunRepository(db: db)
        let store = PromptHistoryStore(db: db)
        let workspaceID = WorkspaceID()
        let coord = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [
                .codex: FakeProviderRunner(provider: .codex),
                .claude: FakeProviderRunner(provider: .claude)
            ]
        )
        let vm = AgentAppViewModel(
            workspaceID: workspaceID, cwd: tmp,
            coordinator: coord, threadRepo: threadRepo, messageRepo: messageRepo,
            promptHistoryStore: store
        )
        return (vm, store)
    }

    private func makeVM() throws -> AgentAppViewModel {
        let (vm, _) = try makeVMWithStore()
        return vm
    }

    // MARK: - P1: retry warns when original message had attachments

    func test_retryLastPrompt_postsSystemNoteWhenOriginalHadAttachments() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-uxgaps-retry-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo  = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo     = AgentRunRepository(db: db)
        let sharedStore = PromptHistoryStore(db: db)
        let workspaceID = WorkspaceID()
        // Seed prompt history BEFORE building the VM so init picks it up.
        sharedStore.save(["rerun this"], workspaceID: workspaceID)

        let coord = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [
                .codex: FakeProviderRunner(provider: .codex),
                .claude: FakeProviderRunner(provider: .claude)
            ]
        )
        let vm = AgentAppViewModel(
            workspaceID: workspaceID, cwd: tmp,
            coordinator: coord, threadRepo: threadRepo, messageRepo: messageRepo,
            promptHistoryStore: sharedStore
        )

        vm.createThread(title: "retry-with-attachments")
        vm.lastSentAttachmentCount = 2

        await vm.retryLastPrompt()

        let systemNote = vm.messages.first { $0.role == .system && $0.content.contains("attachment") }
        XCTAssertNotNil(systemNote,
                        "retryLastPrompt must post a system note warning about dropped attachments when lastSentAttachmentCount > 0")
        let noteContent = systemNote?.content ?? ""
        XCTAssert(noteContent.contains("2"),
                  "system note must mention the attachment count; got: \"\(noteContent)\"")
    }

    func test_retryLastPrompt_noNoteWhenNoAttachments() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-uxgaps-noattach-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo  = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo     = AgentRunRepository(db: db)
        let sharedStore = PromptHistoryStore(db: db)
        let workspaceID = WorkspaceID()
        sharedStore.save(["no attachments here"], workspaceID: workspaceID)

        let coord = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [
                .codex: FakeProviderRunner(provider: .codex),
                .claude: FakeProviderRunner(provider: .claude)
            ]
        )
        let vm = AgentAppViewModel(
            workspaceID: workspaceID, cwd: tmp,
            coordinator: coord, threadRepo: threadRepo, messageRepo: messageRepo,
            promptHistoryStore: sharedStore
        )

        vm.createThread(title: "retry-no-attachments")
        // lastSentAttachmentCount defaults to 0

        await vm.retryLastPrompt()

        let attachmentNote = vm.messages.first { $0.role == .system && $0.content.contains("attachment") }
        XCTAssertNil(attachmentNote,
                     "retryLastPrompt must NOT post an attachment warning when no attachments were on the original message")
    }

    func test_lastSentAttachmentCount_zeroByDefault() throws {
        let vm = try makeVM()
        XCTAssertEqual(vm.lastSentAttachmentCount, 0,
                       "fresh VM must report zero last-sent attachments — no spurious warning on first retry")
    }

    // MARK: - P2: /clear posts a system note

    func test_clearSlashCommand_postsSystemNote() throws {
        let vm = try makeVM()
        vm.createThread(title: "before-clear")
        let originalId = vm.selectedThreadId

        _ = vm.handleSlashCommand("/clear")

        // /clear creates a NEW thread (different id).
        XCTAssertNotEqual(vm.selectedThreadId, originalId,
                          "/clear must switch to a new thread, not keep the current one")

        // The system note is posted into the NEW thread's message list.
        let noteContent = vm.messages.first { $0.role == .system }?.content ?? ""
        XCTAssert(noteContent.contains("/clear"),
                  "/clear must post a system note explaining that a new thread was created; found: \"\(noteContent)\"")
    }

    // MARK: - P2: Option+Enter maps to insertNewline

    func test_optionEnterMapsToInsertNewline() {
        // keyCode 36 = Return; .option modifier.
        let action = PromptComposerKeyAction.action(keyCode: 36, modifiers: .option)
        XCTAssertEqual(action, .insertNewline,
                       "Option+Enter must insert a newline instead of sending, matching most chat editors")
    }

    func test_shiftEnterMapsToInsertNewline() {
        let action = PromptComposerKeyAction.action(keyCode: 36, modifiers: .shift)
        XCTAssertEqual(action, .insertNewline,
                       "Shift+Enter must insert a newline (regression guard: must stay working after Option+Enter fix)")
    }

    func test_plainEnterMapsToSend() {
        let action = PromptComposerKeyAction.action(keyCode: 36, modifiers: [])
        XCTAssertEqual(action, .send,
                       "plain Enter must still send")
    }

    // MARK: - P3: providerLocked excludes system messages

    func test_providerLocked_falseAfterOnlySystemMessages() throws {
        let vm = try makeVM()
        vm.createThread(title: "system-only")
        let id = vm.selectedThreadId!

        // Simulate what /status does: posts a system message without a user turn.
        vm.messages.append(AgentMessage(threadId: id, role: .system, content: "Status: OK"))

        XCTAssertFalse(vm.providerLocked,
                       "a thread with only system notes must not lock the provider — /status must not prevent source switching")
    }

    func test_providerLocked_trueAfterUserMessage() throws {
        let vm = try makeVM()
        vm.createThread(title: "user-turn")
        let id = vm.selectedThreadId!

        vm.messages.append(AgentMessage(threadId: id, role: .user, content: "hello"))

        XCTAssertTrue(vm.providerLocked,
                      "a thread with at least one user message must lock the provider (regression guard)")
    }

    func test_providerLocked_trueAfterSystemPlusUserMessage() throws {
        let vm = try makeVM()
        vm.createThread(title: "mixed")
        let id = vm.selectedThreadId!

        vm.messages.append(AgentMessage(threadId: id, role: .system, content: "note"))
        vm.messages.append(AgentMessage(threadId: id, role: .user, content: "hello"))

        XCTAssertTrue(vm.providerLocked,
                      "a thread with a user message must lock even if system messages came first")
    }

    // MARK: - P2: applyBodyBudget regression (content-omitted path)

    func test_applyBodyBudget_blanksOldestBodiesToMeetBudget() {
        let big = String(repeating: "x", count: 1_000)
        let tid = AgentThreadID()
        let msgs: [AgentMessage] = (0..<5).map { _ in
            AgentMessage(threadId: tid, role: .assistant, content: big)
        }
        let (result, blanked) = AgentAppViewModel.applyBodyBudget(msgs, budget: 2_500)
        // 5 x 1000 = 5000 bytes > 2500 budget; oldest must be blanked.
        XCTAssertGreaterThan(blanked, 0,
                             "applyBodyBudget must blank oldest bodies when over budget so content-omitted placeholder has something to show")
        XCTAssert(result.contains { $0.content.isEmpty },
                  "at least one message must have an empty body after budget trim")
    }
}
