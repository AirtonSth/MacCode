import XCTest
@testable import CoreModel

final class AgentProviderInstructionTextTests: XCTestCase {
    func test_providerPreamblesStayCompactAndPreserveRequiredControls() {
        let defaultPreamble = AgentProviderInstructionText.providerPreamble(for: .default)
        let planPreamble = AgentProviderInstructionText.providerPreamble(for: .plan)

        XCTAssertLessThanOrEqual(defaultPreamble.count, 130,
                                 "F17: fixed default preamble is appended after compression every turn; keep it tight")
        XCTAssertLessThanOrEqual(planPreamble.count, 190,
                                 "F17: fixed plan preamble is appended after compression every turn; keep it tight")
        XCTAssertTrue(defaultPreamble.contains("preserve unrelated work"))
        XCTAssertTrue(defaultPreamble.contains("verify"))
        XCTAssertTrue(planPreamble.contains("Plan mode."))
        XCTAssertTrue(planPreamble.contains("Do not edit"))
        XCTAssertTrue(planPreamble.contains("ExitPlanMode"))
    }

    func test_developerInstructionsStayCompactAndPlanOnly() {
        let defaultInstructions = AgentProviderInstructionText.developerInstructions(for: .default)
        let planInstructions = AgentProviderInstructionText.developerInstructions(for: .plan)

        XCTAssertLessThanOrEqual(defaultInstructions.count, 110)
        XCTAssertLessThanOrEqual(planInstructions.count, 90)
        XCTAssertTrue(planInstructions.contains("Plan only"))
        XCTAssertTrue(planInstructions.contains("Do not edit"))
    }

    /// Regression for the Codex `| distill` bug. Codex (app-server) has NO automatic
    /// tool-output compression — the PostToolUse distill hook is Claude-SDK-only. Codex's
    /// single reliable per-turn channel for the Token Saver rule is `developer_instructions`.
    /// Without the rule here Codex almost never pipes, so large command output is never
    /// compressed and Token Saver records ~no command-output savings for Codex. Conversely the
    /// rule must NOT appear when Token Saver is off: the managed `distill` CLI is uninstalled
    /// then, so a `cmd | distill` pipe would fail with command-not-found and drop the output.
    func test_developerInstructionsCarryDistillRule_onlyWhenTokenSaverEnabled() {
        for mode in [AgentInteractionMode.default, .plan] {
            let on = AgentProviderInstructionText.developerInstructions(for: mode, tokenSaverEnabled: true)
            let off = AgentProviderInstructionText.developerInstructions(for: mode, tokenSaverEnabled: false)

            XCTAssertTrue(on.contains("| distill"),
                          "\(mode) developer_instructions must instruct piping through distill when Token Saver is on")
            XCTAssertFalse(off.contains("distill"),
                           "\(mode) developer_instructions must not mention distill when Token Saver is off (CLI is uninstalled)")
            XCTAssertTrue(off.count < on.count, "the distill rule is additive over the unchanged base instructions")
            XCTAssertLessThanOrEqual(on.count, 420,
                                     "developer_instructions are sent every Codex turn; keep the distill rule tight")
        }
    }

    /// The default (off) call site used by every existing turn must be byte-identical to the
    /// pre-fix text so non-Token-Saver runs are untouched.
    func test_developerInstructionsDefaultArgMatchesTokenSaverDisabled() {
        for mode in [AgentInteractionMode.default, .plan] {
            XCTAssertEqual(
                AgentProviderInstructionText.developerInstructions(for: mode),
                AgentProviderInstructionText.developerInstructions(for: mode, tokenSaverEnabled: false)
            )
        }
    }
}
