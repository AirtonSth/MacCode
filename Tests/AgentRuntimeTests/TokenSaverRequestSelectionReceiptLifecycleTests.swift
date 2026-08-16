import CryptoKit
import XCTest
@testable import AgentRuntime
@testable import CoreModel
@testable import Persistence

/// Honest post-send receipt lifecycle. Persistence happens atomically with the
/// pending agent_run before sendTurn; delivery state never comes from the
/// outbound-delivery callback.
final class TokenSaverRequestSelectionReceiptLifecycleTests: XCTestCase {
    func test_acceptedSendTurnPersistsDeliveredReceiptBeforeAndAfterProviderWrite() async throws {
        let harness = try C10ReceiptHarness.make(title: "delivered", acceptance: .accepted)
        harness.injectScopedRCW1()
        let decision = await C10ReceiptArms().decision(.rcw1)
        harness.select { _ in decision }
        let runID = try await harness.start(C10ReceiptArms.human)
        XCTAssertTrue(harness.adapter.sendTurnEntered)
        XCTAssertEqual(harness.adapter.lifecycleDuringSendTurn, .provisional)
        XCTAssertNotNil(harness.adapter.runDuringSendTurn)
        let stored = try XCTUnwrap(harness.receipts.load(runId: runID))
        XCTAssertEqual(stored.winner.lifecycle, .delivered)
        XCTAssertEqual(stored.winner.selectedFormat, .rcw1)
        XCTAssertEqual(stored.arms.count, 3)
        XCTAssertEqual(try XCTUnwrap(stored.arm(.rcs1)).availability, .unavailable)
        XCTAssertNil(try XCTUnwrap(stored.arm(.rcs1)).provenEffectiveCount)
        XCTAssertEqual(try harness.savingsCount(), 0)
    }

    func test_claimFailureAfterReceiptCommitIsNotDelivered() async throws {
        let harness = try C10ReceiptHarness.make(title: "not-delivered")
        harness.select { _ in await C10ReceiptArms().decision(.human) }
        harness.coordinator.onRunPrepared = { request, _ in
            harness.coordinator.cancelPreparation(threadId: request.threadId)
        }
        let runID = AgentRunID()
        do {
            _ = try await harness.start(C10ReceiptArms.human, runID: runID)
            XCTFail("claim failure must fail closed before sendTurn")
        } catch {
            XCTAssertTrue(error is AgentRunAcceptanceError)
        }
        XCTAssertFalse(harness.adapter.sendTurnEntered)
        XCTAssertEqual(try harness.receipts.load(runId: runID)?.winner.lifecycle, .notDelivered)
        XCTAssertEqual(try harness.savingsCount(), 0)
    }

    func test_sendTurnWriteFailureAndPermitlessAdapterAreDeliveryUnknown() async throws {
        let failed = try C10ReceiptHarness.make(title: "write-fail", acceptance: .unknown)
        failed.select { _ in await C10ReceiptArms().decision(.human) }
        let failedID = try await failed.start(C10ReceiptArms.human)
        XCTAssertTrue(failed.adapter.sendTurnEntered)
        XCTAssertEqual(try failed.receipts.load(runId: failedID)?.winner.lifecycle, .deliveryUnknown)

        let permitless = try C10ReceiptHarness.make(title: "permitless", acceptance: .accepted)
        permitless.adapter.dropPermit = true
        permitless.select { _ in await C10ReceiptArms().decision(.rcw1) }
        let permitlessID = try await permitless.start(C10ReceiptArms.human)
        XCTAssertTrue(permitless.adapter.sendTurnEntered)
        XCTAssertEqual(try permitless.receipts.load(runId: permitlessID)?.winner.lifecycle, .deliveryUnknown)
    }

    func test_persistFailureFailsClosedBeforeSendTurn() async throws {
        let harness = try C10ReceiptHarness.make(title: "persist-fail")
        try harness.db.execute("""
            CREATE TRIGGER fail_c10_winner_insert
            BEFORE INSERT ON token_saver_run_winner_receipts
            BEGIN
                SELECT RAISE(ABORT, 'injected winner persist failure');
            END;
            """)
        harness.select { _ in await C10ReceiptArms().decision(.human) }
        let runID = AgentRunID()
        do {
            _ = try await harness.start(C10ReceiptArms.human, runID: runID)
            XCTFail("persist failure must fail closed before sendTurn")
        } catch {
            XCTAssertFalse(error is AgentRunAcceptanceError)
        }
        XCTAssertFalse(harness.adapter.sendTurnEntered)
        XCTAssertNil(try harness.receipts.load(runId: runID))
        XCTAssertNil(try harness.runs.get(id: runID))
    }

    func test_unsetSelectorRequiresNoReceipt() async throws {
        let harness = try C10ReceiptHarness.make(title: "legacy")
        let runID = try await harness.start(C10ReceiptArms.human)
        XCTAssertNil(try harness.receipts.load(runId: runID))
        XCTAssertNotNil(try harness.runs.get(id: runID))
        XCTAssertEqual(try harness.savingsCount(), 0)
    }

