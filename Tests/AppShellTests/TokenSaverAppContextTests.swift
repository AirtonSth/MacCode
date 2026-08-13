import XCTest
import AppKit
import CryptoKit
import CoreModel
@testable import AgentRuntime
import DistillCore
import Persistence
import SocketServer
@testable import AppShell

@MainActor
final class TokenSaverAppContextTests: XCTestCase {
    func testAppContextPayloadCompressorDispatchesAutoWithSeparateUserAndHostLegs() async throws {
        // WHY: the production AppContext hook must be exercised by the Auto
        // coordinator itself. A compressor closure that simply returns a
        // precomputed wire cannot prove the three-command user contract or the
        // separate host instruction at the provider dispatch boundary.
        let appSupport = NSTemporaryDirectory() + "RC2AutoPayloadIntegration-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update {
            $0.tokenSaverEnabled = true
            $0.sessionLearnEnabled = true
        }

        let runtime = AgentOrchestrationRuntime(
            repository: AgentOrchestrationRepository(db: context.db),
            packageVerification: { true },
            rolloutGate: { true },
            killSwitch: { false },
            costEstimator: { _, usage in usage?.totalTokens }
        )
        let configuration = AgentRoutingConfiguration(
            mode: .auto,
            manualSelection: AgentModelSelection(
                provider: .codex,
                modelId: "gpt-5.6-sol",
                reasoningEffort: .medium,
                serviceTier: .fast
            ),
            manualProviderInstanceId: "codex-live",
            eligibleProviders: [.codex],
            policyDigest: runtime.policyDigest,
            revision: 1
        )
        let thread = AgentThread(
            projectId: ProjectID(),
            workspaceId: WorkspaceID(),
            title: "auto payload integration",
            provider: .claude,
            model: "claude-manual",
            routingConfiguration: configuration
        )
        try context.threadRepo.upsert(thread)
        try admitTokenSaver(in: context, threadID: thread.id)
        let projectID = try XCTUnwrap(thread.projectId?.value.uuidString)
        try context.tokenSaverLaneStateRepo.upsert(.init(
            projectID: projectID,
            lane: "session_learn",
            state: "promoted",
            reason: "test",
            evidenceLevel: "provider_usage",
            ownerRole: "Operations Owner:test",
            permissionBoundary: "project",
            retentionDays: 30,
            optedOut: false,
            killSwitchActive: false,
            attributionJoined: true,
            reconciliationPassed: true,
            usageSemanticsAvailable: true,
            scorecardID: "session-learn-scorecard"
        ))
        let exactScope = TokenSaverSessionLearnScope(
            workspaceID: try XCTUnwrap(thread.workspaceId?.value.uuidString),
            projectID: projectID,
            threadID: thread.id.value.uuidString,
            provider: AgentProvider.codex.rawValue
        )
        try context.tokenSaverSessionLearnRepo.save(
            text: "preserve command output",
            scope: exactScope,
            attemptID: "auto-integration"
        )

        let runner = AutoPayloadCaptureRunner(provider: .codex)
        let coordinator = AgentRunCoordinator(
            runRepo: context.runRepo,
            messageRepo: context.messageRepo,
            threadRepo: context.threadRepo,
            orchestrationRuntime: runtime,
            providerSnapshotSupplier: { [
                AgentProviderSnapshotFactory.snapshot(
                    provider: .codex,
                    models: [AgentModelDescriptor(
                        id: "gpt-5.6-sol",
                        label: "gpt-5.6-sol",
                        provider: .codex,
                        supportsReasoning: true,
                        supportedReasoningEfforts: [.high],
                        supportsServiceTier: true
                    )],
                    binaryPath: "/usr/bin/true",
                    authenticated: true,
                    id: "codex-live",
                    capabilitiesOverride: AgentProviderCapabilities(supportsStreaming: true),
                    modelDiscoverySource: .live
                )
            ] },
            providers: [.codex: runner]
        )
        // This is the closure installed by AppContext's production initializer;
        // do not replace it with a test compressor that returns expected bytes.
        coordinator.promptPayloadCompressor = context.coordinator.promptPayloadCompressor

        let naturalPrompt = "Run these commands in order: `command -v swift`, then `command -v distill`, then `command -v git`. Return exactly three lines containing the exact response from each command. Do not edit files. Do not mark complete until commands succeed."
        let expectedUserWire = """
        @sr2 v1
        run:[command -v swift]>[command -v distill]>[command -v git]
        out:=3lines
        !file-edit
        done:run
        """
        let runID = AgentRunID()
        _ = try await coordinator.startRun(AgentRunRequest(
            runId: runID,
            threadId: thread.id,
            provider: .claude,
            providerInstanceId: "claude-manual",
            model: "claude-manual",
            cwd: NSTemporaryDirectory(),
            prompt: naturalPrompt,
            userMessageContent: naturalPrompt,
            permissionMode: .supervised,
            reasoningEffort: .medium,
            serviceTier: .auto,
            interactionMode: .default
        ))

        let dispatched = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(dispatched.provider, .codex)
        XCTAssertEqual(dispatched.model, "gpt-5.6-luna")
        XCTAssertEqual(dispatched.userMessageContent, naturalPrompt)
        XCTAssertEqual(dispatched.prompt, naturalPrompt)
        let host = try XCTUnwrap(dispatched.trustedHostInstruction?.text)
        XCTAssertTrue(host.contains("REMOTE_CODE_AUTO_ORCHESTRATION_V1"), host)
        XCTAssertTrue(host.contains("REMOTE_CODE_SESSION_LEARN_V1"), host)
        XCTAssertTrue(host.contains("preserve command output"), host)
        XCTAssertFalse(host.contains(expectedUserWire), host)
        XCTAssertFalse(dispatched.prompt.contains("REMOTE_CODE_AUTO_ORCHESTRATION_V1"))
        XCTAssertFalse(dispatched.prompt.contains("SESSION_LEARN_EXACT_SCOPE"))

        // A fresh thread gives the production coordinator a new provider scope;
        // this keeps the compound assertion independent of the completed simple
        // turn while still using the same real AppContext compressor closure.
        let compoundThread = AgentThread(
            projectId: thread.projectId,
            workspaceId: thread.workspaceId,
            title: "compound auto payload integration",
            provider: .claude,
            model: "claude-manual",
            routingConfiguration: configuration
        )
        try context.threadRepo.upsert(compoundThread)
        try admitTokenSaver(in: context, threadID: compoundThread.id)
        let compoundProjectID = try XCTUnwrap(compoundThread.projectId?.value.uuidString)
        try context.tokenSaverSessionLearnRepo.save(
            text: "preserve command output",
            scope: TokenSaverSessionLearnScope(
                workspaceID: try XCTUnwrap(compoundThread.workspaceId?.value.uuidString),
                projectID: compoundProjectID,
                threadID: compoundThread.id.value.uuidString,
                provider: AgentProvider.codex.rawValue
            ),
            attemptID: "auto-compound-integration"
        )

        let compoundPrompt = SR2Optimizer.r7LiveCompoundPrompt
        let expectedCompoundWire = """
        @sr2 v1
        run:[command -v swift;command -v distill]>[rg -n UNIQUE_EXACT_MATCH README.md]>[swift noisy.swift]
        out:1=2lines,2=1line
        !file-edit
        done:run+summary
        """
        _ = try await coordinator.startRun(AgentRunRequest(
            runId: AgentRunID(),
            threadId: compoundThread.id,
            provider: .claude,
            providerInstanceId: "claude-manual",
            model: "claude-manual",
            cwd: NSTemporaryDirectory(),
            prompt: compoundPrompt,
            userMessageContent: compoundPrompt,
            permissionMode: .supervised,
            reasoningEffort: .medium,
            serviceTier: .auto,
            interactionMode: .default
        ))

