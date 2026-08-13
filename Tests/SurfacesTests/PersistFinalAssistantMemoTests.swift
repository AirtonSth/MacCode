import XCTest
import CoreModel
import Persistence
import AgentRuntime
@testable import Surfaces

/// PERF-MAC_AGENT-012: validates `shouldReloadForFinal` — the pure seam that
/// decides when `persistFinalAssistantIfMissing` must reload the full thread
/// message list versus safely skipping the O(history) DB query.
///
/// WHY the seam exists:
/// Before this fix every completion with a new final text fired `messageRepo.list`
/// for the whole thread (O(thread) main-actor DB read). The per-thread ID memo
/// (`lastPersistedFinalIdByThread`) records the `AgentMessageID` this surface
/// wrote in the current session. When the ID is present, the surface owns the
/// DB state for that thread from this session, so a new (different-text) final
/// can be appended directly — no list needed. When the ID is absent (first
/// completion in a session) a one-time reload guards against a prior session
/// or path having already persisted the same text.
///
/// R7: content keys are `AssistantContentFingerprint` (utf8 count + digest).
///
/// Correctness argument:
/// - If id == nil → unknown DB state → reload (pessimistic, correct).
/// - If id != nil → we persisted the previous final; content memo already
///   confirmed the incoming text differs; the previous row is in DB with
///   different content, so appending the new text cannot create a duplicate.
/// - On revert, both the content memo and the ID memo are cleared so the
///   next completion falls back to the safe reload path.
@MainActor
final class PersistFinalAssistantMemoTests: XCTestCase {

    private func fp(_ text: String) -> AssistantContentFingerprint {
        AssistantContentFingerprint.of(text)
    }

    // MARK: - shouldReloadForFinal

    /// No session ID → reload required.
    /// WHY: first completion in a session; DB state is unknown; a prior session
    /// may have written the same final. Reload is the only way to confirm.
    func test_shouldReload_whenNoSessionId() {
        let result = AgentAppViewModel.shouldReloadForFinal(
            lastPersistedId: nil,
            lastPersistedKey: nil,
            incomingKey: fp("some final answer")
        )
        XCTAssertTrue(result,
                      "no session ID means DB state is unknown — reload required to prevent a duplicate persist")
    }

    /// No session ID, even if content key happens to be set → reload required.
    /// WHY: content key without ID can arise if the memo was partially cleared;
    /// the ID is the authoritative proof of session ownership.
    func test_shouldReload_whenNoSessionId_evenIfContentKeyPresent() {
        let result = AgentAppViewModel.shouldReloadForFinal(
            lastPersistedId: nil,
            lastPersistedKey: fp("old answer"),
            incomingKey: fp("new answer")
        )
        XCTAssertTrue(result,
                      "the ID memo is the session ownership proof; a content key without an ID is not sufficient to skip the reload")
    }

    /// Session ID present → skip reload.
    /// WHY: we wrote to this thread this session; DB state is known; the content
    /// memo already confirmed the incoming text is different, so appending is safe.
    func test_shouldNotReload_whenSessionIdPresent() {
        let id = AgentMessageID()
        let result = AgentAppViewModel.shouldReloadForFinal(
            lastPersistedId: id,
            lastPersistedKey: fp("previous final"),
            incomingKey: fp("new final")
        )
        XCTAssertFalse(result,
                       "session ID present means this surface owns the last persisted row; the new text can be appended without a full thread reload")
    }

    /// Session ID present, content key nil → skip reload.
    /// WHY: content key may be absent if the session just started from a
    /// partial state; the ID is sufficient to skip.
    func test_shouldNotReload_whenSessionIdPresent_contentKeyNil() {
        let id = AgentMessageID()
        let result = AgentAppViewModel.shouldReloadForFinal(
            lastPersistedId: id,
            lastPersistedKey: nil,
            incomingKey: fp("some answer")
        )
        XCTAssertFalse(result,
                       "ID presence alone is sufficient to skip reload; content key absence is irrelevant")
    }

    // MARK: - Integration: persistFinalAssistantIfMissing via VM

