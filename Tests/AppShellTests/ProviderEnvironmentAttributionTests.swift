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

    /// Token economy is paid: with Token Saver off, no distill hint / PostToolUse.
    /// With Token Saver on, every provider gets the distill hint; Claude also gets PostToolUse.
    @MainActor
    func test_providerEnvironment_emitsDistillHintOnlyWhenTokenSaverEnabled() throws {
        let appSupport = NSTemporaryDirectory() + "RC2ProvEnvHint-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        let codexThread = try admittedThread(in: ctx, provider: .codex)
        let claudeThread = try admittedThread(in: ctx, provider: .claude)
        let grokThread = try admittedThread(in: ctx, provider: .grok)

        ctx.reconcileManagedDistillSkills(tokenSaverEnabled: false)
        XCTAssertNil(
            router.providerEnvironment(provider: .codex, instanceId: nil, threadId: codexThread.id)["RC_TOKEN_SAVER_DISTILL_HINT"]
        )
        XCTAssertNil(
            router.providerEnvironment(provider: .claude, instanceId: nil, threadId: claudeThread.id)["RC_TOKEN_SAVER_POST_TOOL_USE"]
        )

        SettingsStore(db: ctx.db).update { $0.tokenSaverEnabled = true }
        ctx.reconcileManagedDistillSkills(tokenSaverEnabled: true)

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
            "Claude's PostToolUse compression hook is Token Saver only"
        )
    }

    @MainActor
    func test_providerEnvironment_alwaysCarriesSubagentTelemetryScope_withoutTokenSaverLanes() throws {
        // WHY: Subagents activity is user-visible even when Token Saver is off;
        // telemetry must remain scoped without accidentally enabling compression.
        let appSupport = NSTemporaryDirectory() + "RC2SubagentTelemetryEnv-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)

        for provider in AgentProvider.allCases {
            let thread = try admittedThread(in: ctx, provider: provider)
            let environment = router.providerEnvironment(
                provider: provider,
                instanceId: nil,
                threadId: thread.id
            )
            XCTAssertEqual(environment["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"], appSupport)
            XCTAssertEqual(environment["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"], thread.id.value.uuidString)
            XCTAssertEqual(environment["REMOTE_CODE_AGENT_PROVIDER"], provider.rawValue)
            XCTAssertEqual(environment["REMOTE_CODE_AGENT_MODEL"], thread.model)
            XCTAssertNil(environment["RC_TOKEN_SAVER_DISTILL_HINT"])
            XCTAssertNil(environment["RC_TOKEN_SAVER_POST_TOOL_USE"])
        }
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

        // Token Saver off → no token-economy env.
        let codexOff = ctx.tokenSaverAgentEnvironment(provider: .codex, threadId: codexThread.id)
        XCTAssertTrue(codexOff.isEmpty, "Token Saver off must not emit distill/hint env")
        XCTAssertNil(codexOff["RC_TOKEN_SAVER_POST_TOOL_USE"])

        SettingsStore(db: ctx.db).update { $0.tokenSaverEnabled = true }
        ctx.reconcileManagedDistillSkills(tokenSaverEnabled: true)

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

    /// WHY: production threads are often projectless (project_id nil). Previously
    /// recovery headers required full project admission, so PATH distill never got
    /// scope and store-before-loss forced every compression to verbatim.
    @MainActor
    func test_tokenSaverAgentEnvironment_injectsWorkspaceFallbackScopeForProjectlessThread() throws {
        let appSupport = NSTemporaryDirectory() + "RC2TSEnvProjectless-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: ctx.db).update { $0.tokenSaverEnabled = true }
        ctx.reconcileManagedDistillSkills(tokenSaverEnabled: true)
        let workspaceID = WorkspaceID()
        let thread = AgentThread(
            projectId: nil,
            workspaceId: workspaceID,
            title: "projectless",
            provider: .codex,
            model: "test",
            status: .completed
        )
        try ctx.threadRepo.upsert(thread)

        let env = ctx.tokenSaverAgentEnvironment(provider: .codex, threadId: thread.id)
        XCTAssertEqual(env["RC_TOKEN_SAVER_DISTILL_HINT"], "1")
        XCTAssertEqual(env["RC_TOKEN_SAVER_WORKSPACE_ID"], workspaceID.value.uuidString)
        XCTAssertEqual(
            env["RC_TOKEN_SAVER_PROJECT_ID"],
            workspaceID.value.uuidString,
            "projectless threads must use workspace id as recovery project key"
        )
        XCTAssertEqual(env["RC_TOKEN_SAVER_THREAD_ID"], thread.id.value.uuidString)
    }

    /// Transparent command wrappers only help Codex/Claude provider shells if the managed bin
    /// directory wins PATH lookup inside the provider process. With Token Saver on,
    /// providerEnvironment prepends managed bin so `| distill` and wrappers resolve.
    @MainActor
    func test_providerEnvironmentPrependsManagedWrapperBinToProviderPath() throws {
        let appSupport = NSTemporaryDirectory() + "RC2TSEnvPath-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        SettingsStore(db: ctx.db).update { $0.tokenSaverEnabled = true }
        ctx.reconcileManagedDistillSkills(tokenSaverEnabled: true)
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
