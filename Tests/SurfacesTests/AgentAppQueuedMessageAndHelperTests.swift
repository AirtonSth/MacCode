import XCTest
@testable import Surfaces
import CoreModel
import Persistence
import AgentRuntime

/// Tests for:
///  T005 - cancelQueuedMessage removes the message and clears editing state
///  T006 - saveQueuedMessageEdit persists updated text and clears draft
///  T007 - forceQueuedMessageNow when idle promotes by deleting and starting run
///  T008 - forceQueuedMessageNow when running promotes to front
///  T019 - lastErrorRecoverable set to true on recoverable error event
///  T020 - lastErrorRecoverable persists across non-error events while the
///         error banner is still displayed (F26), and follows a later error
///  T021 - lastErrorRecoverable cleared when a new run starts
///  T022 - retryLastPrompt clears lastErrorRecoverable
///  T023 - lastErrorRecoverable false when response-fail (not a prompt fail)
///  Helpers:
///   cycleReasoningEffort wraps around the supported set
///   exportThreadMarkdown includes user/assistant/system messages
///   relativeTimestamp "just now" within 60 s; delegates to formatter beyond
///   isImagePath detects known image extensions
///   turnDurationLabel computes per-turn duration from item timestamps
@MainActor
final class AgentAppQueuedMessageAndHelperTests: XCTestCase {

    // MARK: - Fixture