    func test_rcs1DecisionIsNeitherSentNorPersistedAsSelected() async throws {
        let harness = try C10ReceiptHarness.make(title: "no-rcs1")
        let decision = await C10ReceiptArms().decision(.rcs1)
        XCTAssertEqual(decision.selectedFormat, .rcs1)
        harness.select { _ in decision }
        let runID = try await harness.start(C10ReceiptArms.human)
        XCTAssertEqual(harness.adapter.request?.prompt, C10ReceiptArms.human)
        let stored = try XCTUnwrap(harness.receipts.load(runId: runID))
        XCTAssertEqual(stored.winner.selectedFormat, .human)
        XCTAssertEqual(stored.winner.reason, .candidateError)
        XCTAssertEqual(try XCTUnwrap(stored.arm(.rcs1)).producerId,
                       TokenSaverRequestSelectionReceipt.rcs1UnavailableProducerID)
        XCTAssertNil(try XCTUnwrap(stored.arm(.rcs1)).provenEffectiveCount)
    }

    func test_relaunchSweepMarksLeftoverProvisionalUnknownAndLeavesDelivered() async throws {
        let harness = try C10ReceiptHarness.make(title: "relaunch")
        let leftoverRun = AgentRun(
            threadId: harness.thread.id,
            provider: .codex,
            model: "fake-model",
            status: .pending
        )
        let leftover = TokenSaverRequestSelectionReceipt.project(
            decision: await C10ReceiptArms().decision(.human),
            runId: leftoverRun.id.value.uuidString,
            threadId: harness.thread.id.value.uuidString,
            provider: "codex",
            resolvedModel: "fake-model"
        )
        try harness.receipts.persistPendingRun(leftoverRun, record: leftover)
        harness.select { _ in await C10ReceiptArms().decision(.rcw1) }
        let deliveredID = try await harness.start(C10ReceiptArms.human)
        try harness.coordinator.reconcileOnLaunch()
        XCTAssertEqual(try harness.receipts.load(runId: leftoverRun.id)?.winner.lifecycle, .deliveryUnknown)
        XCTAssertEqual(try harness.receipts.load(runId: deliveredID)?.winner.lifecycle, .delivered)
    }

    func test_deliveryCallbackIsNotThePersistSeam() async throws {
        let harness = try C10ReceiptHarness.make(title: "callback-not-persist")
        let receipts = harness.receipts
        let sawRow = CallbackFlag()
        harness.select { _ in await C10ReceiptArms().decision(.human) }
        harness.coordinator.onTokenSaverOutboundDelivery = { delivery in
            sawRow.value = (try? receipts.load(runId: delivery.runId)) != nil
        }
        let runID = try await harness.start(C10ReceiptArms.human)
        XCTAssertTrue(sawRow.value, "receipt must already exist before the observation callback")
        XCTAssertEqual(try harness.receipts.load(runId: runID)?.winner.lifecycle, .delivered)
    }
}

private final class CallbackFlag: @unchecked Sendable {
    var value = false
}

private enum C10PromptAcceptance { case accepted, unknown }

private final class C10ReceiptAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider = .codex
    var dropPermit = false
    private let lock = NSLock()
    private let acceptance: C10PromptAcceptance
    private let receipts: TokenSaverRequestSelectionReceiptRepository
    private let runs: AgentRunRepository
    private var _request: AgentRunRequest?
    private(set) var sendTurnEntered = false
    private(set) var lifecycleDuringSendTurn: TokenSaverRequestSelectionReceipt.Lifecycle?
    private(set) var runDuringSendTurn: AgentRun?

    init(
        acceptance: C10PromptAcceptance,
        receipts: TokenSaverRequestSelectionReceiptRepository,
        runs: AgentRunRepository
    ) {
        self.acceptance = acceptance
        self.receipts = receipts
        self.runs = runs
    }

    var request: AgentRunRequest? { lock.withLock { _request } }

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
        sendTurnEntered = true
        runDuringSendTurn = try runs.get(id: request.runId)
        lifecycleDuringSendTurn = try receipts.load(runId: request.runId)?.winner.lifecycle
        let capture = { self.lock.withLock { self._request = request } }
        let permit = dropPermit ? nil : request.acceptancePermit
        switch (acceptance, permit) {
        case (.accepted, let permit?):
            try permit.withAcceptance(capture)
        case (.unknown, let permit?):
            do {
                try permit.withAcceptance {
                    capture()
                    throw NSError(domain: "C10Receipt", code: 1)
                }
            } catch {
                if (error as NSError).domain != "C10Receipt" { throw error }
            }
        default:
            capture()
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }

    func interruptTurn(threadId: AgentThreadID) throws {}
    func respondToRequest(
        threadId: AgentThreadID,
        requestId: String,
        response: AgentProviderRequestResponse
    ) async throws {}
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {}
    func stopSession(threadId: AgentThreadID) throws {}
    func recoverSession(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] { [] }
    func hasSession(threadId: AgentThreadID) -> Bool { false }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func streamEvents(
        threadId: AgentThreadID,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) throws {}
}

