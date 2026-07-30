import XCTest
@testable import AgentRuntime

final class DistillInstructionsTemplateTests: XCTestCase {
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
        // WHY: Token Saver must require `| distill` on eligible noisy output for every
        // admitted primary, same-provider subagent, and cross-provider nested run — not
        // a soft "good to pipe" suggestion the model can ignore.
        XCTAssertTrue(t.contains("MANDATORY") || t.contains("REQUIRED to pipe"),
                      "the template must require piping eligible noisy commands")
        XCTAssertTrue(t.contains("policy violation") || t.contains("Omitting `| distill`"),
                      "omitting eligible | distill must be called out as a violation")
        XCTAssertTrue(t.contains("auto-compress via the host wrapper"),
                      "the template must clarify host PATH wrappers also compress catalog commands")
        XCTAssertTrue(
            t.contains("| distill \"<question>\""),
            "the instruction must show the concrete pipe-with-question syntax"
        )
        XCTAssertTrue(
            t.contains("primary agents") || t.contains("cross-provider") || t.contains("subagents"),
            "policy must apply to primary, subagent, and cross-provider shapes"
        )
        XCTAssertTrue(t.contains("NEVER pipe `| distill` for exact-output tools"),
                      "the template must forbid compressing output the agent consumes byte-exactly")
        XCTAssertTrue(t.contains("rg, grep"),
                      "the never-pipe list must name the search tools whose exact stdout the agent needs")
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
        // Sparse dialect: R0 micro O-only + R1 work O-first (token savings vs 6-line tax).
        XCTAssertTrue(t.contains("R0 micro"), "R0 micro register present")
        XCTAssertTrue(t.contains("R1 work"), "R1 work register present")
        XCTAssertTrue(t.contains("O-first") || t.contains("O: only") || t.contains("`O:` only"),
                      "O-first / O-only sparsity present")
        XCTAssertTrue(t.lowercased().contains("never pad to six"),
                      "must forbid fixed six-line S/C/D padding")
        // Reasoning/thinking narration must be distill-shaped too, so the existing reasoning ->
        // humanize -> savings pipeline can compress and credit it instead of leaking verbose prose.
        XCTAssertTrue(t.lowercased().contains("reasoning") || t.lowercased().contains("r1"),
                      "agent must keep thinking/work turns in sparse distill, not free prose")
        XCTAssertFalse(t.contains("Keep hidden chain-of-thought private"),
                       "thinking is no longer exempt from distill; surfaced reasoning is compressed and counted")
        // Retrieve half of the reversibility story (G2/N5).
        XCTAssertTrue(t.contains("distill retrieve <handle>"), "retrieve command documented")
        XCTAssertTrue(t.contains("[[rc:<handle>]]"), "handle marker documented so the agent knows how to recover originals")
        // F10: keep the always-loaded config block compact; examples live in SKILL.md.
        // Raised slightly after MANDATORY/cross-provider wording (still compact vs full skill).
        XCTAssertLessThan(t.count, 2_600, "provider config must stay compact (skill-complete rule may add a few lines)")
        XCTAssertFalse(t.contains("bun test 2>&1 | distill"), "examples belong in the managed skill")
        XCTAssertTrue(AgentSkillInstaller.distillSkillTemplate.contains("bun test 2>&1 | distill"))
        XCTAssertTrue(AgentSkillInstaller.distillSkillTemplate.contains("R0 micro"),
                      "full skill carries R0 dialect details")
        XCTAssertTrue(AgentSkillInstaller.distillSkillTemplate.contains("NEVER Distill skill content"),
                      "full skill body also protects skill content as a verbatim category")
        XCTAssertTrue(
            AgentSkillInstaller.distillSkillTemplate.contains("MANDATORY")
                || AgentSkillInstaller.distillSkillTemplate.contains("REQUIRED"),
            "full skill body must also require | distill on eligible noisy commands"
        )
        // Bounded by the managed markers.
        XCTAssertTrue(t.hasPrefix(AgentSkillInstaller.distillInstructionsBeginMarker))
        XCTAssertTrue(t.contains("<!-- distill skill: end -->"))
    }

    func test_tokenSaverOffDoesNotInjectDistillPolicy() {
        // WHY: Token Saver off must fail open with no Distill dialect injection.
        let off = AgentSkillInstaller.tokenSaverProviderPrompt("base only", environment: [:])
        XCTAssertEqual(off, "base only")
        XCTAssertFalse(off.contains("| distill"))
        XCTAssertFalse(off.contains(AgentSkillInstaller.distillAgentInstructionsBody))

        let on = AgentSkillInstaller.tokenSaverProviderPrompt(
            "base only",
            environment: ["RC_TOKEN_SAVER_DISTILL_HINT": "1"]
        )
        XCTAssertTrue(on.contains("NEVER Distill skill content"))
        XCTAssertTrue(on.contains("| distill") || on.contains("distill"),
                      "Token Saver on still injects ordinary-output Distill eligibility")
    }
}
