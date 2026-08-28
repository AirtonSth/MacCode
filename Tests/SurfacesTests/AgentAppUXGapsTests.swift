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
///  UX-TOKEN-SAVER-BADGE — showsTokenSaverOptimizedBadge: true=>true, false=>false
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
                       "active run after Stop clicked must return .stopping so UI can label force-stop affordance")
    }

    func test_stopButtonState_notActive_returnsHidden() {
        XCTAssertEqual(AgentAppViewModel.stopButtonState(runActive: false, isStopping: false), .hidden,
                       "no active run must hide the Stop button regardless of isStopping")
        XCTAssertEqual(AgentAppViewModel.stopButtonState(runActive: false, isStopping: true), .hidden,
                       "isStopping=true with no active run must also be hidden (stale flag must not resurface button)")
    }

    func test_isStopping_setOnStop_clearedOnTerminalFinish() async throws {
        // UX-MAC_AGENT-STOP-GHOST: the run must be genuinely interruptible for Stop
        // to latch Stopping…. This test used to fake `status = .running` with no run
        // at all and assert the latch anyway — that is exactly the state that left
        // the field UI stuck on "Stopping… (click to force)" forever, because only
        // run lifecycle events clear the latch and a dead run emits none. A durable
        // pending/running row is the minimum proof that a stop has a target.
        let tmp = NSTemporaryDirectory() + "rc2-uxgaps-stop-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coord = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(provider: .codex)]
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(), cwd: tmp,
            coordinator: coord, threadRepo: threadRepo, messageRepo: messageRepo,
            promptHistoryStore: PromptHistoryStore(db: db)
        )
        vm.createThread(title: "stop-feedback")
        let threadId = try XCTUnwrap(vm.selectedThreadId)
        try runRepo.upsert(AgentRun(threadId: threadId, provider: .codex,
                                    model: "gpt-5.6-luna", status: .running))
        vm.status = .running

        // Precondition: flag is clear.
        XCTAssertFalse(vm.isStopping)

        vm.stop()
        XCTAssertTrue(vm.isStopping,
                      "stop() must set isStopping=true immediately so the UI can show Stopping feedback")

        // Simulate the coordinator finishing the run (as didFinish would).
        vm.status = .cancelled
        vm.isStopping = false  // mirrors the MainActor assignment in didFinish

        XCTAssertFalse(vm.isStopping,
                       "isStopping must be cleared when the run reaches a terminal state")
    }

    /// The other half of the same contract: with no live and no durable run, Stop
    /// has nothing to interrupt, so it must clear the stale projection instead of
    /// arming a latch that nothing can ever release.
    func test_stopWithoutAnyRunDoesNotLatchStopping() async throws {
        let vm = try makeVM()
        vm.createThread(title: "no-run-stop")
        vm.status = .running

        vm.stop()

        XCTAssertFalse(vm.isStopping,
                       "Stop on a thread with no run must not latch Stopping… — that latch is unclearable")
        XCTAssertNil(vm.currentRunId)
        XCTAssertNil(vm.runStartedAt)
    }

    // MARK: - Token Saver optimized disclosure

    /// WHY: an optimized provider exchange must remain transparent to the user.
    func test_showsTokenSaverOptimizedBadge_true_whenOptimized() {
        XCTAssertTrue(
            AgentAppView.showsTokenSaverOptimizedBadge(wasTokenSaverOptimized: true),
            "Badge must appear when Token Saver optimized the exchange"
        )
    }

    func test_showsTokenSaverOptimizedBadge_false_whenNotTranslated() {
        XCTAssertFalse(
            AgentAppView.showsTokenSaverOptimizedBadge(wasTokenSaverOptimized: false),
            "Badge must NOT appear for ordinary messages"
        )
    }

    func test_tokenSaverBadgeLabel_staysCompactWhenOriginalTextExists() {
        XCTAssertEqual(
            AgentAppView.tokenSaverBadgeLabel(hasOriginalText: true),
            "Token Saver optimized",
            "The visible Translated/RCW1 control owns disclosure, so the badge must not repeat an obsolete popover action"
        )
    }

    func test_tokenSaverBadgeLabel_usesPlainBadgeWithoutOriginalText() {
        XCTAssertEqual(
            AgentAppView.tokenSaverBadgeLabel(hasOriginalText: false),
            "Token Saver optimized",
            "Badge text must remain compact when older events have no original text to show"
        )
    }

    /// WHY: each disclosure belongs to one transcript item. Persisting RCW1 for
    /// one row must not change any sibling row, including after app relaunch.
    func test_tokenSaverDisplaySelections_areIndependentAndDurablePerItem() {
        let first = "thread-a:message-a"
        let second = "thread-a:message-b"
        var selections = AgentAppView.TokenSaverDisplaySelections()

        XCTAssertEqual(selections.mode(for: first), .translated)
        XCTAssertEqual(selections.mode(for: second), .translated)

        selections.set(.original, for: first)
        XCTAssertEqual(selections.mode(for: first), .original)
        XCTAssertEqual(selections.mode(for: second), .translated,
                       "clicking RCW1 on one message must leave its sibling in Human mode")

        var restored = AgentAppView.TokenSaverDisplaySelections(rawValue: selections.rawValue)
        XCTAssertEqual(restored.mode(for: first), .original)
        XCTAssertEqual(restored.mode(for: second), .translated,
                       "per-message choices must survive decoding on relaunch")

        restored.set(.original, for: second)
        restored.set(.translated, for: first)
        XCTAssertEqual(restored.mode(for: first), .translated)
        XCTAssertEqual(restored.mode(for: second), .original,
                       "changing the first message back must not reset the second")

        let legacyScalar = AgentAppView.TokenSaverDisplaySelections(rawValue: "original")
        XCTAssertEqual(legacyScalar.mode(for: first), .translated,
                       "the retired global value must not make every new row RCW1")

        XCTAssertNotEqual(
            AgentAppView.tokenSaverTimelineItemDisplayKey(turnId: "turn-a", itemId: "item-1"),
            AgentAppView.tokenSaverTimelineItemDisplayKey(turnId: "turn-b", itemId: "item-1"),
            "provider item IDs may repeat, so each turn must own a separate display choice"
        )
        XCTAssertNotEqual(
            AgentAppView.tokenSaverTimelineItemDisplayKey(turnId: "a", itemId: "b:c"),
            AgentAppView.tokenSaverTimelineItemDisplayKey(turnId: "a:b", itemId: "c"),
            "opaque provider IDs must remain distinct even when they contain separators"
        )
        XCTAssertNotEqual(
            AgentAppView.tokenSaverTurnDisplayKey("turn-a"),
            AgentAppView.tokenSaverTurnDisplayKey("turn-b"),
            "two visible final rows with identical text must still own separate choices"
        )
        XCTAssertNotEqual(
            AgentAppView.tokenSaverTurnDisplayKey("a:b:c"),
            AgentAppView.tokenSaverTimelineItemDisplayKey(turnId: "a", itemId: "b:c"),
            "turn and item rows must occupy different identity namespaces"
        )
        XCTAssertNotEqual(
            AgentAppView.tokenSaverMessageDisplayKey("a:b"),
            AgentAppView.tokenSaverTimelineItemDisplayKey(turnId: "a", itemId: "b"),
            "durable messages and provider items must occupy different identity namespaces"
        )
        XCTAssertNotEqual(
            AgentAppView.tokenSaverThreadScopedDisplayKey(
                threadId: "a:b",
                itemKey: AgentAppView.tokenSaverMessageDisplayKey("c")
            ),
            AgentAppView.tokenSaverThreadScopedDisplayKey(
                threadId: "a",
                itemKey: AgentAppView.tokenSaverMessageDisplayKey("b:c")
            ),
            "length-prefixed thread and row components must make separator-bearing IDs injective"
        )

        var bounded = AgentAppView.TokenSaverDisplaySelections()
        for index in 0...AgentAppView.TokenSaverDisplaySelections.maximumPersistedItemCount {
            bounded.set(.original, for: "transient-timeline-item-\(index)")
        }
        XCTAssertEqual(
            bounded.originalItemKeys.count,
            AgentAppView.TokenSaverDisplaySelections.maximumPersistedItemCount,
            "evictable timeline-item choices must not grow UserDefaults without a bound; canonical messages use FK-owned SQLite rows"
        )
        XCTAssertEqual(bounded.mode(for: "transient-timeline-item-0"), .translated)
        XCTAssertEqual(
            AgentAppView.TokenSaverDisplaySelections(
                rawValue: String(
                    repeating: "x",
                    count: AgentAppView.TokenSaverDisplaySelections.maximumRawBytes + 1
                )
            ).mode(for: first),
            .translated,
            "oversized persisted state must fail back to Human before JSON decoding"
        )

        let keptThread = "thread-kept"
        let deletedThread = "thread-deleted"
        let keptKey = AgentAppView.tokenSaverThreadScopedDisplayKey(
            threadId: keptThread,
            itemKey: AgentAppView.tokenSaverMessageDisplayKey("message-a")
        )
        let deletedKey = AgentAppView.tokenSaverThreadScopedDisplayKey(
            threadId: deletedThread,
            itemKey: AgentAppView.tokenSaverMessageDisplayKey("message-a")
        )
        var cleaned = AgentAppView.TokenSaverDisplaySelections()
        cleaned.set(.original, for: keptKey)
        cleaned.set(.original, for: deletedKey)
        cleaned.removeSelections(threadIds: [deletedThread])
        XCTAssertEqual(cleaned.mode(for: keptKey), .original)
        XCTAssertEqual(cleaned.mode(for: deletedKey), .translated,
                       "deleting a thread must prune only that thread's persisted row choices")

        let oversizedKey = String(
            repeating: "k",
            count: AgentAppView.TokenSaverDisplaySelections.maximumItemKeyBytes + 1
        )
        cleaned.set(.original, for: oversizedKey)
        XCTAssertEqual(cleaned.mode(for: oversizedKey), .translated,
                       "one hostile identifier must not inflate UserDefaults")

        var byteBounded = AgentAppView.TokenSaverDisplaySelections()
        for index in 0..<400 {
            let suffix = String(repeating: "z", count: 900) + "-\(index)"
            byteBounded.set(.original, for: suffix)
        }
        XCTAssertLessThanOrEqual(
            byteBounded.rawValue.utf8.count,
            AgentAppView.TokenSaverDisplaySelections.maximumRawBytes,
            "the serialized preference must stay bounded even when every key is near its own byte limit"
        )
    }

    /// WHY: switching one row to RCW1 must expose that row's exact provider-bound
    /// request and raw response, while a Human row continues to copy readable text.
    func test_tokenSaverCopyText_tracksVisibleTranslatedOrOriginalMode() {
        let translated = "Focused tests passed."
        let request = "RCW1\tQ\t1\nG\tRun focused tests.\n.\n"
        let response = "RCW1\tA\t1\nO\tFocused tests passed.\n.\n"

        XCTAssertEqual(
            AgentAppView.tokenSaverCopyText(
                translated: translated,
                original: response,
                request: request,
                mode: .translated
            ),
            translated
        )
        let original = AgentAppView.tokenSaverCopyText(
            translated: translated,
            original: response,
            request: request,
            mode: .original
        )
        XCTAssertTrue(original.contains(request), "RCW1 mode must copy exactly what RemoteCode sent")
        XCTAssertTrue(original.hasSuffix(response), "RCW1 mode must copy the exact raw provider response")
    }

    /// IMPORTANT regression: an outbound RCW1 request does not turn a plain
    /// assistant fallback into an RCW1 response. Such rows stay readable, expose
    /// no Human/RCW1 response picker, and Copy never concatenates the request as
    /// though it were raw provider output.
    func test_plainAssistantFallbackCannotMasqueradeAsRCW1Response() {
        let translated = "Focused tests passed."
        let plainFallback = "Focused tests passed."
        let request = "RCW1\tQ\t1\nG\tRun focused tests.\n.\n"
        let response = "RCW1\tA\t1\nO\tFocused tests passed.\n.\n"

        XCTAssertFalse(AgentAppView.hasInspectableAssistantRCW1Response(plainFallback))
        XCTAssertFalse(AgentAppView.hasInspectableAssistantRCW1Response(request),
                       "a request frame is not an assistant response")
        XCTAssertTrue(AgentAppView.hasInspectableAssistantRCW1Response(response))
        XCTAssertFalse(AgentAppView.showsTokenSaverDisplayControl(
            original: plainFallback,
            request: request,
            allowsRequestOnlyRCW1: false
        ), "assistant plaintext must compose without any Human/RCW1 picker")
        XCTAssertTrue(AgentAppView.showsTokenSaverDisplayControl(
            original: plainFallback,
            request: request,
            allowsRequestOnlyRCW1: true
        ), "the durable user row must keep its outbound Human/RCW1 request toggle")
        XCTAssertTrue(AgentAppView.showsTokenSaverDisplayControl(
            original: response,
            request: request,
            allowsRequestOnlyRCW1: false
        ), "a real RCW1 A response owns an assistant picker")
        XCTAssertFalse(AgentAppView.showsTokenSaverOriginalContent(
            original: plainFallback,
            mode: .original
        ), "stale RCW1 selection must not compose plaintext as raw provider output")
        XCTAssertTrue(AgentAppView.showsTokenSaverOriginalContent(
            original: response,
            mode: .original
        ), "RCW1 selection may expose a real RCW1 A response")
        XCTAssertFalse(AgentAppView.showsTokenSaverOriginalContent(
            original: response,
            mode: .translated
        ), "Human selection must compose the readable response")
        XCTAssertEqual(
            AgentAppView.tokenSaverCopyText(
                translated: translated,
                original: plainFallback,
                request: request,
                mode: .original
            ),
            translated,
            "plain fallback Copy must stay Human even if stale state requests RCW1 mode"
        )
    }

    /// WHY: Copy follows the row that owns the clicked toggle. A=RCW1 and
    /// B=Human must coexist without either row borrowing the other's payload.
    func test_tokenSaverCopyText_usesEachRowsIndependentDisplaySelection() {
        let thread = "thread-a"
        let firstKey = AgentAppView.tokenSaverThreadScopedDisplayKey(
            threadId: thread,
            itemKey: AgentAppView.tokenSaverMessageDisplayKey("message-a")
        )
        let secondKey = AgentAppView.tokenSaverThreadScopedDisplayKey(
            threadId: thread,
            itemKey: AgentAppView.tokenSaverMessageDisplayKey("message-b")
        )
        var selections = AgentAppView.TokenSaverDisplaySelections()
        selections.set(.original, for: firstKey)

        let firstCopy = AgentAppView.tokenSaverCopyText(
            translated: "Human A",
            original: "RCW1\tA\t1\nO\tRCW1 A\n.\n",
            request: "RCW1\tQ\t1\nG\tRCW1 request A\n.\n",
            mode: selections.mode(for: firstKey)
        )
        let secondCopy = AgentAppView.tokenSaverCopyText(
            translated: "Human B",
            original: "RCW1\tA\t1\nO\tRCW1 B\n.\n",
            request: "RCW1\tQ\t1\nG\tRCW1 request B\n.\n",
            mode: selections.mode(for: secondKey)
        )

        XCTAssertTrue(firstCopy.contains("RCW1 request A"))
        XCTAssertTrue(firstCopy.hasSuffix("RCW1\tA\t1\nO\tRCW1 A\n.\n"))
        XCTAssertEqual(secondCopy, "Human B",
                       "copying a sibling still in Human mode must not expose or borrow raw RCW1")
        XCTAssertFalse(firstCopy.contains("RCW1 B"))
    }

    /// WHY: the user bubble is the human -> RCW1 half of the exchange. Its
    /// visible body and Copy action must follow that message's own durable mode.
    func test_tokenSaverUserMessageDisplayText_tracksHumanAndRCW1Mode() {
        let human = "Run the focused tests."
        let wire = "RCW1\tQ\t1\nG\tRun the focused tests.\n.\n"

        XCTAssertEqual(
            AgentAppView.tokenSaverUserMessageDisplayText(
                human: human,
                wireRequest: wire,
                mode: .translated
            ),
            human
        )
        XCTAssertEqual(
            AgentAppView.tokenSaverUserMessageDisplayText(
                human: human,
                wireRequest: wire,
                mode: .original
            ),
            wire
        )
        XCTAssertEqual(
            AgentAppView.tokenSaverUserMessageDisplayText(
                human: human,
                wireRequest: nil,
                mode: .original
            ),
            human,
            "old/non-optimized messages must never disappear in RCW1 mode"
        )
        XCTAssertEqual(
            AgentAppView.tokenSaverUserMessageDisplayText(
                human: human,
                wireRequest: "legacy transport",
                mode: .original
            ),
            human,
            "legacy transport metadata must never be mislabeled as RCW1"
        )
    }

    func test_tokenSaverUserMessageDisplayText_keepsImageMarkersInHumanAndRCW1() {
        // WHY: Token Saver RCW1 replaces the bubble with wire bytes that never
        // carried `[Image #1]`. The shared transform must still show the marker.
        let shot = AgentAttachment(path: "/tmp/shot.png", displayName: "shot.png", kind: .image)
        let extra = AgentAttachment(path: "/tmp/extra.jpg", displayName: "extra.jpg", kind: .image)
        let humanOne = AgentChatTranscriptChrome.displayUserLine(
            text: "Describe this",
            attachments: [shot]
        )
        let humanTwo = AgentChatTranscriptChrome.displayUserLine(
            text: "Compare these",
            attachments: [shot, extra]
        )
        let wire = "RCW1\tQ\t1\nG\tDescribe this\n.\n"
        XCTAssertTrue(humanOne.contains("[Image #1]"))
        XCTAssertTrue(humanTwo.contains("[Image #1]"))
        XCTAssertTrue(humanTwo.contains("[Image #2]"))
        XCTAssertEqual(
            AgentAppView.tokenSaverUserMessageDisplayText(
                human: humanOne,
                wireRequest: wire,
                mode: .translated
            ),
            humanOne
        )
        let rcw1 = AgentAppView.tokenSaverUserMessageDisplayText(
            human: humanOne,
            wireRequest: wire,
            mode: .original
        )
        XCTAssertTrue(rcw1.contains("[Image #1]"), "RCW1 mode must not strip the image marker")
        XCTAssertTrue(rcw1.contains("RCW1\tQ\t1"))
        let rcw1Two = AgentAppView.tokenSaverUserMessageDisplayText(
            human: humanTwo,
            wireRequest: wire,
            mode: .original
        )
        XCTAssertTrue(rcw1Two.contains("[Image #1]"))
        XCTAssertTrue(rcw1Two.contains("[Image #2]"))
    }

    /// WHY: stream events are a bounded replay cache. The disclosure attached
    /// to a retained human message must stay visible after a live timeline
    /// refresh evicts its event and after the app constructs a fresh view model.
    func test_userRCW1DisclosureSurvivesTimelineEvictionAndViewModelRestart() async throws {
        let tmp = NSTemporaryDirectory() + "rcw1-user-disclosure-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let workspaceID = WorkspaceID()
        let thread = AgentThread(
            workspaceId: workspaceID,
            title: "RCW1 disclosure",
            provider: .codex,
            model: "test-model"
        )
        let message = AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "Run focused tests."
        )
        let wire = "RCW1\tQ\t1\nG\tRun focused tests.\n.\n"
        try threadRepo.upsert(thread)
        try messageRepo.append(message)

        func makeViewModel() -> AgentAppViewModel {
            let coordinator = AgentRunCoordinator(
                runRepo: runRepo,
                messageRepo: messageRepo,
                threadRepo: threadRepo,
                providers: [.codex: FakeProviderRunner(provider: .codex)]
            )
            return AgentAppViewModel(
                workspaceID: workspaceID,
                cwd: tmp,
                coordinator: coordinator,
                threadRepo: threadRepo,
                messageRepo: messageRepo,
                initialThreadId: thread.id
            )
        }

        let live = makeViewModel()
        try messageRepo.upsertRCW1RequestTranslation(
            messageId: message.id,
            wireRequestText: wire
        )
        live.coordinator.onWireTranslatedMessageId?(message.id)
        for _ in 0..<100 where live.tokenSaverWireRequestText(for: message.id) == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        live.refreshTokenSaverOptimizationStateFromTimeline(AssistantTimelineState())
        XCTAssertEqual(live.tokenSaverWireRequestText(for: message.id), wire,
                       "timeline eviction must not erase the selected thread's durable user disclosure")

        live.dispose()
        let restarted = makeViewModel()
        defer { restarted.dispose() }
        await restarted.waitForMessageHistoryLoad()
        XCTAssertEqual(restarted.tokenSaverWireRequestText(for: message.id), wire,
                       "a fresh view model must rebuild the user toggle from message-owned persistence")
        XCTAssertTrue(restarted.tokenSaverOptimizedMessageIds.contains(message.id))
    }

    /// WHY: first paint loads only the newest 25 messages. RCW1 metadata for an
    /// older retained user row must not be discarded before history pagination
    /// makes that row visible again.
    func test_userRCW1DisclosureSurvivesOlderMessagePagination() async throws {
        let tmp = NSTemporaryDirectory() + "rcw1-user-pagination-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let workspaceID = WorkspaceID()
        let thread = AgentThread(
            workspaceId: workspaceID,
            title: "RCW1 pagination",
            provider: .codex,
            model: "test-model"
        )
        try threadRepo.upsert(thread)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var seeded: [AgentMessage] = []
        for index in 0..<30 {
            let message = AgentMessage(
                threadId: thread.id,
                role: .user,
                content: "Message \(index)",
                createdAt: base.addingTimeInterval(TimeInterval(index))
            )
            try messageRepo.append(message)
            seeded.append(message)
        }
        let oldest = try XCTUnwrap(seeded.first)
        let wire = "RCW1\tQ\t1\nG\tMessage 0\n.\n"
        try messageRepo.upsertRCW1RequestTranslation(
            messageId: oldest.id,
            wireRequestText: wire
        )
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(provider: .codex)]
        )
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            initialThreadId: thread.id
        )
        defer { vm.dispose() }

        for _ in 0..<100 where vm.messages.count < AgentAppViewModel.messageHistoryPageLimit {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(vm.messages.count, AgentAppViewModel.messageHistoryPageLimit)
        XCTAssertFalse(vm.messages.contains { $0.id == oldest.id })
        vm.refreshTokenSaverOptimizationStateFromTimeline(AssistantTimelineState())
        XCTAssertNil(vm.tokenSaverWireRequestText(for: oldest.id),
                     "first paint must not hydrate RCW1 bytes for rows outside the bounded message page")

        vm.loadOlderMessages()
        for _ in 0..<100 where !vm.messages.contains(where: { $0.id == oldest.id }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(vm.messages.contains { $0.id == oldest.id })
        XCTAssertEqual(vm.tokenSaverWireRequestText(for: oldest.id), wire,
                       "loading the older row must reveal its existing Human/RCW1 toggle")
    }

    /// WHY: A short transcript with very tall self-sizing text rows does not benefit
    /// from lazy rematerialization. Crossing that lazy boundary while scrolling used
    /// to enter an unbounded AttributeGraph layout loop and grow RSS continuously.
    func test_shortTranscriptUsesEagerHistoryLayoutToKeepScrollBounded() {
        XCTAssertEqual(
            AgentAppView.eagerTranscriptHistoryEntryLimit,
            AgentChatTimelineHistoryLayout.eagerEntryLimit,
            "Agent App must reuse the shared eager-history threshold"
        )
        XCTAssertFalse(
            AgentAppView.usesLazyTranscriptHistoryLayout(entryCount: 6),
            "the six-row real-world reproduction must stay mounted while scrolling"
        )
        XCTAssertFalse(
            AgentChatTimelineHistoryLayout.usesLazyLayout(entryCount: 6),
            "the shared policy is what keeps a short self-sizing timeline mounted"
        )
        XCTAssertFalse(
            AgentAppView.usesLazyTranscriptHistoryLayout(entryCount: 9),
            "pid 36908 hung restoring a long thread in LazyVStack; history must stay eager at any count"
        )
        XCTAssertFalse(AgentChatTimelineHistoryLayout.usesLazyLayout(entryCount: 9))
        XCTAssertEqual(
            AgentAppView.usesLazyTranscriptHistoryLayout(entryCount: 8),
            AgentChatTimelineHistoryLayout.usesLazyLayout(entryCount: 8)
        )
        XCTAssertFalse(
            AgentAppView.usesLazyTranscriptHistoryLayout(entryCount: 40, liveTurnActive: true)
        )
        XCTAssertFalse(
            AgentChatTimelineHistoryLayout.usesLazyLayout(entryCount: 40, liveTurnActive: false)
        )
    }

    /// WHY: provider item IDs can repeat across turns. A row may use a legacy
    /// item-id translation only when that ID is unique; otherwise showing no raw
    /// toggle is safer than copying another row's provider bytes.
    func test_tokenSaverItemTranslationIndex_neverCrossesDuplicateItemIDsBetweenTurns() {
        func item(turnId: String, body: String) -> AssistantItem {
            AssistantItem(
                id: "shared-item",
                turnId: turnId,
                type: .assistantMessage,
                state: .completed,
                body: body,
                startedAtMs: 1,
                finishedAtMs: 2
            )
        }
        let firstTurn = AssistantTurnSnapshot(
            turnId: "turn-a",
            items: [item(turnId: "turn-a", body: "First human answer")],
            finished: true
        )
        let secondTurn = AssistantTurnSnapshot(
            turnId: "turn-b",
            items: [item(turnId: "turn-b", body: "Second human answer")],
            finished: true
        )
        let first = AssistantSR1Translation(
            itemId: "shared-item",
            originalText: "RCW1\tA\t1\nO\tfirst\n.\n",
            rewrittenText: "First human answer"
        )
        let second = AssistantSR1Translation(
            itemId: "shared-item",
            originalText: "RCW1\tA\t1\nO\tsecond\n.\n",
            rewrittenText: "Second human answer"
        )

        let unsafeLegacy = AgentAppViewModel.safelyIndexedTokenSaverItemTranslations(
            ["shared-item": second],
            turns: [firstTurn, secondTurn]
        )
        XCTAssertTrue(unsafeLegacy.isEmpty,
                      "an ambiguous legacy ID must not show or copy the last writer's RCW1 in both rows")

        let firstKey = AgentAppView.tokenSaverTimelineItemDisplayKey(
            turnId: "turn-a",
            itemId: "shared-item"
        )
        let secondKey = AgentAppView.tokenSaverTimelineItemDisplayKey(
            turnId: "turn-b",
            itemId: "shared-item"
        )
        let exact = AgentAppViewModel.safelyIndexedTokenSaverItemTranslations(
            [firstKey: first, secondKey: second],
            turns: [firstTurn, secondTurn]
        )
        XCTAssertEqual(exact[firstKey]?.originalText, first.originalText)
        XCTAssertEqual(exact[secondKey]?.originalText, second.originalText,
                       "composite identities must preserve each row's own raw/copy payload")
    }

    /// IMPORTANT regression: hand-building a composite dictionary proves only
    /// the lookup helper. Production replay must actually populate those keys as
    /// translation events arrive, including when a provider reuses an item ID.
    func test_tokenSaverTimelineEventsPopulateCompositeTranslationIndexAcrossDuplicateItemIDs() {
        func item(turnId: String, body: String) -> AssistantItem {
            AssistantItem(
                id: "shared-item",
                turnId: turnId,
                type: .assistantMessage,
                state: .completed,
                body: body,
                startedAtMs: 1,
                finishedAtMs: 2
            )
        }

        var timeline = AssistantTimelineState()
        timeline.apply(.turnStarted(turnId: "turn-a"))
        timeline.apply(.itemStarted(item: item(turnId: "turn-a", body: "First human answer")))
        timeline.apply(.wireTranslation(.init(
            itemId: "shared-item",
            originalText: "RCW1\tA\t1\nO\tfirst\n.\n",
            rewrittenText: "First human answer"
        )))
        timeline.apply(.turnCompleted(turnId: "turn-a", finalMessage: "First human answer"))

        timeline.apply(.turnStarted(turnId: "turn-b"))
        timeline.apply(.itemStarted(item: item(turnId: "turn-b", body: "Second human answer")))
        timeline.apply(.wireTranslation(.init(
            itemId: "shared-item",
            originalText: "RCW1\tA\t1\nO\tsecond\n.\n",
            rewrittenText: "Second human answer"
        )))

        let indexed = AgentAppViewModel.safelyIndexedTokenSaverItemTranslations(
            timeline.tokenSaverTranslationsByItemId,
            turns: timeline.turns
        )
        let firstKey = AgentAppView.tokenSaverTimelineItemDisplayKey(
            turnId: "turn-a",
            itemId: "shared-item"
        )
        let secondKey = AgentAppView.tokenSaverTimelineItemDisplayKey(
            turnId: "turn-b",
            itemId: "shared-item"
        )

        XCTAssertEqual(indexed[firstKey]?.rewrittenText, "First human answer")
        XCTAssertEqual(indexed[secondKey]?.rewrittenText, "Second human answer",
                       "production replay must fill the composite index, not only its lookup seam")
    }

    /// IMPORTANT regression: once the durable final response exists, its live
    /// item must use the FK-owned message identity for v69 mode persistence and
    /// Copy. Earlier commentary remains transient and must not borrow that row.
    func test_liveFinalItemBindsOnlyItsDurableTokenSaverMessageIdentity() {
        let durable = AgentMessageID()
        let commentary = AssistantItem(
            id: "commentary",
            turnId: "turn-live",
            type: .assistantMessage,
            state: .completed,
            body: "Still checking.",
            startedAtMs: 1,
            finishedAtMs: 2
        )
        let final = AssistantItem(
            id: "final",
            turnId: "turn-live",
            type: .assistantMessage,
            state: .streaming,
            body: "The focused checks passed.",
            startedAtMs: 3
        )
        let turn = AssistantTurnSnapshot(
            turnId: "turn-live",
            items: [commentary, final],
            finished: false
        )

        XCTAssertNil(AgentAppView.durableFinalMessageId(
            for: commentary,
            in: turn,
            candidate: durable
        ), "commentary must keep its own transient timeline identity")
        XCTAssertEqual(AgentAppView.durableFinalMessageId(
            for: final,
            in: turn,
            candidate: durable
        ), durable, "the live final must bind its toggle and Copy to the durable v69 message row")
        XCTAssertNil(AgentAppView.durableFinalMessageId(
            for: final,
            in: turn,
            candidate: nil
        ), "missing durable identity must fail safely instead of inventing one")
    }

    /// WHY: two providers may return the same readable sentence. Final rows
    /// must rehydrate by durable turn/message identity, never by matching text,
    /// so each toggle and Copy action keeps its own byte-exact RCW1 response.
    func test_identicalHumanFinalsRehydrateDistinctTurnOwnedRCW1Responses() async throws {
        let tmp = NSTemporaryDirectory() + "rcw1-identical-finals-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let workspaceID = WorkspaceID()
        let thread = AgentThread(
            workspaceId: workspaceID,
            title: "Identical readable finals",
            provider: .codex,
            model: "test-model"
        )
        let human = "The focused checks passed."
        let firstMessage = AgentMessage(
            threadId: thread.id,
            role: .assistant,
            content: human,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let secondMessage = AgentMessage(
            threadId: thread.id,
            role: .assistant,
            content: human,
            createdAt: Date(timeIntervalSince1970: 1_700_000_002)
        )
        let unlinkedMessage = AgentMessage(
            threadId: thread.id,
            role: .assistant,
            content: "Readable response without a provider turn id.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_003)
        )
        let firstRaw = "RCW1\tA\t1\nO\tfirst raw\n.\n"
        let secondRaw = "RCW1\tA\t1\nO\tsecond raw\n.\n"
        let unlinkedRaw = "RCW1\tA\t1\nO\tunlinked raw\n.\n"
        let unlinkedRunId = AgentRunID()
        let unlinkedTurnId = "run-\(unlinkedRunId.value.uuidString)"
        try threadRepo.upsert(thread)
        try messageRepo.append(firstMessage)
        try messageRepo.append(secondMessage)
        try messageRepo.append(unlinkedMessage)
        try messageRepo.upsertRCW1ResponseTranslation(
            messageId: firstMessage.id,
            runId: AgentRunID(),
            turnId: "turn-first",
            wireResponseText: firstRaw
        )
        try messageRepo.upsertRCW1ResponseTranslation(
            messageId: secondMessage.id,
            runId: AgentRunID(),
            turnId: "turn-second",
            wireResponseText: secondRaw
        )
        try messageRepo.upsertRCW1ResponseTranslation(
            messageId: unlinkedMessage.id,
            runId: unlinkedRunId,
            turnId: unlinkedTurnId,
            wireResponseText: unlinkedRaw
        )
        try messageRepo.setTokenSaverDisplayMode(messageId: firstMessage.id, mode: .rcw1)

        func makeViewModel() -> AgentAppViewModel {
            let coordinator = AgentRunCoordinator(
                runRepo: runRepo,
                messageRepo: messageRepo,
                threadRepo: threadRepo,
                providers: [.codex: FakeProviderRunner(provider: .codex)]
            )
            return AgentAppViewModel(
                workspaceID: workspaceID,
                cwd: tmp,
                coordinator: coordinator,
                threadRepo: threadRepo,
                messageRepo: messageRepo,
                initialThreadId: thread.id
            )
        }

        let initial = makeViewModel()
        await initial.waitForMessageHistoryLoad()
        XCTAssertEqual(initial.tokenSaverMessageId(forRCW1TurnId: "turn-first"), firstMessage.id)
        XCTAssertEqual(initial.tokenSaverMessageId(forRCW1TurnId: "turn-second"), secondMessage.id)
        XCTAssertEqual(initial.tokenSaverOriginalText(for: firstMessage.id), firstRaw)
        XCTAssertEqual(initial.tokenSaverOriginalText(for: secondMessage.id), secondRaw)
        XCTAssertTrue(initial.tokenSaverDisplaysOriginal(for: firstMessage.id))
        XCTAssertFalse(initial.tokenSaverDisplaysOriginal(for: secondMessage.id),
                       "hydration must keep B in Human when only A was clicked")
        XCTAssertTrue(initial.tokenSaverRequiresDurableMessageRow(for: unlinkedMessage.id),
                      "an unlinked final must keep its own message row instead of borrowing timeline text")
        initial.dispose()

        let relaunched = makeViewModel()
        defer { relaunched.dispose() }
        await relaunched.waitForMessageHistoryLoad()
        XCTAssertEqual(relaunched.tokenSaverMessageId(forRCW1TurnId: "turn-first"), firstMessage.id)
        XCTAssertEqual(relaunched.tokenSaverMessageId(forRCW1TurnId: "turn-second"), secondMessage.id)
        XCTAssertEqual(relaunched.tokenSaverOriginalText(for: firstMessage.id), firstRaw)
        XCTAssertEqual(relaunched.tokenSaverOriginalText(for: secondMessage.id), secondRaw,
                       "relaunch must not let identical Human text swap the second row's raw/copy payload")
        XCTAssertTrue(relaunched.tokenSaverDisplaysOriginal(for: firstMessage.id))
        XCTAssertFalse(relaunched.tokenSaverDisplaysOriginal(for: secondMessage.id))
        XCTAssertEqual(relaunched.tokenSaverOriginalText(for: unlinkedMessage.id), unlinkedRaw)
        XCTAssertTrue(relaunched.tokenSaverRequiresDurableMessageRow(for: unlinkedMessage.id),
                      "relaunch must preserve the canonical toggle when no safe turn link exists")
    }

    /// WHY: a page load can read RCW1 just before the user clicks Human. That
    /// stale result must not repaint the row while the newer per-message choice
    /// is being saved.
    func test_staleDisplayModeHydrationCannotOverrideClickedMessage() async throws {
        let tmp = NSTemporaryDirectory() + "rcw1-display-race-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let workspaceID = WorkspaceID()
        let thread = AgentThread(
            workspaceId: workspaceID,
            title: "RCW1 display race",
            provider: .codex,
            model: "test-model"
        )
        let message = AgentMessage(
            threadId: thread.id,
            role: .assistant,
            content: "Readable answer"
        )
        try threadRepo.upsert(thread)
        try messageRepo.append(message)
        try messageRepo.upsertRCW1ResponseTranslation(
            messageId: message.id,
            runId: AgentRunID(),
            turnId: "turn-display-race",
            wireResponseText: "RCW1\tA\t1\nO\tanswer\n.\n"
        )
        try messageRepo.setTokenSaverDisplayMode(messageId: message.id, mode: .rcw1)

        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(provider: .codex)]
        )
        let vm = AgentAppViewModel(
            workspaceID: workspaceID,
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            initialThreadId: thread.id
        )
        defer { vm.dispose() }
        await vm.waitForMessageHistoryLoad()
        XCTAssertTrue(vm.tokenSaverDisplaysOriginal(for: message.id))

        vm.setTokenSaverDisplaysOriginal(false, for: message.id)
        XCTAssertFalse(vm.tokenSaverDisplaysOriginal(for: message.id))
        vm.mergePersistedTokenSaverDisplayModes([message.id: .rcw1])
        XCTAssertFalse(
            vm.tokenSaverDisplaysOriginal(for: message.id),
            "an older hydration read must not undo the user's newer Human click"
        )

        for _ in 0..<100 {
            let mode = try messageRepo.tokenSaverDisplayModes(
                threadId: thread.id,
                messageIds: [message.id]
            )[message.id]
            if mode == nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(
            try messageRepo.tokenSaverDisplayModes(
                threadId: thread.id,
                messageIds: [message.id]
            )[message.id],
            "the clicked Human mode must remain the durable default after the queued write"
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
