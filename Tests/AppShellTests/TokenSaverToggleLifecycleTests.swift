import XCTest
import AgentRuntime
import CoreModel
import Persistence
@testable import AppShell

@MainActor
final class TokenSaverToggleLifecycleTests: XCTestCase {
    private struct Fixture {
        let context: AppContext
        let home: URL
        let appSupport: URL

        var managedBin: URL {
            home.appendingPathComponent(".remote-code/bin", isDirectory: true)
        }

        var distillCLI: URL {
            managedBin.appendingPathComponent("distill")
        }

        var distillPathLink: URL {
            home.appendingPathComponent(".local/bin/distill")
        }

        var claudeSettings: URL {
            home.appendingPathComponent(".claude/settings.json")
        }

        var codexConfig: URL {
            home.appendingPathComponent(".codex/config.toml")
        }

        var agentAppMiddleware: URL {
            managedBin.appendingPathComponent("remote-code")
        }

        var shellBridge: URL {
            home.appendingPathComponent(".remote-code/shell/zsh/.zshenv")
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2TokenSaverToggle-\(UUID().uuidString)", isDirectory: true)
        let appSupport = root.appendingPathComponent("Application Support", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport.path,
            agentSkillsHomeOverrideForTesting: home
        )
        return Fixture(context: context, home: home, appSupport: appSupport)
    }

    private func saveSession(in context: AppContext, subscribed: Bool) {
        PrivateAccountSessionStore(repo: context.settingsRepo).save(.init(
            accessToken: "test-access",
            refreshToken: "test-refresh",
            user: .init(
                daysRemaing: nil,
                daysRemaining: subscribed ? 30 : 0,
                email: subscribed ? "paid@example.com" : "free@example.com",
                id: subscribed ? "paid" : "free",
                subscribed: subscribed
            )
        ))
    }

    private func fileContains(_ needle: String, at url: URL) -> Bool {
        (try? String(contentsOf: url, encoding: .utf8))?.contains(needle) == true
    }

