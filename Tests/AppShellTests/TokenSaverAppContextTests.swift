import XCTest
import AppKit
import CoreModel
import AgentRuntime
import DistillCore
import Persistence
@testable import AppShell

@MainActor
final class TokenSaverAppContextTests: XCTestCase {
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

        func distill(_ request: DistillRequest) async throws -> String {
            count += 1
            return request.input
        }

        var callCount: Int { count }
    }

    private struct FixedOutputRuntime: DistillRuntime {
        let output: String

        func distill(_ request: DistillRequest) async throws -> String {
            output
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

    func test_appContextReconcilesManagedDistillStateWithTokenSaverToggle() throws {
        let appSupport = NSTemporaryDirectory() + "RC2ManagedSkills-" + UUID().uuidString
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2ManagedSkillsHome-" + UUID().uuidString, isDirectory: true)

        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
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
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: pathLink.path), cliURL.path)

        let skillText = try String(contentsOf: appPrivateSkill)
        XCTAssertTrue(skillText.contains("source: https://github.com/samuelfaj/distill/blob/main/skills/distill/SKILL.md"))
        XCTAssertTrue(skillText.contains("S=state"))
        XCTAssertTrue(skillText.contains("P=proof"))
        let cliDest = try FileManager.default.destinationOfSymbolicLink(atPath: cliURL.path)
        XCTAssertTrue(cliDest.hasSuffix("RemoteCodeDistillService"), "managed CLI is a native symlink, not a script")
        XCTAssertFalse(cliDest.contains("dev/distill/src/cli.ts"))

        // Toggle off again removes economy hooks.
        context.reconcileManagedDistillSkills(tokenSaverEnabled: false)
        XCTAssertEqual(context.managedDistillSkillInstallResults.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cliURL.path),
                       "disabling Token Saver must uninstall managed distill CLI")
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
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
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
        process.environment = CodexRunner.processEnvironment(overrides: [
            "REMOTE_CODE_DISTILL_STATE_PATH": stateURL.path,
            "REMOTE_CODE_AGENT_PROVIDER": "codex",
            "RC_TOKEN_SAVER_WORKSPACE_ID": "workspace",
            "RC_TOKEN_SAVER_PROJECT_ID": "project",
            "RC_TOKEN_SAVER_THREAD_ID": "thread",
            "RC_TOKEN_SAVER_ATTEMPT_ID": "attempt",
        ], purpose: .supportProcess)

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

    func test_appContextLaunchInstallsAppPrivateDistillWhenTokenSaverEnabled() throws {
        let appSupport = NSTemporaryDirectory() + "RC2ManagedSkillsLaunchOn-" + UUID().uuidString
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2ManagedSkillsLaunchHome-" + UUID().uuidString, isDirectory: true)
        let skillURLs = managedDistillSkillURLs(home: home)
        let configURLs = managedDistillConfigURLs(home: home)
        let appPrivateSkill = URL(fileURLWithPath: appSupport, isDirectory: true)
            .appendingPathComponent("AgentSkills/distill/SKILL.md")

        let seedContext = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: seedContext.db).save(AppSettings(tokenSaverEnabled: true))

        let launchedContext = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            agentSkillsHomeOverrideForTesting: home
        )

        XCTAssertEqual(launchedContext.managedDistillSkillInstallResults.count, 1,
                       "Token Saver on at launch installs a single app-private Distill package")
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

        let seedContext = try AppContext(channel: .debug, appSupportOverride: appSupport)
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
        let context = try AppContext(
            channel: .debug,
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
        let context = try AppContext(
            channel: .debug,
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
        let context = try AppContext(
            channel: .debug,
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
        let context = try AppContext(
            channel: .debug,
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
        {"msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":61.0,"billingPeriodEnd":"2026-07-22T20:46:41.975270+00:00"}}}
        """
        try body.write(to: log, atomically: true, encoding: .utf8)

        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
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

        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        context.refreshGrokTokenSaverAccountUsage(reason: "run_finished", billingLogURL: log)
        try? await Task.sleep(nanoseconds: 80_000_000)

        let snapshot = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
        XCTAssertNil(snapshot.providers.first(where: { $0.provider == .grok })?.weeklyUsedPercent,
                     "signed-out sessions must not probe or persist Grok billing usage")
    }

    func test_tokenSaverCompressionCompressesPromptAndRecordsMeasuredSavingsToDB() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverCompress-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        // Real in-process distill service (LocalDistillRuntime, no MLX needed).
        let configuration = try DistillServiceConfiguration(
            authToken: "test-token",
            appSupportDirectory: appSupport
        )
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 4)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler, scopedRecoveryStore: TestScopedRecoveryStore(db: context.db))
        let ready = try await server.start()
        defer { server.stop() }
        context.distillClientOverrideForTesting = DistillServiceClient(ready: ready, authToken: "test-token")

        let bigPrompt = (1...40)
            .map { "line \($0): a verbose instruction line that the distiller will compress away" }
            .joined(separator: "\n")
        XCTAssertGreaterThan(bigPrompt.count, 2_000, "must clear the raised NetPositiveGate floor")

        // Fresh thread => no prior turn => gate treats it as COLD => compresses (N5).
        let threadID = try makeAdmittedTokenSaverThread(in: context, provider: .claude)
        try admitTokenSaver(in: context, threadID: threadID, lane: "semantic_prose")
        let compressed = await context.tokenSaverCompress(
            prompt: bigPrompt, provider: .claude, threadId: threadID, runId: AgentRunID()
        )

        XCTAssertNotEqual(compressed, bigPrompt, "an enabled Token Saver with a reachable model must compress a large cold prompt")
        XCTAssertLessThan(compressed.count, bigPrompt.count, "compressed prompt must be smaller than the original")

        let summary = try context.tokenSaverSavingsRepo.summary()
        let claude = try XCTUnwrap(summary.savings(for: "claude"),
                                   "a measured savings row must be persisted to the local DB for the compressed run")
        XCTAssertEqual(claude.inputTokens, TokenEstimator.estimate(bigPrompt),
                       "savings are recorded in estimated tokens, not characters")
        XCTAssertEqual(claude.outputTokens, TokenEstimator.estimate(compressed),
                       "savings are recorded in estimated tokens, not characters")
        XCTAssertEqual(claude.savedTokens, max(TokenEstimator.estimate(bigPrompt) - TokenEstimator.estimate(compressed), 0))
        XCTAssertEqual(claude.runs, 1)
        XCTAssertGreaterThan(summary.averageSavedPerRun, 0, "the per-run average (média) must be computable from real data")
    }

    func test_semanticSidecarAdoptionRequiresPromotedLaneRetentionAndScopedReadback() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2SemanticRecovery-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let configuration = try DistillServiceConfiguration(authToken: "semantic-token", appSupportDirectory: appSupport)
        let scheduler = DistillScheduler(
            runtime: FixedOutputRuntime(output: "Concise safe prose."),
            maxConcurrentRequests: 2,
            resultCacheCapacity: 0
        )
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler, scopedRecoveryStore: TestScopedRecoveryStore(db: context.db))
        let ready = try await server.start()
        defer { server.stop() }
        context.distillClientOverrideForTesting = DistillServiceClient(ready: ready, authToken: "semantic-token")

        let threadID = try makeAdmittedTokenSaverThread(in: context, provider: .claude)
        let thread = try XCTUnwrap(context.threadRepo.get(id: threadID))
        let projectID = try XCTUnwrap(thread.projectId?.value.uuidString)
        let repeatedBlock = String(
            repeating: "Verbose prose carries recoverable contextual explanation and guidance. ",
            count: 50
        )
        let prompt = repeatedBlock + "\n\n" + repeatedBlock
        let runID = AgentRunID()
        func setSemantic(state: String, retentionDays: Int) throws {
            try context.tokenSaverLaneStateRepo.upsert(.init(
                projectID: projectID,
                lane: "semantic_prose",
                state: state,
                reason: "test",
                evidenceLevel: "provider_usage",
                ownerRole: "Security Owner:test",
                permissionBoundary: "project",
                retentionDays: retentionDays,
                optedOut: false,
                killSwitchActive: false,
                attributionJoined: true,
                reconciliationPassed: true,
                usageSemanticsAvailable: true,
                scorecardID: "semantic-scorecard"
            ))
        }

        try setSemantic(state: "shadow_only", retentionDays: 30)
        let shadowOutput = await context.tokenSaverCompress(
            prompt: prompt, provider: .claude, threadId: threadID, runId: runID
        )
        let deterministicOutput = DistillBlockDeduper.dedupe(prompt).output
        XCTAssertEqual(shadowOutput, deterministicOutput, "shadow semantic output must never replace deterministic provider bytes")
        try setSemantic(state: "promoted", retentionDays: 0)
        let zeroRetentionOutput = await context.tokenSaverCompress(
            prompt: prompt, provider: .claude, threadId: threadID, runId: runID
        )
        XCTAssertEqual(zeroRetentionOutput, deterministicOutput, "retention zero must keep only the non-lossy deterministic win")
        let recoveryBefore = try context.db.prepare("SELECT COUNT(*) FROM token_saver_recovery_objects;")
        XCTAssertTrue(try recoveryBefore.step())
        XCTAssertEqual(recoveryBefore.columnInt64(0), 0)

        try setSemantic(state: "promoted", retentionDays: 7)
        let adopted = await context.tokenSaverCompress(
            prompt: prompt, provider: .claude, threadId: threadID, runId: runID
        )
        XCTAssertTrue(adopted.contains("[[rc:rcv1."))
        XCTAssertLessThan(adopted.utf8.count, prompt.utf8.count)
        let capabilities = adopted.components(separatedBy: "[[rc:").dropFirst().compactMap {
            $0.components(separatedBy: "]]").first
        }
        XCTAssertEqual(capabilities.count, 2, "dedupe + semantic loss requires stage and full-original recovery")
        let scope = TokenSaverPersistentScope(
            workspaceID: try XCTUnwrap(thread.workspaceId?.value.uuidString),
            projectID: projectID,
            threadID: threadID.value.uuidString,
            provider: AgentProvider.claude.rawValue,
            attemptID: runID.value.uuidString
        )
        let recoveryStore = TokenSaverScopedRecoveryStore(db: context.db)
        let recovered = try capabilities.compactMap {
            try recoveryStore.retrieve(capability: $0, scope: scope)
        }
        XCTAssertTrue(recovered.contains(Data(prompt.utf8)), "one marker must recover the exact full pre-pipeline prompt")
        XCTAssertTrue(
            recovered.contains(Data(deterministicOutput.utf8)),
            "accepted dual-marker path must also recover the exact deterministic stage original"
        )
        let recoveryAfter = try context.db.prepare("SELECT COUNT(*) FROM token_saver_recovery_objects;")
        XCTAssertTrue(try recoveryAfter.step())
        XCTAssertEqual(recoveryAfter.columnInt64(0), 2)
        let outbox = try context.db.prepare("SELECT COUNT(*), MIN(state) FROM token_saver_recovery_outbox;")
        XCTAssertTrue(try outbox.step())
        XCTAssertEqual(outbox.columnInt64(0), 2)
        XCTAssertEqual(outbox.columnText(1), "acked")
        let liveCaps = try context.db.prepare(
            "SELECT COUNT(*) FROM token_saver_recovery_capabilities WHERE revoked_at_ms IS NULL;"
        )
        XCTAssertTrue(try liveCaps.step())
        XCTAssertEqual(liveCaps.columnInt64(0), 2)
    }

    func test_semanticAtomicFinalizationInjectedFailureEmitsNoMarkerAndDiscardsProvisionals() async throws {
        // C6-I1: if multi-object finalization fails after the first member would have
        // committed under the old split-transaction path, fail-open must emit no marker
        // and discard every still-provisional recovery object.
        let appSupport = NSTemporaryDirectory() + "RC2SemanticAtomicFinalize-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let configuration = try DistillServiceConfiguration(
            authToken: "test-only-token",
            appSupportDirectory: appSupport
        )
        let scheduler = DistillScheduler(
            runtime: FixedOutputRuntime(output: "Concise safe prose."),
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
            authToken: "test-only-token"
        )

        let threadID = try makeAdmittedTokenSaverThread(in: context, provider: .claude)
        try admitTokenSaver(in: context, threadID: threadID, lane: "semantic_prose")
        let repeatedBlock = String(
            repeating: "Verbose prose carries recoverable contextual explanation and guidance. ",
            count: 50
        )
        let prompt = repeatedBlock + "\n\n" + repeatedBlock
        let runID = AgentRunID()

        TokenSaverScopedRecoveryStore.testInjectFailureBetweenSemanticFinalizationMembers = true
        defer { TokenSaverScopedRecoveryStore.testInjectFailureBetweenSemanticFinalizationMembers = false }

        let output = await context.tokenSaverCompress(
            prompt: prompt, provider: .claude, threadId: threadID, runId: runID
        )

        let deterministicOutput = DistillBlockDeduper.dedupe(prompt).output
        XCTAssertEqual(
            output,
            deterministicOutput.count < prompt.count ? deterministicOutput : prompt,
            "injected finalization failure must fail open to deterministic/original"
        )
        XCTAssertFalse(output.contains("[[rc:"), "fail-open after finalization failure must emit no recovery marker")

        let liveObjects = try context.db.prepare(
            "SELECT COUNT(*) FROM token_saver_recovery_objects WHERE tombstoned_at_ms IS NULL;"
        )
        XCTAssertTrue(try liveObjects.step())
        XCTAssertEqual(liveObjects.columnInt64(0), 0, "all provisionals must be discarded after finalization failure")
        let liveCaps = try context.db.prepare(
            "SELECT COUNT(*) FROM token_saver_recovery_capabilities WHERE revoked_at_ms IS NULL;"
        )
        XCTAssertTrue(try liveCaps.step())
        XCTAssertEqual(liveCaps.columnInt64(0), 0, "zero live capabilities after discard")
        let outbox = try context.db.prepare(
            "SELECT COUNT(*), MIN(state), MIN(transport_outcome) FROM token_saver_recovery_outbox;"
        )
        XCTAssertTrue(try outbox.step())
        XCTAssertGreaterThan(outbox.columnInt64(0), 0, "stage/full objects were prepared then abandoned")
        XCTAssertEqual(outbox.columnText(1), "acked")
        XCTAssertEqual(outbox.columnText(2), "acked")
        let scrubbed = try context.db.prepare(
            """
            SELECT COUNT(*) FROM token_saver_recovery_objects
            WHERE original = X'' AND integrity_sha256 = '' AND byte_count = 0
              AND tombstoned_at_ms IS NOT NULL;
            """
        )
        XCTAssertTrue(try scrubbed.step())
        XCTAssertEqual(scrubbed.columnInt64(0), outbox.columnInt64(0))
    }

    func test_semanticMarkerOverheadRejectionFallsBackWithoutLiveRecovery() async throws {
        // C4-I1: a model-only character win can still lose after markers are attached.
        // The final UTF-8 gate must reject before ack and leave zero live private rows.
        let appSupport = NSTemporaryDirectory() + "RC2SemanticMarkerOverhead-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let configuration = try DistillServiceConfiguration(
            authToken: "test-only-token",
            appSupportDirectory: appSupport
        )
        // Single non-duplicated prose body so deterministic stage == original (one marker).
        let prompt = String(
            repeating: "Unique verbose prose carries recoverable contextual explanation and guidance. ",
            count: 40
        )
        XCTAssertGreaterThan(prompt.count, 2_000)
        XCTAssertEqual(DistillBlockDeduper.dedupe(prompt).output, prompt)
        // Save fewer characters than a single [[rc:rcv1...]] marker adds.
        let marginalCandidate = String(prompt.dropLast(24))
        XCTAssertLessThan(marginalCandidate.utf8.count, prompt.utf8.count)
        let scheduler = DistillScheduler(
            runtime: FixedOutputRuntime(output: marginalCandidate),
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
            authToken: "test-only-token"
        )

        let threadID = try makeAdmittedTokenSaverThread(in: context, provider: .claude)
        try admitTokenSaver(in: context, threadID: threadID, lane: "semantic_prose")
        let runID = AgentRunID()
        let output = await context.tokenSaverCompress(
            prompt: prompt,
            provider: .claude,
            threadId: threadID,
            runId: runID
        )

        XCTAssertEqual(output, prompt, "marker overhead must force deterministic/original fail-open")
        XCTAssertFalse(output.contains("[[rc:"), "rejected semantic candidate must emit no recovery marker")
        let liveObjects = try context.db.prepare(
            "SELECT COUNT(*) FROM token_saver_recovery_objects WHERE tombstoned_at_ms IS NULL;"
        )
        XCTAssertTrue(try liveObjects.step())
        XCTAssertEqual(liveObjects.columnInt64(0), 0, "no live stage/full-original private rows may remain")
        let liveCaps = try context.db.prepare(
            "SELECT COUNT(*) FROM token_saver_recovery_capabilities WHERE revoked_at_ms IS NULL;"
        )
        XCTAssertTrue(try liveCaps.step())
        XCTAssertEqual(liveCaps.columnInt64(0), 0, "zero live capabilities after abandonment")
        let outbox = try context.db.prepare(
            "SELECT COUNT(*), MIN(state), MIN(transport_outcome) FROM token_saver_recovery_outbox;"
        )
        XCTAssertTrue(try outbox.step())
        XCTAssertGreaterThan(outbox.columnInt64(0), 0, "stage was prepared then abandoned")
        XCTAssertEqual(outbox.columnText(1), "acked")
        XCTAssertEqual(outbox.columnText(2), "acked")
        let scrubbed = try context.db.prepare(
            """
            SELECT COUNT(*) FROM token_saver_recovery_objects
            WHERE original = X'' AND integrity_sha256 = '' AND byte_count = 0
              AND tombstoned_at_ms IS NOT NULL;
            """
        )
        XCTAssertTrue(try scrubbed.step())
        XCTAssertEqual(scrubbed.columnInt64(0), outbox.columnInt64(0))
    }

    func test_semanticModelLossAfterStagePreparationLeavesNoLivePrivateRow() async throws {
        // Distill prepares stage recovery whenever lossy output differs from input.
        // If the model later loses the adoption race, that provisional must be discarded.
        let appSupport = NSTemporaryDirectory() + "RC2SemanticModelLoss-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let configuration = try DistillServiceConfiguration(
            authToken: "test-only-token",
            appSupportDirectory: appSupport
        )
        let prompt = String(
            repeating: "Unique verbose prose carries recoverable contextual explanation and guidance. ",
            count: 40
        )
        // Same-length different bytes: Distill still prepares stage recovery (output != input),
        // but AppContext modelWon requires a strict character win and therefore rejects.
        let nonWinningCandidate = String(repeating: "Z", count: prompt.count)
        let scheduler = DistillScheduler(
            runtime: FixedOutputRuntime(output: nonWinningCandidate),
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
            authToken: "test-only-token"
        )

        let threadID = try makeAdmittedTokenSaverThread(in: context, provider: .claude)
        try admitTokenSaver(in: context, threadID: threadID, lane: "semantic_prose")
        let output = await context.tokenSaverCompress(
            prompt: prompt,
            provider: .claude,
            threadId: threadID,
            runId: AgentRunID()
        )

        XCTAssertEqual(output, prompt)
        XCTAssertFalse(output.contains("[[rc:"))
        let liveObjects = try context.db.prepare(
            "SELECT COUNT(*) FROM token_saver_recovery_objects WHERE tombstoned_at_ms IS NULL;"
        )
        XCTAssertTrue(try liveObjects.step())
        XCTAssertEqual(liveObjects.columnInt64(0), 0, "model-loss after stage prep must leave no live private row")
        let liveCaps = try context.db.prepare(
            "SELECT COUNT(*) FROM token_saver_recovery_capabilities WHERE revoked_at_ms IS NULL;"
        )
        XCTAssertTrue(try liveCaps.step())
        XCTAssertEqual(liveCaps.columnInt64(0), 0)
        let totalObjects = try context.db.prepare("SELECT COUNT(*) FROM token_saver_recovery_objects;")
        XCTAssertTrue(try totalObjects.step())
        XCTAssertEqual(totalObjects.columnInt64(0), 1, "exactly the stage provisional is prepared then tombstoned")
    }

    func test_tokenSaverProjectVerbatimAdmissionReturnsExactBytesWithoutWriters() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverVerbatimAdmission-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let threadID = try makeAdmittedTokenSaverThread(in: context, provider: .grok)
        let thread = try XCTUnwrap(context.threadRepo.get(id: threadID))
        let projectID = try XCTUnwrap(thread.projectId?.value.uuidString)
        try context.tokenSaverLaneStateRepo.forceVerbatim(projectID: projectID)
        let prompt = String(repeating: "same large exact block with literal ABC-123\n", count: 100)

        let output = await context.tokenSaverCompress(prompt: prompt, provider: .grok, threadId: threadID)

        XCTAssertEqual(Data(output.utf8), Data(prompt.utf8),
                       "project Verbatim must bypass deterministic and model compressors byte-for-byte")
        XCTAssertEqual(try context.tokenSaverSavingsRepo.summary().totalRuns, 0)
    }

    func test_tokenSaverCompressionAutoSavesForCodexNotJustClaude() async throws {
        // The "Codex Saved 0" complaint: prompt compression is provider-agnostic. The same
        // automatic compress path that records Claude savings must record Codex savings —
        // attributed to codex, engine-tagged — WITHOUT the agent voluntarily piping anything.
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverCodexAuto-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        let configuration = try DistillServiceConfiguration(authToken: "codex-token", appSupportDirectory: appSupport)
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 4)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler, scopedRecoveryStore: TestScopedRecoveryStore(db: context.db))
        let ready = try await server.start()
        defer { server.stop() }
        context.distillClientOverrideForTesting = DistillServiceClient(ready: ready, authToken: "codex-token")

        let bigPrompt = (1...40)
            .map { "line \($0): a verbose codex instruction line that the distiller will compress away" }
            .joined(separator: "\n")
        XCTAssertGreaterThan(bigPrompt.count, 2_000)

        let threadID = try makeAdmittedTokenSaverThread(in: context, provider: .codex)
        try admitTokenSaver(in: context, threadID: threadID, lane: "semantic_prose")
        let compressed = await context.tokenSaverCompress(
            prompt: bigPrompt, provider: .codex, threadId: threadID, runId: AgentRunID()
        )
        XCTAssertLessThan(compressed.count, bigPrompt.count, "Codex prompts must auto-compress, exactly like Claude")

        let summary = try context.tokenSaverSavingsRepo.summary()
        let codex = try XCTUnwrap(summary.savings(for: "codex"),
                                  "a codex-attributed savings row must be persisted — proving Codex is no longer 'Saved 0'")
        XCTAssertGreaterThan(codex.savedTokens, 0, "Codex must actually save tokens automatically")
        XCTAssertEqual(codex.runs, 1)
        // The engine that produced the win must be folded into the mode for the breakdown.
        let codexMode = try XCTUnwrap(summary.modes.first { $0.provider == "codex" })
        XCTAssertTrue(codexMode.mode.contains("(deterministic)") || codexMode.mode.contains("(model)"),
                      "codex savings must be engine-attributed, got mode=\(codexMode.mode)")
        XCTAssertNil(summary.savings(for: "claude"), "this run was codex-only; no claude row should exist")
    }

    func test_tokenSaverFollowUpCompressionRecordsPromptFollowupCacheState() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverFollowupLedger-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        let configuration = try DistillServiceConfiguration(
            authToken: "followup-token",
            appSupportDirectory: appSupport
        )
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 4)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler, scopedRecoveryStore: TestScopedRecoveryStore(db: context.db))
        let ready = try await server.start()
        defer { server.stop() }
        context.distillClientOverrideForTesting = DistillServiceClient(ready: ready, authToken: "followup-token")

        let prompt = (1...40)
            .map { "follow-up verbose prose segment \($0) with repeated diagnostic context and remediation detail" }
            .joined(separator: "\n")

        let threadID = try makeAdmittedTokenSaverThread(in: context, provider: .claude)
        try admitTokenSaver(in: context, threadID: threadID, lane: "semantic_prose")
        let compressed = await context.tokenSaverCompress(
            prompt: prompt,
            provider: .claude,
            threadId: threadID,
            cacheState: "prompt_followup",
            runId: AgentRunID()
        )

        XCTAssertLessThan(compressed.count, prompt.count)
        let stmt = try context.db.prepare("SELECT cache_state FROM token_saver_savings LIMIT 1;")
        XCTAssertTrue(try stmt.step())
        XCTAssertEqual(stmt.columnText(0), "prompt_followup")
    }

    func test_tokenSaverCompressionRejectsModelOutputThatDropsPinnedLiteral() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverLiteralGuard-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        let configuration = try DistillServiceConfiguration(
            authToken: "literal-token",
            appSupportDirectory: appSupport
        )
        let scheduler = DistillScheduler(runtime: FixedOutputRuntime(output: "Short summary without the exact file reference."), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
        let ready = try await server.start()
        defer { server.stop() }
        context.distillClientOverrideForTesting = DistillServiceClient(ready: ready, authToken: "literal-token")

        let prompt = (1...35)
            .map { "diagnostic \($0): failure remains at /tmp/Foo.swift:4242 with verbose context and identifier build-\($0)" }
            .joined(separator: "\n")

        let threadID = try makeAdmittedTokenSaverThread(in: context, provider: .claude)
        try context.tokenSaverLaneStateRepo.upsert(.init(
            projectID: try XCTUnwrap(context.threadRepo.get(id: threadID)?.projectId?.value.uuidString),
            lane: "semantic_prose", state: "shadow_only", reason: "test",
            evidenceLevel: "diagnostic_heuristic", ownerRole: "Security Owner:test",
            permissionBoundary: "project", retentionDays: 30, optedOut: false, killSwitchActive: false
        ))
        let compressed = await context.tokenSaverCompress(prompt: prompt, provider: .claude, threadId: threadID)

        XCTAssertEqual(compressed, prompt,
                       "dropping a pinned file:line literal must reject model compression and fail open")
        XCTAssertEqual(try context.tokenSaverSavingsRepo.summary().totalRuns, 0,
                       "rejected lossy output must not fabricate savings")
    }

    func test_tokenSaverGateSkipsBelowFloorPrompt() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2GateFloor-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        // Under the NetPositiveGate floor (~2k) the gate must skip BEFORE any distill
        // call — a model round-trip on a tiny prompt is not net-positive (G3).
        let small = "tiny prompt well under the compression floor"
        XCTAssertLessThan(small.count, 2_000)
        let threadID = try makeAdmittedTokenSaverThread(in: context, provider: .claude)
        let out = await context.tokenSaverCompress(prompt: small, provider: .claude, threadId: threadID)
        XCTAssertEqual(out, small, "below floor => returned verbatim, no compression")
    }

    func test_tokenSaverSkipSetAvoidsRepeatingKnownNoWinPrompt() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2PromptSkipSet-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        let configuration = try DistillServiceConfiguration(
            authToken: "skip-set-token",
            appSupportDirectory: appSupport
        )
        let runtime = CountingEchoRuntime()
        let scheduler = DistillScheduler(
            runtime: runtime,
            maxConcurrentRequests: 2,
            resultCacheCapacity: 0
        )
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
        let ready = try await server.start()
        defer { server.stop() }
        context.distillClientOverrideForTesting = DistillServiceClient(ready: ready, authToken: "skip-set-token")

        let prompt = (1...45)
            .map { "unique non-compressible instruction line \($0) with path /tmp/file-\($0).swift and code \($0)" }
            .joined(separator: "\n")
        XCTAssertGreaterThan(prompt.count, 2_000)

        let threadID = try makeAdmittedTokenSaverThread(in: context, provider: .claude)
        try context.tokenSaverLaneStateRepo.upsert(.init(
            projectID: try XCTUnwrap(context.threadRepo.get(id: threadID)?.projectId?.value.uuidString),
            lane: "semantic_prose", state: "shadow_only", reason: "test",
            evidenceLevel: "diagnostic_heuristic", ownerRole: "Security Owner:test",
            permissionBoundary: "project", retentionDays: 30, optedOut: false, killSwitchActive: false
        ))
        let first = await context.tokenSaverCompress(prompt: prompt, provider: .claude, threadId: threadID)
        let second = await context.tokenSaverCompress(prompt: prompt, provider: .claude, threadId: threadID)

        XCTAssertEqual(first, prompt)
        XCTAssertEqual(second, prompt)
        let callCount = await runtime.callCount
        XCTAssertEqual(callCount, 1,
                       "a known no-win prompt should be remembered locally instead of paying the sidecar again")
        XCTAssertEqual(try context.tokenSaverSavingsRepo.summary().totalRuns, 0,
                       "no-win skip-set entries must not fabricate savings rows")
    }

    func test_tokenSaverDedupsRepeatedBlockEvenWithoutModelService() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2Dedup-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        // No distill client override and no sidecar → the model step is unavailable; the
        // deterministic, non-lossy dedup must still apply (P4) and fail open to it.

        let block = String(repeating: "The renderer validates each config field before drawing the widget. ", count: 10)
        let padding = String(repeating: "padding sentence to clear the floor. ", count: 30)
        let prompt = "Task intro. \(padding)\n\n\(block)\n\nMiddle note.\n\n\(block)\n\nEnd."
        XCTAssertGreaterThan(prompt.count, 2_000)

        let threadID = try makeAdmittedTokenSaverThread(in: context, provider: .claude)
        let out = await context.tokenSaverCompress(prompt: prompt, provider: .claude, threadId: threadID)
        XCTAssertLessThan(out.count, prompt.count, "the duplicate block is collapsed even with no model service")
        XCTAssertTrue(out.contains("⟪identical to block #"), "model-readable dedup pointer present (non-lossy)")
        XCTAssertTrue(out.contains(block), "the first occurrence stays inline — no information lost")
        XCTAssertEqual(try context.tokenSaverSavingsRepo.summary().totalRuns, 1, "the dedup saving is recorded")
    }

    func test_tokenSaverNearDedupDoesNotEmitUnscopedRecoveryMarker() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2NearDedup-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        let stableTail = String(repeating: " stable auth diagnostic payload", count: 180)
        let first = """
        2026-06-13T10:20:30Z pid=1234 crashed at 0x0000000abcdef123
        ERROR auth failed in LoginView.swift:88\(stableTail)
        """
        let second = """
        2026-06-13T10:20:31Z pid=5678 crashed at 0x0000000abcdef999
        ERROR auth failed in LoginView.swift:88\(stableTail)
        """
        let prompt = "Task intro.\n\n\(first)\n\n\(second)\n\nEnd."
        XCTAssertGreaterThan(prompt.utf8.count, 8_192)

        let threadID = try makeAdmittedTokenSaverThread(in: context, provider: .claude)
        let out = await context.tokenSaverCompress(prompt: prompt, provider: .claude, threadId: threadID)

        XCTAssertLessThan(out.count, prompt.count)
        XCTAssertTrue(out.contains("same as block #1 above except"))
        XCTAssertTrue(out.contains("pid=1234"))
        XCTAssertTrue(out.contains("pid=5678"))
        XCTAssertNil(
            out.range(of: #"\[\[rc:[0-9a-f]+\]\]"#, options: .regularExpression),
            "Wave -1: exact/volatile dedup may remain self-contained, but no raw-hash recovery marker may be emitted"
        )
        XCTAssertEqual(
            try ReversibleContentStore(db: context.db).count(),
            0,
            "Wave -1: near-dedup must not create a new unscoped recovery row"
        )
    }

    func test_tokenSaverDiffPromptFailsOpenUntilScopedRecoveryShips() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2DiffWindow-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        var lines = ["Review this patch:", "diff --git a/Sources/App.swift b/Sources/App.swift", "@@ -1,90 +1,90 @@"]
        for i in 0..<36 {
            lines.append(" context before \(i) with verbose unchanged implementation detail that should not be re-injected into the provider prompt")
        }
        lines.append("-let retryLimit = 2")
        lines.append("+let retryLimit = 4")
        for i in 0..<36 {
            lines.append(" context after \(i) with verbose unchanged implementation detail that should not be re-injected into the provider prompt")
        }
        let prompt = lines.joined(separator: "\n")
        XCTAssertGreaterThan(prompt.count, 2_000)

        let threadID = try makeAdmittedTokenSaverThread(in: context, provider: .claude)
        let out = await context.tokenSaverCompress(prompt: prompt, provider: .claude, threadId: threadID)

        XCTAssertEqual(
            out,
            prompt,
            "Wave -1: diff windowing is lossy and must fail open until scoped recovery and durable read-back ship"
        )
        XCTAssertFalse(out.contains("[[rc:"), "Wave -1: no unscoped raw-hash marker")
        XCTAssertEqual(try ReversibleContentStore(db: context.db).count(), 0)
        XCTAssertEqual(
            try context.tokenSaverSavingsRepo.summary().totalRuns,
            0,
            "verbatim containment must not receive savings credit"
        )
    }

    func test_sessionLearnWritesBoundedExactScopeWithoutGlobalInstructions() throws {
        let appSupport = NSTemporaryDirectory() + "RC2SessionLearn-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
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
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
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
        let context = try AppContext(
            channel: .debug,
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
        let shadow = await context.coordinator.promptCompressor?(prompt, .codex, thread.id, AgentRunID())
        XCTAssertEqual(shadow, prompt)

        try setLane("promoted")
        let promotedValue = await context.coordinator.promptCompressor?(prompt, .codex, thread.id, AgentRunID())
        let promoted = try XCTUnwrap(promotedValue)
        XCTAssertTrue(promoted.contains("preserve browser parity"))
        XCTAssertFalse(promoted.contains("wrong scope browser secret"))
        XCTAssertLessThanOrEqual(promoted.utf8.count - prompt.utf8.count, 560)
    }

    func test_sessionLearnExpensiveRunWritesBoundedExactScope() throws {
        let appSupport = NSTemporaryDirectory() + "RC2SessionLearnTokens-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
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
            status: .completed,
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
        let context = try AppContext(
            channel: .debug,
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
        let context = try AppContext(
            channel: .debug,
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
        let context = try AppContext(
            channel: .debug,
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
        let context = try AppContext(
            channel: .debug,
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
        let context = try AppContext(
            channel: .debug,
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

    func test_offLaneSR1IsHumanizedWithoutTokenSaverWriters() async throws {
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: NSTemporaryDirectory() + "RC2SR1OffLane-" + UUID().uuidString
        )
        let thread = AgentThread(title: "off lane", provider: .grok, model: "test", status: .completed)
        try context.threadRepo.upsert(thread)
        let sr1 = """
        SR1
        S=done
        O=The result is ready.
        """

        let result = await context.tokenSaverHumanizeSR1Response(sr1, provider: .grok, threadId: thread.id)

        XCTAssertFalse(SR1ResponseDetector.isSR1(result))
        XCTAssertEqual(try context.tokenSaverSavingsRepo.summary().totalRuns, 0)
        let attempts = try context.db.prepare("SELECT COUNT(*) FROM token_saver_attempts;")
        XCTAssertTrue(try attempts.step())
        XCTAssertEqual(attempts.columnInt64(0), 0)
    }

    func test_tokenSaverHumanizesSR1FinalResponseThroughDistillClientInUserLanguage() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverHumanizeSR1-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
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

    func test_tokenSaverHumanizesSpaceDelimitedDistillResponseThroughDistillClient() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverHumanizeSR1Space-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)

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
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)

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
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
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
        let factor = TokenSaverSR1SavingsEstimator.effectiveExpansionFactor
        let perInput = humanized.count * factor
        let perOutput = sr1.count * factor
        let expectedInput = perInput * 2
        let expectedOutput = perOutput * 2
        let expectedSaved = max(perInput - perOutput, 0) * 2
        XCTAssertEqual(codex.inputTokens, expectedInput,
                       "SR1 humanization savings must include the avoided human-language transcript expansion at the default-agent verbosity rate")
        XCTAssertEqual(codex.outputTokens, expectedOutput,
                       "SR1 humanization savings must scale the emitted compressed SR1 response with the same factor")
        XCTAssertEqual(codex.savedTokens, expectedSaved,
                       "saved = scaled human length - scaled SR1 length, credited for default agent verbosity, for every sidecar call")
        XCTAssertEqual(codex.runs, 2,
                       "every successful local sidecar humanization call must update Token Saver reports")
    }

    func test_tokenSaverHumanizedSR1FallbackCreditsDefaultAgentVerbosityFactorWhenSidecarUnavailable() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverSR1FallbackSavings-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
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
        let factor = TokenSaverSR1SavingsEstimator.effectiveExpansionFactor
        XCTAssertEqual(claude.inputTokens, humanized.count * factor)
        XCTAssertEqual(claude.outputTokens, sr1.count * factor)
        XCTAssertEqual(claude.savedTokens, max((humanized.count - sr1.count) * factor, 0))
        XCTAssertEqual(claude.runs, 1)
        XCTAssertEqual(summary.modes.first?.mode, "sr1-humanize")
    }

    func test_tokenSaverUsageForDistillSkillRunDoesNotRecordSavingsWithoutSidecarCall() throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverDistillSkillSavings-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
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
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
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
        XCTAssertTrue(attempt.unavailableFields.contains("provider_usage_semantics"))
        let events = try context.tokenSaverAttemptLedger.events(attemptID: attemptID)
        XCTAssertEqual(events.map(\.kind), ["provider_usage"])
        XCTAssertTrue(events[0].payloadJSON.contains("\"total_tokens\":200"))
        XCTAssertTrue(events[0].payloadJSON.contains("\"semantics\":\"unavailable\""))
        let components = try context.db.prepare("SELECT category, tokens FROM token_saver_input_components WHERE attempt_id = ?;")
        try components.bind(1, attemptID)
        XCTAssertTrue(try components.step())
        XCTAssertEqual(components.columnText(0), "unattributed_provider_input")
        XCTAssertEqual(components.columnInt64(1), 120)
        XCTAssertEqual(try context.tokenSaverSavingsRepo.summary().totalRuns, 0)
        let laneStates = try context.tokenSaverLaneStateRepo.list(projectID: thread.projectId!.value.uuidString)
        XCTAssertEqual(laneStates.first(where: { $0.lane == "deterministic_wrapper" })?.state, "promoted")
    }

    func test_shadowPreparationJoinsExactScopeAndRunsPoliciesWithoutChangingProviderBytes() async throws {
        let context = try AppContext(
            channel: .debug,
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
        let first = try AppContext(channel: .debug, appSupportOverride: appSupport)
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

        let degraded = try AppContext(channel: .debug, appSupportOverride: appSupport)
        XCTAssertTrue(degraded.tokenSaverLifecycleDegradedReason?.contains("lifecycle_sweep_failed") == true)
        SettingsStore(db: degraded.db).update { $0.tokenSaverEnabled = true }
        let threadID = try makeAdmittedTokenSaverThread(in: degraded, provider: .claude)
        let prompt = String(repeating: "degraded mode keeps this exact input verbatim\n", count: 80)
        let output = await degraded.tokenSaverCompress(prompt: prompt, provider: .claude, threadId: threadID)
        XCTAssertEqual(output, prompt)
        XCTAssertEqual(
            degraded.tokenSaverRolloverAdmission(parentThreadID: threadID).reason,
            "lifecycle_degraded"
        )
    }

    func test_tokenSaverUsageForDistillSkillRunWithTotalOnlyUsageDoesNotFabricateSavings() throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverDistillSkillTotalOnlySavings-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
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
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
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

    func test_tokenSaverCompressionIsNoOpWhenDisabledOrTooShort() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverNoop-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)

        let configuration = try DistillServiceConfiguration(authToken: "t", appSupportDirectory: appSupport)
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
        let ready = try await server.start()
        defer { server.stop() }
        context.distillClientOverrideForTesting = DistillServiceClient(ready: ready, authToken: "t")

        let bigPrompt = String(repeating: "verbose line to compress here\n", count: 40)

        // Disabled → verbatim passthrough, no DB rows.
        let threadID = try makeAdmittedTokenSaverThread(in: context, provider: .claude)
        let disabled = await context.tokenSaverCompress(prompt: bigPrompt, provider: .claude, threadId: threadID)
        XCTAssertEqual(disabled, bigPrompt)
        XCTAssertEqual(try context.tokenSaverSavingsRepo.summary().totalRuns, 0)

        // Enabled but tiny prompt → below threshold, passthrough, no DB rows.
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let tiny = await context.tokenSaverCompress(prompt: "fix typo", provider: .claude, threadId: threadID)
        XCTAssertEqual(tiny, "fix typo")
        XCTAssertEqual(try context.tokenSaverSavingsRepo.summary().totalRuns, 0)
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
            return XCTFail("expected running Token Saver sidecar status")
        }
        XCTAssertEqual(event.runtime, DistillApprovedModel.runtime)
        XCTAssertEqual(event.modelID, DistillApprovedModel.id)
        XCTAssertEqual(event.maxConcurrentRequests, 8)
        XCTAssertEqual(event.maxQueueDepth, 64)
        let token = try XCTUnwrap(controller.bearerToken)
        let stateURL = appSupport
            .appendingPathComponent("Distill", isDirectory: true)
            .appendingPathComponent("DistillCLIState.json")
        let state = try String(contentsOf: stateURL)
        XCTAssertTrue(state.contains("\"base_url\":\"http:\\/\\/127.0.0.1:18181\"") ||
                      state.contains("\"base_url\":\"http://127.0.0.1:18181\""))
        XCTAssertTrue(state.contains(token),
                      "the managed distill CLI needs the live sidecar bearer token, not an external TypeScript CLI")

        controller.stop()
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

        controller.stop()
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
}
