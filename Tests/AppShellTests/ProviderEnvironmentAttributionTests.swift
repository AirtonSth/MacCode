import XCTest
import CoreModel
import Persistence
@testable import AppShell

/// Regression for the Token Saver savings-attribution bug: command-output savings from the
/// agent's `cmd | distill` were recorded under provider "unknown" because the agent's
/// environment lacked REMOTE_CODE_AGENT_PROVIDER. The source of every agent run's
/// environment is providerEnvironment(provider:instanceId:); it must ALWAYS tag the provider,
/// even when there is no instance config (the path that previously returned an empty env).
final class ProviderEnvironmentAttributionTests: XCTestCase {
    @MainActor
    func test_providerEnvironmentAlwaysTagsProvider_evenWithoutInstanceConfig() throws {
        let appSupport = NSTemporaryDirectory() + "RC2ProvEnv-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)

        // instanceId nil => no provider instance config => previously returned [:] => "unknown".
        XCTAssertEqual(
            router.providerEnvironment(provider: .claude, instanceId: nil)["REMOTE_CODE_AGENT_PROVIDER"],
            "claude",
            "the agent environment must tag the provider so `| distill` savings attribute to claude, not unknown"
        )
        XCTAssertEqual(
            router.providerEnvironment(provider: .codex, instanceId: nil)["REMOTE_CODE_AGENT_PROVIDER"],
            "codex"
        )
    }

    /// Codex (app-server) has no automatic tool-output compression hook, so it depends on its
    /// per-turn developer_instructions to pipe `| distill`. providerEnvironment is the carrier:
    /// it must emit RC_TOKEN_SAVER_DISTILL_HINT iff Token Saver is enabled (the managed distill
    /// CLI is installed only then). With the hint absent the agent must never be told to pipe.
    @MainActor
    func test_providerEnvironment_emitsDistillHint_onlyWhileTokenSaverEnabled() throws {
        let appSupport = NSTemporaryDirectory() + "RC2ProvEnvHint-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)

        // Default off: no hint for either provider.
        XCTAssertNil(router.providerEnvironment(provider: .codex, instanceId: nil)["RC_TOKEN_SAVER_DISTILL_HINT"])
        XCTAssertNil(router.providerEnvironment(provider: .claude, instanceId: nil)["RC_TOKEN_SAVER_DISTILL_HINT"])

        SettingsStore(db: ctx.db).update { $0.tokenSaverEnabled = true }

        XCTAssertEqual(
            router.providerEnvironment(provider: .codex, instanceId: nil)["RC_TOKEN_SAVER_DISTILL_HINT"],
            "1",
            "Codex relies on this hint to enable `| distill` in its developer_instructions when Token Saver is on"
        )
    }
}
