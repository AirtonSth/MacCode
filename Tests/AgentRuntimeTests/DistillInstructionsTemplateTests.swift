import XCTest
@testable import AgentRuntime
@testable import DistillCore

final class DistillInstructionsTemplateTests: XCTestCase {
    func test_rcWireABIIsCompactAndPinsMinimumProviderNeutralContract() {
        // WHY: this block is paid on every admitted provider turn. The previous
        // tutorial-sized ABI cost more tokens than the prompt it was meant to save.
        let wire = AgentSkillInstaller.rcWireAgentInstructionsTemplate

        XCTAssertLessThanOrEqual(
            TokenEstimator.estimate(wire),
            50,
            "the always-loaded RCW1 ABI must not erase prompt savings"
        )
        XCTAssertLessThanOrEqual(wire.utf8.count, 200)
        XCTAssertTrue(wire.contains("REMOTE_CODE_WIRE_V1"))
        XCTAssertTrue(wire.contains("Current RCW1 Q"))
        XCTAssertTrue(wire.contains("G/C/K=task"))
        XCTAssertTrue(wire.contains("X=handle"))
        XCTAssertTrue(wire.contains(#"RCW1 A:O/A/E/R/Q+".""#))
        XCTAssertTrue(wire.contains("full tokens<=45%"))
        XCTAssertTrue(wire.contains("semantically identical terse text"))
        XCTAssertTrue(wire.contains("else same text"))
        XCTAssertFalse(wire.contains("tokens<same terse text"),
                       "the former any-positive-savings gate was too permissive")
        XCTAssertFalse(wire.contains("Reply only RCW1 A"),
                       "an unprofitable response must fail open to terse plaintext")
        XCTAssertTrue(wire.contains("literals/negation/order/approval"))
        XCTAssertTrue(wire.contains("tools native"))
    }

    func test_instructionsCarryHardPipeHeuristicAndRetrieveNote() {
        let t = AgentSkillInstaller.distillAgentInstructionsTemplate
        // WHY: the shipped policy is fidelity-based, not volume-based. An earlier
        // revision told the provider to pipe EVERY pipable command, which compressed
        // exactly the output the agent must consume byte-exactly next (rg/grep/sed
        // feeding an Edit's old_string, a hash, a patch). The template now names both
        // sides explicitly so the provider never has to guess: a noisy-output
        // allowlist, and a never-pipe list of exact-output tools. These assertions
        // pin that decision — they previously asserted its inverse and were red,
        // because the template changed and the test did not.
        // WHY: default is pipe EVERY non-GUI shell command unless the agent needs
        // exact full stdout (rg/sed/cat/…) or the tool is GUI/interactive.
        XCTAssertTrue(t.contains("MANDATORY") || t.contains("default-pipe"),
                      "the template must require default-pipe | distill")
        XCTAssertTrue(
            t.contains("non-GUI") || t.contains("GUI"),
            "the template must exempt GUI/interactive tools from | distill"
        )
        XCTAssertTrue(
            t.contains("byte-exactly") || t.contains("full stdout"),
            "the template must key the decision on needing exact stdout"
        )
        XCTAssertTrue(t.contains("policy violation") || t.contains("Omitting `| distill`"),
                      "omitting eligible | distill must be called out as a violation")
        XCTAssertTrue(
            t.contains("| distill \"<question>\""),
            "the instruction must show the concrete pipe-with-question syntax"
        )
        XCTAssertTrue(
            t.contains("primary agents") || t.contains("cross-provider") || t.contains("subagents"),
            "policy must apply to primary, subagent, and cross-provider shapes"
        )
        XCTAssertTrue(
            t.contains("NEVER pipe `| distill` only for exact-output")
                || t.contains("NEVER pipe `| distill` for exact-output"),
            "the template must forbid compressing output the agent consumes byte-exactly"
        )
        XCTAssertTrue(t.contains("rg, grep"),
                      "the never-pipe list must name the search tools whose exact stdout the agent needs")
        XCTAssertTrue(t.contains("sed"),
                      "the never-pipe list must name sed as exact-output")
        XCTAssertFalse(t.contains("~10 lines or ~1KB"),
                       "the provider must not guess output size before deciding to distill")
        XCTAssertFalse(t.lowercased().contains("bias to compress"),
                       "bias-to-compress was replaced by the fidelity predicate; reinstating it re-breaks exact-output tools")
        // Skill content is protected verbatim — never Distill, summarize, or handle it.
        XCTAssertTrue(t.contains("NEVER Distill skill content"),
                      "canonical policy must exempt skill content before any Distill path")
        XCTAssertTrue(t.contains("complete/verbatim") || t.lowercased().contains("must stay complete"),
                      "requested/returned skill content must stay complete")
        XCTAssertTrue(t.contains("do not require every worker prompt to restate"),
                      "workers must not be forced to restate Distill rules inside skill prompts")
        XCTAssertFalse(t.contains("Every subagent, worker, reviewer, or delegated prompt MUST repeat"),
                       "removed: requiring every worker to restate Distill")
        XCTAssertFalse(t.contains("R0 micro"))
        XCTAssertFalse(t.contains("R1 work"))
        XCTAssertFalse(t.contains("O-first"))
        XCTAssertTrue(t.contains("not a conversation style or user command"),
                      "the surviving Distill policy must be tool-output-only")
        // Retrieve half of the reversibility story (G2/N5).
        XCTAssertTrue(t.contains("distill retrieve <handle>"), "retrieve command documented")
        XCTAssertTrue(t.contains("[[rc:<handle>]]"), "handle marker documented so the agent knows how to recover originals")
        // F10: keep the always-loaded config block compact; examples live in SKILL.md.
        // Raised slightly after MANDATORY/cross-provider wording (still compact vs full skill).
        XCTAssertLessThan(t.count, 2_600, "provider config must stay compact (skill-complete rule may add a few lines)")
        XCTAssertFalse(t.contains("bun test 2>&1 | distill"), "examples belong in the managed skill")
        XCTAssertTrue(AgentSkillInstaller.distillSkillTemplate.contains("bun test 2>&1 | distill"))
        XCTAssertFalse(AgentSkillInstaller.distillSkillTemplate.contains("R0 micro"),
                       "managed skill must not reinstall the removed conversation dialect")
        XCTAssertTrue(AgentSkillInstaller.distillSkillTemplate.contains("NEVER Distill skill content"),
                      "full skill body also protects skill content as a verbatim category")
        XCTAssertTrue(
            AgentSkillInstaller.distillSkillTemplate.contains("MANDATORY")
                || AgentSkillInstaller.distillSkillTemplate.contains("default-pipe"),
            "full skill body must require default-pipe | distill for non-exact shell commands"
        )
        XCTAssertTrue(
            AgentSkillInstaller.distillSkillTemplate.contains("GUI")
                || AgentSkillInstaller.distillSkillTemplate.contains("interactive"),
            "full skill body must exempt GUI/interactive from | distill"
        )
        // Bounded by the managed markers.
        XCTAssertTrue(t.hasPrefix(AgentSkillInstaller.distillInstructionsBeginMarker))
        XCTAssertTrue(t.contains("<!-- distill skill: end -->"))
    }

    func test_tokenSaverOffDoesNotInjectDistillPolicy() {
        // WHY: Token Saver off must fail open with no Token Saver policy.
        let off = AgentSkillInstaller.tokenSaverProviderPrompt("base only", environment: [:])
        XCTAssertEqual(off, "base only")
        XCTAssertFalse(off.contains("| distill"))
        XCTAssertFalse(off.contains(AgentSkillInstaller.distillAgentInstructionsBody))

        let on = AgentSkillInstaller.tokenSaverProviderPrompt(
            "base only",
            environment: [
                "RC_TOKEN_SAVER_DISTILL_HINT": "1",
                TokenSaverExecutionReceiptSeam.wireCapabilityEnvKey: "1",
            ]
        )
        XCTAssertTrue(on.contains("NEVER Distill skill content"))
        XCTAssertTrue(on.contains("| distill") || on.contains("distill"),
                      "Token Saver on still injects ordinary-output Distill eligibility")
        XCTAssertTrue(on.contains("REMOTE_CODE_WIRE_V1"),
                      "the trusted session capability must predate a later encoded follow-up")

        let wireOnly = AgentSkillInstaller.tokenSaverProviderPrompt(
            "base only",
            environment: ["RC_TOKEN_SAVER_WIRE_VERSION": "1"]
        )
        XCTAssertEqual(wireOnly, "base only",
                       "a per-turn flag cannot enable protocol code while Token Saver capability is off")
        XCTAssertTrue(on.contains("Current RCW1 Q"),
                      "the request header, not an environment variable, is authoritative per turn")
        XCTAssertTrue(on.contains("full tokens<=45%"),
                      "providers must enforce the complete response-frame profitability threshold")
        XCTAssertTrue(on.contains("semantically identical terse text"),
                      "the token comparison must hold response meaning constant")
        XCTAssertTrue(on.contains("else same text"),
                      "an expanding response must fail open to the same terse plaintext")
        XCTAssertTrue(on.contains("X=handle"),
                      "a recovery handle must not make providers retrieve redundant prompt text by default")
        XCTAssertTrue(on.contains("tools native"),
                      "tool and approval callbacks remain provider-native, never encoded as chat prose")
        XCTAssertFalse(on.contains("R0 micro"))
    }
}
