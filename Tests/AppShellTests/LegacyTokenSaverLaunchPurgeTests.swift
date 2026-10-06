import XCTest
import AppKit
import CoreModel
import Persistence
@testable import AgentRuntime
@testable import AppShell

/// Token Saver was removed on 2026-10-06. A machine upgraded from a build that
/// had it ON must come up with it OFF and without the leftovers, while the
/// user's other settings and kept data stay. Every path here is a temp folder.
@MainActor
final class LegacyTokenSaverLaunchPurgeTests: XCTestCase {
    private func tempURL(_ prefix: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func test_launchTurnsOffPersistedTokenSaverAndPurgesLegacyInstall() async throws {
        // WHY: a persisted ON would otherwise keep reading as ON in every
        // surface that still checks it, the stored API token is a secret for a
        // feature that no longer exists, and the multi-GB weights and provider
        // hooks would stay on disk forever.
        let appSupport = tempURL("RC2LegacyTSLaunch")
        let home = tempURL("RC2LegacyTSLaunchHome")
        defer {
            try? FileManager.default.removeItem(at: appSupport)
            try? FileManager.default.removeItem(at: home)
        }
        let seed = try AppContext(channel: .debug, appSupportOverride: appSupport.path)
        SettingsStore(db: seed.db).update {
            $0.tokenSaverEnabled = true
            $0.tokenSaverAPIToken = "sk-legacy"
            $0.terminalFontSize = 15
        }
        let installer = AgentSkillInstaller(homeDirectory: home)
        try installLegacyDistillSkill(installer, for: .codex)
        let weights = appSupport.appendingPathComponent("Distill/Models/m/rev/model.safetensors")
        let usage = appSupport.appendingPathComponent("TokenSaver/usage.json")
        let training = appSupport.appendingPathComponent("TokenSaver/training/2026-10-01.jsonl")
        let graph = appSupport.appendingPathComponent("graphify-graphs/repo/graph.json")
        for file in [weights, usage, training, graph] {
            try write("x", to: file)
        }

        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport.path,
            agentSkillsHomeOverrideForTesting: home
        )
        await context.legacyTokenSaverPurgeTask?.value

        let settings = SettingsStore(db: context.db).load()
        XCTAssertFalse(settings.tokenSaverEnabled, "a persisted ON must come up OFF")
        XCTAssertEqual(settings.tokenSaverAPIToken, "", "the removed feature's API token must not be kept")
        XCTAssertEqual(settings.terminalFontSize, 15, "unrelated settings must survive the force-off")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: installer.skillDirectory(provider: .codex, skillID: "distill").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: appSupport.appendingPathComponent("Distill").path),
                       "the multi-GB model folder must be deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: graph.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: usage.path), "account usage still reads usage.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: training.path), "saved training prompts are kept")
    }

    func test_accountChangeWithLegacyPreferenceOnNeverReinstallsTokenSaver() throws {
        // WHY: an account change used to re-admit Token Saver for a stored ON
        // preference. The removed feature must stay off: no managed distill CLI
        // and no Token Saver keys in an agent's environment.
        let appSupport = tempURL("RC2LegacyTSAccountChange")
        let home = tempURL("RC2LegacyTSAccountChangeHome")
        defer {
            try? FileManager.default.removeItem(at: appSupport)
            try? FileManager.default.removeItem(at: home)
        }
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport.path,
            agentSkillsHomeOverrideForTesting: home
        )
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        PrivateAccountSessionStore(repo: context.settingsRepo).save(PrivateAccountSession(
            accessToken: "tok",
            refreshToken: "ref",
            user: PrivateAccountUser(
                daysRemaing: nil,
                daysRemaining: 30,
                email: "paid@example.com",
                id: "paid",
                subscribed: true
            )
        ))
        NotificationCenter.default.post(name: .rc2PrivateAccountChanged, object: nil)

        let thread = AgentThread(title: "legacy", provider: .codex, model: "test")
        try context.threadRepo.upsert(thread)
        let env = AppCommandRouter(context: context)
            .providerEnvironment(provider: .codex, instanceId: nil, threadId: thread.id)
        XCTAssertNil(env["RC_TOKEN_SAVER_DISTILL_HINT"])
        XCTAssertTrue(env.keys.filter { $0.hasPrefix("RC_TOKEN_SAVER_") }.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".remote-code/bin/distill").path
        ), "an account change must never install the managed distill CLI")
    }

    /// What a Token Saver build wrote: a skill folder with RemoteCode's
    /// manifest, and the managed instruction block. Its installers are gone.
    private func installLegacyDistillSkill(_ installer: AgentSkillInstaller, for provider: AgentProvider) throws {
        _ = try installer.installSkill(
            provider: provider,
            skillID: AgentSkillInstaller.distillSkillID,
            skillText: "---\nname: distill\n---\nLegacy Token Saver skill.\n",
            sourceURL: "remote-code://token-saver/distill-tool-output",
            sourceRevision: "rev-a",
            localVersion: "10"
        )
    }

    private func installLegacyDistillInstructions(_ installer: AgentSkillInstaller, for provider: AgentProvider) throws {
        let url = installer.instructionsURL(for: provider)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let block = """
        \(AgentSkillInstaller.distillInstructionsBeginMarker)
        Always communicate with the user in `/distill` compressed language.
        \(AgentSkillInstaller.distillInstructionsEndMarker)
        """
        try Data((block + "\n").utf8).write(to: url, options: .atomic)
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

    func test_appContextLaunchRemovesManagedDistillStateWhenPersistedTokenSaverDisabled() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2ManagedSkillsLaunchOff-" + UUID().uuidString
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2ManagedSkillsLaunchOffHome-" + UUID().uuidString, isDirectory: true)
        let skillURLs = managedDistillSkillURLs(home: home)
        let configURLs = managedDistillConfigURLs(home: home)
        let installer = AgentSkillInstaller(homeDirectory: home)
        try installLegacyDistillSkill(installer, for: .codex)
        try installLegacyDistillSkill(installer, for: .claude)
        try installLegacyDistillInstructions(installer, for: .codex)
        try installLegacyDistillInstructions(installer, for: .claude)
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
        await launchedContext.legacyTokenSaverPurgeTask?.value

        // Launch with Token Saver off scrubs legacy provider-home skill copies and
        // does not install Distill economy hooks (paid feature).
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillURLs.codex.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillURLs.claude.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURLs.codex.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURLs.claude.path))
    }

    func test_applicationWillTerminatePurgesLegacyHomeAndAppPrivateDistill() async throws {
        // WHY: Token Saver was removed. Quit must finish the purge (provider-home
        // skills and the app-private Distill package) and never reinstall either.
        let appSupport = NSTemporaryDirectory() + "RC2ManagedSkillsClose-" + UUID().uuidString
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RC2ManagedSkillsCloseHome-" + UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(atPath: appSupport)
            try? FileManager.default.removeItem(at: home)
        }
        let skillURLs = managedDistillSkillURLs(home: home)
        let configURLs = managedDistillConfigURLs(home: home)
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            agentSkillsHomeOverrideForTesting: home
        )
        await context.legacyTokenSaverPurgeTask?.value
        // An older build left these behind after this launch's purge ran.
        let installer = AgentSkillInstaller(homeDirectory: home)
        try installLegacyDistillSkill(installer, for: .codex)
        try installLegacyDistillSkill(installer, for: .claude)
        let appPrivate = URL(fileURLWithPath: appSupport, isDirectory: true)
            .appendingPathComponent("AgentSkills/distill/SKILL.md")
        try FileManager.default.createDirectory(
            at: appPrivate.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(to: appPrivate)

        let delegate = AppDelegate()
        delegate.context = context
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        XCTAssertFalse(FileManager.default.fileExists(atPath: skillURLs.codex.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillURLs.claude.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURLs.codex.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURLs.claude.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: appPrivate.path),
                       "quit removes the app-private Distill package of the removed feature")
    }

}
