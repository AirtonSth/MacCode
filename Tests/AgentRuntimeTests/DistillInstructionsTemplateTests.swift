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
        // Reasoning/thinking narration must be distill-shaped too, so the existing reasoning ->
        // humanize -> savings pipeline can compress and credit it instead of leaking verbose prose.
        XCTAssertTrue(t.lowercased().contains("reasoning"),
                      "agent must emit reasoning/thinking in distill so it is compressed and counted, not plain prose")
        XCTAssertFalse(t.contains("Keep hidden chain-of-thought private"),
                       "thinking is no longer exempt from distill; surfaced reasoning is compressed and counted")
        // Retrieve half of the reversibility story (G2/N5).
        XCTAssertTrue(t.contains("distill retrieve <handle>"), "retrieve command documented")
        XCTAssertTrue(t.contains("[[rc:<handle>]]"), "handle marker documented so the agent knows how to recover originals")
        // F10: keep the always-loaded config block compact; examples live in SKILL.md.
        XCTAssertLessThan(t.count, 1_500, "provider config must not spend hundreds of tokens every session")
        XCTAssertFalse(t.contains("bun test 2>&1 | distill"), "examples belong in the managed skill")
        XCTAssertTrue(AgentSkillInstaller.distillSkillTemplate.contains("bun test 2>&1 | distill"))
        // Bounded by the managed markers.
        XCTAssertTrue(t.hasPrefix(AgentSkillInstaller.distillInstructionsBeginMarker))
        XCTAssertTrue(t.contains("<!-- distill skill: end -->"))
    }
}
