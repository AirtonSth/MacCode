import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

final class DistillACPClientSessionParamsTests: XCTestCase {
    func test_autoLogicalModelPassesThroughLocalAndGuestLaunchAndSessionMetadata() throws {
        let request = AgentRunRequest(threadId: AgentThreadID(), provider: .distill, model: "auto", cwd: "/tmp", prompt: "Go", reasoningEffort: .low)
        let expected = ["agent", "--model", "auto", "--reasoning-effort", "low", "--no-leader", "stdio"]
        XCTAssertEqual(try DistillACPClient.launchArguments(for: request), expected)
        XCTAssertEqual(try DistillGuestLaunchPlan.guestCommand(binaryPath: "/guest/distill", for: request),
                       ["/guest/distill", "--no-auto-update"] + expected)
        let headless = DistillRunner.buildArgs(request)
        let modelIndex = try XCTUnwrap(headless.firstIndex(of: "--model"))
        XCTAssertEqual(headless[modelIndex + 1], "auto")
        let effortIndex = try XCTUnwrap(headless.firstIndex(of: "--reasoning-effort"))
        XCTAssertEqual(headless[effortIndex + 1], "low")
        let params = DistillACPClient.sessionOpenParams(cwd: "/tmp", mcpServers: [], modelId: "auto", reasoningEffort: .low)
        XCTAssertEqual((params["_meta"] as? [String: Any])?["modelId"] as? String, "auto")
        XCTAssertEqual((params["_meta"] as? [String: Any])?["reasoningEffort"] as? String, "low")
    }

    func test_accountProviderIsCopiedOnlyFromTrustedACPMetadata() {
        let models = DistillACPClient.modelDescriptors(from: ["availableModels": [
            ["modelId": "unrelated-name", "_meta": ["accountProvider": "chatgpt"]],
            ["modelId": "chatgpt/untrusted", "_meta": ["accountProvider": "unknown"]],
            ["modelId": "claude/without-authority"],
        ]])
        XCTAssertEqual(models[0].accountProvider, "chatgpt")
        XCTAssertNil(models[1].accountProvider)
        XCTAssertNil(models[2].accountProvider)
    }

    func test_sessionNewUsesDistillMetaModelAndReasoningEffortWireFields() {
        let params = DistillACPClient.sessionOpenParams(
            cwd: "/tmp",
            mcpServers: [],
            modelId: "grok-4.6",
            reasoningEffort: .high
        )

        XCTAssertNil(params["model"], "Distill's session setup does not select a model from the generic top-level field")
        XCTAssertNil(params["reasoning_effort"])
        let meta = params["_meta"] as? [String: Any]
        XCTAssertEqual(meta?["modelId"] as? String, "grok-4.6")
        XCTAssertEqual(meta?["reasoningEffort"] as? String, "high")
    }

