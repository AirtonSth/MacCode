import XCTest
import CoreModel
@testable import Persistence
@testable import AgentRuntime

final class AgentAutoRunCoordinatorTests: XCTestCase {
    private func database() throws -> (SQLiteDB, String) {
        let root = NSTemporaryDirectory() + "rc-auto-run-coordinator-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        return (db, root)
    }

    private func liveSnapshot(
        provider: AgentProvider = .codex,
        model: String = "gpt-5.6-sol",
        capabilities: AgentProviderCapabilities = AgentProviderCapabilities(supportsStreaming: true)
    ) -> AgentProviderSnapshot {
        AgentProviderSnapshotFactory.snapshot(
            provider: provider,
            models: [AgentModelDescriptor(
                id: model,
                label: model,
                provider: provider,
                supportsReasoning: true,
                supportedReasoningEfforts: [.high],
                supportsServiceTier: true
            )],
            binaryPath: "/usr/bin/true",
            authenticated: true,
            id: "\(provider.rawValue)-live",
            capabilitiesOverride: capabilities,
            modelDiscoverySource: .live
        )
    }

    private func autoConfiguration(
        runtime: AgentOrchestrationRuntime,
        eligibleProviders: [AgentProvider] = [.codex]
    ) -> AgentRoutingConfiguration {
        AgentRoutingConfiguration(
            mode: .auto,
            manualSelection: AgentModelSelection(
                provider: .claude,
                modelId: "claude-manual",
                reasoningEffort: .medium,
                serviceTier: .fast
            ),
            manualProviderInstanceId: "claude-manual",
            eligibleProviders: eligibleProviders,
            policyDigest: runtime.policyDigest,
            revision: 1
        )
    }

    private func request(threadId: AgentThreadID, runId: AgentRunID = AgentRunID()) -> AgentRunRequest {
        AgentRunRequest(
            runId: runId,
            threadId: threadId,
            provider: .claude,
            providerInstanceId: "claude-manual",
            model: "claude-manual",
            cwd: NSTemporaryDirectory(),
            prompt: "route this run",
            userMessageContent: "route this run",
            permissionMode: .supervised,
            reasoningEffort: .medium,
            serviceTier: .auto,
            interactionMode: .default
        )
    }

