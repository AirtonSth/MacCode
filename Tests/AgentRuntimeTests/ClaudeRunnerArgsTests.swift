import XCTest
@testable import AgentRuntime
import CoreModel
import DistillCore
import Persistence

/// Regression: `claude --print --output-format stream-json` is rejected by
/// the CLI ("requires --verbose"). The runner MUST always pass --verbose,
/// keep the prompt last, and map permission modes correctly.
final class ClaudeRunnerArgsTests: XCTestCase {

    private func req(_ mode: AgentPermissionMode = .supervised,
                     resume: String? = nil) -> AgentRunRequest {
        AgentRunRequest(threadId: AgentThreadID(), provider: .claude,
                        model: "claude-opus-4-7", cwd: "/tmp",
                        prompt: "hello world", providerThreadId: resume,
                        permissionMode: mode)
    }

    func test_streamJsonAlwaysCarriesVerbose() {
        let a = ClaudeRunner.buildArgs(req())
        XCTAssertTrue(a.contains("--print"))
        XCTAssertTrue(a.contains("--verbose"),
                      "--print + stream-json without --verbose makes every run fail")
        let i = a.firstIndex(of: "--output-format")!
        XCTAssertEqual(a[a.index(after: i)], "stream-json")
    }

    func test_streamingSessionArgsUseStdinPromptAndStableSessionId() {
        let request = req()
        let a = ClaudeRunner.buildStreamingArgs(request)
        XCTAssertTrue(a.contains("--print"))
        XCTAssertTrue(a.contains("--input-format"))
        XCTAssertEqual(a[a.index(after: a.firstIndex(of: "--input-format")!)], "stream-json")
        XCTAssertEqual(a[a.index(after: a.firstIndex(of: "--output-format")!)], "stream-json")
        XCTAssertTrue(a.contains("--replay-user-messages"),
                      "durable Claude sessions need echoed user messages so the timeline remains complete")
        XCTAssertTrue(a.contains("--include-partial-messages"),
                      "stream-json sessions must request partial messages for token-level streaming")
        XCTAssertEqual(a[a.index(after: a.firstIndex(of: "--session-id")!)], request.threadId.value.uuidString,
                       "new durable Claude sessions must use a stable provider session id for restart diagnostics")
        XCTAssertFalse(a.contains("hello world"),
                       "stream-json sessions must send user turns over stdin, not bake the first prompt into argv")
        XCTAssertFalse(zip(a, a.dropFirst()).contains { $0 == "--tools" && $1.isEmpty },
                       "the streaming fallback must not silently disable Claude tools and degrade into chat-only mode")
    }

    func test_streamingLoadsUserProjectLocalSettingSources() {
        // WHY: without --setting-sources, `claude --print` ignores ~/.claude and
        // ./.claude, so project/user skills (e.g. `/task`), custom slash
        // commands, MCP servers, agents, and hooks are invisible to the agent —
        // the exact "agent mode doesn't see my skills / MCPs" report. This must
        // match what an interactive `claude` session loads.
        let a = ClaudeRunner.buildStreamingArgs(req())
        let i = a.firstIndex(of: "--setting-sources")
        XCTAssertNotNil(i, "streaming args must load filesystem settings so skills/MCP/commands resolve")
        let value = a[a.index(after: i!)]
        // Order-independent: must include all three sources.
        let sources = Set(value.split(separator: ",").map(String.init))
        XCTAssertEqual(sources, ["user", "project", "local"],
                       "must load user + project + local to match interactive claude's `/` surface")
    }

