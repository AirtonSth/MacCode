import XCTest
import CoreModel
@testable import AppShell

final class ScheduledTasksWindowTests: XCTestCase {
    func test_editorBuildsFullTaskWithNextRun_becauseSavedSchedulesMustBeImmediatelyRunnable() throws {
        var draft = ScheduledTaskEditorDraft(now: Date(timeIntervalSince1970: 100))
        draft.title = "Audit"
        draft.prompt = "Inspect"
        draft.workspaceID = WorkspaceID()
        draft.workspacePathSnapshot = "/tmp"
        draft.runAsUser = NSUserName()
        draft.runAsUID = ScheduledSystemUserCatalog.user(named: NSUserName())?.uid ?? 501
        draft.providerInstanceID = "codex"
        draft.model = "gpt-5"
        draft.frequency = .hourly
        draft.intervalHours = 2
        draft.scheduledDate = Date(timeIntervalSince1970: 200)

        let task = try draft.makeTask(now: Date(timeIntervalSince1970: 150))

        XCTAssertEqual(task.permissionModeForScheduledExecution, .fullAccess)
        XCTAssertEqual(task.nextRunAt, Date(timeIntervalSince1970: 200))
    }

    func test_sidebarPlacesScheduleTasksImmediatelyAfterNewWorkspace_becauseNavigationOrderIsContractual() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        let newWorkspace = try XCTUnwrap(source.range(of: "accessibilityIdentifier(\"sidebar.newWorkspace\")"))
        let scheduleTasks = try XCTUnwrap(source.range(of: "accessibilityIdentifier(\"sidebar.scheduleTasks\")"))
        let updateControl = try XCTUnwrap(source.range(of: "if vm.showsUpdateControl"))

        XCTAssertLessThan(newWorkspace.lowerBound, scheduleTasks.lowerBound)
        XCTAssertLessThan(scheduleTasks.lowerBound, updateControl.lowerBound)
    }

    func test_editorSheetDoesNotForceUnwrapPublishedDraft_becauseSaveClearsItDuringRender() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("vm.editorDraft!"))
        XCTAssertTrue(source.contains(".sheet(item: $vm.editorDraft)"))
    }

    func test_savePreflightsAndPausesForApproval_becauseBlockedTasksMustNotClaimActive() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".preflight(task)"))
        XCTAssertTrue(source.contains("Task saved paused."))
        XCTAssertTrue(source.contains("scheduledTasks.openLoginItems"))
    }

    func test_failureDetailsCanExpand_becauseSafeHistoryErrorsMustRemainInspectable() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("expandedRunIDs"))
        XCTAssertTrue(source.contains("Show details"))
        XCTAssertTrue(source.contains("Hide details"))
    }

    private func sourceURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(relative)
    }
}

private extension ScheduledTask {
    var permissionModeForScheduledExecution: AgentPermissionMode { .fullAccess }
}
