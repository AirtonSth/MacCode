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
    }

    func test_streamingSessionResumeUsesProviderThreadId() {
        let a = ClaudeRunner.buildStreamingArgs(req(.supervised, resume: "claude-session-7"))
        XCTAssertEqual(a[a.index(after: a.firstIndex(of: "--resume")!)], "claude-session-7")
        XCTAssertNil(a.firstIndex(of: "--session-id"),
                     "resumed Claude streaming sessions must not also request a new session id")
    }

    func test_streamingTokenSaverHintAppendsDistillSystemPrompt() {
        let on = AgentRunRequest(threadId: AgentThreadID(), provider: .claude,
                                 model: "claude-opus-4-7", cwd: "/tmp", prompt: "hi",
                                 environment: ["RC_TOKEN_SAVER_DISTILL_HINT": "1"])
        let a = ClaudeRunner.buildStreamingArgs(on)
        guard let idx = a.firstIndex(of: "--append-system-prompt") else {
            return XCTFail("Token Saver on must append distill instructions to the streaming CLI system prompt so Claude pipes `| distill` and speaks distill language")
        }
        XCTAssertEqual(a[a.index(after: idx)], AgentSkillInstaller.distillAgentInstructionsBody,
                       "appended system prompt must be the canonical distill instructions, not an ad-hoc string")
        XCTAssertTrue(AgentSkillInstaller.distillAgentInstructionsBody.contains("| distill"),
                      "the injected body must carry the `| distill` piping rule")

        let off = AgentRunRequest(threadId: AgentThreadID(), provider: .claude,
                                  model: "claude-opus-4-7", cwd: "/tmp", prompt: "hi")
        XCTAssertNil(ClaudeRunner.buildStreamingArgs(off).firstIndex(of: "--append-system-prompt"),
                     "no Token Saver hint (CLI uninstalled) must leave the streaming system prompt untouched")
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
        let opus = models.first { $0.id == "opus" }

        XCTAssertEqual(models.first?.id, "opus",
                       "Claude fallback model options must use Claude Code's latest-model alias instead of a hardcoded dated model id")
        XCTAssertEqual(opus?.supportedReasoningEfforts, AgentReasoningEffort.claudeSupportedCases,
                       "Claude thinking-capable models must advertise the legal effort picker values, including Max")
        XCTAssertFalse(opus?.supportsServiceTier == true,
                       "Claude models must not expose Codex-only fast service-tier controls")
        XCTAssertTrue(opus?.supportsCustomModel == true)
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

        XCTAssertEqual(oldIds, ["opus", "sonnet", "haiku"],
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
