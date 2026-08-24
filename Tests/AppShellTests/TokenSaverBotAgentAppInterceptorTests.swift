import XCTest
import CoreModel
import Persistence
@testable import AgentRuntime
@testable import DistillCore
@testable import AppShell

/// Token Saver on must admit Distill + the global PATH interceptor for every
/// provider on Agent App threads and Bot Desk sends. PostToolUse stays Claude-only.
@MainActor
final class TokenSaverBotAgentAppInterceptorTests: XCTestCase {
    private var directory: String!

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "rc-ts-bot-agent-\(UUID().uuidString)"
        UserDefaults.standard.removeObject(forKey: "bots.selectedBotID")
        UserDefaults.standard.removeObject(forKey: "bots.screen")
        UserDefaults.standard.removeObject(forKey: "bots.deskRouting")
        UserDefaults.standard.removeObject(forKey: "bots.deskThreadRouting")
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(atPath: directory)
        }
        directory = nil
    }

    func test_botDeskSendAdmitsDistillAndInterceptorForEveryProvider() async throws {
        // WHY: Bot Desk used to be proven only for Grok. Claude/Codex desk
        // turns must get the same DISTILL_HINT, managed PATH wrappers, and
        // interceptor as Agent App. Codex/Grok have no PostToolUse rewrite.
        let cases: [(AgentProvider, String)] = [
            (.claude, BotsViewModel.defaultModel(for: .claude)),
            (.codex, BotsViewModel.defaultModel(for: .codex)),
            (.grok, BotsViewModel.defaultModel(for: .grok)),
        ]
        for (provider, model) in cases {
            let context = try AppContext(channel: .debug, appSupportOverride: directory)
            SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
            context.reconcileManagedDistillSkills(tokenSaverEnabled: true)
            let router = AppCommandRouter(context: context)
            context.router = router
            let runner = ControlledBotHandoffRunner(provider: provider)
            context.coordinator.replaceProvider(provider, runner: runner)
            router.rememberProviderSnapshotsForSend([
                AgentProviderSnapshotFactory.snapshot(
                    provider: provider,
                    models: [AgentModelDescriptor(id: model, label: model, provider: provider)],
                    binaryPath: "/usr/bin/true",
                    authenticated: true,
                    id: provider.rawValue
                ),
            ])
            let vm = BotsViewModel(context: context, router: router)
            let bot = try vm.create(
                name: "Piper-\(provider.rawValue)",
                title: "Scout"
            )
            vm.openDesk(bot)
            vm.deskRouting = BotDeskRouting(
                provider: provider,
                providerInstanceID: provider.rawValue,
                model: model,
                routingMode: .manual
            )
            vm.composerText = "BOT-DISTILL-\(provider.rawValue)"
            XCTAssertTrue(vm.send(), "\(provider) desk send")
            let started = await waitUntil(timeout: 5) { !runner.requests.isEmpty }
            XCTAssertTrue(started, "\(provider) bot send must reach the provider runner")
            let request = try XCTUnwrap(runner.requests.first, "\(provider)")
            assertAdmittedInterceptorEnvironment(request.environment, provider: provider, surface: "bot-desk")
            XCTAssertTrue(
                CommandWrapPolicy.isWrapped("swift")
                    && CommandWrapPolicy.isWrapped("workspace-report"),
                "\(provider) bot must share the global interceptor"
            )
            XCTAssertEqual(
                DistillServiceLaunch.argvMode(programName: "swift", arguments: ["test"]),
                .wrap(command: "swift", arguments: ["test"]),
                "\(provider) bot PATH wrapper must dispatch wrap, not HTTP"
            )
            _ = runner.finish(runID: request.runId, status: .completed, reply: "ok")
        }
    }

    func test_blockedSidecarStillAdmitsInterceptorWhenTokenSaverIsOn() async throws {
        // WHY: demand-start during Bot Desk / Agent App compress leaves the
        // Distill controller `.blocked` when no model is installed. Token Saver
        // ON must still stamp DISTILL_HINT + managed PATH; Distill fail-opens.
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        context.reconcileManagedDistillSkills(tokenSaverEnabled: true)
        let thread = AgentThread(
            title: "blocked-sidecar",
            provider: .codex,
            model: "test",
            status: .completed
        )
        try context.threadRepo.upsert(thread)
        context.tokenSaverDistillServiceController.startIfEligible(
            session: nil,
            settings: SettingsStore(db: context.db).load(),
            modelValidation: TokenSaverModelValidation(state: .missing, reason: "manifest missing")
        )
        XCTAssertEqual(
            context.tokenSaverDistillServiceController.status.isOperationallyBlocked,
            true,
            "this regression requires the demand-start blocked state"
        )
        let env = context.tokenSaverAgentEnvironment(provider: .codex, threadId: thread.id)
        assertAdmittedInterceptorEnvironment(
            env,
            provider: .codex,
            surface: "blocked-sidecar",
            requireProviderTag: false
        )
    }

    func test_agentAppProviderEnvironmentAdmitsDistillAndInterceptorForEveryProvider() throws {
        // WHY: Agent App threads are the other surface. Admission must not
        // depend on Bot Desk send; providerEnvironment is the shared builder.
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        context.reconcileManagedDistillSkills(tokenSaverEnabled: true)

        for provider in [AgentProvider.claude, .codex, .grok] {
            let thread = AgentThread(
                projectId: ProjectID(),
                workspaceId: WorkspaceID(),
                title: "agent-app-\(provider.rawValue)",
                provider: provider,
                model: "test",
                status: .completed
            )
            try context.threadRepo.upsert(thread)
            let env = router.providerEnvironment(
                provider: provider,
                instanceId: nil,
                threadId: thread.id
            )
            assertAdmittedInterceptorEnvironment(env, provider: provider, surface: "agent-app")
        }
    }

    private func assertAdmittedInterceptorEnvironment(
        _ env: [String: String],
        provider: AgentProvider,
        surface: String,
        requireProviderTag: Bool = true
    ) {
        XCTAssertEqual(
            env["RC_TOKEN_SAVER_DISTILL_HINT"],
            "1",
            "\(surface) \(provider) Distill hint"
        )
        if requireProviderTag {
            XCTAssertEqual(env["REMOTE_CODE_AGENT_PROVIDER"], provider.rawValue, "\(surface) \(provider)")
        }
        let managed = env["RC_REMOTE_CODE_MANAGED_BIN"] ?? ""
        XCTAssertFalse(managed.isEmpty, "\(surface) \(provider) managed bin")
        let path = env["PATH"] ?? ""
        XCTAssertTrue(
            path == managed || path.hasPrefix(managed + ":") || path.contains(":" + managed + ":"),
            "\(surface) \(provider) PATH must include managed wrappers: \(path)"
        )
        XCTAssertNil(env["REMOTE_CODE_WRAP_DISABLE"], "\(surface) \(provider) must not disable wrap")
        if provider == .claude {
            XCTAssertEqual(env["RC_TOKEN_SAVER_POST_TOOL_USE"], "1", "\(surface) Claude PostToolUse")
        } else {
            XCTAssertNil(env["RC_TOKEN_SAVER_POST_TOOL_USE"], "\(surface) \(provider) no PostToolUse rewrite")
        }
        let prompt = AgentSkillInstaller.tokenSaverProviderPrompt("work", environment: env)
        XCTAssertTrue(prompt.contains("| distill"), "\(surface) \(provider) dialect")
        XCTAssertTrue(
            prompt.contains("NEVER auto-distill raw exact-output"),
            "\(surface) \(provider) exact-output still forbidden"
        )
    }

    private func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }
}
