import XCTest
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
        _ = try installer.installDistillSkill(for: .codex, sourceRevision: "rev-a")
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
        XCTAssertFalse(context.isTokenSaverRuntimeActive())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: installer.skillDirectory(provider: .codex, skillID: "distill").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: appSupport.appendingPathComponent("Distill").path),
                       "the multi-GB model folder must be deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: graph.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: usage.path), "account usage still reads usage.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: training.path), "saved training prompts are kept")
    }

    func test_tokenSaverLifecycleCannotTurnTheFeatureBackOn() throws {
        // WHY: the remaining Settings / sidebar / account callers still ask for
        // ON; the removed feature must answer OFF and persist OFF every time.
        let appSupport = tempURL("RC2LegacyTSLifecycle")
        let home = tempURL("RC2LegacyTSLifecycleHome")
        defer {
            try? FileManager.default.removeItem(at: appSupport)
            try? FileManager.default.removeItem(at: home)
        }
        let context = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport.path,
            agentSkillsHomeOverrideForTesting: home
        )
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

        let outcome = context.applyTokenSaverLifecycle(
            requestedEnabled: true,
            modelValidation: .installed,
            persistPreference: true
        )

        XCTAssertEqual(outcome, .disabled)
        XCTAssertFalse(SettingsStore(db: context.db).load().tokenSaverEnabled)
        XCTAssertFalse(context.isTokenSaverRuntimeActive())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".remote-code/bin/distill").path
        ), "asking for ON must never install the managed distill CLI")
    }
}
