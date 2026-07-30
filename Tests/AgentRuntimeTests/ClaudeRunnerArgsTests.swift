import XCTest
@testable import AgentRuntime
import CoreModel

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
        let on = AgentRunRequest(threadId: AgentThreadID(), provider: .claude,
                                 model: "claude-opus-4-7", cwd: "/tmp", prompt: "hi",
                                 environment: ["RC_TOKEN_SAVER_DISTILL_HINT": "1"])
        let aOn = ClaudeRunner.buildStreamingArgs(on)
        guard let idxOn = aOn.firstIndex(of: "--append-system-prompt") else {
            return XCTFail("Claude streaming runs must append a system prompt carrying the background-await rule")
        }
        let promptOn = aOn[aOn.index(after: idxOn)]
        XCTAssertTrue(promptOn.contains(BackgroundAwaitContinuation.awaitingMarker),
                      "appended system prompt must instruct the agent to self-declare a stall with the recovery marker")
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
                    "id": "claude-sonnet-4-6",
                    "display_name": "Claude Sonnet 4.6",
                    "type": "model"
                ],
                [
                    "id": "text-embedding-3-large",
                    "display_name": "Embedding",
                    "type": "model"
                ]
            ]
        ])
        XCTAssertEqual(models.map(\.id), ["claude-opus-4-8", "claude-sonnet-4-6"],
                       "Claude model discovery must accept the Anthropic Models API response instead of relying on bundled model IDs")
        XCTAssertEqual(models.first?.supportedReasoningEfforts, AgentReasoningEffort.claudeSupportedCases)
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
        XCTAssertEqual(eff(.ultracode), "xhigh",
                       "Ultracode is not a --effort value (the CLI rejects it); it maps to xhigh effort")
        XCTAssertEqual(eff(nil), "medium", "no effort → a sane default, never omitted")
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
        XCTAssertEqual(args[args.index(after: args.firstIndex(of: "--effort")!)], "xhigh",
                       "Ultracode runs at xhigh effort")
        let settings = settingsValue(args)
        XCTAssertNotNil(settings, "Ultracode must inject --settings so the spawned session opts into ultracode")
        XCTAssertTrue(settings?.contains("\"ultracode\":true") == true,
                      "Ultracode must set the ultracode settings key the CLI documents for per-session activation")
        XCTAssertTrue(settings?.contains("\"enableWorkflows\":true") == true,
                      "the Workflow tool only appears when enableWorkflows is true, so ultracode must force it on")
    }

    func test_streamingUltracodeEnablesEffortAndWorkflowsViaSettings() {
        let args = ClaudeRunner.buildStreamingArgs(ultracodeReq(.ultracode))
        XCTAssertEqual(args[args.index(after: args.firstIndex(of: "--effort")!)], "xhigh")
        let settings = settingsValue(args)
        XCTAssertTrue(settings?.contains("\"ultracode\":true") == true)
        XCTAssertTrue(settings?.contains("\"enableWorkflows\":true") == true,
                      "durable streaming sessions must also opt into ultracode workflow orchestration")
    }

    func test_nonUltracodeEffortsNeverInjectSettings() {
        for effort in [AgentReasoningEffort.low, .medium, .high, .xhigh, .max] {
            XCTAssertNil(settingsValue(ClaudeRunner.buildArgs(ultracodeReq(effort))),
                         "\(effort) is a plain effort level and must not pollute the run with ultracode --settings")
            XCTAssertNil(settingsValue(ClaudeRunner.buildStreamingArgs(ultracodeReq(effort))),
                         "\(effort) streaming runs must not inject ultracode --settings")
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

    /// (a) Flag absent + non-ultracode → argv is byte-identical to the baseline
    /// that never injects `--settings` (HEAD behavior for the default `.cli` path).
    func test_postToolUseFlagAbsent_nonUltracodeArgvByteIdenticalToBaseline() {
        // Stable thread id so --session-id does not confound byte comparison.
        let threadId = AgentThreadID(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        let baselineReq = postToolUseReq(effort: .high, postToolUse: false, threadId: threadId)
        let baseline = ClaudeRunner.buildStreamingArgs(baselineReq)
        let again = ClaudeRunner.buildStreamingArgs(baselineReq)

        // Settings contribution is empty — the only mechanism that could inject
        // --settings for non-ultracode — so argv cannot gain new flags.
        XCTAssertEqual(
            ClaudeRunner.ultracodeSettingsArgs(.high, environment: [:]),
            [],
            "flag-absent non-ultracode must contribute zero argv tokens (HEAD-identical)"
        )
        XCTAssertNil(settingsValue(baseline),
                     "flag-absent non-ultracode streaming argv must not include --settings")
        XCTAssertEqual(baseline, again, "builder must be pure: identical inputs → identical argv")

        // Flag present only adds the single --settings pair; stripping it must
        // recover the flag-absent baseline byte-for-byte.
        let withFlag = ClaudeRunner.buildStreamingArgs(
            postToolUseReq(effort: .high, postToolUse: true, threadId: threadId)
        )
        var stripped = withFlag
        if let i = stripped.firstIndex(of: "--settings") {
            stripped.remove(at: stripped.index(after: i))
            stripped.remove(at: i)
        }
        XCTAssertEqual(
            stripped, baseline,
            "flag-absent argv must be byte-identical to flag-present argv with the --settings pair removed"
        )
    }

    /// (b) Flag present + non-ultracode → exactly one --settings JSON with the
    /// PostToolUse command hook (resolved managed distill path + timeout 10).
    func test_postToolUseFlagPresent_nonUltracodeRegistersSingleSettingsHook() throws {
        let args = ClaudeRunner.buildStreamingArgs(postToolUseReq(effort: .high, postToolUse: true))
        XCTAssertEqual(settingsFlagCount(args), 1,
                       "must emit exactly one --settings (never two)")
        let settings = try parsedSettingsObject(args)
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
        // JSONSerialization may box Int as NSNumber; accept numeric 10.
        let timeout = commandHooks[0]["timeout"] as? NSNumber
        XCTAssertEqual(timeout?.intValue, 10,
                       "PostToolUse command hook timeout must be 10 seconds")
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
        XCTAssertEqual((commandHooks[0]["timeout"] as? NSNumber)?.intValue, 10)

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
}
