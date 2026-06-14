import XCTest
@testable import AgentRuntime

final class DistillInstructionsTemplateTests: XCTestCase {
    func test_instructionsCarryHardPipeHeuristicAndRetrieveNote() {
        let t = AgentSkillInstaller.distillAgentInstructionsTemplate
        // P1-T7: hard pipe heuristic so agents auto-capture large tool output (G5).
        XCTAssertTrue(t.contains("ALWAYS pipe build, test"), "hard pipe heuristic present")
        XCTAssertTrue(t.contains("~30 lines or ~2KB"), "concrete size threshold present")
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