    func testManualRoutingPassesRequestThroughWithoutConsultingAutoDependencies() async throws {
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "manual", provider: .claude, model: "claude-manual")
        try threadRepo.upsert(thread)
        let runner = RecordingProviderRunner(provider: .claude)
        let supplier = SnapshotSupplierProbe(snapshots: [])
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            orchestrationRuntime: AgentOrchestrationRuntime(
                packageVerification: { false },
                killSwitch: { true }
            ),
            providerSnapshotSupplier: { try supplier.load() },
            providers: [.claude: runner]
        )
        let original = request(threadId: thread.id)

        _ = try await coordinator.startRun(original)

        XCTAssertEqual(runner.lastRequest, original,
                       "Manual routing must preserve the existing coordinator request contract byte-for-byte.")
        XCTAssertEqual(supplier.loadCount, 0,
                       "Manual runs must not consult Auto routing dependencies.")
    }

    func testAutoRoutingAdmitsAndDispatchesTheReturnedRouteWithTheOriginalRunIdentity() async throws {
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let receiptRepo = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: receiptRepo,
            packageVerification: { true },
            killSwitch: { false }
        )
        let thread = AgentThread(
            title: "auto",
            provider: .claude,
            model: "claude-manual",
            routingConfiguration: autoConfiguration(runtime: runtime)
        )
        try threadRepo.upsert(thread)
        let claude = RecordingProviderRunner(provider: .claude)
        let codex = RecordingProviderRunner(provider: .codex)
        let snapshot = liveSnapshot()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            orchestrationRuntime: runtime,
            providerSnapshotSupplier: { [snapshot] in [snapshot] },
            providers: [.claude: claude, .codex: codex]
        )
        let runId = AgentRunID()

        _ = try await coordinator.startRun(request(threadId: thread.id, runId: runId))

        XCTAssertEqual(claude.startCount, 0)
        XCTAssertEqual(codex.startCount, 1)
        let admittedRequest = try XCTUnwrap(codex.lastRequest)
        XCTAssertEqual(admittedRequest.runId, runId)
        XCTAssertEqual(admittedRequest.threadId, thread.id)
        XCTAssertEqual(admittedRequest.provider, .codex)
        XCTAssertEqual(admittedRequest.providerInstanceId, "codex-live")
        XCTAssertEqual(admittedRequest.model, "gpt-5.6-sol")
        XCTAssertEqual(admittedRequest.reasoningEffort, .high)
        XCTAssertEqual(admittedRequest.serviceTier, .fast)
        let receipt = try XCTUnwrap(receiptRepo.receipts().first)
        XCTAssertEqual(try receiptRepo.receipts().count, 1)
        XCTAssertEqual(receipt.runId, runId)
        XCTAssertEqual(receipt.threadId, thread.id)
        XCTAssertEqual(receipt.provider, .codex)
        XCTAssertEqual(receipt.model, "gpt-5.6-sol")
    }

    func testImmutableRoutingSnapshotPreventsTOCTOUAndUsesAdmittedProviderLaunchEnvironment() async throws {
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let receiptRepo = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: receiptRepo,
            packageVerification: { true },
            killSwitch: { false }
        )
        let immutableConfiguration = autoConfiguration(runtime: runtime, eligibleProviders: [.codex])
        var thread = AgentThread(
            title: "queued auto",
            provider: .claude,
            model: "claude-manual",
            routingConfiguration: immutableConfiguration
        )
        try threadRepo.upsert(thread)
        let codexSnapshot = liveSnapshot()
        let supplier = SnapshotSupplierProbe(snapshots: [liveSnapshot(provider: .claude, model: "claude-live")])
        let claude = RecordingProviderRunner(provider: .claude)
        let codex = RecordingProviderRunner(provider: .codex)
        let admissionReceiptID = UUID()
        let queuedDeadline = Date(timeIntervalSince1970: 4_102_444_800)
        let admissionSnapshot = AgentQueuedMessageRoutingSnapshot(
            configuration: immutableConfiguration,
            deadlineAt: queuedDeadline,
            budgetTokens: 900,
            budgetCostMicros: 42,
            reservationId: "queue-reservation",
            reservedTokens: 700,
            reservedCostMicros: 35,
            admissionReceiptId: admissionReceiptID
        )
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            orchestrationRuntime: runtime,
            providerSnapshotSupplier: { try supplier.load() },
            providers: [.claude: claude, .codex: codex]
        )
        let routingSnapshot = AgentOrchestrationRoutingSnapshot(
            configuration: immutableConfiguration,
            providerSnapshots: [codexSnapshot],
            launchConfigurations: [
                codexSnapshot.id: AgentOrchestrationLaunchConfiguration(
                    binary: "/verified/codex",
                    environment: ["ROUTE_OWNER": "codex"]
                )
            ],
            admissionSnapshot: admissionSnapshot
        )

        thread.routingConfiguration = autoConfiguration(runtime: runtime, eligibleProviders: [.claude])
        try threadRepo.upsert(thread)
        let runId = AgentRunID()
        _ = try await coordinator.startRun(
            request(threadId: thread.id, runId: runId),
            routingSnapshot: routingSnapshot
        )

        XCTAssertEqual(supplier.loadCount, 0,
                       "A supplied queued snapshot must prevent a second catalog/configuration read.")
        XCTAssertEqual(claude.startCount, 0)
        XCTAssertEqual(codex.startCount, 1)
        XCTAssertEqual(codex.lastRequest?.providerBinary, "/verified/codex")
        XCTAssertEqual(codex.lastRequest?.environment["ROUTE_OWNER"], "codex")
        let receipt = try XCTUnwrap(receiptRepo.receipt(runId: runId))
        XCTAssertEqual(receipt.id, admissionReceiptID,
                       "queued admission must reuse its immutable receipt identity")
        XCTAssertEqual(receipt.deadlineAt, admissionSnapshot.deadlineAt)
        XCTAssertEqual(receipt.budgetTokens, admissionSnapshot.budgetTokens)
        XCTAssertEqual(receipt.budgetCostMicros, admissionSnapshot.budgetCostMicros)
        XCTAssertEqual(receipt.reservationId, admissionSnapshot.reservationId)
        XCTAssertEqual(receipt.reservedTokens, admissionSnapshot.reservedTokens)
        XCTAssertEqual(receipt.reservedCostMicros, admissionSnapshot.reservedCostMicros)
        XCTAssertEqual(try receiptRepo.receipts().count, 1,
                       "The coordinator must create exactly one admission receipt for the run.")
    }

    func testTerminalRunFinalizesTheSameAdmissionReceipt() async throws {
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let receiptRepo = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: receiptRepo,
            packageVerification: { true },
            killSwitch: { false }
        )
        let thread = AgentThread(
            title: "terminal auto",
            provider: .claude,
            model: "claude-manual",
            routingConfiguration: autoConfiguration(runtime: runtime)
        )
        try threadRepo.upsert(thread)
        let runner = RecordingProviderRunner(provider: .codex, terminalStatus: .completed)
        let snapshot = liveSnapshot()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            orchestrationRuntime: runtime,
            providerSnapshotSupplier: { [snapshot] in [snapshot] },
            providers: [.codex: runner]
        )
        let runId = AgentRunID()

        _ = try await coordinator.startRun(request(threadId: thread.id, runId: runId))

        let receipt = try XCTUnwrap(receiptRepo.receipt(runId: runId))
        XCTAssertEqual(receipt.lifecycleStatus, .finalized)
        XCTAssertEqual(receipt.finalRunStatus, .completed)
        XCTAssertEqual(try receiptRepo.receipts().count, 1)
    }

    func testAutoRoutingBlocksBeforeProviderStartWhenPackageIsUnavailable() async throws {
        try await assertAutoAdmissionBlocked(
            runtime: AgentOrchestrationRuntime(
                packageVerification: { false },
                killSwitch: { false }
            ),
            snapshots: [liveSnapshot()],
            expectedError: .packageUnavailable
        )
    }

    func testAutoRoutingBlocksBeforeProviderStartWhenKillSwitchIsEnabled() async throws {
        try await assertAutoAdmissionBlocked(
            runtime: AgentOrchestrationRuntime(
                packageVerification: { true },
                killSwitch: { true }
            ),
            snapshots: [liveSnapshot()],
            expectedError: .killSwitchEnabled
        )
    }

    func testAutoRoutingBlocksUnknownStreamingCapabilityBeforeProviderStart() async throws {
        try await assertAutoAdmissionBlocked(
            runtime: AgentOrchestrationRuntime(
                packageVerification: { true },
                killSwitch: { false }
            ),
            snapshots: [liveSnapshot(capabilities: .conservative)],
            expectedError: .noEligibleProvider
        )
    }

    func testAutoRoutingBlocksWhenReceiptCannotBePersisted() async throws {
        let runtime = AgentOrchestrationRuntime(
            repository: AgentOrchestrationRepository(
                auditLogURL: URL(fileURLWithPath: "/dev/null/admission-receipts.jsonl")
            ),
            packageVerification: { true },
            killSwitch: { false }
        )
        let error = try await autoAdmissionError(runtime: runtime, snapshots: [liveSnapshot()])

        guard case .receiptPersistenceFailed? = error else {
            return XCTFail("Expected receiptPersistenceFailed, got \(String(describing: error))")
        }
    }

    func testAutoRoutingNeverFallsBackToTheManualProviderWhenNoRouteIsAdmitted() async throws {
        let runtime = AgentOrchestrationRuntime(
            packageVerification: { true },
            killSwitch: { false }
        )
        let error = try await autoAdmissionError(runtime: runtime, snapshots: [])

        XCTAssertEqual(try XCTUnwrap(error), .noEligibleProvider)
    }

    private func assertAutoAdmissionBlocked(
        runtime: AgentOrchestrationRuntime,
        snapshots: [AgentProviderSnapshot],
        expectedError: AgentOrchestrationAdmissionError
    ) async throws {
        let error = try await autoAdmissionError(runtime: runtime, snapshots: snapshots)
        XCTAssertEqual(try XCTUnwrap(error), expectedError)
    }

    private func autoAdmissionError(
        runtime: AgentOrchestrationRuntime,
        snapshots: [AgentProviderSnapshot]
    ) async throws -> AgentOrchestrationAdmissionError? {
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(
            title: "blocked auto",
            provider: .claude,
            model: "claude-manual",
            routingConfiguration: autoConfiguration(runtime: runtime)
        )
        try threadRepo.upsert(thread)
        let claude = RecordingProviderRunner(provider: .claude)
        let codex = RecordingProviderRunner(provider: .codex)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            orchestrationRuntime: runtime,
            providerSnapshotSupplier: { snapshots },
            providers: [.claude: claude, .codex: codex]
        )
        let runId = AgentRunID()

        do {
            _ = try await coordinator.startRun(request(threadId: thread.id, runId: runId))
            XCTFail("Auto admission failure must not start any provider.")
            return nil
        } catch {
            XCTAssertEqual(claude.startCount, 0,
                           "A rejected Auto run must not fall back to the manual provider.")
            XCTAssertEqual(codex.startCount, 0,
                           "A rejected Auto run must not start the candidate provider.")
            XCTAssertNil(try runRepo.get(id: runId),
                         "Admission must fail before the run graph is persisted as started.")
            return error as? AgentOrchestrationAdmissionError
        }
    }
}

private final class SnapshotSupplierProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let snapshots: [AgentProviderSnapshot]
    private var count = 0

    init(snapshots: [AgentProviderSnapshot]) {
        self.snapshots = snapshots
    }

    var loadCount: Int {
        lock.withLock { count }
    }

    func load() throws -> [AgentProviderSnapshot] {
        lock.withLock { count += 1 }
        return snapshots
    }
}

private final class RecordingProviderRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private var requests: [AgentRunRequest] = []
    private let terminalStatus: AgentRunStatus?

    init(provider: AgentProvider, terminalStatus: AgentRunStatus? = nil) {
        self.provider = provider
        self.terminalStatus = terminalStatus
    }

    var startCount: Int {
        lock.withLock { requests.count }
    }

    var lastRequest: AgentRunRequest? {
        lock.withLock { requests.last }
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        lock.withLock { requests.append(request) }
        if let terminalStatus {
            onEvent(.finished(terminalStatus, finalMessage: nil, providerThreadId: nil))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}
