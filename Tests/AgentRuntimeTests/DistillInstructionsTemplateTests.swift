import XCTest
@testable import AgentRuntime

final class DistillInstructionsTemplateTests: XCTestCase {
    func test_instructionsCarryHardPipeHeuristicAndRetrieveNote() {
        let t = AgentSkillInstaller.distillAgentInstructionsTemplate
        // P1-T7: hard pipe heuristic so agents auto-capture large tool output (G5).
        // Strengthened per "err toward more savings": default-pipe with a low threshold.
        XCTAssertTrue(t.contains("by DEFAULT pipe EVERY"), "default-pipe heuristic present")
        XCTAssertTrue(t.contains("~10 lines or ~1KB"), "lowered concrete size threshold present")
        XCTAssertTrue(t.lowercased().contains("bias to compress"), "explicit bias-to-compress directive present")
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
