import XCTest
@testable import CoreModel

final class AgentProviderSelectableTests: XCTestCase {
    func test_selectableIsDistillOnly_becauseRemoteCodeRunsNoOtherProvider() {
        XCTAssertEqual(AgentProvider.selectable, [.distill])
        XCTAssertTrue(AgentProvider.distill.isSelectable)
        for legacy in [AgentProvider.codex, .claude, .grok] {
            XCTAssertFalse(legacy.isSelectable)
            // Persisted threads of these providers must still decode.
            XCTAssertEqual(try? JSONDecoder().decode(AgentProvider.self, from: Data("\"\(legacy.rawValue)\"".utf8)), legacy)
        }
    }

    func test_scheduledTaskWithLegacyProviderBecomesDistill_becauseRunsMustNeverStartOtherProviders() {
        let task = ScheduledTask(
            title: "Nightly", prompt: "Run tests", workspaceID: WorkspaceID(), workspacePathSnapshot: "/tmp",
            runAsUser: "sam", runAsUID: 501, provider: .codex, providerInstanceID: "codex-cli",
            model: "gpt-5.6-sol", reasoningEffort: .high, routingMode: .auto,
            recurrence: .daily(at: ScheduledLocalTime(hour: 9, minute: 0)!), timeZoneIdentifier: "UTC"
        )
        XCTAssertEqual(task.provider, .distill)
        XCTAssertEqual(task.providerInstanceID, "distill")
        XCTAssertEqual(task.model, "", "the other provider's model must not carry over")
        XCTAssertEqual(task.effectiveRoutingMode, .manual)
        XCTAssertEqual(task.prompt, "Run tests", "prompt and schedule survive the migration")
        XCTAssertEqual(task.recurrence, .daily(at: ScheduledLocalTime(hour: 9, minute: 0)!))
    }

    func test_botScheduleSpecWithLegacyProviderDecodesAsDistill_becauseSavedRoutinesMustRunOnDistill() throws {
        var legacy = BotScheduleSpec()
        legacy.provider = .codex
        legacy.providerInstanceID = "codex-cli"
        legacy.model = "gpt-5.6-sol"
        legacy.frequency = .weekly
        let restored = try XCTUnwrap(BotScheduleSpec.decodeJSON(legacy.encodedJSON()))
        XCTAssertEqual(restored.provider, .distill)
        XCTAssertEqual(restored.providerInstanceID, "distill")
        XCTAssertEqual(restored.model, "")
        XCTAssertEqual(restored.frequency, .weekly)
        XCTAssertEqual(BotScheduleSpec().provider, .distill)
    }
}
