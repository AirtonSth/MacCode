import XCTest
import CoreModel
@testable import AppShell
@testable import Persistence

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

    func test_sidebarPlacesScheduleTasksAfterActiveThreads_becauseNavigationOrderIsContractual() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        let newWorkspace = try XCTUnwrap(source.range(of: "accessibilityIdentifier(\"sidebar.newWorkspace\")"))
        let activeThreads = try XCTUnwrap(source.range(of: "accessibilityIdentifier(\"sidebar.activeThreads\")"))
        let scheduleTasks = try XCTUnwrap(source.range(of: "accessibilityIdentifier(\"sidebar.scheduleTasks\")"))
        let reportBug = try XCTUnwrap(source.range(of: "accessibilityIdentifier(\"sidebar.reportBug\")"))
        let updateControl = try XCTUnwrap(source.range(of: "if vm.showsUpdateControl"))

        XCTAssertLessThan(reportBug.lowerBound, newWorkspace.lowerBound,
                          "Report Bug is a header icon, not a dest row under Schedule Tasks")
        XCTAssertLessThan(newWorkspace.lowerBound, activeThreads.lowerBound)
        XCTAssertLessThan(activeThreads.lowerBound, scheduleTasks.lowerBound)
        XCTAssertLessThan(scheduleTasks.lowerBound, updateControl.lowerBound)
    }

    func test_sidebarReportBugOpensMailtoToMaintainer_becauseBugReportsMustReachSupport() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("accessibilityLabel(\"Report Bug\")"),
                      "sidebar must expose Report Bug as a header icon")
        XCTAssertTrue(source.contains(".help(\"Report a bug via email\")"),
                      "the header ladybug must keep a tooltip")
        XCTAssertTrue(source.contains("samuelfajreldines@gmail.com"),
                      "Report Bug must address the maintainer mailbox")
        XCTAssertTrue(source.contains("mailto"),
                      "Report Bug must open a mailto: compose window")
        XCTAssertTrue(source.contains("NSWorkspace.shared.open"),
                      "Report Bug must hand off to the system mail client")
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

    func test_savePreflightsBeforePersist_becauseInvalidTasksMustNotBeSavedActive() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        // WHY: save still preflights provider/workspace before persisting. Login
        // Items approval is retired — schedules run in-process while the app is open.
        XCTAssertTrue(source.contains(".preflight(task)"))
        XCTAssertTrue(source.contains("router.scheduledTaskScheduler"))
        XCTAssertFalse(source.contains("scheduledTasks.openLoginItems"))
        XCTAssertFalse(source.contains("Task saved paused."))
    }

    func test_failureDetailsCanExpand_becauseSafeHistoryErrorsMustRemainInspectable() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("expandedRunIDs"))
        XCTAssertTrue(source.contains("Show details"))
        XCTAssertTrue(source.contains("Hide details"))
        XCTAssertTrue(source.contains("scheduledTasks.history.toggleDetails"),
                      "failure disclosure must be a dedicated control, not the whole row")
    }

    func test_failedHistoryRowShowsReasonWithoutExpansion_becauseFailureMustNotBeOpaque() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        let primaryStart = try XCTUnwrap(source.range(of: "private func historyRowPrimaryContent"))
        let primaryEnd = try XCTUnwrap(source.range(of: "private func agentTaskTitle"))
        let primary = String(source[primaryStart.lowerBound..<primaryEnd.lowerBound])

        XCTAssertTrue(primary.contains("if run.status == .failed, let error = run.errorSummary"))
        XCTAssertTrue(primary.contains("Text(error)"))
        XCTAssertTrue(primary.contains(".lineLimit(1)"),
                      "the visible reason must keep history rows compact; full text stays in details")
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

    func test_searchAndSelectionUseScopedDeferredPasses_becauseOverviewHydrationMustNotRepeat() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("scheduleTasksRefreshPass()"))
        XCTAssertTrue(source.contains("scheduleRunsRefreshPass()"))
        XCTAssertTrue(source.contains("tasksRefreshGeneration &+= 1"))
        XCTAssertTrue(source.contains("runsRefreshGeneration &+= 1"))
        XCTAssertTrue(source.contains("finishTasksRefreshTask(ownedBy: generation)"))
        XCTAssertTrue(source.contains("finishRunsRefreshTask(ownedBy: generation)"))
        XCTAssertFalse(
            source.contains("if deferHydration { scheduleFreshnessPass() } else { reloadTasks() }"),
            "typing in the overview must not re-run unrelated workspace/provider hydration"
        )
        XCTAssertFalse(
            source.contains("if deferHydration { scheduleFreshnessPass() } else { reloadRuns() }"),
            "selecting a task must not re-run unrelated overview hydration"
        )
    }

    @MainActor
    func test_scopedRefreshPublishesExactTaskAndRunResults_latestSearchWins() async throws {
        let directory = NSTemporaryDirectory() + "rc-scheduled-refresh-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let store = ScheduledTaskStore(db: context.db)
        let workspaceID = WorkspaceID()
        let older = ScheduledTask(
            title: "Alpha task", prompt: "Alpha prompt", workspaceID: workspaceID,
            workspacePathSnapshot: "/tmp", runAsUser: NSUserName(), runAsUID: 501,
            provider: .codex, providerInstanceID: "codex", model: "gpt-5", reasoningEffort: .high,
            recurrence: .hourly(anchor: Date(timeIntervalSince1970: 0), intervalHours: 1),
            timeZoneIdentifier: "UTC",
            createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = ScheduledTask(
            title: "Beta task", prompt: "Beta prompt", workspaceID: workspaceID,
            workspacePathSnapshot: "/tmp", runAsUser: NSUserName(), runAsUID: 501,
            provider: .codex, providerInstanceID: "codex", model: "gpt-5", reasoningEffort: .high,
            recurrence: .hourly(anchor: Date(timeIntervalSince1970: 0), intervalHours: 1),
            timeZoneIdentifier: "UTC",
            createdAt: Date(timeIntervalSince1970: 20), updatedAt: Date(timeIntervalSince1970: 20)
        )
        try store.save(older)
        try store.save(newer)
        let claim = try store.claimManual(
            taskID: older.id,
            now: Date(timeIntervalSince1970: 30),
            owner: "scheduled-refresh-test"
        )
        try store.finish(
            runID: claim.run.id,
            status: .failed,
            errorCode: "provider_unavailable",
            errorSummary: "provider unavailable",
            at: Date(timeIntervalSince1970: 40)
        )
        let expectedTasks = try store.list()

        let viewModel = ScheduledTasksViewModel(context: context, router: router, loadImmediately: false)
        viewModel.scheduleFreshnessPass()
        await viewModel.waitForFreshnessForTesting()
        XCTAssertEqual(viewModel.tasks, expectedTasks,
                       "the initial pass must publish the exact persisted task order")
        XCTAssertEqual(viewModel.fullHydrationCountForTesting, 1)

        viewModel.selectedTaskID = older.id
        XCTAssertEqual(viewModel.selectedTaskID, older.id,
                       "selection must be acknowledged before the scoped history read")
        await viewModel.waitForFreshnessForTesting()
        XCTAssertEqual(viewModel.runs.map(\.id), [claim.run.id])
        XCTAssertEqual(viewModel.runs.first?.taskID, older.id)
        XCTAssertEqual(viewModel.runs.first?.status, .failed)
        XCTAssertEqual(viewModel.runs.first?.errorCode, "provider_unavailable")
        XCTAssertEqual(viewModel.runs.first?.errorSummary, "provider unavailable")

        let hydrationCount = viewModel.fullHydrationCountForTesting
        viewModel.searchText = "Alpha"
        viewModel.searchText = "Beta"
        await viewModel.waitForFreshnessForTesting()
        XCTAssertEqual(viewModel.tasks.map(\.id), [newer.id],
                       "the latest search must win and publish only its exact task projection")
        XCTAssertEqual(viewModel.fullHydrationCountForTesting, hydrationCount,
                       "search refreshes must not repeat the full overview hydration")

        let publishedTasksBeforeFailure = viewModel.tasks
        try context.db.execute("DROP TABLE scheduled_tasks")
        viewModel.searchText = "Beta"
        await viewModel.waitForFreshnessForTesting()
        XCTAssertEqual(viewModel.tasks, publishedTasksBeforeFailure,
                       "a failed scoped read must not replace the last known task projection")
        XCTAssertNotNil(viewModel.errorMessage,
                        "a failed scoped read must remain visible to the user")
    }

    func test_scopedTaskAndRunRefreshesKeepLatestWinsAndFailureVisible() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        for marker in [
            "guard !Task.isCancelled,\n                  self.tasksRefreshGeneration == generation else { return }",
            "guard !Task.isCancelled,\n                  self.runsRefreshGeneration == generation else { return }",
            "self.reloadTasks()",
            "self.reloadRuns()",
            "errorMessage = String(describing: error)"
        ] {
            XCTAssertTrue(source.contains(marker), "scoped refresh contract missing: \(marker)")
        }
        XCTAssertTrue(source.contains("self.selectedTaskID = nil"),
                      "a stale selection must clear when the winning task projection no longer contains it")
        XCTAssertTrue(source.contains("activeRunStatuses = next"),
                      "exact run status results must republish the overview badge state")
    }

    func test_scheduledExecutionUsesHeadlessSendPath_becauseSchedulesMustNotStealFocus() throws {
        let runtime = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTaskRuntime.swift"), encoding: .utf8)
        let main = try String(contentsOf: sourceURL("Sources/AppShell/AppDelegate.swift"), encoding: .utf8)
        let router = try String(contentsOf: sourceURL("Sources/AppShell/AppCommandRouter.swift"), encoding: .utf8)
        // Headless in-process: createAgentThread(surfaceID: nil) + sendAgentMessage.
        // Main app owns the scheduler; legacy LaunchAgent is unregistered.
        // openAgentAppForSchedule remains for intentional focus deep-links only.
        XCTAssertTrue(runtime.contains("router.createAgentThread("))
        XCTAssertTrue(runtime.contains("router.sendAgentMessage("))
        XCTAssertTrue(runtime.contains("surfaceID: nil"))
        XCTAssertTrue(runtime.contains("func stop(threadID:"))
        XCTAssertTrue(runtime.contains("ScheduledTaskCrossProcess.notifyStoreChanged"))
        XCTAssertTrue(runtime.contains("skipMissedOccurrencesOnLaunch"))
        XCTAssertTrue(main.contains("startInProcessScheduledTaskScheduler"))
        XCTAssertTrue(main.contains("installScheduledTaskStoreObserver"))
        XCTAssertTrue(router.contains("openAgentAppForSchedule"))
        XCTAssertTrue(router.contains("scheduledTaskScheduler"))
        XCTAssertFalse(runtime.contains("openAgentAppForSchedule"))
        XCTAssertFalse(runtime.contains("await vm.send()"))
        XCTAssertFalse(
            runtime.contains("context.coordinator.startRun("),
            "scheduled execute must start via sendAgentMessage, not a raw coordinator call"
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
        XCTAssertTrue(source.contains("Runs inside RemoteCode while the app is open"))
        // Plan-faithful chrome: full-width card list + full-page editor groups.
        XCTAssertTrue(source.contains("ScheduledTaskCard("))
        XCTAssertTrue(source.contains("Automate recurring agent work"))
        XCTAssertTrue(source.contains("editorGroup(\"Details\")"))
        XCTAssertTrue(source.contains("editorGroup(\"Frequency\")"))
        XCTAssertTrue(source.contains("Run History"))
        XCTAssertTrue(source.contains("Save Task"))
        XCTAssertFalse(source.contains("HSplitView"),
                       "plan mockups use a single-column stack, not master-detail split")
        XCTAssertFalse(source.contains("Open Login Items"),
                       "Login Items approval is retired with LaunchAgent Path B")
    }

    func test_overviewExposesGlobalActiveToggle_becauseTravelPauseMustStopAllSchedules() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)
        let runtime = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTaskRuntime.swift"), encoding: .utf8)
        let settings = try String(contentsOf: sourceURL("Sources/Persistence/SettingsStore.swift"), encoding: .utf8)
        // WHY: users need one switch to pause every automatic occurrence (e.g. travel)
        // without deleting or individually pausing each task.
        XCTAssertTrue(source.contains("scheduledTasks.globalActive"))
        XCTAssertTrue(source.contains("setSchedulerActive"))
        XCTAssertTrue(source.contains("schedulerActive"))
        XCTAssertTrue(source.contains("schedulerActiveControl"))
        XCTAssertTrue(source.contains("AgentKillSwitchControl("))
        // UX: state is not color-only — icon + Active/Paused label + switch.
        // Paint lives on AgentKillSwitchControl; this window only mounts it.
        let chrome = try String(contentsOf: sourceURL("Sources/Surfaces/AgentListChrome.swift"), encoding: .utf8)
        XCTAssertTrue(chrome.contains("bolt.fill"))
        XCTAssertTrue(chrome.contains("pause.fill"))
        XCTAssertTrue(chrome.contains("\"Paused\""))
        XCTAssertTrue(chrome.contains("Travel pause"))
        XCTAssertTrue(settings.contains("scheduledTasksActive"))
        XCTAssertTrue(runtime.contains("scheduledTasksActive"))
        XCTAssertTrue(runtime.contains("global_active=false")
                      || runtime.contains("settings.scheduledTasksActive"))
        // Layout: Active control sits to the right of New Task.
        let newTask = try XCTUnwrap(source.range(of: "scheduledTasks.new"))
        let globalActive = try XCTUnwrap(source.range(of: "scheduledTasks.globalActive"))
        XCTAssertLessThan(newTask.lowerBound, globalActive.lowerBound,
                          "Active toggle must appear after New Task in the overview header")
        // Footer uses status pill (icon+text), not a color-only dot.
        XCTAssertTrue(source.contains("Scheduler paused"))
        XCTAssertTrue(source.contains("DSPill("))
    }

    func test_editorKeepsProviderPickersWithAuto_becauseAutoOnlySelectsModel() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/ScheduledTasksWindow.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("scheduledTasks.editor.autoRouting"))
        XCTAssertTrue(source.contains("scheduledTasks.editor.provider"))
        // Agent App parity: one Provider/Source picker only — no account row.
        XCTAssertFalse(source.contains("scheduledTasks.editor.providerAccount"))
        XCTAssertFalse(source.contains("formRow(\"Provider account\")"))
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
        // Auto → Manual must restore model from the selected provider instance.
        XCTAssertTrue(source.contains("$0.id == draft.providerInstanceID && $0.provider == draft.provider"))
        XCTAssertFalse(source.contains("vm.providers.first(where: { $0.enabled && $0.installed }) ?? vm.providers.first"))
    }

    func test_mainUnregistersLegacyScheduledAgent_becauseSchedulesRunInProcess() throws {
        let source = try String(contentsOf: sourceURL("Sources/AppShell/Main.swift"), encoding: .utf8)
        // WHY: leftover LaunchAgent installs must not dual-claim after upgrade.
        XCTAssertTrue(source.contains("--scheduled-task-agent"))
        XCTAssertTrue(source.contains("ScheduledTaskAgentServiceManager().unregister()"))
        XCTAssertTrue(source.contains("background agent unregistered"))
        XCTAssertFalse(source.contains("ScheduledTaskAgentAppDelegate("))
    }

    private func sourceURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(relative)
    }
}

private extension ScheduledTask {
    var permissionModeForScheduledExecution: AgentPermissionMode { .fullAccess }
}