    func test_liveClaudeRoutesAdmitBotPeerMCPWithExactRunContext() throws {
        // WHY: Claude Code does not read mcpServers from settings.json. Without
        // the explicit per-process config, the primary AI can interpret @bot
        // correctly yet has no bot_ask_peer tool and falsely asks the user to
        // start a peer session. Both CLI routes must carry only active-run
        // authority; no user prose or unrelated environment may enter config.
        let environment = [
            BotSelfConfigCatalog.callerEnvironmentKey: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            BotPeerDelegation.threadEnvironmentKey: "11111111-2222-3333-4444-555555555555",
            BotPeerDelegation.runEnvironmentKey: "66666666-7777-8888-9999-aaaaaaaaaaaa",
            BotPeerDelegation.socketEnvironmentKey: "/tmp/remote-code.sock",
            "UNRELATED_SECRET": "must-not-be-forwarded",
        ]
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .claude,
            model: "claude-opus-4-7",
            cwd: "/tmp",
            prompt: "USER WORDS STAY OUT OF MCP CONFIG",
            environment: environment
        )
        for args in [ClaudeRunner.buildArgs(request), ClaudeRunner.buildStreamingArgs(request)] {
            let index = try XCTUnwrap(args.firstIndex(of: "--mcp-config"))
            let data = Data(args[args.index(after: index)].utf8)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
            let server = try XCTUnwrap(servers[BotSelfConfigMCPAdmit.serverName] as? [String: Any])
            let forwarded = try XCTUnwrap(server["env"] as? [String: String])
            XCTAssertEqual(forwarded, environment.filter { $0.key != "UNRELATED_SECRET" })
            XCTAssertNil(forwarded["UNRELATED_SECRET"])
            XCTAssertFalse(args[args.index(after: index)].contains(request.prompt))
            XCTAssertFalse(args.contains("--strict-mcp-config"),
                           "RemoteCode's server must supplement, not replace, user/project MCP servers")
            let allowedIndex = try XCTUnwrap(args.firstIndex(of: "--allowedTools"))
            let allowed = Set(args[args.index(after: allowedIndex)].split(separator: ",").map(String.init))
            XCTAssertEqual(
                allowed,
                Set(BotSelfConfigMCPAdmit.claudeAutomaticallyAllowedTools
                    + DistillMCPAdmit.claudeAutomaticallyAllowedTools),
                "supervised mode must allow exactly the managed delegation/settings and librarian tools without another user confirmation"
            )
        }
    }

    func test_liveClaudeRoutesAdmitDistillLibrarianMCP() throws {
        // WHY: the distill skill instructs every provider to prefer the librarian
        // MCP tools (rc_stats/rc_search/rc_ask/rc_retrieve/rc_compress — the
        // 01-catalogo.html surface), but Claude never saw the server: it was
        // installed into ~/.claude/settings.json, which Claude Code does not read
        // for mcpServers (proven live: the entry never spawned and `claude mcp
        // list` omits it). Codex reads it from config.toml and Grok admits it per
        // ACP session; both Claude routes must admit it per spawn the same way
        // the bot peer server already is.
        let environment = [
            "RC_TOKEN_SAVER_THREAD_ID": "11111111-2222-3333-4444-555555555555",
            "REMOTE_CODE_AGENT_PROVIDER": "claude",
            "UNRELATED_SECRET": "must-not-be-forwarded",
        ]
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .claude,
            model: "claude-opus-4-7",
            cwd: "/tmp",
            prompt: "hello",
            environment: environment
        )
        for args in [ClaudeRunner.buildArgs(request), ClaudeRunner.buildStreamingArgs(request)] {
            let index = try XCTUnwrap(args.firstIndex(of: "--mcp-config"))
            let data = Data(args[args.index(after: index)].utf8)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
            let librarian = try XCTUnwrap(
                servers[DistillMCPAdmit.serverName] as? [String: Any],
                "every Claude CLI turn must carry the librarian MCP server"
            )
            XCTAssertEqual(librarian["args"] as? [String], ["mcp"])
            let forwarded = try XCTUnwrap(librarian["env"] as? [String: String])
            XCTAssertEqual(forwarded["RC_TOKEN_SAVER_THREAD_ID"], "11111111-2222-3333-4444-555555555555")
            XCTAssertNil(forwarded["UNRELATED_SECRET"],
                         "only recovery-scope keys may be forwarded to the librarian server")
            XCTAssertNotNil(servers[BotSelfConfigMCPAdmit.serverName],
                            "the librarian must supplement, never replace, the bot peer server")
        }

        // SDK bridge engine parity: the same server must ride the bridge payload.
        let sdkServers = ClaudeAgentSDKBridgeAdapter.botPeerMCPServers(environment: environment)
        XCTAssertNotNil(sdkServers[DistillMCPAdmit.serverName] as? [String: Any],
                        "the opt-in SDK engine must admit the librarian server too, or the engines drift")

        // The allowlisted tool names must match the tools the server actually
        // serves (ManagedRetrieveMCP), or supervised mode silently prompts.
        XCTAssertEqual(
            Set(DistillMCPAdmit.toolNames),
            Set([
                ManagedRetrieveMCP.statsToolName,
                ManagedRetrieveMCP.searchToolName,
                ManagedRetrieveMCP.askToolName,
                ManagedRetrieveMCP.toolName,
                ManagedRetrieveMCP.compressToolName,
            ]),
            "CoreModel cannot import DistillCore, so the duplicated tool-name list must be pinned to the real server surface"
        )
    }

    func test_uncaughtSignalIsFailureUnlessCancellationWasRequested() {
        XCTAssertEqual(
            ClaudeRunner.terminalStatus(cancelRequested: false, terminationReason: .uncaughtSignal, terminationStatus: 9),
            .failed,
            "a provider crash must remain a failure instead of being mislabeled as user cancellation"
        )
        XCTAssertEqual(
            ClaudeRunner.terminalStatus(cancelRequested: true, terminationReason: .uncaughtSignal, terminationStatus: 9),
            .cancelled,
            "an uncaught signal caused by an explicit stop remains cancellation"
        )
    }

    func test_streamingSessionResumeUsesProviderThreadId() {
        let a = ClaudeRunner.buildStreamingArgs(req(.supervised, resume: "claude-session-7"))
        XCTAssertEqual(a[a.index(after: a.firstIndex(of: "--resume")!)], "claude-session-7")
        XCTAssertNil(a.firstIndex(of: "--session-id"),
                     "resumed Claude streaming sessions must not also request a new session id")
    }

    func test_streamingAppendsBackgroundAwaitAlwaysAndDistillOnlyWithTokenSaver() {
        // Background-await always; Distill only with Token Saver hint.
        let turnContext = "REMOTE CODE RESOLVED IDENTITY ONLY: @quinn is Quinn"
        let on = AgentRunRequest(threadId: AgentThreadID(), provider: .claude,
                                 model: "claude-opus-4-7", cwd: "/tmp", prompt: "hi",
                                 environment: [
                                    "RC_TOKEN_SAVER_DISTILL_HINT": "1",
                                    BotPeerDelegation.turnContextEnvironmentKey: turnContext,
                                 ])
        let aOn = ClaudeRunner.buildStreamingArgs(on)
        guard let idxOn = aOn.firstIndex(of: "--append-system-prompt") else {
            return XCTFail("Claude streaming runs must append a system prompt carrying the background-await rule")
        }
        let promptOn = aOn[aOn.index(after: idxOn)]
        XCTAssertTrue(promptOn.contains(BackgroundAwaitContinuation.awaitingMarker),
                      "appended system prompt must instruct the agent to self-declare a stall with the recovery marker")
        XCTAssertTrue(promptOn.contains(BotPeerDelegation.providerDirective))
        XCTAssertTrue(promptOn.contains(turnContext),
                      "Claude CLI must receive this turn's identity-only Bot context")
        XCTAssertTrue(promptOn.contains("| distill"),
                      "Token Saver on injects the `| distill` piping rule")
        XCTAssertEqual(promptOn.components(separatedBy: TokenSaverProviderSafetyABI.block).count - 1, 1,
                       "Claude CLI runtime context must carry the safety ABI exactly once without disk instructions")
        XCTAssertEqual(
            (AgentSkillInstaller.distillAgentInstructionsTemplate + "\n\n" + promptOn)
                .components(separatedBy: TokenSaverProviderSafetyABI.block).count - 1,
            1,
            "Claude CLI effective disk plus runtime context must carry the safety ABI exactly once"
        )

        let emptyEnv = AgentRunRequest(threadId: AgentThreadID(), provider: .claude,
                                  model: "claude-opus-4-7", cwd: "/tmp", prompt: "hi")
        let aEmpty = ClaudeRunner.buildStreamingArgs(emptyEnv)
        guard let idxEmpty = aEmpty.firstIndex(of: "--append-system-prompt") else {
            return XCTFail("system prompt must always be appended")
        }
        let promptEmpty = aEmpty[aEmpty.index(after: idxEmpty)]
        XCTAssertTrue(promptEmpty.contains(BackgroundAwaitContinuation.awaitingMarker),
                      "the background-await rule must be present on every Claude call")
        XCTAssertTrue(promptEmpty.contains(BotPeerDelegation.providerDirective))
        XCTAssertFalse(promptEmpty.contains("| distill"),
                       "Token Saver off must not inject Distill")
        XCTAssertFalse(promptEmpty.contains(TokenSaverProviderSafetyABI.block),
                       "Token Saver off must not inject safety ABI")
    }

    func test_mcpAvailabilityDirectiveRidesBothLiveClaudeRoutes() {
        // WHY: in --print / autonomous mode Claude preemptively declared a connected
        // OAuth MCP server (Linear) "unauthenticated / unavailable in this
        // non-interactive session" and returned BLOCKED WITHOUT ever calling the
        // tool — even though it had loaded `mcp__linear__get_issue` via ToolSearch
        // and the cached token works headlessly. The corrective rule must ride EVERY
        // Claude turn on BOTH live routes (CLI streaming + SDK bridge) from one
        // shared source (`alwaysOnClaudeDirectives`) so the two routes cannot drift.
        // Asserts the LIVE builder `buildStreamingArgs` and `claudeSystemPrompt`,
        // never the dead `buildArgs` (unused for turns), so a green test is meaningful.
        let request = req()
        let cliArgs = ClaudeRunner.buildStreamingArgs(request)
        guard let idx = cliArgs.firstIndex(of: "--append-system-prompt") else {
            return XCTFail("streaming runs must append a system prompt carrying the MCP-availability rule")
        }
        let cliPrompt = cliArgs[cliArgs.index(after: idx)]
        XCTAssertTrue(cliPrompt.contains(BackgroundAwaitContinuation.mcpToolAvailabilityDirective),
                      "the live CLI streaming route must carry the MCP-availability rule so the agent stops preemptively refusing connected MCP tools")

        let sdkPrompt = ClaudeAgentSDKBridgeAdapter.claudeSystemPrompt(environment: request.environment)
        XCTAssertTrue(sdkPrompt.contains(BackgroundAwaitContinuation.mcpToolAvailabilityDirective),
                      "the SDK bridge route must carry the identical MCP-availability rule (both routes share one source so they cannot drift)")
        XCTAssertTrue(sdkPrompt.contains(BotPeerDelegation.providerDirective))
        let turnContext = "REMOTE CODE RESOLVED IDENTITY ONLY: @quinn is Quinn"
        XCTAssertFalse(
            ClaudeAgentSDKBridgeAdapter.claudeSystemPrompt(environment: [
                BotPeerDelegation.turnContextEnvironmentKey: turnContext,
            ]).contains(turnContext),
            "identity metadata must ride the individual SDK turn instead of freezing into the long-lived session prompt"
        )

        XCTAssertTrue(BackgroundAwaitContinuation.alwaysOnClaudeDirectives.contains(BackgroundAwaitContinuation.awaitingMarker),
                      "the shared directive bundle must retain the background-await rule alongside the new MCP rule")
    }

    func test_modelAndPromptPlacement() {
        let a = ClaudeRunner.buildArgs(req())
        let m = a.firstIndex(of: "--model")!
        XCTAssertEqual(a[a.index(after: m)], "claude-opus-4-7")
        XCTAssertTrue(a.last?.contains("Default mode.") == true,
                      "the prompt must be the final positional arg with default-mode provider instructions")
        XCTAssertTrue(a.last?.contains("hello world") == true)
    }

    func test_permissionMapping() {
        func mode(_ p: AgentPermissionMode) -> String {
            let a = ClaudeRunner.buildArgs(req(p))
            return a[a.index(after: a.firstIndex(of: "--permission-mode")!)]
        }
        XCTAssertEqual(mode(.supervised), "default")
        XCTAssertEqual(mode(.autoAcceptEdits), "acceptEdits")
        XCTAssertEqual(mode(.fullAccess), "bypassPermissions")
    }

    func test_resumePassesProviderThreadId() {
        let a = ClaudeRunner.buildArgs(req(.supervised, resume: "thread-abc"))
        let r = a.firstIndex(of: "--resume")!
        XCTAssertEqual(a[a.index(after: r)], "thread-abc")
    }

    func test_listModels_exposeClaudeOptionDescriptorsWithoutCodexFastTier() async {
        let models = await ClaudeRunner().listModels()
        let fable = models.first { $0.id == "fable" }

        XCTAssertEqual(models.first?.id, "fable",
                       "Claude fallback model options must lead with the current flagship alias instead of a hardcoded dated model id")
        XCTAssertEqual(fable?.supportedReasoningEfforts, AgentReasoningEffort.claudeSupportedCases,
                       "Claude thinking-capable models must advertise the legal effort picker values, including Max")
        let sonnet = models.first { $0.id == "sonnet" }
        XCTAssertEqual(sonnet?.supportedReasoningEfforts, AgentReasoningEffort.claudeSupportedCases,
                       "the bare Sonnet alias currently resolves to Sonnet 5, which supports xhigh and max")
        XCTAssertEqual(models.first { $0.id == "haiku" }?.supportedReasoningEfforts, [],
                       "Haiku has no configurable thinking effort")
        XCTAssertFalse(fable?.supportsServiceTier == true,
                       "Claude models must not expose Codex-only fast service-tier controls")
        XCTAssertTrue(fable?.supportsCustomModel == true)
    }

    func test_anthropicModelDiscoveryParsesDynamicModels() {
        let models = AnthropicModelDiscovery.modelDescriptors(fromListResponse: [
            "data": [
                [
                    "id": "claude-opus-4-8",
                    "display_name": "Claude Opus 4.8",
                    "type": "model"
                ],
                [
                    "id": "claude-opus-4-6",
                    "display_name": "Claude Opus 4.6",
                    "type": "model"
                ],
                [
                    "id": "claude-sonnet-4-6",
                    "display_name": "Claude Sonnet 4.6",
                    "type": "model"
                ],
                [
                    "id": "claude-opus-5",
                    "display_name": "Claude Opus 5",
                    "type": "model"
                ],
                [
                    "id": "claude-mythos-5",
                    "display_name": "Claude Mythos 5",
                    "type": "model"
                ],
                [
                    "id": "claude-mythos-preview",
                    "display_name": "Claude Mythos Preview",
                    "type": "model"
                ],
                [
                    "id": "claude-haiku-4-5",
                    "display_name": "Claude Haiku 4.5",
                    "type": "model"
                ],
                [
                    "id": "text-embedding-3-large",
                    "display_name": "Embedding",
                    "type": "model"
                ]
            ]
        ])
        XCTAssertEqual(models.map(\.id), [
            "claude-opus-4-8", "claude-opus-4-6", "claude-sonnet-4-6",
            "claude-opus-5", "claude-mythos-5", "claude-mythos-preview",
            "claude-haiku-4-5"
        ],
                       "Claude model discovery must accept the Anthropic Models API response instead of relying on bundled model IDs")
        XCTAssertEqual(models.first?.supportedReasoningEfforts, AgentReasoningEffort.claudeSupportedCases)
        let legacy46Efforts: [AgentReasoningEffort] = [.low, .medium, .high, .max]
        XCTAssertEqual(models.first { $0.id == "claude-opus-4-6" }?.supportedReasoningEfforts, legacy46Efforts)
        XCTAssertEqual(models.first { $0.id == "claude-sonnet-4-6" }?.supportedReasoningEfforts, legacy46Efforts)
        XCTAssertEqual(models.first { $0.id == "claude-opus-5" }?.supportedReasoningEfforts,
                       AgentReasoningEffort.claudeSupportedCases)
        XCTAssertEqual(models.first { $0.id == "claude-mythos-5" }?.supportedReasoningEfforts,
                       AgentReasoningEffort.claudeSupportedCases)
        XCTAssertEqual(models.first { $0.id == "claude-mythos-preview" }?.supportedReasoningEfforts,
                       legacy46Efforts)
        XCTAssertEqual(models.first { $0.id == "claude-haiku-4-5" }?.supportedReasoningEfforts, [])
        XCTAssertTrue(models.allSatisfy(\.supportsCustomModel))
    }

    func test_listModels_fallbackDoesNotDependOnInstalledCliVersion() {
        let oldIds = ClaudeRunner.listModels(installedVersion: "Claude Code 1.5.0").map(\.id)
        let newIds = ClaudeRunner.listModels(installedVersion: "Claude Code 2.1.0").map(\.id)
        let unknownIds = ClaudeRunner.listModels(installedVersion: "Claude Code dev").map(\.id)

        XCTAssertEqual(oldIds, ["fable", "opus", "sonnet", "haiku"],
                       "fallback Claude options must be versionless aliases, not dated model IDs that go stale")
        XCTAssertEqual(newIds, oldIds)
        XCTAssertEqual(unknownIds, newIds,
                       "unparseable dev/nightly versions should preserve alias-based options instead of hiding legal account models")
    }

    func test_effortAlwaysForwarded() {
        func eff(_ e: AgentReasoningEffort?) -> String {
            let r = AgentRunRequest(threadId: AgentThreadID(), provider: .claude,
                                    model: "opus", cwd: "/tmp", prompt: "x",
                                    permissionMode: .supervised, reasoningEffort: e)
            let a = ClaudeRunner.buildArgs(r)
            return a[a.index(after: a.firstIndex(of: "--effort")!)]
        }
        XCTAssertEqual(eff(.minimal), "low")
        XCTAssertEqual(eff(.low), "low")
        XCTAssertEqual(eff(.medium), "medium")
        XCTAssertEqual(eff(.high), "high")
        XCTAssertEqual(eff(.xhigh), "xhigh", "Extra High must use Claude's native xhigh effort flag")
        XCTAssertEqual(eff(.max), "max", "Max must use Claude's native max effort flag")
        XCTAssertEqual(eff(.ultracode), "ultracode",
                       "Claude Code 2.1.203+ accepts ultracode as a native effort value")
        XCTAssertEqual(eff(nil), "medium", "no effort → a sane default, never omitted")
    }

    func test_effortIsNormalizedToTheSelectedClaudeModel() throws {
        func effortFlag(model: String, effort: AgentReasoningEffort) -> String? {
            let request = AgentRunRequest(
                threadId: AgentThreadID(), provider: .claude, model: model,
                cwd: "/tmp", prompt: "x", reasoningEffort: effort
            )
            let args = ClaudeRunner.buildArgs(request)
            guard let index = args.firstIndex(of: "--effort") else { return nil }
            return args[args.index(after: index)]
        }

        XCTAssertEqual(effortFlag(model: "claude-opus-4-7", effort: .xhigh), "xhigh")
        XCTAssertEqual(effortFlag(model: "claude-opus-5", effort: .xhigh), "xhigh")
        XCTAssertEqual(effortFlag(model: "claude-mythos-5", effort: .max), "max")
        XCTAssertEqual(effortFlag(model: "sonnet", effort: .xhigh), "xhigh")
        XCTAssertEqual(effortFlag(model: "opus[1m]", effort: .max), "max")
        XCTAssertEqual(effortFlag(model: "sonnet[1m]", effort: .xhigh), "xhigh")
        XCTAssertEqual(effortFlag(model: "best", effort: .ultracode), "ultracode",
                       "official current aliases must retain the selected Claude effort")
        XCTAssertEqual(effortFlag(model: "claude-opus-4-6", effort: .xhigh), "high")
        XCTAssertEqual(effortFlag(model: "claude-sonnet-4-6", effort: .xhigh), "high")
        XCTAssertEqual(effortFlag(model: "claude-mythos-preview", effort: .max), "max")
        XCTAssertEqual(effortFlag(model: "claude-mythos-preview", effort: .xhigh), "high")
        XCTAssertEqual(effortFlag(model: "claude-opus-4-5", effort: .max), "high")
        XCTAssertNil(effortFlag(model: "claude-haiku-4-5", effort: .high),
                     "manual/stale Haiku selection must not emit an unsupported effort flag")
        XCTAssertNil(effortFlag(model: "claude-opus-4-1", effort: .high))
        XCTAssertNil(effortFlag(model: "claude-custom-future", effort: .high))

        let haikuArgs = ClaudeRunner.buildArgs(AgentRunRequest(
            threadId: AgentThreadID(), provider: .claude, model: "claude-haiku-4-5",
            cwd: "/tmp", prompt: "x", reasoningEffort: .high
        ))
        let settings = try parsedSettingsObject(haikuArgs)
        XCTAssertEqual(settings["alwaysThinkingEnabled"] as? Bool, true,
                       "Haiku still receives thinking enablement without a false effort tier")
    }

    private func ultracodeReq(_ effort: AgentReasoningEffort) -> AgentRunRequest {
        AgentRunRequest(threadId: AgentThreadID(), provider: .claude,
                        model: "opus", cwd: "/tmp", prompt: "build it",
                        permissionMode: .supervised, reasoningEffort: effort)
    }

    private func settingsValue(_ args: [String]) -> String? {
        guard let i = args.firstIndex(of: "--settings"), args.indices.contains(args.index(after: i)) else {
            return nil
        }
        return args[args.index(after: i)]
    }

    func test_ultracodeEnablesEffortAndWorkflowsViaSettings() {
        let args = ClaudeRunner.buildArgs(ultracodeReq(.ultracode))
        XCTAssertEqual(args[args.index(after: args.firstIndex(of: "--effort")!)], "ultracode",
                       "the CLI must receive its native Ultracode selector, which activates xhigh plus workflows")
        let settings = settingsValue(args)
        XCTAssertNotNil(settings, "Ultracode must inject --settings so the spawned session opts into ultracode")
        XCTAssertTrue(settings?.contains("\"ultracode\":true") == true,
                      "Ultracode must set the ultracode settings key the CLI documents for per-session activation")
        XCTAssertTrue(settings?.contains("\"enableWorkflows\":true") == true,
                      "the Workflow tool only appears when enableWorkflows is true, so ultracode must force it on")
    }

    func test_streamingUltracodeEnablesEffortAndWorkflowsViaSettings() {
        let args = ClaudeRunner.buildStreamingArgs(ultracodeReq(.ultracode))
        XCTAssertEqual(args[args.index(after: args.firstIndex(of: "--effort")!)], "ultracode")
        let settings = settingsValue(args)
        XCTAssertTrue(settings?.contains("\"ultracode\":true") == true)
        XCTAssertTrue(settings?.contains("\"enableWorkflows\":true") == true,
                      "durable streaming sessions must also opt into ultracode workflow orchestration")
    }

    func test_allEffortsEnableThinkingWithOneSettingsPayload() throws {
        for effort in [AgentReasoningEffort.low, .medium, .high, .xhigh, .max] {
            for args in [
                ClaudeRunner.buildArgs(ultracodeReq(effort)),
                ClaudeRunner.buildStreamingArgs(ultracodeReq(effort))
            ] {
                XCTAssertEqual(settingsFlagCount(args), 1,
                               "thinking, ultracode, and hooks must share one --settings payload")
                let settings = try parsedSettingsObject(args)
                XCTAssertEqual(settings["alwaysThinkingEnabled"] as? Bool, true,
                               "every Claude run must explicitly enable extended thinking")
                XCTAssertEqual(settings["showThinkingSummaries"] as? Bool, true,
                               "visible summaries are the only observable thinking evidence; hidden CoT is never claimed")
                let settingsEnvironment = try XCTUnwrap(settings["env"] as? [String: String])
                XCTAssertEqual(settingsEnvironment["CLAUDE_CODE_DISABLE_THINKING"], "0")
                XCTAssertEqual(settingsEnvironment["CLAUDE_CODE_EFFORT_LEVEL"], effort.rawValue)
                XCTAssertEqual(settingsEnvironment["DISABLE_INTERLEAVED_THINKING"], "0")
                XCTAssertEqual(settingsEnvironment["MAX_THINKING_TOKENS"], "32000")
                XCTAssertNil(settings["ultracode"],
                             "plain effort levels must not enable ultracode workflow orchestration")
            }
        }
    }

    func test_thinkingEnvironmentNeutralizesEveryDisablingBudgetAndPreservesPositive() throws {
        for invalidBudget in [nil, "0", "-1", "1", "1023", "garbage", "", "   "] as [String?] {
            var input = [
                "CLAUDE_CODE_DISABLE_THINKING": "1",
                "UNCHANGED": "yes"
            ]
            input["MAX_THINKING_TOKENS"] = invalidBudget

            let environment = ClaudeRunner.thinkingEnvironment(input)

            XCTAssertEqual(environment["CLAUDE_CODE_DISABLE_THINKING"], "0")
            XCTAssertEqual(
                environment["MAX_THINKING_TOKENS"],
                "32000",
                "Claude requires at least 1024 thinking tokens; invalid and subminimum budgets must use the safe default"
            )
            XCTAssertEqual(environment["UNCHANGED"], "yes")
        }

        for validBudget in ["1024", "4096"] {
            let positive = ClaudeRunner.thinkingEnvironment(["MAX_THINKING_TOKENS": validBudget])
            XCTAssertEqual(positive["MAX_THINKING_TOKENS"], validBudget,
                           "a valid explicit user budget must be preserved at and above Claude's minimum")
        }

        for inheritedEffort in ["low", "max", "garbage"] {
            let environment = ClaudeRunner.thinkingEnvironment([
                "CLAUDE_CODE_EFFORT_LEVEL": inheritedEffort,
                "DISABLE_INTERLEAVED_THINKING": "1",
                "UNCHANGED": "yes"
            ])
            XCTAssertNil(
                environment["CLAUDE_CODE_EFFORT_LEVEL"],
                "Claude's effort env overrides the explicit CLI/SDK session effort and must not leak through"
            )
            XCTAssertNil(environment["DISABLE_INTERLEAVED_THINKING"])
            XCTAssertEqual(environment["UNCHANGED"], "yes")
        }

        let finalEnvironment = CodexRunner.processEnvironment(
            overrides: ClaudeRunner.thinkingEnvironment([:]),
            purpose: .agentTurn(.claude),
            base: [
                "RC_LOGIN_SHELL_ENV_IMPORT": "0",
                "CLAUDE_CODE_EFFORT_LEVEL": "low",
                "DISABLE_INTERLEAVED_THINKING": "1",
                "UNCHANGED": "yes"
            ]
        )
        XCTAssertNil(finalEnvironment["CLAUDE_CODE_EFFORT_LEVEL"],
                     "the final subprocess environment must tombstone inherited effort overrides")
        XCTAssertNil(finalEnvironment["DISABLE_INTERLEAVED_THINKING"])
        XCTAssertEqual(finalEnvironment["CLAUDE_CODE_DISABLE_THINKING"], "0")
        XCTAssertEqual(finalEnvironment["MAX_THINKING_TOKENS"], "32000")
        XCTAssertEqual(finalEnvironment["UNCHANGED"], "yes")

        let positiveSettings = try parsedSettingsObject(ClaudeRunner.buildArgs(AgentRunRequest(
            threadId: AgentThreadID(), provider: .claude, model: "claude-opus-4-7",
            cwd: "/tmp", prompt: "x", reasoningEffort: .high,
            environment: ["MAX_THINKING_TOKENS": "4096"]
        )))
        XCTAssertEqual(
            (positiveSettings["env"] as? [String: String])?["MAX_THINKING_TOKENS"],
            "4096",
            "the high-precedence settings tombstone must preserve an explicit positive budget"
        )
        XCTAssertEqual(
            (positiveSettings["env"] as? [String: String])?["CLAUDE_CODE_EFFORT_LEVEL"],
            "high",
            "programmatic settings must align with the explicit effective effort so local settings cannot override it"
        )
    }

    func test_extraSettingsCannotDuplicateOrDisableThinking() throws {
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .claude,
            model: "claude-opus-4-7",
            cwd: "/tmp",
            prompt: "hello",
            reasoningEffort: .high,
            extraArgs: [
                "--settings", #"{"alwaysThinkingEnabled":false}"#,
                #"--settings={"showThinkingSummaries":false}"#,
                "--debug"
            ]
        )

        for args in [ClaudeRunner.buildArgs(request), ClaudeRunner.buildStreamingArgs(request)] {
            XCTAssertEqual(settingsFlagCount(args), 1,
                           "caller extra args must not add a second settings payload")
            XCTAssertFalse(args.contains { $0.hasPrefix("--settings=") },
                           "inline caller settings must not bypass the single-payload contract")
            let settings = try parsedSettingsObject(args)
            XCTAssertEqual(settings["alwaysThinkingEnabled"] as? Bool, true)
            XCTAssertEqual(settings["showThinkingSummaries"] as? Bool, true)
            XCTAssertTrue(args.contains("--debug"), "unrelated extra args must be preserved")
        }
    }

    // MARK: - Token Saver CLI PostToolUse hook registration

    private func postToolUseReq(
        effort: AgentReasoningEffort? = nil,
        postToolUse: Bool,
        threadId: AgentThreadID = AgentThreadID()
    ) -> AgentRunRequest {
        AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "opus",
            cwd: "/tmp",
            prompt: "build it",
            permissionMode: .supervised,
            reasoningEffort: effort,
            environment: postToolUse ? [ClaudeRunner.tokenSaverPostToolUseEnvKey: "1"] : [:]
        )
    }

    private func parsedSettingsObject(_ args: [String]) throws -> [String: Any] {
        guard let raw = settingsValue(args) else {
            throw NSError(domain: "ClaudeRunnerArgsTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "missing --settings value"])
        }
        let data = Data(raw.utf8)
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else {
            throw NSError(domain: "ClaudeRunnerArgsTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "settings JSON is not an object"])
        }
        return dict
    }

    private func settingsFlagCount(_ args: [String]) -> Int {
        args.filter { $0 == "--settings" }.count
    }

    private func expectedDistillHookCommand() -> String {
        AgentSkillInstaller.defaultManagedCLIBinDirectory()
            .appendingPathComponent("distill")
            .path + " hook post-tool-use"
    }

    /// (a) Flag absent + non-ultracode → thinking still has one settings payload;
    /// enabling the hook only replaces that payload rather than appending another.
    func test_postToolUseFlagAbsent_nonUltracodeKeepsSingleThinkingSettingsPayload() throws {
        // Stable thread id so --session-id does not confound byte comparison.
        let threadId = AgentThreadID(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        let baselineReq = postToolUseReq(effort: .high, postToolUse: false, threadId: threadId)
        let baseline = ClaudeRunner.buildStreamingArgs(baselineReq)
        let again = ClaudeRunner.buildStreamingArgs(baselineReq)

        XCTAssertEqual(settingsFlagCount(baseline), 1)
        let baselineSettings = try parsedSettingsObject(baseline)
        XCTAssertEqual(baselineSettings["alwaysThinkingEnabled"] as? Bool, true)
        XCTAssertEqual(baselineSettings["showThinkingSummaries"] as? Bool, true)
        XCTAssertNil(baselineSettings["hooks"])
        XCTAssertEqual(baseline, again, "builder must be pure: identical inputs → identical argv")

        let withFlag = ClaudeRunner.buildStreamingArgs(
            postToolUseReq(effort: .high, postToolUse: true, threadId: threadId)
        )
        XCTAssertEqual(settingsFlagCount(withFlag), 1,
                       "PostToolUse must merge into the existing thinking settings payload")
    }

    /// (b) Flag present + non-ultracode → exactly one --settings JSON with the
    /// PostToolUse command hook (resolved managed distill path + timeout 45).
    func test_postToolUseFlagPresent_nonUltracodeRegistersSingleSettingsHook() throws {
        let args = ClaudeRunner.buildStreamingArgs(postToolUseReq(effort: .high, postToolUse: true))
        XCTAssertEqual(settingsFlagCount(args), 1,
                       "must emit exactly one --settings (never two)")
        let settings = try parsedSettingsObject(args)
        XCTAssertEqual(settings["alwaysThinkingEnabled"] as? Bool, true)
        XCTAssertEqual(settings["showThinkingSummaries"] as? Bool, true)
        XCTAssertNil(settings["ultracode"],
                     "non-ultracode effort must not inject ultracode keys")
        XCTAssertNil(settings["enableWorkflows"],
                     "non-ultracode effort must not inject enableWorkflows")

        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any],
                                  "settings must register hooks")
        let postToolUse = try XCTUnwrap(hooks["PostToolUse"] as? [[String: Any]],
                                        "must register PostToolUse")
        XCTAssertEqual(postToolUse.count, 1)
        XCTAssertEqual(postToolUse[0]["matcher"] as? String, "*")
        let commandHooks = try XCTUnwrap(postToolUse[0]["hooks"] as? [[String: Any]])
        XCTAssertEqual(commandHooks.count, 1)
        XCTAssertEqual(commandHooks[0]["type"] as? String, "command")
        XCTAssertEqual(commandHooks[0]["command"] as? String, expectedDistillHookCommand(),
                       "hook command must be managed distill path + hook post-tool-use args")
        // JSONSerialization may box Int as NSNumber; accept numeric 45.
        let timeout = commandHooks[0]["timeout"] as? NSNumber
        XCTAssertEqual(timeout?.intValue, 45,
                       "PostToolUse command hook timeout must be 45 seconds for nested large tools")

        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]],
                                       "Token Saver must also register Bash PreToolUse auto-pipe")
        XCTAssertEqual(preToolUse[0]["matcher"] as? String, "Bash")
        let preHooks = try XCTUnwrap(preToolUse[0]["hooks"] as? [[String: Any]])
        XCTAssertEqual(
            preHooks[0]["command"] as? String,
            AgentSkillInstaller.defaultManagedCLIBinDirectory()
                .appendingPathComponent("distill").path + " hook pre-tool-pipe"
        )
    }

    /// (c) Flag present AND engine .ultracode → exactly one --settings containing
    /// BOTH the PostToolUse hook and the existing ultracode keys.
    func test_postToolUseFlagPresent_ultracodeMergesHookAndUltracodeKeys() throws {
        let args = ClaudeRunner.buildStreamingArgs(postToolUseReq(effort: .ultracode, postToolUse: true))
        XCTAssertEqual(settingsFlagCount(args), 1,
                       "ultracode + PostToolUse must merge into a single --settings payload")
        let settings = try parsedSettingsObject(args)
        XCTAssertEqual(settings["ultracode"] as? Bool, true,
                       "ultracode key must survive the merge")
        XCTAssertEqual(settings["enableWorkflows"] as? Bool, true,
                       "enableWorkflows must survive the merge so the Workflow tool stays exposed")

        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let postToolUse = try XCTUnwrap(hooks["PostToolUse"] as? [[String: Any]])
        let commandHooks = try XCTUnwrap(postToolUse[0]["hooks"] as? [[String: Any]])
        XCTAssertEqual(commandHooks[0]["command"] as? String, expectedDistillHookCommand())
        XCTAssertEqual((commandHooks[0]["timeout"] as? NSNumber)?.intValue, 45)

        // SDK bridge takes .last of ultracodeSettingsArgs — still the JSON string.
        let settingsArgs = ClaudeRunner.ultracodeSettingsArgs(
            .ultracode,
            environment: [ClaudeRunner.tokenSaverPostToolUseEnvKey: "1"]
        )
        XCTAssertEqual(settingsArgs.first, "--settings")
        XCTAssertEqual(settingsArgs.last, settingsValue(args),
                       "`.last` must remain the JSON payload so ClaudeAgentSDKBridgeAdapter keeps working")
        XCTAssertEqual(settingsArgs.count, 2)
    }

    func test_ultracodeIsOfferedToClaudeButNotCodexPicker() {
        XCTAssertTrue(AgentReasoningEffort.claudeSupportedCases.contains(.ultracode),
                      "Claude reasoning models must offer Ultracode in the effort picker")
        XCTAssertFalse(AgentReasoningEffort.supportedCases.contains(.ultracode),
                       "Codex falls back to supportedCases and the codex CLI has no ultracode; it must stay Claude-only")
        XCTAssertEqual(AgentReasoningEffort.ultracode.displayName, "Ultracode")
    }

    func test_xhighEffortDoesNotRewritePromptWithThinkingHack() {
        let request = AgentRunRequest(threadId: AgentThreadID(), provider: .claude,
                                      model: "opus", cwd: "/tmp", prompt: "solve deeply",
                                      permissionMode: .supervised, reasoningEffort: .xhigh)
        let args = ClaudeRunner.buildArgs(request)
        XCTAssertFalse(args.last?.hasPrefix("ultrathink\n\n") == true,
                       "Extra High must use the provider flag instead of mutating the user's prompt")
        XCTAssertTrue(args.last?.contains("solve deeply") == true)
    }

    func test_planModeWrapsPromptWithProviderInstructions() {
        let request = AgentRunRequest(threadId: AgentThreadID(), provider: .claude,
                                      model: "claude-opus-4-7", cwd: "/tmp",
                                      prompt: "inspect first", interactionMode: .plan)
        let args = ClaudeRunner.buildArgs(request)
        let mode = args[args.index(after: args.firstIndex(of: "--permission-mode")!)]
        XCTAssertEqual(mode, "plan",
                       "Claude plan mode must use the provider-level permission mode, not only local prompt wrapping")
        XCTAssertTrue(args.last?.contains("Plan mode.") == true,
                      "plan mode must reach Claude as provider instructions, not only toggle local UI")
        XCTAssertTrue(args.last?.contains("Do not edit files") == true)
        XCTAssertTrue(args.last?.contains("ExitPlanMode") == true,
                      "Claude plan mode must tell provider-native planning tools to emit one final plan artifact")
        XCTAssertTrue(args.last?.contains("then wait") == true,
                      "after a plan artifact, Claude must not continue into implementation inside the same run")
        XCTAssertTrue(args.last?.contains("inspect first") == true)
    }

    func test_defaultModeWrapsPromptWithProviderInstructions() {
        let args = ClaudeRunner.buildArgs(req())
        XCTAssertTrue(args.last?.contains("Default mode.") == true)
        XCTAssertTrue(args.last?.contains("preserve unrelated work") == true)
        XCTAssertTrue(args.last?.contains("verify") == true)
        XCTAssertTrue(args.last?.contains("hello world") == true)
    }

    func test_stderrClassifierSuppressesBenignClaudeNoiseButKeepsFatalTransportErrors() {
        XCTAssertFalse(ClaudeRunner.shouldDisplayStderr("Warning: Claude Code update available\n"),
                       "benign Claude stderr warnings must not appear as failed agent work")
        XCTAssertFalse(ClaudeRunner.shouldDisplayStderr("deprecated setting ignored\n"),
                       "deprecation noise must not interrupt long-running Agent App sessions")

        let fatal = ClaudeRunner.displayableStderr("authentication error: session expired\n")
        XCTAssertEqual(fatal, "authentication error: session expired",
                       "fatal Claude stderr must stay visible so provider loss does not look like an app freeze")
    }

    func test_fatalClaudeStderrBuildsProviderRuntimeEvidence() {
        let event = ProviderStderrClassifier.runtimeEvent(
            message: "authentication error: session expired",
            provider: .claude,
            source: "claude.stream-json.stderr"
        )

        XCTAssertEqual(event.method, "stderr.fatal")
        XCTAssertEqual(event.source, "claude.stream-json.stderr")
        XCTAssertTrue(event.payloadJSON.contains("session expired"),
                      "fatal Claude stderr must be stored as raw provider runtime evidence for later debugging")
    }

    func test_interpretStreamJSONLine_decodesJSONOnce() {
        // WHY: emitLine used to JSONSerialization via fromJSONLine and again
        // in ClaudeParser.parseLine on every stream-json token.
        let parser = ClaudeParser()
        _ = parser.parseObject([
            "type": "system", "subtype": "init", "session_id": "sid",
        ], now: 1)
        _ = parser.parseObject([
            "type": "message_start", "message": ["id": "m1"],
        ], now: 1)
        _ = parser.parseObject([
            "type": "content_block_start",
            "index": 0,
            "content_block": ["type": "text", "id": "item0"],
        ], now: 1)
        ClaudeRunner.streamJSONDecodeCountForTesting = 0
        let line = #"{"type":"content_block_delta","index":0,"session_id":"sid","delta":{"type":"text_delta","text":"Hi"}}"#
        let interpreted = ClaudeRunner.interpretStreamJSONLine(line, parser: parser, receivedAtMs: 1)
        XCTAssertEqual(
            ClaudeRunner.streamJSONDecodeCountForTesting, 1,
            "runtime + parser must share one JSONSerialization"
        )
        XCTAssertNil(
            interpreted.runtimeEvent,
            "token-rate deltas must not mint providerRuntime; itemDelta is the product event"
        )
        XCTAssertTrue(
            interpreted.parsedEvents.contains { event in
                if case .itemDelta(_, let body, _, _) = event { return body == "Hi" }
                return false
            },
            "decode-once must still surface the text delta: \(interpreted.parsedEvents)"
        )
    }

    func test_highFrequencyStreamingTypesSkipProviderRuntime() {
        // WHY: interpretStreamJSONLine used to fromJSONObject every stream-json
        // line. content_block_delta (and SDK stream_event wrappers) fire at
        // token rate; each one JSONSerialization.data(.sortedKeys) then
        // persistStream + EventBus EventLog. itemDelta already carries the
        // bytes. Lifecycle types stay.
        XCTAssertFalse(ProviderRuntimeEvent.shouldEmitFromDecodedStreamObject(
            ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "x"]]
        ))
        XCTAssertFalse(ProviderRuntimeEvent.shouldEmitFromDecodedStreamObject(
            ["type": "input_json_delta", "partial_json": "{"]
        ))
        XCTAssertFalse(ProviderRuntimeEvent.shouldEmitFromDecodedStreamObject(
            ["type": "ping"]
        ))
        XCTAssertFalse(ProviderRuntimeEvent.shouldEmitFromDecodedStreamObject([
            "type": "stream_event",
            "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "x"]],
        ]))
        XCTAssertTrue(
            ProviderRuntimeEvent.shouldEmitFromDecodedStreamObject(["type": "system", "subtype": "init"]),
            "system init is lifecycle and still needs the raw provider payload"
        )
        XCTAssertTrue(ProviderRuntimeEvent.shouldEmitFromDecodedStreamObject(["type": "result"]))
        XCTAssertTrue(ProviderRuntimeEvent.shouldEmitFromDecodedStreamObject([
            "type": "stream_event",
            "event": ["type": "content_block_start", "index": 0],
        ]), "non-delta stream_event wrappers still emit providerRuntime")
        XCTAssertTrue(ProviderRuntimeEvent.shouldEmitFromDecodedStreamObject(["type": "assistant"]))

        let parser = ClaudeParser()
        _ = parser.parseObject(["type": "system", "subtype": "init", "session_id": "sid"], now: 1)
        let lifecycle = ClaudeRunner.interpretStreamJSONLine(
            #"{"type":"system","subtype":"init","session_id":"sid"}"#,
            parser: parser,
            receivedAtMs: 1
        )
        XCTAssertEqual(lifecycle.runtimeEvent?.method, "system")
        XCTAssertEqual(lifecycle.runtimeEvent?.source, "claude.stream-json")
    }
}
