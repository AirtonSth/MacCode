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

    func test_tokenSaverOnDoesNotRegisterGrokPostToolUseOutputRewrite() {
        // WHY: harvest has 680 large Grok `read_file`s (~11.7M chars). Claude
        // PostToolUse can replace Read via updatedToolOutput. Grok PostToolUse
        // stdout is ignored (official hooks guide). Do not invent that hook.
        let on = GrokRunner.buildArgs(req(environment: [
            "RC_TOKEN_SAVER_DISTILL_HINT": "1",
            ClaudeRunner.tokenSaverPostToolUseEnvKey: "1",
        ]))
        // Prompt text may mention PostToolUse as a ceiling; argv must not
        // register a Grok output-rewrite hook.
        XCTAssertFalse(on.contains { $0 == "--settings" || $0.hasPrefix("--settings=") })
        XCTAssertFalse(on.contains { $0.contains("hook post-tool-use") })
        XCTAssertFalse(on.contains { $0.contains("updatedToolOutput") })
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

        // Token Saver off → no Distill / safety ABI on Grok headless.
        let emptyEnvArgs = GrokRunner.buildArgs(req())
        let emptyEnvPrompt = emptyEnvArgs[emptyEnvArgs.index(after: emptyEnvArgs.firstIndex(of: "-p")!)]
        XCTAssertFalse(emptyEnvPrompt.contains(TokenSaverProviderSafetyABI.block))
        XCTAssertFalse(emptyEnvPrompt.contains("| distill"))
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
    /// Emitting them as providerRuntime floods Work log above the user message
    /// and used to JSONSerialization.data(.sortedKeys) before the drop.
    func test_streamTokenLinesDoNotBecomeProviderRuntimeEvents() {
        // WHY: providerRuntimeEventIfNeeded used to fromJSONObject then drop
        // thought/text. That still paid sortedKeys serialize + would persist
        // and EventBus if the drop were ever reordered. fromJSONObjectIfNeeded
        // refuses before serialize. itemDelta already carries the bytes.
        XCTAssertNil(GrokRunner.providerRuntimeEventIfNeeded(
            line: #"{"type":"thought","data":"The"}"#,
            source: "grok.streaming-json"
        ), "thought tokens must not become Work log / runtime noise")
        XCTAssertNil(GrokRunner.providerRuntimeEventIfNeeded(
            line: #"{"type":"text","data":"hi"}"#,
            source: "grok.streaming-json"
        ), "text tokens must not become Work log / runtime noise")
        XCTAssertTrue(GrokRunner.isTokenStreamMethod("thought"))
        XCTAssertTrue(GrokRunner.isTokenStreamMethod("text"))
        XCTAssertFalse(GrokRunner.isTokenStreamMethod("end"))
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

    func test_reasoningEffortFlagNormalizesToAdvertisedModelValues() {
        func wire(_ effort: AgentReasoningEffort, model: String = "grok-4.6") -> String {
            let a = GrokRunner.buildArgs(req(model: model, effort: effort))
            return a[a.index(after: a.firstIndex(of: "--reasoning-effort")!)]
        }
        XCTAssertEqual(wire(.minimal), "low",
                       "Grok 4.6 live catalog omits minimal; remap to low")
        XCTAssertEqual(wire(.low), "low")
        XCTAssertEqual(wire(.medium), "medium")
        XCTAssertEqual(wire(.high), "high")
        XCTAssertEqual(wire(.xhigh), "xhigh")
        XCTAssertEqual(wire(.max), "xhigh",
                       "Grok 4.6 does not advertise max; use its deepest supported level")
        XCTAssertEqual(wire(.ultracode), "xhigh")
        XCTAssertEqual(wire(.minimal, model: "grok-4.5"), "low",
                       "Grok 4.5 omits minimal; remap to low")
        XCTAssertEqual(wire(.xhigh, model: "grok-4.5"), "high")
        XCTAssertEqual(wire(.max, model: "grok-4.5"), "high",
                       "Grok 4.5 supports only low/medium/high")
    }

    func test_glmFlashPreservesMaxReasoningEffort() throws {
        let model = "glm-5.3-flash"
        XCTAssertEqual(
            GrokRunner.supportedReasoningEfforts(for: model),
            [.low, .medium, .high, .xhigh, .max]
        )
        let args = GrokRunner.buildArgs(req(model: model, effort: .max))
        let index = try XCTUnwrap(args.firstIndex(of: "--reasoning-effort"))
        XCTAssertEqual(args[index + 1], "max")
    }

    func test_composerModelOmitsReasoningEffortFlag() {
        let a = GrokRunner.buildArgs(req(model: "grok-composer-2.5-fast", effort: .high))
        XCTAssertNil(a.firstIndex(of: "--reasoning-effort"),
                     "Grok Composer has supports_reasoning_effort=false; do not pass --reasoning-effort")
    }

    func test_glmMediumWiresMediumNotMax() throws {
        // WHY: live grok 1.0.30 GLM aliases medium→high. Clamping missing
        // medium onto max over-reasons cheap turns.
        for model in ["glm-5.3", "glm-5.3-flash"] {
            let args = GrokRunner.buildArgs(req(model: model, effort: .medium))
            let index = try XCTUnwrap(args.firstIndex(of: "--reasoning-effort"))
            XCTAssertEqual(args[index + 1], "medium", model)
            XCTAssertEqual(GrokACPClient.wireReasoningEffort(.medium, modelId: model), "medium")
        }
    }

    func test_museSparkWiresXhigh() throws {
        let args = GrokRunner.buildArgs(req(model: "muse-spark-1.3-contributor", effort: .xhigh))
        let index = try XCTUnwrap(args.firstIndex(of: "--reasoning-effort"))
        XCTAssertEqual(args[index + 1], "xhigh")
        XCTAssertNil(
            GrokRunner.buildArgs(req(model: "qwen38-omlx", effort: .high))
                .firstIndex(of: "--reasoning-effort")
        )
    }

    func test_unknownCustomModelDoesNotInventReasoningContract() {
        let a = GrokRunner.buildArgs(req(model: "grok-custom-future", effort: .max))
        XCTAssertNil(a.firstIndex(of: "--reasoning-effort"),
                     "unknown Grok models must fail closed instead of inheriting Grok 4.5 limits")
    }

    func test_listModelsReasoningParityWithGrokCLICache() {
        let models = GrokRunner.listModels(installedVersion: nil)
        let fourSix = try! XCTUnwrap(models.first { $0.id == "grok-4.6" })
        XCTAssertEqual(fourSix.supportedReasoningEfforts, [.low, .medium, .high, .xhigh])
        let fourFive = try! XCTUnwrap(models.first { $0.id == "grok-4.5" })
        XCTAssertTrue(fourFive.supportsReasoning)
        XCTAssertEqual(fourFive.supportedReasoningEfforts, [.low, .medium, .high],
                       "Grok 4.5 menu is low/medium/high only (no Extra High / xhigh in model menu)")

        XCTAssertNil(models.first { $0.id == "grok-composer-2.5-fast" },
                     "live grok 1.0.30 no longer lists composer-fast")
        let glm = try! XCTUnwrap(models.first { $0.id == "glm-5.3" })
        XCTAssertEqual(glm.supportedReasoningEfforts, [.low, .medium, .high, .xhigh, .max])
        let muse = try! XCTUnwrap(models.first { $0.id == "muse-spark-1.3-contributor" })
        XCTAssertEqual(muse.supportedReasoningEfforts, [.low, .medium, .high, .xhigh])
        let qwen = try! XCTUnwrap(models.first { $0.id == "qwen38-omlx" })
        XCTAssertTrue(qwen.supportedReasoningEfforts.isEmpty)

        let accountDefault = try! XCTUnwrap(models.first { $0.id == "" })
        XCTAssertEqual(accountDefault.supportedReasoningEfforts, [.low, .medium, .high, .xhigh])
    }

    func test_listModelsIncludesGrokDefaults() {
        let models = GrokRunner.listModels(installedVersion: nil)
        XCTAssertEqual(models.first?.id, "grok-4.6")
        XCTAssertTrue(models.contains { $0.id == "grok-4.5" && $0.provider == .grok })
        XCTAssertTrue(models.contains { $0.provider == .grok && $0.supportsCustomModel })
    }

    func test_missingBinaryMessageNamesGrokInstall() {
        let msg = GrokRunner.missingBinaryMessage("grok")
        XCTAssertTrue(msg.contains("x.ai/cli/install.sh"),
                      "unavailable guidance must name the official Grok install path")
        XCTAssertTrue(msg.contains("grok"))
    }

    func test_interpretStreamJSONLine_decodesJSONOnce() {
        // WHY: emitLine used to JSONSerialization via fromJSONLine and again
        // in GrokParser.parseLine on every thought/text token.
        let parser = GrokParser()
        GrokRunner.streamJSONDecodeCountForTesting = 0
        let line = #"{"type":"text","data":"Hi"}"#
        let interpreted = GrokRunner.interpretStreamJSONLine(line, parser: parser, receivedAtMs: 1)
        XCTAssertEqual(
            GrokRunner.streamJSONDecodeCountForTesting, 1,
            "runtime filter + parser must share one JSONSerialization"
        )
        XCTAssertNil(interpreted.runtimeEvent, "pure text tokens must not flood Work log")
        XCTAssertTrue(
            interpreted.parsedEvents.contains { event in
                if case .itemDelta(_, let body, _, _) = event { return body == "Hi" }
                return false
            },
            "decode-once must still surface the text token: \(interpreted.parsedEvents)"
        )

        GrokRunner.streamJSONDecodeCountForTesting = 0
        let tool = GrokRunner.interpretStreamJSONLine(
            #"{"type":"tool_call","toolCallId":"t1"}"#,
            parser: GrokParser(),
            receivedAtMs: 1
        )
        XCTAssertEqual(GrokRunner.streamJSONDecodeCountForTesting, 1)
        XCTAssertEqual(tool.runtimeEvent?.method, "tool_call")
        XCTAssertEqual(tool.runtimeEvent?.source, "grok.streaming-json")
    }
}
