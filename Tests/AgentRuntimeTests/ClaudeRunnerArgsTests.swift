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

    func test_modelAndPromptPlacement() {
        let a = ClaudeRunner.buildArgs(req())
        let m = a.firstIndex(of: "--model")!
        XCTAssertEqual(a[a.index(after: m)], "claude-opus-4-7")
        XCTAssertTrue(a.last?.contains("You are in default mode inside the RemoteCode Agent App") == true,
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
        let opus = models.first { $0.id == "claude-opus-4-7" }
        let haiku = models.first { $0.id == "claude-haiku-4-5-20251001" }

        XCTAssertEqual(opus?.supportedReasoningEfforts, AgentReasoningEffort.supportedCases,
                       "Claude thinking-capable models must advertise the legal effort picker values")
        XCTAssertFalse(opus?.supportsServiceTier == true,
                       "Claude models must not expose Codex-only fast service-tier controls")
        XCTAssertTrue(opus?.supportsCustomModel == true)
        XCTAssertEqual(haiku?.supportedReasoningEfforts, [],
                       "Claude models without thinking support must not render a reasoning picker")
    }

    func test_listModels_filtersNewerClaudeModelsByInstalledCliVersion() {
        let oldIds = ClaudeRunner.listModels(installedVersion: "Claude Code 1.5.0").map(\.id)
        let newIds = ClaudeRunner.listModels(installedVersion: "Claude Code 2.1.0").map(\.id)
        let unknownIds = ClaudeRunner.listModels(installedVersion: "Claude Code dev").map(\.id)

        XCTAssertEqual(oldIds, ["claude-haiku-4-5-20251001"],
                       "old Claude Code builds must not offer newer Opus/Sonnet ids that will fail only after the user starts a long run")
        XCTAssertTrue(newIds.contains("claude-opus-4-7"))
        XCTAssertTrue(newIds.contains("claude-sonnet-4-6"))
        XCTAssertEqual(unknownIds, newIds,
                       "unparseable dev/nightly versions should preserve the full custom-capable list instead of hiding legal account models")
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
        XCTAssertEqual(eff(nil), "medium", "no effort → a sane default, never omitted")
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
        XCTAssertTrue(args.last?.contains("You are in plan mode") == true,
                      "plan mode must reach Claude as provider instructions, not only toggle local UI")
        XCTAssertTrue(args.last?.contains("Do not edit files") == true)
        XCTAssertTrue(args.last?.contains("ExitPlanMode") == true,
                      "Claude plan mode must tell provider-native planning tools to emit one final plan artifact")
        XCTAssertTrue(args.last?.contains("stop and wait for the user") == true,
                      "after a plan artifact, Claude must not continue into implementation inside the same run")
        XCTAssertTrue(args.last?.contains("inspect first") == true)
    }

    func test_defaultModeWrapsPromptWithProviderInstructions() {
        let args = ClaudeRunner.buildArgs(req())
        XCTAssertTrue(args.last?.contains("You are in default mode inside the RemoteCode Agent App") == true)
        XCTAssertTrue(args.last?.contains("preserve unrelated local work") == true)
        XCTAssertTrue(args.last?.contains("verify the result") == true)
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
