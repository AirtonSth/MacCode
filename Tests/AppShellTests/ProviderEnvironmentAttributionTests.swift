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
    static func exerciseProviderSpawnedWorkerPromptDoesNotRunBestOfThreeAgain() async throws {
        // WHY: provider-native workers are events inside the admitted provider
        // turn, not new host sends. Their real lifecycle boundary must inherit
        // the admitted technique surface without selecting a format again.
        // Child-produced delivery accounting is intentionally proved by S003;
        // this request slice proves only that its ledger scope is applicable.
        let appSupport = NSTemporaryDirectory() + "RC2ProviderWorker-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        context.reconcileManagedDistillSkills(tokenSaverEnabled: true)
        let runners = Dictionary(uniqueKeysWithValues: [AgentProvider.claude, .codex, .grok].map {
            ($0, ControlledBotHandoffRunner(provider: $0))
        })
        for (provider, runner) in runners {
            context.coordinator.replaceProvider(provider, runner: runner)
        }
        let selections = TokenSaverSelectionCount()
        context.coordinator.tokenSaverOutboundSelector = { request in
            await selections.increment()
            return await TokenSaverBestOfThreeSelector.select(
                canonicalHuman: request.canonicalHuman,
                humanOutboundPrompt: request.admittedRequest.prompt,
                humanEffectiveEnvelope: request.admittedRequest.prompt,
                target: .init(
                    provider: request.admittedRequest.provider.rawValue,
                    resolvedModel: request.admittedRequest.model,
                    counterID: "unavailable",
                    counterRevision: "unavailable",
                    encoding: "unavailable"
                ),
                candidates: [],
                counter: nil
            )
        }

        var roots: [AgentProvider: AgentRunRequest] = [:]
        for provider in [AgentProvider.claude, .codex, .grok] {
            let thread = AgentThread(title: "provider worker", provider: provider, model: "test")
            try context.threadRepo.upsert(thread)
            let environment = router.providerEnvironment(
                provider: provider,
                instanceId: nil,
                threadId: thread.id
            )
            _ = try await context.coordinator.startRun(AgentRunRequest(
                threadId: thread.id,
                provider: provider,
                model: "test",
                cwd: appSupport,
                prompt: "root prompt that may spawn \(provider.rawValue) workers",
                environment: environment
            ))
            let root = try XCTUnwrap(runners[provider]?.requests.first)
            roots[provider] = root
            let receipt = try XCTUnwrap(TokenSaverExecutionReceiptSeam.receipt(from: root.environment))
            XCTAssertTrue(receipt.admitted && receipt.sameUser)
            XCTAssertEqual(receipt.provider, provider.rawValue)
            XCTAssertEqual(receipt.threadId.lowercased(), thread.id.value.uuidString.lowercased())
            XCTAssertEqual(root.environment["RC_TOKEN_SAVER_DISTILL_HINT"], "1")
            XCTAssertEqual(root.environment["RC_REMOTE_CODE_ROOT_RUN_ID"]?.lowercased(), root.runId.value.uuidString.lowercased())
            XCTAssertEqual(root.environment["RC_REMOTE_CODE_ATTEMPT_ID"]?.lowercased(), root.runId.value.uuidString.lowercased())
            let managed = try XCTUnwrap(root.environment["RC_REMOTE_CODE_MANAGED_BIN"])
            let path = try XCTUnwrap(root.environment["PATH"])
            XCTAssertTrue(path == managed || path.hasPrefix(managed + ":"))
            XCTAssertTrue(AgentSkillInstaller.tokenSaverProviderPrompt(
                "provider-native worker prompt",
                environment: root.environment
            ).contains("| distill"))
            if provider == .claude {
                XCTAssertEqual(root.environment["RC_TOKEN_SAVER_POST_TOOL_USE"], "1")
                XCTAssertNotNil(root.environment["REMOTE_CODE_DISTILL_STATE_PATH"])
            } else {
                XCTAssertNil(root.environment["RC_TOKEN_SAVER_POST_TOOL_USE"])
            }

            let ledgerThreadID = root.environment["RC_TOKEN_SAVER_THREAD_ID"]
                ?? root.environment["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"]
            XCTAssertEqual(ledgerThreadID?.lowercased(), thread.id.value.uuidString.lowercased())
            XCTAssertNotNil(ledgerThreadID, "provider-native delivery can attribute to the admitted root thread")
        }
        let rootSelectionCount = await selections.value
        XCTAssertEqual(rootSelectionCount, 3, "one root selection per provider")

        let codexRoot = try XCTUnwrap(roots[.codex])
        let codexChild = AgentRunID()
        let codexStates = try JSONSerialization.data(withJSONObject: [
            codexChild.value.uuidString.lowercased(): ["status": "running", "message": NSNull()],
        ], options: [.sortedKeys])
        XCTAssertTrue(runners[.codex]?.emit(
            runID: codexRoot.runId,
            event: .itemDelta(
                itemId: "native-codex",
                bodyAppend: nil,
                outputAppend: String(decoding: codexStates, as: UTF8.self),
                summary: "SpawnAgent"
            )
        ) == true)

        let crossProviderChild = AgentRunID()
        XCTAssertTrue(runners[.codex]?.emit(
            runID: codexRoot.runId,
            event: grokNativeWorkerEvent(childID: crossProviderChild, description: "cross-provider child")
        ) == true)
        let grokRoot = try XCTUnwrap(roots[.grok])
        let grokChild = AgentRunID()
        XCTAssertTrue(runners[.grok]?.emit(
            runID: grokRoot.runId,
            event: grokNativeWorkerEvent(childID: grokChild, description: "same-provider child")
        ) == true)

        for (child, provider, parent) in [
            (codexChild, AgentProvider.codex, codexRoot),
            (crossProviderChild, AgentProvider.grok, codexRoot),
            (grokChild, AgentProvider.grok, grokRoot),
        ] {
            let receipt = try XCTUnwrap(context.orchestrationRuntime.receipt(runId: child))
            XCTAssertEqual(receipt.provider, provider)
            XCTAssertEqual(receipt.threadId, parent.threadId)
            XCTAssertNotNil(receipt.parentReceiptId)
            XCTAssertEqual(receipt.lifecycleStatus, .accepted)
        }
        let finalSelectionCount = await selections.value
        XCTAssertEqual(finalSelectionCount, 3, "same/cross child events must not re-enter host selection")
        for root in roots.values {
            XCTAssertTrue(runners[root.provider]?.finish(runID: root.runId, status: .completed, reply: "done") == true)
        }
    }

    private static func grokNativeWorkerEvent(childID: AgentRunID, description: String) -> AssistantEvent {
        let payload: [String: Any] = [
            "sessionId": "parent-session",
            "update": [
                "sessionUpdate": "subagent_spawned",
                "subagent_id": childID.value.uuidString.lowercased(),
                "child_session_id": childID.value.uuidString.lowercased(),
                "description": description,
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return .providerRuntime(ProviderRuntimeEvent(
            provider: .grok,
            source: "grok.acp",
            method: "x.ai/session_notification",
            payloadJSON: String(decoding: data, as: UTF8.self),
            receivedAtMs: 1
        ))
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
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: context)
        let workspace = try router.createWorkspace(name: "auto-ts", cwd: NSTemporaryDirectory())
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        context.reconcileManagedDistillSkills(tokenSaverEnabled: true)

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
            XCTAssertFalse(managed.isEmpty, "\(provider) managed bin")
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
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
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
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = true }
        context.reconcileManagedDistillSkills(tokenSaverEnabled: true)

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
        let context = try AppContext(channel: .debug, appSupportOverride: appSupport)
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
        XCTAssertNotNil(codex["REMOTE_CODE_DISTILL_STATE_PATH"],
                        "Codex PATH wrappers need the same sidecar lease as explicit distill")

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

    /// Nested provider proxies must resolve even when Token Saver is off: Subagents
    /// telemetry is always-on, and bare `grok`/`claude`/`codex` shell calls need the
    /// managed PATH controller without any distillation lane.
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
        let shellBridge = skillsHome.appendingPathComponent(".remote-code/shell/zsh").path

        for provider in AgentProvider.allCases {
            let thread = try admittedThread(in: ctx, provider: provider)
            let env = router.providerEnvironment(provider: provider, instanceId: nil, threadId: thread.id)
            let path = try XCTUnwrap(env["PATH"], "\(provider) must expose PATH with managed bin")
            XCTAssertTrue(
                path.hasPrefix(managedBin + ":") || path == managedBin,
                "\(provider): managed bin must lead PATH when Token Saver is off for nested provider proxies"
            )
            XCTAssertEqual(env["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"], thread.id.value.uuidString)
            XCTAssertEqual(env["RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE"], "1")
            XCTAssertEqual(env["RC_REMOTE_CODE_AGENT_APP_SOCKET_PATH"], AppPaths.socketPath(for: .debug))
            XCTAssertEqual(
                env["RC_REMOTE_CODE_AGENT_APP_COMMAND"],
                skillsHome.appendingPathComponent(".remote-code/bin")
                    .appendingPathComponent(AgentSkillInstaller.agentAppMiddlewareCommand).path
            )
            XCTAssertEqual(
                env["ZDOTDIR"],
                shellBridge,
                "the provider shell must use RemoteCode's profile-preserving login bridge"
            )
            XCTAssertNil(env["RC_TOKEN_SAVER_DISTILL_HINT"])
        }
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
        XCTAssertTrue(
            tokenSaverEnv["PATH"]?.hasPrefix(
                skillsHome.appendingPathComponent(".remote-code/bin").path + ":"
            ) == true,
            "Token Saver admission must retain the sandboxed managed bin"
        )
        XCTAssertEqual(tokenSaverEnv["RC_TOKEN_SAVER_DISTILL_HINT"], "1")
    }

    @MainActor
    func test_providerEnvironmentDoesNotAdvertiseUserOwnedAgentAppAlias() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2ForeignAgentAppAlias-\(UUID().uuidString)", isDirectory: true)
        let skillsHome = root.appendingPathComponent("managed", isDirectory: true)
        let managedBin = skillsHome.appendingPathComponent(".remote-code/bin", isDirectory: true)
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
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let thread = try admittedThread(in: ctx, provider: .codex)
        let managedBin = AgentSkillInstaller.defaultManagedCLIBinDirectory().path
        let recoveryEnvironment = try XCTUnwrap(ctx.coordinator.recoveryEnvironmentProvider)

        SettingsStore(db: ctx.db).update { $0.tokenSaverEnabled = false }
        ctx.reconcileManagedDistillSkills(tokenSaverEnabled: false)
        let disabled = await recoveryEnvironment(.codex, thread.id)
        let disabledPath = try XCTUnwrap(disabled["PATH"])
        XCTAssertTrue(disabledPath.hasPrefix(managedBin + ":") || disabledPath == managedBin)
        XCTAssertEqual(disabled["RC_REMOTE_CODE_AGENT_APP_MIDDLEWARE"], "1")
        XCTAssertNil(disabled["RC_TOKEN_SAVER_DISTILL_HINT"])

        SettingsStore(db: ctx.db).update { $0.tokenSaverEnabled = true }
        ctx.reconcileManagedDistillSkills(tokenSaverEnabled: true)
        let enabled = await recoveryEnvironment(.codex, thread.id)
        let enabledPath = try XCTUnwrap(enabled["PATH"])
        XCTAssertTrue(enabledPath.hasPrefix(managedBin + ":") || enabledPath == managedBin)
        XCTAssertEqual(enabled["RC_TOKEN_SAVER_DISTILL_HINT"], "1")
    }

    /// Without a thread id there is no nested-provider interception scope.
    @MainActor
    func test_providerEnvironment_withoutThreadDoesNotRequireManagedPath() throws {
        let appSupport = NSTemporaryDirectory() + "RC2ProvProxyNoThread-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        let env = router.providerEnvironment(provider: .codex, instanceId: nil, threadId: nil)
        XCTAssertEqual(env["REMOTE_CODE_AGENT_PROVIDER"], "codex")
        XCTAssertNil(env["RC_REMOTE_CODE_SUBAGENT_THREAD_ID"])
        if let path = env["PATH"] {
            let managedBin = AgentSkillInstaller.defaultManagedCLIBinDirectory().path
            XCTAssertFalse(
                path.split(separator: ":").map(String.init).contains(managedBin),
                "no-thread env must not inject managed bin (scrubbed raw path)"
            )
        }
    }

    @MainActor
    func test_providerEnvironmentStampsCallerBotIdAndLogicalHostAdmission() throws {
        // WHY: self-config MCP must inherit the calling bot, not a baked home-MCP id.
        let appSupport = NSTemporaryDirectory() + "RC2BotSelfConfigEnv-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        let bot = try ctx.botStore.create(name: "Piper", title: "", description: "", provider: .claude)
        let thread = try admittedThread(in: ctx, provider: .claude)
        try ctx.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Desk", linkedAgentThreadID: thread.id)
        )

        let env = router.providerEnvironment(provider: .claude, instanceId: nil, threadId: thread.id)
        XCTAssertEqual(
            env[BotSelfConfigCatalog.callerEnvironmentKey],
            bot.id.value.uuidString.lowercased()
        )
        XCTAssertEqual(env[AgentSkillInstaller.computerUseHostAdmissionEnvironmentKey], "1")

        let other = try admittedThread(in: ctx, provider: .grok)
        let unbound = router.providerEnvironment(provider: .grok, instanceId: nil, threadId: other.id)
        XCTAssertNil(unbound[BotSelfConfigCatalog.callerEnvironmentKey])
    }

    @MainActor
    func test_providerEnvironmentStubsDockerAndExcludesHostMCP() throws {
        // WHY: dockerDesktop child PATH must retain failing host stubs and must
        // not keep DOCKER_HOST or the native physical-host MCP admission.
        let appSupport = NSTemporaryDirectory() + "RC2DockerPath-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: appSupport)
        let router = AppCommandRouter(context: ctx)
        let dockerBot = try ctx.botStore.create(
            name: "Piper",
            title: "",
            description: "",
            provider: .claude,
            desktopKind: .dockerDesktop
        )
        let dockerThread = try admittedThread(in: ctx, provider: .claude)
        try ctx.botStore.upsertConversation(
            BotConversation(botID: dockerBot.id, title: "Desk", linkedAgentThreadID: dockerThread.id)
        )
        let dockerEnv = router.providerEnvironment(
            provider: .claude,
            instanceId: nil,
            threadId: dockerThread.id
        )
        XCTAssertNil(dockerEnv["DOCKER_HOST"])
        XCTAssertNil(dockerEnv["DOCKER_CONTEXT"])
        XCTAssertNil(dockerEnv[AgentSkillInstaller.computerUseHostAdmissionEnvironmentKey])
        let stub = URL(fileURLWithPath: appSupport, isDirectory: true)
            .appendingPathComponent("bot-desktop-stubs", isDirectory: true)
            .appendingPathComponent("dockerDesktop", isDirectory: true)
        let path = try XCTUnwrap(dockerEnv["PATH"])
        XCTAssertTrue(
            path.split(separator: ":").map(String.init).contains(stub.path),
            "dockerDesktop PATH must include the stub dir, got \(path)"
        )
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: stub.appendingPathComponent("macos-harness").path)
        )
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: stub.appendingPathComponent("docker").path)
        )

        let hostBot = try ctx.botStore.create(
            name: "Scout",
            title: "",
            description: "",
            provider: .claude,
            desktopKind: .logicalExecutionSpace
        )
        let hostThread = try admittedThread(in: ctx, provider: .claude)
        try ctx.botStore.upsertConversation(
            BotConversation(botID: hostBot.id, title: "Desk", linkedAgentThreadID: hostThread.id)
        )
        let hostEnv = router.providerEnvironment(
            provider: .claude,
            instanceId: nil,
            threadId: hostThread.id
        )
        XCTAssertEqual(hostEnv[AgentSkillInstaller.computerUseHostAdmissionEnvironmentKey], "1")
        let hostPath = hostEnv["PATH"] ?? ""
        XCTAssertFalse(
            hostPath.split(separator: ":").map(String.init).contains(stub.path),
            "this-Mac PATH must not include the dockerDesktop stub dir"
        )
    }
}

private actor TokenSaverSelectionCount {
    private var count = 0
    func increment() { count += 1 }
    var value: Int { count }
}
