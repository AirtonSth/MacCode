import XCTest
@testable import Surfaces
import CoreModel
@testable import Persistence
@testable import AgentRuntime

/// WHY: the host mirrors every `onThreadChromeWritten` as one
/// `agent.thread.updated`, so iOS sees the surface's own status/unread commits.
/// A pending stamp that never gets its terminal leaves iOS (and macOS) showing
/// a busy thread forever; a write that did not commit, or a duplicate, bumps
/// `agentThreads` for nothing.
@MainActor
final class AgentAppThreadChromeWriteTests: XCTestCase {
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

    func test_startRefusedByProviderAdmission_mirrorsPendingThenFailed() async throws {
        let h = try makeHarness()
        h.coordinator.providerAdmissionCheck = { _, _ in
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "admission refused"])
        }
        await h.send("hello")
        await waitAsync("failed stamp mirrored") { h.writes(for: h.thread.id).count >= 2 }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(h.runner.requests.isEmpty, "fixture: admission refused before the provider")
        XCTAssertEqual(h.writes(for: h.thread.id).map(\.status), [.pending, .failed])
        let row = try XCTUnwrap(try h.threadRepo.get(id: h.thread.id))
        XCTAssertEqual(row.status, .failed, "the row must not stay pending with no owner")
        XCTAssertEqual(
            h.writes(for: h.thread.id).last?.updatedAt.timeIntervalSince1970 ?? 0,
            row.updatedAt.timeIntervalSince1970,
            accuracy: 1,
            "the mirrored failed stamp is the committed one"
        )
    }

    func test_promptTransformFailure_mirrorsPendingThenFailedOnce() async throws {
        let h = try makeHarness(transform: { _, _, _ in
            throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "transform failed"])
        })
        await h.send("hello")
        await waitAsync("failed stamp mirrored") { h.writes(for: h.thread.id).count >= 2 }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(
            h.writes(for: h.thread.id).map(\.status), [.pending, .failed],
            "the transform-failed stamp must not be mirrored twice by the start-failure catch"
        )
        XCTAssertEqual(try h.threadRepo.status(of: h.thread.id), .failed)
    }

    func test_successfulStart_mirrorsOnlyTheSurfacePendingStamp() async throws {
        let h = try makeHarness()
        await h.send("hello")
        await waitAsync("run request captured") { h.runner.requests.count == 1 }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(
            h.writes(for: h.thread.id).map(\.status), [.pending],
            "a start the coordinator owns must never be stamped failed by the surface"
        )
    }

    func test_botReplyOnUnselectedThread_mirrorsUnreadOnceAndNothingWhenAlreadyUnread() throws {
        let h = try makeHarness()
        let other = AgentThread(title: "other", provider: .codex, model: "gpt-5.5")
        try h.threadRepo.upsert(other)
        let peer = BotDefinition(handle: "quinn", name: "Quinn", title: "Scout", description: "", avatarSymbol: "star.fill")

        XCTAssertNotNil(h.vm.presentBotPeerMessage(peer: peer, text: "first", threadId: other.id))
        let first = h.writes(for: other.id)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.hasUnread, true)
        XCTAssertNil(first.first?.status, "an unread-only write must not claim a status")
        XCTAssertEqual(
            first.first?.updatedAt.timeIntervalSince1970 ?? 0,
            try XCTUnwrap(try h.threadRepo.updatedAt(of: other.id)).timeIntervalSince1970,
            accuracy: 1
        )

        XCTAssertNotNil(h.vm.presentBotPeerMessage(peer: peer, text: "second", threadId: other.id))
        XCTAssertEqual(h.writes(for: other.id).count, 1, "an already-unread thread commits nothing to mirror")
    }

    // MARK: - Harness

    private final class Harness {
        let vm: AgentAppViewModel
        let coordinator: AgentRunCoordinator
        let threadRepo: AgentThreadRepository
        let runner: ChromeCapturingRunner
        let thread: AgentThread
        var captured: [AgentThreadChromeWrite] = []

        init(
            vm: AgentAppViewModel,
            coordinator: AgentRunCoordinator,
            threadRepo: AgentThreadRepository,
            runner: ChromeCapturingRunner,
            thread: AgentThread
        ) {
            self.vm = vm
            self.coordinator = coordinator
            self.threadRepo = threadRepo
            self.runner = runner
            self.thread = thread
        }

        func writes(for threadID: AgentThreadID) -> [AgentThreadChromeWrite] {
            captured.filter { $0.threadID == threadID }
        }

        @MainActor
        func send(_ text: String) async {
            vm.prompt = text
            await vm.send()
        }
    }

    private func makeHarness(
        transform: (@MainActor (String, AgentThreadID, AgentRunID) async throws -> String)? = nil
    ) throws -> Harness {
        let tmp = NSTemporaryDirectory() + "rc2-thread-chrome-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let runner = ChromeCapturingRunner(provider: .codex)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let thread = AgentThread(title: "chrome", provider: .codex, model: "gpt-5.5")
        try threadRepo.upsert(thread)
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            draftRepo: AgentThreadDraftRepository(db: db),
            attachmentStore: AgentAttachmentStore(
                root: URL(fileURLWithPath: tmp).appendingPathComponent("agent-attachments")
            ),
            promptHistoryStore: PromptHistoryStore(db: db),
            embedding: AgentAppEmbedding(pinnedThreadId: thread.id, promptTransform: transform)
        )
        vm.providerSnapshots = [
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex,
                models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
                binaryPath: "/usr/bin/true",
                authenticated: true
            )
        ]
        let harness = Harness(
            vm: vm, coordinator: coordinator, threadRepo: threadRepo, runner: runner, thread: thread
        )
        vm.onThreadChromeWritten = { [weak harness] write in harness?.captured.append(write) }
        vm.selectThread(thread.id)
        return harness
    }

    private func waitAsync(_ desc: String, timeout: TimeInterval = 6, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(cond(), "timed out waiting for: \(desc)")
    }
}

private final class ChromeCapturingRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private var _requests: [AgentRunRequest] = []

    var requests: [AgentRunRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    init(provider: AgentProvider) { self.provider = provider }

    func listModels() async -> [AgentModelDescriptor] {
        [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: provider)]
    }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        lock.lock(); _requests.append(request); lock.unlock()
        // Never finishes: the test reads the start-path stamps only.
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}
