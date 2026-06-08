import XCTest
@testable import AgentRuntime
import CoreModel

/// A1: codex must resume by session id (so it keeps context), use the
/// account default model when none is chosen, and map effort/sandbox.
final class CodexRunnerArgsTests: XCTestCase {

    private func req(model: String = "", resume: String? = nil,
                     effort: AgentReasoningEffort? = .medium,
                     mode: AgentPermissionMode = .supervised,
                     serviceTier: AgentServiceTier = .auto) -> AgentRunRequest {
        AgentRunRequest(threadId: AgentThreadID(), provider: .codex,
                        model: model, cwd: "/tmp", prompt: "do it",
                        providerThreadId: resume, permissionMode: mode,
                        reasoningEffort: effort, serviceTier: serviceTier)
    }

    func test_freshRun_usesExecNotResume_andOmitsModelWhenDefault() {
        let a = CodexRunner.buildArgs(req())
        XCTAssertEqual(a.first, "exec")
        XCTAssertFalse(a.contains("resume"), "a first run must not be a resume")
        XCTAssertFalse(a.contains("--model"), "empty model → account default (no -m)")
        XCTAssertTrue(a.contains("--json") && a.contains("--skip-git-repo-check"))
        XCTAssertTrue(a.last?.contains("You are in default mode inside the RemoteCode Agent App") == true,
                      "Default Mode semantics must reach Codex, not only local UI state")
        XCTAssertTrue(a.last?.contains("do it") == true, "prompt is the final positional arg payload")
    }

    func test_resume_passesSessionIdBeforePromptAndDropsSandboxModel() {
        let a = CodexRunner.buildArgs(req(model: "gpt-5-codex", resume: "sess-99", mode: .fullAccess))
        XCTAssertEqual(Array(a.prefix(2)), ["exec", "resume"])
        XCTAssertEqual(a[a.count - 2], "sess-99")
        XCTAssertTrue(a.last?.contains("do it") == true,
                       "session id then prompt are the trailing positionals")
        XCTAssertFalse(a.contains("--sandbox"),
                       "`codex exec resume` rejects --sandbox (session keeps its own)")
        XCTAssertFalse(a.contains("--model"),
                       "`codex exec resume` rejects --model (session keeps its own)")
        XCTAssertTrue(a.contains("--json") && a.contains("--skip-git-repo-check"))
    }

    func test_imageAttachmentsUseNativeCodexImageFlagsBeforePrompt() {
        let image = AgentAttachment(path: "/tmp/screen.png", kind: .image, mimeType: "image/png")
        let text = AgentAttachment(path: "/tmp/notes.txt", kind: .file)
        let request = AgentRunRequest(threadId: AgentThreadID(), provider: .codex,
                                      model: "", cwd: "/tmp", prompt: "inspect",
                                      attachments: [image, text])

        let args = CodexRunner.buildArgs(request)

        let imageFlag = args.firstIndex(of: "--image")
        XCTAssertNotNil(imageFlag, "Codex image attachments must use the native --image channel")
        XCTAssertEqual(imageFlag.map { args[args.index(after: $0)] }, "/tmp/screen.png")
        XCTAssertFalse(args.contains("/tmp/notes.txt"),
                       "unsupported file attachments must not be smuggled into Codex argv as image inputs")
        XCTAssertEqual(args.last, request.providerPrompt)
    }

    func test_resumeImageAttachmentsStayBeforeSessionIdAndPrompt() {
        let request = AgentRunRequest(threadId: AgentThreadID(), provider: .codex,
                                      model: "", cwd: "/tmp", prompt: "inspect",
                                      attachments: [AgentAttachment(path: "/tmp/screen.png", kind: .image)],
                                      providerThreadId: "sess-99")

        let args = CodexRunner.buildArgs(request)

        XCTAssertLessThan(args.firstIndex(of: "--image")!, args.firstIndex(of: "sess-99")!,
                          "`codex exec resume` expects image flags before the session id positional")
        XCTAssertEqual(args[args.count - 2], "sess-99")
        XCTAssertEqual(args.last, request.providerPrompt)
    }

