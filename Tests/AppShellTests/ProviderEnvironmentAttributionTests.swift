import XCTest
import CoreModel
import Persistence
import AgentRuntime
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
        // The merge must also carry Claude's PostToolUse compression env end-to-end.
        XCTAssertEqual(
            router.providerEnvironment(provider: .claude, instanceId: nil)["RC_TOKEN_SAVER_POST_TOOL_USE"],
            "1",
            "Claude's SDK-bridge PostToolUse compression hook is driven by this env from providerEnvironment"
        )
    }

    /// The Token Saver env is built in ONE place (AppContext.tokenSaverAgentEnvironment) and shared
    /// by both the normal run path (providerEnvironment) and the recovered-session path (the
    /// coordinator rebuilds its own request env, bypassing providerEnvironment). Before this was
    /// shared, recovered sessions silently dropped the distill hint and stopped piping/speaking
    /// distill on resume even with Token Saver on. Codex must get the distill hint only; Claude
    /// additionally gets the PostToolUse compression vars.
    @MainActor
    func test_tokenSaverAgentEnvironment_isSharedAndProviderScoped() throws {
        let appSupport = NSTemporaryDirectory() + "RC2TSEnv-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)

        // Off: empty for both providers (managed distill CLI is uninstalled).
        XCTAssertTrue(ctx.tokenSaverAgentEnvironment(provider: .codex).isEmpty)
        XCTAssertTrue(ctx.tokenSaverAgentEnvironment(provider: .claude).isEmpty)

        SettingsStore(db: ctx.db).update { $0.tokenSaverEnabled = true }

        let codex = ctx.tokenSaverAgentEnvironment(provider: .codex)
        XCTAssertEqual(codex["RC_TOKEN_SAVER_DISTILL_HINT"], "1")
        XCTAssertNil(codex["RC_TOKEN_SAVER_POST_TOOL_USE"],
                     "PostToolUse auto-compression is Claude-SDK-only; Codex must not carry it")

        let claude = ctx.tokenSaverAgentEnvironment(provider: .claude)
        XCTAssertEqual(claude["RC_TOKEN_SAVER_DISTILL_HINT"], "1")
        XCTAssertEqual(claude["RC_TOKEN_SAVER_POST_TOOL_USE"], "1")
        XCTAssertNotNil(claude["REMOTE_CODE_DISTILL_STATE_PATH"])
    }

    /// Transparent command wrappers only help Codex/Claude provider shells if the managed bin
    /// directory wins PATH lookup inside the provider process. The user's interactive shell may
    /// still resolve Homebrew `rg`; providerEnvironment must make the provider shell resolve
    /// `~/.remote-code/bin/rg` first when Token Saver is enabled.
    @MainActor
    func test_providerEnvironmentPrependsManagedWrapperBinToProviderPathWhenTokenSaverEnabled() throws {
        let appSupport = NSTemporaryDirectory() + "RC2TSEnvPath-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        SettingsStore(db: ctx.db).update { $0.tokenSaverEnabled = true }

        let managedBin = AgentSkillInstaller.defaultManagedCLIBinDirectory().path
        let codexPath = try XCTUnwrap(router.providerEnvironment(provider: .codex, instanceId: nil)["PATH"])
        let claudePath = try XCTUnwrap(router.providerEnvironment(provider: .claude, instanceId: nil)["PATH"])

        XCTAssertTrue(codexPath.hasPrefix(managedBin + ":"), "Codex provider shell must resolve wrapped commands through managed bin first")
        XCTAssertTrue(claudePath.hasPrefix(managedBin + ":"), "Claude provider shell must resolve wrapped commands through managed bin first")
    }
}
