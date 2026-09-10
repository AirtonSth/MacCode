import XCTest
@testable import AgentRuntime
import CoreModel
import CryptoKit
import Persistence

/// Provider runner that records the exact prompt it was handed, so we can prove
/// the Token Saver compression hook transforms the *outbound* prompt while the
/// *displayed* user message stays the original.
private final class PromptCapturingRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private var _captured: String?
    private var _capturedEnvironment: [String: String] = [:]
    /// At most one waiter; taken under lock so resume runs at most once.
    private var _promptWaiter: CheckedContinuation<Void, Never>?

    init(provider: AgentProvider = .codex) { self.provider = provider }

    var capturedPrompt: String? {
        lock.lock(); defer { lock.unlock() }
        return _captured
    }

    var capturedEnvironment: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return _capturedEnvironment
    }

    /// Suspend until `startRun` has stored a prompt. Race-safe whether capture
    /// happens before or after this call; never resumes a continuation twice.
    func waitForPromptCapture() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if _captured != nil {
                lock.unlock()
                continuation.resume()
                return
            }
            precondition(_promptWaiter == nil, "PromptCapturingRunner supports a single prompt waiter")
            _promptWaiter = continuation
            lock.unlock()
        }
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        lock.lock()
        _captured = request.prompt
        _capturedEnvironment = request.environment
        let waiter = _promptWaiter
        _promptWaiter = nil
        lock.unlock()
        waiter?.resume()
        let handle = AgentRunHandle(runId: request.runId, process: nil) {}
        let tid = request.providerThreadId ?? UUID().uuidString
        Task.detached {
            onEvent(.status(.running))
            onEvent(.event(.threadStarted(threadId: tid, providerThreadId: tid)))
            onEvent(.finished(.completed, finalMessage: "done", providerThreadId: tid))
        }
        return handle
    }
}

private final class ScriptedFinalRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    let finalMessage: String

    init(provider: AgentProvider, finalMessage: String) {
        self.provider = provider
        self.finalMessage = finalMessage
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let handle = AgentRunHandle(runId: request.runId, process: nil) {}
        let finalMessage = self.finalMessage
        Task.detached {
            try? await Task.sleep(nanoseconds: 20_000_000)
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            let turnId = "turn-final-\(request.runId.value.uuidString)"
            let itemId = "assistant-final-\(request.runId.value.uuidString)"
            onEvent(.status(.running))
            onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            onEvent(.event(.turnStarted(turnId: turnId)))
            onEvent(.event(.itemStarted(item: AssistantItem(id: itemId, turnId: turnId, type: .assistantMessage, startedAtMs: 0))))
            onEvent(.event(.itemDelta(itemId: itemId, bodyAppend: finalMessage, outputAppend: nil, summary: nil)))
            onEvent(.event(.itemCompleted(itemId: itemId, finalState: .completed)))
            onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: finalMessage)))
            onEvent(.finished(.completed, finalMessage: finalMessage, providerThreadId: providerThreadId))
        }
        return handle
    }
}

private final class ScriptedStreamRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    let itemType: AssistantItemType
    let bodyChunks: [String]
    let output: String?
    let finalMessage: String

    init(
        provider: AgentProvider,
        itemType: AssistantItemType = .assistantMessage,
        body: String,
        output: String? = nil,
        finalMessage: String = "done"
    ) {
        self.provider = provider
        self.itemType = itemType
        self.bodyChunks = body.isEmpty ? [] : [body]
        self.output = output
        self.finalMessage = finalMessage
    }

    init(provider: AgentProvider, bodyChunks: [String], finalMessage: String = "done") {
        self.provider = provider
        self.itemType = .assistantMessage
        self.bodyChunks = bodyChunks
        self.output = nil
        self.finalMessage = finalMessage
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let handle = AgentRunHandle(runId: request.runId, process: nil) {}
        let providerThreadId = request.providerThreadId ?? UUID().uuidString
        let itemType = self.itemType
        let bodyChunks = self.bodyChunks
        let output = self.output
        let finalMessage = self.finalMessage
        Task.detached {
            let turnId = "turn-stream"
            let itemId = "stream-item"
            onEvent(.status(.running))
            onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            onEvent(.event(.turnStarted(turnId: turnId)))
            onEvent(.event(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: turnId,
                type: itemType,
                startedAtMs: 0
            ))))
            for chunk in bodyChunks {
                onEvent(.event(.itemDelta(itemId: itemId, bodyAppend: chunk, outputAppend: nil, summary: nil)))
            }
            if let output {
                onEvent(.event(.itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: output, summary: "Reasoning")))
            }
            onEvent(.event(.itemCompleted(itemId: itemId, finalState: .completed)))
            onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: finalMessage)))
            onEvent(.finished(.completed, finalMessage: finalMessage, providerThreadId: providerThreadId))
        }
        return handle
    }
}

private final class RecordingObserver: AgentRunObserver {
    private let lock = NSLock()
    private var events: [AssistantEvent] = []

    var recordedEvents: [AssistantEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func runCoordinator(_ c: AgentRunCoordinator, didReceive event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func runCoordinator(_ c: AgentRunCoordinator, didFinish runId: AgentRunID, threadId: AgentThreadID, status: AgentRunStatus, finalMessage: String?, providerThreadId: String?) {}

    func runCoordinator(_ c: AgentRunCoordinator, didChangeStatus status: AgentRunStatus, runId: AgentRunID, threadId: AgentThreadID) {}
}

private final class UserInputCapturingAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private(set) var capturedUserInput: (threadId: AgentThreadID, requestId: String, verbatimText: String, outboundText: String)?

    init(provider: AgentProvider = .claude) {
        self.provider = provider
    }

    func listModels() async -> [AgentModelDescriptor] { [] }
    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }
    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func interruptTurn(threadId: AgentThreadID) throws {}
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {}
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        try respondToUserInput(threadId: threadId, requestId: requestId, verbatimText: text, outboundText: text)
    }
    func respondToUserInput(threadId: AgentThreadID, requestId: String, verbatimText: String, outboundText: String) throws {
        lock.lock()
        capturedUserInput = (threadId, requestId, verbatimText, outboundText)
        lock.unlock()
    }
    func stopSession(threadId: AgentThreadID) throws {}
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] { [] }
    func hasSession(threadId: AgentThreadID) -> Bool { true }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}
}

private enum PromptAcceptanceMode { case accepted, notAccepted, unknown }
private struct SimulatedPromptWriteError: Error {}
private let rcw1Cap = TokenSaverExecutionReceiptSeam.wireCapabilityEnvKey
private let rcw1Ver = "RC_TOKEN_SAVER_WIRE_VERSION"

private final class PromptCapturingAcceptanceAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider
    let acceptanceMode: PromptAcceptanceMode
    private let lock = NSLock()
    private var _request: AgentRunRequest?

    init(provider: AgentProvider = .codex, acceptanceMode: PromptAcceptanceMode = .accepted) {
        self.provider = provider
        self.acceptanceMode = acceptanceMode
    }

    var request: AgentRunRequest? { lock.withLock { _request } }
    func listModels() async -> [AgentModelDescriptor] { [] }
    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }
    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let capture = { self.lock.withLock { self._request = request } }
        switch (acceptanceMode, request.acceptancePermit) {
        case (.accepted, let permit?):
            try permit.withAcceptance(capture)
        case (.unknown, let permit?):
            do {
                try permit.withAcceptance {
                    capture()
                    throw SimulatedPromptWriteError()
                }
            } catch is SimulatedPromptWriteError {}
        case (.accepted, nil), (.notAccepted, _), (.unknown, nil):
            capture()
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func interruptTurn(threadId: AgentThreadID) throws {}
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {}
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {}
    func stopSession(threadId: AgentThreadID) throws {}
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] { [] }
    func hasSession(threadId: AgentThreadID) -> Bool { false }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}
}

private final class Best3Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveries: [TokenSaverOutboundDelivery] = []
    private var selections: [TokenSaverOutboundSelectionRequest] = []
    var events: [TokenSaverOutboundDelivery] { lock.withLock { deliveries } }
    var requests: [TokenSaverOutboundSelectionRequest] { lock.withLock { selections } }
    func record(_ event: TokenSaverOutboundDelivery) { lock.withLock { deliveries.append(event) } }
    func record(_ request: TokenSaverOutboundSelectionRequest) { lock.withLock { selections.append(request) } }
}

private struct Best3Harness {
    let tmp: String
    let messageRepo: AgentMessageRepository
    let sessionRepo: ProviderSessionRuntimeRepository
    let coordinator: AgentRunCoordinator
    let adapter: PromptCapturingAcceptanceAdapter
    let recorder: Best3Recorder
    let observer: RecordingObserver
    let thread: AgentThread

    static func make(title: String, acceptanceMode: PromptAcceptanceMode = .accepted) throws -> Best3Harness {
        let tmp = NSTemporaryDirectory() + "rc2-ts-best3-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let thread = AgentThread(title: title, provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let adapter = PromptCapturingAcceptanceAdapter(acceptanceMode: acceptanceMode)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providerSessionRepo: sessionRepo, providerAdapters: [.codex: adapter]
        )
        let observer = RecordingObserver()
        coordinator.addObserver(observer)
        return Best3Harness(
            tmp: tmp, messageRepo: messageRepo, sessionRepo: sessionRepo,
            coordinator: coordinator, adapter: adapter, recorder: Best3Recorder(),
            observer: observer, thread: thread
        )
    }

    func injectScopedRCW1() {
        coordinator.runEnvironmentProvider = { _, _, base in
            var env = base
            env[rcw1Cap] = "1"
            env[rcw1Ver] = "1"
            return env
        }
    }

    func injectReceiptBearingEnvironment(
        calls: CallLog,
        staleRoot: String = "11111111-1111-1111-1111-111111111111",
        staleAttempt: String = "22222222-2222-2222-2222-222222222222"
    ) {
        coordinator.runEnvironmentProvider = { provider, threadId, base in
            calls.add("environment")
            let receipt = TokenSaverExecutionReceiptSeam.admit(
                tokenSaverEnabled: true,
                sameUser: true,
                sidecarAvailable: true,
                provider: provider,
                threadId: threadId.value.uuidString,
                rootRunId: staleRoot,
                attemptId: staleAttempt,
                workspaceId: "20000000-0000-0000-0000-000000000002",
                projectId: "30000000-0000-0000-0000-000000000003"
            )
            var env = base
            env.merge(TokenSaverExecutionReceiptSeam.environment(from: receipt)) { _, next in next }
            env[rcw1Ver] = "1"
            return env
        }
    }

    func select(_ body: @escaping @Sendable (TokenSaverOutboundSelectionRequest) async -> TokenSaverBestOfThreeSelector.Decision) {
        let recorder = self.recorder
        coordinator.tokenSaverOutboundSelector = { request in
            recorder.record(request)
            return await body(request)
        }
        coordinator.onTokenSaverOutboundDelivery = { recorder.record($0) }
    }

    func start(_ prompt: String, runID: AgentRunID = AgentRunID()) async throws -> AgentRunID {
        _ = try await coordinator.startRun(.init(
            runId: runID, threadId: thread.id, provider: .codex,
            model: "fake-model", cwd: tmp, prompt: prompt
        ))
        return runID
    }

    func sessionWireVersion() throws -> String? {
        guard let json = try sessionRepo.get(threadId: thread.id)?.runtimePayloadJSON,
              let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["wireProtocolVersion"] as? String
    }
}

private func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func assertUnboundHumanFallback(
    harness: Best3Harness,
    arms: Best3Arms,
    runID: AgentRunID,
    reason: TokenSaverBestOfThreeSelector.Reason = .candidateError
) throws {
    let sent = try XCTUnwrap(harness.adapter.request?.prompt)
    let receipt = try XCTUnwrap(harness.recorder.events.first?.receipt)
    XCTAssertEqual(sent, arms.human)
    XCTAssertEqual(
        try harness.messageRepo.get(id: AgentMessageID(runID.value))?.content,
        arms.human
    )
    XCTAssertTrue(
        try harness.messageRepo.rcw1RequestTranslations(
            threadId: harness.thread.id, messageIds: [AgentMessageID(runID.value)]
        ).isEmpty
    )
    XCTAssertFalse(harness.observer.recordedEvents.contains {
        if case .wireTranslation = $0 { return true }
        return false
    })
    XCTAssertNil(try harness.sessionWireVersion())
    XCTAssertNil(harness.adapter.request?.environment[rcw1Cap])
    XCTAssertNil(harness.adapter.request?.environment[rcw1Ver])
    XCTAssertEqual(receipt.selectedFormat, .human)
    XCTAssertEqual(receipt.reason, reason)
    XCTAssertEqual(receipt.modeledContextDelta, 0)
    XCTAssertEqual(receipt.sourceSHA256, sha256Hex(arms.human))
    XCTAssertTrue(receipt.costs.isEmpty)
    XCTAssertTrue(receipt.arms.isEmpty)
    XCTAssertNil(receipt.counter)
    XCTAssertFalse(receipt.billingClaim)
}

