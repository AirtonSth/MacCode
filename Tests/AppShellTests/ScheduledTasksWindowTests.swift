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
        XCTAssertEqual(task.effectiveRoutingMode, .auto)
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

    func test_scheduleTasksOpensInMainContent_notOnlyDetachedWindow() throws {
        let main = try String(contentsOf: sourceURL("Sources/AppShell/MainWindowController.swift"), encoding: .utf8)
        let sidebar = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        XCTAssertTrue(main.contains("presentScheduledTasksInMainContent"),
                      "Schedule Tasks must mount in the main workspace content column")
        XCTAssertTrue(main.contains("installScheduledTasksContent"),
                      "main shell must install ScheduledTasksRootView into workspaceContent")
        XCTAssertTrue(sidebar.contains("onPresentScheduledTasks"),
                      "sidebar must route Schedule Tasks to the main shell presenter")
        XCTAssertTrue(sidebar.contains("onWorkspaceContentActivated"),
                      "selecting a workspace must leave the Schedule Tasks shell destination")
        XCTAssertTrue(main.contains("visibleWorkspaceLabel.stringValue = \"Schedule Tasks\""),
                      "title bar must read Schedule Tasks while that shell destination is active")
        XCTAssertTrue(sidebar.contains("isScheduledTasksSelected"),
                      "sidebar must track Schedule Tasks selection so workspace rows can fully deselect")
    }

    func test_editorDoesNotForceUnwrapPublishedDraft_becauseSaveClearsItDuringRender() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("vm.editorDraft!"))
        // Plan mockups use a full-page editor route (not a modal sheet).
        XCTAssertTrue(source.contains("case .editor"),
                      "editor must be a navigation screen so Cancel/Save match the plan chrome")
        XCTAssertTrue(source.contains("if let draft = vm.editorDraft"),
                      "editor must bind the optional draft without force-unwrap after save clears it")
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
        XCTAssertTrue(source.contains("scheduledTasks.history.toggleDetails"),
                      "failure disclosure must be a dedicated control, not the whole row")
    }

    func test_historyRowOpensThreadOnPrimaryClick_becauseCompletedRunsMustStayNavigable() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        // WHY: completed runs used to wrap the row in a disabled Button, which also
        // disabled the nested Agent Task control and blocked openThread navigation.
        XCTAssertTrue(source.contains("scheduledTasks.history.openThread"))
        XCTAssertTrue(source.contains("vm.openThread(run)"))
        XCTAssertTrue(source.contains("canOpenThread"))
        XCTAssertTrue(source.contains("historyRowPrimaryContent"))
        XCTAssertFalse(
            source.contains(".disabled(run.errorSummary == nil && run.status != .failed)"),
            "history rows must not disable open-thread hit targets on successful runs"
        )
    }

    func test_runNowSetsQueuedImmediately_becauseUsersNeedSameClickFeedback() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        // WHY: Run Now used to wait for the XPC claim before any badge change,
        // so the overview card stayed Active until the agent replied.
        XCTAssertTrue(source.contains("activeRunStatuses[task.id] = .queued"))
        XCTAssertTrue(source.contains("DSPill(\"Queued\""))
        XCTAssertTrue(source.contains("activeRunStatus: vm.activeRunStatus(for: task.id)"))
        XCTAssertTrue(source.contains("ensureActiveRunPolling"))
    }

    func test_scheduledExecutionUsesAgentAppSendPath_becauseStopAndRailMustMatchManualThreads() throws {
        let runtime = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTaskRuntime.swift"), encoding: .utf8)
        let main = try String(contentsOf: sourceURL("Sources/AppShell/AppDelegate.swift"), encoding: .utf8)
        let router = try String(contentsOf: sourceURL("Sources/AppShell/AppCommandRouter.swift"), encoding: .utf8)
        // Path B: LaunchAgent is sole executor; UI stops via XPC; rails reload
        // on distributed store invalidation (not a second in-process scheduler).
        XCTAssertTrue(runtime.contains("router.createAgentThread("))
        XCTAssertTrue(runtime.contains("router.sendAgentMessage("))
        XCTAssertTrue(runtime.contains("func stop(threadID:"))
        XCTAssertTrue(runtime.contains("ScheduledTaskCrossProcess.notifyStoreChanged"))
        XCTAssertTrue(runtime.contains("protocolVersion = 2"))
        XCTAssertFalse(runtime.contains("ScheduledTaskInProcessHost"),
                       "path B must not dual-host an in-process scheduler")
        XCTAssertTrue(main.contains("installScheduledTaskStoreObserver"))
        XCTAssertTrue(router.contains("wireScheduledRunControl"))
        XCTAssertTrue(router.contains("stopScheduledThread"))
        XCTAssertFalse(
            runtime.contains("context.coordinator.startRun("),
            "scheduled execute still uses create+send inside the agent process"
        )
    }

    func test_rootViewUsesDesignSystemSurfaces_becauseScheduledTasksMustMatchLatestRemoteCodeChrome() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("DSPrimaryButtonStyle()"))
        XCTAssertTrue(source.contains("DSSecondaryButtonStyle()"))
        XCTAssertTrue(source.contains("DSPill("))
        XCTAssertTrue(source.contains("DSEmptyState("))
        XCTAssertTrue(source.contains("dsPanel("))
        XCTAssertTrue(source.contains("serviceRequiresApproval"))
        XCTAssertTrue(source.contains("Open Login Items"))
        // Plan-faithful chrome: full-width card list + full-page editor groups.
        XCTAssertTrue(source.contains("ScheduledTaskCard("))
        XCTAssertTrue(source.contains("Automate recurring agent work"))
        XCTAssertTrue(source.contains("editorGroup(\"Details\")"))
        XCTAssertTrue(source.contains("editorGroup(\"Frequency\")"))
        XCTAssertTrue(source.contains("Run History"))
        XCTAssertTrue(source.contains("Save Task"))
        XCTAssertFalse(source.contains("HSplitView"),
                       "plan mockups use a single-column stack, not master-detail split")
    }

    func test_editorKeepsProviderPickersWithAuto_becauseAutoOnlySelectsModel() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("scheduledTasks.editor.autoRouting"))
        XCTAssertTrue(source.contains("scheduledTasks.editor.provider"))
        XCTAssertTrue(source.contains("scheduledTasks.editor.providerAccount"))
        XCTAssertTrue(source.contains("if draft.routingMode == .auto"))
        // Auto must never claim it picks the provider — only the model for the chosen Source.
        XCTAssertTrue(source.contains("Auto selects the best model for the selected provider at run time."))
        XCTAssertFalse(source.contains("Auto selects the best available provider and model at run time."))
        XCTAssertTrue(source.contains("ProgressView()"))
        // Provider pickers live outside the Auto-only branch so they stay visible.
        let providerPicker = try XCTUnwrap(source.range(of: "scheduledTasks.editor.provider"))
        let autoBranch = try XCTUnwrap(source.range(of: "if draft.routingMode == .auto"))
        XCTAssertLessThan(providerPicker.lowerBound, autoBranch.lowerBound,
                          "Provider picker must render before the Auto-only model branch")
        // Labels must keep the chosen Source when Auto is on (not "Provider: Auto").
        XCTAssertTrue(source.contains("\\(host) · Auto"))
        XCTAssertTrue(source.contains("\\(task.provider.rawValue.capitalized) · Auto"))
        // Auto → Manual must restore model from the selected account, not first catalog host.
        XCTAssertTrue(source.contains("$0.id == draft.providerInstanceID && $0.provider == draft.provider"))
        XCTAssertFalse(source.contains("vm.providers.first(where: { $0.enabled && $0.installed }) ?? vm.providers.first"))
    }

    func test_mainDisablesManagedDistillInScheduledAgent_becauseHeadlessRunsMustNotMutateShellSkills() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/Main.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("setenv(\"RC2_DISABLE_MANAGED_DISTILL_RECONCILE\", \"1\", 1)"))
        XCTAssertTrue(source.contains("--scheduled-task-agent"))
    }

    private func sourceURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(relative)
    }
}

private extension ScheduledTask {
    var permissionModeForScheduledExecution: AgentPermissionMode { .fullAccess }
}
