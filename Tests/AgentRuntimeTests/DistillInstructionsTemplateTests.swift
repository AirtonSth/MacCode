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
        XCTAssertTrue(t.contains("Good to pipe:"),
                      "the template must name the noisy-output cases that default to the managed CLI")
        XCTAssertTrue(t.contains("NEVER pipe `| distill` for exact-output tools"),
                      "the template must forbid compressing output the agent consumes byte-exactly")
        XCTAssertTrue(t.contains("rg, grep"),
                      "the never-pipe list must name the search tools whose exact stdout the agent needs")
        XCTAssertFalse(t.contains("~10 lines or ~1KB"),
                       "the provider must not guess output size before deciding to distill")
        XCTAssertFalse(t.lowercased().contains("bias to compress"),
                       "bias-to-compress was replaced by the fidelity predicate; reinstating it re-breaks exact-output tools")
        XCTAssertTrue(t.contains("subagent, worker, reviewer"),
                      "delegated prompts must carry the same distill contract")
        XCTAssertTrue(t.contains("descendants"),
                      "nested subagents must not lose the distill contract")
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
        XCTAssertLessThan(t.count, 1_800, "provider config must stay compact (sparse dialect may be slightly larger than 1500)")
        XCTAssertFalse(t.contains("bun test 2>&1 | distill"), "examples belong in the managed skill")
        XCTAssertTrue(AgentSkillInstaller.distillSkillTemplate.contains("bun test 2>&1 | distill"))
        XCTAssertTrue(AgentSkillInstaller.distillSkillTemplate.contains("R0 micro"),
                      "full skill carries R0 dialect details")
        // Bounded by the managed markers.
        XCTAssertTrue(t.hasPrefix(AgentSkillInstaller.distillInstructionsBeginMarker))
        XCTAssertTrue(t.contains("<!-- distill skill: end -->"))
    }
}
