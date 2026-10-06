import CryptoKit
import XCTest
import CoreModel
@testable import Persistence
@testable import AgentRuntime

final class AgentAutoRunCoordinatorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: AgentOrchestrationRuntime.rolloutFlagKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AgentOrchestrationRuntime.rolloutFlagKey)
        super.tearDown()
    }

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
        let manualProvider = eligibleProviders.first ?? .codex
        let manualModel = manualProvider == .distill ? "grok-4.6" : "gpt-5.6-sol"
        return AgentRoutingConfiguration(
            mode: .auto,
            manualSelection: AgentModelSelection(
                provider: manualProvider,
                modelId: manualModel,
                reasoningEffort: .medium,
                serviceTier: .fast
            ),
            manualProviderInstanceId: manualProvider == .distill ? "distill-live" : "codex-live",
            eligibleProviders: eligibleProviders,
            policyDigest: runtime.policyDigest,
            revision: 1
        )
    }

    private func request(
        threadId: AgentThreadID,
        runId: AgentRunID = AgentRunID(),
        model: String = "claude-manual",
        environment: [String: String] = [:]
    ) -> AgentRunRequest {
        AgentRunRequest(
            runId: runId,
            threadId: threadId,
            provider: .claude,
            providerInstanceId: "claude-manual",
            model: model,
            cwd: NSTemporaryDirectory(),
            prompt: "route this run",
            userMessageContent: "route this run",
            permissionMode: .supervised,
            reasoningEffort: .medium,
            serviceTier: .auto,
            interactionMode: .default,
            environment: environment
        )
    }

    func testManualRoutingPassesRequestThroughWithoutConsultingAutoDependencies() async throws {
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let supportedModel = "claude-sonnet-4-6"
        let thread = AgentThread(title: "manual", provider: .claude, model: supportedModel)
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
        let original = request(threadId: thread.id, model: supportedModel)

        _ = try await coordinator.startRun(original)

        let dispatched = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(dispatched.runId, original.runId)
        XCTAssertEqual(dispatched.threadId, original.threadId)
        XCTAssertEqual(dispatched.provider, original.provider)
        XCTAssertEqual(dispatched.providerInstanceId, original.providerInstanceId)
        XCTAssertEqual(dispatched.model, original.model)
        XCTAssertEqual(dispatched.cwd, original.cwd)
        XCTAssertEqual(dispatched.prompt, original.prompt)
        XCTAssertEqual(dispatched.userMessageContent, original.userMessageContent)
        XCTAssertEqual(dispatched.permissionMode, original.permissionMode)
        XCTAssertEqual(dispatched.reasoningEffort, original.reasoningEffort)
        XCTAssertEqual(dispatched.serviceTier, original.serviceTier)
        XCTAssertEqual(dispatched.interactionMode, original.interactionMode)
        XCTAssertEqual(
            dispatched.environment["RC_REMOTE_CODE_ROOT_RUN_ID"],
            original.runId.value.uuidString,
            "Every manual controller turn needs host-owned parent scope so nested provider workers attach to it."
        )
        XCTAssertEqual(
            dispatched.environment["RC_REMOTE_CODE_ATTEMPT_ID"],
            original.runId.value.uuidString
        )
        XCTAssertNotNil(
            dispatched.acceptancePermit,
            "The dispatched request must carry the coordinator's single-start acceptance permit."
        )
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
            killSwitch: { false },
            costEstimator: { _, usage in usage?.totalTokens }
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
        // Auto controller is always LIGHT (Codex matrix: gpt-5.6-luna / medium).
        XCTAssertEqual(admittedRequest.model, "gpt-5.6-luna")
        XCTAssertEqual(admittedRequest.reasoningEffort, .medium)
        XCTAssertEqual(admittedRequest.serviceTier, .auto)
        XCTAssertEqual(admittedRequest.userMessageContent, "route this run",
                       "user-visible transcript keeps the original message")
        XCTAssertTrue(
            AgentOrchestrationRuntime.promptAlreadyInvokesOrchestrateSkill(admittedRequest.prompt),
            "Auto must always invoke $remote-code-orchestrate"
        )
        XCTAssertTrue(admittedRequest.prompt.contains("route this run"))
        let receipt = try XCTUnwrap(receiptRepo.receipts().first)
        XCTAssertEqual(try receiptRepo.receipts().count, 1)
        XCTAssertEqual(receipt.runId, runId)
        XCTAssertEqual(receipt.threadId, thread.id)
        XCTAssertEqual(receipt.provider, .codex)
        XCTAssertEqual(receipt.model, "gpt-5.6-luna")
    }

    func testAutoRoutingToDistillKeepsOriginalPromptAndSkipsPromptTransforms() async throws {
        // WHY: Distill must receive native mode handling plus the human request, not
        // the Auto controller wrapper.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let receiptRepo = AgentOrchestrationRepository(db: db)
        let runtime = AgentOrchestrationRuntime(
            repository: receiptRepo,
            packageVerification: { true },
            killSwitch: { false },
            costEstimator: { _, usage in usage?.totalTokens }
        )
        let thread = AgentThread(
            title: "auto distill",
            provider: .claude,
            model: "claude-manual",
            routingConfiguration: autoConfiguration(runtime: runtime, eligibleProviders: [.distill])
        )
        try threadRepo.upsert(thread)
        let distill = RecordingProviderRunner(provider: .distill)
        let snapshot = liveSnapshot(
            provider: .distill,
            model: "grok-4.6",
            capabilities: AgentProviderCapabilities(supportsStreaming: true, supportsPlanReview: true)
        )
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            orchestrationRuntime: runtime,
            providerSnapshotSupplier: { [snapshot] in [snapshot] },
            providers: [.distill: distill]
        )
        let original = "Keep exact user wording; do not wrap this request."

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .claude,
            providerInstanceId: "claude-manual",
            model: "claude-manual",
            cwd: root,
            prompt: original,
            userMessageContent: original,
            interactionMode: .default
        ))

        let dispatched = try XCTUnwrap(distill.lastRequest)
        XCTAssertEqual(dispatched.provider, .distill)
        XCTAssertEqual(dispatched.prompt, original)
        XCTAssertEqual(dispatched.userMessageContent, original)
        XCTAssertEqual(dispatched.interactionMode, .default)
        XCTAssertFalse(AgentOrchestrationRuntime.promptAlreadyInvokesOrchestrateSkill(dispatched.prompt))
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
            killSwitch: { false },
            costEstimator: { _, usage in usage?.totalTokens }
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
        let runner = RecordingProviderRunner(provider: .codex, terminalStatus: .completed, terminalMessage: "done")
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
        XCTAssertEqual(receipt.qualityOutcome, "verified:output-present")
        XCTAssertEqual(try receiptRepo.receipts().count, 1)
    }

    func testMixedTokenUsageFinalizesReconciledReceiptAndLateCumulativeEnrichesIt() async throws {
        // WHY: Claude can emit independent request charges around a cumulative
        // snapshot, and providers can deliver a final cumulative usage receipt
        // after the run terminal. The durable receipt must reflect reconciled
        // growth without reopening or otherwise changing its terminal outcome.
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
            title: "mixed usage auto",
            provider: .claude,
            model: "claude-manual",
            routingConfiguration: autoConfiguration(runtime: runtime)
        )
        try threadRepo.upsert(thread)
        let runner = RecordingProviderRunner(provider: .codex)
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

        runner.emit(.event(.tokenUsage(.init(
            totalTokens: 40,
            semantics: .incremental
        ))))
        runner.emit(.event(.tokenUsage(.init(
            totalTokens: 50,
            semantics: .cumulative
        ))))
        runner.emit(.event(.tokenUsage(.init(
            totalTokens: 20,
            semantics: .incremental
        ))))
        runner.emit(.finished(
            .completed,
            finalMessage: "done",
            providerThreadId: nil
        ))

        let finalized = try XCTUnwrap(receiptRepo.receipt(runId: runId))
        let finalizedAt = try XCTUnwrap(finalized.finalizedAt)
        XCTAssertEqual(finalized.actualTokens, 60,
                       "40 + 20 incremental must win over the 50 cumulative snapshot")
        XCTAssertEqual(finalized.lifecycleStatus, .finalized)
        XCTAssertEqual(finalized.finalRunStatus, .completed)
        XCTAssertEqual(finalized.qualityOutcome, "verified:output-present")
        XCTAssertEqual(try receiptRepo.ledger().first?.tokenUsage, 60)

        runner.emit(.event(.tokenUsage(.init(
            totalTokens: 90,
            semantics: .cumulative
        ))))

        let enriched = try XCTUnwrap(receiptRepo.receipt(runId: runId))
        XCTAssertEqual(enriched.actualTokens, 90)
        XCTAssertEqual(enriched.lifecycleStatus, .finalized)
        XCTAssertEqual(enriched.finalRunStatus, .completed)
        XCTAssertEqual(enriched.qualityOutcome, "verified:output-present")
        XCTAssertEqual(enriched.finalizedAt, finalizedAt,
                       "usage correction must not rewrite the terminal timestamp")
        XCTAssertEqual(try receiptRepo.ledger().first?.tokenUsage, 90)
        XCTAssertEqual(try receiptRepo.ledger().count, 2,
                       "late positive growth is an append-only ledger correction")

        runner.emit(.event(.tokenUsage(.init(
            totalTokens: 80,
            semantics: .cumulative
        ))))
        XCTAssertEqual(try receiptRepo.receipt(runId: runId)?.actualTokens, 90)
        XCTAssertEqual(try receiptRepo.ledger().count, 2,
                       "a lower repeated snapshot must not create another correction")
    }

    func testLateCumulativeUsageRetriesAfterTransientReceiptPersistenceFailure() async throws {
        // WHY: a provider can report its authoritative usage after terminal
        // while the receipt ledger is briefly unwritable. The coordinator must
        // retain that snapshot and retry it; dropping it makes the durable
        // receipt permanently undercount the completed run.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let receiptURL = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("orchestration/receipts.jsonl")
        let receiptRepo = AgentOrchestrationRepository(auditLogURL: receiptURL)
        let runtime = AgentOrchestrationRuntime(
            repository: receiptRepo,
            packageVerification: { true },
            killSwitch: { false }
        )
        let thread = AgentThread(
            title: "late usage retry",
            provider: .claude,
            model: "claude-manual",
            routingConfiguration: autoConfiguration(runtime: runtime)
        )
        try threadRepo.upsert(thread)
        let runner = RecordingProviderRunner(provider: .codex)
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
        runner.emit(.event(.tokenUsage(.init(
            totalTokens: 60,
            semantics: .cumulative
        ))))
        runner.emit(.finished(
            .completed,
            finalMessage: "done",
            providerThreadId: nil
        ))

        let finalized = try XCTUnwrap(receiptRepo.receipt(runId: runId))
        let finalizedAt = try XCTUnwrap(finalized.finalizedAt)
        XCTAssertEqual(finalized.actualTokens, 60)
        XCTAssertEqual(try receiptRepo.ledger().count, 1)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: receiptURL.path
        )
        runner.emit(.event(.tokenUsage(.init(
            totalTokens: 90,
            semantics: .cumulative
        ))))
        XCTAssertEqual(try receiptRepo.receipt(runId: runId)?.actualTokens, 60,
                       "the injected write failure must happen before enrichment persists")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: receiptURL.path
        )

        for _ in 0..<50 {
            if try receiptRepo.receipt(runId: runId)?.actualTokens == 90 {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let corrected = try XCTUnwrap(receiptRepo.receipt(runId: runId))
        XCTAssertEqual(corrected.actualTokens, 90)
        XCTAssertEqual(corrected.lifecycleStatus, .finalized)
        XCTAssertEqual(corrected.finalRunStatus, .completed)
        XCTAssertEqual(corrected.finalizedAt, finalizedAt)
        XCTAssertEqual(try receiptRepo.ledger().count, 2)
        XCTAssertEqual(try receiptRepo.ledger().first?.tokenUsage, 90)

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(try receiptRepo.ledger().count, 2,
                       "a scheduled retry that already succeeded must not duplicate the correction")
    }

    func testTerminalReceiptFinalizationRetriesWithoutLosingUsage() async throws {
        // WHY: the run graph and orchestration receipt use separate durability
        // stores. A transient receipt failure after the run commits terminal
        // must not strand the receipt as accepted or discard the captured usage.
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let receiptURL = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("orchestration/finalization-retry.jsonl")
        let receiptRepo = AgentOrchestrationRepository(auditLogURL: receiptURL)
        let runtime = AgentOrchestrationRuntime(
            repository: receiptRepo,
            packageVerification: { true },
            killSwitch: { false }
        )
        let thread = AgentThread(
            title: "receipt finalization retry",
            provider: .claude,
            model: "claude-manual",
            routingConfiguration: autoConfiguration(runtime: runtime)
        )
        try threadRepo.upsert(thread)
        let runner = RecordingProviderRunner(provider: .codex)
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
        runner.emit(.event(.tokenUsage(.init(
            totalTokens: 60,
            semantics: .cumulative
        ))))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: receiptURL.path
        )
        runner.emit(.finished(
            .completed,
            finalMessage: "done",
            providerThreadId: nil
        ))
        XCTAssertEqual(try runRepo.get(id: runId)?.status, .completed)
        XCTAssertEqual(try receiptRepo.receipt(runId: runId)?.lifecycleStatus, .accepted)
        XCTAssertNil(try receiptRepo.receipt(runId: runId)?.actualTokens)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: receiptURL.path
        )

        for _ in 0..<50 {
            if try receiptRepo.receipt(runId: runId)?.lifecycleStatus == .finalized {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let finalized = try XCTUnwrap(receiptRepo.receipt(runId: runId))
        XCTAssertEqual(finalized.lifecycleStatus, .finalized)
        XCTAssertEqual(finalized.finalRunStatus, .completed)
        XCTAssertEqual(finalized.actualTokens, 60)
        XCTAssertEqual(finalized.qualityOutcome, "verified:output-present")
        XCTAssertNotNil(finalized.finalizedAt)
        XCTAssertEqual(try receiptRepo.ledger().count, 1)
        XCTAssertEqual(try receiptRepo.ledger().first?.tokenUsage, 60)

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(try receiptRepo.ledger().count, 1,
                       "successful retry must clear pending finalization exactly once")
    }

    func testAutoWrapsOnlyTheHumanPromptWithTheHostReceiptAcrossEveryProvider() async throws {
        // WHY: every provider must enter the orchestration skill with its exact
        // admitted host receipt, wrapping the human request once, while the
        // transcript keeps the human text.
        for provider in [AgentProvider.claude, .codex, .grok] {
            let (db, root) = try database()
            defer { try? FileManager.default.removeItem(atPath: root) }
            let threadRepo = AgentThreadRepository(db: db)
            let messageRepo = AgentMessageRepository(db: db)
            let runRepo = AgentRunRepository(db: db)
            let runtime = AgentOrchestrationRuntime(
                repository: AgentOrchestrationRepository(db: db),
                packageVerification: { true },
                killSwitch: { false }
            )
            let instanceID = "\(provider.rawValue)-live"
            let configuration = AgentRoutingConfiguration(
                mode: .auto,
                manualSelection: AgentModelSelection(
                    provider: provider,
                    modelId: "test-model",
                    reasoningEffort: .medium,
                    serviceTier: .auto
                ),
                manualProviderInstanceId: instanceID,
                eligibleProviders: [provider],
                policyDigest: runtime.policyDigest,
                revision: 1
            )
            let thread = AgentThread(
                title: "auto-wire-\(provider.rawValue)",
                provider: provider,
                model: "test-model",
                routingConfiguration: configuration
            )
            try threadRepo.upsert(thread)
            let runner = RecordingProviderRunner(provider: provider)
            let snapshot = liveSnapshot(provider: provider, model: "test-model")
            let coordinator = AgentRunCoordinator(
                runRepo: runRepo,
                messageRepo: messageRepo,
                threadRepo: threadRepo,
                orchestrationRuntime: runtime,
                providerSnapshotSupplier: { [snapshot] in [snapshot] },
                providers: [provider: runner]
            )
            let humanPrompt = "Analyze this detailed reliability report and propose the smallest safe fix."

            _ = try await coordinator.startRun(AgentRunRequest(
                threadId: thread.id,
                provider: provider,
                providerInstanceId: instanceID,
                model: "test-model",
                cwd: root,
                prompt: humanPrompt,
                userMessageContent: humanPrompt
            ))

            let dispatched = try XCTUnwrap(runner.lastRequest)
            XCTAssertTrue(dispatched.prompt.hasPrefix("$remote-code-orchestrate"),
                          "\(provider.rawValue) must enter the orchestration skill")
            XCTAssertTrue(dispatched.prompt.contains("- provider: \(provider.rawValue)"))
            XCTAssertTrue(dispatched.prompt.contains("- provider_instance_id: \(instanceID)"))
            XCTAssertEqual(dispatched.prompt.components(separatedBy: humanPrompt).count, 2,
                           "\(provider.rawValue) must carry the human request exactly once")
            XCTAssertEqual(dispatched.userMessageContent, humanPrompt,
                           "\(provider.rawValue) transcript must remain canonical human text")
        }
    }

    func testAutoDeadlineCancelsAnActiveProviderAndFinalizesItsReceipt() async throws {
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
        let configuration = autoConfiguration(runtime: runtime)
        let thread = AgentThread(
            title: "deadline auto",
            provider: .claude,
            model: "claude-manual",
            routingConfiguration: configuration
        )
        try threadRepo.upsert(thread)
        let runner = RecordingProviderRunner(provider: .codex)
        let snapshot = liveSnapshot()
        let runId = AgentRunID()
        let deadline = Date().addingTimeInterval(0.05)
        let routingSnapshot = AgentOrchestrationRoutingSnapshot(
            configuration: configuration,
            providerSnapshots: [snapshot],
            admissionSnapshot: AgentQueuedMessageRoutingSnapshot(
                configuration: configuration,
                deadlineAt: deadline
            )
        )
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            orchestrationRuntime: runtime,
            providerSnapshotSupplier: { [snapshot] in [snapshot] },
            providers: [.codex: runner]
        )

        _ = try await coordinator.startRun(
            request(threadId: thread.id, runId: runId),
            routingSnapshot: routingSnapshot
        )

        for _ in 0..<50 {
            if try runRepo.get(id: runId)?.status == .cancelled,
               try receiptRepo.receipt(runId: runId)?.lifecycleStatus == .finalized {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(try runRepo.get(id: runId)?.status, .cancelled)
        let receipt = try XCTUnwrap(receiptRepo.receipt(runId: runId))
        XCTAssertEqual(receipt.lifecycleStatus, .finalized)
        XCTAssertEqual(receipt.finalRunStatus, .cancelled)
        XCTAssertEqual(receipt.qualityOutcome, "not-verified:cancelled")
    }

    func testAutoRoutingBlocksBeforeProviderStartWhenPackageIsUnavailable() async throws {
        // Superseded semantics: package-unavailable no longer hard-blocks Auto. The
        // coordinator DEEP-falls-back on the SAME selected Source (codex) — never
        // cross-provider — dropping the $remote-code-orchestrate wrapper. Hard-block
        // coverage now lives in AgentOrchestrationRuntimeTests.
        try await assertSelectedSourceDeepStarts(
            runtime: AgentOrchestrationRuntime(
                packageVerification: { false },
                killSwitch: { false }
            )
        )
    }

    func testAutoRoutingBlocksBeforeProviderStartWhenKillSwitchIsEnabled() async throws {
        // Superseded semantics: the kill switch no longer hard-blocks Auto — same-host
        // DEEP fallback on the selected Source (codex), no orchestrate wrapper. Hard-block
        // coverage now lives in AgentOrchestrationRuntimeTests.
        try await assertSelectedSourceDeepStarts(
            runtime: AgentOrchestrationRuntime(
                packageVerification: { true },
                killSwitch: { true }
            )
        )
    }

    func testAutoRoutingBlocksUnknownStreamingCapabilityBeforeProviderStart() async throws {
        let error = try await autoAdmissionError(
            runtime: AgentOrchestrationRuntime(
                packageVerification: { true },
                killSwitch: { false }
            ),
            snapshots: [liveSnapshot(capabilities: .conservative)]
        )
        // The selected Source (codex) is present but cannot stream → fail closed on
        // that Source; Auto must never silently route to another provider.
        guard case .preferredSourceUnavailable(let provider, _)? = error else {
            return XCTFail("Expected preferredSourceUnavailable, got \(String(describing: error))")
        }
        XCTAssertEqual(provider, .codex)
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

        // Auto binds to the selected Source (codex). With no runnable codex snapshot it
        // fails closed on that Source — it must never fall back to the manual provider
        // or any other host.
        guard case .preferredSourceUnavailable(let provider, _)? = error else {
            return XCTFail("Expected preferredSourceUnavailable, got \(String(describing: error))")
        }
        XCTAssertEqual(provider, .codex)
    }

    /// DEEP fallback: when orchestration is gated (package unavailable / kill switch)
    /// Auto still starts the SELECTED Source host (codex) on its DEEP matrix row,
    /// without the `$remote-code-orchestrate` wrapper, and never switches provider.
    private func assertSelectedSourceDeepStarts(
        runtime: AgentOrchestrationRuntime
    ) async throws {
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(
            title: "deep fallback auto",
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

        XCTAssertEqual(claude.startCount, 0,
                       "DEEP fallback must stay on the selected Source, never cross-provider.")
        XCTAssertEqual(codex.startCount, 1,
                       "DEEP fallback still starts the selected Source host.")
        let admitted = try XCTUnwrap(codex.lastRequest)
        XCTAssertEqual(admitted.runId, runId)
        XCTAssertEqual(admitted.provider, .codex)
        XCTAssertEqual(admitted.providerInstanceId, "codex-live")
        // Codex DEEP row is sol / high (LIGHT orchestration would be luna / medium).
        XCTAssertEqual(admitted.model, "gpt-5.6-sol")
        XCTAssertEqual(admitted.reasoningEffort, .high)
        XCTAssertFalse(
            AgentOrchestrationRuntime.promptAlreadyInvokesOrchestrateSkill(admitted.prompt),
            "DEEP fallback drops the $remote-code-orchestrate wrapper."
        )
        XCTAssertTrue(admitted.prompt.contains("route this run"))
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
    private var eventSink: (@Sendable (AgentRunEvent) -> Void)?
    private let terminalStatus: AgentRunStatus?
    private let terminalMessage: String?

    init(
        provider: AgentProvider,
        terminalStatus: AgentRunStatus? = nil,
        terminalMessage: String? = nil
    ) {
        self.provider = provider
        self.terminalStatus = terminalStatus
        self.terminalMessage = terminalMessage
    }

    var startCount: Int {
        lock.withLock { requests.count }
    }

    var lastRequest: AgentRunRequest? {
        lock.withLock { requests.last }
    }

    func emit(_ event: AgentRunEvent) {
        lock.withLock { eventSink }?(event)
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        lock.withLock {
            requests.append(request)
            eventSink = onEvent
        }
        if let terminalStatus {
            onEvent(.finished(terminalStatus, finalMessage: terminalMessage, providerThreadId: nil))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}
