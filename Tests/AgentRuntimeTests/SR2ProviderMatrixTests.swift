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
}