        let compoundDispatched = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(compoundDispatched.provider, .codex)
        XCTAssertEqual(compoundDispatched.userMessageContent, compoundPrompt)
        XCTAssertEqual(compoundDispatched.prompt, compoundPrompt)
        let compoundHost = try XCTUnwrap(compoundDispatched.trustedHostInstruction?.text)
        XCTAssertTrue(compoundHost.contains("REMOTE_CODE_AUTO_ORCHESTRATION_V1"), compoundHost)
        XCTAssertTrue(compoundHost.contains("REMOTE_CODE_SESSION_LEARN_V1"), compoundHost)
        XCTAssertTrue(compoundHost.contains("preserve command output"), compoundHost)
        XCTAssertFalse(compoundHost.contains(expectedCompoundWire), compoundHost)
    }

    private final class TestScopedRecoveryStore: TokenSaverScopedRecoveryStoring, @unchecked Sendable {
        private let store: TokenSaverScopedRecoveryStore

        init(db: SQLiteDB) {
            store = TokenSaverScopedRecoveryStore(db: db)
        }

        private func scope(_ context: TokenSaverRecoveryRequestContext) -> TokenSaverPersistentScope {
            .init(
                workspaceID: context.workspaceID,
                projectID: context.projectID,
                threadID: context.threadID,
                provider: context.provider,
                attemptID: context.attemptID
            )
        }

        func prepareOriginal(
            _ data: Data,
            context: TokenSaverRecoveryRequestContext,
            lane _: String
        ) throws -> TokenSaverScopedPreparation {
            let prepared = try store.prepare(
                data,
                scope: scope(context),
                operationID: context.operationID,
                expiresAt: Date().addingTimeInterval(7 * 86_400),
                disk: .init(freeBytes: 40 * 1_024 * 1_024 * 1_024, totalBytes: 100 * 1_024 * 1_024 * 1_024)
            )
            return .init(
                capability: prepared.capability,
                idempotencyKey: prepared.idempotencyKey,
                readBackVerified: prepared.readBackVerified
            )
        }

        func retrieveOriginal(capability: String, context: TokenSaverRecoveryRequestContext) throws -> Data? {
            try store.retrieve(capability: capability, scope: scope(context))
        }

        func markDelivered(
            capability: String,
            idempotencyKey: String,
            context: TokenSaverRecoveryRequestContext,
            outcome: TokenSaverScopedDeliveryOutcome
        ) throws -> Bool {
            let mapped: TokenSaverRecoveryTransportOutcome
            switch outcome {
            case .notSent: mapped = .notSent
            case .sentUnknown: mapped = .sentUnknown
            case .acked: mapped = .acked
            case .failed: mapped = .failed
            }
            return try store.markDelivered(
                capability: capability,
                scope: scope(context),
                idempotencyKey: idempotencyKey,
                outcome: mapped
            )
        }

        func ack(
            capability: String,
            idempotencyKey: String,
            context: TokenSaverRecoveryRequestContext
        ) throws -> Bool {
            try store.ack(capability: capability, scope: scope(context), idempotencyKey: idempotencyKey)
        }
    }

    private struct PartialSR1HumanizeRuntime: DistillRuntime {
        func distill(_ request: DistillRequest) async throws -> String {
            """
            Dict: S=state C=context D=action R=risk O=outcome N=no-go P=proof
            Estado: starting
            Acao: create #g1
            """
        }
    }

    private actor CountingEchoRuntime: DistillRuntime {
        private var count = 0
        private var providers: [String?] = []

        func distill(_ request: DistillRequest) async throws -> String {
            count += 1
            providers.append(request.provider)
            return request.input
        }

        var callCount: Int { count }
        var lastProvider: String? { providers.last ?? nil }
    }

    private struct FixedOutputRuntime: DistillRuntime {
        let output: String

        func distill(_ request: DistillRequest) async throws -> String {
            output
        }
    }

    private actor FixedOutputCountingRuntime: DistillRuntime {
        let output: String
        private(set) var count = 0

        init(output: String) {
            self.output = output
        }

        func distill(_ request: DistillRequest) async throws -> String {
            count += 1
            return output
        }
    }

    private actor FakeTokenSaverAccountUsageRefresher: TokenSaverAccountUsageRefreshing {
        let response: [AssistantAccountUsage]
        private(set) var requests: [TokenSaverAccountUsageRefreshRequest] = []

        init(response: [AssistantAccountUsage]) {
            self.response = response
        }

        func refreshAccountUsage(_ request: TokenSaverAccountUsageRefreshRequest) async -> [AssistantAccountUsage] {
            requests.append(request)
            return response
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private struct IsolatedProviderProcessOwnership {
        let ledger: URL
        let previousStore: ProviderProcessOwnershipStore?
        let previousRecords: [SpawnedProcessTag]?
    }

    /// Real sidecar spawning records an ownership row immediately after
    /// `Process.run()`. Keep that row in this test's app-support sandbox so a
    /// stale suite-wide test ledger can neither authorize nor reject this run.
    /// A fresh coordinator remains fail-closed until production wiring calls
    /// `configure(fileURL:)`; this assertion protects that production default.
    private func configureIsolatedProviderProcessOwnership(
        at appSupport: URL
    ) -> IsolatedProviderProcessOwnership {
        let previousStore = ProviderProcessOwnership.shared.configurationSnapshotForTesting()
        let previousRecords: [SpawnedProcessTag]?
        if let previousStore {
            previousRecords = try? previousStore.load()
        } else {
            previousRecords = nil
        }
        if let previousStore {
            XCTAssertTrue(
                ProviderProcessOwnership.shared.store() === previousStore,
                "the shared ownership coordinator must expose the exact prior configured store"
            )
        } else {
            XCTAssertNil(
                ProviderProcessOwnership.shared.store(),
                "the shared ownership coordinator must be unconfigured before the isolated test seam"
            )
        }

        let unconfigured = ProviderProcessOwnership()
        XCTAssertNil(unconfigured.store(),
                     "production ownership must have no implicit global store")
        let tag = SpawnedProcessTag(
            pgid: 42,
            spawnedAt: Date(timeIntervalSince1970: 1),
            ownerPID: 7,
            provider: .codex
        )
        XCTAssertThrowsError(try unconfigured.record(tag)) { error in
            XCTAssertEqual(error as? ProviderProcessOwnershipError, .storeNotConfigured,
                           "production ownership must fail closed before AppDelegate wiring")
        }

        let ledger = appSupport
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent("provider-process-ownership.json", isDirectory: false)
        do {
            try FileManager.default.createDirectory(
                at: ledger.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            XCTFail("isolated provider ownership directory must be writable: \(error)")
        }
        ProviderProcessOwnership.shared.configure(fileURL: ledger)
        XCTAssertEqual(ProviderProcessOwnership.shared.store()?.fileURL, ledger)
        return IsolatedProviderProcessOwnership(
            ledger: ledger,
            previousStore: previousStore,
            previousRecords: previousRecords
        )
    }

    private func restoreIsolatedProviderProcessOwnership(
        _ configuration: IsolatedProviderProcessOwnership
    ) {
        ProviderProcessOwnership.shared.restoreConfigurationForTesting(configuration.previousStore)
        let restoredStore = ProviderProcessOwnership.shared.configurationSnapshotForTesting()
        if let previousStore = configuration.previousStore {
            XCTAssertTrue(
                restoredStore === previousStore,
                "isolated ownership test must restore the exact prior configured store"
            )
            XCTAssertEqual(restoredStore?.fileURL, previousStore.fileURL)
            if let previousRecords = configuration.previousRecords {
                XCTAssertEqual(
                    try? previousStore.load(),
                    previousRecords,
                    "isolated ownership cleanup must not mutate the prior store"
                )
            }
        } else {
            XCTAssertNil(
                restoredStore,
                "isolated ownership test must restore the prior unconfigured state"
            )
        }
    }

    /// WHY: the real-spawner tests temporarily replace the process-wide store.
    /// A late ownership removal must never mutate a previously configured store
    /// after restoration, even when that prior store contains live rows.
    func test_isolatedProviderOwnershipRestoresFakePriorStoreWithoutMutation() throws {
        let baseline = ProviderProcessOwnership.shared.configurationSnapshotForTesting()
        let priorLedger = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2ProviderOwnershipPrior-\(UUID().uuidString).json")
        let isolatedRoot = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("RC2ProviderOwnershipIsolation-\(UUID().uuidString)", isDirectory: true)
        let priorStore = ProviderProcessOwnershipStore(fileURL: priorLedger)
        let sentinel = SpawnedProcessTag(
            pgid: 4242,
            spawnedAt: Date(timeIntervalSince1970: 1),
            ownerPID: 7,
            provider: .grok
        )
        try priorStore.replace([sentinel])
        ProviderProcessOwnership.shared.configure(fileURL: priorLedger)
        defer {
            ProviderProcessOwnership.shared.restoreConfigurationForTesting(baseline)
            removeIsolatedProviderProcessOwnership(priorLedger)
            try? FileManager.default.removeItem(at: isolatedRoot)
        }

        try FileManager.default.createDirectory(at: isolatedRoot, withIntermediateDirectories: true)
        let isolated = configureIsolatedProviderProcessOwnership(at: isolatedRoot)
        defer {
            removeIsolatedProviderProcessOwnership(isolated.ledger)
            restoreIsolatedProviderProcessOwnership(isolated)
        }
        let isolatedTag = SpawnedProcessTag(
            pgid: 4343,
            spawnedAt: Date(timeIntervalSince1970: 2),
            ownerPID: 8,
            provider: .codex
        )
        try ProviderProcessOwnership.shared.record(isolatedTag)
        restoreIsolatedProviderProcessOwnership(isolated)

        XCTAssertEqual(try priorStore.load(), [sentinel],
                       "restoring an isolated test store must leave the prior store byte-for-byte equivalent")
    }

    private func cleanupIsolatedProviderProcessOwnership(
        _ configuration: IsolatedProviderProcessOwnership,
        controller: TokenSaverDistillServiceController
    ) async {
        controller.stop()
        let store = ProviderProcessOwnershipStore(fileURL: configuration.ledger)
        let released = await waitUntil(timeout: 4) {
            (try? store.load().isEmpty) == true
        }
        XCTAssertTrue(
            released,
            "controller.stop() must await exact isolated ownership removal before restoring the prior store"
        )
        guard released else { return }
        removeIsolatedProviderProcessOwnership(configuration.ledger)
        try? FileManager.default.removeItem(at: configuration.ledger.deletingLastPathComponent().deletingLastPathComponent())
        restoreIsolatedProviderProcessOwnership(configuration)
    }

    private func removeIsolatedProviderProcessOwnership(_ ledger: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: ledger)
        try? fileManager.removeItem(
            at: ledger.deletingPathExtension().appendingPathExtension("lock")
        )
    }

    /// AppContext performs managed-skill reconciliation during initialization.
    /// Pass a unique sandbox root for that first pass even in tests that exercise
    /// the historical direct-settings Token Saver seam; those tests do not need
    /// to retain the installer override after initialization.
    private func makeTestContext(
        appSupportOverride: String,
        tokenSaverAccountUsageRefresher: TokenSaverAccountUsageRefreshing = TokenSaverAccountUsageRefresher()
    ) throws -> AppContext {
        let skillsHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2TokenSaverSkills-\(UUID().uuidString)", isDirectory: true)
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupportOverride,
            tokenSaverAccountUsageRefresher: tokenSaverAccountUsageRefresher,
            agentSkillsHomeOverrideForTesting: skillsHome
        )
        // Most tests in this class intentionally use the unit-test direct-settings
        // gate. Managed-install integration tests construct an explicit context
        // with a retained override below; clearing it here keeps that test seam
        // while still making initialization unable to touch the real home.
        context.agentSkillsHomeOverrideForTesting = nil
        return context
    }

    private func savePrivateSession(in context: AppContext, subscribed: Bool = true) {
        PrivateAccountSessionStore(repo: context.settingsRepo).save(PrivateAccountSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            user: PrivateAccountUser(
                daysRemaing: nil,
                daysRemaining: 30,
                email: subscribed ? "paid@example.com" : "unpaid@example.com",
                id: subscribed ? "paid-user" : "unpaid-user",
                subscribed: subscribed
            )
        ))
    }

    @discardableResult
    private func admitTokenSaver(
        in context: AppContext,
        threadID: AgentThreadID,
        lane: String = "deterministic_wrapper"
    ) throws -> AgentThreadID {
        var thread = try XCTUnwrap(context.threadRepo.get(id: threadID))
        if thread.projectId == nil || thread.workspaceId == nil {
            thread.projectId = thread.projectId ?? ProjectID()
            thread.workspaceId = thread.workspaceId ?? WorkspaceID()
            // AgentThreadRepository deliberately keeps ownership immutable on
            // conflict; tests create the exact scoped row before adding messages.
            try context.threadRepo.delete(id: threadID)
            try context.threadRepo.upsert(thread)
        }
        try context.tokenSaverLaneStateRepo.upsert(.init(
            projectID: thread.projectId!.value.uuidString,
            lane: lane,
            state: "promoted",
            reason: "test_scorecard_passed",
            evidenceLevel: "provider_usage",
            ownerRole: "Operations Owner:test",
            permissionBoundary: "project",
            retentionDays: 30,
            optedOut: false,
            killSwitchActive: false,
            attributionJoined: true,
            reconciliationPassed: true,
            usageSemanticsAvailable: true,
            scorecardID: "test-scorecard"
        ))
        return threadID
    }

    private func makeAdmittedTokenSaverThread(
        in context: AppContext,
        provider: AgentProvider,
        status: AgentRunStatus = .completed
    ) throws -> AgentThreadID {
        let thread = AgentThread(
            projectId: ProjectID(),
            workspaceId: WorkspaceID(),
            title: "token saver admitted test",
            provider: provider,
            model: "test-model",
            status: status
        )
        try context.threadRepo.upsert(thread)
        return try admitTokenSaver(in: context, threadID: thread.id)
    }

    private func managedDistillSkillURLs(home: URL) -> (codex: URL, claude: URL) {
        (
            codex: home.appendingPathComponent(".codex/skills/distill/SKILL.md"),
            claude: home.appendingPathComponent(".claude/skills/distill/SKILL.md")
        )
    }

    private func managedDistillConfigURLs(home: URL) -> (codex: URL, claude: URL) {
        (
            codex: home.appendingPathComponent(".codex/AGENTS.md"),
            claude: home.appendingPathComponent(".claude/CLAUDE.md")
        )
    }

    private func managedDistillCLIURL(home: URL) -> URL {
        home.appendingPathComponent(".remote-code/bin/distill")
    }

    private func managedDistillPathLinkURL(home: URL) -> URL {
        home.appendingPathComponent(".local/bin/distill")
    }

    func test_appContextInitializationReconcilesOnlyTheControlledSkillsHome() throws {
        // WHY: startup reconciliation runs before a test can assign the override
        // after init. A sentinel in the injected home proves that this first pass
        // targets the controlled tree rather than the developer's real home.
        let appSupport = NSTemporaryDirectory() + "RC2ManagedSkillsInitGuard-" + UUID().uuidString
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2ManagedSkillsInitGuardHome-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(atPath: appSupport)
            try? FileManager.default.removeItem(at: home)
        }

        let installer = AgentSkillInstaller(homeDirectory: home)
        _ = try installer.installDistillSkill(for: .codex, sourceRevision: "sentinel")
        let sentinel = managedDistillSkillURLs(home: home).codex
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))

        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            agentSkillsHomeOverrideForTesting: home
        )

        XCTAssertEqual(context.agentSkillsHomeOverrideForTesting, home)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sentinel.path),
            "startup reconciliation must scrub the injected sentinel, not a real provider home"
        )
    }

    func test_appContextReconcilesManagedDistillStateWithTokenSaverToggle() throws {
        let appSupport = NSTemporaryDirectory() + "RC2ManagedSkills-" + UUID().uuidString
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2ManagedSkillsHome-" + UUID().uuidString, isDirectory: true)

        let context = try makeTestContext(appSupportOverride: appSupport)
        // Sandbox the install roots so the test writes into a temp home, not the
        // developer's real ~/.claude / ~/.codex.
        context.agentSkillsHomeOverrideForTesting = home

        // Legacy provider-home skill dirs must never be used again.
        let codexSkill = home.appendingPathComponent(".codex/skills/distill/SKILL.md")
        let claudeSkill = home.appendingPathComponent(".claude/skills/distill/SKILL.md")
        let configURLs = managedDistillConfigURLs(home: home)
        let cliURL = managedDistillCLIURL(home: home)
        let pathLink = managedDistillPathLinkURL(home: home)
        let appPrivateSkill = URL(fileURLWithPath: appSupport, isDirectory: true)
            .appendingPathComponent("AgentSkills/distill/SKILL.md")

        // Token Saver off: no Distill CLI / app-private install results; still scrub legacy homes.
        context.reconcileManagedDistillSkills(tokenSaverEnabled: false)
        XCTAssertEqual(context.managedDistillSkillInstallResults.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexSkill.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeSkill.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURLs.codex.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURLs.claude.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cliURL.path),
                       "Token Saver off must not leave managed distill CLI installed")

        // Token Saver on: app-private Distill + CLI under RemoteCode Application Support.
        context.reconcileManagedDistillSkills(tokenSaverEnabled: true)
        XCTAssertEqual(context.managedDistillSkillInstallResults.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: appPrivateSkill.path),
                      "Distill lives under RemoteCode Application Support, not provider homes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexSkill.path),
                       "must never install into ~/.codex/skills")
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeSkill.path),
                       "must never install into ~/.claude/skills")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cliURL.path),
                      "Token Saver on installs managed distill CLI for | distill pipes")
        let claudeStyle = home.appendingPathComponent(
            ".claude/output-styles/\(ClaudeRunner.sr2OutputStyleFileName)"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: claudeStyle.path),
            "Token Saver on must install Claude's SR2 output style so outputStyle can load"
        )
        XCTAssertEqual(
            try String(contentsOf: claudeStyle),
            ClaudeRunner.sr2OutputStyleMarkdown
        )
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: pathLink.path), cliURL.path)

        let skillText = try String(contentsOf: appPrivateSkill)
        XCTAssertTrue(skillText.contains("source: https://github.com/samuelfaj/distill/blob/main/skills/distill/SKILL.md"))
        XCTAssertTrue(skillText.contains("@sr2 v1"))
        XCTAssertTrue(skillText.contains("Never emit legacy `@sr2 v0`"))
        XCTAssertFalse(skillText.contains("S=state"))
        XCTAssertFalse(skillText.contains("P=proof"))
        let cliDest = try FileManager.default.destinationOfSymbolicLink(atPath: cliURL.path)
        XCTAssertTrue(cliDest.hasSuffix("RemoteCodeDistillService"), "managed CLI is a native symlink, not a script")
        XCTAssertFalse(cliDest.contains("dev/distill/src/cli.ts"))

        // Toggle off revokes runtime admission but preserves shared entrypoints.
        context.reconcileManagedDistillSkills(tokenSaverEnabled: false)
        XCTAssertEqual(context.managedDistillSkillInstallResults.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cliURL.path),
                      "disabling one instance must not uninstall shared managed distill CLI")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: pathLink.path),
            cliURL.path,
            "disabling one instance must not remove the shared PATH bridge"
        )
    }

    func test_offInstanceLaunchDoesNotRemoveManagedDistillIntegrationOwnedByOnInstance() throws {
        // WHY: the managed CLI and PATH wrappers are per-user shared entrypoints.
        // Launching a second RemoteCode instance with Token Saver off must not
        // tear down an integration that an already-running ON instance needs.
        let onAppSupport = NSTemporaryDirectory() + "RC2ManagedSkillsOn-" + UUID().uuidString
        let offAppSupport = NSTemporaryDirectory() + "RC2ManagedSkillsOff-" + UUID().uuidString
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2ManagedSkillsSharedHome-" + UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(atPath: onAppSupport)
            try? FileManager.default.removeItem(atPath: offAppSupport)
            try? FileManager.default.removeItem(at: home)
        }

        let onContext = try AppContext(
            channel: .debug,
            appSupportOverride: onAppSupport,
            agentSkillsHomeOverrideForTesting: home
        )
        XCTAssertNil(onContext.reconcileManagedDistillSkills(tokenSaverEnabled: true))

        let installer = AgentSkillInstaller(homeDirectory: home)
        let cliURL = managedDistillCLIURL(home: home)
        let pathLink = managedDistillPathLinkURL(home: home)
        let wrapperURL = home.appendingPathComponent(".remote-code/bin/ls")
        XCTAssertTrue(installer.isDistillCLIHealthy())
        XCTAssertTrue(FileManager.default.fileExists(atPath: wrapperURL.path))
        let cliDestination = try FileManager.default.destinationOfSymbolicLink(atPath: cliURL.path)
        let pathDestination = try FileManager.default.destinationOfSymbolicLink(atPath: pathLink.path)

        // This initializer is the ordinary OFF launch path. Its startup
        // reconcile must leave the ON instance's shared links untouched.
        _ = try AppContext(
            channel: .debug,
            appSupportOverride: offAppSupport,
            agentSkillsHomeOverrideForTesting: home
        )

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: cliURL.path),
            cliDestination,
            "OFF launch must not remove the shared managed distill CLI"
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: pathLink.path),
            pathDestination,
            "OFF launch must not remove the shared PATH bridge"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: wrapperURL.path),
            "OFF launch must not remove a wrapper used by the ON instance"
        )
    }

    func test_distillInstallStatusMappingDistinguishesFailedFromOff() {
        // A reconcile failure must surface as .failed (visible), never collapse into
        // .inactive. Installed only when Token Saver is on and package is present.
        XCTAssertEqual(
            DistillInstallStatus.from(error: "no service binary", enabled: true, installedCount: 0),
            .failed("no service binary"),
            "an install failure must be visible, not swallowed as inactive")
        XCTAssertEqual(
            DistillInstallStatus.from(error: "no service binary", enabled: false, installedCount: 0),
            .failed("no service binary"),
            "a recorded error wins even if the toggle reads off")
        XCTAssertEqual(
            DistillInstallStatus.from(error: nil, enabled: true, installedCount: 1),
            .installed)
        XCTAssertEqual(
            DistillInstallStatus.from(error: nil, enabled: false, installedCount: 1),
            .inactive,
            "Token Saver off → Distill status is inactive even if files linger on disk")
        XCTAssertEqual(
            DistillInstallStatus.from(error: nil, enabled: true, installedCount: 0),
            .inactive,
            "nothing installed yet is inactive, not a false 'installed'")
        XCTAssertEqual(
            DistillInstallStatus.from(error: nil, enabled: false, installedCount: 0),
            .inactive)
    }

    func test_reconcileClearsInstallErrorOnSuccessAndOff() throws {
        let appSupport = NSTemporaryDirectory() + "RC2DistillInstallStatus-" + UUID().uuidString
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2DistillInstallStatusHome-" + UUID().uuidString, isDirectory: true)
        let context = try makeTestContext(appSupportOverride: appSupport)
        context.agentSkillsHomeOverrideForTesting = home

        context.reconcileManagedDistillSkills(tokenSaverEnabled: true)
        XCTAssertEqual(context.managedDistillSkillInstallResults.count, 1,
                       "app-private Distill is a single package install")
        XCTAssertNil(context.managedDistillSkillInstallError,
                     "a clean install must leave no error so the UI shows installed, not failed")

        context.reconcileManagedDistillSkills(tokenSaverEnabled: false)
        XCTAssertEqual(context.managedDistillSkillInstallResults.count, 0,
                       "Token Saver off must uninstall Distill economy hooks")
        XCTAssertNil(context.managedDistillSkillInstallError,
                     "turning Token Saver off is not a failure — the error must clear")
    }

    func test_managedDistillCLIUsesLocalMacDistillService() async throws {
        let appSupportURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2ManagedDistillCLI-\(UUID().uuidString)", isDirectory: true)
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2ManagedDistillCLIHome-\(UUID().uuidString)", isDirectory: true)
        let installer = AgentSkillInstaller(homeDirectory: home)
        let cliURL = try installer.installDistillCLI(appSupportDirectory: appSupportURL)

        let configuration = try DistillServiceConfiguration(
            authToken: "cli-token",
            appSupportDirectory: appSupportURL.path
        )
        let (_, recoveryDB) = try Bootstrap(channel: .debug, appSupportOverride: appSupportURL.path).run()
        SettingsStore(db: recoveryDB).update { $0.tokenSaverEnabled = true }
        try SettingsRepository(db: recoveryDB).set(
            "private.account.session",
            #"{"user":{"subscribed":true}}"#
        )
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: scheduler,
            scopedRecoveryStore: TestScopedRecoveryStore(db: recoveryDB)
        )
        let ready = try await server.start()
        defer { server.stop() }

        let stateURL = appSupportURL
            .appendingPathComponent("Distill", isDirectory: true)
            .appendingPathComponent("DistillCLIState.json")
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "base_url": "\(ready.baseURL)",
          "auth_token": "cli-token",
          "pid": \(ready.pid),
          "runtime": "\(ready.runtime)",
          "model_id": "\(ready.modelID)"
        }
        """.utf8).write(to: stateURL)

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = cliURL
        process.arguments = ["Return PASS or FAIL only, then one proof line."]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        var cliEnvironment = ProcessInfo.processInfo.environment
        let receipt = TokenSaverExecutionReceiptSeam.admit(
            tokenSaverEnabled: true,
            sameUser: true,
            sidecarAvailable: true,
            provider: .codex,
            threadId: "10000000-0000-0000-0000-000000000001",
            rootRunId: "40000000-0000-0000-0000-000000000004",
            attemptId: "50000000-0000-0000-0000-000000000005",
            workspaceId: "20000000-0000-0000-0000-000000000002",
            projectId: "30000000-0000-0000-0000-000000000003"
        )
        let receiptEnvironment = TokenSaverExecutionReceiptSeam.environment(from: receipt).merging([
            "REMOTE_CODE_DISTILL_STATE_PATH": stateURL.path,
            "RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY": appSupportURL.path,
            "REMOTE_CODE_AGENT_PROVIDER": "codex",
        ], uniquingKeysWith: { _, explicit in explicit })
        for (key, value) in receiptEnvironment {
            cliEnvironment[key] = value
        }
        process.environment = cliEnvironment

        try process.run()
        stdin.fileHandleForWriting.write(Data("unit tests passed\nno failures\n".utf8))
        stdin.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, error)
        XCTAssertEqual(output.split(whereSeparator: \.isNewline).first.map(String.init), "PASS",
                       "the managed distill command must preserve the requested answer before its recovery marker")
        XCTAssertTrue(output.contains("[[rc:rcv1."), "lossy CLI output must carry its exact-scope recovery capability")
        XCTAssertFalse(output.contains("PROMPT:"))
        XCTAssertFalse(output.contains("INPUT:"))
        XCTAssertFalse(error.contains("dev/distill/src/cli.ts"),
                       "the provider-visible CLI path must never hit the old TypeScript checkout")
    }

    func test_appContextInstallsAppPrivateDistillWhenEntitledAndModelReady() throws {
        let appSupport = NSTemporaryDirectory() + "RC2ManagedSkillsLaunchOn-" + UUID().uuidString
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2ManagedSkillsLaunchHome-" + UUID().uuidString, isDirectory: true)
        let skillURLs = managedDistillSkillURLs(home: home)
        let configURLs = managedDistillConfigURLs(home: home)
        let appPrivateSkill = URL(fileURLWithPath: appSupport, isDirectory: true)
            .appendingPathComponent("AgentSkills/distill/SKILL.md")

        let launchedContext = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            agentSkillsHomeOverrideForTesting: home
        )
        savePrivateSession(in: launchedContext)
        XCTAssertEqual(
            launchedContext.applyTokenSaverLifecycle(
                requestedEnabled: true,
                modelValidation: .installed,
                persistPreference: true
            ),
            .enabled
        )

        XCTAssertEqual(launchedContext.managedDistillSkillInstallResults.count, 1,
                       "an entitled, model-ready Token Saver installs one app-private Distill package")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appPrivateSkill.path),
                      "Distill lives under RemoteCode Application Support, not provider homes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillURLs.codex.path),
                       "must never install into ~/.codex/skills")
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillURLs.claude.path),
                       "must never install into ~/.claude/skills")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURLs.codex.path),
                       "Codex instructions are injected only into admitted runtime turns")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURLs.claude.path),
                       "Claude instructions are injected only into admitted runtime turns")
    }

    func test_appContextLaunchRemovesManagedDistillStateWhenPersistedTokenSaverDisabled() throws {
        let appSupport = NSTemporaryDirectory() + "RC2ManagedSkillsLaunchOff-" + UUID().uuidString
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2ManagedSkillsLaunchOffHome-" + UUID().uuidString, isDirectory: true)
        let skillURLs = managedDistillSkillURLs(home: home)
        let configURLs = managedDistillConfigURLs(home: home)
        let installer = AgentSkillInstaller(homeDirectory: home)
        _ = try installer.installDistillSkill(for: .codex, sourceRevision: "rev-a")
        _ = try installer.installDistillSkill(for: .claude, sourceRevision: "rev-a")
        try installer.installDistillInstructions(for: .codex)
        try installer.installDistillInstructions(for: .claude)
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillURLs.codex.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillURLs.claude.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURLs.codex.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURLs.claude.path))

        let seedContext = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: seedContext.db).save(AppSettings(tokenSaverEnabled: false))

        let launchedContext = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            agentSkillsHomeOverrideForTesting: home
        )

        // Launch with Token Saver off scrubs legacy provider-home skill copies and
        // does not install Distill economy hooks (paid feature).
        XCTAssertEqual(launchedContext.managedDistillSkillInstallResults.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillURLs.codex.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillURLs.claude.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURLs.codex.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURLs.claude.path))
    }

    func test_applicationWillTerminateScrubsLegacyHomeDistillButKeepsAppPrivate() throws {
        let appSupport = NSTemporaryDirectory() + "RC2ManagedSkillsClose-" + UUID().uuidString
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2ManagedSkillsCloseHome-" + UUID().uuidString, isDirectory: true)
        let skillURLs = managedDistillSkillURLs(home: home)
        let configURLs = managedDistillConfigURLs(home: home)
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            agentSkillsHomeOverrideForTesting: home
        )
        // Seed legacy home installs, then reconcile (scrubs home, keeps app-private).
        let installer = AgentSkillInstaller(homeDirectory: home)
        _ = try installer.installDistillSkill(for: .codex, sourceRevision: "rev-a")
        _ = try installer.installDistillSkill(for: .claude, sourceRevision: "rev-a")
        context.reconcileManagedDistillSkills(tokenSaverEnabled: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillURLs.codex.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillURLs.claude.path))
        let appPrivate = URL(fileURLWithPath: appSupport, isDirectory: true)
            .appendingPathComponent("AgentSkills/distill/SKILL.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appPrivate.path))

        let delegate = AppDelegate()
        delegate.context = context
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        // Terminate reconcile still must not reinstall into provider homes.
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillURLs.codex.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillURLs.claude.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURLs.codex.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURLs.claude.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: appPrivate.path),
                      "app-private Distill package remains for the next launch")
    }

    func test_tokenSaverDistillLaunchPlannerOnlyStartsForPaidEnabledInstalledModel() {
        XCTAssertEqual(
            TokenSaverDistillLaunchPlanner.decide(TokenSaverDistillLaunchInput(
                hasPrivateAccount: false,
                isSubscribed: false,
                tokenSaverEnabled: true,
                modelValidation: .installed
            )),
            .skip(reason: "private account not signed in")
        )

        XCTAssertEqual(
            TokenSaverDistillLaunchPlanner.decide(TokenSaverDistillLaunchInput(
                hasPrivateAccount: true,
                isSubscribed: false,
                tokenSaverEnabled: true,
                modelValidation: .installed
            )),
            .skip(reason: "subscription required")
        )

        XCTAssertEqual(
            TokenSaverDistillLaunchPlanner.decide(TokenSaverDistillLaunchInput(
                hasPrivateAccount: true,
                isSubscribed: true,
                tokenSaverEnabled: true,
                modelValidation: TokenSaverModelValidation(state: .missing, reason: "manifest missing")
            )),
            .requireModel(reason: "manifest missing")
        )

        XCTAssertEqual(
            TokenSaverDistillLaunchPlanner.decide(TokenSaverDistillLaunchInput(
                hasPrivateAccount: true,
                isSubscribed: true,
                tokenSaverEnabled: true,
                modelValidation: .installed
            )),
            .start
        )
    }

    func test_tokenSaverDistillServiceDoesNotAutoResolveExecutableInsideUnitTests() {
        XCTAssertNil(
            TokenSaverDistillServiceController.defaultExecutableURL(),
            "unit tests must not auto-spawn the sidecar because leaked child processes can corrupt later process-sweeper coverage"
        )
    }

    func test_appContextRefreshesTokenSaverAccountUsageFromProviderCommands() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverAccountUsage-" + UUID().uuidString
        let refresher = FakeTokenSaverAccountUsageRefresher(response: [
            AssistantAccountUsage(provider: .claude, weeklyUsedPercent: 57, weeklyWindowDurationMinutes: 10_080, currentSessionUsedPercent: 3),
            AssistantAccountUsage(provider: .codex, weeklyUsedPercent: 34, weeklyWindowDurationMinutes: 10_080, currentSessionUsedPercent: 13)
        ])
        let context = try makeTestContext(
            appSupportOverride: appSupport,
            tokenSaverAccountUsageRefresher: refresher
        )
        savePrivateSession(in: context)

        context.refreshTokenSaverAccountUsage(reason: "test")

        let didPersist = await waitUntil {
            let snapshot = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
            let claude = snapshot.providers.first { $0.provider == .claude }
            let codex = snapshot.providers.first { $0.provider == .codex }
            return claude?.weeklyUsedPercent == 57
                && claude?.currentSessionUsedPercent == 3
                && codex?.weeklyUsedPercent == 34
                && codex?.currentSessionUsedPercent == 13
        }
        XCTAssertTrue(didPersist,
                      "startup/details/periodic refresh must persist real provider weekly percentages for the Token Saver rings")
        XCTAssertEqual(context.tokenSaverAccountUsageRefreshCount, 1)
        let requests = await refresher.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.codexBinary, "codex")
        XCTAssertEqual(requests.first?.claudeBinary, "claude")
    }

    /// WHY: Claude left inactive must not keep a frozen weekly ring after a
    /// partial refresh still succeeds for Codex/Grok.
    func test_appContextClearsMissingProviderAccountUsageOnPartialRefresh() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverClearMissing-" + UUID().uuidString
        let store = TokenSaverUsageStore(appSupportDirectory: URL(fileURLWithPath: appSupport))
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: appSupport).appendingPathComponent("TokenSaver", isDirectory: true),
            withIntermediateDirectories: true
        )
        _ = try store.recordAccountUsage(provider: .claude, weeklyUsedPercent: 45, weeklyWindowDurationMinutes: 10_080)
        _ = try store.recordAccountUsage(provider: .codex, weeklyUsedPercent: 10, weeklyWindowDurationMinutes: 10_080)

        let refresher = FakeTokenSaverAccountUsageRefresher(response: [
            AssistantAccountUsage(provider: .codex, weeklyUsedPercent: 23, weeklyWindowDurationMinutes: 10_080),
            AssistantAccountUsage(provider: .grok, weeklyUsedPercent: 59, weeklyWindowDurationMinutes: 10_080)
        ])
        let context = try makeTestContext(
            appSupportOverride: appSupport,
            tokenSaverAccountUsageRefresher: refresher
        )
        savePrivateSession(in: context)

        context.refreshTokenSaverAccountUsage(reason: "test")

        let didClear = await waitUntil {
            let snapshot = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
            let claude = snapshot.providers.first { $0.provider == .claude }
            let codex = snapshot.providers.first { $0.provider == .codex }
            let grok = snapshot.providers.first { $0.provider == .grok }
            return claude?.weeklyUsedPercent == 0
                && codex?.weeklyUsedPercent == 23
                && grok?.weeklyUsedPercent == 59
        }
        XCTAssertTrue(didClear,
                      "partial refresh without Claude must zero Claude's frozen weekly % while updating the live providers")
    }

    /// WHY: Grok frequently painted Used 0% after Codex-only partial refreshes
    /// even though the SuperGrok weekly window was still open. A flaky billing
    /// log miss must keep the last live percent until the window expires.
    func test_appContextKeepsUnexpiredGrokPercentWhenMissingFromPartialRefresh() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverKeepGrok-" + UUID().uuidString
        let store = TokenSaverUsageStore(appSupportDirectory: URL(fileURLWithPath: appSupport))
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: appSupport).appendingPathComponent("TokenSaver", isDirectory: true),
            withIntermediateDirectories: true
        )
        let futureReset = Date().addingTimeInterval(3 * 24 * 3600)
        _ = try store.recordAccountUsage(
            provider: .grok,
            weeklyUsedPercent: 65,
            weeklyWindowDurationMinutes: 10_080,
            weeklyResetsAt: futureReset
        )
        _ = try store.recordAccountUsage(provider: .codex, weeklyUsedPercent: 10, weeklyWindowDurationMinutes: 10_080)

        let refresher = FakeTokenSaverAccountUsageRefresher(response: [
            AssistantAccountUsage(provider: .codex, weeklyUsedPercent: 71, weeklyWindowDurationMinutes: 10_080)
        ])
        let context = try makeTestContext(
            appSupportOverride: appSupport,
            tokenSaverAccountUsageRefresher: refresher
        )
        savePrivateSession(in: context)

        context.refreshTokenSaverAccountUsage(reason: "test")

        let didKeep = await waitUntil {
            let snapshot = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
            let grok = snapshot.providers.first { $0.provider == .grok }
            let codex = snapshot.providers.first { $0.provider == .codex }
            return grok?.weeklyUsedPercent == 65 && codex?.weeklyUsedPercent == 71
        }
        XCTAssertTrue(didKeep,
                      "partial refresh that omits Grok must keep Grok's unexpired weekly % instead of painting 0%")
    }

    func test_appContextSkipsTokenSaverAccountUsageRefreshWhenNotSignedIn() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverNoAccountUsage-" + UUID().uuidString
        let refresher = FakeTokenSaverAccountUsageRefresher(response: [
            AssistantAccountUsage(provider: .codex, weeklyUsedPercent: 34)
        ])
        let context = try makeTestContext(
            appSupportOverride: appSupport,
            tokenSaverAccountUsageRefresher: refresher
        )

        context.refreshTokenSaverAccountUsage(reason: "test")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(context.tokenSaverAccountUsageRefreshCount, 0)
        let requests = await refresher.requests
        XCTAssertTrue(requests.isEmpty,
                      "provider limit commands must not run before a RemoteCode private account is signed in")
    }

    func test_tokenSaverAccountUsageRefreshIntervalIsFiveMinutes() {
        XCTAssertEqual(AppDelegate.tokenSaverAccountUsageRefreshInterval, 300)
    }

    func test_appContextRefreshesGrokAccountUsageFromBillingLogAfterRun() async throws {
        // WHY: Grok ACP never emits live `.accountUsage`, so the Token Saver
        // purple ring stayed stale between the 5-minute periodic probes. After
        // a Grok run finishes we re-read the local billing log; this pins that
        // the lightweight path persists creditUsagePercent without Claude/Codex.
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverGrokRunUsage-" + UUID().uuidString
        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-grok-billing-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logDir) }
        let log = logDir.appendingPathComponent("unified.jsonl")
        let body = """
        {"msg":"noise"}
        {"msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":61.0,"billingPeriodEnd":"2099-07-22T20:46:41.975270+00:00"}}}
        """
        try body.write(to: log, atomically: true, encoding: .utf8)

        let context = try makeTestContext(appSupportOverride: appSupport)
        savePrivateSession(in: context)

        context.refreshGrokTokenSaverAccountUsage(reason: "run_finished", billingLogURL: log)

        let didPersist = await waitUntil {
            let snapshot = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
            return snapshot.providers.first(where: { $0.provider == .grok })?.weeklyUsedPercent == 61
        }
        XCTAssertTrue(didPersist,
                      "post-run Grok billing-log refresh must write weeklyUsedPercent so the purple ring updates without the 5-minute probe")
    }

    func test_appContextSkipsGrokBillingLogRefreshWhenNotSignedIn() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverGrokNoAccount-" + UUID().uuidString
        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-grok-billing-signedout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logDir) }
        let log = logDir.appendingPathComponent("unified.jsonl")
        try #"{"msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":88.0}}}"#
            .write(to: log, atomically: true, encoding: .utf8)

        let context = try makeTestContext(appSupportOverride: appSupport)
        context.refreshGrokTokenSaverAccountUsage(reason: "run_finished", billingLogURL: log)
        try? await Task.sleep(nanoseconds: 80_000_000)

        let snapshot = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
        XCTAssertNil(snapshot.providers.first(where: { $0.provider == .grok })?.weeklyUsedPercent,
                     "signed-out sessions must not probe or persist Grok billing usage")
    }
    func test_tokenSaverProjectVerbatimAdmissionReturnsExactBytesWithoutWriters() async throws {
        // WHY: Verbatim project admission used to be the compress-lane bypass.
        // The send path no longer compiles user text, so the live hook must
        // still ship typed bytes and record no prompt-compile savings.
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverVerbatimAdmission-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let threadID = try makeAdmittedTokenSaverThread(in: context, provider: .grok)
        let thread = try XCTUnwrap(context.threadRepo.get(id: threadID))
        let projectID = try XCTUnwrap(thread.projectId?.value.uuidString)
        try context.tokenSaverLaneStateRepo.forceVerbatim(projectID: projectID)
        let prompt = String(repeating: "same large exact block with literal ABC-123\n", count: 100)

        let outputValue = await context.coordinator.promptCompressor?(
            prompt,
            AgentPromptSemanticSource(prompt),
            .grok,
            threadID,
            AgentRunID()
        )
        let output = try XCTUnwrap(outputValue)

        XCTAssertEqual(Data(output.utf8), Data(prompt.utf8),
                       "project Verbatim must ship the typed user prompt byte-for-byte")
        XCTAssertEqual(try context.tokenSaverSavingsRepo.summary().totalRuns, 0)
    }
    func test_sessionLearnWritesBoundedExactScopeWithoutGlobalInstructions() throws {
        let appSupport = NSTemporaryDirectory() + "RC2SessionLearn-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update {
            $0.sessionLearnEnabled = true
            $0.tokenSaverEnabled = true
        }
        let learnFile = URL(fileURLWithPath: appSupport).appendingPathComponent("AGENTS.md")
        context.sessionLearnInstructionFilesOverrideForTesting = [learnFile]

        let thread = AgentThread(
            projectId: ProjectID(),
            workspaceId: WorkspaceID(),
            title: "t",
            provider: .codex,
            model: "m"
        )
        try context.threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m", status: .failed,
                           errorMessage: "build error: cannot find symbol Foo in scope")
        try context.runRepo.upsert(run)
        try context.tokenSaverLaneStateRepo.upsert(.init(
            projectID: thread.projectId!.value.uuidString,
            lane: "session_learn",
            state: "shadow_only",
            reason: "test_shadow",
            evidenceLevel: "diagnostic_heuristic",
            ownerRole: "Security Owner:test",
            permissionBoundary: "project",
            retentionDays: 30,
            optedOut: false,
            killSwitchActive: false,
            attributionJoined: true,
            reconciliationPassed: true,
            usageSemanticsAvailable: true,
            scorecardID: "rollover-scorecard"
        ))

        context.recordSessionLearnFromRun(runId: run.id, status: .failed)

        XCTAssertEqual(try SessionLearnRegion(fileURL: learnFile).rules().count, 0,
                       "scoped learning never mutates global AGENTS/CLAUDE instructions")
        let scope = TokenSaverSessionLearnScope(
            workspaceID: thread.workspaceId!.value.uuidString,
            projectID: thread.projectId!.value.uuidString,
            threadID: thread.id.value.uuidString,
            provider: AgentProvider.codex.rawValue
        )
        let records = try context.tokenSaverSessionLearnRepo.topK(scope: scope, byteBudget: 1_024, limit: 5)
        XCTAssertEqual(records.count, 1)
        XCTAssertLessThanOrEqual(records[0].text.utf8.count, 512)
        XCTAssertTrue(records[0].text.contains("cannot find symbol"))
    }

    func test_sessionLearnNoOpWhenDisabledOrCompleted() throws {
        let appSupport = NSTemporaryDirectory() + "RC2SessionLearn2-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        let learnFile = URL(fileURLWithPath: appSupport).appendingPathComponent("AGENTS.md")
        context.sessionLearnInstructionFilesOverrideForTesting = [learnFile]
        let thread = AgentThread(title: "t", provider: .codex, model: "m")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m", status: .failed, errorMessage: "err")
        try context.runRepo.upsert(run)
        // Disabled => no-op (default off).
        context.recordSessionLearnFromRun(runId: run.id, status: .failed)
        XCTAssertEqual(try SessionLearnRegion(fileURL: learnFile).rules().count, 0)

        // Enabled but completed (not failed/expensive) => no-op.
        SettingsStore(db: context.db).update {
            $0.sessionLearnEnabled = true
            $0.tokenSaverEnabled = true
        }
        context.recordSessionLearnFromRun(runId: run.id, status: .completed)
        XCTAssertEqual(try SessionLearnRegion(fileURL: learnFile).rules().count, 0)
    }

    func test_sessionLearnPromotedInjectsOnlyBoundedExactScopeWhileShadowIsVerbatim() async throws {
        let context = try makeTestContext(
            appSupportOverride: NSTemporaryDirectory() + "RC2SessionLearnPrompt-" + UUID().uuidString
        )
        SettingsStore(db: context.db).update {
            $0.tokenSaverEnabled = true
            $0.sessionLearnEnabled = true
        }
        let thread = AgentThread(
            projectId: ProjectID(), workspaceId: WorkspaceID(), title: "learn",
            provider: .codex, model: "test", status: .completed
        )
        let other = AgentThread(
            projectId: thread.projectId, workspaceId: thread.workspaceId, title: "other",
            provider: .codex, model: "test", status: .completed
        )
        try context.threadRepo.upsert(thread)
        try context.threadRepo.upsert(other)
        let exactScope = TokenSaverSessionLearnScope(
            workspaceID: thread.workspaceId!.value.uuidString,
            projectID: thread.projectId!.value.uuidString,
            threadID: thread.id.value.uuidString,
            provider: AgentProvider.codex.rawValue
        )
        let wrongScope = TokenSaverSessionLearnScope(
            workspaceID: other.workspaceId!.value.uuidString,
            projectID: other.projectId!.value.uuidString,
            threadID: other.id.value.uuidString,
            provider: AgentProvider.codex.rawValue
        )
        try context.tokenSaverSessionLearnRepo.save(text: "preserve browser parity", scope: exactScope, attemptID: "prior")
        try context.tokenSaverSessionLearnRepo.save(text: "wrong scope browser secret", scope: wrongScope, attemptID: "wrong")
        func setLane(_ state: String) throws {
            try context.tokenSaverLaneStateRepo.upsert(.init(
                projectID: thread.projectId!.value.uuidString,
                lane: "session_learn",
                state: state,
                reason: "test",
                evidenceLevel: "provider_usage",
                ownerRole: "Security Owner:test",
                permissionBoundary: "project",
                retentionDays: 30,
                optedOut: false,
                killSwitchActive: false,
                attributionJoined: true,
                reconciliationPassed: true,
                usageSemanticsAvailable: true,
                scorecardID: "semantic-scorecard"
            ))
        }
        let prompt = "Check browser parity."
        try setLane("shadow_only")
        let shadow = await context.coordinator.promptCompressor?(
            prompt,
            AgentPromptSemanticSource(prompt),
            .codex,
            thread.id,
            AgentRunID()
        )
        let shadowWire = try XCTUnwrap(shadow)
        XCTAssertEqual(shadowWire, prompt)
        XCTAssertNil(SR2WirePolicy.userInstruction(in: shadowWire), shadowWire)
        XCTAssertFalse(shadowWire.contains("preserve browser parity"))

        try setLane("promoted")
        let promotedValue = await context.coordinator.promptCompressor?(
            prompt,
            AgentPromptSemanticSource(prompt),
            .codex,
            thread.id,
            AgentRunID()
        )
        let promoted = try XCTUnwrap(promotedValue)
        XCTAssertTrue(promoted.contains("preserve browser parity"))
        XCTAssertFalse(promoted.contains("wrong scope browser secret"))
        XCTAssertLessThanOrEqual(promoted.utf8.count - prompt.utf8.count, 560)

        // A command-shaped user request must stay typed text. SessionLearn is
        // appended as host context, not compiled into a v1 command grammar.
        let commandPrompt = "Execute apenas `command -v swift; command -v distill` e retorne exatamente as duas linhas. Não edite arquivos."
        try context.tokenSaverSessionLearnRepo.save(
            text: "preserve command output",
            scope: exactScope,
            attemptID: "command-prior"
        )
        let commandValue = await context.coordinator.promptCompressor?(
            commandPrompt,
            AgentPromptSemanticSource(commandPrompt),
            .codex,
            thread.id,
            AgentRunID()
        )
        let commandWire = try XCTUnwrap(commandValue)
        let expectedProviderPrompt = commandPrompt
            + "\n\nSESSION_LEARN_EXACT_SCOPE:\n- preserve command output"
        XCTAssertEqual(
            commandWire,
            expectedProviderPrompt,
            "an unrepresentable trusted SessionLearn segment stays on the natural prompt, not a u: dump: \(commandWire)"
        )
        XCTAssertTrue(commandWire.contains("preserve command output"), commandWire)
        XCTAssertNil(SR2WirePolicy.userInstruction(in: commandWire), commandWire)
    }

    func test_promotedSidecarLegacyV0CannotDropTrustedSessionLearnSemantics() async throws {
        // WHY: a shorter legacy v0 sidecar response can preserve pinned command
        // literals while omitting a non-literal constraint and the host-owned
        // SessionLearn context. Rejected recompilation must return the complete
        // provider prompt, not that apparently-safe v0 stub.
        let appSupport = NSTemporaryDirectory() + "RC2SessionLearnLegacyV0-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update {
            $0.tokenSaverEnabled = true
            $0.sessionLearnEnabled = true
        }
        let threadID = try makeAdmittedTokenSaverThread(in: context, provider: .codex)
        let thread = try XCTUnwrap(context.threadRepo.get(id: threadID))
        let projectID = try XCTUnwrap(thread.projectId?.value.uuidString)
        try context.tokenSaverLaneStateRepo.upsert(.init(
            projectID: projectID,
            lane: "semantic_prose",
            state: "promoted",
            reason: "test",
            evidenceLevel: "provider_usage",
            ownerRole: "Security Owner:test",
            permissionBoundary: "project",
            retentionDays: 30,
            optedOut: false,
            killSwitchActive: false,
            attributionJoined: true,
            reconciliationPassed: true,
            usageSemanticsAvailable: true,
            scorecardID: "semantic-scorecard"
        ))
        try context.tokenSaverLaneStateRepo.upsert(.init(
            projectID: projectID,
            lane: "session_learn",
            state: "promoted",
            reason: "test",
            evidenceLevel: "provider_usage",
            ownerRole: "Security Owner:test",
            permissionBoundary: "project",
            retentionDays: 30,
            optedOut: false,
            killSwitchActive: false,
            attributionJoined: true,
            reconciliationPassed: true,
            usageSemanticsAvailable: true,
            scorecardID: "session-learn-scorecard"
        ))
        let exactScope = TokenSaverSessionLearnScope(
            workspaceID: try XCTUnwrap(thread.workspaceId?.value.uuidString),
            projectID: projectID,
            threadID: threadID.value.uuidString,
            provider: AgentProvider.codex.rawValue
        )
        try context.tokenSaverSessionLearnRepo.save(
            text: "preserve command output",
            scope: exactScope,
            attemptID: "legacy-v0-prior"
        )

        let naturalPrompt = "Execute apenas `command -v swift; command -v distill` e retorne exatamente as duas linhas. Não edite arquivos."
        let padding = (0..<80).map {
            "context fragment \(String(repeating: "x", count: $0 + 1)) keeps command output guidance available for the provider."
        }.joined(separator: "\n")
        let prompt = naturalPrompt + "\n" + padding
        XCTAssertGreaterThan(prompt.count, 2_000)
        let learned = "- preserve command output"
        let expectedProviderPrompt = prompt + "\n\nSESSION_LEARN_EXACT_SCOPE:\n" + learned
        let legacyV0 = """
        @sr2 v0
        u:Execute apenas `command -v swift; command -v distill` e retorne exatamente as duas linhas. \(learned)
        o:cont
        """
        XCTAssertTrue(SR2WirePolicy.isSR2(legacyV0), legacyV0)
        XCTAssertLessThan(legacyV0.utf8.count, prompt.utf8.count)
        XCTAssertTrue(legacyV0.contains(learned), legacyV0)
        XCTAssertFalse(legacyV0.contains("Não edite arquivos."), legacyV0)
        XCTAssertTrue(
            LiteralPreservation.preservesLiterals(
                original: expectedProviderPrompt,
                compressed: legacyV0
            ),
            "the sidecar stub must pass literal preservation while still being semantically incomplete"
        )

        let runtime = FixedOutputCountingRuntime(output: legacyV0)
        let configuration = try DistillServiceConfiguration(
            authToken: "legacy-v0-token",
            appSupportDirectory: appSupport
        )
        let scheduler = DistillScheduler(
            runtime: runtime,
            maxConcurrentRequests: 2,
            resultCacheCapacity: 0
        )
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: scheduler,
            scopedRecoveryStore: TestScopedRecoveryStore(db: context.db)
        )
        let ready = try await server.start()
        defer { server.stop() }
        context.distillClientOverrideForTesting = DistillServiceClient(
            ready: ready,
            authToken: "legacy-v0-token"
        )

        let outputValue = await context.coordinator.promptCompressor?(
            prompt,
            AgentPromptSemanticSource(prompt),
            .codex,
            threadID,
            AgentRunID()
        )
        let output = try XCTUnwrap(outputValue)
        let sidecarCallCount = await runtime.count
        XCTAssertEqual(sidecarCallCount, 0, "the send path must not compile the user prompt through Distill")
        XCTAssertEqual(
            output,
            expectedProviderPrompt,
            "user text plus SessionLearn must stay verbatim — never a compiled SR2 stub"
        )
        XCTAssertTrue(output.contains("SESSION_LEARN_EXACT_SCOPE:"), output)
        XCTAssertTrue(output.contains("Não edite arquivos."), output)
        XCTAssertTrue(output.contains(learned), output)
    }

    func test_sessionLearnExpensiveRunWritesBoundedExactScope() throws {
        let appSupport = NSTemporaryDirectory() + "RC2SessionLearnTokens-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update {
            $0.sessionLearnEnabled = true
            $0.tokenSaverEnabled = true
        }
        let learnFile = URL(fileURLWithPath: appSupport).appendingPathComponent("AGENTS.md")
        context.sessionLearnInstructionFilesOverrideForTesting = [learnFile]

        let thread = AgentThread(
            projectId: ProjectID(),
            workspaceId: WorkspaceID(),
            title: "t",
            provider: .claude,
            model: "m"
        )
        try context.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "m",
            status: .running,
            errorMessage: "near context limit: replayed redundant tool output"
        )
        try context.runRepo.upsert(run)
        try context.tokenSaverLaneStateRepo.upsert(.init(
            projectID: thread.projectId!.value.uuidString,
            lane: "session_learn",
            state: "shadow_only",
            reason: "test_shadow",
            evidenceLevel: "diagnostic_heuristic",
            ownerRole: "Security Owner:test",
            permissionBoundary: "project",
            retentionDays: 30,
            optedOut: false,
            killSwitchActive: false,
            attributionJoined: true,
            reconciliationPassed: true,
            usageSemanticsAvailable: true,
            scorecardID: "rollover-scorecard"
        ))

        context.coordinator.onAssistantEvent?(
            .tokenUsage(AssistantTokenUsage(inputTokens: 80_000, outputTokens: 10, totalTokens: 80_010)),
            thread.id,
            run.id
        )
        context.recordSessionLearnFromRun(runId: run.id, status: .completed)

        XCTAssertEqual(try SessionLearnRegion(fileURL: learnFile).rules().count, 0)
        let scope = TokenSaverSessionLearnScope(
            workspaceID: thread.workspaceId!.value.uuidString,
            projectID: thread.projectId!.value.uuidString,
            threadID: thread.id.value.uuidString,
            provider: AgentProvider.claude.rawValue
        )
        let records = try context.tokenSaverSessionLearnRepo.topK(scope: scope, byteBudget: 1_024, limit: 5)
        XCTAssertEqual(records.count, 1)
        XCTAssertLessThanOrEqual(records[0].text.utf8.count, 512)
    }

    func test_rolloverRequiresPromotedLaneAndPreservesParentThread() throws {
        let context = try makeTestContext(
            appSupportOverride: NSTemporaryDirectory() + "RC2Rollover-" + UUID().uuidString
        )
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let parent = AgentThread(
            projectId: ProjectID(),
            workspaceId: WorkspaceID(),
            title: "long task",
            provider: .codex,
            model: "gpt-test",
            status: .completed
        )
        try context.threadRepo.upsert(parent)
        try context.messageRepo.append(.init(threadId: parent.id, role: .user, content: "Preserve ABC-123 and browser parity."))

        XCTAssertThrowsError(try context.createTokenSaverRollover(parentThreadID: parent.id, maxBytes: 1_024))
        try context.tokenSaverLaneStateRepo.upsert(.init(
            projectID: parent.projectId!.value.uuidString,
            lane: "rollover_capsule",
            state: "promoted",
            reason: "test_gate_passed",
            evidenceLevel: "provider_usage",
            ownerRole: "Provider Compatibility Owner:test",
            permissionBoundary: "project",
            retentionDays: 30,
            optedOut: false,
            killSwitchActive: false,
            attributionJoined: true,
            reconciliationPassed: true,
            usageSemanticsAvailable: true,
            scorecardID: "rollover-scorecard"
        ))

        let child = try context.createTokenSaverRollover(parentThreadID: parent.id, maxBytes: 1_024)
        XCTAssertEqual(try context.messageRepo.list(threadId: parent.id).map(\.content), ["Preserve ABC-123 and browser parity."])
        let childMessages = try context.messageRepo.list(threadId: child.id)
        XCTAssertEqual(childMessages.count, 1)
        XCTAssertEqual(childMessages[0].role, .system)
        XCTAssertTrue(childMessages[0].content.contains("ABC-123"))
        XCTAssertNotNil(try context.tokenSaverRolloverRepo.get(childThreadID: child.id.value.uuidString))
    }

    func test_rolloverAdmissionRequiresGlobalEnableAuthoritativeReceiptAndAssignedOwner() throws {
        // WHY: rollover is lossy context replacement. UI and execution must share
        // one fail-closed decision for every promotion receipt and ownership gate.
        let context = try makeTestContext(
            appSupportOverride: NSTemporaryDirectory() + "RC2RolloverAdmission-" + UUID().uuidString
        )
        let parent = AgentThread(
            projectId: ProjectID(), workspaceId: WorkspaceID(), title: "admission",
            provider: .codex, model: "test", status: .completed
        )
        try context.threadRepo.upsert(parent)

        func setLane(evidence: String, owner: String) throws {
            try context.tokenSaverLaneStateRepo.upsert(.init(
                projectID: parent.projectId!.value.uuidString,
                lane: "rollover_capsule",
                state: "promoted",
                reason: "test",
                evidenceLevel: evidence,
                ownerRole: owner,
                permissionBoundary: "project",
                retentionDays: 30,
                optedOut: false,
                killSwitchActive: false,
                attributionJoined: true,
                reconciliationPassed: true,
                usageSemanticsAvailable: true,
                scorecardID: "rollover-scorecard"
            ))
        }

        try setLane(evidence: "provider_usage", owner: "Operations Owner:test")
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = false }
        XCTAssertEqual(context.tokenSaverRolloverAdmission(parentThreadID: parent.id).reason, "globally_disabled")

        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        try setLane(evidence: "diagnostic_heuristic", owner: "Operations Owner:test")
        XCTAssertEqual(context.tokenSaverRolloverAdmission(parentThreadID: parent.id).reason, "evidence_not_authoritative")

        try setLane(evidence: "provider_usage", owner: "unassigned:operations")
        XCTAssertEqual(context.tokenSaverRolloverAdmission(parentThreadID: parent.id).reason, "owner_unassigned")

        try setLane(evidence: "provider_usage", owner: "Operations Owner:test")
        XCTAssertEqual(
            context.tokenSaverRolloverAdmission(parentThreadID: parent.id),
            .init(allowed: true, reason: "admitted")
        )
    }

    func test_rolloverRejectsBusyParentAndCleansChildWhenCapsuleWriteFails() throws {
        let context = try makeTestContext(
            appSupportOverride: NSTemporaryDirectory() + "RC2RolloverFailure-" + UUID().uuidString
        )
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        var parent = AgentThread(
            projectId: ProjectID(),
            workspaceId: WorkspaceID(),
            title: "busy task",
            provider: .grok,
            model: "grok-test",
            status: .running
        )
        try context.threadRepo.upsert(parent)
        try context.tokenSaverLaneStateRepo.upsert(.init(
            projectID: parent.projectId!.value.uuidString,
            lane: "rollover_capsule",
            state: "promoted",
            reason: "test_gate_passed",
            evidenceLevel: "provider_usage",
            ownerRole: "Provider Compatibility Owner:test",
            permissionBoundary: "project",
            retentionDays: 30,
            optedOut: false,
            killSwitchActive: false,
            attributionJoined: true,
            reconciliationPassed: true,
            usageSemanticsAvailable: true,
            scorecardID: "rollover-scorecard"
        ))
        XCTAssertThrowsError(try context.createTokenSaverRollover(parentThreadID: parent.id)) { error in
            XCTAssertEqual(error as? TokenSaverRolloverError, .parentBusy(.running))
        }

        parent.status = .completed
        try context.threadRepo.upsert(parent)
        try context.messageRepo.append(.init(threadId: parent.id, role: .user, content: "latest exact message"))
        try context.db.execute("""
            CREATE TRIGGER fail_rollover_capsule_insert
            BEFORE INSERT ON token_saver_rollover_capsules
            BEGIN SELECT RAISE(ABORT, 'forced capsule failure'); END;
        """)
        XCTAssertThrowsError(try context.createTokenSaverRollover(parentThreadID: parent.id))
        XCTAssertEqual(try context.threadRepo.list().map(\.id), [parent.id],
                       "failed capsule persistence must compensate the child thread and its message")
    }

    func test_rolloverRejectsMessageRaceAndLeavesNoChildOrCapsule() throws {
        let context = try makeTestContext(
            appSupportOverride: NSTemporaryDirectory() + "RC2RolloverRace-" + UUID().uuidString
        )
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let parent = AgentThread(
            projectId: ProjectID(), workspaceId: WorkspaceID(), title: "race",
            provider: .codex, model: "test", status: .completed
        )
        try context.threadRepo.upsert(parent)
        try context.messageRepo.append(.init(threadId: parent.id, role: .user, content: "first"))
        try context.tokenSaverLaneStateRepo.upsert(.init(
            projectID: parent.projectId!.value.uuidString,
            lane: "rollover_capsule",
            state: "promoted",
            reason: "test",
            evidenceLevel: "provider_usage",
            ownerRole: "Operations Owner:test",
            permissionBoundary: "project",
            retentionDays: 30,
            optedOut: false,
            killSwitchActive: false,
            attributionJoined: true,
            reconciliationPassed: true,
            usageSemanticsAvailable: true,
            scorecardID: "rollover-scorecard"
        ))
        context.tokenSaverRolloverBeforeCommitForTesting = {
            try context.messageRepo.append(.init(threadId: parent.id, role: .user, content: "racing newest"))
        }

        XCTAssertThrowsError(try context.createTokenSaverRollover(parentThreadID: parent.id)) {
            XCTAssertEqual($0 as? TokenSaverRolloverError, .parentChanged)
        }
        XCTAssertEqual(try context.threadRepo.list().map(\.id), [parent.id])
        XCTAssertEqual(try context.messageRepo.list(threadId: parent.id).map(\.content), ["first", "racing newest"])
    }

    func test_rolloverCompensatesChildAndCapsuleWhenPostCreateLifecycleFails() throws {
        let context = try makeTestContext(
            appSupportOverride: NSTemporaryDirectory() + "RC2RolloverPostSweep-" + UUID().uuidString
        )
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let parent = AgentThread(
            projectId: ProjectID(), workspaceId: WorkspaceID(), title: "post sweep",
            provider: .claude, model: "test", status: .completed
        )
        try context.threadRepo.upsert(parent)
        try context.messageRepo.append(.init(threadId: parent.id, role: .user, content: "newest exact"))
        try context.tokenSaverLaneStateRepo.upsert(.init(
            projectID: parent.projectId!.value.uuidString,
            lane: "rollover_capsule",
            state: "promoted",
            reason: "test",
            evidenceLevel: "provider_usage",
            ownerRole: "Operations Owner:test",
            permissionBoundary: "project",
            retentionDays: 30,
            optedOut: false,
            killSwitchActive: false,
            attributionJoined: true,
            reconciliationPassed: true,
            usageSemanticsAvailable: true,
            scorecardID: "rollover-scorecard"
        ))
        context.tokenSaverRolloverBeforeCommitForTesting = {
            try context.tokenSaverSessionLearnRepo.save(
                text: "expires between sweeps",
                scope: .init(workspaceID: "w", projectID: "p", threadID: "t", provider: "claude"),
                attemptID: "post",
                now: Date(timeIntervalSince1970: 10),
                expiresAt: Date(timeIntervalSince1970: 20)
            )
            try context.db.execute("""
                CREATE TRIGGER fail_post_rollover_lifecycle
                BEFORE UPDATE ON token_saver_session_learn_records
                BEGIN SELECT RAISE(ABORT, 'forced post-create sweep failure'); END;
            """)
        }

        XCTAssertThrowsError(try context.createTokenSaverRollover(parentThreadID: parent.id))
        XCTAssertEqual(try context.threadRepo.list().map(\.id), [parent.id])
        let capsules = try context.db.prepare("SELECT COUNT(*) FROM token_saver_rollover_capsules;")
        XCTAssertTrue(try capsules.step())
        XCTAssertEqual(capsules.columnInt64(0), 0)
    }

    func test_rolloverAtCapPrunesEligibleVictimAndPublishesAfterGraphCommit() throws {
        let context = try makeTestContext(
            appSupportOverride: NSTemporaryDirectory() + "RC2RolloverCap-" + UUID().uuidString
        )
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let workspaceID = WorkspaceID()
        let projectID = ProjectID()
        var victim = AgentThread(
            projectId: projectID,
            workspaceId: workspaceID,
            title: "old eligible",
            provider: .codex,
            model: "test",
            status: .completed
        )
        victim.updatedAt = Date(timeIntervalSince1970: 1)
        try context.threadRepo.upsert(victim)
        var parent = AgentThread(
            projectId: projectID,
            workspaceId: workspaceID,
            title: "rollover parent",
            provider: .codex,
            model: "test",
            status: .completed
        )
        parent.pinned = true
        parent.updatedAt = Date()
        try context.threadRepo.upsert(parent)
        var originalIDs: Set<AgentThreadID> = [victim.id, parent.id]
        for index in 0..<(AgentThreadRepository.maxThreadsPerWorkspace - 2) {
            var thread = AgentThread(
                projectId: projectID,
                workspaceId: workspaceID,
                title: "protected \(index)",
                provider: .codex,
                model: "test"
            )
            thread.status = .running
            try context.threadRepo.upsert(thread)
            originalIDs.insert(thread.id)
        }
        try context.messageRepo.append(.init(threadId: parent.id, role: .user, content: "preserve rollover context"))
        try context.tokenSaverLaneStateRepo.upsert(.init(
            projectID: projectID.value.uuidString,
            lane: "rollover_capsule",
            state: "promoted",
            reason: "test",
            evidenceLevel: "provider_usage",
            ownerRole: "Operations Owner:test",
            permissionBoundary: "project",
            retentionDays: 30,
            optedOut: false,
            killSwitchActive: false,
            attributionJoined: true,
            reconciliationPassed: true,
            usageSemanticsAvailable: true,
            scorecardID: "rollover-scorecard"
        ))
        var lifecycleEvents: [EventBus.Event] = []
        var callbackObservedCommittedGraph = false
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "agent.thread.deleted" || event.kind == "agent.thread.deleted_many" else { return }
            lifecycleEvents.append(event)
            do {
                let statement = try context.db.prepare(
                    "SELECT child_thread_id FROM token_saver_rollover_capsules LIMIT 1;"
                )
                guard try statement.step(),
                      let rawChildID = statement.columnText(0),
                      let uuid = UUID(uuidString: rawChildID) else { return }
                let childID = AgentThreadID(uuid)
                callbackObservedCommittedGraph = try context.threadRepo.get(id: childID) != nil
                    && !context.messageRepo.list(threadId: childID).isEmpty
                    && context.tokenSaverRolloverRepo.get(childThreadID: rawChildID) != nil
            } catch {}
        }
        defer { EventBus.shared.unsubscribe(token) }

        let child = try context.createTokenSaverRollover(parentThreadID: parent.id)

        XCTAssertEqual(
            Set(try context.threadRepo.list(workspaceId: workspaceID).map(\.id)),
            originalIDs.subtracting([victim.id]).union([child.id])
        )
        XCTAssertNotNil(try context.tokenSaverRolloverRepo.get(childThreadID: child.id.value.uuidString))
        XCTAssertEqual(lifecycleEvents.count, 1,
                       "the committed rollover must publish its authoritative victim exactly once")
        XCTAssertTrue(callbackObservedCommittedGraph,
                      "the deletion callback must observe child, capsule message, and capsule after one atomic commit")
    }

    func test_rolloverAtCap_graphWriteFailureRollsBackVictimAndPublishesNothing() throws {
        let context = try makeTestContext(
            appSupportOverride: NSTemporaryDirectory() + "RC2RolloverCapRollback-" + UUID().uuidString
        )
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let workspaceID = WorkspaceID()
        let projectID = ProjectID()
        var victim = AgentThread(
            projectId: projectID,
            workspaceId: workspaceID,
            title: "victim must survive",
            provider: .codex,
            model: "test",
            status: .completed
        )
        victim.updatedAt = Date(timeIntervalSince1970: 1)
        try context.threadRepo.upsert(victim)
        var parent = AgentThread(
            projectId: projectID,
            workspaceId: workspaceID,
            title: "rollover parent",
            provider: .codex,
            model: "test",
            status: .completed
        )
        parent.pinned = true
        parent.updatedAt = Date()
        try context.threadRepo.upsert(parent)
        var originalIDs: Set<AgentThreadID> = [victim.id, parent.id]
        for index in 0..<(AgentThreadRepository.maxThreadsPerWorkspace - 2) {
            var protected = AgentThread(
                projectId: projectID,
                workspaceId: workspaceID,
                title: "protected \(index)",
                provider: .codex,
                model: "test"
            )
            protected.status = .running
            try context.threadRepo.upsert(protected)
            originalIDs.insert(protected.id)
        }
        try context.messageRepo.append(.init(threadId: parent.id, role: .user, content: "preserve parent"))
        try context.tokenSaverLaneStateRepo.upsert(.init(
            projectID: projectID.value.uuidString,
            lane: "rollover_capsule",
            state: "promoted",
            reason: "test",
            evidenceLevel: "provider_usage",
            ownerRole: "Operations Owner:test",
            permissionBoundary: "project",
            retentionDays: 30,
            optedOut: false,
            killSwitchActive: false,
            attributionJoined: true,
            reconciliationPassed: true,
            usageSemanticsAvailable: true,
            scorecardID: "rollover-scorecard"
        ))
        try context.db.execute("""
            CREATE TRIGGER fail_capped_rollover_capsule
            BEFORE INSERT ON token_saver_rollover_capsules
            BEGIN SELECT RAISE(ABORT, 'forced capped capsule failure'); END;
        """)
        var lifecycleEvents: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind.hasPrefix("agent.thread.") else { return }
            lifecycleEvents.append(event)
        }
        defer { EventBus.shared.unsubscribe(token) }

        XCTAssertThrowsError(try context.createTokenSaverRollover(parentThreadID: parent.id))

        XCTAssertEqual(Set(try context.threadRepo.list(workspaceId: workspaceID).map(\.id)), originalIDs)
        XCTAssertNotNil(try context.threadRepo.get(id: victim.id),
                        "a graph write failure must roll back the tentative cap victim")
        let capsules = try context.db.prepare("SELECT COUNT(*) FROM token_saver_rollover_capsules;")
        XCTAssertTrue(try capsules.step())
        XCTAssertEqual(capsules.columnInt64(0), 0)
        XCTAssertTrue(lifecycleEvents.isEmpty,
                      "rolled-back rollover graph and victim deletes must publish no lifecycle")
    }

    func test_rolloverProtectedCapacityFailsBeforeGraphWritesAndPublishesNothing() throws {
        let context = try makeTestContext(
            appSupportOverride: NSTemporaryDirectory() + "RC2RolloverProtectedCap-" + UUID().uuidString
        )
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let workspaceID = WorkspaceID()
        let projectID = ProjectID()
        let parent = AgentThread(
            projectId: projectID,
            workspaceId: workspaceID,
            title: "only eligible parent",
            provider: .codex,
            model: "test",
            status: .completed
        )
        try context.threadRepo.upsert(parent)
        var originalIDs: Set<AgentThreadID> = [parent.id]
        for index in 0..<(AgentThreadRepository.maxThreadsPerWorkspace - 1) {
            var thread = AgentThread(
                projectId: projectID,
                workspaceId: workspaceID,
                title: "protected \(index)",
                provider: .codex,
                model: "test"
            )
            thread.status = .running
            try context.threadRepo.upsert(thread)
            originalIDs.insert(thread.id)
        }
        try context.messageRepo.append(.init(threadId: parent.id, role: .user, content: "must remain unchanged"))
        try context.tokenSaverLaneStateRepo.upsert(.init(
            projectID: projectID.value.uuidString,
            lane: "rollover_capsule",
            state: "promoted",
            reason: "test",
            evidenceLevel: "provider_usage",
            ownerRole: "Operations Owner:test",
            permissionBoundary: "project",
            retentionDays: 30,
            optedOut: false,
            killSwitchActive: false,
            attributionJoined: true,
            reconciliationPassed: true,
            usageSemanticsAvailable: true,
            scorecardID: "rollover-scorecard"
        ))
        var lifecycleEvents: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind.hasPrefix("agent.thread.") else { return }
            lifecycleEvents.append(event)
        }
        defer { EventBus.shared.unsubscribe(token) }

        XCTAssertThrowsError(try context.createTokenSaverRollover(parentThreadID: parent.id)) { error in
            XCTAssertTrue(error is AgentThreadCapacityError)
            XCTAssertTrue(error.localizedDescription.contains("Agent thread capacity exceeded"))
        }

        XCTAssertEqual(Set(try context.threadRepo.list(workspaceId: workspaceID).map(\.id)), originalIDs)
        let capsules = try context.db.prepare("SELECT COUNT(*) FROM token_saver_rollover_capsules;")
        XCTAssertTrue(try capsules.step())
        XCTAssertEqual(capsules.columnInt64(0), 0)
        XCTAssertTrue(lifecycleEvents.isEmpty)
    }

    func test_tokenSaverOffKeepsSR1ByteIdenticalWithoutClientOrLedgerWrites() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2SR1OffLane-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = false }

        let runtime = CountingEchoRuntime()
        let configuration = try DistillServiceConfiguration(
            authToken: "off-lane-token",
            appSupportDirectory: appSupport
        )
        let scheduler = DistillScheduler(runtime: runtime, maxConcurrentRequests: 1)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
        let ready = try await server.start()
        defer { server.stop() }
        context.distillClientOverrideForTesting = DistillServiceClient(
            ready: ready,
            authToken: "off-lane-token"
        )

        let thread = AgentThread(title: "off lane", provider: .grok, model: "test", status: .completed)
        try context.threadRepo.upsert(thread)
        let sr1 = """
        SR1
        S=done
        O=The result is ready.
        """

        let result = await context.tokenSaverHumanizeSR1Response(sr1, provider: .grok, threadId: thread.id)

        XCTAssertEqual(result, sr1, "Token Saver OFF must preserve provider bytes exactly")
        let clientCallCount = await runtime.callCount
        XCTAssertEqual(clientCallCount, 0, "an already-live sidecar client must not be called")
        XCTAssertEqual(try context.tokenSaverSavingsRepo.summary().totalRuns, 0)
        XCTAssertEqual(
            TokenSaverUsageStore(
                appSupportDirectory: URL(fileURLWithPath: appSupport, isDirectory: true)
            ).load().usedTokens,
            0,
            "SR1 rewrite gating must not synthesize local provider usage"
        )
        let attempts = try context.db.prepare("SELECT COUNT(*) FROM token_saver_attempts;")
        XCTAssertTrue(try attempts.step())
        XCTAssertEqual(attempts.columnInt64(0), 0)
        let auditEvents = try context.db.prepare("SELECT COUNT(*) FROM token_saver_audit_events;")
        XCTAssertTrue(try auditEvents.step())
        XCTAssertEqual(auditEvents.columnInt64(0), 0)
    }

    func test_tokenSaverHumanizesSR1FinalResponseThroughDistillClientInUserLanguage() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverHumanizeSR1-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        let configuration = try DistillServiceConfiguration(
            authToken: "humanize-token",
            appSupportDirectory: appSupport
        )
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 4)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
        let ready = try await server.start()
        defer { server.stop() }
        context.distillClientOverrideForTesting = DistillServiceClient(ready: ready, authToken: "humanize-token")

        let thread = AgentThread(title: "sr1", provider: .codex, model: "fake-model")
        try context.threadRepo.upsert(thread)
        try admitTokenSaver(in: context, threadID: thread.id)
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "/distill Responda em portugues o resultado dos testes."
        ))
        let sr1 = """
        SR1
        S: tests green
        C: user asked in Portuguese
        O: saved counter updated
        P: macOS suite passed
        """

        let humanized = await context.tokenSaverHumanizeSR1Response(sr1, provider: .codex, threadId: thread.id)

        XCTAssertFalse(SR1ResponseDetector.isSR1(humanized),
                       "the Agent App must store the human-language answer, not another SR1 block")
        // Fail-open UI prefers O (outcome) over ops chrome (S/C/D). Portuguese is
        // still the target language for the Distill request when the sidecar answers.
        XCTAssertTrue(
            humanized.contains("saved counter updated") || humanized.localizedCaseInsensitiveContains("estado"),
            "humanized answer must surface the SR1 outcome (or a PT-labeled expansion)"
        )
        XCTAssertTrue(
            humanized.contains("macOS suite passed") || humanized.localizedCaseInsensitiveContains("prova"),
            "proof line remains available when present on the SR1 block"
        )
    }

    func test_tokenSaverHumanizeRejectsMixedWireLeakAndUsesDeterministicFallback() async throws {
        // WHY: a sidecar can prepend ordinary prose to a raw SR2 marker. The
        // complete translation must be rejected at the trusted humanize
        // boundary so control fields never become UI text.
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverHumanizeMixedWire-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        let configuration = try DistillServiceConfiguration(
            authToken: "mixed-humanize-token",
            appSupportDirectory: appSupport
        )
        let leaked = "ok\n@sr2 v0\ng:remote-code-orchestrate"
        let scheduler = DistillScheduler(
            runtime: FixedOutputRuntime(output: leaked),
            maxConcurrentRequests: 4
        )
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
        let ready = try await server.start()
        defer { server.stop() }
        context.distillClientOverrideForTesting = DistillServiceClient(
            ready: ready,
            authToken: "mixed-humanize-token"
        )

        let thread = AgentThread(title: "mixed wire", provider: .codex, model: "fake-model")
        try context.threadRepo.upsert(thread)
        try admitTokenSaver(in: context, threadID: thread.id)
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "Summarize the completed test result."
        ))
        let sr1 = """
        SR1
        S: tests green
        C: user asked for a summary
        O: saved counter updated
        P: macOS suite passed
        """

        let humanized = await context.tokenSaverHumanizeSR1Response(
            sr1,
            provider: .codex,
            threadId: thread.id
        )

        XCTAssertEqual(
            humanized,
            "saved counter updated\nmacOS suite passed",
            "a mixed marker leak must use the clean deterministic fallback"
        )
        XCTAssertFalse(humanized.contains("@sr2"), humanized)
        XCTAssertFalse(humanized.contains("g:remote-code-orchestrate"), humanized)
    }

    func test_tokenSaverHumanizeExactR9ProjectlessFallbackPreservesEveryProof() async throws {
        // WHY: live R9 had no project_id. Its humanize row carried
        // missing_project_scope and the local model returned a partial rendering
        // (`done\n@sr2...`) that lost p:2/p:3 in the visible final. This freezes
        // the exact 190-byte provider wire and the same projectless audit path.
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverHumanizeR9-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        let configuration = try DistillServiceConfiguration(
            authToken: "r9-humanize-token",
            appSupportDirectory: appSupport
        )
        let leaked = "done\n@sr2 v0\n1=/Users/samuelfajreldines/.remote-code/bin/swift;/Users/samuelfajreldines/.remote-code/bin/distill"
        let scheduler = DistillScheduler(runtime: FixedOutputRuntime(output: leaked), maxConcurrentRequests: 4)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
        let ready = try await server.start()
        defer { server.stop() }
        context.distillClientOverrideForTesting = DistillServiceClient(
            ready: ready,
            authToken: "r9-humanize-token"
        )

        let thread = AgentThread(title: "R9 projectless", provider: .codex, model: "fake-model")
        XCTAssertNil(thread.projectId, "fixture must exercise missing_project_scope")
        try context.threadRepo.upsert(thread)
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "Report the exact completed checks in English."
        ))
        let wire = "@sr2 v0\no:done\np:1=/Users/samuelfajreldines/.remote-code/bin/swift;/Users/samuelfajreldines/.remote-code/bin/distill\np:2=3:UNIQUE_EXACT_MATCH=sr2-e2e-20260811\np:3=swift noisy.swift completed"
        XCTAssertEqual(wire.utf8.count, 190)

        let humanized = await context.tokenSaverHumanizeSR1Response(
            wire,
            provider: .codex,
            threadId: thread.id
        )

        XCTAssertFalse(humanized.localizedCaseInsensitiveContains("@sr2"), humanized)
        XCTAssertFalse(humanized.contains("p:1="), humanized)
        XCTAssertTrue(humanized.contains("/Users/samuelfajreldines/.remote-code/bin/swift"), humanized)
        XCTAssertTrue(humanized.contains("/Users/samuelfajreldines/.remote-code/bin/distill"), humanized)
        XCTAssertTrue(humanized.contains("3:UNIQUE_EXACT_MATCH=sr2-e2e-20260811"), humanized)
        XCTAssertTrue(humanized.contains("swift noisy.swift completed"), humanized)

        let row = try context.db.prepare("""
            SELECT governance_json, delivered
            FROM token_saver_savings
            WHERE mode LIKE 'sr1-humanize%'
            ORDER BY id DESC LIMIT 1;
        """)
        XCTAssertTrue(try row.step(), "projectless fallback must remain auditable")
        XCTAssertTrue((row.columnText(0) ?? "").contains("missing_project_scope"))
        XCTAssertEqual(row.columnInt64(1), 1, "the deterministic visible fallback was delivered")
    }

    func test_tokenSaverHumanizeExactR17InvalidBannerUsesCleanFallback() async throws {
        // WHY: strict SR2 validation rejected the live `o:swift=...` outcome and
        // the old enforced-free-prose shortcut returned all 401 wire characters
        // before either the local humanizer or deterministic fallback could run.
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverHumanizeR17-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        let wire = "@sr2 v1\ng:run-summary\no:swift=/tmp/RemoteCodeAgentCanary-r17.9NjZ6W/state/Application Support/RemoteCodeAgentCanary/ManagedIntegrationHome/.remote-code/bin/swift; distill=/tmp/RemoteCodeAgentCanary-r17.9NjZ6W/state/Application Support/RemoteCodeAgentCanary/ManagedIntegrationHome/.remote-code/bin/distill\\nREADME.md:3 UNIQUE_EXACT_MATCH=sr2-e2e-20260811; noisy.swift=200 lines\nd:exit=0; files-edited=0"
        XCTAssertEqual(wire.count, 401)
        XCTAssertEqual(
            SHA256.hash(data: Data(wire.utf8)).map { String(format: "%02x", $0) }.joined(),
            "f1e7839008cd5493b45b4dc9d861396773c2720b1ca3957f2c332de64c16d99a"
        )
        XCTAssertFalse(SR2WirePolicy.isSR2(wire), "strict compliance remains fail-closed")

        let configuration = try DistillServiceConfiguration(
            authToken: "r17-humanize-token",
            appSupportDirectory: appSupport
        )
        let scheduler = DistillScheduler(
            runtime: FixedOutputRuntime(output: wire),
            maxConcurrentRequests: 4
        )
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
        let ready = try await server.start()
        defer { server.stop() }
        context.distillClientOverrideForTesting = DistillServiceClient(
            ready: ready,
            authToken: "r17-humanize-token"
        )

        let thread = AgentThread(title: "R17 final", provider: .codex, model: "fake-model")
        try context.threadRepo.upsert(thread)
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "Report the exact command results in English."
        ))

        let humanized = await context.tokenSaverHumanizeSR1Response(
            wire,
            provider: .codex,
            threadId: thread.id
        )

        XCTAssertNotEqual(humanized, wire)
        XCTAssertFalse(humanized.localizedCaseInsensitiveContains("@sr2"), humanized)
        XCTAssertTrue(humanized.contains("swift"), humanized)
        XCTAssertTrue(humanized.contains("distill"), humanized)
        XCTAssertTrue(humanized.contains("UNIQUE_EXACT_MATCH=sr2-e2e-20260811"), humanized)
        XCTAssertTrue(humanized.contains("files-edited=0"), humanized)
    }

    func test_tokenSaverHumanizesSpaceDelimitedDistillResponseThroughDistillClient() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverHumanizeSR1Space-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)

        let configuration = try DistillServiceConfiguration(
            authToken: "humanize-space-token",
            appSupportDirectory: appSupport
        )
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 4)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
        let ready = try await server.start()
        defer { server.stop() }
        context.distillClientOverrideForTesting = DistillServiceClient(ready: ready, authToken: "humanize-space-token")

        let thread = AgentThread(title: "sr1 space", provider: .claude, model: "fake-model")
        try context.threadRepo.upsert(thread)
        try admitTokenSaver(in: context, threadID: thread.id)
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "/distill crie o snage game em html"
        ))
        let sr1 = """
        O Snake game criado.
        O file: /Users/samuelfajreldines/snake.html (single-file, zero deps)
        O feat: canvas 20x20 grid, score, wall+self collision, food respawn, game-over restart
        O ctrl: setas ou WASD; ESPACO reinicia
        P open: abrir snake.html no browser -> jogo roda
        """

        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let humanized = await context.tokenSaverHumanizeSR1Response(sr1, provider: .claude, threadId: thread.id)

        XCTAssertFalse(SR1ResponseDetector.isSR1(humanized),
                       "humanized output must not still look like SR1")
        XCTAssertFalse(humanized.contains("O file:"),
                       "space-delimited O prefixes must be expanded out of the UI answer")
        XCTAssertTrue(humanized.contains("Snake game criado."),
                      "primary outcome remains user-visible")
        XCTAssertTrue(
            humanized.contains("abrir snake.html") || humanized.contains("open:"),
            "proof/open guidance remains available when present"
        )
    }

    func test_tokenSaverHumanizeFallsBackWhenLocalLLMLeavesSR1Dictionary() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverHumanizePartialSR1-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)

        let configuration = try DistillServiceConfiguration(
            authToken: "partial-humanize-token",
            appSupportDirectory: appSupport
        )
        let scheduler = DistillScheduler(runtime: PartialSR1HumanizeRuntime(), maxConcurrentRequests: 4)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
        let ready = try await server.start()
        defer { server.stop() }
        context.distillClientOverrideForTesting = DistillServiceClient(ready: ready, authToken: "partial-humanize-token")

        let thread = AgentThread(title: "sr1 partial", provider: .codex, model: "fake-model")
        try context.threadRepo.upsert(thread)
        try admitTokenSaver(in: context, threadID: thread.id)
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "/distill crie o snage game em html"
        ))
        let sr1 = """
        Dict: S=state C=context D=action R=risk O=outcome N=no-go P=proof #g1=Snake HTML game
        S starting. D load /distill rules, inspect /tmp, then create #g1.
        """

        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let humanized = await context.tokenSaverHumanizeSR1Response(sr1, provider: .codex, threadId: thread.id)

        XCTAssertFalse(humanized.contains("Dict:"),
                       "the Agent App must not display a local-LLM partial translation that still contains the SR1 dictionary")
        XCTAssertFalse(humanized.contains("#g1"),
                       "SR1 variables are for provider compression only and must be expanded before the user sees the answer")
        // Partial SR1 from the local model is rejected → fail-open humanize (may be a
        // cannot-expand notice when the block has no recoverable O/P segments).
        XCTAssertFalse(humanized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "fail-open path must still return a user-facing string")
        XCTAssertFalse(SR1ResponseDetector.isSR1(humanized),
                       "fail-open output must not still look like SR1")
    }

    func test_tokenSaverHumanizedSR1ResponseCreditsDefaultAgentVerbosityFactor() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverSR1OutputSavings-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        let configuration = try DistillServiceConfiguration(
            authToken: "sr1-output-savings-token",
            appSupportDirectory: appSupport
        )
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 4)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
        let ready = try await server.start()
        defer { server.stop() }
        context.distillClientOverrideForTesting = DistillServiceClient(ready: ready, authToken: "sr1-output-savings-token")

        let thread = AgentThread(title: "sr1 output savings", provider: .codex, model: "fake-model")
        try context.threadRepo.upsert(thread)
        try admitTokenSaver(in: context, threadID: thread.id)
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "/distill crie o snage game em html"
        ))
        let sr1 = """
        S ok.
        O /tmp/index.html.
        P pass.
        """
        let runId = AgentRunID()

        let humanized = await context.tokenSaverHumanizeSR1Response(sr1, provider: .codex, threadId: thread.id, runId: runId)
        _ = await context.tokenSaverHumanizeSR1Response(sr1, provider: .codex, threadId: thread.id, runId: runId)

        let summary = try context.tokenSaverSavingsRepo.summary()
        let codex = try XCTUnwrap(summary.savings(for: "codex"))
        // WHY no expansion factor: the 9x credit this used to assert was an
        // uncalibrated counterfactual applied to character counts. Both legs now use
        // the same deterministic token estimator, so the recorded saving is a delta
        // between two texts that were actually produced.
        let perInput = TokenEstimator.estimate(humanized)
        let perOutput = TokenEstimator.estimate(sr1)
        let expectedInput = perInput * 2
        let expectedOutput = perOutput * 2
        let expectedSaved = max(perInput - perOutput, 0) * 2
        XCTAssertEqual(codex.inputTokens, expectedInput,
                       "SR1 humanization accounting records the estimated token size of the humanized text")
        XCTAssertEqual(codex.outputTokens, expectedOutput,
                       "the emitted compressed response is measured with the same estimator")
        XCTAssertEqual(codex.savedTokens, expectedSaved,
                       "saved = estimated humanized tokens - estimated SR1 tokens, per sidecar call, with no credit")
        XCTAssertEqual(codex.runs, 2,
                       "every successful local sidecar humanization call must update Token Saver reports")
    }

    func test_tokenSaverHumanizedSR1FallbackCreditsDefaultAgentVerbosityFactorWhenSidecarUnavailable() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverSR1FallbackSavings-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        let thread = AgentThread(title: "sr1 fallback", provider: .claude, model: "fake-model")
        try context.threadRepo.upsert(thread)
        try admitTokenSaver(in: context, threadID: thread.id)
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "Please answer in English using the compact Token Saver language."
        ))

        let sr1 = """
        S ok.
        O /tmp/index.html created.
        P tests passed.
        """

        let humanized = await context.tokenSaverHumanizeSR1Response(sr1, provider: .claude, threadId: thread.id)

        XCTAssertNotEqual(humanized, sr1)
        let summary = try context.tokenSaverSavingsRepo.summary()
        let claude = try XCTUnwrap(summary.savings(for: "claude"),
                                   "fallback SR1 expansion still saves output tokens and must be visible in the report")
        // Same estimator on both legs; no expansion or verbosity credit (see the
        // estimator's own comment for why the 9x factor was removed).
        XCTAssertEqual(claude.inputTokens, TokenEstimator.estimate(humanized))
        XCTAssertEqual(claude.outputTokens, TokenEstimator.estimate(sr1))
        XCTAssertEqual(claude.savedTokens,
                       max(TokenEstimator.estimate(humanized) - TokenEstimator.estimate(sr1), 0))
        XCTAssertEqual(claude.runs, 1)
        XCTAssertEqual(summary.modes.first?.mode, "sr1-humanize")
    }

    func test_tokenSaverHumanizeFallbackRendersSR2V1ThinkingFieldsAsNaturalText() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverSR2V1Fallback-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let thread = AgentThread(title: "sr2 fallback", provider: .claude, model: "fake-model")
        try context.threadRepo.upsert(thread)
        try admitTokenSaver(in: context, threadID: thread.id)
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "Please keep the visible transcript in English."
        ))
        let wire = "@sr2 v1\nflow:inspect>verify>deploy\ndone:flow\no:cont"

        let humanized = await context.tokenSaverHumanizeSR1Response(
            wire,
            provider: .claude,
            threadId: thread.id
        )

        XCTAssertFalse(humanized.contains("@sr2"), humanized)
        XCTAssertTrue(humanized.contains("Next steps: inspect then verify then deploy."), humanized)
        XCTAssertTrue(humanized.contains("Complete when: flow."), humanized)
    }

    func test_tokenSaverHumanizeFallbackExpandsTrackerDeliveryBlockedDeployProof() async throws {
        // WHY: the live Trello/Codex final painted mixed SR2 (`Action:`/`e:` keys).
        // The host fallback must emit the status narrative, not the protocol dump.
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverSR2Trello-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let thread = AgentThread(title: "trello sr2 fallback", provider: .codex, model: "fake-model")
        try context.threadRepo.upsert(thread)
        try admitTokenSaver(in: context, threadID: thread.id)
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "Please keep the visible transcript in English."
        ))
        let wire = """
        @sr2 v1
        g:trello-doing-delivery
        Action: blocked-deploy-proof
        Proof: path:final
        blocked
        e:PRs-merged:19,14
        e:railway-main-admin:SUCCESS
        e:railway-prod-api:INITIALIZING
        e:railway-prod-access-pins:404-before-clean-deploy
        e:playwright:unverified
        e:trello:unchanged-Doing
        e:comments:not-posted
        e:PR19:https://github.com/si-ncs/star-api-v3/pull/19
        e:PR14:https://github.com/si-ncs/admin-foundation-v3/pull/14
        e:next:wait-for-deploy-then-run-authenticated-playwright-postdeploy-and-update-Trello
        """

        let humanized = await context.tokenSaverHumanizeSR1Response(
            wire,
            provider: .codex,
            threadId: thread.id
        )

        XCTAssertFalse(humanized.contains("@sr2"), humanized)
        XCTAssertFalse(humanized.contains("e:playwright"), humanized)
        XCTAssertTrue(
            humanized.contains("The goal is to deliver the Trello task currently in Doing."),
            humanized
        )
        XCTAssertTrue(
            humanized.contains("The current action is blocked while waiting for deployment proof."),
            humanized
        )
        XCTAssertTrue(humanized.contains("si-ncs/star-api-v3#19"), humanized)
        XCTAssertTrue(
            humanized.contains("The next step is to wait for the deployment to finish"),
            humanized
        )
    }

    func test_tokenSaverUsageForDistillSkillRunDoesNotRecordSavingsWithoutSidecarCall() throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverDistillSkillSavings-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        let thread = AgentThread(
            title: "distill skill",
            provider: .codex,
            model: "gpt-test"
        )
        try context.threadRepo.upsert(thread)
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "/distill"
        ))
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "gpt-test",
            status: .running,
            startedAt: Date()
        )
        try context.runRepo.upsert(run)

        context.coordinator.onAssistantEvent?(
            .tokenUsage(AssistantTokenUsage(inputTokens: 120, outputTokens: 80, totalTokens: 200)),
            thread.id,
            run.id
        )
        context.coordinator.onAssistantEvent?(
            .tokenUsage(AssistantTokenUsage(inputTokens: 120, outputTokens: 80, totalTokens: 200)),
            thread.id,
            run.id
        )

        let summary = try context.tokenSaverSavingsRepo.summary()
        XCTAssertEqual(summary.totalRuns, 0,
                       "provider token-usage events do not know the original command output or humanized SR1 length; savings are recorded only by local sidecar calls")
    }

    func test_providerUsageCreatesAppendOnlyAttemptEvidenceWithoutClaimingSavings() throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverAttemptEvidence-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let thread = AgentThread(
            projectId: ProjectID(),
            workspaceId: WorkspaceID(),
            title: "provider evidence",
            provider: .grok,
            model: "grok-test"
        )
        try context.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .grok,
            model: "grok-test",
            status: .running,
            startedAt: Date()
        )
        try context.runRepo.upsert(run)

        context.coordinator.onRunStarted?(thread.id, run.id)
        context.coordinator.onAssistantEvent?(
            .tokenUsage(AssistantTokenUsage(inputTokens: 1, outputTokens: 1, totalTokens: 2)),
            thread.id,
            run.id
        )
        let attemptID = run.id.value.uuidString
        XCTAssertNil(try context.tokenSaverAttemptLedger.attempt(id: attemptID),
                     "an off project lane must not create attempt or provider-event rows")

        try admitTokenSaver(in: context, threadID: thread.id)
        try context.tokenSaverLaneStateRepo.upsert(.init(
            projectID: thread.projectId!.value.uuidString,
            lane: "measurement",
            state: "shadow_only",
            reason: "test_measurement",
            evidenceLevel: "provider_usage",
            ownerRole: "Measurement Owner:test",
            permissionBoundary: "project",
            retentionDays: 0,
            optedOut: false,
            killSwitchActive: false
        ))
        context.coordinator.onRunStarted?(thread.id, run.id)
        context.coordinator.onAssistantEvent?(
            .tokenUsage(AssistantTokenUsage(inputTokens: 120, outputTokens: 80, totalTokens: 200)),
            thread.id,
            run.id
        )

        let attempt = try XCTUnwrap(context.tokenSaverAttemptLedger.attempt(id: attemptID))
        XCTAssertEqual(attempt.runID, attemptID)
        XCTAssertEqual(attempt.provider, AgentProvider.grok.rawValue)
        XCTAssertEqual(attempt.model, "grok-test")
        XCTAssertEqual(attempt.evidenceLevel, "provider_usage")
        XCTAssertFalse(attempt.unavailableFields.contains("provider_usage_semantics"))
        let events = try context.tokenSaverAttemptLedger.events(attemptID: attemptID)
        XCTAssertEqual(events.map(\.kind), ["provider_usage"])
        XCTAssertTrue(events[0].payloadJSON.contains("\"total_tokens\":200"))
        XCTAssertTrue(events[0].payloadJSON.contains("\"semantics\":\"cumulative\""))
        let components = try context.db.prepare("SELECT category, tokens FROM token_saver_input_components WHERE attempt_id = ?;")
        try components.bind(1, attemptID)
        XCTAssertTrue(try components.step())
        XCTAssertEqual(components.columnText(0), "unattributed_provider_input")
        XCTAssertEqual(components.columnInt64(1), 120)
        XCTAssertEqual(try context.tokenSaverSavingsRepo.summary().totalRuns, 0)
        let laneStates = try context.tokenSaverLaneStateRepo.list(projectID: thread.projectId!.value.uuidString)
        XCTAssertEqual(laneStates.first(where: { $0.lane == "deterministic_wrapper" })?.state, "promoted")
    }

    func test_providerUsageEvidenceKeepsRawEventsButRecordsOnlyReconciledInputGrowth() throws {
        // WHY: Claude can emit independent request charges followed by a
        // cumulative result. Raw audit events remain append-only, but Pareto
        // components must represent the effective 260-token run, not 510 tokens
        // from naively summing every snapshot.
        let context = try makeTestContext(
            appSupportOverride: NSTemporaryDirectory()
                + "RC2TokenSaverReconciledEvidence-"
                + UUID().uuidString
        )
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let thread = AgentThread(
            projectId: ProjectID(),
            workspaceId: WorkspaceID(),
            title: "mixed usage evidence",
            provider: .claude,
            model: "claude-test"
        )
        try context.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "claude-test",
            status: .running,
            startedAt: Date()
        )
        try context.runRepo.upsert(run)
        try admitTokenSaver(in: context, threadID: thread.id)
        try context.tokenSaverLaneStateRepo.upsert(.init(
            projectID: thread.projectId!.value.uuidString,
            lane: "measurement",
            state: "shadow_only",
            reason: "test_measurement",
            evidenceLevel: "provider_usage",
            ownerRole: "Measurement Owner:test",
            permissionBoundary: "project",
            retentionDays: 0,
            optedOut: false,
            killSwitchActive: false
        ))
        context.coordinator.onRunStarted?(thread.id, run.id)

        for usage in [
            AssistantTokenUsage(
                inputTokens: 100,
                totalTokens: 100,
                semantics: .incremental
            ),
            AssistantTokenUsage(
                inputTokens: 150,
                totalTokens: 150,
                semantics: .incremental
            ),
            AssistantTokenUsage(
                inputTokens: 260,
                totalTokens: 260,
                semantics: .cumulative
            ),
        ] {
            context.coordinator.onAssistantEvent?(.tokenUsage(usage), thread.id, run.id)
        }

        let attemptID = run.id.value.uuidString
        let events = try context.tokenSaverAttemptLedger.events(attemptID: attemptID)
        XCTAssertEqual(events.map(\.kind), [
            "provider_usage",
            "provider_usage",
            "provider_usage",
        ], "raw provider observations stay append-only")
        XCTAssertTrue(events[0].payloadJSON.contains("\"semantics\":\"incremental\""))
        XCTAssertTrue(events[2].payloadJSON.contains("\"semantics\":\"cumulative\""))

        let components = try context.db.prepare("""
            SELECT COUNT(*), COALESCE(SUM(tokens), 0)
            FROM token_saver_input_components
            WHERE attempt_id = ? AND category = 'unattributed_provider_input';
        """)
        try components.bind(1, attemptID)
        XCTAssertTrue(try components.step())
        XCTAssertEqual(components.columnInt64(0), 3)
        XCTAssertEqual(components.columnInt64(1), 260)
        XCTAssertEqual(try context.tokenSaverSavingsRepo.summary().totalRuns, 0)
    }

    func test_shadowPreparationJoinsExactScopeAndRunsPoliciesWithoutChangingProviderBytes() async throws {
        let context = try makeTestContext(
            appSupportOverride: NSTemporaryDirectory() + "RC2ShadowJoin-" + UUID().uuidString
        )
        SettingsStore(db: context.db).update {
            $0.tokenSaverEnabled = true
            $0.sessionLearnEnabled = true
        }
        let thread = AgentThread(
            projectId: ProjectID(), workspaceId: WorkspaceID(), title: "shadow",
            provider: .grok, model: "grok-test", status: .running
        )
        try context.threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .grok, model: "grok-test", status: .running)
        try context.runRepo.upsert(run)
        for lane in ["measurement", "session_learn", "semantic_prose", "adaptive_effort", "visual_artifact", "provider_native"] {
            try context.tokenSaverLaneStateRepo.upsert(.init(
                projectID: thread.projectId!.value.uuidString,
                lane: lane,
                state: "shadow_only",
                reason: "test",
                evidenceLevel: "diagnostic_heuristic",
                ownerRole: "Operations Owner:test",
                permissionBoundary: "project",
                retentionDays: 30,
                optedOut: false,
                killSwitchActive: false
            ))
        }
        let scope = TokenSaverSessionLearnScope(
            workspaceID: thread.workspaceId!.value.uuidString,
            projectID: thread.projectId!.value.uuidString,
            threadID: thread.id.value.uuidString,
            provider: AgentProvider.grok.rawValue
        )
        try context.tokenSaverSessionLearnRepo.save(
            text: "retain browser parity",
            scope: scope,
            attemptID: "prior"
        )
        let prompt = "Rename the browser parity helper and run tests without modifying this exact provider prompt."
        let request = AgentRunRequest(
            runId: run.id,
            threadId: thread.id,
            provider: .grok,
            model: "grok-test",
            cwd: "/tmp",
            prompt: prompt,
            attachments: [.init(path: "/tmp/evidence.png", kind: .image, mimeType: "image/png", sizeBytes: 4_096)],
            reasoningEffort: .high
        )

        await context.coordinator.onRunPrepared?(request, prompt)
        context.coordinator.onAssistantEvent?(
            .tokenUsage(.init(inputTokens: 321, outputTokens: 10, totalTokens: 331)),
            thread.id,
            run.id
        )

        let events = try context.tokenSaverAttemptLedger.events(attemptID: run.id.value.uuidString)
        XCTAssertTrue(events.map(\.kind).contains("treatment_join"))
        XCTAssertEqual(events.filter { $0.kind == "shadow_policy" }.count, 4)
        XCTAssertTrue(events.map(\.kind).contains("session_learn_retrieval"))
        XCTAssertFalse(events.contains { $0.payloadJSON.contains(prompt) }, "telemetry must remain content-free")
        XCTAssertTrue(events.allSatisfy { !$0.payloadJSON.contains("provider_bytes_changed\":true") })
        XCTAssertTrue(events.contains { $0.payloadJSON.contains("\"task_class\":\"mechanical\"") })
        XCTAssertTrue(events.contains { $0.payloadJSON.contains("\"known_image_bytes\":4096") })
        let components = try context.db.prepare("SELECT category, tokens FROM token_saver_input_components WHERE attempt_id = ?;")
        try components.bind(1, run.id.value.uuidString)
        XCTAssertTrue(try components.step())
        XCTAssertEqual(components.columnText(0), "unattributed_provider_input")
        XCTAssertEqual(components.columnInt64(1), 321)
    }

    func test_appContextLaunchDegradesTokenSaverWhenLifecycleSweepCannotComplete() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverLifecycleFailClosed-" + UUID().uuidString
        let first = try makeTestContext(appSupportOverride: appSupport)
        try first.tokenSaverSessionLearnRepo.save(
            text: "expired private test record",
            scope: .init(workspaceID: "w", projectID: "p", threadID: "t", provider: "claude"),
            attemptID: "a",
            now: Date(timeIntervalSince1970: 10),
            expiresAt: Date(timeIntervalSince1970: 20)
        )
        try first.db.execute("""
            CREATE TRIGGER fail_session_learn_lifecycle_update
            BEFORE UPDATE ON token_saver_session_learn_records
            BEGIN SELECT RAISE(ABORT, 'forced lifecycle failure'); END;
        """)

        let degraded = try makeTestContext(appSupportOverride: appSupport)
        XCTAssertTrue(degraded.tokenSaverLifecycleDegradedReason?.contains("lifecycle_sweep_failed") == true)
        SettingsStore(db: degraded.db).update {
            $0.tokenSaverEnabled = true
            $0.sessionLearnEnabled = true
        }
        let threadID = try makeAdmittedTokenSaverThread(in: degraded, provider: .claude)
        let prompt = String(repeating: "degraded mode keeps this exact input verbatim\n", count: 80)
        let outputValue = await degraded.coordinator.promptCompressor?(
            prompt,
            AgentPromptSemanticSource(prompt),
            .claude,
            threadID,
            AgentRunID()
        )
        let output = try XCTUnwrap(outputValue)
        XCTAssertEqual(output, prompt)
        XCTAssertEqual(
            degraded.tokenSaverRolloverAdmission(parentThreadID: threadID).reason,
            "lifecycle_degraded"
        )
    }

    func test_tokenSaverUsageForDistillSkillRunWithTotalOnlyUsageDoesNotFabricateSavings() throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverDistillSkillTotalOnlySavings-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        let thread = AgentThread(
            title: "distill skill total only",
            provider: .codex,
            model: "gpt-test"
        )
        try context.threadRepo.upsert(thread)
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "/distill Responda usando SR1."
        ))
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "gpt-test",
            status: .running,
            startedAt: Date()
        )
        try context.runRepo.upsert(run)

        context.coordinator.onAssistantEvent?(
            .tokenUsage(AssistantTokenUsage(inputTokens: 0, outputTokens: 0, totalTokens: 200)),
            thread.id,
            run.id
        )

        let summary = try context.tokenSaverSavingsRepo.summary()
        XCTAssertEqual(summary.totalRuns, 0,
                       "total-only provider usage must not invent Token Saver savings; command-output and SR1 savings are measured by the sidecar")
    }

    func test_tokenSaverUsageForInputOnlyDistillEventDoesNotFabricateSavedTokens() throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverDistillSkillInputOnlyNoSavings-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        let thread = AgentThread(
            title: "distill input only",
            provider: .claude,
            model: "claude-test"
        )
        try context.threadRepo.upsert(thread)
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "/distill"
        ))
        let run = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "claude-test",
            status: .running,
            startedAt: Date()
        )
        try context.runRepo.upsert(run)

        context.coordinator.onAssistantEvent?(
            .tokenUsage(AssistantTokenUsage(inputTokens: 200, outputTokens: 0, totalTokens: 200)),
            thread.id,
            run.id
        )

        XCTAssertEqual(try context.tokenSaverSavingsRepo.summary().totalRuns, 0,
                       "input-only token usage is not compressed output and must not inflate Saved")
    }
    func test_tokenSaverDistillServiceControllerStartsInjectedSidecarForPaidEnabledInstalledModel() async throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2PaidTokenSaverLaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let executable = appSupport.appendingPathComponent("FakeRemoteCodeDistillService")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"event":"ready","base_url":"http://127.0.0.1:18181","host":"127.0.0.1","port":18181,"pid":12345,"protocol":1,"runtime":"mlx","model_id":"\(DistillApprovedModel.id)","max_concurrent_requests":8,"max_queue_depth":64}'
        exec 1>/dev/null
        sleep 20
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let ownership = configureIsolatedProviderProcessOwnership(at: appSupport)

        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: appSupport,
            executableURLResolver: { executable }
        )
        let session = PrivateAccountSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            user: PrivateAccountUser(
                daysRemaing: nil,
                daysRemaining: 30,
                email: "paid@example.com",
                id: "paid-user",
                subscribed: true
            )
        )

        controller.startIfEligible(
            session: session,
            settings: AppSettings(tokenSaverEnabled: true),
            modelValidation: .installed
        )

        let ready = await waitUntil {
            if case .running = controller.status { return true }
            return false
        }
        XCTAssertTrue(ready,
                      "paid subscribed launches with Token Saver enabled and a verified model must spawn the managed sidecar")
        guard case .running(let event) = controller.status else {
            XCTFail("expected running Token Saver sidecar status")
            await cleanupIsolatedProviderProcessOwnership(ownership, controller: controller)
            return
        }
        XCTAssertEqual(event.runtime, DistillApprovedModel.runtime)
        XCTAssertEqual(event.modelID, DistillApprovedModel.id)
        XCTAssertEqual(event.maxConcurrentRequests, 8)
        XCTAssertEqual(event.maxQueueDepth, 64)
        guard let token = controller.bearerToken else {
            XCTFail("running Token Saver sidecar must expose its bearer token")
            await cleanupIsolatedProviderProcessOwnership(ownership, controller: controller)
            return
        }
        let stateURL = appSupport
            .appendingPathComponent("Distill", isDirectory: true)
            .appendingPathComponent("DistillCLIState.json")
        guard let state = try? String(contentsOf: stateURL) else {
            XCTFail("running Token Saver sidecar must persist its CLI state")
            await cleanupIsolatedProviderProcessOwnership(ownership, controller: controller)
            return
        }
        XCTAssertTrue(state.contains("\"base_url\":\"http:\\/\\/127.0.0.1:18181\"") ||
                      state.contains("\"base_url\":\"http://127.0.0.1:18181\""))
        XCTAssertTrue(state.contains(token),
                      "the managed distill CLI needs the live sidecar bearer token, not an external TypeScript CLI")

        let ownershipStore = ProviderProcessOwnershipStore(fileURL: ownership.ledger)
        XCTAssertEqual((try? ownershipStore.load().count) ?? -1, 1,
                       "the real spawner must persist exactly one isolated sidecar ownership row")
        await cleanupIsolatedProviderProcessOwnership(ownership, controller: controller)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func test_tokenSaverDistillServiceControllerReadsReadyBeforeSidecarClosesStdout() async throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2PaidTokenSaverOpenStdout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let executable = appSupport.appendingPathComponent("FakeRemoteCodeDistillService")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"event":"ready","base_url":"http://127.0.0.1:18182","host":"127.0.0.1","port":18182,"pid":12346,"protocol":1,"runtime":"mlx","model_id":"\(DistillApprovedModel.id)","max_concurrent_requests":8,"max_queue_depth":64}'
        sleep 20
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let ownership = configureIsolatedProviderProcessOwnership(at: appSupport)

        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: appSupport,
            executableURLResolver: { executable }
        )
        let session = PrivateAccountSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            user: PrivateAccountUser(
                daysRemaing: nil,
                daysRemaining: 30,
                email: "paid@example.com",
                id: "paid-user",
                subscribed: true
            )
        )

        controller.startIfEligible(
            session: session,
            settings: AppSettings(tokenSaverEnabled: true),
            modelValidation: .installed
        )

        let ready = await waitUntil {
            if case .running = controller.status { return true }
            return false
        }
        XCTAssertTrue(ready,
                      "the sidecar keeps stdout open after the ready line; waiting for EOF leaves Token Saver stuck in starting")

        let ownershipStore = ProviderProcessOwnershipStore(fileURL: ownership.ledger)
        XCTAssertEqual((try? ownershipStore.load().count) ?? -1, 1,
                       "the real spawner must persist exactly one isolated sidecar ownership row")
        await cleanupIsolatedProviderProcessOwnership(ownership, controller: controller)
    }

    func test_refreshAccountUsageWithTimeoutReturnsRealResultAndDoesNotReturnEmptyOnFastRefresher() async {
        // WHY: the watchdog task must be cancelled when the work completes normally.
        // Before this fix the watchdog lingered for 60 s per call; now it is cancelled
        // inside resume() on the first winner. This test pins that a fast refresher
        // returns the real result (not []) and completes well within the tight
        // timeoutNanoseconds budget, proving the normal-finish path is hit.
        let expected = [
            AssistantAccountUsage(provider: .claude, weeklyUsedPercent: 42)
        ]
        let refresher = FakeTokenSaverAccountUsageRefresher(response: expected)
        let request = TokenSaverAccountUsageRefreshRequest(codexBinary: "codex", claudeBinary: "claude")

        // 5-second timeout: more than enough for an in-process fake; tight enough that
        // a regression returning [] (watchdog fires first) would be caught quickly.
        let result = await AppContext.refreshAccountUsageWithTimeout(
            refresher: refresher,
            request: request,
            timeoutNanoseconds: 5_000_000_000
        )

        XCTAssertEqual(result.count, 1, "fast refresher must return the real result, not the timeout empty fallback")
        XCTAssertEqual(result.first?.provider, .claude)
        XCTAssertEqual(result.first?.weeklyUsedPercent, 42,
                       "watchdog cancellation on normal completion must not discard the real usage data")
    }

    func test_refreshAccountUsageWithTimeoutReturnsEmptyWhenWorkExceedsTimeout() async {
        // WHY: the timeout path must still fire if work hangs; returning [] is the
        // correct sentinel that the caller treats as "no data this cycle".
        struct HangingRefresher: TokenSaverAccountUsageRefreshing {
            func refreshAccountUsage(_ request: TokenSaverAccountUsageRefreshRequest) async -> [AssistantAccountUsage] {
                // Simulate a hang; respect cooperative cancellation so the test finishes.
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return [AssistantAccountUsage(provider: .claude, weeklyUsedPercent: 99)]
            }
        }

        // 10 ms timeout: work hangs => watchdog fires => returns [].
        let result = await AppContext.refreshAccountUsageWithTimeout(
            refresher: HangingRefresher(),
            request: TokenSaverAccountUsageRefreshRequest(codexBinary: "codex", claudeBinary: "claude"),
            timeoutNanoseconds: 10_000_000
        )

        XCTAssertTrue(result.isEmpty,
                      "when work exceeds the watchdog timeout the function must return [] so the caller skips this cycle")
    }

    func test_tokenSaverDistillServiceControllerPostsUsageChangedForSavingsEvents() async throws {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2PaidTokenSaverSavingsEvent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let executable = appSupport.appendingPathComponent("FakeRemoteCodeDistillService")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"event":"ready","base_url":"http://127.0.0.1:18183","host":"127.0.0.1","port":18183,"pid":12347,"protocol":1,"runtime":"mlx","model_id":"\(DistillApprovedModel.id)","max_concurrent_requests":8,"max_queue_depth":64}'
        sleep 0.1
        printf '%s\\n' '{"event":"savings_recorded","provider":"codex","mode":"command-output","input_tokens":30,"output_tokens":10,"saved_tokens":20}'
        sleep 20
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        var didPostUsageChanged = false
        let observer = NotificationCenter.default.addObserver(
            forName: .rc2TokenSaverUsageChanged,
            object: nil,
            queue: .main
        ) { _ in
            didPostUsageChanged = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let controller = TokenSaverDistillServiceController(
            appSupportDirectory: appSupport,
            executableURLResolver: { executable }
        )
        let session = PrivateAccountSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            user: PrivateAccountUser(
                daysRemaing: nil,
                daysRemaining: 30,
                email: "paid@example.com",
                id: "paid-user",
                subscribed: true
            )
        )

        controller.startIfEligible(
            session: session,
            settings: AppSettings(tokenSaverEnabled: true),
            modelValidation: .installed
        )

        let posted = await waitUntil { didPostUsageChanged }
        XCTAssertTrue(posted,
                      "sidecar savings events must refresh Token Saver chart/report state in the running app")

        controller.stop()
    }

    // MARK: - Per-lane kill switch, measurement ungating, loud denials

    func test_tokenSaverLaneKillSwitch_experimentalDefaultDisabled_explicitEnableWorks() {
        // WHY: new/experimental lanes must default OFF so an unvetted compressor cannot
        // ship live without an explicit operator opt-in; known stable lanes stay on
        // unless the incident kill list names them.
        XCTAssertTrue(
            TokenSaverLaneKillSwitch.isDisabled(
                "brand_new_experimental_lane",
                environment: [:],
                cliState: .empty
            ),
            "experimental lanes default DISABLED"
        )
        XCTAssertFalse(
            TokenSaverLaneKillSwitch.isDisabled(
                "deterministic_wrapper",
                environment: [:],
                cliState: .empty
            ),
            "known stable lanes are not disabled by default"
        )
        XCTAssertFalse(
            TokenSaverLaneKillSwitch.isDisabled(
                "brand_new_experimental_lane",
                environment: [TokenSaverLaneKillSwitch.enabledEnvKey: "brand_new_experimental_lane"],
                cliState: .empty
            ),
            "explicit enable must turn an experimental lane on"
        )
        XCTAssertTrue(
            TokenSaverLaneKillSwitch.isDisabled(
                "deterministic_wrapper",
                environment: [TokenSaverLaneKillSwitch.disabledEnvKey: "deterministic_wrapper"],
                cliState: .empty
            ),
            "operator DISABLED_LANES is the incident kill switch"
        )
        // CLI state file overlay must also disable.
        XCTAssertTrue(
            TokenSaverLaneKillSwitch.isDisabled(
                "semantic_prose",
                environment: [:],
                cliState: .init(disabledLanes: ["semantic_prose"], enabledLanes: [])
            ),
            "DistillCLIState disabled_lanes must be honored"
        )
        // Kill switch wins over enable.
        XCTAssertTrue(
            TokenSaverLaneKillSwitch.isDisabled(
                "deterministic_wrapper",
                environment: [
                    TokenSaverLaneKillSwitch.disabledEnvKey: "deterministic_wrapper",
                    TokenSaverLaneKillSwitch.enabledEnvKey: "deterministic_wrapper",
                ],
                cliState: .empty
            ),
            "incident disable must beat enable lists"
        )
    }

    func test_tokenSaverMeasurementRecordsSavingsWithNilProjectId() async throws {
        // WHY: production DBs have project_id NULL on every agent_thread and 0
        // token_saver_lane_state rows. Measurement must still land so sr1-humanize
        // savings are not silently dead.
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverMeasureNilProject-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        let thread = AgentThread(
            title: "nil project measurement",
            provider: .claude,
            model: "test-model",
            status: .completed
        )
        XCTAssertNil(thread.projectId, "fixture must reproduce the production project_id NULL case")
        try context.threadRepo.upsert(thread)

        let sr1 = """
        SR1
        S=done
        O=The result is ready for the user.
        P=ok
        """
        let humanized = await context.tokenSaverHumanizeSR1Response(
            sr1,
            provider: .claude,
            threadId: thread.id
        )
        XCTAssertFalse(SR1ResponseDetector.isSR1(humanized))

        let summary = try context.tokenSaverSavingsRepo.summary()
        XCTAssertGreaterThan(
            summary.totalRuns,
            0,
            "measurement write must succeed on project_id == nil when Token Saver is enabled"
        )
        XCTAssertEqual(summary.modes.first?.mode, "sr1-humanize")

        // Governance snapshot is attached even when admission would have denied.
        let gov = try context.db.prepare(
            "SELECT governance_json FROM token_saver_savings WHERE mode = 'sr1-humanize' LIMIT 1;"
        )
        XCTAssertTrue(try gov.step())
        let govJSON = try XCTUnwrap(gov.columnText(0))
        XCTAssertTrue(
            govJSON.contains("admission_allowed") || govJSON.contains("\"admission_allowed\":false"),
            "savings row must carry governance snapshot; got \(govJSON)"
        )
        XCTAssertTrue(
            govJSON.contains("governed_write") || govJSON.contains("\"governed_write\":false"),
            "measurement rows are not governed writes; got \(govJSON)"
        )
    }

    func test_tokenSaverAdmissionDenialAppendsAuditEvent() async throws {
        // WHY: project-admission denials used to return silently, hiding the
        // empty-lane_state / nil-project silent-death condition from operators.
        // The live send hook only records that denial on SessionLearn now.
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverDenialAudit-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update {
            $0.tokenSaverEnabled = true
            $0.sessionLearnEnabled = true
        }

        let thread = AgentThread(
            title: "denial audit",
            provider: .claude,
            model: "test-model",
            status: .completed
        )
        XCTAssertNil(thread.projectId)
        try context.threadRepo.upsert(thread)

        let bigPrompt = (1...40)
            .map { "line \($0): verbose instruction that would compress if admitted" }
            .joined(separator: "\n")
        XCTAssertGreaterThan(bigPrompt.count, 2_000)

        let before = try context.tokenSaverAuditEventsRepo.count(eventKind: "token_saver_denial")
        let outputValue = await context.coordinator.promptCompressor?(
            bigPrompt,
            AgentPromptSemanticSource(bigPrompt),
            .claude,
            thread.id,
            AgentRunID()
        )
        let output = try XCTUnwrap(outputValue)
        XCTAssertEqual(output, bigPrompt, "denied SessionLearn must leave the typed prompt unchanged")

        let after = try context.tokenSaverAuditEventsRepo.count(eventKind: "token_saver_denial")
        XCTAssertEqual(
            after,
            before + 1,
            "admission denial must append token_saver_audit_events instead of returning silently"
        )

        let row = try context.db.prepare("""
            SELECT reason, object_id, thread_id FROM token_saver_audit_events
            WHERE event_kind = 'token_saver_denial'
            ORDER BY id DESC LIMIT 1;
        """)
        XCTAssertTrue(try row.step())
        XCTAssertEqual(row.columnText(0), "session_learn", "lane goes in reason")
        XCTAssertEqual(
            row.columnText(1),
            "missing_project_scope",
            "admission reason is retained on object_id for operators"
        )
        XCTAssertEqual(row.columnText(2), thread.id.value.uuidString)
    }

    func test_tokenSaverAgentEnvironmentExportsDisabledLanes() throws {
        // WHY: child distill processes must see the same kill-switch decision.
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverEnvKill-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        let thread = AgentThread(title: "env kill", provider: .claude, model: "m")
        try context.threadRepo.upsert(thread)

        let env = context.tokenSaverAgentEnvironment(
            provider: .claude,
            threadId: thread.id,
            baseEnvironment: [
                "PATH": "/usr/bin",
                TokenSaverLaneKillSwitch.disabledEnvKey: "semantic_prose",
            ]
        )
        let disabled = env[TokenSaverLaneKillSwitch.disabledEnvKey] ?? ""
        XCTAssertTrue(
            disabled.split(separator: ",").map(String.init).contains("semantic_prose"),
            "resolved disabled set must export to child env; got \(disabled)"
        )
    }

    func test_tokenSaverAgentEnvironmentExportsNamespaceLocalStateForEveryManagedProvider() throws {
        // WHY: Codex/Grok command wrappers use the same live lease as Claude's
        // PostToolUse hook. Omitting this path for non-Claude providers makes a
        // canary/debug child fall through to the stable Distill state file.
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverNamespaceState-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        for provider in [AgentProvider.codex, .claude, .grok] {
            let thread = AgentThread(title: "namespace state \(provider.rawValue)", provider: provider, model: "m")
            try context.threadRepo.upsert(thread)
            let env = context.tokenSaverAgentEnvironment(
                provider: provider,
                threadId: thread.id,
                baseEnvironment: ["PATH": "/usr/bin"]
            )
            XCTAssertEqual(
                env["REMOTE_CODE_DISTILL_STATE_PATH"],
                URL(fileURLWithPath: appSupport)
                    .appendingPathComponent("Distill", isDirectory: true)
                    .appendingPathComponent("DistillCLIState.json")
                    .path,
                "\(provider.rawValue) must use its app-support namespace lease"
            )
        }
    }

    func test_appSideSavingsWritePersistsDeliveredAndNonUnknownAttributability() async throws {
        // WHY: TokenSaverSavingsRepository.record defaults are attributability="unknown"
        // and delivered=false. displayedSavingsEligibilitySQL admits
        // (attributability='unknown' AND provider!='unknown') only as a pre-migration
        // escape hatch. New app-side rows that omit the kwargs land in that bucket,
        // so delivered can never filter app writes and forfeited-looking rows present
        // as attributed. AppContext must write delivered=1 + non-unknown class.
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverHonestyColumns-" + UUID().uuidString
        let context = try makeTestContext(appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        let thread = AgentThread(
            title: "honesty columns",
            provider: .claude,
            model: "test-model",
            status: .completed
        )
        try context.threadRepo.upsert(thread)

        let sr1 = """
        SR1
        S=done
        O=The result is ready for the user.
        P=ok
        """
        let humanized = await context.tokenSaverHumanizeSR1Response(
            sr1,
            provider: .claude,
            threadId: thread.id
        )
        XCTAssertFalse(SR1ResponseDetector.isSR1(humanized))

        let stmt = try context.db.prepare("""
            SELECT attributability, delivered, provider
            FROM token_saver_savings
            WHERE mode = 'sr1-humanize'
            LIMIT 1;
        """)
        XCTAssertTrue(try stmt.step(), "app-side SR1 humanize must persist a savings row")
        let attributability = try XCTUnwrap(stmt.columnText(0))
        let delivered = stmt.columnInt64(1)
        let provider = try XCTUnwrap(stmt.columnText(2))

        XCTAssertEqual(
            delivered,
            1,
            "app-side delivered compressions must persist delivered=1 (not the false default)"
        )
        XCTAssertNotEqual(
            attributability,
            "unknown",
            "new rows must not rely on the pre-migration attributability=unknown escape hatch"
        )
        XCTAssertEqual(
            attributability,
            "not_prompt_bound",
            "app-side measurement rows are delivered but not proven prompt-bound"
        )
        XCTAssertNotEqual(provider, "unknown", "provider must be the real agent provider")

        // Eligibility must hold via delivered=1, independent of the legacy branch.
        XCTAssertTrue(
            delivered == 1 || (attributability == "unknown" && provider != "unknown"),
            "row must satisfy displayedSavingsEligibilitySQL"
        )
        XCTAssertEqual(delivered, 1, "eligibility for this new row is via delivered=1 only")
    }

    func test_sidecarMainConstructionWiresSavingsAndAuditHandlers() throws {
        // WHY: DistillHTTPServer.emitForfeitedCompression only publishes delivered=0
        // forfeit rows and token_saver_denial audits through optional onSavingsRecord /
        // onAuditEvent. Leaving them nil in the shipping sidecar makes that
        // observability dead in production (alive only in DistillCore unit tests).
        // Assert the production construction site supplies both named handlers —
        // the wiring seam itself, not a mock's call history.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources/RemoteCodeDistillService/RemoteCodeDistillServiceMain.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        // Executable construction: DistillHTTPServer(... onSavingsRecord: ... onAuditEvent: ...)
        XCTAssertTrue(
            source.contains("DistillHTTPServer("),
            "sidecar main must construct DistillHTTPServer"
        )
        XCTAssertTrue(
            source.contains("onSavingsRecord:"),
            "sidecar must wire onSavingsRecord so forfeited compressions land in the ledger"
        )
        XCTAssertTrue(
            source.contains("onAuditEvent:"),
            "sidecar must wire onAuditEvent so token_saver_denial forfeit audits persist"
        )
        // Must not leave either seam as an explicit nil (defaults are also nil).
        XCTAssertFalse(
            source.contains("onSavingsRecord: nil"),
            "onSavingsRecord must not be explicitly nil"
        )
        XCTAssertFalse(
            source.contains("onAuditEvent: nil"),
            "onAuditEvent must not be explicitly nil"
        )
        // Handlers must reach real persistence (savings repo + audit append path).
        XCTAssertTrue(
            source.contains("TokenSaverAuditEventRepository"),
            "audit handler must be backed by TokenSaverAuditEventRepository"
        )
        XCTAssertTrue(
            source.contains("savingsRepo.record(") || source.contains("persistSavings"),
            "savings handler must persist via TokenSaverSavingsRepository"
        )
    }
}

private final class AutoPayloadCaptureRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private var requests: [AgentRunRequest] = []

    init(provider: AgentProvider) {
        self.provider = provider
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
        onEvent(.finished(.completed, finalMessage: "captured", providerThreadId: nil))
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}
