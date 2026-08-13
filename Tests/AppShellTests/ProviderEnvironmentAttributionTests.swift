import XCTest
import CoreModel
import Persistence
@testable import AgentRuntime
import SocketServer
@testable import AppShell

/// Regression for the Token Saver savings-attribution bug: command-output savings from the
/// agent's `cmd | distill` were recorded under provider "unknown" because the agent's
/// environment lacked REMOTE_CODE_AGENT_PROVIDER. The source of every agent run's
/// environment is providerEnvironment(provider:instanceId:); it must ALWAYS tag the provider,
/// even when there is no instance config (the path that previously returned an empty env).
final class ProviderEnvironmentAttributionTests: XCTestCase {
    private func managedIntegrationHome(for appSupport: String) -> URL {
        URL(fileURLWithPath: appSupport, isDirectory: true)
            .appendingPathComponent("ManagedIntegrationHome", isDirectory: true)
    }

    @MainActor
    private func makeContext(appSupport: String) throws -> AppContext {
        try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            agentSkillsHomeOverrideForTesting: managedIntegrationHome(for: appSupport)
        )
    }

    @MainActor
    private func enableTokenSaver(in context: AppContext) throws {
        context.tokenSaverEntitlementModelValidationOverrideForTesting = .installed
        PrivateAccountSessionStore(repo: context.settingsRepo).save(.init(
            accessToken: "test-access",
            refreshToken: "test-refresh",
            user: .init(
                daysRemaing: nil,
                daysRemaining: 30,
                email: "paid@example.com",
                id: "paid",
                subscribed: true
            )
        ))
        XCTAssertEqual(
            context.applyTokenSaverLifecycle(
                requestedEnabled: true,
                modelValidation: .installed,
                persistPreference: true
            ),
            .enabled
        )
        // These are provider-environment tests, not sidecar-launch tests. Keep
        // the admitted runtime bit while returning the controller to XCTest's
        // explicit notStarted-as-ready seam.
        context.tokenSaverDistillServiceController.stop()
    }

    @MainActor
    func test_fixtureManagedIntegrationNeverUsesTheDeveloperHome() throws {
        // WHY: direct reconcile calls used to install/uninstall the developer's
        // real ~/.remote-code/bin during this test class. Every fixture must keep
        // that destructive surface below its disposable app-support directory.
        let appSupport = NSTemporaryDirectory() + "RC2ProvEnvIsolation-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let context = try makeContext(appSupport: appSupport)

        XCTAssertEqual(
            context.agentSkillsHomeOverrideForTesting,
            managedIntegrationHome(for: appSupport)
        )
        XCTAssertNotEqual(
            context.agentSkillsHomeOverrideForTesting?.standardizedFileURL,
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        )
    }

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
    func test_autoAndNestedWorkerEnvironmentsCarryFullTokenSaverTechniqueSurface() async throws {
        // WHY: product rule — every Auto/orchestrate controller and every
        // orchestrated worker must receive the full Token Saver technique set
        // (receipt, DISTILL_HINT, managed PATH, Distill state for Claude,
        // Subagents lifecycle). providerEnvironment is the building block for
        // the Auto send base and completeOrchestratedWorkerEnvironment; if it
        // drops any of these keys, workers inherit a thinned host surface.
        let appSupport = NSTemporaryDirectory() + "RC2AutoWorkerTS-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let context = try makeContext(appSupport: appSupport)
        let router = AppCommandRouter(context: context)
        let workspace = try router.createWorkspace(name: "auto-ts", cwd: NSTemporaryDirectory())
        try enableTokenSaver(in: context)

        for provider in [AgentProvider.claude, .codex, .grok] {
            let thread = try admittedThread(in: context, provider: provider)
            // Prefer workspace binding so providerEnvironment scopes recovery.
            var bound = thread
            bound.workspaceId = workspace.id
            try context.threadRepo.upsert(bound)

            let env = router.providerEnvironment(
                provider: provider,
                instanceId: bound.providerInstanceId,
                threadId: bound.id
            )
            XCTAssertEqual(
                env["RC_TOKEN_SAVER_DISTILL_HINT"], "1",
                "\(provider) primary/Auto controller must admit distill"
            )
            XCTAssertNotNil(
                env[TokenSaverExecutionReceipt.envKey],
                "\(provider) must carry execution receipt for nested inheritance"
            )
            XCTAssertEqual(env["REMOTE_CODE_AGENT_PROVIDER"], provider.rawValue)
            XCTAssertEqual(
                env["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"],
                bound.id.value.uuidString,
                "\(provider) Subagents lifecycle scope"
            )
            let path = env["PATH"] ?? ""
            let managed = env["RC_REMOTE_CODE_MANAGED_BIN"] ?? ""
            let zdotdir = env["ZDOTDIR"] ?? ""
            XCTAssertFalse(managed.isEmpty, "\(provider) managed bin")
            XCTAssertTrue(
                managed.contains("/.remote-code/runtime/") && managed.hasSuffix("/bin"),
                "\(provider) must use its bundle artifact runtime bin: \(managed)"
            )
            XCTAssertTrue(
                zdotdir.contains("/.remote-code/runtime/")
                    && zdotdir.hasSuffix("/shell/zsh-tool-v1"),
                "\(provider) must use its bundle artifact shell bridge: \(zdotdir)"
            )
            XCTAssertEqual(env["RC_REMOTE_CODE_MANAGED_ZDOTDIR"], zdotdir)
            XCTAssertTrue(
                path.hasPrefix(managed + ":") || path == managed,
                "\(provider) PATH must front managed wrappers for | distill / proxies: \(path)"
            )
            if provider == .claude {
                XCTAssertEqual(env["RC_TOKEN_SAVER_POST_TOOL_USE"], "1")
                XCTAssertNotNil(env["REMOTE_CODE_DISTILL_STATE_PATH"])
            }
            let dialect = AgentSkillInstaller.tokenSaverProviderPrompt(
                "orchestrate work",
                environment: env
            )
            XCTAssertTrue(
                dialect.contains("| distill"),
                "\(provider) dialect must require | distill when admitted"
            )
        }
    }

    @MainActor
    func test_nestedAgentAppInheritsProjectScopeAndTokenSaverAdmission() async throws {
        // WHY: a cross-provider child must keep the host-validated project
        // scope of its active parent; otherwise the same Token Saver lanes that
        // protect the main Agent App silently turn off for the subagent.
        let appSupport = NSTemporaryDirectory() + "RC2NestedProject-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let context = try makeContext(appSupport: appSupport)
        let router = AppCommandRouter(context: context)
        let workspace = try router.createWorkspace(name: "nested", cwd: NSTemporaryDirectory())
        let projectID = ProjectID()
        let parentThread = AgentThread(
            projectId: projectID,
            workspaceId: workspace.id,
            title: "parent",
            provider: .codex,
            model: "gpt",
            permissionMode: .fullAccess
        )
        try context.threadRepo.upsert(parentThread)
        try context.tokenSaverLaneStateRepo.upsert(.init(
            projectID: projectID.value.uuidString,
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
            scorecardID: "nested-project"
        ))
        let parentRunID = AgentRunID()
        let parentCapability = AgentDelegationCapability.issue()
        _ = try context.orchestrationRuntime.recordExternalRoot(
            runId: parentRunID,
            threadId: parentThread.id,
            provider: .codex,
            providerInstanceId: "codex",
            model: "gpt",
            permissionMode: .fullAccess,
            delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(
                parentCapability
            )
        )
        try enableTokenSaver(in: context)

        let child = try await router.createAgentThreadRouting(
            workspace: workspace.id,
            title: "child",
            provider: .grok,
            model: "grok",
            permissionMode: .supervised,
            reasoningEffort: .high,
            serviceTier: .auto,
            modelSelection: nil,
            providerInstanceId: nil,
            runAsUser: nil,
            surfaceID: nil,
            routing: nil,
            nestedRunContext: AgentNestedRunContext(
                parentRunID: parentRunID,
                parentThreadID: parentThread.id,
                nodeID: "nested.grok.project",
                parentCapability: parentCapability
            )
        )

        XCTAssertEqual(child.projectId, projectID)
        XCTAssertEqual(child.workspaceId, parentThread.workspaceId)
        XCTAssertEqual(child.runAsUser, parentThread.runAsUser)
        XCTAssertEqual(child.executionMode, parentThread.executionMode)
        XCTAssertEqual(
            router.providerEnvironment(
                provider: .grok,
                instanceId: child.providerInstanceId,
                threadId: child.id
            )["RC_TOKEN_SAVER_DISTILL_HINT"],
            "1"
        )
    }

    @MainActor
    func test_nestedAgentAppRejectsForeignRunAsParentBeforePersistingChildThread() async throws {
        // WHY: the Agent App middleware returns through an owner-only local IPC
        // socket. Persisting a foreign run-as child would claim an execution
        // identity that the host cannot actually launch or reconnect.
        let appSupport = NSTemporaryDirectory() + "RC2NestedForeignUser-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let context = try makeContext(appSupport: appSupport)
        let router = AppCommandRouter(context: context)
        let workspace = try router.createWorkspace(name: "nested-foreign", cwd: NSTemporaryDirectory())
        let foreignUser = AgentRunAsUser(
            generatedUID: "foreign-user",
            shortName: "foreign-user",
            uid: getuid() &+ 1,
            gid: getgid(),
            homePath: "/Users/foreign-user"
        )
        let parentThread = AgentThread(
            workspaceId: workspace.id,
            title: "foreign parent",
            provider: .codex,
            model: "gpt",
            permissionMode: .fullAccess,
            runAsUser: foreignUser
        )
        try context.threadRepo.upsert(parentThread)
        let parentRunID = AgentRunID()
        let parentCapability = AgentDelegationCapability.issue()
        _ = try context.orchestrationRuntime.recordExternalRoot(
            runId: parentRunID,
            threadId: parentThread.id,
            provider: .codex,
            providerInstanceId: "codex",
            model: "gpt",
            permissionMode: .fullAccess,
            delegationCapabilitySHA256: AgentDelegationCapability.sha256Hex(
                parentCapability
            )
        )

        do {
            _ = try await router.createAgentThreadRouting(
                workspace: workspace.id,
                title: "must not persist",
                provider: .grok,
                model: "grok-4.5",
                permissionMode: .supervised,
                reasoningEffort: .high,
                serviceTier: .auto,
                modelSelection: nil,
                providerInstanceId: nil,
                runAsUser: nil,
                surfaceID: nil,
                routing: nil,
                nestedRunContext: AgentNestedRunContext(
                    parentRunID: parentRunID,
                    parentThreadID: parentThread.id,
                    nodeID: "nested.grok.foreign",
                    parentCapability: parentCapability
                )
            )
            XCTFail("foreign-user parent must fail before child persistence")
        } catch let error as JSONRPCError {
            XCTAssertEqual(error.code, -32020)
            XCTAssertEqual(
                error.message,
                "Nested Agent App cannot cross the host IPC user boundary."
            )
        }

        let persisted = try context.threadRepo.list(workspaceId: workspace.id)
        XCTAssertEqual(persisted.map(\.id), [parentThread.id])
    }

    @MainActor
    func test_providerEnvironmentAlwaysTagsProvider_evenWithoutInstanceConfig() throws {
        let appSupport = NSTemporaryDirectory() + "RC2ProvEnv-" + UUID().uuidString
        let ctx = try makeContext(appSupport: appSupport)
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
        let ctx = try makeContext(appSupport: appSupport)
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

        try enableTokenSaver(in: ctx)

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
        let ctx = try makeContext(appSupport: appSupport)
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
        let ctx = try makeContext(appSupport: appSupport)
        let codexThread = try admittedThread(in: ctx, provider: .codex)
        let claudeThread = try admittedThread(in: ctx, provider: .claude)

        ctx.reconcileManagedDistillSkills(tokenSaverEnabled: false)

        // Token Saver off → no token-economy env.
        let codexOff = ctx.tokenSaverAgentEnvironment(provider: .codex, threadId: codexThread.id)
        XCTAssertTrue(codexOff.isEmpty, "Token Saver off must not emit distill/hint env")
        XCTAssertNil(codexOff["RC_TOKEN_SAVER_POST_TOOL_USE"])

        try enableTokenSaver(in: ctx)

        let codex = ctx.tokenSaverAgentEnvironment(provider: .codex, threadId: codexThread.id)
        XCTAssertEqual(codex["RC_TOKEN_SAVER_DISTILL_HINT"], "1")
        XCTAssertEqual(codex["RC_TOKEN_SAVER_WORKSPACE_ID"], codexThread.workspaceId?.value.uuidString)
        XCTAssertEqual(codex["RC_TOKEN_SAVER_PROJECT_ID"], codexThread.projectId?.value.uuidString)
        XCTAssertEqual(codex["RC_TOKEN_SAVER_THREAD_ID"], codexThread.id.value.uuidString)
        XCTAssertNil(codex["RC_TOKEN_SAVER_ATTEMPT_ID"], "the coordinator binds a fresh attempt per run")
        XCTAssertNil(codex["RC_TOKEN_SAVER_POST_TOOL_USE"],
                     "PostToolUse auto-compression is Claude-SDK-only; Codex must not carry it")
        XCTAssertEqual(codex["RC_TOKEN_SAVER_TOOL_SHELL_INTERCEPT"], "1")
        XCTAssertEqual(
            codex[AgentSkillInstaller.toolShellProtocolEnvironmentKey],
            AgentSkillInstaller.toolShellProtocolVersion
        )
        let toolShellBinary = try XCTUnwrap(
            codex[AgentSkillInstaller.toolShellBinaryEnvironmentKey]
        )
        XCTAssertEqual(
            URL(fileURLWithPath: toolShellBinary).lastPathComponent,
            "RemoteCodeDistillService"
        )
        XCTAssertNotEqual(
            toolShellBinary,
            AgentSkillInstaller.defaultManagedCLIBinDirectory()
                .appendingPathComponent("distill").path,
            "the aggregate intercept must not execute the mutable managed symlink"
        )

        let claude = ctx.tokenSaverAgentEnvironment(provider: .claude, threadId: claudeThread.id)
        XCTAssertEqual(claude["RC_TOKEN_SAVER_DISTILL_HINT"], "1")
        XCTAssertEqual(claude["RC_TOKEN_SAVER_POST_TOOL_USE"], "1")
        XCTAssertNil(claude["RC_TOKEN_SAVER_TOOL_SHELL_INTERCEPT"])
        XCTAssertNil(claude[AgentSkillInstaller.toolShellBinaryEnvironmentKey])
        XCTAssertNotNil(claude["REMOTE_CODE_DISTILL_STATE_PATH"])
        for (provider, environment) in [("codex", codex), ("claude", claude)] {
            XCTAssertTrue(
                environment["RC_REMOTE_CODE_MANAGED_BIN"]?.contains(
                    "/.remote-code/runtime/"
                ) == true,
                "\(provider) explicit | distill must use the artifact runtime bin"
            )
            XCTAssertTrue(
                environment["ZDOTDIR"]?.hasSuffix("/shell/zsh-tool-v1") == true,
                "\(provider) must use the artifact runtime bridge"
            )
        }
    }

    /// WHY: production threads are often projectless (project_id nil). Previously
    /// recovery headers required full project admission, so PATH distill never got
    /// scope and store-before-loss forced every compression to verbatim.
    @MainActor
    func test_tokenSaverAgentEnvironment_injectsWorkspaceFallbackScopeForProjectlessThread() throws {
        let appSupport = NSTemporaryDirectory() + "RC2TSEnvProjectless-" + UUID().uuidString
        let ctx = try makeContext(appSupport: appSupport)
        try enableTokenSaver(in: ctx)
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
        let ctx = try makeContext(appSupport: appSupport)
        try enableTokenSaver(in: ctx)
        let router = AppCommandRouter(context: ctx)
        let codexThread = try admittedThread(in: ctx, provider: .codex)
        let claudeThread = try admittedThread(in: ctx, provider: .claude)

        for (provider, thread) in [(AgentProvider.codex, codexThread), (.claude, claudeThread)] {
            let environment = router.providerEnvironment(
                provider: provider,
                instanceId: nil,
                threadId: thread.id
            )
            let managedBin = try XCTUnwrap(environment["RC_REMOTE_CODE_MANAGED_BIN"])
            let path = try XCTUnwrap(environment["PATH"])
            XCTAssertTrue(managedBin.contains("/.remote-code/runtime/"), "\(provider)")
            XCTAssertTrue(
                path.hasPrefix(managedBin + ":") || path == managedBin,
                "\(provider) provider shell must resolve its artifact-scoped wrappers first"
            )
            XCTAssertEqual(
                environment["RC_REMOTE_CODE_PROVIDER_PROXY_BIN"],
                managedBin,
                "\(provider) admitted proxies must resolve from the same artifact namespace"
            )
            let globalProxyBin = AgentSkillInstaller(homeDirectory: managedIntegrationHome(for: appSupport))
                .providerProxyBinURL.path
            XCTAssertFalse(
                path.split(separator: ":").map(String.init).contains(globalProxyBin),
                "\(provider) admitted PATH must not fall back to mutable global proxies"
            )
        }
    }

    @MainActor
    func test_admittedProviderEnvironmentRepairsMissingArtifactWrapperBeforeAcceptance() throws {
        // WHY: an accepted Distill symlink is insufficient when a concurrent
        // reconcile removed an ordinary wrapper; the next provider turn must
        // restore the pinned interceptor before exposing managed PATH.
        let appSupport = NSTemporaryDirectory() + "RC2WrapperRepair-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let context = try makeContext(appSupport: appSupport)
        try enableTokenSaver(in: context)
        let thread = try admittedThread(in: context, provider: .codex)
        let router = AppCommandRouter(context: context)

        let first = router.providerEnvironment(
            provider: .codex,
            instanceId: nil,
            threadId: thread.id
        )
        let managedBin = try XCTUnwrap(first["RC_REMOTE_CODE_MANAGED_BIN"])
        let wrapper = URL(fileURLWithPath: managedBin).appendingPathComponent("ls")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wrapper.path))
        try FileManager.default.removeItem(at: wrapper)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wrapper.path))

        let repaired = router.providerEnvironment(
            provider: .codex,
            instanceId: nil,
            threadId: thread.id
        )
        XCTAssertEqual(repaired["RC_REMOTE_CODE_MANAGED_BIN"], managedBin)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wrapper.path))
        let destination = try XCTUnwrap(
            FileManager.default.destinationOfSymbolicLink(atPath: wrapper.path)
        )
        let expected = URL(fileURLWithPath: managedBin)
            .deletingLastPathComponent()
            .appendingPathComponent("RemoteCodeDistillService")
            .standardizedFileURL.path
        XCTAssertEqual(
            URL(fileURLWithPath: destination).standardizedFileURL.path,
            expected,
            "ordinary wrapper must be repaired to the accepted artifact service"
        )
    }

    @MainActor
    func test_admittedProviderEnvironmentRejectsForeignOrdinaryWrapper() throws {
        // WHY: a user-owned real file in the discovered wrapper set is a
        // partial runtime, not a successful install. Paid PATH/ZDOTDIR must
        // fail open instead of accepting the installer's short return list.
        let appSupport = NSTemporaryDirectory() + "RC2WrapperCollision-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let context = try makeContext(appSupport: appSupport)
        try enableTokenSaver(in: context)
        let thread = try admittedThread(in: context, provider: .codex)
        let router = AppCommandRouter(context: context)

        let first = router.providerEnvironment(
            provider: .codex,
            instanceId: nil,
            threadId: thread.id
        )
        let runtimeBin = try XCTUnwrap(first["RC_REMOTE_CODE_MANAGED_BIN"])
        let ls = URL(fileURLWithPath: runtimeBin).appendingPathComponent("ls")
        try FileManager.default.removeItem(at: ls)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: ls)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ls.path)

        let rejected = router.providerEnvironment(
            provider: .codex,
            instanceId: nil,
            threadId: thread.id
        )
        XCTAssertNil(rejected[AgentSkillInstaller.runtimeRootEnvironmentKey])
        XCTAssertFalse(rejected["PATH"]?.contains("/.remote-code/runtime/") == true)
        XCTAssertFalse(rejected["ZDOTDIR"]?.contains("/.remote-code/runtime/") == true)
    }

    @MainActor
    func test_subagentEnvironmentRepairsMissingArtifactProxyBeforeAcceptance() throws {
        // WHY: nested providers must receive the same immutable namespace as
        // the parent. A concurrent reconcile may remove either class of link;
        // acceptance is valid only after both are repaired and pinned.
        let appSupport = NSTemporaryDirectory() + "RC2SubagentProxyRepair-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let context = try makeContext(appSupport: appSupport)
        try enableTokenSaver(in: context)
        let thread = try admittedThread(in: context, provider: .codex)

        let first = context.subagentTelemetryEnvironment(
            provider: .codex,
            threadId: thread.id
        )
        let runtimeBin = try XCTUnwrap(first["RC_REMOTE_CODE_MANAGED_BIN"])
        let runtimeRoot = URL(fileURLWithPath: runtimeBin).deletingLastPathComponent()
        let service = runtimeRoot.appendingPathComponent("RemoteCodeDistillService")
        let wrapper = URL(fileURLWithPath: runtimeBin).appendingPathComponent("ls")
        let proxy = URL(fileURLWithPath: runtimeBin).appendingPathComponent("codex")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wrapper.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: proxy.path))
        try FileManager.default.removeItem(at: wrapper)
        try FileManager.default.removeItem(at: proxy)

        let repaired = context.subagentTelemetryEnvironment(
            provider: .codex,
            threadId: thread.id
        )
        XCTAssertEqual(repaired["RC_REMOTE_CODE_MANAGED_BIN"], runtimeBin)
        XCTAssertEqual(
            repaired[AgentSkillInstaller.runtimeRootEnvironmentKey],
            runtimeRoot.path
        )
        XCTAssertEqual(
            URL(fileURLWithPath: try FileManager.default.destinationOfSymbolicLink(atPath: wrapper.path))
                .standardizedFileURL.path,
            service.standardizedFileURL.path
        )
        XCTAssertEqual(
            URL(fileURLWithPath: try FileManager.default.destinationOfSymbolicLink(atPath: proxy.path))
                .standardizedFileURL.path,
            service.standardizedFileURL.path
        )
    }

    @MainActor
    func test_subagentEnvironmentFailsOpenWhenArtifactProxyCannotBeRepaired() throws {
        // WHY: a partial runtime must never advertise paid PATH/ZDOTDIR. A
        // user-owned provider basename blocks repair and therefore rejects the
        // artifact namespace instead of silently routing through a stale link.
        let appSupport = NSTemporaryDirectory() + "RC2SubagentProxyFailure-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let context = try makeContext(appSupport: appSupport)
        try enableTokenSaver(in: context)
        let thread = try admittedThread(in: context, provider: .codex)

        let first = context.subagentTelemetryEnvironment(
            provider: .codex,
            threadId: thread.id
        )
        let runtimeBin = try XCTUnwrap(first["RC_REMOTE_CODE_MANAGED_BIN"])
        let wrapper = URL(fileURLWithPath: runtimeBin).appendingPathComponent("ls")
        try FileManager.default.removeItem(at: wrapper)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let proxy = URL(fileURLWithPath: runtimeBin).appendingPathComponent("codex")
        try FileManager.default.removeItem(at: proxy)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: proxy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: proxy.path)

        let rejected = context.subagentTelemetryEnvironment(
            provider: .codex,
            threadId: thread.id
        )
        XCTAssertNil(
            rejected[AgentSkillInstaller.runtimeRootEnvironmentKey],
            "partial runtime must not expose a trusted artifact root"
        )
        XCTAssertFalse(
            rejected["PATH"]?.contains("/.remote-code/runtime/") == true,
            "partial runtime must not expose artifact-paid PATH"
        )
        XCTAssertFalse(
            rejected["ZDOTDIR"]?.contains("/.remote-code/runtime/") == true,
            "partial runtime must not expose artifact-paid ZDOTDIR"
        )
    }

    @MainActor
    func test_subagentEnvironmentRejectsPriorArtifactZDOTDIRAndBASH_ENV() throws {
        // WHY: a resumed worker can inherit startup pointers from an older
        // RemoteCode bundle. Treating those pointers as user profiles re-enters
        // the old interceptor and can recurse or hang the current turn.
        let appSupport = NSTemporaryDirectory() + "RC2OldBridge-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let context = try makeContext(appSupport: appSupport)
        try enableTokenSaver(in: context)
        let thread = try admittedThread(in: context, provider: .codex)
        let oldBridge = managedIntegrationHome(for: appSupport)
            .appendingPathComponent(".remote-code/runtime/old-artifact/shell/zsh-tool-v1")
        let environment = context.subagentTelemetryEnvironment(
            provider: .codex,
            threadId: thread.id,
            baseEnvironment: [
                "ZDOTDIR": oldBridge.path,
                "BASH_ENV": oldBridge.appendingPathComponent(".bash_env").path,
                "PATH": "\(managedIntegrationHome(for: appSupport).path)/.remote-code/bin:/usr/bin:/bin",
            ]
        )
        XCTAssertNotEqual(environment["RC_REMOTE_CODE_ORIGINAL_ZDOTDIR"], oldBridge.path)
        XCTAssertNotEqual(environment["ZDOTDIR"], oldBridge.path)
        XCTAssertNil(environment["RC_REMOTE_CODE_ORIGINAL_BASH_ENV"])
        XCTAssertFalse(environment["PATH"]?.contains("/.remote-code/bin") == true)
        let runtimeBin = try XCTUnwrap(environment["RC_REMOTE_CODE_MANAGED_BIN"])
        let expectedRuntimeBashEnv = URL(fileURLWithPath: runtimeBin)
            .deletingLastPathComponent()
            .appendingPathComponent("shell/zsh-tool-v1/.bash_env")
            .path
        XCTAssertEqual(
            environment["BASH_ENV"],
            expectedRuntimeBashEnv,
            "admitted subagent telemetry must pair BASH_ENV with its immutable runtime namespace"
        )
    }

    /// Nested provider proxies must resolve even when Token Saver is off: Subagents
    /// telemetry is always-on, and bare `grok`/`claude`/`codex` shell calls need the
    /// provider-only PATH controller without any distillation lane.
    @MainActor
    func test_providerEnvironmentPrependsManagedBin_whenTokenSaverOff() throws {
        let appSupport = NSTemporaryDirectory() + "RC2ProvProxyPathOff-" + UUID().uuidString
        let skillsHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2ProvProxyHome-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: skillsHome) }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: appSupport,
            agentSkillsHomeOverrideForTesting: skillsHome
        )
        SettingsStore(db: ctx.db).update { $0.tokenSaverEnabled = false }
        ctx.reconcileManagedDistillSkills(tokenSaverEnabled: false)
        let router = AppCommandRouter(context: ctx)
        let managedBin = skillsHome.appendingPathComponent(".remote-code/bin").path
        let providerProxyBin = skillsHome.appendingPathComponent(".remote-code/provider-bin").path
        let shellBridge = skillsHome.appendingPathComponent(".remote-code/shell/zsh").path
        let realBin = skillsHome.appendingPathComponent("real-bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: managedBin, isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: realBin, withIntermediateDirectories: true)
        let managedProbe = URL(fileURLWithPath: managedBin).appendingPathComponent("ordinary-probe")
        let realProbe = realBin.appendingPathComponent("ordinary-probe")
        try Data("#!/bin/sh\nprintf managed-wrapper\n".utf8).write(to: managedProbe)
        try Data("#!/bin/sh\nprintf real-command\n".utf8).write(to: realProbe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: managedProbe.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realProbe.path)

        for provider in AgentProvider.allCases {
            let thread = try admittedThread(in: ctx, provider: provider)
            let env = router.providerEnvironment(provider: provider, instanceId: nil, threadId: thread.id)
            let path = try XCTUnwrap(env["PATH"], "\(provider) must expose PATH with provider proxy bin")
            XCTAssertTrue(
                path.hasPrefix(providerProxyBin + ":") || path == providerProxyBin,
                "\(provider): provider proxy bin must lead PATH when Token Saver is off"
            )
            XCTAssertFalse(path.hasPrefix(managedBin + ":"),
                           "\(provider): universal wrapper bin must not lead OFF PATH")
            XCTAssertEqual(env["RC_REMOTE_CODE_PROVIDER_PROXY_BIN"], providerProxyBin)
            XCTAssertEqual(env["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"], thread.id.value.uuidString)
            XCTAssertEqual(env["RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE"], "1")
            XCTAssertEqual(env["RC_REMOTE_CODE_AGENT_APP_SOCKET_PATH"], AppPaths.socketPath(for: .debug))
            XCTAssertEqual(
                env["RC_REMOTE_CODE_AGENT_APP_COMMAND"],
                skillsHome.appendingPathComponent(".remote-code/provider-bin")
                    .appendingPathComponent(AgentSkillInstaller.agentAppMiddlewareCommand).path
            )
            XCTAssertEqual(
                env["ZDOTDIR"],
                shellBridge,
                "the provider shell must use RemoteCode's profile-preserving login bridge"
            )
            XCTAssertEqual(
                env["BASH_ENV"],
                skillsHome.appendingPathComponent(".remote-code/shell/zsh/.bash_env").path,
                "Grok ACP's persistent Bash terminal must use the managed PATH bridge"
            )
            XCTAssertNil(env["RC_TOKEN_SAVER_DISTILL_HINT"])
        }

        let offEnv = try XCTUnwrap(
            router.providerEnvironment(provider: .codex, instanceId: nil, threadId: try admittedThread(in: ctx, provider: .codex).id)
        )
        let offLookup = try runCommandLookup(environment: offEnv, path: realBin.path + ":" + (offEnv["PATH"] ?? ""))
        XCTAssertTrue(offLookup.contains("ordinary-probe=" + realProbe.path), offLookup)
        XCTAssertFalse(offLookup.contains(managedProbe.path), offLookup)
        XCTAssertTrue(
            offLookup.contains("remote-code=" + (offEnv["RC_REMOTE_CODE_AGENT_APP_COMMAND"] ?? "")),
            "OFF provider shell must retain the provider-only Agent App proxy: \(offLookup)"
        )

        try enableTokenSaver(in: ctx)
        let onThread = try admittedThread(in: ctx, provider: .codex)
        let onEnv = router.providerEnvironment(provider: .codex, instanceId: nil, threadId: onThread.id)
        let onLookup = try runCommandLookup(environment: onEnv, path: managedBin + ":" + realBin.path + ":" + (onEnv["PATH"] ?? ""))
        XCTAssertTrue(onLookup.contains("ordinary-probe=" + managedProbe.path), onLookup)
    }

    private func runCommandLookup(environment: [String: String], path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "printf 'ordinary-probe=%s\\nremote-code=%s\\n' \"$(command -v ordinary-probe)\" \"$(command -v remote-code)\""
        ]
        var child = environment
        child["PATH"] = path
        process.environment = child
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @MainActor
    func test_providerEnvironmentUsesCustomProviderHOMEAsOriginalZDOTDIR() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2CustomProviderHome-\(UUID().uuidString)", isDirectory: true)
        let skillsHome = root.appendingPathComponent("managed", isDirectory: true)
        let providerHome = root.appendingPathComponent("claude-home", isDirectory: true)
        try FileManager.default.createDirectory(at: providerHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path,
            agentSkillsHomeOverrideForTesting: skillsHome
        )
        try ctx.settingsRepo.set("agent.provider.instances", """
        [
          {
            "id": "claude-isolated",
            "provider": "claude",
            "displayName": "Claude Isolated",
            "binaryPath": "/usr/bin/env",
            "homePath": "\(providerHome.path)",
            "enabled": true,
            "env": {}
          }
        ]
        """)
        let router = AppCommandRouter(context: ctx)
        let thread = try admittedThread(in: ctx, provider: .claude)

        let env = router.providerEnvironment(
            provider: .claude,
            instanceId: "claude-isolated",
            threadId: thread.id
        )

        XCTAssertEqual(env["HOME"], providerHome.path)
        XCTAssertEqual(env["RC_REMOTE_CODE_ORIGINAL_ZDOTDIR"], providerHome.path)
        XCTAssertEqual(env["RC_REMOTE_CODE_EFFECTIVE_ZDOTDIR"], providerHome.path)
        XCTAssertEqual(
            env["ZDOTDIR"],
            skillsHome.appendingPathComponent(".remote-code/shell/zsh").path
        )

        ctx.tokenSaverEntitlementModelValidationOverrideForTesting = .installed
        PrivateAccountSessionStore(repo: ctx.settingsRepo).save(.init(
            accessToken: "test-access",
            refreshToken: "test-refresh",
            user: .init(
                daysRemaing: nil,
                daysRemaining: 30,
                email: "paid@example.com",
                id: "paid",
                subscribed: true
            )
        ))
        XCTAssertEqual(
            ctx.applyTokenSaverLifecycle(
                requestedEnabled: true,
                modelValidation: .installed,
                persistPreference: true
            ),
            .enabled
        )
        // This environment-only test has no packaged sidecar executable. Put
        // the controller back on the explicit XCTest injected-ready seam after
        // lifecycle admission so the assertion exercises the emitted runtime
        // environment rather than a synthetic process-launch failure.
        ctx.tokenSaverDistillServiceController.stop()
        let tokenSaverEnv = router.providerEnvironment(
            provider: .claude,
            instanceId: "claude-isolated",
            threadId: thread.id
        )
        let tokenSaverManagedBin = try XCTUnwrap(tokenSaverEnv["RC_REMOTE_CODE_MANAGED_BIN"])
        XCTAssertTrue(tokenSaverManagedBin.hasPrefix(skillsHome.path + "/.remote-code/runtime/"))
        XCTAssertTrue(
            tokenSaverEnv["PATH"]?.hasPrefix(tokenSaverManagedBin + ":") == true,
            "Token Saver admission must retain its sandboxed artifact runtime bin"
        )
        XCTAssertEqual(tokenSaverEnv["RC_TOKEN_SAVER_DISTILL_HINT"], "1")
    }

    @MainActor
    func test_providerEnvironmentDoesNotAdvertiseUserOwnedAgentAppAlias() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2ForeignAgentAppAlias-\(UUID().uuidString)", isDirectory: true)
        let skillsHome = root.appendingPathComponent("managed", isDirectory: true)
        let managedBin = skillsHome.appendingPathComponent(".remote-code/provider-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: managedBin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(
            to: managedBin.appendingPathComponent(AgentSkillInstaller.agentAppMiddlewareCommand)
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = try AppContext(
            channel: .debug,
            appSupportOverride: root.appendingPathComponent("support").path,
            agentSkillsHomeOverrideForTesting: skillsHome
        )
        let router = AppCommandRouter(context: ctx)
        let thread = try admittedThread(in: ctx, provider: .codex)

        let env = router.providerEnvironment(
            provider: .codex,
            instanceId: nil,
            threadId: thread.id
        )

        XCTAssertEqual(env["RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE"], "1")
        XCTAssertNil(
            env["RC_REMOTE_CODE_AGENT_APP_COMMAND"],
            "provider prompts must not receive a missing or user-owned launcher path"
        )
    }

    /// Recovered provider sessions bypass AppCommandRouter.providerEnvironment.
    /// WHY: without the managed PATH here, a resumed parent silently loses the
    /// provider middleware for every nested child even though fresh runs keep it.
    @MainActor
    func test_recoveryEnvironmentAlwaysCarriesManagedMiddlewarePath_andGatesTokenSaver() async throws {
        let appSupport = NSTemporaryDirectory() + "RC2RecoveryProxyPath-" + UUID().uuidString
        let ctx = try makeContext(appSupport: appSupport)
        let thread = try admittedThread(in: ctx, provider: .codex)
        let installer = AgentSkillInstaller(homeDirectory: managedIntegrationHome(for: appSupport))
        let managedBin = installer.managedCLIBinURL.path
        let providerProxyBin = installer.providerProxyBinURL.path
        let recoveryEnvironment = try XCTUnwrap(ctx.coordinator.recoveryEnvironmentProvider)

        SettingsStore(db: ctx.db).update { $0.tokenSaverEnabled = false }
        ctx.reconcileManagedDistillSkills(tokenSaverEnabled: false)
        let disabled = await recoveryEnvironment(.codex, thread.id)
        let disabledPath = try XCTUnwrap(disabled["PATH"])
        XCTAssertTrue(disabledPath.hasPrefix(providerProxyBin + ":") || disabledPath == providerProxyBin)
        XCTAssertFalse(disabledPath.hasPrefix(managedBin + ":"))
        XCTAssertEqual(disabled["RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE"], "1")
        XCTAssertNil(disabled["RC_TOKEN_SAVER_DISTILL_HINT"])

        try enableTokenSaver(in: ctx)
        let enabled = await recoveryEnvironment(.codex, thread.id)
        let enabledPath = try XCTUnwrap(enabled["PATH"])
        let enabledManagedBin = try XCTUnwrap(enabled["RC_REMOTE_CODE_MANAGED_BIN"])
        XCTAssertTrue(enabledManagedBin.contains("/.remote-code/runtime/"))
        XCTAssertTrue(
            enabledPath.hasPrefix(enabledManagedBin + ":") || enabledPath == enabledManagedBin
        )
        XCTAssertEqual(enabled["RC_TOKEN_SAVER_DISTILL_HINT"], "1")
    }

    /// Without a thread id there is no nested-provider interception scope.
    @MainActor
    func test_providerEnvironment_withoutThreadDoesNotRequireManagedPath() throws {
        let appSupport = NSTemporaryDirectory() + "RC2ProvProxyNoThread-" + UUID().uuidString
        let ctx = try makeContext(appSupport: appSupport)
        let router = AppCommandRouter(context: ctx)
        let env = router.providerEnvironment(provider: .codex, instanceId: nil, threadId: nil)
        XCTAssertEqual(env["REMOTE_CODE_AGENT_PROVIDER"], "codex")
        XCTAssertNil(env["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"])
        if let path = env["PATH"] {
            let managedBin = managedIntegrationHome(for: appSupport)
                .appendingPathComponent(".remote-code/bin", isDirectory: true).path
            XCTAssertFalse(
                path.split(separator: ":").map(String.init).contains(managedBin),
                "no-thread env must not inject managed bin (scrubbed raw path)"
            )
        }
    }
}
