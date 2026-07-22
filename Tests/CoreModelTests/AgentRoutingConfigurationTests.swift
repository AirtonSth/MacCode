import XCTest
@testable import CoreModel

final class AgentRoutingConfigurationTests: XCTestCase {
    func testLegacySelectionMigratesToManualWithoutChangingFastTier() {
        let selection = AgentModelSelection(
            provider: .codex,
            modelId: "gpt-5.6-sol",
            reasoningEffort: .xhigh,
            serviceTier: .fast
        )

        let routing = AgentRoutingConfiguration.legacyManual(
            selection: selection,
            providerInstanceId: "codex-work",
            updatedAt: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(routing.mode, .manual)
        XCTAssertEqual(routing.manualSelection, selection)
        XCTAssertEqual(routing.manualProviderInstanceId, "codex-work")
        XCTAssertEqual(routing.manualSelection.serviceTier, .fast,
                       "legacy service tier is manual provider speed, never an Auto-routing signal")
        XCTAssertEqual(routing.revision, 0)
    }

    func testAutoThenManualPreservesExactManualSelection() throws {
        let selection = AgentModelSelection(
            provider: .claude,
            modelId: "claude-opus-4-1",
            reasoningEffort: .max,
            serviceTier: .fast
        )
        let manual = AgentRoutingConfiguration.legacyManual(
            selection: selection,
            providerInstanceId: "claude-personal"
        )

        let auto = try manual.replacing(
            expectedRevision: 0,
            mode: .auto,
            manualSelection: selection,
            manualProviderInstanceId: "claude-personal",
            eligibleProviders: [.claude, .codex, .grok],
            policyDigest: String(repeating: "a", count: 64),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let restored = try auto.replacing(
            expectedRevision: 1,
            mode: .manual,
            manualSelection: auto.manualSelection,
            manualProviderInstanceId: auto.manualProviderInstanceId,
            eligibleProviders: auto.eligibleProviders,
            policyDigest: auto.policyDigest,
            updatedAt: Date(timeIntervalSince1970: 30)
        )

        XCTAssertEqual(auto.mode, .auto)
        XCTAssertEqual(restored.mode, .manual)
        XCTAssertEqual(restored.manualSelection, selection)
        XCTAssertEqual(restored.manualProviderInstanceId, "claude-personal")
        XCTAssertEqual(restored.revision, 2)
    }

    func testRevisionConflictFailsLoudly() throws {
        let routing = AgentRoutingConfiguration.legacyManual(
            selection: AgentModelSelection(provider: .grok, modelId: "grok-4")
        )

        XCTAssertThrowsError(try routing.replacing(
            expectedRevision: 7,
            mode: .auto,
            manualSelection: routing.manualSelection,
            manualProviderInstanceId: nil,
            eligibleProviders: [.grok],
            policyDigest: String(repeating: "b", count: 64)
        )) { error in
            XCTAssertEqual(error as? AgentRoutingRevisionError, .conflict(expected: 7, actual: 0))
        }
    }
}