    func test_fallbackCatalogContainsOnlyExplicitDistillModels_becauseMainSelectionMustNeverBeAccountDefault() {
        let models = DistillRunner.listModels(installedVersion: nil)

        XCTAssertFalse(models.isEmpty)
        XCTAssertTrue(models.allSatisfy { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        XCTAssertFalse(models.contains { $0.label == "Default (account)" })
    }

    func test_cliRunnerRejectsEmptyMainModelBeforeResolvingBinary_becauseAccountDefaultIsNotSelectable() async throws {
        let runner = DistillRunner(binaryNameOverride: "/missing/distill-agent")
        do {
            _ = try await runner.startRun(
                AgentRunRequest(
                    threadId: AgentThreadID(),
                    provider: .distill,
                    model: "",
                    cwd: "/tmp",
                    prompt: "Do work"
                ),
                onEvent: { _ in }
            )
            XCTFail("The CLI runner must not omit --model for a Distill run")
        } catch let error as AgentRunError {
            guard case .spawnFailed(let message) = error else {
                return XCTFail("expected explicit Main-model validation, got \(error)")
            }
            XCTAssertEqual(message, "Select an explicit Distill Main model before running.")
        }
    }

    func test_modelResolutionUsesExactQualifiedIDThenOnlyUniqueProviderAlias() {
        let models = [
            AgentModelDescriptor(id: "chatgpt/gpt-6-luna", label: "Luna", provider: .distill),
            AgentModelDescriptor(id: "openai/gpt-6-luna", label: "Luna", provider: .distill),
        ]

        XCTAssertEqual(
            DistillACPClient.matchingModels("chatgpt/gpt-6-luna", in: models).map(\.id),
            ["chatgpt/gpt-6-luna"]
        )
        XCTAssertEqual(DistillACPClient.matchingModels("gpt-6-luna", in: models).count, 2)
        XCTAssertTrue(DistillACPClient.matchingModels("other/gpt-6-luna", in: models).isEmpty)
    }

    func test_sessionNewOmitsUnavailableModelAndEffort() {
        let params = DistillACPClient.sessionOpenParams(cwd: "/tmp", mcpServers: [])

        XCTAssertNil(params["model"])
        XCTAssertNil(params["reasoning_effort"])
        XCTAssertNil(params["_meta"])
    }

    func test_promptBlocks_keepOriginalPromptAndEssentialBotDirectives_withoutGenericModeOrTokenSaverText() throws {
        let original = "Original user request with exact wording."
        let botContext = "RemoteCode-resolved Bot identities for this exact turn: @quinn"
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .distill,
            model: "grok-4.6",
            cwd: "/tmp",
            prompt: original,
            interactionMode: .plan,
            environment: [
                BotPeerDelegation.turnContextEnvironmentKey: botContext,
                "RC_TOKEN_SAVER_ENABLED": "1",
                "RC_AUTO_ENABLED": "1"
            ]
        )
        let capabilities = DistillACPInitializeResult(
            protocolVersion: 1,
            loadSession: true,
            embeddedContext: false
        )

        let blocks = try DistillACPClient.promptBlocks(for: request, capabilities: capabilities)
        let text = try XCTUnwrap(blocks.first?["text"] as? String)

        XCTAssertTrue(text.contains(original))
        XCTAssertTrue(text.contains(botContext))
        XCTAssertTrue(text.contains(BackgroundAwaitContinuation.awaitingMarker))
        XCTAssertTrue(text.contains(BotPeerDelegation.providerDirective))
        XCTAssertFalse(text.contains("Default mode."))
        XCTAssertFalse(text.contains("Plan mode."))
        XCTAssertFalse(text.contains("Auto is on."))
        XCTAssertFalse(text.contains("Token Saver"))
    }

    func test_slashCommandStaysExactFirstBlock_soDistillParsesArgsWithoutDirectiveText() throws {
        // WHY: Distill reads `/name args` from the first text block only; appended directives corrupted `/goal status`.
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .distill,
            model: "grok-4.6",
            cwd: "/tmp",
            prompt: "/goal status"
        )
        let capabilities = DistillACPInitializeResult(protocolVersion: 1, loadSession: true, embeddedContext: false)

        let blocks = try DistillACPClient.promptBlocks(for: request, capabilities: capabilities)

        XCTAssertEqual(blocks.first?["text"] as? String, "/goal status")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertTrue((blocks[1]["text"] as? String)?.contains(BackgroundAwaitContinuation.awaitingMarker) == true)
    }

    func test_otherProviderStillUsesGenericModePrompt() {
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .claude,
            model: "claude",
            cwd: "/tmp",
            prompt: "Original"
        )