private func validRCS1Decision(
    human: String,
    item: String,
    request: TokenSaverOutboundSelectionRequest
) async -> TokenSaverBestOfThreeSelector.Decision {
    let rcwPayload = "RCW1\tQ\t1\nG\tRuntime request\nX\t[[rc:rcv1.runtime]]\n.\n"
    let rcwABI = "RCW1 ABI"
    let rcs1Env = request.environment(for: .rcs1)
    let rcs1ABI = AgentSkillInstaller.tokenSaverProviderPrompt("", environment: rcs1Env)
    let humanEnv = "BASE ABI\n\(human)"
    let rcwEnv = "\(rcwABI)\n\(rcwPayload)"
    let rcs1Envelope = "\(rcs1ABI)\n\(item)"
    let source = SHA256.hash(data: Data(human.utf8)).map { String(format: "%02x", $0) }.joined()
    let rcw1 = TokenSaverBestOfThreeSelector.Candidate(
        format: .rcw1,
        sourceSHA256: source,
        payload: rcwPayload,
        abi: rcwABI,
        effectiveEnvelope: rcwEnv,
        handle: "rcv1.runtime",
        producerID: "remotecode-rcw1",
        producerRevision: "1",
        abiRevision: "1",
        generation: .passed,
        structural: .passed,
        semantic: .passed,
        recovery: .passed
    )
    let rcs1 = TokenSaverBestOfThreeSelector.Candidate(
        format: .rcs1,
        sourceSHA256: source,
        payload: item,
        abi: rcs1ABI,
        effectiveEnvelope: rcs1Envelope,
        handle: nil,
        producerID: TokenSaverRequestSelectionReceipt.rcs1ProducerID,
        producerRevision: "1",
        abiRevision: "1",
        generation: .passed,
        structural: .passed,
        semantic: .passed,
        recovery: .passed
    )
    let counts = [
        human: 40,
        humanEnv: 110,
        rcwPayload: 20,
        "rcv1.runtime": 4,
        rcwABI: 5,
        rcwEnv: 90,
        item: 8,
        rcs1ABI: 6,
        rcs1Envelope: 20,
    ]
    return await TokenSaverBestOfThreeSelector.select(
        canonicalHuman: human,
        humanOutboundPrompt: human,
        humanEffectiveEnvelope: humanEnv,
        target: .init(
            provider: "codex",
            resolvedModel: "fake-model",
            counterID: "runtime-counter",
            counterRevision: "1",
            encoding: "fixture"
        ),
        candidates: [rcw1, rcs1],
        counter: .init(counter: .init(
            id: "runtime-counter",
            revision: "1",
            encoding: "fixture",
            provider: "codex",
            resolvedModel: "fake-model",
            quality: .exactLocalTokenizer
        )) { text in
            guard let count = counts[text] else { throw NSError(domain: "counter", code: 1) }
            return count
        }
    )
}

private enum Best3Winner { case rcw1, rcs1, human }

private struct Best3Arms {
    let human = "Canonical Human request stays visible."
    let rcwOutbound: String
    let rcs1Outbound: String
    private let rcwHandle = "rcv1.runtime"
    private let rcs1Handle = "rcs1.runtime"

    init(rcs1LooksLikeRCW1: Bool = false) {
        rcwOutbound = "RCW1\tQ\t1\nG\tRuntime request\nX\t[[rc:\(rcwHandle)]]\n.\n"
        rcs1Outbound = rcs1LooksLikeRCW1
            ? "RCW1\tQ\t1\nG\tRCS1 winner must not be RCW1\nX\t[[rc:\(rcs1Handle)]]\n.\n"
            : "RCS1 Runtime request [[rc:\(rcs1Handle)]]"
    }

    func payload(_ winner: Best3Winner) -> String {
        switch winner {
        case .rcw1: rcwOutbound
        case .rcs1: rcs1Outbound
        case .human: human
        }
    }

    var malformedRCW1: String {
        "RCW1\tQ\t1\nG\tRuntime request\nX\t[[rc:\(rcwHandle)]]"
    }

    var responseDirectionRCW1: String {
        "RCW1\tA\t1\nO\tnot a request [[rc:\(rcwHandle)]]\n.\n"
    }

    func decision(
        _ winner: Best3Winner,
        rcwPayload: String? = nil,
        canonicalHuman: String? = nil,
        humanOutboundPrompt: String? = nil,
        provider: String = "codex",
        resolvedModel: String = "fake-model"
    ) async -> TokenSaverBestOfThreeSelector.Decision {
        let human = canonicalHuman ?? self.human
        let humanOutbound = humanOutboundPrompt ?? self.human
        let rcwOutbound = rcwPayload ?? self.rcwOutbound
        let rcwABI = "RCW1 ABI", rcs1ABI = "RCS1 ABI"
        let humanEnv = "BASE ABI\n\(humanOutbound)"
        let rcwEnv = "\(rcwABI)\n\(rcwOutbound)", rcs1Env = "\(rcs1ABI)\n\(rcs1Outbound)"
        let envelopes: (Int, Int, Int) = switch winner {
        case .rcw1: (110, 30, 60)
        case .rcs1: (110, 90, 30)
        case .human: (25, 50, 55)
        }
        let source = SHA256.hash(data: Data(human.utf8)).map { String(format: "%02x", $0) }.joined()
        func arm(_ format: TokenSaverBestOfThreeSelector.Format, payload: String, abi: String, envelope: String, handle: String) -> TokenSaverBestOfThreeSelector.Candidate {
            .init(
                format: format, sourceSHA256: source, payload: payload, abi: abi,
                effectiveEnvelope: envelope, handle: handle,
                producerID: format == .rcw1 ? "remotecode-rcw1" : "remotecode-rcs1",
                producerRevision: "1", abiRevision: "1",
                generation: .passed, structural: .passed, semantic: .passed, recovery: .passed
            )
        }
        let counts = [
            humanOutbound: envelopes.0 - 10, humanEnv: envelopes.0,
            rcwOutbound: 20, rcwHandle: 4, rcwABI: 5, rcwEnv: envelopes.1,
            rcs1Outbound: 20, rcs1Handle: 4, rcs1ABI: 5, rcs1Env: envelopes.2,
        ]
        return await TokenSaverBestOfThreeSelector.select(
            canonicalHuman: human,
            humanOutboundPrompt: humanOutbound,
            humanEffectiveEnvelope: humanEnv,
            target: .init(
                provider: provider,
                resolvedModel: resolvedModel,
                counterID: "runtime-counter",
                counterRevision: "1",
                encoding: "fixture"
            ),
            candidates: [
                arm(.rcw1, payload: rcwOutbound, abi: rcwABI, envelope: rcwEnv, handle: rcwHandle),
                arm(.rcs1, payload: rcs1Outbound, abi: rcs1ABI, envelope: rcs1Env, handle: rcs1Handle),
            ],
            counter: .init(counter: .init(
                id: "runtime-counter", revision: "1", encoding: "fixture",
                provider: provider, resolvedModel: resolvedModel, quality: .exactLocalTokenizer
            )) { text in
                guard let count = counts[text] else { throw NSError(domain: "counter", code: 1) }
                return count
            }
        )
    }

    static func humanFallback(_ human: String) async -> TokenSaverBestOfThreeSelector.Decision {
        await TokenSaverBestOfThreeSelector.select(
            canonicalHuman: human, humanOutboundPrompt: human, humanEffectiveEnvelope: human,
            target: .init(provider: "codex", resolvedModel: "fake-model", counterID: "runtime-counter", counterRevision: "1", encoding: "fixture"),
            candidates: [], counter: nil
        )
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _steps: [String] = []
    var steps: [String] { lock.withLock { _steps } }
    var count: Int { steps.count }
    func add(_ step: String) { lock.withLock { _steps.append(step) } }
}

private final class ScopeRefreshingAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private var sessions: [AgentThreadID: AgentProviderSessionSummary] = [:]
    private(set) var requests: [AgentRunRequest] = []
    private(set) var retiredEnvironments: [[String: String]] = []
    private(set) var stopSessionCalls = 0

    init(provider: AgentProvider) {
        self.provider = provider
    }

    /// Seeds a resident idle session the coordinator can observe via `hasSession`
    /// without a durable provider thread id (the pre-continuity Token Saver case).
    func seedIdleSession(
        threadId: AgentThreadID,
        providerThreadId: String? = nil,
        status: AgentRunStatus = .completed
    ) {
        lock.lock()
        sessions[threadId] = .init(
            threadId: threadId,
            provider: provider,
            status: status,
            providerThreadId: providerThreadId
        )
        lock.unlock()
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startSession(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }

    func sendTurn(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        let providerThreadID = request.providerThreadId ?? "continuity-\(provider.rawValue)"
        lock.lock()
        requests.append(request)
        sessions[request.threadId] = .init(
            threadId: request.threadId,
            provider: provider,
            status: .completed,
            providerThreadId: providerThreadID
        )
        lock.unlock()
        Task.detached {
            onEvent(.event(.threadStarted(threadId: providerThreadID, providerThreadId: providerThreadID)))
            onEvent(.finished(.completed, finalMessage: "done", providerThreadId: providerThreadID))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }

    func interruptTurn(threadId: AgentThreadID) throws {}
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {}
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {}

    func stopSession(threadId: AgentThreadID) throws {
        lock.lock()
        stopSessionCalls += 1
        if let request = requests.last(where: { $0.threadId == threadId }) {
            retiredEnvironments.append(request.environment)
        }
        sessions.removeValue(forKey: threadId)
        lock.unlock()
    }

    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] {
        lock.lock()
        defer { lock.unlock() }
        return Array(sessions.values)
    }
    func hasSession(threadId: AgentThreadID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessions[threadId] != nil
    }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}
}

private extension AssistantEvent {
    var bodyAppendForTest: String? {
        if case .itemDelta(_, let bodyAppend, _, _) = self {
            return bodyAppend
        }
        return nil
    }

    var outputAppendForTest: String? {
        if case .itemDelta(_, _, let outputAppend, _) = self {
            return outputAppend
        }
        return nil
    }

    var turnCompletedFinalMessageForTest: String? {
        if case .turnCompleted(_, let finalMessage) = self {
            return finalMessage
        }
        return nil
    }
}

final class TokenSaverCompressionTests: XCTestCase {
    private func makeCoordinator() throws -> (AgentRunCoordinator, AgentMessageRepository, AgentThread, String, PromptCapturingRunner) {
        let tmp = NSTemporaryDirectory() + "rc2-ts-compress-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "t", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = PromptCapturingRunner(provider: .codex)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        return (coordinator, messageRepo, thread, tmp, runner)
    }

    private func waitForPrompt(_ runner: PromptCapturingRunner) async {
        await runner.waitForPromptCapture()
    }

    private func waitForRun(
        _ runID: AgentRunID,
        in repository: AgentRunRepository
    ) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let run = try repository.get(id: runID), run.status == .completed {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("run did not complete")
    }