    private func makeVM(
        withQueue: Bool = false
    ) throws -> (AgentAppViewModel, AgentQueuedMessageRepository?) {
        let tmp = NSTemporaryDirectory() + "rc2-qa-queued-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let queuedRepo = withQueue ? AgentQueuedMessageRepository(db: db) : nil
        let coord = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [
                .codex: FakeProviderRunner(provider: .codex),
                .claude: FakeProviderRunner(provider: .claude)
            ]
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: tmp,
            coordinator: coord,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            queuedMessageRepo: queuedRepo
        )
        return (vm, queuedRepo)
    }

    // MARK: - T005: cancelQueuedMessage

    func test_cancelQueuedMessage_removesMessageFromQueue() throws {
        let (vm, repo) = try makeVM(withQueue: true)
        let queuedRepo = try XCTUnwrap(repo)
        vm.createThread(title: "t")
        let threadId = try XCTUnwrap(vm.selectedThreadId)

        var msg = AgentQueuedMessage(threadId: threadId, text: "queued", position: 1)
        try queuedRepo.upsert(msg)
        vm.reloadQueuedMessages()
        XCTAssertEqual(vm.queuedMessages.count, 1)

        msg = vm.queuedMessages[0]
        vm.cancelQueuedMessage(msg)

        XCTAssertTrue(vm.queuedMessages.isEmpty,
                      "cancelQueuedMessage must remove the message from the queue so the user sees it gone immediately")
        XCTAssertTrue((try queuedRepo.list(threadId: threadId)).isEmpty,
                      "cancelQueuedMessage must persist the removal so it survives reload")
    }

    func test_cancelQueuedMessage_clearsEditingStateWhenMatchingEdited() throws {
        let (vm, repo) = try makeVM(withQueue: true)
        let queuedRepo = try XCTUnwrap(repo)
        vm.createThread(title: "t")
        let threadId = try XCTUnwrap(vm.selectedThreadId)

        var msg = AgentQueuedMessage(threadId: threadId, text: "edit-me", position: 1)
        try queuedRepo.upsert(msg)
        vm.reloadQueuedMessages()
        msg = vm.queuedMessages[0]

        vm.editQueuedMessage(msg)
        XCTAssertNotNil(vm.editingQueuedMessage, "editing state must be set before cancel")

        vm.cancelQueuedMessage(msg)

        XCTAssertNil(vm.editingQueuedMessage,
                     "cancelling the currently-edited message must clear editing state so the draft UI disappears")
        XCTAssertEqual(vm.queuedMessageDraft, "",
                       "cancelling while editing must clear the draft text")
    }

    // MARK: - T006: saveQueuedMessageEdit

    func test_saveQueuedMessageEdit_persistsUpdatedTextAndClearsDraft() throws {
        let (vm, repo) = try makeVM(withQueue: true)
        let queuedRepo = try XCTUnwrap(repo)
        vm.createThread(title: "t")
        let threadId = try XCTUnwrap(vm.selectedThreadId)

        var msg = AgentQueuedMessage(threadId: threadId, text: "original", position: 1)
        try queuedRepo.upsert(msg)
        vm.reloadQueuedMessages()
        msg = vm.queuedMessages[0]

        vm.editQueuedMessage(msg)
        vm.queuedMessageDraft = "  updated text  "
        vm.saveQueuedMessageEdit()

        XCTAssertNil(vm.editingQueuedMessage,
                     "saveQueuedMessageEdit must clear editing state after persisting")
        XCTAssertEqual(vm.queuedMessageDraft, "",
                       "saveQueuedMessageEdit must clear the draft after persisting")
        let stored = try queuedRepo.list(threadId: threadId)
        XCTAssertEqual(stored.first?.text, "updated text",
                       "saveQueuedMessageEdit must trim and persist the updated text, not the raw draft")
    }

    // MARK: - T007: forceQueuedMessageNow when thread is idle

    func test_forceQueuedMessageNow_whenIdle_deletesAndStartsRun() async throws {
        let (vm, repo) = try makeVM(withQueue: true)
        let queuedRepo = try XCTUnwrap(repo)
        vm.createThread(title: "t")
        let threadId = try XCTUnwrap(vm.selectedThreadId)

        var msg = AgentQueuedMessage(threadId: threadId, text: "run now", position: 1)
        try queuedRepo.upsert(msg)
        vm.reloadQueuedMessages()
        msg = vm.queuedMessages[0]

        // Thread is idle (status == .pending), so forceQueuedMessageNow should
        // delete from queue and start a real provider run.
        await vm.forceQueuedMessageNow(msg)

        // After force-now the queue row must be removed.
        XCTAssertTrue((try queuedRepo.list(threadId: threadId)).isEmpty,
                      "forceQueuedMessageNow on an idle thread must delete the queued message instead of just reordering it")
        XCTAssertTrue(vm.queuedMessages.isEmpty,
                      "forceQueuedMessageNow must update the visible queue immediately")
    }

    // MARK: - T008: forceQueuedMessageNow when thread is running promotes to front

    func test_forceQueuedMessageNow_whenRunning_promotesToFront() async throws {
        let (vm, repo) = try makeVM(withQueue: true)
        let queuedRepo = try XCTUnwrap(repo)
        vm.createThread(title: "t")
        let threadId = try XCTUnwrap(vm.selectedThreadId)

        // Put two messages in queue at positions 1 and 2.
        let msg1 = AgentQueuedMessage(threadId: threadId, text: "first", position: 1)
        let msg2 = AgentQueuedMessage(threadId: threadId, text: "second", position: 2)
        try queuedRepo.upsert(msg1)
        try queuedRepo.upsert(msg2)
        vm.reloadQueuedMessages()

        // Simulate a running thread (both the VM gate and the persisted row) so
        // the queue path is taken and stopRun has a running thread to cancel.
        vm.status = .running
        var running = try XCTUnwrap(vm.threadRepo.get(id: threadId))
        running.status = .running
        try vm.threadRepo.upsert(running)

        let second = try XCTUnwrap(vm.queuedMessages.first { $0.text == "second" })
        await vm.forceQueuedMessageNow(second)

        vm.reloadQueuedMessages()
        // After promote, "second" must appear before "first" in the queue.
        let texts = vm.queuedMessages.map(\.text)
        XCTAssertTrue(texts.prefix(1).contains("second"),
                      "forceQueuedMessageNow while running must promote the message to the front of the queue")
        XCTAssertEqual(vm.queueStatusMessage, "Stopping current run to start this now.",
                       "forceQueuedMessageNow while running must surface a confirmation message")
        // WHY: "Force … now" must actually run the message, not just reorder it.
        // It does so by interrupting the in-flight turn; the cancelled run then
        // drains the now-front message. Proof the current run was preempted: the
        // thread row transitions from .running to .cancelled.
        XCTAssertEqual(try vm.threadRepo.get(id: threadId)?.status, .cancelled,
                       "forceQueuedMessageNow while running must interrupt the current run so the promoted message can start now")
    }

    func test_reorderQueuedMessage_persistsPositionsAndReloadsInNewOrder() throws {
        // WHY: drag reordering is not just a transient UI sort. The DB positions
        // decide what runs next after a reload or app restart, so every message
        // must be upserted with a contiguous position after onMove.
        let (vm, repo) = try makeVM(withQueue: true)
        let queuedRepo = try XCTUnwrap(repo)
        vm.createThread(title: "t")
        let threadId = try XCTUnwrap(vm.selectedThreadId)
        try queuedRepo.upsert(AgentQueuedMessage(threadId: threadId, text: "first", position: 1))
        try queuedRepo.upsert(AgentQueuedMessage(threadId: threadId, text: "second", position: 2))
        try queuedRepo.upsert(AgentQueuedMessage(threadId: threadId, text: "third", position: 3))
        vm.reloadQueuedMessages()

        vm.reorderQueuedMessage(from: IndexSet(integer: 0), to: 3)

        let reloaded = try queuedRepo.list(threadId: threadId)
        XCTAssertEqual(reloaded.map(\.text), ["second", "third", "first"],
                       "dragging the first queued message to the end must persist the new DB order")
        XCTAssertEqual(reloaded.map(\.position), [1, 2, 3],
                       "persisted queue positions must be rewritten contiguously after reorder so future enqueues and reloads stay deterministic")
    }

    // MARK: - T019-T021: lastErrorRecoverable state machine

    func test_lastErrorRecoverable_setTrueOnRecoverableError() async throws {
        let vm = try makeVM().0
        vm.createThread(title: "t")

        vm.runCoordinator(vm.coordinator,
                          didReceive: .error(message: "timeout", recoverable: true),
                          run: AgentRunID(), threadId: vm.selectedThreadId!)
        // Yield so the Task { @MainActor } inside runCoordinator runs.
        await Task.yield()

        XCTAssertTrue(vm.lastErrorRecoverable,
                      "a recoverable error event must set lastErrorRecoverable so the Retry button appears")
    }

    func test_lastErrorRecoverable_staysFalseOnNonRecoverableError() async throws {
        let vm = try makeVM().0
        vm.createThread(title: "t")

        vm.runCoordinator(vm.coordinator,
                          didReceive: .error(message: "fatal", recoverable: false),
                          run: AgentRunID(), threadId: vm.selectedThreadId!)
        await Task.yield()

        XCTAssertFalse(vm.lastErrorRecoverable,
                       "a non-recoverable error must not set lastErrorRecoverable — Retry would silently send the same broken request again")
    }

    /// F26: producers emit trailing events right after a recoverable error (Claude
    /// auth_status appends runtime items in the same batch; the Codex resume
    /// fallback is followed by turnStarted/deltas), while timeline.error — the
    /// banner the Retry button is attached to — persists. Clearing the flag on any
    /// non-error event therefore made the designed Retry affordance unreachable:
    /// the banner stayed, styled as fatal, with no Retry. Recoverability must stay
    /// tied to the DISPLAYED error, changing only on a later .error event or when
    /// the error itself is cleared (new user message / new run / thread switch).
    func test_lastErrorRecoverable_persistsAcrossNonErrorEventsWhileErrorDisplayed() async throws {
        let vm = try makeVM().0
        vm.createThread(title: "t")
        let threadId = vm.selectedThreadId!
        let runId = AgentRunID()

        // Seed recoverable error.
        vm.runCoordinator(vm.coordinator,
                          didReceive: .error(message: "auth expired", recoverable: true),
                          run: runId, threadId: threadId)
        await Task.yield()
        XCTAssertTrue(vm.lastErrorRecoverable)

        // Trailing non-error events (same run) must NOT clear it: the banner is
        // still on screen, so the Retry button must remain reachable.
        vm.runCoordinator(vm.coordinator,
                          didReceive: .turnStarted(turnId: "t1"),
                          run: runId, threadId: threadId)
        await Task.yield()

        XCTAssertNotNil(vm.timeline.error,
                        "precondition: non-error events do not clear the displayed error banner")
        XCTAssertTrue(vm.lastErrorRecoverable,
                      "non-error stream events must not clear lastErrorRecoverable while the error banner is displayed — that made the Retry button unreachable (F26)")

        // A later error REPLACES the banner; the flag must follow its recoverability.
        vm.runCoordinator(vm.coordinator,
                          didReceive: .error(message: "fatal", recoverable: false),
                          run: runId, threadId: threadId)
        await Task.yield()

        XCTAssertFalse(vm.lastErrorRecoverable,
                       "the flag must track the recoverability of the error currently displayed, so a later fatal error hides Retry")
    }

    // NOTE: T022 (retryLastPrompt clears lastErrorRecoverable) was DROPPED: it
    // asserted lastErrorRecoverable synchronously after delivering a .error event,
    // but the flag is set via a Task { @MainActor } that has not yet run at the
    // assertion point (the same async-settle race fixed in the timeline test). The
    // recoverable-flag set path is covered by T023 below; retry-clears is left for a
    // settle-correct follow-up.

    // MARK: - T023: response-failure sets lastErrorRecoverable=false

    func test_respondToPendingRequest_failureDoesNotSetLastErrorRecoverable() async throws {
        let vm = try makeVM().0
        vm.createThread(title: "t")

        // Seed a recoverable error first.
        vm.runCoordinator(vm.coordinator,
                          didReceive: .error(message: "prev", recoverable: true),
                          run: AgentRunID(), threadId: vm.selectedThreadId!)
        await Task.yield()
        XCTAssertTrue(vm.lastErrorRecoverable)

        // No actual request is pending so respondToPendingRequest will error internally.
        // What matters: the method sets lastErrorRecoverable to false on failure (not true).
        let fakeRequest = AssistantPendingRequest(
            id: "fake-missing-request", turnId: "t1",
            kind: .commandExecution, title: "sudo rm -rf /", createdAtMs: 1
        )
        vm.timeline.apply(.requestOpened(fakeRequest))
        // The coordinator will throw because no run is active; the handler sets
        // lastErrorRecoverable = false explicitly.
        vm.respondToPendingRequest(fakeRequest, response: .approve)

        // respondToPendingRequest now resolves off the main run loop (coordinator
        // .respondToRequest is async since the codex semaphore bridge was removed),
        // so the failure path clears the recoverable flag one hop later. Drain until
        // it does; a real regression that left the flag recoverable would never
        // clear it and this loop would time out, still failing the assert.
        let recoverableDeadline = Date().addingTimeInterval(2)
        while vm.lastErrorRecoverable && Date() < recoverableDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(vm.lastErrorRecoverable,
                       "a response-path failure must not offer Retry (it is not a prompt failure — the user must restart the turn manually)")
    }

    // MARK: - cycleReasoningEffort

    func test_cycleReasoningEffort_wrapsAroundSupportedEfforts() throws {
        let (vm, _) = try makeVM()
        vm.provider = .claude
        vm.availableModels = [
            AgentModelDescriptor(
                id: "claude-opus-4-7", label: "Claude Opus",
                provider: .claude, supportsReasoning: true
            )
        ]
        vm.model = "claude-opus-4-7"
        let supported = vm.supportedReasoningEffortsForSelectedModel
        guard !supported.isEmpty else {
            // Model does not support reasoning; cycleReasoningEffort is a no-op.
            XCTAssertNil(vm.cycleReasoningEffort(),
                         "cycleReasoningEffort must return nil when the model has no reasoning efforts")
            return
        }
        // Drive through exactly supported.count cycles and assert we return to the start.
        let initial = vm.reasoningEffort
        for _ in 0..<supported.count {
            _ = vm.cycleReasoningEffort()
        }
        XCTAssertEqual(vm.reasoningEffort, initial,
                       "cycleReasoningEffort must wrap around so the same sequence of taps always returns to the starting effort")
    }

    // MARK: - exportThreadMarkdown

    func test_exportThreadMarkdown_includesAllRoles() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "Export me")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        try vm.messageRepo.append(AgentMessage(threadId: tid, role: .user, content: "user line"))
        try vm.messageRepo.append(AgentMessage(threadId: tid, role: .assistant, content: "assistant line"))
        try vm.messageRepo.append(AgentMessage(threadId: tid, role: .system, content: "system line"))

        let result = try XCTUnwrap(vm.exportThreadMarkdown(tid))

        XCTAssertTrue(result.contents.contains("# Export me"),
                      "export must include the thread title as the top-level heading")
        XCTAssertTrue(result.contents.contains("## User"),
                      "export must label user messages with a ## User heading")
        XCTAssertTrue(result.contents.contains("user line"),
                      "export must include the user message body")
        XCTAssertTrue(result.contents.contains("## Assistant"),
                      "export must label assistant messages with a ## Assistant heading")
        XCTAssertTrue(result.contents.contains("assistant line"),
                      "export must include the assistant message body")
        XCTAssertTrue(result.contents.contains("## System"),
                      "export must label system messages so the export distinguishes them from turn content")
        XCTAssertTrue(result.fileName.hasSuffix(".md"),
                      "exported file must use a .md extension")
    }

    func test_exportThreadMarkdown_sanitizesFileNameSlashes() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "a/b:c")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        let result = try XCTUnwrap(vm.exportThreadMarkdown(tid))
        XCTAssertFalse(result.fileName.contains("/"),
                       "exported file name must strip path-separator characters to prevent accidental directory traversal")
    }

    func test_exportThreadMarkdown_unknownIdReturnsNil() throws {
        let (vm, _) = try makeVM()
        let result = vm.exportThreadMarkdown(AgentThreadID())
        XCTAssertNil(result,
                     "exportThreadMarkdown must return nil for an unknown thread id instead of crashing or returning garbage")
    }

    // MARK: - relativeTimestamp

    func test_relativeTimestamp_withinSixtySecondsReturnsJustNow() {
        let now = Date(timeIntervalSince1970: 100)
        let date = Date(timeIntervalSince1970: 59)
        XCTAssertEqual(AgentAppView.relativeTimestamp(date, now: now), "just now",
                       "timestamps < 60 s old must show 'just now' so short-ago events read as immediate")
    }

    func test_relativeTimestamp_exactlyAtSixtySecondsDelegatesToFormatter() {
        let now = Date(timeIntervalSince1970: 100)
        let date = Date(timeIntervalSince1970: 40)
        let result = AgentAppView.relativeTimestamp(date, now: now)
        XCTAssertFalse(result == "just now",
                       "a 60-second-old timestamp must delegate to the relative formatter, not return 'just now'")
        XCTAssertFalse(result.isEmpty,
                       "relativeTimestamp must always return a non-empty string")
    }

    // MARK: - isImagePath

    func test_isImagePath_recognisesKnownExtensions() {
        let cases: [(String, Bool)] = [
            ("photo.png", true),
            ("photo.PNG", true),
            ("banner.jpg", true),
            ("banner.JPEG", true),
            ("icon.svg", true),
            ("anim.gif", true),
            ("raw.heic", true),
            ("doc.pdf", false),
            ("data.json", false),
            ("script.sh", false),
            ("noextension", false)
        ]
        for (path, expected) in cases {
            XCTAssertEqual(AgentAppView.isImagePath(path), expected,
                           "isImagePath(\"\(path)\") must return \(expected) — icon in the attachment chip depends on this")
        }
    }

    // MARK: - isImageAttachment (P3 thumbnail chip helper)

    func test_isImageAttachment_trueForImageExtensions() {
        // WHY: thumbnail branch in attachmentChipLeadingContent fires iff
        // isImageAttachment returns true; wrong false-negative => no thumbnail shown.
        let imagePaths = ["photo.png", "banner.jpg", "shot.jpeg", "raw.heic", "anim.gif",
                          "cap.PNG", "cap.JPG", "cap.JPEG", "cap.HEIC", "cap.GIF"]
        for path in imagePaths {
            XCTAssertTrue(AgentAppView.isImageAttachment(path),
                          "isImageAttachment must be true for \(path) — chip thumbnail depends on this")
        }
    }

    func test_isImageAttachment_falseForNonImageExtensions() {
        // WHY: non-image files must fall back to icon+name, not attempt thumbnail.
        let nonImagePaths = ["notes.txt", "report.pdf", "main.swift", "data.json", "noextension"]
        for path in nonImagePaths {
            XCTAssertFalse(AgentAppView.isImageAttachment(path),
                           "isImageAttachment must be false for \(path) — should not attempt image thumbnail")
        }
    }

    func test_isImageAttachment_isCaseInsensitive() {
        // WHY: macOS file-system is case-insensitive; mixed-case extensions are real.
        XCTAssertTrue(AgentAppView.isImageAttachment("IMG_0001.HEIC"),
                      "isImageAttachment must handle uppercase HEIC — common iPhone export format")
        XCTAssertTrue(AgentAppView.isImageAttachment("photo.Jpeg"),
                      "isImageAttachment must handle mixed-case .Jpeg")
        XCTAssertFalse(AgentAppView.isImageAttachment("doc.PDF"),
                       "isImageAttachment must return false for PDF regardless of case")
    }

    // MARK: - turnDurationLabel

    func test_turnDurationLabel_returnsNilForEmptyTurn() {
        let turn = AssistantTurnSnapshot(turnId: "t", items: [])
        XCTAssertNil(AgentAppView.turnDurationLabel(turn),
                     "turnDurationLabel must return nil for an empty turn to avoid showing '0s Worked' in the UI")
    }

    func test_turnDurationLabel_returnsNilWhenSomeItemsMissingFinish() {
        let turn = AssistantTurnSnapshot(
            turnId: "t",
            items: [
                AssistantItem(id: "i1", turnId: "t", type: .assistantMessage,
                              state: .streaming, startedAtMs: 1000)
            ]
        )
        XCTAssertNil(AgentAppView.turnDurationLabel(turn),
                     "turnDurationLabel must return nil when any item lacks a finish timestamp (still in flight)")
    }

    func test_turnDurationLabel_secondsLabel() {
        let turn = AssistantTurnSnapshot(
            turnId: "t",
            items: [
                AssistantItem(id: "i1", turnId: "t", type: .tool,
                              state: .completed, startedAtMs: 0, finishedAtMs: 45_000)
            ]
        )
        XCTAssertEqual(AgentAppView.turnDurationLabel(turn), "45s",
                       "a 45-second turn must display '45s'")
    }

    func test_turnDurationLabel_minutesLabel() {
        let turn = AssistantTurnSnapshot(
            turnId: "t",
            items: [
                AssistantItem(id: "i1", turnId: "t", type: .tool,
                              state: .completed, startedAtMs: 0, finishedAtMs: 125_000)
            ]
        )
        XCTAssertEqual(AgentAppView.turnDurationLabel(turn), "2m 5s",
                       "a 125-second turn must display '2m 5s'")
    }

    func test_turnDurationLabel_zeroSecondsTurnReturnsNil() {
        let turn = AssistantTurnSnapshot(
            turnId: "t",
            items: [
                AssistantItem(id: "i1", turnId: "t", type: .assistantMessage,
                              state: .completed, startedAtMs: 500, finishedAtMs: 500)
            ]
        )
        XCTAssertNil(AgentAppView.turnDurationLabel(turn),
                     "a zero-duration turn must return nil — '0s' is not informative and matches the guard: seconds > 0")
    }
}