    func test_settingsOffStopsSidecarAndRemovesPaidHooksButKeepsSubagentBridge() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.appSupport.deletingLastPathComponent()) }
        saveSession(in: fixture.context, subscribed: true)

        XCTAssertEqual(
            fixture.context.applyTokenSaverLifecycle(
                requestedEnabled: true,
                modelValidation: .installed,
                persistPreference: true
            ),
            .enabled
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.distillCLI.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.distillPathLink.path))
        XCTAssertTrue(fileContains(AgentSkillInstaller.retrieveMCPName, at: fixture.claudeSettings))
        XCTAssertTrue(fileContains(AgentSkillInstaller.retrieveMCPName, at: fixture.codexConfig))
        let wrapperURLs = WrappedCommandCatalog.commands.map {
            fixture.managedBin.appendingPathComponent($0)
        }.filter {
            (try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path)) != nil
        }
        XCTAssertFalse(wrapperURLs.isEmpty, "the fixture must exercise paid command-wrapper cleanup")

        let viewModel = SettingsViewModel(context: fixture.context)
        viewModel.setTokenSaverEnabled(false)

        XCTAssertFalse(viewModel.appSettings.tokenSaverEnabled)
        XCTAssertFalse(SettingsStore(db: fixture.context.db).load().tokenSaverEnabled)
        XCTAssertEqual(fixture.context.tokenSaverDistillServiceController.status, .notStarted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.distillCLI.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.distillPathLink.path))
        XCTAssertFalse(fileContains(AgentSkillInstaller.retrieveMCPName, at: fixture.claudeSettings))
        XCTAssertFalse(fileContains(AgentSkillInstaller.retrieveMCPName, at: fixture.codexConfig))
        for wrapper in wrapperURLs {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: wrapper.path),
                "Token Saver OFF must remove paid wrapper \(wrapper.lastPathComponent)"
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.agentAppMiddleware.path),
            "cross-provider Agent App middleware is always-on, not a paid Token Saver hook"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.shellBridge.path),
            "the always-on nested-provider shell bridge must survive Token Saver OFF"
        )
    }

    func test_settingsOnFailsClosedWithoutSubscriptionOrInstalledModel() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.appSupport.deletingLastPathComponent()) }
        let viewModel = SettingsViewModel(context: fixture.context)

        viewModel.setTokenSaverEnabled(true)
        XCTAssertFalse(viewModel.appSettings.tokenSaverEnabled)
        XCTAssertFalse(SettingsStore(db: fixture.context.db).load().tokenSaverEnabled)

        saveSession(in: fixture.context, subscribed: false)
        viewModel.reload()
        viewModel.setTokenSaverEnabled(true)
        XCTAssertFalse(viewModel.appSettings.tokenSaverEnabled)
        XCTAssertFalse(SettingsStore(db: fixture.context.db).load().tokenSaverEnabled)

        saveSession(in: fixture.context, subscribed: true)
        viewModel.reload()
        viewModel.setTokenSaverEnabled(true)
        XCTAssertFalse(
            viewModel.appSettings.tokenSaverEnabled,
            "a subscription must not bypass local model readiness"
        )
        XCTAssertFalse(SettingsStore(db: fixture.context.db).load().tokenSaverEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.distillCLI.path))
        XCTAssertEqual(fixture.context.tokenSaverDistillServiceController.status, .notStarted)
    }

    func test_legacyCleanupFailureCannotShortCircuitPaidOffCleanup() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.appSupport.deletingLastPathComponent()) }
        saveSession(in: fixture.context, subscribed: true)
        XCTAssertEqual(
            fixture.context.applyTokenSaverLifecycle(
                requestedEnabled: true,
                modelValidation: .installed,
                persistPreference: true
            ),
            .enabled
        )
        let wrapperURLs = WrappedCommandCatalog.commands.map {
            fixture.managedBin.appendingPathComponent($0)
        }.filter {
            (try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path)) != nil
        }
        fixture.context.legacyDistillCleanupOverrideForTesting = {
            throw NSError(
                domain: "TokenSaverToggleLifecycleTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "injected legacy cleanup failure"]
            )
        }

        let viewModel = SettingsViewModel(context: fixture.context)
        viewModel.setTokenSaverEnabled(false)

        XCTAssertFalse(viewModel.appSettings.tokenSaverEnabled)
        XCTAssertFalse(SettingsStore(db: fixture.context.db).load().tokenSaverEnabled)
        XCTAssertEqual(fixture.context.tokenSaverDistillServiceController.status, .notStarted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.distillCLI.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.distillPathLink.path))
        XCTAssertFalse(fileContains(AgentSkillInstaller.retrieveMCPName, at: fixture.claudeSettings))
        XCTAssertFalse(fileContains(AgentSkillInstaller.retrieveMCPName, at: fixture.codexConfig))
        XCTAssertTrue(
            wrapperURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) },
            "paid wrapper cleanup must finish before the injected legacy failure"
        )
        XCTAssertTrue(
            fixture.context.managedDistillSkillInstallError?
                .contains("injected legacy cleanup failure") == true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.agentAppMiddleware.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.shellBridge.path))
    }

    func test_sidebarOffStillCleansUpAfterSubscriptionLapses() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.appSupport.deletingLastPathComponent()) }
        saveSession(in: fixture.context, subscribed: true)
        XCTAssertEqual(
            fixture.context.applyTokenSaverLifecycle(
                requestedEnabled: true,
                modelValidation: .installed,
                persistPreference: true
            ),
            .enabled
        )
        saveSession(in: fixture.context, subscribed: false)
        let viewModel = SidebarViewModel(
            context: fixture.context,
            router: AppCommandRouter(context: fixture.context),
            tokenSaverDisableConfirmProvider: { true }
        )
        XCTAssertFalse(viewModel.privateAccountUser?.subscribed == true)
        XCTAssertTrue(viewModel.tokenSaverEnabled)

        viewModel.setTokenSaverEnabled(false)

        XCTAssertFalse(viewModel.tokenSaverEnabled)
        XCTAssertFalse(SettingsStore(db: fixture.context.db).load().tokenSaverEnabled)
        XCTAssertEqual(fixture.context.tokenSaverDistillServiceController.status, .notStarted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.distillCLI.path))
        XCTAssertFalse(fileContains(AgentSkillInstaller.retrieveMCPName, at: fixture.claudeSettings))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.agentAppMiddleware.path))
    }

    func test_accountChangeNotificationImmediatelyRevokesPaidRuntimeAfterSubscriptionLapse() async throws {
        let fixture = try makeFixture()
        defer {
            fixture.context.tokenSaverDistillServiceController.stop()
            try? FileManager.default.removeItem(at: fixture.appSupport.deletingLastPathComponent())
        }
        saveSession(in: fixture.context, subscribed: true)
        XCTAssertEqual(
            fixture.context.applyTokenSaverLifecycle(
                requestedEnabled: true,
                modelValidation: .installed,
                persistPreference: true
            ),
            .enabled
        )
        let thread = AgentThread(title: "entitlement lapse", provider: .codex, model: "test")
        try fixture.context.threadRepo.upsert(thread)
        XCTAssertTrue(fixture.context.isTokenSaverRuntimeActive())
        XCTAssertFalse(
            fixture.context.tokenSaverAgentEnvironment(
                provider: .codex,
                threadId: thread.id
            ).isEmpty
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.distillCLI.path))

        saveSession(in: fixture.context, subscribed: false)

        XCTAssertFalse(fixture.context.isTokenSaverRuntimeActive())
        XCTAssertTrue(
            fixture.context.tokenSaverAgentEnvironment(
                provider: .codex,
                threadId: thread.id
            ).isEmpty,
            "a persisted ON request must not emit paid capabilities after entitlement loss"
        )
        let wireAfterLapse = await fixture.context.tokenSaverRenderWireResponse(
            "C1:#g1=\"secret\";R:#g1",
            provider: .codex,
            threadId: thread.id
        )
        XCTAssertEqual(
            wireAfterLapse,
            "C1:#g1=\"secret\";R:#g1",
            "wire rendering is a paid mutation and must be bypassed after entitlement loss"
        )
        XCTAssertEqual(fixture.context.tokenSaverDistillServiceController.status, .notStarted)
        XCTAssertFalse(GraphifyWorkspaceService.shared.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.distillCLI.path))
        XCTAssertFalse(fileContains(AgentSkillInstaller.retrieveMCPName, at: fixture.claudeSettings))
        XCTAssertTrue(
            SettingsStore(db: fixture.context.db).load().tokenSaverEnabled,
            "entitlement loss suspends runtime without erasing the user's requested preference"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.agentAppMiddleware.path))
    }

    func test_sessionStoreClearImmediatelyRevokesPaidRuntime() throws {
        let fixture = try makeFixture()
        defer {
            fixture.context.tokenSaverDistillServiceController.stop()
            try? FileManager.default.removeItem(at: fixture.appSupport.deletingLastPathComponent())
        }
        saveSession(in: fixture.context, subscribed: true)
        XCTAssertEqual(
            fixture.context.applyTokenSaverLifecycle(
                requestedEnabled: true,
                modelValidation: .installed,
                persistPreference: true
            ),
            .enabled
        )
        XCTAssertTrue(fixture.context.isTokenSaverRuntimeActive())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.distillCLI.path))
        XCTAssertTrue(GraphifyWorkspaceService.shared.enabled)

        PrivateAccountSessionStore(repo: fixture.context.settingsRepo).clear()

        XCTAssertFalse(fixture.context.isTokenSaverRuntimeActive())
        XCTAssertEqual(fixture.context.tokenSaverDistillServiceController.status, .notStarted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.distillCLI.path))
        XCTAssertFalse(fileContains(AgentSkillInstaller.retrieveMCPName, at: fixture.claudeSettings))
        XCTAssertFalse(GraphifyWorkspaceService.shared.enabled)
        XCTAssertTrue(
            SettingsStore(db: fixture.context.db).load().tokenSaverEnabled,
            "session clear suspends paid runtime without erasing the user's requested preference"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.agentAppMiddleware.path))
    }

    func test_accountRenewalReadmitsOnlyAfterModelReadinessPasses() throws {
        let fixture = try makeFixture()
        defer {
            fixture.context.tokenSaverDistillServiceController.stop()
            try? FileManager.default.removeItem(at: fixture.appSupport.deletingLastPathComponent())
        }
        SettingsStore(db: fixture.context.db).update { $0.tokenSaverEnabled = true }
        fixture.context.tokenSaverEntitlementModelValidationOverrideForTesting = .init(
            state: .missing,
            reason: "model missing"
        )

        saveSession(in: fixture.context, subscribed: true)

        XCTAssertFalse(fixture.context.isTokenSaverRuntimeActive())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.distillCLI.path))
        XCTAssertFalse(GraphifyWorkspaceService.shared.enabled)
        XCTAssertTrue(SettingsStore(db: fixture.context.db).load().tokenSaverEnabled)

        saveSession(in: fixture.context, subscribed: false)
        fixture.context.tokenSaverEntitlementModelValidationOverrideForTesting = .installed
        saveSession(in: fixture.context, subscribed: true)

        XCTAssertTrue(fixture.context.isTokenSaverRuntimeActive())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.distillCLI.path))
        XCTAssertTrue(GraphifyWorkspaceService.shared.enabled)
        XCTAssertTrue(SettingsStore(db: fixture.context.db).load().tokenSaverEnabled)
    }

    func test_terminationDoesNotReinstallFromPersistedBoolWhenEntitlementIsUnavailable() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.appSupport.deletingLastPathComponent()) }
        // Seed the historical unsafe state directly: the preference and paid
        // hooks exist, but no private-account entitlement is available.
        SettingsStore(db: fixture.context.db).update { $0.tokenSaverEnabled = true }
        fixture.context.reconcileManagedDistillSkills(tokenSaverEnabled: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.distillCLI.path))

        let outcome = fixture.context.prepareTokenSaverLifecycleForTermination()

        guard case .blocked = outcome else {
            return XCTFail("termination must reject a persisted ON bool without entitlement")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.distillCLI.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.distillPathLink.path))
        XCTAssertFalse(fileContains(AgentSkillInstaller.retrieveMCPName, at: fixture.claudeSettings))
        XCTAssertEqual(fixture.context.tokenSaverDistillServiceController.status, .notStarted)
        XCTAssertTrue(
            SettingsStore(db: fixture.context.db).load().tokenSaverEnabled,
            "quit-time cleanup must not erase the user's persisted preference"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.agentAppMiddleware.path))
    }

    func test_bootTreatsPersistedOnAsRequestAndCleansHooksWithoutEntitlement() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.appSupport.deletingLastPathComponent()) }
        SettingsStore(db: fixture.context.db).update { $0.tokenSaverEnabled = true }
        fixture.context.reconcileManagedDistillSkills(tokenSaverEnabled: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.distillCLI.path))

        let relaunched = try AppContext(
            channel: .debug,
            appSupportOverride: fixture.appSupport.path,
            agentSkillsHomeOverrideForTesting: fixture.home
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.distillCLI.path),
            "boot must fail closed before using the persisted ON preference"
        )
        XCTAssertEqual(relaunched.tokenSaverDistillServiceController.status, .notStarted)
        XCTAssertTrue(
            SettingsStore(db: relaunched.db).load().tokenSaverEnabled,
            "boot-time entitlement failure preserves the user's requested preference"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.agentAppMiddleware.path))
    }
}