        XCTAssertTrue(request.providerPrompt.contains("Default mode."))
        XCTAssertTrue(request.providerPrompt.contains("User request:\nOriginal"))
    }

    func test_distillPromptBlocks_preserveAttachmentBlocks() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("distill-prompt-\(UUID().uuidString).txt")
        try Data("attachment body".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .distill,
            model: "grok-4.6",
            cwd: "/tmp",
            prompt: "Keep this prompt",
            attachments: [AgentAttachment(path: fileURL.path, kind: .file)]
        )
        let capabilities = DistillACPInitializeResult(
            protocolVersion: 1,
            loadSession: true,
            embeddedContext: true
        )

        let blocks = try DistillACPClient.promptBlocks(for: request, capabilities: capabilities)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[1]["type"] as? String, "resource")
    }

    func test_distillHomePrecedence_instanceThenEnvThenDotDistill() {
        // WHY: an explicit instance home must win over the app env, and ~/.grok must never be adopted.
        XCTAssertEqual(
            DistillProvisioner.homeURL(
                instanceHomePath: " /i ", environment: ["DISTILL_HOME": "/e", "GROK_HOME": "/g"], userHome: "/u"
            ).path,
            "/i"
        )
        XCTAssertEqual(
            DistillProvisioner.homeURL(
                instanceHomePath: "", environment: ["DISTILL_HOME": "/e", "GROK_HOME": "/g"], userHome: "/u"
            ).path,
            "/e"
        )
        XCTAssertEqual(
            DistillProvisioner.homeURL(instanceHomePath: nil, environment: ["GROK_HOME": "/g"], userHome: "/u").path,
            "/u/.distill"
        )
    }

    func test_distillModelsConfigReadsOnlyWorkerKeysFromModelsSection() {
        // WHY: the global Worker display must ignore comments, other sections, and empty values.
        let parsed = DistillModelsConfig.parse("""
        worker = "top-level-ignored"
        [other]
        worker = "other-section"
        [models]
        # worker = "commented"
        main = "gpt"
        worker = "grok-4.5" # trailing
        worker_effort = 'high'
        """)
        XCTAssertEqual(parsed.worker, "grok-4.5")
        XCTAssertEqual(parsed.workerEffort, "high")
        let empty = DistillModelsConfig.parse("[models]\nworker = \"\"\nworker_effort = \"\"\n")
        XCTAssertNil(empty.worker)
        XCTAssertNil(empty.workerEffort)
    }

    func test_distillModelsConfigReadMissingFileIsNil() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)")
        let result = DistillModelsConfig.read(home: home)
        XCTAssertNil(result.worker)
        XCTAssertNil(result.workerEffort)
    }

    private func sessionMCPServerNames(_ environment: [String: String]) -> [String] {
        DistillACPClient.sessionMCPServers(
            existing: [],
            command: "/tmp/RemoteCodeDistillService",
            environment: environment
        ).compactMap { ($0 as? [String: Any])?["name"] as? String }
    }

    /// WHY: bot-computer/-browser/-web answer every call with callerMissing
    /// without RC_REMOTE_CODE_BOT_ID, so a non-bot Agent App Distill thread was
    /// being offered tools that can only fail. bot-self-config stays on every
    /// session: Agent App runs use it for bot_ask_peer and the rc_* host catalog.
    func test_sessionMCPServersAdmitBotOnlyServersOnlyForBotRuns() {
        let botOnly = [BotBrowserMCPAdmit.serverName, BotComputerMCPAdmit.serverName, BotWebMCPAdmit.serverName]

        let nonBot = sessionMCPServerNames([:])
        XCTAssertTrue(nonBot.contains(BotSelfConfigMCPAdmit.serverName))
        for name in botOnly {
            XCTAssertFalse(nonBot.contains(name), "non-bot Distill session must not see \(name)")
        }
        let blankBotID = sessionMCPServerNames([BotSelfConfigCatalog.callerEnvironmentKey: "  "])
        XCTAssertFalse(blankBotID.contains(BotComputerMCPAdmit.serverName), "a blank bot id is not a bot run")

        let bot = sessionMCPServerNames([BotSelfConfigCatalog.callerEnvironmentKey: "bot-proof"])
        for name in [BotSelfConfigMCPAdmit.serverName] + botOnly {
            XCTAssertTrue(bot.contains(name), "bot Distill session must admit \(name)")
        }
    }

    /// WHY: a bot agent called cua-driver__get_browser_state, a Mac tool, from a
    /// bot run. Distill imports ~/.claude.json and Cursor MCPs unless these two
    /// toggles are 0 (verified with distill 2.0.30 `inspect`). Only bot runs are
    /// isolated; a normal Agent App thread keeps the user's MCPs.
    func test_launchEnvironmentDisablesUserMCPImportOnlyForBotRuns() {
        let keys = ["GROK_CLAUDE_MCPS_ENABLED", "GROK_CURSOR_MCPS_ENABLED"]

        let bot = DistillACPClient.launchEnvironment([
            BotSelfConfigCatalog.callerEnvironmentKey: "bot-proof",
            "GROK_CLAUDE_MCPS_ENABLED": "1",
            "PATH": "/usr/bin",
        ])
        for key in keys {
            XCTAssertEqual(bot[key], "0", "bot run must not import the user's \(key) MCPs")
        }
        XCTAssertEqual(bot["PATH"], "/usr/bin")

        let nonBot = DistillACPClient.launchEnvironment(["PATH": "/usr/bin"])
        XCTAssertEqual(nonBot, ["PATH": "/usr/bin"], "non-bot runs keep the user's MCPs untouched")
        let userChoice = DistillACPClient.launchEnvironment(["GROK_CURSOR_MCPS_ENABLED": "1"])
        XCTAssertEqual(userChoice["GROK_CURSOR_MCPS_ENABLED"], "1")
    }

    /// WHY: Distill's default caveman level `full` drops articles, so bots
    /// answered "Fala tarefa.". `lite` keeps full sentences; a host
    /// GROK_CAVEMAN must not override it for bots, while a non-bot Agent App
    /// thread keeps the user's own choice.
    func test_botLaunchesPinLiteCaveman_nonBotLaunchesKeepTheUsersLevel() {
        let bot = DistillACPClient.launchEnvironment([
            BotSelfConfigCatalog.callerEnvironmentKey: "bot-proof",
            "GROK_CAVEMAN": "ultra",
        ])
        XCTAssertEqual(bot["GROK_CAVEMAN"], "lite")
        XCTAssertNil(DistillACPClient.launchEnvironment(["PATH": "/usr/bin"])["GROK_CAVEMAN"])
        XCTAssertEqual(DistillACPClient.launchEnvironment(["GROK_CAVEMAN": "full"])["GROK_CAVEMAN"], "full")
    }

    /// WHY: the bot persona arrives as a user turn, below Distill's
    /// system-level `<output_style>` ("takes precedence over other tone").
    /// Only `_meta.rules` (appended to the system prompt) can override it,
    /// and only bot sessions may get it.
    func test_sessionNewCarriesHumanReplyRulesOnlyForBotRuns() throws {
        let rules = try XCTUnwrap(BotRunMCPAdmission.distillSessionRules(
            environment: [BotSelfConfigCatalog.callerEnvironmentKey: "bot-proof"]
        ))
        XCTAssertEqual(rules, BotRunMCPAdmission.distillBotReplyRules)
        XCTAssertTrue(rules.contains("ignore the <output_style> section"))
        XCTAssertTrue(rules.contains(BotStandingInstructions.replyStyleLine))
        XCTAssertNil(BotRunMCPAdmission.distillSessionRules(environment: ["PATH": "/usr/bin"]))

        let params = DistillACPClient.sessionOpenParams(cwd: "/tmp", mcpServers: [], rules: rules)
        XCTAssertEqual((params["_meta"] as? [String: Any])?["rules"] as? String, rules)
        XCTAssertNil(DistillACPClient.sessionOpenParams(cwd: "/tmp", mcpServers: [], rules: nil)["_meta"])
    }
}


