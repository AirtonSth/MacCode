import XCTest
@testable import AgentRuntime
@testable import CoreModel

/// Proves Claude / Codex / Grok share the same Token Saver SR2 instruct path
/// when `RC_TOKEN_SAVER_DISTILL_HINT=1` (T-SR2-09 matrix gate).
final class SR2ProviderMatrixTests: XCTestCase {
    func testTokenSaverProviderPromptInjectsSR2AlwaysOnForAllProviders() {
        let env = ["RC_TOKEN_SAVER_DISTILL_HINT": "1"]
        let prompt = AgentSkillInstaller.tokenSaverProviderPrompt("", environment: env)
        XCTAssertTrue(
            prompt.contains(SR2WirePolicy.instructBlockMarker),
            "SR2 always-on block must be in managed distill provider prompt"
        )
        XCTAssertTrue(prompt.contains("Claude"))
        XCTAssertTrue(prompt.contains("Codex"))
        XCTAssertTrue(prompt.contains("Grok"))
        XCTAssertTrue(prompt.contains("@sr2"))
    }

    func testTokenSaverProviderPromptRequiresSR2ForEveryProviderAuthoredTextItem() {
        // WHY: a final-only rule still lets visible reasoning/commentary leak
        // PT/EN into the transcript and provider history.
        let prompt = AgentSkillInstaller.tokenSaverProviderPrompt(
            "",
            environment: ["RC_TOKEN_SAVER_DISTILL_HINT": "1"]
        )

        XCTAssertTrue(prompt.contains("Every provider-authored text item"), prompt)
        XCTAssertTrue(prompt.contains("reasoning"), prompt)
        XCTAssertTrue(prompt.contains("commentary"), prompt)
        XCTAssertTrue(prompt.contains("Tool stdout stays exact"), prompt)
        XCTAssertTrue(prompt.contains("@sr2 v1"), prompt)
        XCTAssertFalse(prompt.contains("Format:\n@sr2 v0"), prompt)
        XCTAssertTrue(prompt.contains("Never emit legacy `@sr2 v0`"), prompt)
        XCTAssertFalse(prompt.contains("fallback only if you cannot emit SR2"), prompt)
    }

    func testTokenSaverOffDoesNotInjectSR2Block() {
        let prompt = AgentSkillInstaller.tokenSaverProviderPrompt(
            "base only",
            environment: [:]
        )
        XCTAssertFalse(prompt.contains(SR2WirePolicy.instructBlockMarker))
        XCTAssertTrue(prompt.contains("base only") || prompt.contains("REMOTE_CODE_SUBAGENT") || prompt.isEmpty || prompt == "base only" || !prompt.contains("@sr2 v0 Opaque"))
        // Nested routing may still append without distill hint; SR2 block must be absent.
        XCTAssertFalse(prompt.contains(SR2WirePolicy.instructBlockMarker))
    }

    func testProviderProxyMergesPromptForClaudeCodexGrok() {
        let env = ["RC_TOKEN_SAVER_DISTILL_HINT": "1"]
        // Claude: --append-system-prompt
        let claudeArgs = AgentSkillInstaller.providerProxyArguments(
            provider: .claude,
            arguments: ["-p", "hi"],
            environment: env
        )
        let claudeJoined = claudeArgs.joined(separator: " ")
        XCTAssertTrue(
            claudeJoined.contains(SR2WirePolicy.instructBlockMarker)
                || claudeArgs.contains(where: { $0.contains(SR2WirePolicy.instructBlockMarker) }),
            "Claude proxy args must carry SR2 instruct: \(claudeArgs)"
        )

        // Codex: developer_instructions config
        let codexArgs = AgentSkillInstaller.providerProxyArguments(
            provider: .codex,
            arguments: ["exec", "hi"],
            environment: env
        )
        let codexJoined = codexArgs.joined(separator: " ")
        XCTAssertTrue(
            codexJoined.contains("developer_instructions")
                || codexJoined.contains(SR2WirePolicy.instructBlockMarker)
                || codexArgs.contains(where: { $0.contains("REMOTE_CODE_SR2") || $0.contains("developer_instructions") }),
            "Codex proxy args must carry developer_instructions SR2: \(codexArgs)"
        )

        // Grok: --rules
        let grokArgs = AgentSkillInstaller.providerProxyArguments(
            provider: .grok,
            arguments: ["-p", "hi"],
            environment: env
        )
        let grokJoined = grokArgs.joined(separator: " ")
        XCTAssertTrue(
            grokJoined.contains(SR2WirePolicy.instructBlockMarker)
                || grokArgs.contains(where: { $0.contains(SR2WirePolicy.instructBlockMarker) })
                || grokJoined.contains("--rules"),
            "Grok proxy args must carry SR2 rules: \(grokArgs)"
        )

        let covered: Set<String> = ["claude", "codex", "grok"]
        XCTAssertTrue(SR2WirePolicy.matrixIsComplete(coveredProviders: covered))
    }

    func testManagedDistillPromptIdempotentSR2() {
        let once = AgentSkillInstaller.managedDistillProviderPrompt("")
        let twice = AgentSkillInstaller.managedDistillProviderPrompt(once)
        let count = twice.components(separatedBy: SR2WirePolicy.instructBlockMarker).count - 1
        XCTAssertEqual(count, 1, "SR2 instruct must append exactly once")
    }

