import XCTest
@testable import AppShell
@testable import AgentRuntime
import CoreModel
import Persistence

/// WHY: exact-counter installation must also own context-seed preparation.
/// Leaving the Codex adapter on Human-only after C11 request wiring would
/// make resume-fallback ignore the same exact bound the request path uses.
@MainActor
final class TokenSaverContextSeedAppContextTests: XCTestCase {
    func test_installingExactCapabilityWiresContextSeedPreparer() throws {
        let context = try makeContext()
        defer { cleanup(context) }

        XCTAssertNotNil(context.coordinator.tokenSaverContextSeedPreparer)
        XCTAssertTrue(context.installTokenSaverExactRuntimeCapability(try XCTUnwrap(exactCapability())))
        XCTAssertTrue(context.coordinator.tokenSaverContextSeedPreparer is TokenSaverExactContextSeedPreparer)
    }

    func test_requestSelectorRemainsInstalledIndependently() throws {
        let context = try makeContext()
        defer { cleanup(context) }
        XCTAssertTrue(context.installTokenSaverExactRuntimeCapability(try XCTUnwrap(exactCapability())))
        XCTAssertNotNil(context.coordinator.tokenSaverOutboundSelector)
        XCTAssertNotNil(context.coordinator.tokenSaverContextSeedPreparer)
    }

    func test_settingsReplacementKeepsExactSeedHooksAndPersistsDeliveredReceipts() async throws {
        // WHY: Settings CLI-path commit used to swap a bare Codex adapter into
        // the coordinator, so later fresh-fallback seeds lost exact selection
        // and durable receipts.
        let context = try makeContext()
        defer { cleanup(context) }
        XCTAssertTrue(context.installTokenSaverExactRuntimeCapability(try XCTUnwrap(exactCapability())))
        XCTAssertNotNil(context.coordinator.tokenSaverOutboundSelector)

        let settings = SettingsViewModel(context: context)
        settings.setCodexPath("/tmp/rc-ctx-codex-" + UUID().uuidString, committed: true)

        let dest = AppContextSeedMockClient(freshThreadId: "settings-dest")
        let adapter = fallbackAdapter(dest: dest)
        context.replaceCodexProviderAdapter(adapter)
        XCTAssertTrue(adapter.contextSeedPreparer is TokenSaverExactContextSeedPreparer)
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
        XCTAssertNotNil(context.coordinator.tokenSaverOutboundSelector)
    }

    func test_exactCapabilityWithCompactSpanLaneDefaultDoesNotEmitRCS1ContextSeed() async throws {
        // WHY: request-path RCS1 already honors the compact-span kill switch.
        // Context-seed projection used to hardcode capability=1, so a cheaper
        // RCS1 arm could still win and be written into RCSEED1 while the
        // production-default lane is disabled.
        let context = try makeContext()
        defer { cleanup(context) }
        XCTAssertTrue(
            TokenSaverLaneKillSwitch.isDisabled(
                "compact-span",
                environment: ProcessInfo.processInfo.environment,
                cliState: TokenSaverLaneKillSwitch.loadCLIStateOverlay(from: distillCLIStateURL(in: context))
            ),
            "compact-span stays disabled unless opted in"
        )
        XCTAssertFalse(TokenSaverLaneKillSwitch.knownStableLanes.contains("compact-span"))
        XCTAssertTrue(context.installTokenSaverExactRuntimeCapability(try XCTUnwrap(rcs1CheaperExactCapability())))

        let prepared = try await prepareSeed(in: context)
        let assistant = try XCTUnwrap(prepared.document.items.first(where: { $0.role == .assistant }))
        XCTAssertNotEqual(assistant.format, .rcs1)
        XCTAssertEqual(assistant.payload, repeatingHuman)
        XCTAssertNil(RemoteCodeCompactSpan.decode(assistant.payload))
        XCTAssertFalse(prepared.encoded.contains("\trcs1\t"))
        let receipt = try XCTUnwrap(prepared.receipts.first(where: { $0.winner.role == .assistant }))
        XCTAssertNotEqual(receipt.winner.selectedFormat, .rcs1)
        let rcs1 = try XCTUnwrap(receipt.arm(.rcs1))
        XCTAssertFalse(rcs1.eligible)
        XCTAssertEqual(rcs1.producerId, TokenSaverRequestSelectionReceipt.rcs1UnavailableProducerID)
    }

