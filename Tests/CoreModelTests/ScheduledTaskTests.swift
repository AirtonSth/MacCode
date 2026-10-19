import XCTest
@testable import CoreModel

final class ScheduledTaskTests: XCTestCase {
    // Legacy-provider machinery is still exercised here; Distill-only rules run with the seam cleared.
    override class func setUp() {
        super.setUp()
        AgentProvider.selectableForTesting = AgentProvider.allCases
    }

    override class func tearDown() {
        AgentProvider.selectableForTesting = nil
        super.tearDown()
    }

    func test_validation_requiresEveryExecutionInput_becauseBackgroundRunsCannotPrompt() {
        let task = ScheduledTask(
            title: " ", prompt: "", workspaceID: WorkspaceID(), workspacePathSnapshot: "", runAsUser: "", runAsUID: 0,
            provider: .codex, providerInstanceID: "", model: "", reasoningEffort: .high,
            recurrence: .daily(at: ScheduledLocalTime(hour: 9, minute: 0)!),
            timeZoneIdentifier: "Not/AZone"
        )

        XCTAssertEqual(task.validationErrors().count, 8)
    }

    func test_autoRequiresProviderButNotManualModel_becauseSourceIsUserChosen() {
        // Provider/Source is always required (Agent App parity). Auto may omit
        // a concrete model id; runtime picks one within the selected host.
        let missingInstance = ScheduledTask(
            title: "Auto", prompt: "Run", workspaceID: WorkspaceID(), workspacePathSnapshot: "/tmp",
            runAsUser: "sam", runAsUID: 501, provider: .codex, providerInstanceID: "", model: "",
            reasoningEffort: .high, routingMode: .auto,
            recurrence: .daily(at: ScheduledLocalTime(hour: 9, minute: 0)!), timeZoneIdentifier: "UTC"
        )
        XCTAssertTrue(missingInstance.validationErrors().contains("Provider is required."))
        XCTAssertFalse(missingInstance.validationErrors().contains("Model is required."))

        let autoWithSource = ScheduledTask(
            title: "Auto", prompt: "Run", workspaceID: WorkspaceID(), workspacePathSnapshot: "/tmp",
            runAsUser: "sam", runAsUID: 501, provider: .codex, providerInstanceID: "codex", model: "",
            reasoningEffort: .high, routingMode: .auto,
            recurrence: .daily(at: ScheduledLocalTime(hour: 9, minute: 0)!), timeZoneIdentifier: "UTC"
        )
        XCTAssertTrue(autoWithSource.validationErrors().isEmpty)
    }

    func test_missingRoutingModeDecodesAsManual_becauseOlderSerializedTasksMustKeepBehavior() throws {
        let task = ScheduledTask(
            title: "Legacy", prompt: "Run", workspaceID: WorkspaceID(), workspacePathSnapshot: "/tmp",
            runAsUser: "sam", runAsUID: 501, provider: .codex, providerInstanceID: "codex",
            model: "gpt-5", reasoningEffort: .high,
            recurrence: .daily(at: ScheduledLocalTime(hour: 9, minute: 0)!), timeZoneIdentifier: "UTC"
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        object.removeValue(forKey: "routingMode")

        let decoded = try JSONDecoder().decode(
            ScheduledTask.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.effectiveRoutingMode, .manual)
    }

    func test_missingRunOptionsDecodeAsNewMessageDefaults_becauseOlderTasksMustKeepRunningUnchanged() throws {
        let task = ScheduledTask(
            title: "Legacy", prompt: "Run", workspaceID: WorkspaceID(), workspacePathSnapshot: "/tmp",
            runAsUser: "sam", runAsUID: 501, provider: .distill, providerInstanceID: "distill",
            model: "auto", reasoningEffort: .high, distillUltracode: true, permissionMode: .supervised,
            interactionMode: .plan, executionMode: .worktree, baseBranch: "main",
            recurrence: .daily(at: ScheduledLocalTime(hour: 9, minute: 0)!), timeZoneIdentifier: "UTC"
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        for key in ["distillUltracode", "permissionMode", "interactionMode", "executionMode", "baseBranch"] {
            object.removeValue(forKey: key)
        }

        let decoded = try JSONDecoder().decode(ScheduledTask.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertFalse(decoded.distillUltracode)
        XCTAssertEqual(decoded.permissionMode, .fullAccess)
        XCTAssertEqual(decoded.interactionMode, .default)
        XCTAssertEqual(decoded.executionMode, .local)
        XCTAssertNil(decoded.baseBranch)
        XCTAssertEqual(try JSONDecoder().decode(ScheduledTask.self, from: JSONEncoder().encode(task)), task)
    }

    func test_calculatedNextRun_usesStoredIANATimeZone_becauseSchedulesAreCivilTime() throws {
        let task = ScheduledTask(
            title: "Daily", prompt: "Run", workspaceID: WorkspaceID(), workspacePathSnapshot: "/tmp", runAsUser: "sam", runAsUID: 501,
            provider: .codex, providerInstanceID: "codex", model: "gpt-5", reasoningEffort: .high,
            recurrence: .daily(at: ScheduledLocalTime(hour: 9, minute: 30)!),
            timeZoneIdentifier: "America/New_York"
        )
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let after = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 14)))
        let expected = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 7, day: 19, hour: 13, minute: 30)))

        XCTAssertEqual(task.calculatedNextRun(after: after), expected)
    }

    func test_validationCapsTitleAndPrompt_becauseUnattendedPayloadsMustStayBounded() {
        let task = ScheduledTask(
            title: String(repeating: "t", count: 121), prompt: String(repeating: "p", count: 65_537),
            workspaceID: WorkspaceID(), workspacePathSnapshot: "/tmp", runAsUser: "sam", runAsUID: 501,
            provider: .codex, providerInstanceID: "codex", model: "gpt-5", reasoningEffort: .high,
            recurrence: .daily(at: ScheduledLocalTime(hour: 9, minute: 30)!), timeZoneIdentifier: "UTC"
        )

        XCTAssertTrue(task.validationErrors().contains("Title must be at most 120 characters."))
        XCTAssertTrue(task.validationErrors().contains("Prompt must be at most 64 KiB."))
    }
}
