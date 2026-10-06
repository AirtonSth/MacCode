import XCTest
@testable import AppShell
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: a Codex session that cannot be resumed is restarted fresh and seeded
/// with the prior conversation. The seed receipts are durable so a restart does
/// not seed twice. The Settings CLI-path commit swaps in a new Codex adapter;
/// it used to drop the receipts, so later fresh-fallback seeds were not
/// recorded.
@MainActor
final class CodexAdapterReplacementSeedTests: XCTestCase {
    func test_settingsReplacementKeepsSeedReceiptsAndPersistsDeliveredReceipts() async throws {
        let context = try makeContext()
        defer { cleanup(context) }

        let settings = SettingsViewModel(context: context)
        settings.setCodexPath("/tmp/rc-ctx-codex-" + UUID().uuidString, committed: true)

        let dest = AppContextSeedMockClient(freshThreadId: "settings-dest")
        let adapter = fallbackAdapter(dest: dest)
        context.replaceCodexProviderAdapter(adapter)
        XCTAssertNotNil(adapter.contextSeedReceipts)

        let thread = AgentThread(title: "settings-seed", provider: .codex, model: "test-model")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "test-model", status: .pending)
        try context.runRepo.upsert(run)
        let snapshot = try XCTUnwrap(TokenSaverCanonicalConversationSnapshot.capture(
            messages: [
                AgentMessage(threadId: thread.id, role: .user, content: "prior user"),
                AgentMessage(threadId: thread.id, role: .assistant, content: "prior assistant"),
            ],
            persistedRCW1ByMessageId: [:],
            excludingCurrentUserText: "unused"
        ))
        var request = AgentRunRequest(
            runId: run.id,
            threadId: thread.id,
            provider: .codex,
            model: "test-model",
            cwd: context.appSupportDirectory.path,
            prompt: "after settings replace",
            providerThreadId: "old-thread"
        )
        request.contextSnapshot = snapshot
        _ = try await adapter.sendTurn(request) { _ in }

        XCTAssertEqual(dest.startedTurns.count, 1)
        XCTAssertNotNil(dest.startedTurns.first?.request.preparedContextSeed)
        XCTAssertEqual(dest.startedTurns.first?.request.prompt, "after settings replace")
        let receipts = try context.runRepo.contextSelectionReceipts().list(runId: run.id)
        XCTAssertFalse(receipts.isEmpty)
        XCTAssertTrue(receipts.allSatisfy { $0.winner.lifecycle == .delivered })
    }

    private func makeContext() throws -> AppContext {
        let tmp = NSTemporaryDirectory() + "rc-context-seed-app-" + UUID().uuidString
        return try AppContext(channel: .debug, appSupportOverride: tmp)
    }

    private func cleanup(_ context: AppContext) {
        try? FileManager.default.removeItem(atPath: context.appSupportDirectory.path)
    }

    private func fallbackAdapter(dest: AppContextSeedMockClient) -> CodexAppServerAdapter {
        let timedOut = AppContextSeedMockClient(
            openThreadError: CodexAppServerError.requestTimedOut(method: "thread/resume", timeout: 30)
        )
        let factoryCalls = AppContextSeedCounter()
        return CodexAppServerAdapter(
            clientFactory: { _, notificationHandler, _ in
                factoryCalls.increment()
                let client = factoryCalls.value <= 2 ? timedOut : dest
                client.notificationHandler = notificationHandler
                return client
            },
            threadResumeRetryPolicy: CodexThreadResumeRetryPolicy(
                maxAttempts: 2,
                backoffNanoseconds: [],
                perAttemptTimeoutHint: 30
            )
        )
    }
}

private final class AppContextSeedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

private final class AppContextSeedMockClient: CodexAppServerControlling, @unchecked Sendable {
    struct StartedTurn {
        let providerThreadId: String
        let request: AgentRunRequest
    }

    var notificationHandler: CodexAppServerClient.NotificationHandler?
    var terminationHandler: (@Sendable (Error) -> Void)?
    let openThreadError: Error?
    let freshThreadId: String
    private let lock = NSLock()
    private var _startedTurns: [StartedTurn] = []

    init(openThreadError: Error? = nil, freshThreadId: String = "codex-thread-1") {
        self.openThreadError = openThreadError
        self.freshThreadId = freshThreadId
    }

    var startedTurns: [StartedTurn] { lock.withLock { _startedTurns } }

    func initialize(clientName: String, clientTitle: String, clientVersion: String) async throws -> CodexAppServerInitializeResult {
        CodexAppServerInitializeResult(userAgent: "mock", codexHome: nil, platformFamily: nil, platformOs: nil)
    }

    func openThread(for request: AgentRunRequest) async throws -> CodexAppServerThreadOpenResult {
        if let openThreadError { throw openThreadError }
        let providerThreadId = request.providerThreadId?.isEmpty == false ? request.providerThreadId! : freshThreadId
        return CodexAppServerThreadOpenResult(providerThreadId: providerThreadId, response: ["id": providerThreadId])
    }

    func startTurn(providerThreadId: String, for request: AgentRunRequest) async throws -> CodexAppServerClient.JSONObject {
        lock.lock(); _startedTurns.append(StartedTurn(providerThreadId: providerThreadId, request: request)); lock.unlock()
        return ["turn": ["id": "turn-app-server-1"]]
    }

    func interruptTurn(providerThreadId: String, turnId: String) async throws {}
    func readThread(providerThreadId: String, includeTurns: Bool) async throws -> CodexAppServerClient.JSONObject {
        ["thread": ["id": providerThreadId, "turns": []]]
    }
    func forkThread(providerThreadId: String, lastTurnId: String?) async throws -> String { "child" }
    func rollbackThread(providerThreadId: String, beforeTurnId: String) async throws -> CodexAppServerClient.JSONObject {
        ["thread": ["id": providerThreadId]]
    }
    func updateThreadSettings(providerThreadId: String, permissionMode: AgentPermissionMode) async throws {}
    func stop() {}
}