    func test_exactCapabilityWithCompactSpanLaneEnabledLetsRCS1WinContextSeed() async throws {
        // WHY: the same lane admission that blocks default RCS1 must still
        // let an explicit compact-span opt-in compete under best-of-three.
        let context = try makeContext()
        defer { cleanup(context) }
        try enableCompactSpan(in: context)
        XCTAssertTrue(context.installTokenSaverExactRuntimeCapability(try XCTUnwrap(rcs1CheaperExactCapability())))

        let prepared = try await prepareSeed(in: context)
        let assistant = try XCTUnwrap(prepared.document.items.first(where: { $0.role == .assistant }))
        XCTAssertEqual(assistant.format, .rcs1)
        XCTAssertEqual(RemoteCodeCompactSpan.decode(assistant.payload), repeatingHuman)
        let receipt = try XCTUnwrap(prepared.receipts.first(where: { $0.winner.role == .assistant }))
        XCTAssertEqual(receipt.winner.selectedFormat, .rcs1)
        let rcs1 = try XCTUnwrap(receipt.arm(.rcs1))
        XCTAssertTrue(rcs1.eligible)
        XCTAssertEqual(rcs1.producerId, TokenSaverRequestSelectionReceipt.rcs1ProducerID)
    }

    private func makeContext() throws -> AppContext {
        let tmp = NSTemporaryDirectory() + "rc-context-seed-app-" + UUID().uuidString
        return try AppContext(channel: .debug, appSupportOverride: tmp)
    }

    private func cleanup(_ context: AppContext) {
        try? FileManager.default.removeItem(atPath: context.appSupportDirectory.path)
    }

    private var repeatingHuman: String {
        String(repeating: "ABCDEFGH", count: 16)
    }

    private func exactCapability() -> TokenSaverExactRuntimeCapability? {
        TokenSaverExactRuntimeCapability.admitted(
            provider: "codex",
            resolvedModel: "test-model",
            counterID: "fixture-counter",
            counterRevision: "1",
            encoding: "fixture-exact",
            quality: .exactLocalTokenizer,
            count: { _ in 10 }
        )
    }

    private func rcs1CheaperExactCapability() -> TokenSaverExactRuntimeCapability? {
        TokenSaverExactRuntimeCapability.admitted(
            provider: "codex",
            resolvedModel: "test-model",
            counterID: "fixture-counter",
            counterRevision: "1",
            encoding: "fixture-exact",
            quality: .exactLocalTokenizer,
            count: { text in
                if text.contains("RCS1/1") || text.contains("REMOTE_CODE_COMPACT_SPAN_V1") {
                    return 12
                }
                return 80
            }
        )
    }

    private func distillCLIStateURL(in context: AppContext) -> URL {
        context.appSupportDirectory
            .appendingPathComponent("Distill", isDirectory: true)
            .appendingPathComponent("DistillCLIState.json")
    }

    private func enableCompactSpan(in context: AppContext) throws {
        let url = distillCLIStateURL(in: context)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing
        }
        var enabled = Set((object["enabled_lanes"] as? [String]) ?? [])
        enabled.insert("compact-span")
        object["enabled_lanes"] = Array(enabled)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
            .write(to: url, options: .atomic)
        XCTAssertFalse(
            TokenSaverLaneKillSwitch.isDisabled(
                "compact-span",
                environment: ProcessInfo.processInfo.environment,
                cliState: TokenSaverLaneKillSwitch.loadCLIStateOverlay(from: url)
            ),
            "compact-span must be opted in through the CLI state seam"
        )
    }

    private func prepareSeed(in context: AppContext) async throws -> TokenSaverPreparedContextSeed {
        let preparer = try XCTUnwrap(context.coordinator.tokenSaverContextSeedPreparer)
        let threadId = AgentThreadID()
        let snapshot = try XCTUnwrap(TokenSaverCanonicalConversationSnapshot.capture(
            messages: [
                AgentMessage(threadId: threadId, role: .user, content: "prior user"),
                AgentMessage(threadId: threadId, role: .assistant, content: repeatingHuman),
            ],
            persistedRCW1ByMessageId: [:],
            excludingCurrentUserText: "unused"
        ))
        let request = AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "test-model",
            cwd: context.appSupportDirectory.path,
            prompt: "current prompt"
        )
        let prepared = await preparer.prepare(
            snapshot: snapshot,
            request: request,
            destinationProviderThreadId: "dest-thread"
        )
        return try XCTUnwrap(prepared)
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
