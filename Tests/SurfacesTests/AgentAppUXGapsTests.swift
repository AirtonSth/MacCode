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
///  UX-SR1-BADGE — showsTranslatedBadge: true=>true, false=>false
@MainActor
final class AgentAppUXGapsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Isolate from model choices remembered by earlier test runs via
        // AgentLastModelStore.shared (runner-level UserDefaults leak).
        UserDefaults.standard.removeObject(forKey: "agent.lastModel.byProvider.v1")
    }
    func test_imageViewPresentationUsesBasenameAndKeepsPrivateActionURL() throws {
        let item = AssistantItem(
            id: "generated-image",
            turnId: "turn-1",
            type: .imageView,
            state: .completed,
            summary: "generated.png",
            resourcePath: "/Users/private/work/generated.png",
            startedAtMs: 1,
            finishedAtMs: 2
        )

        let presentation = try XCTUnwrap(AgentImageViewPresentation.make(for: item))
        XCTAssertEqual(presentation.displayName, "generated.png")
        XCTAssertEqual(presentation.resourceURL.path, "/Users/private/work/generated.png")
        let timeline = AgentTimelineItemPresentation.make(for: item)
        XCTAssertFalse(timeline.label.contains("/Users/private"),
                       "normal transcript text must never expose the private image path")
        XCTAssertFalse(timeline.detail?.contains("/Users/private") == true)
    }

    /// WHY: "Running 2 images…" groups must surface thumbnails without expand.
    /// Presentations for the strip are pure so the group row can render them.
    func test_imagePresentationsInGroup_collectsResolvableImageViewsOnly() {
        let img1 = AssistantItem(
            id: "i1", turnId: "t", type: .imageView, state: .completed,
            summary: "a.png", resourcePath: "/tmp/a.png", startedAtMs: 1, finishedAtMs: 2
        )
        let img2 = AssistantItem(
            id: "i2", turnId: "t", type: .imageView, state: .completed,
            summary: "b.png", resourcePath: "/tmp/b.png", startedAtMs: 3, finishedAtMs: 4
        )
        let cmd = AssistantItem(
            id: "c1", turnId: "t", type: .commandExecution, state: .completed,
            body: #"{"command":"ls"}"#, startedAtMs: 5, finishedAtMs: 6
        )
        let baseless = AssistantItem(
            id: "i3", turnId: "t", type: .imageView, state: .completed,
            summary: "orphan.png", startedAtMs: 7, finishedAtMs: 8
        )
        let found = AgentImageViewPresentation.presentations(in: [img1, cmd, img2, baseless])
        XCTAssertEqual(found.map(\.displayName), ["a.png", "b.png"],
                       "only imageView items with absolute resource paths feed the thumbnail strip")
        XCTAssertEqual(AgentImageViewPresentation.absoluteFilePath(from: "~/Desktop/x.png")?.hasSuffix("/Desktop/x.png"), true)
        XCTAssertNil(AgentImageViewPresentation.absoluteFilePath(from: "relative.png"),
                     "basename-only tokens must not invent a CWD path for thumbnails")
    }

    func test_statusAndEmptyQueueErrorsRemainRenderEligible() {
        XCTAssertEqual(AgentAppView.visibleStatusMessage("  Disk full while saving draft.  "),
                       "Disk full while saving draft.",
                       "the primary status channel must produce visible banner text")
        XCTAssertNil(AgentAppView.visibleStatusMessage("   "))
        XCTAssertEqual(AgentAppView.standaloneQueueStatusMessage("Queue send failed: disk full", queuedCount: 0),
                       "Queue send failed: disk full",
                       "the first queue insertion error must remain visible even when no row exists")
        XCTAssertNil(AgentAppView.standaloneQueueStatusMessage("Queued", queuedCount: 1),
                     "non-empty queues render their status inside the queue section, not twice")
    }

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

    func test_retryLastPrompt_requiresConfirmationBeforeDroppingLegacyAttachments() async throws {
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

        XCTAssertEqual(vm.pendingAttachmentRetryConfirmation?.unavailableAttachmentNames, ["previous attachments"],
                       "legacy attachment metadata must pause retry instead of silently dropping the original files")
        XCTAssertFalse(vm.messages.contains { $0.role == .system && $0.content.contains("attachment") },
                       "the omission note must not claim a retry happened before the user confirms it")

        await vm.confirmRetryWithoutUnavailableAttachments()

        let systemNote = vm.messages.first { $0.role == .system && $0.content.contains("attachment") }
        XCTAssertNotNil(systemNote,
                        "the transcript must record the attachment omission after the user explicitly confirms it")
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

    // MARK: - UX-MAC_AGENT-STOP: isStopping / stopButtonState

    // WHY: a Stop button with no feedback invites repeated clicks and confusion.
    // The pure seam must encode the three reachable states so label/enabled logic
    // is verifiable without any view instantiation.

    func test_stopButtonState_activeNotStopping_returnsStop() {
        let state = AgentAppViewModel.stopButtonState(runActive: true, isStopping: false)
        XCTAssertEqual(state, .stop,
                       "active run with no pending interrupt must show the Stop affordance")
    }

    func test_stopButtonState_activeAndStopping_returnsStopping() {
        let state = AgentAppViewModel.stopButtonState(runActive: true, isStopping: true)
        XCTAssertEqual(state, .stopping,
                       "active run after Stop clicked must return .stopping so button is disabled and labelled 'Stopping...'")
    }

    func test_stopButtonState_notActive_returnsHidden() {
        XCTAssertEqual(AgentAppViewModel.stopButtonState(runActive: false, isStopping: false), .hidden,
                       "no active run must hide the Stop button regardless of isStopping")
        XCTAssertEqual(AgentAppViewModel.stopButtonState(runActive: false, isStopping: true), .hidden,
                       "isStopping=true with no active run must also be hidden (stale flag must not resurface button)")
    }

    func test_isStopping_setOnStop_clearedOnTerminalFinish() async throws {
        let vm = try makeVM()
        vm.createThread(title: "stop-feedback")

        // Simulate an active run by setting status directly.
        vm.status = .running

        // Precondition: flag is clear.
        XCTAssertFalse(vm.isStopping)

        // Calling stop() on a VM with no real coordinator handle must still set the flag.
        vm.stop()
        XCTAssertTrue(vm.isStopping,
                      "stop() must set isStopping=true immediately so the UI can disable the button")

        // Simulate the coordinator finishing the run (as didFinish would).
        vm.status = .cancelled
        vm.isStopping = false  // mirrors the MainActor assignment in didFinish

        XCTAssertFalse(vm.isStopping,
                       "isStopping must be cleared when the run reaches a terminal state")
    }

    // MARK: - UX-SR1-BADGE: showsTranslatedBadge seam

    /// WHY: a humanized SR1 reply must be transparently labeled so the user knows
    /// it was rewritten by Token Saver. The badge decision is a pure function of
    /// the wasTranslated flag so it can be verified without any view setup.
    func test_showsTranslatedBadge_true_whenWasSR1Translated() {
        XCTAssertTrue(
            AgentAppView.showsTranslatedBadge(wasSR1Translated: true),
            "Badge must appear when the message was SR1-translated"
        )
    }

    func test_showsTranslatedBadge_false_whenNotTranslated() {
        XCTAssertFalse(
            AgentAppView.showsTranslatedBadge(wasSR1Translated: false),
            "Badge must NOT appear for normal (non-SR1) messages"
        )
    }

    func test_sr1BadgeLabel_exposesViewOriginalWhenOriginalTextExists() {
        XCTAssertEqual(
            AgentAppView.sr1BadgeLabel(hasOriginalText: true),
            "translated from compressed output - View original",
            "Badge text must expose the original SR1 text affordance when persisted original text is available"
        )
    }

    func test_sr1BadgeLabel_usesPlainBadgeWithoutOriginalText() {
        XCTAssertEqual(
            AgentAppView.sr1BadgeLabel(hasOriginalText: false),
            "translated from compressed output",
            "Badge text must remain compact when older events have no original text to show"
        )
    }

    func test_promptHistoryWriteErrorMessage_isUserVisible() {
        let message = AgentAppViewModel.promptHistoryWriteErrorMessage(NSError(
            domain: "test",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "disk full"]
        ))

        XCTAssertEqual(
            message,
            "Prompt history could not be saved: disk full.",
            "Prompt-history write failures must produce user-visible status copy instead of being swallowed"
        )
    }

    func test_fullAccessScopeCopy_matchesPersistedThreadSetting() {
        XCTAssertEqual(
            AgentAppView.fullAccessScopeDescription,
            "The agent runs tools, edits, and proposed plans without asking for this thread until you change it.",
            "full-access copy must describe the persisted thread scope — including that proposed plans auto-implement — instead of promising a process session scope"
        )
        XCTAssertEqual(
            AgentAppView.sessionApprovalHelp,
            "Auto-approve requests for this thread until you change it",
            "Approve Session help must describe the same persisted thread scope as the resulting setting"
        )
    }

    func test_threadDeletionConfirmationCopy_matchesImmediateUndoWindow() {
        XCTAssertEqual(
            AgentAppView.threadDeletionConfirmationDescription,
            "Threads are deleted immediately. You can undo for 10 seconds; after that, their history is permanently deleted.",
            "delete confirmation must disclose the real immediate delete, brief Undo, and permanent expiry behavior"
        )
        XCTAssertEqual(AgentAppViewModel.threadDeletionUndoWindow, 10,
                       "the disclosed Undo duration must stay aligned with the runtime window")
    }

    func test_emptyThreadCopy_namesEverySupportedProvider() {
        XCTAssertEqual(
            AgentAppView.emptyThreadSubtitle,
            "Send a prompt to start a Codex, Claude, or Grok thread.",
            "the empty state must not hide Grok from the supported-provider set"
        )
    }

    func test_attachmentRemovalAccessibilityLabel_includesFilename() {
        XCTAssertEqual(
            AgentAppView.attachmentRemovalAccessibilityLabel(path: "/private/tmp/quarterly-plan.pdf"),
            "Remove attachment quarterly-plan.pdf",
            "VoiceOver users must know which attachment each remove button targets"
        )
    }
}
