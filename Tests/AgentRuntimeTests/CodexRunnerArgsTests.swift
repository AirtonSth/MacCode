import XCTest
@testable import AgentRuntime
import CoreModel

/// A1: codex must resume by session id (so it keeps context), use the
/// account default model when none is chosen, and map effort/sandbox.
final class CodexRunnerArgsTests: XCTestCase {

    private func req(model: String = "", resume: String? = nil,
                     effort: AgentReasoningEffort? = .medium,
                     mode: AgentPermissionMode = .supervised) -> AgentRunRequest {
        AgentRunRequest(threadId: AgentThreadID(), provider: .codex,
                        model: model, cwd: "/tmp", prompt: "do it",
                        providerThreadId: resume, permissionMode: mode,
                        reasoningEffort: effort)
    }

    func test_freshRun_usesExecNotResume_andOmitsModelWhenDefault() {
        let a = CodexRunner.buildArgs(req())
        XCTAssertEqual(a.first, "exec")
        XCTAssertFalse(a.contains("resume"), "a first run must not be a resume")
        XCTAssertFalse(a.contains("--model"), "empty model → account default (no -m)")
        XCTAssertTrue(a.contains("--json") && a.contains("--skip-git-repo-check"))
        XCTAssertEqual(a.last, "do it", "prompt is the final positional arg")
    }

    func test_resume_passesSessionIdBeforePromptAndDropsSandboxModel() {
        let a = CodexRunner.buildArgs(req(model: "gpt-5-codex", resume: "sess-99", mode: .fullAccess))
        XCTAssertEqual(Array(a.prefix(2)), ["exec", "resume"])
        XCTAssertEqual(Array(a.suffix(2)), ["sess-99", "do it"],
                       "session id then prompt are the trailing positionals")
        XCTAssertFalse(a.contains("--sandbox"),
                       "`codex exec resume` rejects --sandbox (session keeps its own)")
        XCTAssertFalse(a.contains("--model"),
                       "`codex exec resume` rejects --model (session keeps its own)")
        XCTAssertTrue(a.contains("--json") && a.contains("--skip-git-repo-check"))
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

    /// Codex accepts `model_reasoning_effort="xhigh"` (it is the value in
    /// the user's ~/.codex/config.toml). The enum must forward it verbatim.
    func test_xhighEffort_forwardedToCodex() {
        let a = CodexRunner.buildArgs(req(effort: .xhigh))
        XCTAssertTrue(a.contains(#"model_reasoning_effort="xhigh""#),
                      "Extra High must map to the codex xhigh effort")
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
}
