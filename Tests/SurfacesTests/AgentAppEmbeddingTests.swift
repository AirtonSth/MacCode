import XCTest
@testable import Surfaces
import CoreModel
@testable import Persistence
@testable import AgentRuntime

/// WHY: the bot desk embeds Agent App on one fixed thread that has no workspace.
/// These tests pin the embedding contract without changing default Agent App behavior.
@MainActor
final class AgentAppEmbeddingTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "agent.lastModel.byProvider.v1")
    }

    private struct Harness {
        let vm: AgentAppViewModel
        let threadRepo: AgentThreadRepository
        let messageRepo: AgentMessageRepository
        let runner: EmbeddingCapturingRunner
        let thread: AgentThread
    }

    private func makeHarness(
        threadWorkspace: WorkspaceID?,
        embed: ((AgentThreadID) -> AgentAppEmbedding)?
    ) throws -> Harness {
        let tmp = NSTemporaryDirectory() + "rc2-vm-embedding-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let runner = EmbeddingCapturingRunner(provider: .codex)
        let coord = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let thread = AgentThread(
            workspaceId: threadWorkspace,
            title: "embedded",
            provider: .codex,
            model: "gpt-5.5"
        )
        try threadRepo.upsert(thread)
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: tmp,
            coordinator: coord,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            draftRepo: AgentThreadDraftRepository(db: db),
            attachmentStore: AgentAttachmentStore(root: URL(fileURLWithPath: tmp).appendingPathComponent("agent-attachments")),
            promptHistoryStore: PromptHistoryStore(db: db),
            embedding: embed?(thread.id)
        )
        vm.providerSnapshots = [
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex,
                models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
                binaryPath: "/usr/bin/true",
                authenticated: true
            )
        ]
        return Harness(vm: vm, threadRepo: threadRepo, messageRepo: messageRepo, runner: runner, thread: thread)
    }

    private func waitAsync(_ desc: String, timeout: TimeInterval = 6, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(cond(), "timed out waiting for: \(desc)")
    }

    /// WHY: bot threads are created without a workspace; a pinned surface must still open them.
    func test_pinnedVMSelectsWorkspaceNilThreadBecauseBotThreadsHaveNoWorkspace() async throws {
        let h = try makeHarness(threadWorkspace: nil) { AgentAppEmbedding(pinnedThreadId: $0) }
        h.vm.selectThread(h.thread.id)
        await h.vm.waitForSelectThreadHydrationForTesting()
        XCTAssertEqual(h.vm.selectedThreadId, h.thread.id)
        XCTAssertEqual(h.vm.threads.map(\.id), [h.thread.id],
                       "embedded surface must list only its pinned thread")
    }

    /// WHY: the default Agent App must keep isolating workspaces; embedding must not loosen it.
    func test_nonEmbeddedVMStillRejectsWorkspaceNilThreadToKeepWorkspaceIsolation() async throws {
        let h = try makeHarness(threadWorkspace: nil, embed: nil)
        h.vm.selectThread(h.thread.id)
        await h.vm.waitForSelectThreadHydrationForTesting()
        XCTAssertNil(h.vm.selectedThreadId)
    }

    /// WHY: a pinned surface must not wander to other threads.
    func test_pinnedVMIgnoresSelectionOfOtherThreadsBecauseItIsBoundToOne() async throws {
        let h = try makeHarness(threadWorkspace: nil) { AgentAppEmbedding(pinnedThreadId: $0) }
        let other = AgentThread(workspaceId: h.vm.workspaceID, title: "other", provider: .codex, model: "gpt-5.5")
        try h.threadRepo.upsert(other)
        h.vm.selectThread(other.id)
        XCTAssertEqual(h.vm.selectedThreadId, h.thread.id)
    }

    /// WHY: the desk compiles a bot-brain payload for the provider, but the transcript
    /// must show exactly what the user typed.
    func test_promptTransformReachesRunPromptWhileUserMessageStaysRaw() async throws {
        var started: [(AgentRunID, AgentThreadID)] = []
        var transformedRunIds: [AgentRunID] = []
        let h = try makeHarness(threadWorkspace: nil) { tid in
            AgentAppEmbedding(
                pinnedThreadId: tid,
                executionCwd: "/tmp/bot-home",
                promptTransform: { text, _, runId in
                    transformedRunIds.append(runId)
                    return "COMPILED[\(text)]"
                },
                onRunStarted: { runId, threadId in started.append((runId, threadId)) }
            )
        }
        h.vm.selectThread(h.thread.id)
        await h.vm.waitForSelectThreadHydrationForTesting()
        h.vm.prompt = "hello bot"
        await h.vm.send()
        await waitAsync("run request captured") { h.runner.requests.count == 1 }
        let request = try XCTUnwrap(h.runner.requests.first)
        XCTAssertEqual(request.prompt, "COMPILED[hello bot]")
        XCTAssertEqual(request.userMessageContent, "hello bot")
        XCTAssertEqual(request.cwd, "/tmp/bot-home", "executionCwd must override the surface cwd")
        XCTAssertEqual(transformedRunIds, [request.runId])
        let user = try h.messageRepo.listRecent(threadId: h.thread.id, limit: 10).first(where: { $0.role == .user })
        XCTAssertEqual(user?.content, "hello bot")
        XCTAssertEqual(started.count, 1, "onRunStarted must fire exactly once per run")
        XCTAssertEqual(started.first?.0, request.runId)
        XCTAssertEqual(started.first?.1, h.thread.id)
    }

    /// WHY: a failed prompt compile must never reach the provider with the raw text.
    func test_throwingPromptTransformDoesNotSendBecauseRawPromptWouldBypassBotBrain() async throws {
        struct Boom: Error {}
        var started = 0
        let h = try makeHarness(threadWorkspace: nil) { tid in
            AgentAppEmbedding(
                pinnedThreadId: tid,
                promptTransform: { _, _, _ in throw Boom() },
                onRunStarted: { _, _ in started += 1 }
            )
        }
        h.vm.selectThread(h.thread.id)
        await h.vm.waitForSelectThreadHydrationForTesting()
        h.vm.prompt = "hello"
        await h.vm.send()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(h.runner.requests.isEmpty)
        XCTAssertEqual(started, 0)
        XCTAssertTrue(h.vm.statusMessage.contains("Failed to start"))
    }

    /// WHY: only Agent App tabs get the side chat and /btw hosts from the router.
    /// A Bot desk has neither, and send() clears the composer before the command
    /// runs, so without a note the typed question vanished with no answer.
    func test_sideAndBtwOnAnEmbeddedChatLeaveANoteBecauseNoHostCanAnswerThem() async throws {
        let h = try makeHarness(threadWorkspace: nil) { AgentAppEmbedding(pinnedThreadId: $0) }
        h.vm.providerSnapshots = [
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex,
                models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
                binaryPath: "/usr/bin/true",
                authenticated: true,
                capabilitiesOverride: AgentProviderCapabilities(
                    supportsAttachments: true,
                    supportedAttachmentKinds: [.file, .image],
                    supportedAttachmentMediaTypes: ["*/*"],
                    supportsApprovals: true,
                    supportsUserInput: true,
                    supportsStreaming: true,
                    supportsFork: true,
                    supportsRollback: true,
                    supportsPlanReview: true
                )
            )
        ]
        h.vm.selectThread(h.thread.id)
        await h.vm.waitForSelectThreadHydrationForTesting()
        XCTAssertNil(h.vm.onRequestBtw, "an embedded chat is not wired to a /btw host")
        XCTAssertNil(h.vm.onRequestSideChat, "an embedded chat is not wired to a side chat host")

        h.vm.prompt = "/btw what changed?"
        await h.vm.send()
        XCTAssertEqual(h.vm.messages.last?.role, .system)
        XCTAssertEqual(h.vm.messages.last?.content, "/btw is not available in this chat.")

        h.vm.prompt = "/side compare both"
        await h.vm.send()
        XCTAssertEqual(h.vm.messages.last?.role, .system)
        XCTAssertEqual(h.vm.messages.last?.content, "/side is not available in this chat.")

        XCTAssertTrue(h.runner.requests.isEmpty, "a local command must not start a provider run")
    }
    func test_contextualReplyFailurePreservesDraftAndNeverStartsProvider() async throws {
        var reject = true
        var sent: [String] = []
        let h = try makeHarness(threadWorkspace: nil) { threadID in
            AgentAppEmbedding(pinnedThreadId: threadID, hostReplyHandler: { text, _ in
                if reject { throw NSError(domain: "Notice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Question is already resolved"] ) }
                sent.append(text)
                return true
            })
        }
        h.vm.selectThread(h.thread.id)
        await h.vm.waitForSelectThreadHydrationForTesting()
        let target = AgentReplyTarget(threadId: h.thread.id, excerpt: "Deploy which workspace?", noticeMessageID: "notice-A")
        h.vm.composerState.replyTarget = target
        h.vm.prompt = "Use staging"
        await h.vm.send()
        XCTAssertEqual(h.vm.prompt, "Use staging")
        XCTAssertEqual(h.vm.activeReplyTarget, target)
        XCTAssertEqual(h.vm.statusMessage, "Question is already resolved")
        XCTAssertTrue(h.runner.requests.isEmpty)
        reject = false
        await h.vm.send()
        XCTAssertEqual(sent, ["Use staging"])
        XCTAssertTrue(h.vm.prompt.isEmpty)
        XCTAssertNil(h.vm.activeReplyTarget)
        XCTAssertTrue(h.runner.requests.isEmpty)
    }

    func test_peerReplyKeepsTheAttributedBotEvenWhereOrdinaryRepliesAreHidden() async throws {
        let h = try makeHarness(threadWorkspace: nil) { AgentAppEmbedding(pinnedThreadId: $0) }
        h.vm.selectThread(h.thread.id)
        await h.vm.waitForSelectThreadHydrationForTesting()
        XCTAssertFalse(h.vm.supportsReplies)
        let bot = BotDefinition(handle: "quinn", name: "Quinn", title: "CRM", description: "")
        h.vm.beginReply(to: AgentMessage(
            threadId: h.thread.id, role: .assistant,
            content: BotPeerTranscript.encode(peer: bot, text: "**Inbox** is clear.")
        ))
        XCTAssertEqual(h.vm.activeReplyTarget?.peerHandle, "quinn")
        XCTAssertEqual(h.vm.activeReplyTarget?.peerBotID, bot.id)
        XCTAssertEqual(h.vm.activeReplyTarget?.excerpt, "Inbox is clear.")
        h.vm.cancelReply()
        h.vm.beginReply(to: "Ordinary answer")
        XCTAssertNil(h.vm.activeReplyTarget)
    }

    func test_sendNoticeReplyReportsAcceptedAndClearsItsOwnDraft() async throws {
        // WHY: a host-accepted notice answer must read as sent (no resend), and the
        // composer must end empty so the card's text is not sent twice.
        var sent: [String] = []
        let h = try makeHarness(threadWorkspace: nil) { threadID in
            AgentAppEmbedding(pinnedThreadId: threadID, hostReplyHandler: { text, _ in
                sent.append(text)
                return true
            })
        }
        h.vm.selectThread(h.thread.id)
        await h.vm.waitForSelectThreadHydrationForTesting()
        let notice = AgentMessage(id: AgentMessageID(), threadId: h.thread.id, role: .assistant,
                                  content: "Deploy which workspace?", createdAt: Date())

        let ok = await h.vm.sendNoticeReply(to: notice, text: "Use staging")

        XCTAssertTrue(ok)
        XCTAssertEqual(sent, ["Use staging"])
        XCTAssertTrue(h.vm.prompt.isEmpty)
        XCTAssertNil(h.vm.activeReplyTarget)
    }

    func test_sendNoticeReplyFailureKeepsDraftTypedDuringSend() async throws {
        // WHY: a failed notice answer must not wipe a draft the user typed while it sent.
        let h = try makeHarness(threadWorkspace: nil) { threadID in
            AgentAppEmbedding(pinnedThreadId: threadID, hostReplyHandler: { _, _ in
                throw NSError(domain: "Notice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Question is already resolved"])
            })
        }
        h.vm.selectThread(h.thread.id)
        await h.vm.waitForSelectThreadHydrationForTesting()
        let notice = AgentMessage(id: AgentMessageID(), threadId: h.thread.id, role: .assistant,
                                  content: "Deploy which workspace?", createdAt: Date())

        let ok = await h.vm.sendNoticeReply(to: notice, text: "Use staging")

        XCTAssertFalse(ok)
        XCTAssertEqual(h.vm.statusMessage, "Question is already resolved")
        XCTAssertNil(h.vm.activeReplyTarget, "the target we set is cleared on failure")
        XCTAssertTrue(h.vm.prompt.isEmpty, "our own text is cleared on failure")
    }

}

private final class EmbeddingCapturingRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private var _requests: [AgentRunRequest] = []

    var requests: [AgentRunRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    init(provider: AgentProvider) { self.provider = provider }

    func listModels() async -> [AgentModelDescriptor] {
        [AgentModelDescriptor(id: "capture-model", label: "Capture Model", provider: provider)]
    }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        lock.lock(); _requests.append(request); lock.unlock()
        Task.detached {
            onEvent(.status(.completed))
            onEvent(.finished(.completed, finalMessage: nil, providerThreadId: request.providerThreadId ?? UUID().uuidString))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}
