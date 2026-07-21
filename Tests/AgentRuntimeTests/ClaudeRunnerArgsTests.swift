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

    func test_streamingAlwaysAppendsBackgroundAwaitDirective_andDistillOnlyWithTokenSaver() {
        // UX-MAC_AGENT-BG-AWAIT: the background-await self-declaration rule must ride
        // in the system prompt on EVERY Claude run (independent of Token Saver) so the
        // agent marks any unavoidable wait with the recovery marker. Token Saver's
        // distill rules ride in the SAME `--append-system-prompt` value when on.
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
                      "with Token Saver on, the same appended prompt must also carry the `| distill` piping rule")
        XCTAssertEqual(promptOn.components(separatedBy: TokenSaverProviderSafetyABI.block).count - 1, 1,
                       "Claude CLI runtime context must carry the safety ABI exactly once without disk instructions")
        XCTAssertEqual(
            (AgentSkillInstaller.distillAgentInstructionsTemplate + "\n\n" + promptOn)
                .components(separatedBy: TokenSaverProviderSafetyABI.block).count - 1,
            1,
            "Claude CLI effective disk plus runtime context must carry the safety ABI exactly once"
        )

        let off = AgentRunRequest(threadId: AgentThreadID(), provider: .claude,
                                  model: "claude-opus-4-7", cwd: "/tmp", prompt: "hi")
        let aOff = ClaudeRunner.buildStreamingArgs(off)
        guard let idxOff = aOff.firstIndex(of: "--append-system-prompt") else {
            return XCTFail("even with Token Saver off, the background-await rule must still be appended")
        }
        let promptOff = aOff[aOff.index(after: idxOff)]
        XCTAssertTrue(promptOff.contains(BackgroundAwaitContinuation.awaitingMarker),
                      "the background-await rule must be present regardless of Token Saver")
        XCTAssertFalse(promptOff.contains("| distill"),
                       "with Token Saver off (CLI uninstalled) the distill rules must NOT be appended")
        XCTAssertFalse(promptOff.contains(TokenSaverProviderSafetyABI.block),
                       "Claude CLI must not receive the Token Saver safety ABI when disabled")
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