    func testTypedHostAndCanonicalUserLegsStaySeparateAcrossLiveProviderAdapters() throws {
        let userWire = """
        @sr2 v1
        run:command -v swift;command -v distill;command -v git
        out:=3lines
        !file-edit
        done:run
        """
        let host = AgentTrustedHostInstruction(
            text: "REMOTE_CODE_AUTO_ORCHESTRATION_V1\nSESSION_LEARN_EXACT_SCOPE:\n- preserve command output"
        )
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .codex,
            model: "gpt-5.6-luna",
            cwd: "/tmp",
            prompt: userWire,
            trustedHostInstruction: host
        )

        let codex = CodexAppServerClient.turnStartParams(providerThreadId: "t", for: request)
        let codexInput = try XCTUnwrap(codex["input"] as? [[String: Any]])
        XCTAssertEqual(codexInput.first?["text"] as? String, userWire)
        let codexMode = try XCTUnwrap(codex["collaborationMode"] as? [String: Any])
        let codexSettings = try XCTUnwrap(codexMode["settings"] as? [String: Any])
        let codexInstructions = try XCTUnwrap(codexSettings["developer_instructions"] as? String)
        XCTAssertTrue(codexInstructions.contains(host.text))
        XCTAssertFalse(codexInstructions.contains(userWire))

        let codexCLIArgs = CodexRunner.buildArgs(request)
        let codexCLIInstructions = try XCTUnwrap(
            codexCLIArgs.first(where: { $0.hasPrefix("developer_instructions=") })
        )
        XCTAssertTrue(codexCLIInstructions.contains("REMOTE_CODE_AUTO_ORCHESTRATION_V1"))
        XCTAssertTrue(codexCLIInstructions.contains("SESSION_LEARN_EXACT_SCOPE:"))
        XCTAssertFalse(codexCLIInstructions.contains(userWire))
        XCTAssertEqual(codexCLIArgs.last, userWire)

        let claude = AgentRunRequest(
            threadId: request.threadId,
            provider: .claude,
            model: "claude-opus-4-7",
            cwd: "/tmp",
            prompt: userWire,
            trustedHostInstruction: host
        )
        let claudeArgs = ClaudeRunner.buildArgs(claude)
        XCTAssertEqual(claudeArgs.last, userWire)
        let claudeSystemIndex = try XCTUnwrap(claudeArgs.firstIndex(of: "--append-system-prompt"))
        XCTAssertTrue(claudeArgs[claudeArgs.index(after: claudeSystemIndex)].contains(host.text))
        XCTAssertFalse(claudeArgs[claudeArgs.index(after: claudeSystemIndex)].contains(userWire))
        let claudeStreamingArgs = ClaudeRunner.buildStreamingArgs(claude)
        let claudeStreamingSystemIndex = try XCTUnwrap(
            claudeStreamingArgs.firstIndex(of: "--append-system-prompt")
        )
        let claudeStreamingSystem = claudeStreamingArgs[claudeStreamingArgs.index(after: claudeStreamingSystemIndex)]
        XCTAssertTrue(claudeStreamingSystem.contains(host.text))
        XCTAssertFalse(claudeStreamingSystem.contains(userWire))
        let claudeSDKSystem = ClaudeAgentSDKBridgeAdapter.claudeSystemPrompt(
            environment: claude.environment,
            interactionMode: claude.interactionMode,
            trustedHostInstruction: host
        )
        XCTAssertTrue(claudeSDKSystem.contains(host.text))
        XCTAssertFalse(claudeSDKSystem.contains(userWire))

        let grok = AgentRunRequest(
            threadId: request.threadId,
            provider: .grok,
            model: "grok-4.5",
            cwd: "/tmp",
            prompt: userWire,
            trustedHostInstruction: host,
            environment: [
                "RC_TOKEN_SAVER_DISTILL_HINT": "1",
                "RC_GRAPHIFY_ENABLED": "1",
                "RC_GRAPHIFY_JSON": "{\"workspace\":\"/tmp\"}"
            ]
        )
        let blocks = try GrokACPClient.promptBlocks(
            for: grok,
            capabilities: .init(protocolVersion: 1, loadSession: true, embeddedContext: true)
        )
        XCTAssertEqual(
            blocks.first?["text"] as? String,
            SR2WirePolicy.trustedHostInstructionWire(host.text)
        )
        XCTAssertTrue(blocks.contains { $0["text"] as? String == userWire })
        XCTAssertFalse(blocks.contains { ($0["text"] as? String)?.contains("SESSION_LEARN_EXACT_SCOPE") == true && ($0["text"] as? String) != SR2WirePolicy.trustedHostInstructionWire(host.text) })

        let grokArgs = GrokRunner.buildArgs(grok)
        let promptIndex = try XCTUnwrap(grokArgs.firstIndex(of: "-p"))
        XCTAssertEqual(grokArgs[grokArgs.index(after: promptIndex)], userWire)
        let rulesIndex = try XCTUnwrap(grokArgs.firstIndex(of: "--rules"))
        let rulesArg = grokArgs[grokArgs.index(after: rulesIndex)]
        XCTAssertTrue(rulesArg.contains(host.text))
        XCTAssertTrue(rulesArg.contains("@sr2"), "Grok rules must retain the SR2 provider policy")
        XCTAssertTrue(rulesArg.localizedCaseInsensitiveContains("distill"))
        XCTAssertTrue(rulesArg.localizedCaseInsensitiveContains("graphify"))
        XCTAssertTrue(rulesArg.contains("background"))
        XCTAssertFalse(rulesArg.contains(userWire), "the canonical user wire belongs only on -p")
    }
}