private struct C10ReceiptHarness {
    let root: String
    let db: SQLiteDB
    let coordinator: AgentRunCoordinator
    let adapter: C10ReceiptAdapter
    let receipts: TokenSaverRequestSelectionReceiptRepository
    let runs: AgentRunRepository
    let thread: AgentThread

    static func make(
        title: String,
        acceptance: C10PromptAcceptance = .accepted
    ) throws -> C10ReceiptHarness {
        let root = NSTemporaryDirectory() + "rc2-c10-receipt-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        let threads = AgentThreadRepository(db: db)
        let messages = AgentMessageRepository(db: db)
        let runs = AgentRunRepository(db: db)
        let sessions = ProviderSessionRuntimeRepository(db: db)
        let receipts = TokenSaverRequestSelectionReceiptRepository(db: db)
        let thread = AgentThread(title: title, provider: .codex, model: "fake-model")
        try threads.upsert(thread)
        let adapter = C10ReceiptAdapter(acceptance: acceptance, receipts: receipts, runs: runs)
        let coordinator = AgentRunCoordinator(
            runRepo: runs,
            messageRepo: messages,
            threadRepo: threads,
            providerSessionRepo: sessions,
            providerAdapters: [.codex: adapter]
        )
        return C10ReceiptHarness(
            root: root,
            db: db,
            coordinator: coordinator,
            adapter: adapter,
            receipts: receipts,
            runs: runs,
            thread: thread
        )
    }

    func injectScopedRCW1() {
        coordinator.runEnvironmentProvider = { _, _, base in
            var env = base
            env[TokenSaverExecutionReceiptSeam.wireCapabilityEnvKey] = "1"
            env["RC_TOKEN_SAVER_WIRE_VERSION"] = "1"
            return env
        }
    }

    func select(
        _ body: @escaping @Sendable (TokenSaverOutboundSelectionRequest) async -> TokenSaverBestOfThreeSelector.Decision
    ) {
        coordinator.tokenSaverOutboundSelector = { request in
            await body(request)
        }
    }

    func start(_ prompt: String, runID: AgentRunID = AgentRunID()) async throws -> AgentRunID {
        _ = try await coordinator.startRun(.init(
            runId: runID,
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: root,
            prompt: prompt
        ))
        return runID
    }

    func savingsCount() throws -> Int {
        let statement = try db.prepare("SELECT COUNT(*) FROM token_saver_savings;")
        defer { statement.reset() }
        guard try statement.step() else { return 0 }
        return Int(statement.columnInt64(0))
    }
}

private struct C10ReceiptArms {
    static let human = "Canonical Human request stays visible."
    let rcwOutbound = "RCW1\tQ\t1\nG\tRuntime request\nX\t[[rc:rcv1.runtime]]\n.\n"
    let rcs1Outbound = "RCS1 Runtime request [[rc:rcs1.runtime]]"

    enum Winner { case human, rcw1, rcs1 }

    func decision(_ winner: Winner) async -> TokenSaverBestOfThreeSelector.Decision {
        let human = Self.human
        let rcwABI = "RCW1 ABI"
        let rcs1ABI = "RCS1 ABI"
        let humanEnv = "BASE ABI\n\(human)"
        let rcwEnv = "\(rcwABI)\n\(rcwOutbound)"
        let rcs1Env = "\(rcs1ABI)\n\(rcs1Outbound)"
        let envelopes: (Int, Int, Int)
        switch winner {
        case .rcw1: envelopes = (110, 30, 60)
        case .rcs1: envelopes = (110, 90, 30)
        case .human: envelopes = (25, 50, 55)
        }
        let source = SHA256.hash(data: Data(human.utf8)).map { String(format: "%02x", $0) }.joined()
        func arm(
            _ format: TokenSaverBestOfThreeSelector.Format,
            payload: String,
            abi: String,
            envelope: String,
            handle: String
        ) -> TokenSaverBestOfThreeSelector.Candidate {
            .init(
                format: format,
                sourceSHA256: source,
                payload: payload,
                abi: abi,
                effectiveEnvelope: envelope,
                handle: handle,
                producerID: format == .rcw1 ? "remotecode-rcw1" : "remotecode-rcs1",
                producerRevision: "1",
                abiRevision: "1",
                generation: .passed,
                structural: .passed,
                semantic: .passed,
                recovery: .passed
            )
        }
        let counts = [
            human: envelopes.0 - 10, humanEnv: envelopes.0,
            rcwOutbound: 20, "rcv1.runtime": 4, rcwABI: 5, rcwEnv: envelopes.1,
            rcs1Outbound: 20, "rcs1.runtime": 4, rcs1ABI: 5, rcs1Env: envelopes.2,
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
            candidates: [
                arm(.rcw1, payload: rcwOutbound, abi: rcwABI, envelope: rcwEnv, handle: "rcv1.runtime"),
                arm(.rcs1, payload: rcs1Outbound, abi: rcs1ABI, envelope: rcs1Env, handle: "rcs1.runtime"),
            ],
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
}
