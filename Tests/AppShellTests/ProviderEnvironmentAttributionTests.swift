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
    private func admittedThread(in context: AppContext, provider: AgentProvider) throws -> AgentThread {
        let thread = AgentThread(
            projectId: ProjectID(), workspaceId: WorkspaceID(), title: "scoped",
            provider: provider, model: "test", status: .completed
        )
        try context.threadRepo.upsert(thread)
        try context.tokenSaverLaneStateRepo.upsert(.init(
            projectID: thread.projectId!.value.uuidString,
            lane: "deterministic_wrapper",
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
            scorecardID: "test-scorecard"
        ))
        return thread
    }

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

    /// Distill is always-on for every provider call (app-private managed skill).
    /// providerEnvironment must always carry the distill hint and Claude PostToolUse.
    @MainActor
    func test_providerEnvironment_alwaysEmitsDistillHintForAllProviders() throws {
        let appSupport = NSTemporaryDirectory() + "RC2ProvEnvHint-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        // Ensure managed distill reconcile succeeded so the hint is emitted.
        ctx.reconcileManagedDistillSkills(tokenSaverEnabled: false)
        let router = AppCommandRouter(context: ctx)
        let codexThread = try admittedThread(in: ctx, provider: .codex)
        let claudeThread = try admittedThread(in: ctx, provider: .claude)
        let grokThread = try admittedThread(in: ctx, provider: .grok)

        XCTAssertEqual(
            router.providerEnvironment(provider: .codex, instanceId: nil, threadId: codexThread.id)["RC_TOKEN_SAVER_DISTILL_HINT"],
            "1"
        )
        XCTAssertEqual(
            router.providerEnvironment(provider: .claude, instanceId: nil, threadId: claudeThread.id)["RC_TOKEN_SAVER_DISTILL_HINT"],
            "1"
        )
        XCTAssertEqual(
            router.providerEnvironment(provider: .grok, instanceId: nil, threadId: grokThread.id)["RC_TOKEN_SAVER_DISTILL_HINT"],
            "1"
        )
        XCTAssertEqual(
            router.providerEnvironment(provider: .claude, instanceId: nil, threadId: claudeThread.id)["RC_TOKEN_SAVER_POST_TOOL_USE"],
            "1",
            "Claude's PostToolUse compression hook is always on with managed Distill"
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
        let codexThread = try admittedThread(in: ctx, provider: .codex)
        let claudeThread = try admittedThread(in: ctx, provider: .claude)

        ctx.reconcileManagedDistillSkills(tokenSaverEnabled: false)

        // Always-on Distill for every provider, even with Token Saver toggle off.
        let codexOff = ctx.tokenSaverAgentEnvironment(provider: .codex, threadId: codexThread.id)
        XCTAssertEqual(codexOff["RC_TOKEN_SAVER_DISTILL_HINT"], "1")
        XCTAssertNil(codexOff["RC_TOKEN_SAVER_POST_TOOL_USE"],
                     "PostToolUse auto-compression is Claude-SDK-only; Codex must not carry it")

        SettingsStore(db: ctx.db).update { $0.tokenSaverEnabled = true }

        let codex = ctx.tokenSaverAgentEnvironment(provider: .codex, threadId: codexThread.id)
        XCTAssertEqual(codex["RC_TOKEN_SAVER_DISTILL_HINT"], "1")
        XCTAssertEqual(codex["RC_TOKEN_SAVER_WORKSPACE_ID"], codexThread.workspaceId?.value.uuidString)
        XCTAssertEqual(codex["RC_TOKEN_SAVER_PROJECT_ID"], codexThread.projectId?.value.uuidString)
        XCTAssertEqual(codex["RC_TOKEN_SAVER_THREAD_ID"], codexThread.id.value.uuidString)
        XCTAssertNil(codex["RC_TOKEN_SAVER_ATTEMPT_ID"], "the coordinator binds a fresh attempt per run")
        XCTAssertNil(codex["RC_TOKEN_SAVER_POST_TOOL_USE"],
                     "PostToolUse auto-compression is Claude-SDK-only; Codex must not carry it")

        let claude = ctx.tokenSaverAgentEnvironment(provider: .claude, threadId: claudeThread.id)
        XCTAssertEqual(claude["RC_TOKEN_SAVER_DISTILL_HINT"], "1")
        XCTAssertEqual(claude["RC_TOKEN_SAVER_POST_TOOL_USE"], "1")
        XCTAssertNotNil(claude["REMOTE_CODE_DISTILL_STATE_PATH"])
    }

    /// Transparent command wrappers only help Codex/Claude provider shells if the managed bin
    /// directory wins PATH lookup inside the provider process. providerEnvironment always
    /// prepends managed bin so `| distill` and wrappers resolve for every provider call.
    @MainActor
    func test_providerEnvironmentPrependsManagedWrapperBinToProviderPath() throws {
        let appSupport = NSTemporaryDirectory() + "RC2TSEnvPath-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        let codexThread = try admittedThread(in: ctx, provider: .codex)
        let claudeThread = try admittedThread(in: ctx, provider: .claude)

        let managedBin = AgentSkillInstaller.defaultManagedCLIBinDirectory().path
        let codexPath = try XCTUnwrap(router.providerEnvironment(provider: .codex, instanceId: nil, threadId: codexThread.id)["PATH"])
        let claudePath = try XCTUnwrap(router.providerEnvironment(provider: .claude, instanceId: nil, threadId: claudeThread.id)["PATH"])

        XCTAssertTrue(codexPath.hasPrefix(managedBin + ":"), "Codex provider shell must resolve wrapped commands through managed bin first")
        XCTAssertTrue(claudePath.hasPrefix(managedBin + ":"), "Claude provider shell must resolve wrapped commands through managed bin first")
    }
}
