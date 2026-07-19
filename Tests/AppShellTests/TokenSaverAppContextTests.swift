import XCTest
import AppKit
import CoreModel
import AgentRuntime
import DistillCore
import Persistence
@testable import AppShell

@MainActor
final class TokenSaverAppContextTests: XCTestCase {
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

        // The provider skill dirs the agents actually scan.
        let codexSkill = home.appendingPathComponent(".codex/skills/distill/SKILL.md")
        let claudeSkill = home.appendingPathComponent(".claude/skills/distill/SKILL.md")
        let configURLs = managedDistillConfigURLs(home: home)
        let cliURL = managedDistillCLIURL(home: home)
        let pathLink = managedDistillPathLinkURL(home: home)

        // Token Saver disabled (the default) must NOT leave managed /distill state on disk.
        XCTAssertEqual(context.managedDistillSkillInstallResults.count, 0,
                       "managed /distill state must only exist while Token Saver is enabled")
        context.reconcileManagedDistillSkills(tokenSaverEnabled: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexSkill.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeSkill.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURLs.codex.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURLs.claude.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cliURL.path))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: pathLink.path))

        // Enabling Token Saver installs /distill skill and config into each provider's real roots.
        context.reconcileManagedDistillSkills(tokenSaverEnabled: true)
        XCTAssertEqual(context.managedDistillSkillInstallResults.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: codexSkill.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: claudeSkill.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURLs.codex.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURLs.claude.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cliURL.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: pathLink.path), cliURL.path,
                       "enabling Token Saver must bridge the managed CLI onto PATH (~/.local/bin/distill)")

        let skillText = try String(contentsOf: claudeSkill)
        XCTAssertTrue(skillText.contains("source: https://github.com/samuelfaj/distill/blob/main/skills/distill/SKILL.md"))
        XCTAssertTrue(skillText.contains("S=state"))
        XCTAssertTrue(skillText.contains("P=proof"))
        let codexConfigText = try String(contentsOf: configURLs.codex)
        let claudeConfigText = try String(contentsOf: configURLs.claude)
        XCTAssertTrue(codexConfigText.contains("Use `/distill` for every user-visible response"))
        XCTAssertTrue(codexConfigText.contains("RemoteCode-managed `distill` CLI"))
        XCTAssertTrue(claudeConfigText.contains("RemoteCodeDistillService"))
        XCTAssertFalse(codexConfigText.contains("dev/distill/src/cli.ts"))
        // Native CLI (N1): the managed `distill` is a symlink to the RemoteCodeDistillService
        // binary (CLI mode), not a Python/TypeScript script.
        let cliDest = try FileManager.default.destinationOfSymbolicLink(atPath: cliURL.path)
        XCTAssertTrue(cliDest.hasSuffix("RemoteCodeDistillService"), "managed CLI is a native symlink, not a script")
        XCTAssertFalse(cliDest.contains("dev/distill/src/cli.ts"))

        // Disabling Token Saver removes managed skill and config again for both providers.
        context.reconcileManagedDistillSkills(tokenSaverEnabled: false)
        XCTAssertEqual(context.managedDistillSkillInstallResults.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexSkill.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeSkill.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURLs.codex.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURLs.claude.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cliURL.path))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: pathLink.path),
                     "disabling Token Saver must remove the PATH symlink too")
    }

    func test_distillInstallStatusMappingDistinguishesFailedFromOff() {
        // A reconcile failure must surface as .failed (visible), never collapse into
        // .inactive which looks identical to "Token Saver off".
        XCTAssertEqual(
            DistillInstallStatus.from(error: "no service binary", enabled: true, installedCount: 0),
            .failed("no service binary"),
            "an install failure must be visible, not swallowed as inactive")
        XCTAssertEqual(
            DistillInstallStatus.from(error: "no service binary", enabled: false, installedCount: 0),
            .failed("no service binary"),
            "a recorded error wins even if the toggle reads off")
        XCTAssertEqual(
            DistillInstallStatus.from(error: nil, enabled: true, installedCount: 2),
            .installed)
        XCTAssertEqual(
            DistillInstallStatus.from(error: nil, enabled: true, installedCount: 0),
            .inactive,
            "enabled but nothing installed yet is inactive, not a false 'installed'")
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
        XCTAssertEqual(context.managedDistillSkillInstallResults.count, 2)
        XCTAssertNil(context.managedDistillSkillInstallError,
                     "a clean install must leave no error so the UI shows installed, not failed")

        context.reconcileManagedDistillSkills(tokenSaverEnabled: false)
        XCTAssertTrue(context.managedDistillSkillInstallResults.isEmpty)
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
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
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
            "REMOTE_CODE_DISTILL_STATE_PATH": stateURL.path
        ])

        try process.run()
        stdin.fileHandleForWriting.write(Data("unit tests passed\nno failures\n".utf8))
        stdin.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, error)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "PASS",
                       "the managed distill command must return only the format requested by the agent")
        XCTAssertFalse(output.contains("PROMPT:"))
        XCTAssertFalse(output.contains("INPUT:"))
        XCTAssertFalse(error.contains("dev/distill/src/cli.ts"),
                       "the provider-visible CLI path must never hit the old TypeScript checkout")
    }

    func test_appContextLaunchInstallsManagedDistillStateWhenPersistedTokenSaverEnabled() throws {
        let appSupport = NSTemporaryDirectory() + "RC2ManagedSkillsLaunchOn-" + UUID().uuidString
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2ManagedSkillsLaunchHome-" + UUID().uuidString, isDirectory: true)
        let skillURLs = managedDistillSkillURLs(home: home)
        let configURLs = managedDistillConfigURLs(home: home)

        let seedContext = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: seedContext.db).save(AppSettings(tokenSaverEnabled: true))

        let launchedContext = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            agentSkillsHomeOverrideForTesting: home
        )

        XCTAssertEqual(launchedContext.managedDistillSkillInstallResults.count, 2,
                       "opening the app with Token Saver already enabled must install /distill before provider runs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillURLs.codex.path),
                      "Codex must see the managed /distill skill from its provider skill root on launch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillURLs.claude.path),
                      "Claude must see the managed /distill skill from its provider skill root on launch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURLs.codex.path),
                      "Codex must receive the managed AGENTS.md distill instructions on launch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURLs.claude.path),
                      "Claude must receive the managed CLAUDE.md distill instructions on launch")
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

        XCTAssertEqual(launchedContext.managedDistillSkillInstallResults.count, 0,
                       "opening the app with Token Saver disabled must not keep stale managed distill state active")
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillURLs.codex.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillURLs.claude.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURLs.codex.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURLs.claude.path))
    }

    func test_applicationWillTerminateRemovesManagedDistillState() throws {
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
        context.reconcileManagedDistillSkills(tokenSaverEnabled: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillURLs.codex.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillURLs.claude.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURLs.codex.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURLs.claude.path))

        let delegate = AppDelegate()
        delegate.context = context
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        XCTAssertFalse(FileManager.default.fileExists(atPath: skillURLs.codex.path),
                       "closing RemoteCode must remove the managed Codex /distill skill")
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillURLs.claude.path),
                       "closing RemoteCode must remove the managed Claude /distill skill")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURLs.codex.path),
                       "closing RemoteCode must remove managed Codex distill instructions")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURLs.claude.path),
                       "closing RemoteCode must remove managed Claude distill instructions")
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
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
        let ready = try await server.start()
        defer { server.stop() }
        context.distillClientOverrideForTesting = DistillServiceClient(ready: ready, authToken: "test-token")

        let bigPrompt = (1...40)
            .map { "line \($0): a verbose instruction line that the distiller will compress away" }
            .joined(separator: "\n")
        XCTAssertGreaterThan(bigPrompt.count, 2_000, "must clear the raised NetPositiveGate floor")

        // Fresh thread => no prior turn => gate treats it as COLD => compresses (N5).
        let compressed = await context.tokenSaverCompress(prompt: bigPrompt, provider: .claude, threadId: AgentThreadID())

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

    func test_tokenSaverCompressionAutoSavesForCodexNotJustClaude() async throws {
        // The "Codex Saved 0" complaint: prompt compression is provider-agnostic. The same
        // automatic compress path that records Claude savings must record Codex savings —
        // attributed to codex, engine-tagged — WITHOUT the agent voluntarily piping anything.
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverCodexAuto-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }

        let configuration = try DistillServiceConfiguration(authToken: "codex-token", appSupportDirectory: appSupport)
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 4)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
        let ready = try await server.start()
        defer { server.stop() }
        context.distillClientOverrideForTesting = DistillServiceClient(ready: ready, authToken: "codex-token")

        let bigPrompt = (1...40)
            .map { "line \($0): a verbose codex instruction line that the distiller will compress away" }
            .joined(separator: "\n")
        XCTAssertGreaterThan(bigPrompt.count, 2_000)

        let compressed = await context.tokenSaverCompress(prompt: bigPrompt, provider: .codex, threadId: AgentThreadID())
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
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler)
        let ready = try await server.start()
        defer { server.stop() }
        context.distillClientOverrideForTesting = DistillServiceClient(ready: ready, authToken: "followup-token")

        let prompt = (1...40)
            .map { "follow-up verbose prose segment \($0) with repeated diagnostic context and remediation detail" }
            .joined(separator: "\n")

        let compressed = await context.tokenSaverCompress(
            prompt: prompt,
            provider: .claude,
            threadId: AgentThreadID(),
            cacheState: "prompt_followup"
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

        let compressed = await context.tokenSaverCompress(prompt: prompt, provider: .claude, threadId: AgentThreadID())

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
        let out = await context.tokenSaverCompress(prompt: small, provider: .claude, threadId: AgentThreadID())
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

        let first = await context.tokenSaverCompress(prompt: prompt, provider: .claude, threadId: AgentThreadID())
        let second = await context.tokenSaverCompress(prompt: prompt, provider: .claude, threadId: AgentThreadID())

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

        let out = await context.tokenSaverCompress(prompt: prompt, provider: .claude, threadId: AgentThreadID())
        XCTAssertLessThan(out.count, prompt.count, "the duplicate block is collapsed even with no model service")
        XCTAssertTrue(out.contains("⟪identical to block #"), "model-readable dedup pointer present (non-lossy)")
        XCTAssertTrue(out.contains(block), "the first occurrence stays inline — no information lost")
        XCTAssertEqual(try context.tokenSaverSavingsRepo.summary().totalRuns, 1, "the dedup saving is recorded")
    }

    func test_tokenSaverNearDedupsVolatileOnlyBlocksWithCCRHandleWithoutModelService() async throws {
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

        let out = await context.tokenSaverCompress(prompt: prompt, provider: .claude, threadId: AgentThreadID())

        XCTAssertLessThan(out.count, prompt.count)
        XCTAssertTrue(out.contains("same as block #1 above except"))
        XCTAssertTrue(out.contains("pid=1234"))
        XCTAssertTrue(out.contains("pid=5678"))
        let markerRange = try XCTUnwrap(out.range(of: #"\[\[rc:[0-9a-f]+\]\]"#, options: .regularExpression))
        let marker = String(out[markerRange])
        XCTAssertEqual(try ReversibleContentStore(db: context.db).retrieveText(marker), prompt,
                       "large near-dup prompt must retain a byte-exact CCR recovery handle")
    }

    func test_tokenSaverDiffPromptUsesCCRBackedWindowWithoutModelService() async throws {
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

        let out = await context.tokenSaverCompress(prompt: prompt, provider: .claude, threadId: AgentThreadID())

        XCTAssertLessThan(out.count, prompt.count, "diff prompt re-injection should send the windowed diff, not the full patch")
        XCTAssertTrue(out.contains("-let retryLimit = 2"))
        XCTAssertTrue(out.contains("+let retryLimit = 4"))
        XCTAssertTrue(out.contains("unchanged lines"), "unchanged diff context must collapse to an explicit marker")
        let markerRange = try XCTUnwrap(out.range(of: #"\[\[rc:[0-9a-f]+\]\]"#, options: .regularExpression))
        let marker = String(out[markerRange])
        XCTAssertEqual(try ReversibleContentStore(db: context.db).retrieveText(marker), prompt,
                       "the full original prompt/diff must be recoverable byte-exact from the CCR marker")
        XCTAssertEqual(try context.tokenSaverSavingsRepo.summary().totalRuns, 1, "deterministic diff windowing savings are recorded")
    }

    func test_sessionLearnMinesFailedRunIntoRegionWhenEnabled() throws {
        let appSupport = NSTemporaryDirectory() + "RC2SessionLearn-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.sessionLearnEnabled = true }
        let learnFile = URL(fileURLWithPath: appSupport).appendingPathComponent("AGENTS.md")
        context.sessionLearnInstructionFilesOverrideForTesting = [learnFile]

        let thread = AgentThread(title: "t", provider: .codex, model: "m")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "m", status: .failed,
                           errorMessage: "build error: cannot find symbol Foo in scope")
        try context.runRepo.upsert(run)

        context.recordSessionLearnFromRun(runId: run.id, status: .failed)

        let rules = try SessionLearnRegion(fileURL: learnFile).rules()
        XCTAssertEqual(rules.count, 1, "a failed run mines exactly one correction rule")
        XCTAssertTrue(rules[0].contains("cannot find symbol Foo in scope"), "the rule captures the failure cause")
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
        SettingsStore(db: context.db).update { $0.sessionLearnEnabled = true }
        context.recordSessionLearnFromRun(runId: run.id, status: .completed)
        XCTAssertEqual(try SessionLearnRegion(fileURL: learnFile).rules().count, 0)
    }

    func test_sessionLearnUsesParsedInputTokensForExpensiveRunGate() throws {
        let appSupport = NSTemporaryDirectory() + "RC2SessionLearnTokens-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: context.db).update { $0.sessionLearnEnabled = true }
        let learnFile = URL(fileURLWithPath: appSupport).appendingPathComponent("AGENTS.md")
        context.sessionLearnInstructionFilesOverrideForTesting = [learnFile]

        let thread = AgentThread(title: "t", provider: .claude, model: "m")
        try context.threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "m",
            status: .completed,
            errorMessage: "near context limit: replayed redundant tool output"
        )
        try context.runRepo.upsert(run)

        context.coordinator.onAssistantEvent?(
            .tokenUsage(AssistantTokenUsage(inputTokens: 80_000, outputTokens: 10, totalTokens: 80_010)),
            thread.id,
            run.id
        )
        context.recordSessionLearnFromRun(runId: run.id, status: .completed)

        let rules = try SessionLearnRegion(fileURL: learnFile).rules()
        XCTAssertEqual(rules.count, 1,
                       "expensive successful runs must use parsed provider input tokens instead of the old hardcoded zero")
        XCTAssertTrue(rules[0].contains("replayed redundant tool output"))
    }

    func test_tokenSaverHumanizesSR1FinalResponseThroughDistillClientInUserLanguage() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2TokenSaverHumanizeSR1-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)

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
        XCTAssertTrue(humanized.contains("Estado: tests green"),
                      "the distill humanize request must target the user's Portuguese language even when the user types portugues without an accent")
        XCTAssertTrue(humanized.contains("Prova: macOS suite passed"))
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

        let humanized = await context.tokenSaverHumanizeSR1Response(sr1, provider: .claude, threadId: thread.id)

        XCTAssertFalse(SR1ResponseDetector.isSR1(humanized),
                       "humanized output must not still look like SR1")
        XCTAssertFalse(humanized.contains("O file:"))
        XCTAssertTrue(humanized.contains("Resultado: Snake game criado."))
        XCTAssertTrue(humanized.contains("Prova: open: abrir snake.html no browser -> jogo roda"))
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
        try context.messageRepo.append(AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "/distill crie o snage game em html"
        ))
        let sr1 = """
        Dict: S=state C=context D=action R=risk O=outcome N=no-go P=proof #g1=Snake HTML game
        S starting. D load /distill rules, inspect /tmp, then create #g1.
        """

        let humanized = await context.tokenSaverHumanizeSR1Response(sr1, provider: .codex, threadId: thread.id)

        XCTAssertFalse(humanized.contains("Dict:"),
                       "the Agent App must not display a local-LLM partial translation that still contains the SR1 dictionary")
        XCTAssertTrue(humanized.contains("Estado: starting"))
        XCTAssertFalse(humanized.contains("#g1"),
                       "SR1 variables are for provider compression only and must be expanded before the user sees the answer")
        XCTAssertTrue(humanized.contains("Acao: load /distill rules, inspect /tmp, then create Snake HTML game"))
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
        let disabled = await context.tokenSaverCompress(prompt: bigPrompt, provider: .claude, threadId: AgentThreadID())
        XCTAssertEqual(disabled, bigPrompt)
        XCTAssertEqual(try context.tokenSaverSavingsRepo.summary().totalRuns, 0)

        // Enabled but tiny prompt → below threshold, passthrough, no DB rows.
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        let tiny = await context.tokenSaverCompress(prompt: "fix typo", provider: .claude, threadId: AgentThreadID())
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