    private func makeVM() throws -> (AgentAppViewModel, AgentMessageRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-persist-final-memo-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coord = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [
                .codex: FakeProviderRunner(provider: .codex),
                .claude: FakeProviderRunner(provider: .claude)
            ]
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(), cwd: tmp,
            coordinator: coord, threadRepo: threadRepo, messageRepo: messageRepo
        )
        return (vm, messageRepo)
    }

    /// First completion in a session: one assistant message must be written to DB.
    /// WHY: without a session ID the reload path runs, confirms the text is
    /// absent, and the append fires. A missing append = lost final message.
    @MainActor
    func test_firstCompletion_persistsToDB() async throws {
        let (vm, messageRepo) = try makeVM()
        vm.createThread(title: "t1")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        let runId = AgentRunID()

        vm.runCoordinator(vm.coordinator, didFinish: runId, threadId: tid,
                          status: .completed, finalMessage: "Answer A",
                          providerThreadId: nil)

        // Wait for the @MainActor Task in didFinish to execute.
        let deadline = Date().addingTimeInterval(4)
        while (try? messageRepo.list(threadId: tid))?.contains(where: {
            $0.role == .assistant && $0.content == "Answer A"
        }) != true && Date() < deadline {
            await Task.yield()
        }

        let msgs = try messageRepo.list(threadId: tid)
        XCTAssertTrue(msgs.contains(where: { $0.role == .assistant && $0.content == "Answer A" }),
                      "the first completion must persist the final assistant message to DB; losing it means the thread history is corrupt")
    }

    /// Second call with the SAME text must not create a duplicate row.
    /// WHY: the content-equality fast path (PERF-MAC_AGENT-006) must detect the
    /// duplicate and return early; writing twice would corrupt the dedup view.
    @MainActor
    func test_sameTextTwice_noDuplicate() async throws {
        let (vm, messageRepo) = try makeVM()
        vm.createThread(title: "t2")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        let runId1 = AgentRunID()
        let runId2 = AgentRunID()

        vm.runCoordinator(vm.coordinator, didFinish: runId1, threadId: tid,
                          status: .completed, finalMessage: "Answer B",
                          providerThreadId: nil)

        let deadline1 = Date().addingTimeInterval(4)
        while (try? messageRepo.list(threadId: tid))?.contains(where: {
            $0.role == .assistant && $0.content == "Answer B"
        }) != true && Date() < deadline1 {
            await Task.yield()
        }

        vm.runCoordinator(vm.coordinator, didFinish: runId2, threadId: tid,
                          status: .completed, finalMessage: "Answer B",
                          providerThreadId: nil)

        await Task.yield()
        await Task.yield()

        let msgs = try messageRepo.list(threadId: tid)
        let assistantCount = msgs.filter { $0.role == .assistant && $0.content == "Answer B" }.count
        XCTAssertEqual(assistantCount, 1,
                       "identical final text must not produce a second DB row; deduplication is required for correct transcript rendering")
    }

    /// Second call with DIFFERENT text must persist a new row without a full reload.
    /// WHY: once the ID memo is set, the new final skips O(history) list and appends
    /// directly. The result must still appear in DB — skipping reload must not
    /// silently drop the message.
    @MainActor
    func test_differentTextSecond_persists() async throws {
        let (vm, messageRepo) = try makeVM()
        vm.createThread(title: "t3")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        let runId1 = AgentRunID()
        let runId2 = AgentRunID()

        vm.runCoordinator(vm.coordinator, didFinish: runId1, threadId: tid,
                          status: .completed, finalMessage: "Answer C",
                          providerThreadId: nil)

        let deadline1 = Date().addingTimeInterval(4)
        while (try? messageRepo.list(threadId: tid))?.contains(where: {
            $0.role == .assistant && $0.content == "Answer C"
        }) != true && Date() < deadline1 {
            await Task.yield()
        }

        vm.runCoordinator(vm.coordinator, didFinish: runId2, threadId: tid,
                          status: .completed, finalMessage: "Answer D",
                          providerThreadId: nil)

        let deadline2 = Date().addingTimeInterval(4)
        while (try? messageRepo.list(threadId: tid))?.contains(where: {
            $0.role == .assistant && $0.content == "Answer D"
        }) != true && Date() < deadline2 {
            await Task.yield()
        }

        let msgs = try messageRepo.list(threadId: tid)
        XCTAssertTrue(msgs.contains(where: { $0.role == .assistant && $0.content == "Answer D" }),
                      "a new final answer after the ID memo is set must still be persisted — skipping reload must not silently discard the message")
    }
}
