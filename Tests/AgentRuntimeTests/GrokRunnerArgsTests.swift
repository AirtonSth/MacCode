import XCTest
@testable import AgentRuntime
import CoreModel

/// Regression: Grok headless argv must match the official Build CLI
/// (`-p`, streaming-json, resume, permission-mode, model).
final class GrokRunnerArgsTests: XCTestCase {

    private func req(
        mode: AgentPermissionMode = .supervised,
        resume: String? = nil,
        model: String = "grok-4.5",
        interaction: AgentInteractionMode = .default,
        effort: AgentReasoningEffort? = .medium,
        environment: [String: String] = [:]
    ) -> AgentRunRequest {
        AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .grok,
            model: model,
            cwd: "/tmp",
            prompt: "hello world",
            providerThreadId: resume,
            permissionMode: mode,
            reasoningEffort: effort,
            interactionMode: interaction,
            environment: environment
        )
    }

    func test_tokenSaverSafetyABIIsInjectedExactlyOnceForGrokHeadless() {
        let args = GrokRunner.buildArgs(req(environment: ["RC_TOKEN_SAVER_DISTILL_HINT": "1"]))
        let prompt = args[args.index(after: args.firstIndex(of: "-p")!)]
        XCTAssertEqual(prompt.components(separatedBy: TokenSaverProviderSafetyABI.block).count - 1, 1)
        XCTAssertTrue(prompt.contains("| distill"))
        XCTAssertEqual(
            (AgentSkillInstaller.distillAgentInstructionsTemplate + "\n\n" + prompt)
                .components(separatedBy: TokenSaverProviderSafetyABI.block).count - 1,
            1,
            "Grok headless effective disk plus runtime context receives the safety ABI exactly once"
        )

        let disabledArgs = GrokRunner.buildArgs(req())
        let disabledPrompt = disabledArgs[disabledArgs.index(after: disabledArgs.firstIndex(of: "-p")!)]
        XCTAssertFalse(disabledPrompt.contains(TokenSaverProviderSafetyABI.block))
    }

    func test_headlessStreamingJsonFlags() {
        let a = GrokRunner.buildArgs(req())
        XCTAssertTrue(a.contains("-p"))
        let fmt = a.firstIndex(of: "--output-format")!
        XCTAssertEqual(a[a.index(after: fmt)], "streaming-json",
                       "Agent App depends on streaming-json for live transcript events")
        XCTAssertEqual(a[a.index(after: a.firstIndex(of: "-p")!)], a[1],
                       "prompt must ride on -p so the process exits after one turn")
        XCTAssertTrue(a[1].contains("hello world"))
        XCTAssertTrue(a[1].contains("Default mode."))
    }

    /// Token-level NDJSON lines are already parsed into Thought/answer items.
    /// Emitting them as providerRuntime floods Work log above the user message.
    func test_streamTokenLinesDoNotBecomeProviderRuntimeEvents() {
        XCTAssertNil(GrokRunner.providerRuntimeEventIfNeeded(
            line: #"{"type":"thought","data":"The"}"#,
            source: "grok.streaming-json"
        ), "thought tokens must not become Work log / runtime noise")
        XCTAssertNil(GrokRunner.providerRuntimeEventIfNeeded(
            line: #"{"type":"text","data":"hi"}"#,
            source: "grok.streaming-json"
        ), "text tokens must not become Work log / runtime noise")
        let end = GrokRunner.providerRuntimeEventIfNeeded(
            line: #"{"type":"end","stopReason":"EndTurn","sessionId":"s1"}"#,
            source: "grok.streaming-json"
        )
        XCTAssertEqual(end?.method, "end",
                       "lifecycle end events stay visible for debug/session resume diagnostics")
        let err = GrokRunner.providerRuntimeEventIfNeeded(
            line: #"{"type":"error","message":"auth"}"#,
            source: "grok.streaming-json"
        )
        XCTAssertEqual(err?.method, "error")
    }

    func test_modelAndPermissionMapping() {
        let a = GrokRunner.buildArgs(req(mode: .fullAccess, model: "grok-4.5"))
        XCTAssertEqual(a[a.index(after: a.firstIndex(of: "--model")!)], "grok-4.5")
        XCTAssertEqual(a[a.index(after: a.firstIndex(of: "--permission-mode")!)], "bypassPermissions")

        XCTAssertEqual(
            GrokRunner.buildArgs(req(mode: .autoAcceptEdits))[
                GrokRunner.buildArgs(req(mode: .autoAcceptEdits)).index(
                    after: GrokRunner.buildArgs(req(mode: .autoAcceptEdits)).firstIndex(of: "--permission-mode")!
                )
            ],
            "acceptEdits"
        )
        XCTAssertEqual(
            GrokRunner.buildArgs(req(mode: .supervised))[
                GrokRunner.buildArgs(req(mode: .supervised)).index(
                    after: GrokRunner.buildArgs(req(mode: .supervised)).firstIndex(of: "--permission-mode")!
                )
            ],
            "default"
        )
    }

    func test_planModeUsesPlanPermission() {
        let a = GrokRunner.buildArgs(req(interaction: .plan))
        XCTAssertEqual(a[a.index(after: a.firstIndex(of: "--permission-mode")!)], "plan")
    }

    func test_resumePassesProviderThreadId() {
        let a = GrokRunner.buildArgs(req(resume: "sess-xyz"))
        XCTAssertEqual(a[a.index(after: a.firstIndex(of: "--resume")!)], "sess-xyz",
                       "follow-up turns must resume the same Grok session for multi-turn context")
    }

    func test_newSessionIdIsChosenBeforeSpawn() {
        let sessionId = "11111111-2222-3333-4444-555555555555"
        let args = GrokRunner.buildArgs(req(), newSessionId: sessionId)
        XCTAssertEqual(args[args.index(after: args.firstIndex(of: "--session-id")!)], sessionId,
                       "AG-011: a first turn must have recoverable identity before any stdout/end event")
    }

    func test_terminalSignalWithoutUserCancelIsFailed() {
        XCTAssertEqual(GrokRunner.terminalStatus(cancelledByUser: false, terminationReason: .uncaughtSignal, exitStatus: 6), .failed)
        XCTAssertEqual(GrokRunner.terminalStatus(cancelledByUser: true, terminationReason: .uncaughtSignal, exitStatus: 15), .cancelled)
    }

    func test_emptyModelOmitsModelFlag() {
        let a = GrokRunner.buildArgs(req(model: ""))
        XCTAssertNil(a.firstIndex(of: "--model"),
                     "empty model means account default; do not pass a blank --model")
    }

    func test_reasoningEffortFlagMapsWireValuesOneToOne() {
        func wire(_ effort: AgentReasoningEffort) -> String {
            let a = GrokRunner.buildArgs(req(effort: effort))
            return a[a.index(after: a.firstIndex(of: "--reasoning-effort")!)]
        }
        XCTAssertEqual(wire(.minimal), "minimal")
        XCTAssertEqual(wire(.low), "low")
        XCTAssertEqual(wire(.medium), "medium")
        XCTAssertEqual(wire(.high), "high")
        XCTAssertEqual(wire(.xhigh), "xhigh",
                       "Grok CLI accepts xhigh; Extra High must not silently collapse to high")
        XCTAssertEqual(wire(.max), "max")
        XCTAssertEqual(wire(.ultracode), "high",
                       "ultracode is Claude-only; map to high so a stale picker value never rejects the run")
    }

    func test_composerModelOmitsReasoningEffortFlag() {
        let a = GrokRunner.buildArgs(req(model: "grok-composer-2.5-fast", effort: .high))
        XCTAssertNil(a.firstIndex(of: "--reasoning-effort"),
                     "Grok Composer has supports_reasoning_effort=false; do not pass --reasoning-effort")
    }

    func test_listModelsReasoningParityWithGrokCLICache() {
        let models = GrokRunner.listModels(installedVersion: nil)
        let fourFive = try! XCTUnwrap(models.first { $0.id == "grok-4.5" })
        XCTAssertTrue(fourFive.supportsReasoning)
        XCTAssertEqual(fourFive.supportedReasoningEfforts, [.low, .medium, .high],
                       "Grok 4.5 menu is low/medium/high only (no Extra High / xhigh in model menu)")

        let composer = try! XCTUnwrap(models.first { $0.id == "grok-composer-2.5-fast" })
        XCTAssertFalse(composer.supportsReasoning,
                       "Composer 2.5 Fast must hide the Reasoning effort picker")
        XCTAssertTrue(composer.supportedReasoningEfforts.isEmpty)

        let accountDefault = try! XCTUnwrap(models.first { $0.id == "" })
        XCTAssertEqual(accountDefault.supportedReasoningEfforts, [.low, .medium, .high])
    }

    func test_listModelsIncludesGrokDefaults() {
        let models = GrokRunner.listModels(installedVersion: nil)
        XCTAssertTrue(models.contains { $0.id == "grok-4.5" && $0.provider == .grok })
        XCTAssertTrue(models.contains { $0.provider == .grok && $0.supportsCustomModel })
    }

    func test_missingBinaryMessageNamesGrokInstall() {
        let msg = GrokRunner.missingBinaryMessage("grok")
        XCTAssertTrue(msg.contains("x.ai/cli/install.sh"),
                      "unavailable guidance must name the official Grok install path")
        XCTAssertTrue(msg.contains("grok"))
    }
}