    func test_reusedProviderSessionsRefreshExactTurnScopeForClaudeCodexAndGrok() async throws {
        // WHY: a resident provider process cannot mutate its environment. Every
        // Token Saver attempt must launch with the current exact scope while the
        // provider thread id preserves conversation continuity.
        for provider in [AgentProvider.claude, .codex, .grok] {
            let tmp = NSTemporaryDirectory() + "rc2-ts-scope-refresh-" + provider.rawValue + "-" + UUID().uuidString
            let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
            let threadRepo = AgentThreadRepository(db: db)
            let messageRepo = AgentMessageRepository(db: db)
            let runRepo = AgentRunRepository(db: db)
            let thread = AgentThread(title: "scope", provider: provider, model: "test")
            try threadRepo.upsert(thread)
            let adapter = ScopeRefreshingAdapter(provider: provider)
            let coordinator = AgentRunCoordinator(
                runRepo: runRepo,
                messageRepo: messageRepo,
                threadRepo: threadRepo,
                providerAdapters: [provider: adapter]
            )
            coordinator.runEnvironmentProvider = { selectedProvider, selectedThread, _ in
                [
                    "RC_TOKEN_SAVER_DISTILL_HINT": "1",
                    "RC_TOKEN_SAVER_WORKSPACE_ID": "workspace-2",
                    "RC_TOKEN_SAVER_PROJECT_ID": "project-2",
                    "RC_TOKEN_SAVER_THREAD_ID": selectedThread.value.uuidString,
                    "REMOTE_CODE_AGENT_PROVIDER": selectedProvider.rawValue,
                ]
            }
            coordinator.promptCompressor = { prompt, _, _, _ in
                guard prompt == "first" else { return prompt }
                return "RCW1\tQ\t1\nG\tfirst\n.\n"
            }

            let firstRunID = AgentRunID()
            _ = try await coordinator.startRun(.init(
                runId: firstRunID,
                threadId: thread.id,
                provider: provider,
                model: "test",
                cwd: tmp,
                prompt: "first"
            ))
            try await waitForRun(firstRunID, in: runRepo)

            let continuedThread = try XCTUnwrap(try threadRepo.get(id: thread.id))
            let providerThreadID = try XCTUnwrap(continuedThread.providerThreadId)
            let secondRunID = AgentRunID()
            _ = try await coordinator.startRun(.init(
                runId: secondRunID,
                threadId: thread.id,
                provider: provider,
                model: "test",
                cwd: tmp,
                prompt: "second",
                providerThreadId: providerThreadID
            ))
            try await waitForRun(secondRunID, in: runRepo)

            XCTAssertEqual(adapter.requests.count, 2, "\(provider.rawValue) must execute both turns")
            XCTAssertEqual(adapter.requests[0].environment["RC_TOKEN_SAVER_WIRE_VERSION"], "1",
                           "\(provider.rawValue) must atomically admit RCW1 for the encoded turn")
            XCTAssertNil(adapter.requests[1].environment["RC_TOKEN_SAVER_WIRE_VERSION"],
                         "\(provider.rawValue) must explicitly reset wire admission when the next turn bypasses encoding")
            XCTAssertTrue(RCWireProtocol.isWire(adapter.requests[0].prompt))
            XCTAssertEqual(adapter.requests[1].prompt, "second")
            let firstEnvironment = adapter.requests[0].environment
            let secondEnvironment = adapter.requests[1].environment
            XCTAssertEqual(firstEnvironment["RC_TOKEN_SAVER_ATTEMPT_ID"], firstRunID.value.uuidString)
            XCTAssertEqual(secondEnvironment["RC_TOKEN_SAVER_ATTEMPT_ID"], secondRunID.value.uuidString)
            XCTAssertNotEqual(firstEnvironment["RC_TOKEN_SAVER_ATTEMPT_ID"], secondEnvironment["RC_TOKEN_SAVER_ATTEMPT_ID"])
            XCTAssertEqual(adapter.retiredEnvironments, [firstEnvironment], "\(provider.rawValue) must deny reuse of the run-1 process scope")
            XCTAssertEqual(adapter.requests[1].providerThreadId, providerThreadID, "\(provider.rawValue) must preserve provider conversation continuity")
        }
    }

    func test_reusedProviderSessionsRefreshWhenBotSecretsChangeButReuseWhenUnchanged() async throws {
        for provider in [AgentProvider.claude, .codex, .grok] {
            let tmp = NSTemporaryDirectory() + "rc2-bot-secret-scope-" + provider.rawValue + "-" + UUID().uuidString
            let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
            let threadRepo = AgentThreadRepository(db: db)
            let messageRepo = AgentMessageRepository(db: db)
            let runRepo = AgentRunRepository(db: db)
            let thread = AgentThread(title: "bot secrets", provider: provider, model: "test")
            try threadRepo.upsert(thread)
            let adapter = ScopeRefreshingAdapter(provider: provider)
            let botID = BotID(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!)
            let secretStore = InMemoryBotSecretStore()
            let coordinator = AgentRunCoordinator(
                runRepo: runRepo,
                messageRepo: messageRepo,
                threadRepo: threadRepo,
                providerAdapters: [provider: adapter],
                botSecretStore: secretStore
            )
            let scope = BotSecretScopeTestState(botID: botID)
            coordinator.runEnvironmentProvider = { selectedProvider, selectedThread, _ in
                scope.environment(provider: selectedProvider, threadId: selectedThread)
            }

            func runTurn(_ prompt: String, providerThreadId: String? = nil) async throws {
                let runID = AgentRunID()
                _ = try await coordinator.startRun(.init(
                    runId: runID,
                    threadId: thread.id,
                    provider: provider,
                    model: "test",
                    cwd: tmp,
                    prompt: prompt,
                    providerThreadId: providerThreadId
                ))
                try await waitForRun(runID, in: runRepo)
            }

            try secretStore.save(botID: botID, name: "SERVICE_TOKEN", value: "one")
            try await runTurn("first")
            let providerThreadID = try XCTUnwrap(try threadRepo.get(id: thread.id)?.providerThreadId)

            try await runTurn("unchanged", providerThreadId: providerThreadID)
            XCTAssertEqual(adapter.stopSessionCalls, 0, "\(provider.rawValue) must reuse an unchanged secret scope")

            try secretStore.save(botID: botID, name: "SERVICE_TOKEN", value: "two")
            try await runTurn("updated", providerThreadId: providerThreadID)
            XCTAssertEqual(adapter.stopSessionCalls, 1, "\(provider.rawValue) must refresh after a secret update")

            try await runTurn("updated again", providerThreadId: providerThreadID)
            XCTAssertEqual(adapter.stopSessionCalls, 1, "\(provider.rawValue) must reuse an unchanged updated secret")

            try secretStore.delete(botID: botID, name: "SERVICE_TOKEN")
            try await runTurn("removed", providerThreadId: providerThreadID)
            XCTAssertEqual(adapter.stopSessionCalls, 2, "\(provider.rawValue) must refresh after a secret removal")

            try await runTurn("still removed", providerThreadId: providerThreadID)
            XCTAssertEqual(adapter.stopSessionCalls, 2, "\(provider.rawValue) must reuse an unchanged empty secret scope")
        }
    }

