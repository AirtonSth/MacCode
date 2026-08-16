import XCTest
@testable import AgentRuntime
@testable import CoreModel

/// WHY: RCS1 ABI must be exclusive, identical across adapter seams, and never
/// carry RCW1 transport or billing language.
final class TokenSaverCompactSpanABITests: XCTestCase {
    func test_environmentsAreMutuallyExclusive() {
        let base = [
            "RC_TOKEN_SAVER_DISTILL_HINT": "1",
            TokenSaverExecutionReceiptSeam.wireCapabilityEnvKey: "1",
            "RC_TOKEN_SAVER_WIRE_VERSION": "1",
            TokenSaverExecutionReceiptSeam.compactSpanCapabilityEnvKey: "stale",
            TokenSaverExecutionReceiptSeam.compactSpanVersionEnvKey: "stale",
        ]
        let human = TokenSaverOutboundSelectionRequest.environment(base, for: .human)
        XCTAssertNil(human[TokenSaverExecutionReceiptSeam.wireCapabilityEnvKey])
        XCTAssertNil(human["RC_TOKEN_SAVER_WIRE_VERSION"])
        XCTAssertNil(human[TokenSaverExecutionReceiptSeam.compactSpanCapabilityEnvKey])
        XCTAssertNil(human[TokenSaverExecutionReceiptSeam.compactSpanVersionEnvKey])

        let rcw1 = TokenSaverOutboundSelectionRequest.environment(base, for: .rcw1)
        XCTAssertEqual(rcw1[TokenSaverExecutionReceiptSeam.wireCapabilityEnvKey], "1")
        XCTAssertEqual(rcw1["RC_TOKEN_SAVER_WIRE_VERSION"], "1")
        XCTAssertNil(rcw1[TokenSaverExecutionReceiptSeam.compactSpanCapabilityEnvKey])
        XCTAssertNil(rcw1[TokenSaverExecutionReceiptSeam.compactSpanVersionEnvKey])

        let rcs1 = TokenSaverOutboundSelectionRequest.environment(base, for: .rcs1)
        XCTAssertNil(rcs1[TokenSaverExecutionReceiptSeam.wireCapabilityEnvKey])
        XCTAssertNil(rcs1["RC_TOKEN_SAVER_WIRE_VERSION"])
        XCTAssertEqual(rcs1[TokenSaverExecutionReceiptSeam.compactSpanCapabilityEnvKey], "1")
        XCTAssertEqual(rcs1[TokenSaverExecutionReceiptSeam.compactSpanVersionEnvKey], "1")
    }

    func test_compactSpanSentinelIsInjectedOnceOnlyForExactRCS1Env() {
        let rcs1Env = TokenSaverOutboundSelectionRequest.environment(
            ["RC_TOKEN_SAVER_DISTILL_HINT": "1"],
            for: .rcs1
        )
        let prompt = AgentSkillInstaller.tokenSaverProviderPrompt("", environment: rcs1Env)
        let sentinel = AgentSkillInstaller.compactSpanAgentInstructionsTemplate
        XCTAssertEqual(prompt.components(separatedBy: sentinel).count - 1, 1)
        XCTAssertTrue(sentinel.contains("RCS1/1"))
        XCTAssertTrue(sentinel.contains("Decode the complete item before acting"))
        XCTAssertTrue(sentinel.contains("Concatenate L literals and D for each R"))
        XCTAssertTrue(sentinel.contains("literals/negation/order"))
        XCTAssertTrue(sentinel.contains("Tools remain native"))
        XCTAssertFalse(sentinel.contains("Caveman"))
        XCTAssertFalse(sentinel.contains("caveman"))
        XCTAssertFalse(sentinel.contains("RCW1"))
        XCTAssertFalse(sentinel.contains("45 percent"))
        XCTAssertFalse(sentinel.contains("45%"))
        XCTAssertFalse(sentinel.contains("handle"))
        XCTAssertFalse(sentinel.contains("retrieve"))
        XCTAssertFalse(sentinel.lowercased().contains("billing"))
        XCTAssertFalse(prompt.contains("REMOTE_CODE_WIRE_V1"))

        let again = AgentSkillInstaller.tokenSaverProviderPrompt(prompt, environment: rcs1Env)
        XCTAssertEqual(again.components(separatedBy: sentinel).count - 1, 1)
    }

    func test_humanAndRCW1DoNotReceiveCompactSpanSentinel() {
        let base = [
            "RC_TOKEN_SAVER_DISTILL_HINT": "1",
            TokenSaverExecutionReceiptSeam.wireCapabilityEnvKey: "1",
        ]
        let human = AgentSkillInstaller.tokenSaverProviderPrompt(
            "",
            environment: TokenSaverOutboundSelectionRequest.environment(base, for: .human)
        )
        let rcw1 = AgentSkillInstaller.tokenSaverProviderPrompt(
            "",
            environment: TokenSaverOutboundSelectionRequest.environment(base, for: .rcw1)
        )
        XCTAssertFalse(human.contains(AgentSkillInstaller.compactSpanAgentInstructionsTemplate))
        XCTAssertFalse(rcw1.contains(AgentSkillInstaller.compactSpanAgentInstructionsTemplate))
        XCTAssertTrue(rcw1.contains(AgentSkillInstaller.rcWireAgentInstructionsTemplate))
        XCTAssertFalse(
            AgentSkillInstaller.tokenSaverProviderPrompt(
                "",
                environment: TokenSaverOutboundSelectionRequest.environment(base, for: .rcs1)
            ).contains(AgentSkillInstaller.rcWireAgentInstructionsTemplate)
        )
    }

    func test_sameProjectedABIIsUsedByClaudeCodexAndGrokSeams() {
        let env = TokenSaverOutboundSelectionRequest.environment(
            ["RC_TOKEN_SAVER_DISTILL_HINT": "1"],
            for: .rcs1
        )
        let expected = AgentSkillInstaller.tokenSaverProviderPrompt("", environment: env)
        XCTAssertFalse(expected.isEmpty)
        for provider in [AgentProvider.claude, .codex, .grok] {
            let prompt = AgentSkillInstaller.tokenSaverProviderPrompt("", environment: env)
            XCTAssertEqual(prompt, expected, "\(provider.rawValue) must share the RCS1 ABI")
            XCTAssertEqual(
                prompt.components(separatedBy: AgentSkillInstaller.compactSpanAgentInstructionsTemplate).count - 1,
                1,
                "\(provider.rawValue) must inject the sentinel once"
            )
        }
    }

}