/// Per-Bot Caveman (2026-10-15): the host stamps the Bot's setting on the run;
/// Distill's own caveman style is kept for caveman Bots and overridden otherwise.
final class DistillBotCavemanEnvironmentTests: XCTestCase {
    private func botRun(caveman: Bool) -> [String: String] {
        [
            BotSelfConfigCatalog.callerEnvironmentKey: UUID().uuidString,
            BotRunMCPAdmission.cavemanEnvironmentKey: caveman ? "1" : "0",
            "GROK_CAVEMAN": "ultra",
        ]
    }

    func test_cavemanFlagBotRunStillGetsHumanReplyRules() {
        // WHY: the host now stamps "0" for every Bot; a leftover "1" must
        // still get the human rules so no Bot falls back to caveman prose.
        let env = botRun(caveman: true)
        XCTAssertEqual(DistillACPClient.launchEnvironment(env)["GROK_CAVEMAN"], "full",
                       "a host value never changes a Bot's level")
        XCTAssertEqual(BotRunMCPAdmission.distillSessionRules(environment: env), BotRunMCPAdmission.distillBotReplyRules)
    }

    func test_cavemanOffBotKeepsFullSentences() {
        let env = botRun(caveman: false)
        XCTAssertEqual(DistillACPClient.launchEnvironment(env)["GROK_CAVEMAN"], "lite")
        XCTAssertEqual(BotRunMCPAdmission.distillSessionRules(environment: env), BotRunMCPAdmission.distillBotReplyRules)
    }

    func test_guestRunsFollowTheSameBotSetting() {
        let guest = DistillGuestEnvironment.build(
            providerEnvironment: botRun(caveman: true),
            runID: "run",
            gatewayToken: "token",
            modelSecrets: [:],
            gitIdentity: nil
        )
        XCTAssertEqual(guest["GROK_CAVEMAN"], "full")
    }

    func test_nonBotThreadsKeepTheUsersOwnDistillStyle() {
        let env = ["GROK_CAVEMAN": "ultra", BotRunMCPAdmission.cavemanEnvironmentKey: "1"]
        XCTAssertEqual(DistillACPClient.launchEnvironment(env)["GROK_CAVEMAN"], "ultra")
        XCTAssertNil(BotRunMCPAdmission.distillSessionRules(environment: env))
    }
}