    func test_startRunFailsClosedOnProtectedSecretStorageFailureBeforeProviderAdmission() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-bot-secret-failure-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "secret failure", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = PromptCapturingRunner(provider: .codex)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner],
            botSecretStore: FailingBotSecretStore()
        )
        let admission = CallLog()
        coordinator.providerAdmissionCheck = { _, _ in admission.add("admission") }

        do {
            _ = try await coordinator.startRun(.init(
                threadId: thread.id,
                provider: .codex,
                model: "fake-model",
                cwd: tmp,
                prompt: "must not start",
                environment: [
                    BotSecretEnvironment.botIDEnvironmentKey:
                        "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
                ]
            ))
            XCTFail("secret storage failure must reject run admission")
        } catch {
            XCTAssertEqual(String(describing: error), "Protected secret storage is unavailable.")
        }
        XCTAssertTrue(admission.steps.isEmpty)
        XCTAssertNil(runner.capturedPrompt)
    }

    func test_startRun_refusesStaleTokenSaverScopeWhenLiveSessionLacksDurableProviderThreadId() async throws {
        // WHY: provider process env is immutable after launch. A live adapter
        // session with no durable providerThreadId has no safe resume handle, so
        // a new Token Saver admission scope cannot reuse that process (wrong
        // workspace/project/attempt isolation) and also cannot stop+restart it
        // without losing continuity. Refuse the run instead of silently reusing
        // or incorrectly tearing down the stale session.
        let tmp = NSTemporaryDirectory() + "rc2-ts-scope-refuse-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "stale-scope", provider: .claude, model: "test")
        try threadRepo.upsert(thread)

        let adapter = ScopeRefreshingAdapter(provider: .claude)
        // Live idle session, no durable provider continuity id, no prior coordinator scope.
        adapter.seedIdleSession(threadId: thread.id, providerThreadId: nil, status: .completed)
        XCTAssertTrue(adapter.hasSession(threadId: thread.id))

        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerAdapters: [.claude: adapter]
        )
        coordinator.runEnvironmentProvider = { selectedProvider, selectedThread, _ in
            [
                "RC_TOKEN_SAVER_DISTILL_HINT": "1",
                "RC_TOKEN_SAVER_WORKSPACE_ID": "workspace-new",
                "RC_TOKEN_SAVER_PROJECT_ID": "project-new",
                "RC_TOKEN_SAVER_THREAD_ID": selectedThread.value.uuidString,
                "REMOTE_CODE_AGENT_PROVIDER": selectedProvider.rawValue,
            ]
        }

        let safetyMessage =
            "Provider process scope changed before a durable provider thread id was available; refusing to reuse stale Token Saver scope."

        do {
            _ = try await coordinator.startRun(.init(
                threadId: thread.id,
                provider: .claude,
                model: "test",
                cwd: tmp,
                prompt: "must not reuse stale scope",
                providerThreadId: nil
            ))
            XCTFail("startRun must refuse when Token Saver scope arrives against a live session without durable providerThreadId")
        } catch let error as AgentProviderAdapterError {
            guard case .unsupported(let detail) = error else {
                return XCTFail("expected .unsupported safety refusal, got \(error)")
            }
            XCTAssertEqual(detail, safetyMessage,
                           "refusal must carry the exact stale Token Saver scope safety intent")
        }

        XCTAssertTrue(adapter.hasSession(threadId: thread.id),
                      "refusal must leave the resident session in place — stopping without a resume handle drops continuity incorrectly")
        XCTAssertEqual(adapter.stopSessionCalls, 0,
                       "must not stopSession on scope refusal without a durable providerThreadId")
        XCTAssertTrue(adapter.requests.isEmpty,
                      "must not reuse the stale live session by sending a turn under the new Token Saver scope")
        XCTAssertTrue(adapter.retiredEnvironments.isEmpty)
        XCTAssertNil(try threadRepo.get(id: thread.id)?.providerThreadId,
                     "coordinator must not invent a providerThreadId when continuity was never established")
    }

    /// WHY: legacy hosts keep compressor-then-env. Env-first is a regression.
    func test_legacyCompressorRunsBeforeEnvironmentProvider() async throws {
        let (coordinator, _, thread, tmp, runner) = try makeCoordinator()
        let order = CallLog()
        coordinator.promptCompressor = { prompt, _, _, _ in
            order.add("compressor")
            return "RCW1\tQ\t1\nG\t\(prompt)\n.\n"
        }
        coordinator.runEnvironmentProvider = { _, _, base in
            order.add("environment")
            var env = base
            env[rcw1Cap] = "1"
            return env
        }
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model",
            cwd: tmp, prompt: "legacy order"
        ))
        await waitForPrompt(runner)
        XCTAssertEqual(order.steps, ["compressor", "environment"])
        XCTAssertEqual(runner.capturedEnvironment[rcw1Cap], "1")
        XCTAssertEqual(runner.capturedEnvironment[rcw1Ver], "1")
        XCTAssertTrue(RCWireProtocol.isWire(runner.capturedPrompt ?? ""))
    }

    /// WHY: typed RCW1 is valid only with capability=1 and a structural all-Q
    /// request. Missing ABI, malformed frames, or A-direction must send Human.
    func test_typedRCW1DecisionFailsClosedWithoutCapabilityOrValidAllQRequest() async throws {
        enum Case { case missingCapability, malformed, responseDirection }
        for item in [Case.missingCapability, .malformed, .responseDirection] {
            let harness = try Best3Harness.make(title: "best3 fail-closed \(item)")
            let arms = Best3Arms()
            if item != .missingCapability {
                harness.injectScopedRCW1()
            }
            let selectedPayload: String = switch item {
            case .missingCapability: arms.rcwOutbound
            case .malformed: arms.malformedRCW1
            case .responseDirection: arms.responseDirectionRCW1
            }
            harness.select { request in
                if item == .missingCapability {
                    XCTAssertNil(request.admittedEnvironment[rcw1Cap])
                    XCTAssertNil(request.environment(for: .rcw1)[rcw1Cap])
                    XCTAssertNil(request.environment(for: .rcw1)[rcw1Ver])
                } else {
                    XCTAssertEqual(request.environment(for: .rcw1)[rcw1Cap], "1")
                    XCTAssertEqual(request.environment(for: .rcw1)[rcw1Ver], "1")
                }
                return await arms.decision(.rcw1, rcwPayload: selectedPayload)
            }
            let runID: AgentRunID
            do {
                runID = try await harness.start(arms.human)
            } catch {
                XCTFail("\(item) must fail closed to Human without throwing: \(error)")
                continue
            }
            let env = harness.adapter.request?.environment ?? [:]
            XCTAssertEqual(
                harness.adapter.request?.prompt,
                arms.human,
                "\(item) must send the Auto-shaped Human outbound, not RCW1"
            )
            XCTAssertEqual(
                try harness.messageRepo.get(id: AgentMessageID(runID.value))?.content,
                arms.human,
                "\(item) displayed user message stays canonical Human"
            )
            XCTAssertTrue(
                try harness.messageRepo.rcw1RequestTranslations(
                    threadId: harness.thread.id, messageIds: [AgentMessageID(runID.value)]
                ).isEmpty,
                "\(item) must not persist RCW1 disclosure"
            )
            XCTAssertFalse(harness.observer.recordedEvents.contains {
                if case .wireTranslation = $0 { return true }
                return false
            }, "\(item) must not emit a wire translation event")
            XCTAssertNil(try harness.sessionWireVersion(),
                         "\(item) must not persist RCW1 session metadata")
            XCTAssertNil(env[rcw1Cap], "\(item) Human fallback cannot inherit RCW1 capability")
            XCTAssertNil(env[rcw1Ver], "\(item) Human fallback cannot inherit RCW1 version")
            XCTAssertEqual(harness.recorder.events.count, 1)
            XCTAssertEqual(harness.recorder.events.first?.receipt.selectedFormat, .human)
            XCTAssertEqual(harness.recorder.events.first?.receipt.reason, .candidateError)
            XCTAssertEqual(harness.recorder.events.first?.receipt.modeledContextDelta, 0)
            XCTAssertFalse(harness.recorder.events.first?.receipt.billingClaim ?? true)
            XCTAssertEqual(harness.recorder.events.first?.outcome, .accepted)
        }
    }

    /// WHY: a structurally valid, capability-present RCW1 Decision bound to
    /// another canonical Human must not send those bytes or persist its costs.
    func test_staleSourceSHAWithValidCapableRCW1SendsHumanAndDropsEvidence() async throws {
        let harness = try Best3Harness.make(title: "c7 stale source rcw1")
        let arms = Best3Arms()
        harness.injectScopedRCW1()
        harness.select { _ in
            await arms.decision(
                .rcw1,
                canonicalHuman: "stale canonical Human from another turn",
                humanOutboundPrompt: "stale canonical Human from another turn"
            )
        }
        let runID = try await harness.start(arms.human)
        try assertUnboundHumanFallback(harness: harness, arms: arms, runID: runID)
    }

    /// WHY: a valid RCS1 winner whose Human Cost hashes a different Auto
    /// outbound must fail closed before send and drop the unbound evidence.
    func test_staleHumanOutboundSHAWithValidRCS1SendsHumanAndDropsEvidence() async throws {
        let harness = try Best3Harness.make(title: "c7 stale human outbound rcs1")
        let arms = Best3Arms()
        harness.injectScopedRCW1()
        harness.select { _ in
            await arms.decision(
                .rcs1,
                humanOutboundPrompt: "AUTO HUMAN: \(arms.human)"
            )
        }
        let runID = try await harness.start(arms.human)
        try assertUnboundHumanFallback(harness: harness, arms: arms, runID: runID)
    }

    /// WHY: content hashes are not a tokenizer identity. A valid, capable RCW1
    /// Decision ranked for another provider must not ride identical bytes onto
    /// the current target or persist that other tokenizer's costs.
    func test_staleCounterProviderWithValidCapableRCW1SendsHumanAndDropsEvidence() async throws {
        let harness = try Best3Harness.make(title: "c7 stale counter provider rcw1")
        let arms = Best3Arms()
        harness.injectScopedRCW1()
        harness.select { request in
            XCTAssertEqual(request.admittedRequest.provider, .codex)
            XCTAssertEqual(request.admittedRequest.model, "fake-model")
            let decision = await arms.decision(.rcw1, provider: "claude")
            XCTAssertEqual(decision.selectedFormat, .rcw1)
            XCTAssertEqual(decision.reason, .uniqueStrictMinimum)
            XCTAssertEqual(decision.counter?.provider, "claude")
            XCTAssertEqual(decision.counter?.resolvedModel, "fake-model")
            XCTAssertGreaterThan(decision.modeledContextDelta, 0)
            return decision
        }
        let runID = try await harness.start(arms.human)
        try assertUnboundHumanFallback(
            harness: harness,
            arms: arms,
            runID: runID,
            reason: .counterBindingMismatch
        )
    }

    /// WHY: the same candidate bytes ranked on another resolved model are not
    /// evidence for this model's tokenizer. Send current admitted Human.
    func test_staleCounterResolvedModelWithValidRCS1SendsHumanAndDropsEvidence() async throws {
        let harness = try Best3Harness.make(title: "c7 stale counter model rcs1")
        let arms = Best3Arms()
        harness.injectScopedRCW1()
        harness.select { request in
            XCTAssertEqual(request.admittedRequest.provider, .codex)
            XCTAssertEqual(request.admittedRequest.model, "fake-model")
            let decision = await arms.decision(.rcs1, resolvedModel: "other-model")
            XCTAssertEqual(decision.selectedFormat, .rcs1)
            XCTAssertEqual(decision.reason, .uniqueStrictMinimum)
            XCTAssertEqual(decision.counter?.provider, "codex")
            XCTAssertEqual(decision.counter?.resolvedModel, "other-model")
            XCTAssertGreaterThan(decision.modeledContextDelta, 0)
            return decision
        }
        let runID = try await harness.start(arms.human)
        try assertUnboundHumanFallback(
            harness: harness,
            arms: arms,
            runID: runID,
            reason: .counterBindingMismatch
        )
    }

    /// WHY: exact current-target counter evidence is the only optimized path.
    /// Matching provider/model must keep the ranked arm and its receipt.
    func test_boundCounterProviderAndModelDecisionRemainsOptimized() async throws {
        let cases: [(Best3Winner, TokenSaverBestOfThreeSelector.Format)] = [
            (.rcw1, .rcw1),
            (.rcs1, .rcs1),
        ]
        for (winner, format) in cases {
            let harness = try Best3Harness.make(title: "c7 bound counter \(format.rawValue)")
            let arms = Best3Arms()
            harness.injectScopedRCW1()
            harness.select { request in
                XCTAssertEqual(request.admittedRequest.provider.rawValue, "codex")
                XCTAssertEqual(request.admittedRequest.model, "fake-model")
                let decision = await arms.decision(winner)
                XCTAssertEqual(decision.selectedFormat, format)
                XCTAssertEqual(decision.counter?.provider, "codex")
                XCTAssertEqual(decision.counter?.resolvedModel, "fake-model")
                return decision
            }
            let runID = try await harness.start(arms.human)
            let env = harness.adapter.request?.environment ?? [:]
            let receipt = try XCTUnwrap(harness.recorder.events.first?.receipt)
            let sentFormat: TokenSaverBestOfThreeSelector.Format = winner == .rcs1 ? .human : format
            XCTAssertEqual(
                harness.adapter.request?.prompt,
                winner == .rcs1 ? arms.human : arms.payload(winner)
            )
            XCTAssertEqual(
                try harness.messageRepo.get(id: AgentMessageID(runID.value))?.content,
                arms.human
            )
            XCTAssertEqual(receipt.selectedFormat, sentFormat)
            if winner == .rcs1 {
                XCTAssertEqual(receipt.reason, .candidateError)
                XCTAssertEqual(receipt.modeledContextDelta, 0)
            } else {
                XCTAssertEqual(receipt.reason, .uniqueStrictMinimum)
                XCTAssertGreaterThan(receipt.modeledContextDelta, 0)
            }
            XCTAssertEqual(receipt.counter?.provider, "codex")
            XCTAssertEqual(receipt.counter?.resolvedModel, "fake-model")
            XCTAssertFalse(receipt.costs.isEmpty)
            XCTAssertFalse(receipt.arms.isEmpty)
            XCTAssertFalse(receipt.billingClaim)
            if winner == .rcw1 {
                XCTAssertEqual(env[rcw1Cap], "1")
                XCTAssertEqual(env[rcw1Ver], "1")
                XCTAssertEqual(
                    try harness.messageRepo.rcw1RequestTranslations(
                        threadId: harness.thread.id, messageIds: [AgentMessageID(runID.value)]
                    )[AgentMessageID(runID.value)],
                    arms.rcwOutbound
                )
                XCTAssertEqual(try harness.sessionWireVersion(), RCWireProtocol.version)
            } else {
                XCTAssertNil(env[rcw1Cap], "\(format.rawValue) must not inherit RCW1 capability")
                XCTAssertNil(env[rcw1Ver], "\(format.rawValue) must not inherit RCW1 version")
                XCTAssertTrue(
                    try harness.messageRepo.rcw1RequestTranslations(
                        threadId: harness.thread.id, messageIds: [AgentMessageID(runID.value)]
                    ).isEmpty
                )
                XCTAssertNil(try harness.sessionWireVersion())
            }
        }
    }

    /// WHY: capability/malformed fallback may keep measured arms only when the
    /// Decision already binds to this turn and Human Cost matches the sent bytes.
    func test_boundInvalidRCW1FallbackPreservesTruthfulEvidence() async throws {
        let harness = try Best3Harness.make(title: "c7 bound invalid rcw1")
        let arms = Best3Arms()
        harness.injectScopedRCW1()
        harness.select { _ in
            await arms.decision(.rcw1, rcwPayload: arms.malformedRCW1)
        }
        let runID = try await harness.start(arms.human)
        let sent = try XCTUnwrap(harness.adapter.request?.prompt)
        let receipt = try XCTUnwrap(harness.recorder.events.first?.receipt)
        let humanCost = try XCTUnwrap(receipt.costs.first { $0.format == .human })
        XCTAssertEqual(sent, arms.human)
        XCTAssertEqual(
            try harness.messageRepo.get(id: AgentMessageID(runID.value))?.content,
            arms.human
        )
        XCTAssertTrue(
            try harness.messageRepo.rcw1RequestTranslations(
                threadId: harness.thread.id, messageIds: [AgentMessageID(runID.value)]
            ).isEmpty
        )
        XCTAssertNil(try harness.sessionWireVersion())
        XCTAssertNil(harness.adapter.request?.environment[rcw1Cap])
        XCTAssertNil(harness.adapter.request?.environment[rcw1Ver])
        XCTAssertEqual(receipt.selectedFormat, .human)
        XCTAssertEqual(receipt.reason, .candidateError)
        XCTAssertEqual(receipt.modeledContextDelta, 0)
        XCTAssertEqual(receipt.sourceSHA256, sha256Hex(arms.human))
        XCTAssertEqual(humanCost.payloadSHA256, sha256Hex(sent))
        XCTAssertFalse(receipt.costs.isEmpty)
        XCTAssertFalse(receipt.arms.isEmpty)
        XCTAssertNotNil(receipt.counter)
        XCTAssertFalse(receipt.billingClaim)
    }

    /// WHY: stamp-after-projection lets Human/RCS1 regain capability and
    /// drops RCW1 VERSION. Counted projection must equal the sent environment.
    func test_typedReceiptBearingCountedEnvironmentEqualsSentEnvironment() async throws {
        let cases: [(Best3Winner, TokenSaverBestOfThreeSelector.Format)] = [
            (.human, .human),
            (.rcw1, .rcw1),
            (.rcs1, .rcs1),
        ]
        for (winner, format) in cases {
            let harness = try Best3Harness.make(title: "best3 receipt \(format.rawValue)")
            let arms = Best3Arms()
            let envCalls = CallLog()
            harness.injectReceiptBearingEnvironment(calls: envCalls)
            harness.select { request in
                XCTAssertEqual(envCalls.count, 1, "\(format) runEnvironmentProvider must run before selection")
                return await arms.decision(winner)
            }
            let runID = try await harness.start(arms.human)
            XCTAssertEqual(envCalls.count, 1, "\(format) must call runEnvironmentProvider exactly once")
            let selection = try XCTUnwrap(harness.recorder.requests.first)
            let sent = harness.adapter.request?.environment ?? [:]
            let sentFormat: TokenSaverBestOfThreeSelector.Format = winner == .rcs1 ? .human : format
            let projected = selection.environment(for: sentFormat)
            let attempt = runID.value.uuidString
            let admittedReceipt = try XCTUnwrap(
                TokenSaverExecutionReceiptSeam.receipt(from: selection.admittedEnvironment)
            )
            let projectedReceipt = try XCTUnwrap(TokenSaverExecutionReceiptSeam.receipt(from: projected))
            let sentReceipt = try XCTUnwrap(TokenSaverExecutionReceiptSeam.receipt(from: sent))
            XCTAssertEqual(admittedReceipt.rootRunId, attempt)
            XCTAssertEqual(admittedReceipt.attemptId, attempt)
            XCTAssertEqual(admittedReceipt.provider, "codex")
            XCTAssertEqual(projectedReceipt.rootRunId, attempt)
            XCTAssertEqual(projectedReceipt.attemptId, attempt)
            XCTAssertEqual(projectedReceipt.provider, "codex")
            XCTAssertEqual(sentReceipt.rootRunId, attempt)
            XCTAssertEqual(sentReceipt.attemptId, attempt)
            XCTAssertEqual(sentReceipt.provider, "codex")
            XCTAssertEqual(selection.admittedEnvironment["RC_TOKEN_SAVER_ROOT_RUN_ID"], attempt)
            XCTAssertEqual(selection.admittedEnvironment["RC_TOKEN_SAVER_ATTEMPT_ID"], attempt)
            XCTAssertEqual(projected[rcw1Cap], sent[rcw1Cap])
            XCTAssertEqual(projected[rcw1Ver], sent[rcw1Ver])
            XCTAssertEqual(projected["RC_TOKEN_SAVER_ROOT_RUN_ID"], sent["RC_TOKEN_SAVER_ROOT_RUN_ID"])
            XCTAssertEqual(projected["RC_TOKEN_SAVER_ATTEMPT_ID"], sent["RC_TOKEN_SAVER_ATTEMPT_ID"])
            XCTAssertEqual(harness.adapter.request?.provider, .codex)
            if sentFormat == .rcw1 {
                XCTAssertEqual(sent[rcw1Cap], "1")
                XCTAssertEqual(sent[rcw1Ver], "1")
                XCTAssertEqual(projected[rcw1Cap], "1")
                XCTAssertEqual(projected[rcw1Ver], "1")
            } else {
                XCTAssertNil(sent[rcw1Cap], "\(format) must not inherit RCW1 capability")
                XCTAssertNil(sent[rcw1Ver], "\(format) must not inherit RCW1 version")
                XCTAssertNil(projected[rcw1Cap])
                XCTAssertNil(projected[rcw1Ver])
            }
            XCTAssertEqual(harness.recorder.events.count, 1)
            XCTAssertEqual(harness.recorder.events.first?.receipt.selectedFormat, sentFormat)
            XCTAssertFalse(harness.recorder.events.first?.receipt.billingClaim ?? true)
        }
    }

    func test_promptCompressorTransformsOutboundButPreservesDisplayedMessage() async throws {
        let (coordinator, messageRepo, thread, tmp, runner) = try makeCoordinator()
        coordinator.promptCompressor = { prompt, _, _, _ in "COMPRESSED::" + prompt.uppercased() }
        coordinator.runEnvironmentProvider = { _, _, _ in
            [
                "RC_TOKEN_SAVER_DISTILL_HINT": "1",
                "RC_TOKEN_SAVER_WORKSPACE_ID": "workspace",
                "RC_TOKEN_SAVER_PROJECT_ID": "project",
                "RC_TOKEN_SAVER_THREAD_ID": thread.id.value.uuidString,
            ]
        }

        let original = "Please refactor the widget renderer in file Foo.swift, keep ID abc-123"
        let runID = AgentRunID()
        _ = try await coordinator.startRun(AgentRunRequest(
            runId: runID, threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: original
        ))
        await waitForPrompt(runner)

        XCTAssertEqual(runner.capturedPrompt, "COMPRESSED::" + original.uppercased(),
                       "the provider must receive the compressed prompt")
        XCTAssertEqual(runner.capturedEnvironment["RC_TOKEN_SAVER_ATTEMPT_ID"], runID.value.uuidString)
        let messages = (try? messageRepo.list(threadId: thread.id)) ?? []
        XCTAssertEqual(messages.first(where: { $0.role == .user })?.content, original,
                       "the displayed user message must remain the original, uncompressed text")
    }

    /// WHY: format, not prefix sniffing, decides the transport lane.
    func test_bestOfThreeWinnerAppliesFormatSpecificWireAdmission() async throws {
        let cases: [(Best3Winner, TokenSaverBestOfThreeSelector.Format, TokenSaverBestOfThreeSelector.Reason)] = [
            (.rcw1, .rcw1, .uniqueStrictMinimum),
            (.rcs1, .rcs1, .uniqueStrictMinimum),
            (.human, .human, .humanLowestCost),
        ]
        for (winner, format, reason) in cases {
            let harness = try Best3Harness.make(title: "best3 \(format.rawValue)")
            let arms = Best3Arms(rcs1LooksLikeRCW1: winner == .rcs1)
            if winner == .rcs1 {
                XCTAssertTrue(RCWireProtocol.isWire(arms.rcs1Outbound), "RCS1 fixture must look like RCW1")
            }
            let compressorCalls = CallLog()
            harness.injectScopedRCW1()
            harness.coordinator.promptCompressor = { prompt, _, _, _ in
                compressorCalls.add("compressor")
                return "COMPRESSOR-MUST-NOT-RUN::\(prompt)"
            }
            harness.select { request in
                if winner == .rcw1 {
                    XCTAssertEqual(request.canonicalHuman, arms.human)
                    XCTAssertEqual(request.admittedRequest.provider, .codex)
                    XCTAssertEqual(request.admittedRequest.model, "fake-model")
                    XCTAssertNil(request.autoRoute, "manual runs must not invent an Auto route")
                }
                XCTAssertEqual(request.admittedEnvironment[rcw1Cap], "1")
                XCTAssertEqual(request.admittedEnvironment[rcw1Ver], "1")
                XCTAssertEqual(request.environment(for: .rcw1)[rcw1Cap], "1")
                XCTAssertEqual(request.environment(for: .rcw1)[rcw1Ver], "1")
                XCTAssertNil(request.environment(for: .human)[rcw1Cap])
                XCTAssertNil(request.environment(for: .human)[rcw1Ver])
                XCTAssertNil(request.environment(for: .rcs1)[rcw1Cap])
                XCTAssertNil(request.environment(for: .rcs1)[rcw1Ver])
                return await arms.decision(winner)
            }
            let runID = try await harness.start(arms.human)
            let selection = try XCTUnwrap(harness.recorder.requests.first)
            let env = harness.adapter.request?.environment ?? [:]
            let sentFormat: TokenSaverBestOfThreeSelector.Format = winner == .rcs1 ? .human : format
            let projected = selection.environment(for: sentFormat)
            XCTAssertEqual(env[rcw1Cap], projected[rcw1Cap])
            XCTAssertEqual(env[rcw1Ver], projected[rcw1Ver])
            XCTAssertEqual(compressorCalls.count, 0, "typed selector must replace, not chain, the String compressor")
            XCTAssertEqual(
                harness.adapter.request?.prompt,
                winner == .rcs1 ? arms.human : arms.payload(winner)
            )
            XCTAssertEqual(try harness.messageRepo.get(id: AgentMessageID(runID.value))?.content, arms.human)
            XCTAssertEqual(harness.recorder.events.count, 1)
            XCTAssertEqual(harness.recorder.events.first?.outcome, .accepted)
            XCTAssertEqual(harness.recorder.events.first?.receipt.selectedFormat, sentFormat)
            XCTAssertEqual(
                harness.recorder.events.first?.receipt.reason,
                winner == .rcs1 ? .candidateError : reason
            )
            XCTAssertFalse(harness.recorder.events.first?.receipt.billingClaim ?? true)
            if winner == .rcw1 {
                XCTAssertEqual(env[rcw1Cap], "1")
                XCTAssertEqual(env[rcw1Ver], "1")
                XCTAssertEqual(
                    try harness.messageRepo.rcw1RequestTranslations(
                        threadId: harness.thread.id, messageIds: [AgentMessageID(runID.value)]
                    )[AgentMessageID(runID.value)],
                    arms.rcwOutbound
                )
                XCTAssertEqual(try harness.sessionWireVersion(), RCWireProtocol.version)
                XCTAssertEqual(harness.recorder.events.first?.provider, .codex)
                XCTAssertEqual(harness.recorder.events.first?.resolvedModel, "fake-model")
                XCTAssertEqual(harness.recorder.events.first?.runId, runID)
            } else {
                XCTAssertNil(env[rcw1Cap], "\(format.rawValue) must not inherit the scoped RCW1 capability")
                XCTAssertNil(env[rcw1Ver], "\(format.rawValue) must not receive the RCW1 wire version")
                XCTAssertTrue(
                    try harness.messageRepo.rcw1RequestTranslations(
                        threadId: harness.thread.id, messageIds: [AgentMessageID(runID.value)]
                    ).isEmpty
                )
                XCTAssertFalse(harness.observer.recordedEvents.contains {
                    if case .wireTranslation = $0 { return true }
                    return false
                })
                XCTAssertNil(try harness.sessionWireVersion(),
                             "\(format.rawValue) must not persist RCW1 session metadata")
            }
        }
    }

    /// WHY: a structurally valid RCS1 winner must reach the provider with the
    /// exclusive compact-span environment, never as RCW1 disclosure.
    func test_validRCS1WinnerSendsExactPayloadAndEnvironmentWithoutRCW1Disclosure() async throws {
        let harness = try Best3Harness.make(title: "valid rcs1 send")
        let human = String(repeating: "ABCDEFGH", count: 16)
        let item = try XCTUnwrap(RemoteCodeCompactSpan.encode(human))
        harness.injectScopedRCW1()
        harness.select { request in
            XCTAssertNil(request.environment(for: .rcs1)[rcw1Cap])
            XCTAssertNil(request.environment(for: .rcs1)[rcw1Ver])
            XCTAssertEqual(
                request.environment(for: .rcs1)[TokenSaverExecutionReceiptSeam.compactSpanCapabilityEnvKey],
                "1"
            )
            XCTAssertEqual(
                request.environment(for: .rcs1)[TokenSaverExecutionReceiptSeam.compactSpanVersionEnvKey],
                "1"
            )
            XCTAssertNil(request.environment(for: .human)[TokenSaverExecutionReceiptSeam.compactSpanCapabilityEnvKey])
            XCTAssertNil(request.environment(for: .rcw1)[TokenSaverExecutionReceiptSeam.compactSpanCapabilityEnvKey])
            return await validRCS1Decision(human: human, item: item, request: request)
        }
        let runID = try await harness.start(human)
        let env = harness.adapter.request?.environment ?? [:]
        XCTAssertEqual(harness.adapter.request?.prompt, item)
        XCTAssertEqual(
            try harness.messageRepo.get(id: AgentMessageID(runID.value))?.content,
            human
        )
        XCTAssertEqual(env[TokenSaverExecutionReceiptSeam.compactSpanCapabilityEnvKey], "1")
        XCTAssertEqual(env[TokenSaverExecutionReceiptSeam.compactSpanVersionEnvKey], "1")
        XCTAssertNil(env[rcw1Cap])
        XCTAssertNil(env[rcw1Ver])
        XCTAssertTrue(
            try harness.messageRepo.rcw1RequestTranslations(
                threadId: harness.thread.id, messageIds: [AgentMessageID(runID.value)]
            ).isEmpty
        )
        XCTAssertFalse(harness.observer.recordedEvents.contains {
            if case .wireTranslation = $0 { return true }
            return false
        })
        XCTAssertNil(try harness.sessionWireVersion())
        XCTAssertEqual(harness.recorder.events.count, 1)
        XCTAssertEqual(harness.recorder.events.first?.receipt.selectedFormat, .rcs1)
        XCTAssertEqual(harness.recorder.events.first?.receipt.reason, .uniqueStrictMinimum)
        XCTAssertFalse(harness.recorder.events.first?.receipt.billingClaim ?? true)
    }

    /// WHY: a synthetic or malformed RCS1 winner is not a transport item.
    func test_malformedRCS1WinnerFallsBackToHumanWithoutRCW1Disclosure() async throws {
        let harness = try Best3Harness.make(title: "malformed rcs1 fallback")
        let arms = Best3Arms()
        harness.injectScopedRCW1()
        harness.select { _ in await arms.decision(.rcs1) }
        let runID = try await harness.start(arms.human)
        let env = harness.adapter.request?.environment ?? [:]
        XCTAssertEqual(harness.adapter.request?.prompt, arms.human)
        XCTAssertEqual(
            try harness.messageRepo.get(id: AgentMessageID(runID.value))?.content,
            arms.human
        )
        XCTAssertNil(env[rcw1Cap])
        XCTAssertNil(env[rcw1Ver])
        XCTAssertNil(env[TokenSaverExecutionReceiptSeam.compactSpanCapabilityEnvKey])
        XCTAssertTrue(
            try harness.messageRepo.rcw1RequestTranslations(
                threadId: harness.thread.id, messageIds: [AgentMessageID(runID.value)]
            ).isEmpty
        )
        XCTAssertNil(try harness.sessionWireVersion())
        XCTAssertEqual(harness.recorder.events.first?.receipt.selectedFormat, .human)
        XCTAssertEqual(harness.recorder.events.first?.receipt.reason, .candidateError)
    }

    /// WHY: one local-write observation per decision; never billing.
    func test_bestOfThreeDeliveryCallbackReportsLocalWriteOutcome() async throws {
        enum Case { case refused, notAccepted, unknown }
        for item in [Case.refused, .notAccepted, .unknown] {
            let mode: PromptAcceptanceMode = item == .unknown ? .unknown : .notAccepted
            let harness = try Best3Harness.make(title: "best3 outcome", acceptanceMode: mode)
            let human = "Canonical Human fallback remains exact."
            harness.select { _ in await Best3Arms.humanFallback(human) }
            harness.coordinator.providerAdmissionCheck = { _, _ in
                harness.coordinator.onTokenSaverOutboundDelivery = { _ in
                    XCTFail("post-selection handler rebind must not steal this decision's local-write receipt")
                }
                if item == .refused {
                    throw AgentProviderAdapterError.unsupported("post-selection admission refused")
                }
            }
            let runID = AgentRunID()
            do {
                _ = try await harness.start(human, runID: runID)
                if item == .refused {
                    XCTFail("startRun must throw after the selected decision when admission refuses")
                }
            } catch let error as AgentProviderAdapterError {
                guard item == .refused, case .unsupported(let detail) = error else {
                    return XCTFail("unexpected startRun error \(error)")
                }
                XCTAssertEqual(detail, "post-selection admission refused")
            }
            if item == .refused {
                XCTAssertNil(harness.adapter.request, "refused admission must not write the selected prompt")
            } else {
                XCTAssertEqual(harness.adapter.request?.prompt, human)
                XCTAssertEqual(harness.recorder.events.first?.receipt.reason, .candidateError)
            }
            XCTAssertEqual(harness.recorder.events.count, 1)
            XCTAssertEqual(harness.recorder.events.first?.outcome, item == .unknown ? .unknown : .notAccepted)
            XCTAssertEqual(harness.recorder.events.first?.receipt.selectedFormat, .human)
            XCTAssertFalse(harness.recorder.events.first?.receipt.billingClaim ?? true)
        }
    }

    /// WHY: human -> RCW1 is a translation of the user message itself. Keying
    /// disclosure only to a later reasoning/assistant item leaves the user row
    /// with no way to render its Human/RCW1 toggle.
    func test_wirePromptPublishesUserMessageDisclosureForAllProviders() async throws {
        for provider in [AgentProvider.claude, .codex, .grok] {
            let tmp = NSTemporaryDirectory()
                + "rc2-user-wire-disclosure-\(provider.rawValue)-\(UUID().uuidString)"
            let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
            let threadRepo = AgentThreadRepository(db: db)
            let messageRepo = AgentMessageRepository(db: db)
            let runRepo = AgentRunRepository(db: db)
            let thread = AgentThread(title: "user wire disclosure", provider: provider, model: "fake-model")
            try threadRepo.upsert(thread)
            let runner = PromptCapturingRunner(provider: provider)
            let coordinator = AgentRunCoordinator(
                runRepo: runRepo,
                messageRepo: messageRepo,
                threadRepo: threadRepo,
                providers: [provider: runner]
            )
            let observer = RecordingObserver()
            coordinator.addObserver(observer)

            let human = "Inspect the real provider path and report one result."
            let wire = "RCW1\tQ\t1\nG\tInspect the real provider path and report one result.\n.\n"
            coordinator.promptCompressor = { _, _, _, _ in wire }
            let runID = AgentRunID()

            _ = try await coordinator.startRun(.init(
                runId: runID,
                threadId: thread.id,
                provider: provider,
                model: "fake-model",
                cwd: tmp,
                prompt: human
            ))
            await runner.waitForPromptCapture()
            try await waitForRun(runID, in: runRepo)

            let disclosure = observer.recordedEvents.compactMap { event -> AssistantWireTranslation? in
                guard case .wireTranslation(let translation) = event,
                      translation.messageId == runID.value.uuidString else { return nil }
                return translation
            }.first
            XCTAssertEqual(disclosure?.fallbackReason, "outbound_wire_request", "\(provider) user disclosure")
            XCTAssertEqual(disclosure?.wireRequestText, wire, "\(provider) exact provider-bound RCW1")
            XCTAssertEqual(disclosure?.originalText, "", "\(provider) must not duplicate a large RCW1 request")
            XCTAssertEqual(disclosure?.rewrittenText, "", "\(provider) human text already lives in AgentMessage")

            let messages = (try? messageRepo.list(threadId: thread.id)) ?? []
            XCTAssertEqual(
                messages.first(where: { $0.id == AgentMessageID(runID.value) })?.content,
                human,
                "\(provider) visible user message stays human"
            )

            var timeline = AssistantTimelineState()
            for event in coordinator.latestStreamEvents(threadId: thread.id) {
                timeline.apply(event)
            }
            XCTAssertEqual(
                timeline.tokenSaverTranslationsByMessageId[runID.value.uuidString]?.wireRequestText,
                wire,
                "\(provider) restart replay must retain the user-row RCW1 toggle metadata"
            )
        }
    }

    func test_followUpCompressorTransformsOutboundButPreservesVerbatimAnswer() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-followup-compress-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "follow-up", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let adapter = UserInputCapturingAdapter(provider: .claude)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerAdapters: [.claude: adapter]
        )
        let activeRun = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            status: .running,
            startedAt: Date()
        )
        try runRepo.upsert(activeRun)
        coordinator.promptCompressor = { _, _, _, _ in
            XCTFail("free-form follow-up answers should use followUpPromptCompressor when present")
            return "WRONG"
        }
        coordinator.followUpPromptCompressor = { prompt, provider, threadId, runId in
            XCTAssertEqual(provider, .claude)
            XCTAssertEqual(threadId, thread.id)
            XCTAssertEqual(runId, activeRun.id,
                           "follow-up RCW1 recovery must use the active provider attempt scope")
            return "COMPRESSED::" + prompt
        }

        let original = "Here is a long follow-up stack trace at /tmp/Foo.swift:42 with error code 17"
        try await coordinator.respondToUserInput(threadId: thread.id, requestId: "free-form-1", text: original)

        XCTAssertEqual(adapter.capturedUserInput?.verbatimText, original,
                       "UI/history must preserve the exact user answer")
        XCTAssertEqual(adapter.capturedUserInput?.outboundText, "COMPRESSED::" + original,
                       "free-form follow-up dispatch must use the compressed outbound text")
    }

    func test_noCompressorSendsOriginalUnchanged() async throws {
        let (coordinator, messageRepo, thread, tmp, runner) = try makeCoordinator()
        // No promptCompressor set → Token Saver inactive → verbatim passthrough.
        let original = "build the project and run the tests"
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: original
        ))
        await waitForPrompt(runner)

        XCTAssertEqual(runner.capturedPrompt, original)
        let messages = (try? messageRepo.list(threadId: thread.id)) ?? []
        XCTAssertEqual(messages.first(where: { $0.role == .user })?.content, original)
    }

    func test_failOpenCompressorReturningInputLeavesPromptIntact() async throws {
        let (coordinator, messageRepo, thread, tmp, runner) = try makeCoordinator()
        // Fail-open contract: compressor returns its input on any failure.
        coordinator.promptCompressor = { prompt, _, _, _ in prompt }
        let original = "explain this stack trace and fix the crash"
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: original
        ))
        await waitForPrompt(runner)

        XCTAssertEqual(runner.capturedPrompt, original)
        let messages = (try? messageRepo.list(threadId: thread.id)) ?? []
        XCTAssertEqual(messages.first(where: { $0.role == .user })?.content, original)
    }

    func test_wireFinalResponseIsRenderedBeforePersistenceAndKeepsRawMetadata() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-response-humanize-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let wire = "RCW1\tA\t1\nO\tSaved counter updated.\nE\tmacOS suite passed.\n.\n"
        let runner = ScriptedFinalRunner(provider: .claude, finalMessage: wire)
        let thread = AgentThread(title: "wire", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.claude: runner]
        )

        let rendered = "Tests passed and the saved-token counter was updated."
        coordinator.finalResponseWireAdmissionCheck = { _, _ in true }
        coordinator.finalResponseTranslator = { response, provider, threadId, _ in
            XCTAssertEqual(provider, .claude)
            XCTAssertEqual(threadId, thread.id)
            XCTAssertTrue(RCWireProtocol.isWire(response))
            return rendered
        }

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            cwd: tmp,
            prompt: "Explain the result."
        ))
        let assistant = try await waitForAssistantMessage(messageRepo, threadId: thread.id)

        XCTAssertEqual(assistant.content, rendered,
                       "the transcript must persist readable text, not provider wire")
        XCTAssertFalse(assistant.content.contains("RCW1"))
        let translation = try await waitForWireTranslation(
            coordinator,
            threadId: thread.id,
            messageId: assistant.id.value.uuidString
        )
        XCTAssertEqual(translation.originalText, wire,
                       "persisted stream replay must retain the original provider wire for disclosure")
        XCTAssertEqual(translation.rewrittenText, rendered)
        let durable = try await waitForDurableRCW1Response(
            messageRepo,
            threadId: thread.id,
            messageId: assistant.id
        )
        XCTAssertEqual(durable.wireResponseText, wire,
                       "the exact provider response must also survive outside the capped stream")
        XCTAssertEqual(durable.messageId, assistant.id)
    }

    /// WHY: RCW1 framing is not a saving when the complete provider frame costs
    /// more than its deterministic Human projection. Such a response must remain
    /// readable without being persisted or advertised as an optimized translation.
    func test_unadmittedWireFinalFailsOpenToHumanWithoutRCW1Disclosure() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-response-profitability-gate-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let wire = "RCW1\tA\t1\nO\tOK\n.\n"
        let runner = ScriptedFinalRunner(provider: .codex, finalMessage: wire)
        let thread = AgentThread(title: "wire admission", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let wireRequest = "RCW1\tQ\t1\nG\tReturn one terse result.\n.\n"
        coordinator.promptCompressor = { _, _, _, _ in wireRequest }
        coordinator.finalResponseTranslator = { _, _, _, _ in
            XCTFail("an unadmitted RCW1 response must not enter the translation lane")
            return "wrong"
        }

        _ = try await coordinator.startRun(.init(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "Return one terse result."
        ))
        let assistant = try await waitForAssistantMessage(messageRepo, threadId: thread.id)

        XCTAssertEqual(assistant.content, "OK")
        XCTAssertTrue(
            try messageRepo.rcw1ResponseTranslations(
                threadId: thread.id,
                messageIds: [assistant.id]
            ).isEmpty,
            "a fail-open Human response must not gain an RCW1 toggle"
        )
        var timeline = AssistantTimelineState()
        for event in coordinator.latestStreamEvents(threadId: thread.id) {
            timeline.apply(event)
        }
        XCTAssertNil(timeline.tokenSaverTranslationsByMessageId[assistant.id.value.uuidString])
    }

    func test_identicalReadableResponsesKeepDistinctRunOwnedRCW1Associations() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-identical-response-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let wire = "RCW1\tA\t1\nO\tThe same readable result.\n.\n"
        let readable = "The same readable result."
        let runner = ScriptedFinalRunner(provider: .claude, finalMessage: wire)
        let thread = AgentThread(title: "identical wire", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.claude: runner]
        )
        coordinator.finalResponseWireAdmissionCheck = { _, _ in true }
        coordinator.finalResponseTranslator = { _, _, _, _ in readable }

        let firstRun = AgentRunID()
        _ = try await coordinator.startRun(.init(
            runId: firstRun,
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            cwd: tmp,
            prompt: "First turn."
        ))
        let firstAssistant = try await waitForAssistantMessage(messageRepo, threadId: thread.id)
        _ = try await waitForDurableRCW1Response(
            messageRepo,
            threadId: thread.id,
            messageId: firstAssistant.id
        )
        let idleDeadline = Date().addingTimeInterval(3)
        while Date() < idleDeadline, coordinator.activeRunId(threadId: thread.id) != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(coordinator.activeRunId(threadId: thread.id))

        let secondRun = AgentRunID()
        _ = try await coordinator.startRun(.init(
            runId: secondRun,
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            cwd: tmp,
            prompt: "Second turn."
        ))
        let deadline = Date().addingTimeInterval(3)
        var assistants: [AgentMessage] = []
        while Date() < deadline {
            assistants = ((try? messageRepo.list(threadId: thread.id)) ?? [])
                .filter { $0.role == .assistant && $0.content == readable }
            if assistants.count == 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(assistants.count, 2,
                       "equal prose from separate turns must not be collapsed by content")
        XCTAssertEqual(Set(assistants.map(\.id)).count, 2)
        let durable = try await waitForDurableRCW1Responses(
            messageRepo,
            threadId: thread.id,
            messageIds: assistants.map(\.id),
            expectedCount: 2
        )
        XCTAssertEqual(Set(durable.values.map(\.runId)), Set([firstRun, secondRun]))
        for assistant in assistants {
            XCTAssertEqual(durable[assistant.id]?.wireResponseText, wire)
            XCTAssertEqual(durable[assistant.id]?.messageId, assistant.id)
        }
    }

    func test_providerPreambleBeforeWireIsRenderedWithoutTransportLeak() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-response-preamble-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let wire = "RCW1\tA\t1\nO\tThe provider matrix passed.\nE\tClaude exited 0.\n.\n"
        let raw = "Response in the requested RCW1 frame:\n\n" + wire
        let runner = ScriptedFinalRunner(provider: .claude, finalMessage: raw)
        let thread = AgentThread(title: "wire preamble", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.claude: runner]
        )

        let rendered = "The provider matrix passed. Claude exited 0."
        coordinator.finalResponseWireAdmissionCheck = { _, _ in true }
        coordinator.finalResponseTranslator = { response, _, _, _ in
            XCTAssertEqual(response, wire.trimmingCharacters(in: .whitespacesAndNewlines),
                           "the local renderer must receive only the strict frame payload")
            return rendered
        }

        _ = try await coordinator.startRun(.init(
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            cwd: tmp,
            prompt: "Run the provider matrix."
        ))
        let assistant = try await waitForAssistantMessage(messageRepo, threadId: thread.id)
        let translation = try await waitForWireTranslation(
            coordinator,
            threadId: thread.id,
            messageId: assistant.id.value.uuidString
        )

        XCTAssertEqual(assistant.content, rendered)
        XCTAssertFalse(assistant.content.contains("RCW1"),
                       "a provider preamble must not make private wire visible")
        XCTAssertEqual(translation.originalText, raw,
                       "the exact nonconforming provider response remains available in disclosure")
        XCTAssertEqual(translation.rewrittenText, rendered)
    }

    func test_finalAssistantMarkersAreStrippedBeforePersistenceAndTurnCompletedDisplay() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-final-handle-strip-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let runID = AgentRunID()
        let receiptKey = Data((0..<32).map(UInt8.init))
        let receiptPrefix = Data("Build passed. Full raw output available.\n[[rc:deadbeef]]\n".utf8)
        let receipt = try XCTUnwrap(DistillAppliedReceipt.makeV2Marker(
            rootRunID: runID.value.uuidString,
            payload: receiptPrefix,
            key: receiptKey,
            nonce: Data(repeating: 0x42, count: 16)
        ))
        let final = String(decoding: receiptPrefix, as: UTF8.self) + receipt
        let stateURL = URL(fileURLWithPath: tmp, isDirectory: true)
            .appendingPathComponent("DistillCLIState.json")
        let state = try JSONSerialization.data(withJSONObject: [
            "base_url": "http://127.0.0.1:1",
            "auth_token": "test-token",
            "receipt_key": try XCTUnwrap(DistillAppliedReceipt.encodeReceiptKey(receiptKey)),
            "pid": ProcessInfo.processInfo.processIdentifier,
        ], options: [.sortedKeys])
        try state.write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        let runner = ScriptedFinalRunner(provider: .codex, finalMessage: final)
        let thread = AgentThread(title: "final handle", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let observer = RecordingObserver()
        coordinator.addObserver(observer)

        _ = try await coordinator.startRun(AgentRunRequest(
            runId: runID,
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "Summarize the build output.",
            environment: [
                "RC_TOKEN_SAVER_DISTILL_HINT": "1",
                "RC_TOKEN_SAVER_ROOT_RUN_ID": runID.value.uuidString,
                "REMOTE_CODE_DISTILL_STATE_PATH": stateURL.path,
            ]
        ))
        let assistant = try await waitForAssistantMessage(messageRepo, threadId: thread.id)

        XCTAssertEqual(assistant.content, "Build passed. Full raw output available.",
                       "final assistant persistence must strip recovery and applied markers so transcript text stays human-facing")
        XCTAssertFalse(assistant.content.contains("[[rc:"))
        XCTAssertFalse(assistant.content.contains("[[rcd:"))
        let turnCompleted = observer.recordedEvents.compactMap(\.turnCompletedFinalMessageForTest).last
        XCTAssertEqual(turnCompleted, assistant.content,
                       "turnCompleted display payload must match the sanitized persisted assistant text")
    }

    func test_finalResponseTranslatorOutputHandleMarkerIsStrippedBeforePersistence() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-translated-handle-strip-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let wire = "RCW1\tA\t1\nO\tBuild passed.\nE\tunit tests green.\n.\n"
        let runner = ScriptedFinalRunner(provider: .claude, finalMessage: wire)
        let thread = AgentThread(title: "translated handle", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.claude: runner]
        )

        coordinator.finalResponseWireAdmissionCheck = { _, _ in true }
        coordinator.finalResponseTranslator = { _, _, _, _ in
            "Build passed. Raw log retained.\n[[rc:cafebabe]]"
        }

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            cwd: tmp,
            prompt: "Explain the build result."
        ))
        let assistant = try await waitForAssistantMessage(messageRepo, threadId: thread.id)

        XCTAssertEqual(assistant.content, "Build passed. Raw log retained.",
                       "translated final text must be sanitized before it reaches transcript persistence")
        XCTAssertFalse(assistant.content.contains("[[rc:"))
    }

    func test_wireAssistantStreamRendersDeterministicallyWithoutLeakingRawFrame() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-wire-stream-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let wire = "RCW1\tA\t1\nA\tInspecting App.swift.\n.\nRCW1\tA\t2\nO\tThe race was fixed.\nE\tFocused tests passed.\n.\n"
        let runner = ScriptedStreamRunner(provider: .codex, body: wire)
        let thread = AgentThread(title: "wire stream", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let observer = RecordingObserver()
        coordinator.addObserver(observer)
        coordinator.finalResponseWireAdmissionCheck = { _, _ in true }
        coordinator.finalResponseTranslator = { _, _, _, _ in
            XCTFail("complete streamed frames use the deterministic renderer without an MLX wait")
            return "wrong"
        }

        _ = try await coordinator.startRun(.init(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: "Fix the race."
        ))

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              !observer.recordedEvents.compactMap(\.bodyAppendForTest).joined().contains("Focused tests passed") {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let visible = observer.recordedEvents.compactMap(\.bodyAppendForTest).joined(separator: "")
        XCTAssertTrue(visible.contains("Action: Inspecting App.swift."))
        XCTAssertTrue(visible.contains("The race was fixed."))
        XCTAssertTrue(visible.contains("Evidence: Focused tests passed."))
        XCTAssertFalse(visible.contains("RCW1"), "raw wire must never leak into the primary transcript")

        let disclosureDeadline = Date().addingTimeInterval(3)
        var pendingMetadata: AssistantSR1Translation?
        while Date() < disclosureDeadline, pendingMetadata == nil {
            var timeline = AssistantTimelineState()
            for event in coordinator.latestStreamEvents(threadId: thread.id) { timeline.apply(event) }
            pendingMetadata = timeline.tokenSaverTranslationsByItemId["stream-item"]
            if pendingMetadata == nil {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let metadata = try XCTUnwrap(pendingMetadata)
        XCTAssertEqual(metadata.originalText, wire)
        XCTAssertTrue(metadata.rewrittenText.contains("Focused tests passed"))
    }

    /// WHY: streamed providers expose complete RCW1 prefixes before the item is
    /// terminal. Disclosure must wait for the complete-frame host gate so a
    /// temporarily small prefix cannot create a misleading optimized toggle.
    func test_unadmittedWireStreamRendersHumanWithoutRCW1Disclosure() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-wire-stream-profitability-gate-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let wire = "RCW1\tA\t1\nO\tOK\n.\n"
        let runner = ScriptedStreamRunner(provider: .grok, body: wire)
        let thread = AgentThread(title: "wire stream admission", provider: .grok, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.grok: runner]
        )
        let observer = RecordingObserver()
        coordinator.addObserver(observer)
        let wireRequest = "RCW1\tQ\t1\nG\tReturn one terse result.\n.\n"
        coordinator.promptCompressor = { _, _, _, _ in wireRequest }
        coordinator.finalResponseTranslator = { _, _, _, _ in
            XCTFail("complete unadmitted streamed frames use deterministic Human fail-open")
            return "wrong"
        }

        _ = try await coordinator.startRun(.init(
            threadId: thread.id,
            provider: .grok,
            model: "fake-model",
            cwd: tmp,
            prompt: "Return one terse result."
        ))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              !observer.recordedEvents.contains(where: {
                  if case .itemCompleted(let itemId, _) = $0 { return itemId == "stream-item" }
                  return false
              }) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(observer.recordedEvents.compactMap(\.bodyAppendForTest).joined(), "OK")
        var timeline = AssistantTimelineState()
        for event in coordinator.latestStreamEvents(threadId: thread.id) {
            timeline.apply(event)
        }
        XCTAssertNil(
            timeline.tokenSaverTranslationsByItemId["stream-item"],
            "Human fail-open stream items must not gain an RCW1 response toggle"
        )
    }

    func test_splitWireSentinelNeverLeaksPartialTransportText() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-wire-split-sentinel-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let wire = "RCW1\tA\t1\nO\tThe split frame stayed private.\n.\n"
        let runner = ScriptedStreamRunner(
            provider: .grok,
            bodyChunks: ["R", "C", "W", "1\t", "A\t1\n", "O\tThe split frame stayed private.\n", ".\n"]
        )
        let thread = AgentThread(title: "split wire sentinel", provider: .grok, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.grok: runner]
        )
        let observer = RecordingObserver()
        coordinator.addObserver(observer)
        coordinator.finalResponseWireAdmissionCheck = { _, _ in true }
        coordinator.finalResponseTranslator = { response, _, _, _ in response }

        _ = try await coordinator.startRun(.init(
            threadId: thread.id, provider: .grok, model: "fake-model", cwd: tmp, prompt: "Report the result."
        ))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            var currentTimeline = AssistantTimelineState()
            for event in coordinator.latestStreamEvents(threadId: thread.id) { currentTimeline.apply(event) }
            if currentTimeline.tokenSaverTranslationsByItemId["stream-item"]?.originalText == wire {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let visible = observer.recordedEvents.compactMap(\.bodyAppendForTest).joined()
        XCTAssertEqual(visible, "The split frame stayed private.")
        XCTAssertFalse(visible.contains("RCW1"))
        XCTAssertFalse(visible.hasPrefix("R"), "a fragmented sentinel must remain buffered until classified")
        var timeline = AssistantTimelineState()
        for event in coordinator.latestStreamEvents(threadId: thread.id) { timeline.apply(event) }
        XCTAssertEqual(timeline.tokenSaverTranslationsByItemId["stream-item"]?.originalText, wire)
    }

    func test_truncatedWireStreamShowsReadableErrorAndKeepsRawDisclosure() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-wire-truncated-stream-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let raw = "RCW1\tA\t1\nO\tThis frame was truncated"
        let runner = ScriptedStreamRunner(provider: .claude, bodyChunks: ["RC", "W1\tA\t1\n", "O\tThis frame was truncated"])
        let thread = AgentThread(title: "truncated wire", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.claude: runner]
        )
        let observer = RecordingObserver()
        coordinator.addObserver(observer)
        coordinator.finalResponseTranslator = { response, _, _, _ in response }

        _ = try await coordinator.startRun(.init(
            threadId: thread.id, provider: .claude, model: "fake-model", cwd: tmp, prompt: "Report the result."
        ))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            var currentTimeline = AssistantTimelineState()
            for event in coordinator.latestStreamEvents(threadId: thread.id) { currentTimeline.apply(event) }
            if currentTimeline.tokenSaverTranslationsByItemId["stream-item"]?.originalText == raw {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let visible = observer.recordedEvents.compactMap(\.bodyAppendForTest).joined()
        XCTAssertTrue(visible.contains("Token Saver could not decode"))
        XCTAssertFalse(visible.contains("RCW1"), "malformed transport must not masquerade as fluent output")
        var timeline = AssistantTimelineState()
        for event in coordinator.latestStreamEvents(threadId: thread.id) { timeline.apply(event) }
        let metadata = try XCTUnwrap(timeline.tokenSaverTranslationsByItemId["stream-item"])
        XCTAssertEqual(metadata.originalText, raw)
        let wireMetadata = coordinator.latestStreamEvents(threadId: thread.id).compactMap { event -> AssistantWireTranslation? in
            guard case .wireTranslation(let translation) = event else { return nil }
            return translation
        }.last
        XCTAssertEqual(wireMetadata?.fallbackReason, "deterministic_render")
    }

    func test_reasoningStreamIsNeverDecodedAsAssistantWire() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-wire-reasoning-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let raw = "RCW1\tA\t1\nA\tprivate reasoning record\n.\n"
        let runner = ScriptedStreamRunner(provider: .claude, itemType: .reasoning, body: "", output: raw)
        let thread = AgentThread(title: "reasoning", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.claude: runner]
        )
        let observer = RecordingObserver()
        coordinator.addObserver(observer)
        coordinator.finalResponseTranslator = { _, _, _, _ in
            XCTFail("RCW1 v1 covers assistant messages, not reasoning/tool protocol events")
            return "wrong"
        }

        _ = try await coordinator.startRun(.init(
            threadId: thread.id, provider: .claude, model: "fake-model", cwd: tmp, prompt: "Inspect."
        ))
        try? await Task.sleep(nanoseconds: 100_000_000)
        let output = observer.recordedEvents.compactMap(\.outputAppendForTest).joined()
        XCTAssertEqual(output, raw)
    }

    /// WHY: reasoning is the only provider narrative visible while many Grok
    /// turns are running. When the outbound turn used RCW1, its transport
    /// disclosure must be available at item start instead of waiting for the
    /// eventual final assistant message.
    func test_reasoningStreamPublishesWireAdmissionBeforeItemCompletes() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-wire-reasoning-disclosure-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let runner = ScriptedStreamRunner(
            provider: .grok,
            itemType: .reasoning,
            body: "Inspecting the merge state."
        )
        let thread = AgentThread(title: "reasoning disclosure", provider: .grok, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.grok: runner]
        )
        let observer = RecordingObserver()
        coordinator.addObserver(observer)
        let wireRequest = "RCW1\tQ\t1\nG\tInspect the merge state.\n.\n"
        coordinator.promptCompressor = { _, _, _, _ in wireRequest }
        coordinator.finalResponseTranslator = { response, _, _, _ in response }

        _ = try await coordinator.startRun(.init(
            threadId: thread.id,
            provider: .grok,
            model: "fake-model",
            cwd: tmp,
            prompt: "Inspect the merge state."
        ))

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              !observer.recordedEvents.contains(where: {
                  if case .itemCompleted(let itemId, _) = $0 { return itemId == "stream-item" }
                  return false
              }) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let events = observer.recordedEvents
        let admissionIndex = events.firstIndex { event in
            guard case .wireTranslation(let translation) = event else { return false }
            return translation.itemId == "stream-item"
                && translation.fallbackReason == "provider_response_pending"
                && translation.wireRequestText == wireRequest
        }
        let completionIndex = events.firstIndex { event in
            if case .itemCompleted(let itemId, _) = event { return itemId == "stream-item" }
            return false
        }

        XCTAssertNotNil(admissionIndex, "the running reasoning row must receive RCW1 disclosure metadata")
        XCTAssertNotNil(completionIndex)
        if let admissionIndex, let completionIndex {
            XCTAssertLessThan(admissionIndex, completionIndex, "the toggle must not wait for thread completion")
        }

        while Date() < deadline,
              !coordinator.latestStreamEvents(threadId: thread.id).contains(where: {
                  guard case .wireTranslation(let translation) = $0 else { return false }
                  return translation.itemId == "stream-item"
              }) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        var timeline = AssistantTimelineState()
        for event in coordinator.latestStreamEvents(threadId: thread.id) {
            timeline.apply(event)
        }
        let persisted = try XCTUnwrap(timeline.tokenSaverTranslationsByItemId["stream-item"])
        XCTAssertEqual(persisted.wireRequestText, wireRequest)
        XCTAssertEqual(persisted.originalText, "",
                       "the running row uses its current visible reasoning as the raw-response fallback")
    }

    func test_normalFinalResponseDoesNotInvokeWireTranslator() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-ts-response-normal-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let normal = "Sure, I can explain the result in normal prose."
        let runner = ScriptedFinalRunner(provider: .codex, finalMessage: normal)
        let thread = AgentThread(title: "normal", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: runner]
        )

        coordinator.finalResponseTranslator = { _, _, _, _ in
            XCTFail("normal prose must not be sent through the wire renderer")
            return "wrong"
        }

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "Explain the result."
        ))
        let assistant = try await waitForAssistantMessage(messageRepo, threadId: thread.id)

        XCTAssertEqual(assistant.content, normal)
    }

    func test_plainProviderResponseToAdmittedWireStaysReadableAndPersistsFallbackDisclosure() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-wire-plain-fallback-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let plain = "Approval is required before I can inspect the fixture."
        let runner = ScriptedFinalRunner(provider: .claude, finalMessage: plain)
        let thread = AgentThread(title: "wire fallback", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.claude: runner]
        )
        let requestWire = try RCWireProtocol.serialize(.init(
            direction: .request,
            sequence: 1,
            records: [.init(kind: .goal, value: "Inspect the fixture.")]
        ))
        coordinator.promptCompressor = { _, _, _, _ in requestWire }
        coordinator.finalResponseTranslator = { _, _, _, _ in
            XCTFail("human-readable provider fallback must not wait for local rendering")
            return "wrong"
        }

        _ = try await coordinator.startRun(.init(
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            cwd: tmp,
            prompt: "Inspect the fixture and explain the result."
        ))
        let assistant = try await waitForAssistantMessage(messageRepo, threadId: thread.id)
        let translation = try await waitForWireTranslation(
            coordinator,
            threadId: thread.id,
            messageId: assistant.id.value.uuidString
        )

        XCTAssertEqual(assistant.content, plain,
                       "a provider protocol miss must remain readable instead of becoming an empty or raw-wire reply")
        XCTAssertEqual(translation.originalText, plain,
                       "the exact provider response must survive for transport disclosure")
        XCTAssertEqual(translation.rewrittenText, plain)
        XCTAssertEqual(translation.fallbackReason, "provider_plaintext_fallback",
                       "the UI must distinguish provider nonconformance from a successful decoded frame")
        XCTAssertEqual(translation.wireRequestText, requestWire,
                       "the disclosure must retain what RemoteCode actually sent")
    }

    func test_plainStreamOnAdmittedWireKeepsRequestDisclosureOnUserMessageWithoutBufferingProse() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-wire-plain-stream-disclosure-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let plain = "Action: Inspecting the live workspace now."
        let runner = ScriptedStreamRunner(provider: .codex, body: plain)
        let thread = AgentThread(title: "wire plain stream", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let observer = RecordingObserver()
        coordinator.addObserver(observer)
        let requestWire = try RCWireProtocol.serialize(.init(
            direction: .request,
            sequence: 1,
            records: [.init(kind: .goal, value: "Inspect the live workspace now.")]
        ))
        coordinator.promptCompressor = { _, _, _, _ in requestWire }
        coordinator.finalResponseTranslator = { response, _, _, _ in response }

        let runId = AgentRunID()
        _ = try await coordinator.startRun(.init(
            runId: runId,
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "Inspect the live workspace now."
        ))

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              !observer.recordedEvents.compactMap(\.bodyAppendForTest).joined().contains(plain) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(observer.recordedEvents.compactMap(\.bodyAppendForTest).joined(), plain,
                       "provider plaintext must keep streaming immediately instead of waiting for translation")
        try await waitForRun(runId, in: runRepo)
        var timeline = AssistantTimelineState()
        for event in coordinator.latestStreamEvents(threadId: thread.id) {
            timeline.apply(event)
        }
        XCTAssertNil(
            timeline.tokenSaverTranslationsByItemId["stream-item"],
            "a Human provider response must not inherit the user message's RCW1 toggle"
        )
        XCTAssertEqual(
            timeline.tokenSaverTranslationsByMessageId[runId.value.uuidString]?.wireRequestText,
            requestWire,
            "the exact admitted request remains inspectable on its owning user message"
        )
    }

    private func waitForAssistantMessage(
        _ messageRepo: AgentMessageRepository,
        threadId: AgentThreadID
    ) async throws -> AgentMessage {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let assistant = ((try? messageRepo.list(threadId: threadId)) ?? []).first(where: { $0.role == .assistant }) {
                return assistant
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for assistant message")
        throw XCTSkip("assistant message did not persist")
    }

    private func waitForWireTranslation(
        _ coordinator: AgentRunCoordinator,
        threadId: AgentThreadID,
        messageId: String
    ) async throws -> AssistantWireTranslation {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            for event in coordinator.latestStreamEvents(threadId: threadId) {
                if case .wireTranslation(let translation) = event,
                   translation.messageId == messageId {
                    return translation
                }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for persisted wire translation metadata")
        throw XCTSkip("wire translation metadata did not persist")
    }

    private func waitForDurableRCW1Response(
        _ messageRepo: AgentMessageRepository,
        threadId: AgentThreadID,
        messageId: AgentMessageID
    ) async throws -> AgentMessageRCW1Response {
        let values = try await waitForDurableRCW1Responses(
            messageRepo,
            threadId: threadId,
            messageIds: [messageId],
            expectedCount: 1
        )
        return try XCTUnwrap(values[messageId])
    }

    private func waitForDurableRCW1Responses(
        _ messageRepo: AgentMessageRepository,
        threadId: AgentThreadID,
        messageIds: [AgentMessageID],
        expectedCount: Int
    ) async throws -> [AgentMessageID: AgentMessageRCW1Response] {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let values = (try? messageRepo.rcw1ResponseTranslations(
                threadId: threadId,
                messageIds: messageIds
            )) ?? [:]
            if values.count == expectedCount { return values }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for durable RCW1 response metadata")
        throw XCTSkip("durable RCW1 response metadata did not persist")
    }
}

private final class BotSecretScopeTestState: @unchecked Sendable {
    private let lock = NSLock()
    private let botID: BotID

    init(botID: BotID) {
        self.botID = botID
    }

    func environment(provider: AgentProvider, threadId: AgentThreadID) -> [String: String] {
        lock.withLock {
            var environment = [
                "REMOTE_CODE_AGENT_PROVIDER": provider.rawValue,
                BotSecretEnvironment.botIDEnvironmentKey: botID.value.uuidString,
            ]
            environment["RC_TOKEN_SAVER_THREAD_ID"] = threadId.value.uuidString
            return environment
        }
    }
}

private final class FailingBotSecretStore: BotSecretStore, @unchecked Sendable {
    private func fail() throws -> Never { throw SyntheticProtectedStorageFailure() }

    func list(botID: BotID) throws -> [BotSecretMetadata] { try fail() }
    func save(botID: BotID, name: String, value: String) throws { try fail() }
    func load(botID: BotID, name: String) throws -> String? { try fail() }
    func delete(botID: BotID, name: String) throws { try fail() }
    func deleteAll(botID: BotID) throws { try fail() }
}

private struct SyntheticProtectedStorageFailure: Error {}