    func test_modelPassedWhenChosen_andEffortMapped() {
        let a = CodexRunner.buildArgs(req(model: "gpt-5-codex", effort: .high))
        let m = a.firstIndex(of: "--model")!
        XCTAssertEqual(a[a.index(after: m)], "gpt-5-codex")
        XCTAssertTrue(a.contains("-c") && a.contains(#"model_reasoning_effort="high""#),
                      "reasoning effort must be forwarded as a config override")
    }

    func test_sandboxByPermission() {
        XCTAssertTrue(CodexRunner.buildArgs(req(mode: .fullAccess)).contains("danger-full-access"))
        XCTAssertTrue(CodexRunner.buildArgs(req(mode: .autoAcceptEdits)).contains("workspace-write"))
        XCTAssertTrue(CodexRunner.buildArgs(req(mode: .supervised)).contains("read-only"))
    }

    func test_approvalPolicyByPermission() {
        XCTAssertTrue(CodexRunner.buildArgs(req(mode: .supervised)).contains(#"approval_policy="untrusted""#),
                      "supervised mode must keep Codex in approval-required mode instead of auto-running untrusted commands")
        XCTAssertTrue(CodexRunner.buildArgs(req(mode: .autoAcceptEdits)).contains(#"approval_policy="never""#),
                      "auto-accept-edits mode must let Codex run workspace-write commands without approval deadlocks")
        XCTAssertTrue(CodexRunner.buildArgs(req(mode: .fullAccess)).contains(#"approval_policy="never""#),
                      "full-access mode must not prompt for approvals after the user selects danger-full-access")
    }

    /// Regression: the picker once listed gpt-5 / gpt-5-codex / o3, which
    /// are dead on codex 0.130.0 — `codex --model <dead>` exits non-zero
    /// with no assistant output (the "Codex chat doesn't work" report).
    /// The list must be the real models and must NOT contain the dead ids.
    func test_listModels_areRealCodexIds_andOmitDeadOnes() async {
        let models = await CodexRunner().listModels()
        let ids = Set(models.map(\.id))
        XCTAssertTrue(ids.contains(""), "account default must stay (always works)")
        for real in ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini",
                     "gpt-5.3-codex", "gpt-5.3-codex-spark", "gpt-5.2"] {
            XCTAssertTrue(ids.contains(real), "missing real codex model \(real)")
        }
        for dead in ["gpt-5", "gpt-5-codex", "o3", "gpt-6"] {
            XCTAssertFalse(ids.contains(dead), "dead model id \(dead) must not be offered")
        }
    }

    func test_listModels_exposeCodexOptionDescriptors() async {
        let model = await CodexRunner().listModels().first { $0.id == "gpt-5.5" }

        XCTAssertEqual(model?.supportedReasoningEfforts, AgentReasoningEffort.supportedCases,
                       "Codex model metadata must tell clients exactly which reasoning efforts are legal")
        XCTAssertTrue(model?.supportsServiceTier == true,
                      "Codex model metadata must expose fast service-tier support instead of relying on provider-global UI guesses")
        XCTAssertTrue(model?.supportsCustomModel == true,
                      "Codex model metadata must allow custom account/model ids without losing the descriptor contract")
    }

    /// Codex accepts `model_reasoning_effort="xhigh"` (it is the value in
    /// the user's ~/.codex/config.toml). The enum must forward it verbatim.
    func test_xhighEffort_forwardedToCodex() {
        let a = CodexRunner.buildArgs(req(effort: .xhigh))
        XCTAssertTrue(a.contains(#"model_reasoning_effort="xhigh""#),
                      "Extra High must map to the codex xhigh effort")
    }

    func test_fastServiceTier_forwardedToCodexConfig() {
        let a = CodexRunner.buildArgs(req(serviceTier: .fast))
        XCTAssertTrue(a.contains(#"model_service_tier="fast""#),
                      "Fast mode must reach Codex as the service tier requested by t3code parity")
    }

    func test_supportedEfforts_omitMinimalRejectedByCodexCli() {
        XCTAssertEqual(AgentReasoningEffort.supportedCases, [.low, .medium, .high, .xhigh],
                       "Codex CLI rejects minimal; the picker must expose only efforts that run")
    }

    func test_processLocatorAcceptsAbsoluteExecutablePath() {
        XCTAssertEqual(ProcessLocator.resolve("/usr/bin/env"), "/usr/bin/env",
                       "CLI path settings must be able to point at a concrete executable, not only a name in PATH")
        XCTAssertNil(ProcessLocator.resolve("/no/such/codex"),
                     "CLI path settings must fail loud when the configured executable does not exist")
    }

    func test_processEnvironmentMergesProviderInstanceHomeWithoutDroppingPath() {
        let env = CodexRunner.processEnvironment(
            overrides: ["CODEX_HOME": "/tmp/codex-work", "REMOTE_CODE_INSTANCE": "work"],
            base: ["PATH": "/usr/bin", "HOME": "/tmp/remote-code-home", "CODEX_HOME": "/tmp/default"],
            provider: .codex
        )

        let path = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        XCTAssertEqual(path.first, "/tmp/remote-code-home/.remote-code/bin",
                       "RemoteCode-managed provider helpers such as distill must beat stale user/global CLIs on PATH")
        XCTAssertTrue(path.contains("/usr/bin"))
        XCTAssertTrue(path.contains("/opt/homebrew/bin"),
                      "Finder-launched macOS apps receive a minimal PATH; provider wrappers using /usr/bin/env node must still find Homebrew node")
        XCTAssertTrue(path.contains("/tmp/remote-code-home/.local/bin"),
                      "provider subprocesses must keep common user CLI install directories reachable when the app is launched from Finder")
        XCTAssertEqual(env["CODEX_HOME"], "/tmp/codex-work",
                       "provider instances must isolate Codex auth/session state by overriding CODEX_HOME per run")
        XCTAssertEqual(env["REMOTE_CODE_INSTANCE"], "work")
        XCTAssertEqual(env["REMOTE_CODE_AGENT_PROVIDER"], "codex",
                       "the managed distill CLI must attribute command-output savings to the active provider")
    }

    func test_processLocatorFallsBackToCommonUserCliDirectoriesWhenGuiPathIsLimited() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-code-locator-\(UUID().uuidString)")
        let bin = root.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let cli = bin.appendingPathComponent("claude")
        FileManager.default.createFile(atPath: cli.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            ProcessLocator.resolve("claude",
                                   environmentPath: "/usr/bin:/bin:/usr/sbin:/sbin",
                                   homeDirectory: root.path),
            cli.path,
            "macOS GUI launches often provide a limited PATH; agent CLIs installed in user bin dirs must still be discovered"
        )
    }

    func test_planModeWrapsPromptWithProviderInstructions() {
        let request = AgentRunRequest(threadId: AgentThreadID(), provider: .codex,
                                      model: "", cwd: "/tmp", prompt: "inspect first",
                                      interactionMode: .plan)
        let args = CodexRunner.buildArgs(request)
        XCTAssertTrue(args.last?.contains("You are in plan mode") == true,
                      "plan mode must reach Codex as provider instructions, not only toggle local UI")
        XCTAssertTrue(args.last?.contains("Do not edit files") == true)
        XCTAssertTrue(args.last?.contains("inspect first") == true)
    }

    func test_defaultModeWrapsPromptWithProviderInstructions() {
        let args = CodexRunner.buildArgs(req())
        XCTAssertTrue(args.last?.contains("You are in default mode inside the RemoteCode Agent App") == true)
        XCTAssertTrue(args.last?.contains("preserve unrelated local work") == true)
        XCTAssertTrue(args.last?.contains("verify the result") == true)
        XCTAssertTrue(args.last?.contains("do it") == true)
    }

    func test_stderrClassifierSuppressesBenignCodexNoiseButKeepsFatalTransportErrors() {
        XCTAssertFalse(CodexRunner.shouldDisplayStderr("Warning: codex updated in background\n"),
                       "benign Codex stderr warnings must not become visible run errors during long sessions")
        XCTAssertFalse(CodexRunner.shouldDisplayStderr("Reading additional input from stdin...\n"),
                       "stdin advisory noise must stay hidden because RemoteCode already passes the prompt as an arg")

        let fatal = CodexRunner.displayableStderr("transport error: websocket closed unexpectedly\n")
        XCTAssertEqual(fatal, "transport error: websocket closed unexpectedly",
                       "fatal Codex transport stderr must remain visible with native evidence instead of leaving the Agent App stuck")
    }

    func test_fatalCodexStderrBuildsProviderRuntimeEvidence() {
        let event = ProviderStderrClassifier.runtimeEvent(
            message: "transport error: websocket closed unexpectedly",
            provider: .codex,
            source: "codex.exec.stderr"
        )

        XCTAssertEqual(event.method, "stderr.fatal")
        XCTAssertEqual(event.source, "codex.exec.stderr")
        XCTAssertTrue(event.payloadJSON.contains("websocket closed unexpectedly"),
                      "fatal Codex stderr must be stored as raw provider runtime evidence for later debugging")
    }
}
