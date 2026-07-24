import XCTest
import CoreModel
import ServiceManagement
@testable import AppShell

final class ScheduledTaskRuntimeTests: XCTestCase {
    func test_reconciledDueDateLeavesPastDueUnchanged_becauseMissedFiresAreSkippedOnlyOnLaunch() {
        // WHY: while the app is open, claimDue must still see next_run_at <= now.
        // Catch-up compression of a multi-day backlog is intentionally gone.
        let now = Date(timeIntervalSince1970: 10 * 24 * 60 * 60)
        let past = Date(timeIntervalSince1970: 0)
        let task = makeHourly(nextRunAt: past)

        let reconciled = ScheduledTaskScheduler.reconciledDueDate(task: task, now: now)

        XCTAssertEqual(reconciled, past)
    }

    func test_reconciledDueDateFillsMissingNextRun_becauseEnabledTasksNeedASchedulePointer() {
        let now = Date(timeIntervalSince1970: 3 * 24 * 60 * 60)
        var task = makeHourly(nextRunAt: nil)
        task.recurrence = .once(at: Date(timeIntervalSince1970: 0))
        task.nextRunAt = nil

        // Once-in-the-past with nil next: calculatedNextRun returns nil.
        XCTAssertNil(ScheduledTaskScheduler.reconciledDueDate(task: task, now: now))
    }

    func test_catchUpWindowIsZero_becauseMissedFiresMustNotReplayOnRelaunch() {
        // WHY: product decision — schedules only run while RemoteCode is open;
        // reopening must not claim backlog within a 24h window.
        XCTAssertEqual(ScheduledTaskScheduler.catchUpWindow, 0)
    }

    func test_executeAdvancesWithSpentOccurrenceHelper_becauseTruncationMustNotRestall() throws {
        // WHY: source contract — after claim, next pointer must use afterSpent
        // (+1s), not bare calculatedNextRun(after: scheduledAt).
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/ScheduledTaskRuntime.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("calculatedNextRunAfterSpent"))
        XCTAssertFalse(
            source.contains("calculatedNextRun(after: claim.run.scheduledAt)"),
            "execute must not advance with the raw spent scheduledAt"
        )
    }

    func test_eligibleUsersIncludesCurrentNonRootUser_becauseEditorMustOfferRunnableIdentity() throws {
        let user = try XCTUnwrap(ScheduledSystemUserCatalog.user(named: NSUserName()))
        XCTAssertNotEqual(user.uid, 0)
        XCTAssertTrue(ScheduledSystemUserCatalog.eligibleUsers().contains(user))
    }

    func test_isolatedE2EDisablesManagedDistillReconcile_becauseItMustNotMutateRunningAppTools() {
        XCTAssertFalse(AppContext.shouldReconcileManagedDistillIntegration(
            isRunningUnitTests: false,
            hasSkillsHomeOverride: false,
            environment: ["RC2_DISABLE_MANAGED_DISTILL_RECONCILE": "1"]
        ))
        XCTAssertTrue(AppContext.shouldReconcileManagedDistillIntegration(
            isRunningUnitTests: false,
            hasSkillsHomeOverride: false,
            environment: [:]
        ))
    }

    @MainActor
    func test_notFoundStillRegisters_becausePackagedAgentsCanReportItBeforeFirstRegistration() {
        XCTAssertTrue(ScheduledTaskAgentServiceManager.registrationIsRequired(for: .notFound))
        XCTAssertTrue(ScheduledTaskAgentServiceManager.registrationIsRequired(for: .notRegistered))
        XCTAssertFalse(ScheduledTaskAgentServiceManager.registrationIsRequired(for: .enabled))
        XCTAssertFalse(ScheduledTaskAgentServiceManager.registrationIsRequired(for: .requiresApproval))
    }

    func test_headlessAgentUsesDurableProviderOwnershipStore_becauseProviderSpawnMustBeCrashSafe() {
        let root = URL(fileURLWithPath: "/tmp/remote-code-scheduled-test", isDirectory: true)
        XCTAssertEqual(
            ScheduledTaskAgentAppDelegate.providerOwnershipFile(in: root).path,
            "/tmp/remote-code-scheduled-test/diagnostics/provider-process-ownership.json"
        )
    }

    func test_crossUserRunnerIsTraversableButNotWritable_becauseSudoTargetMustExecuteWithoutReplacingIt() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/ScheduledTaskRuntime.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".posixPermissions: 0o711"))
        XCTAssertTrue(source.contains(".posixPermissions: 0o755"))
        XCTAssertFalse(source.contains("--preserve-env"))
    }

    func test_runtimePreservesFrozenProviderAndReportsManualClaimFailures_becauseRunNowMustNotSilentlyChangeOrDrop() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/ScheduledTaskRuntime.swift"))

        XCTAssertFalse(source.contains("?? snapshots.first(where: { $0.provider == task.provider })"))
        XCTAssertTrue(source.contains("completion(.failure(error))"))
        XCTAssertTrue(source.contains("scheduler.runNow(taskID: id) { result in"))
        XCTAssertTrue(source.contains("store.listActiveRuns()"))
    }

    func test_preflightErrorLocalizedDescriptionPreservesMessage_becauseRunNowAlertMustNotShowError0() {
        // WHY: without LocalizedError, NSError bridging surfaces
        // "AppShell.ScheduledTaskPreflightError error 0" and hides the payload.
        let cases: [ScheduledTaskPreflightError] = [
            .invalidTask("Two scheduled task runs are already active."),
            .missingWorkspace,
            .inaccessibleWorkspace("/tmp/ws"),
            .ineligibleUser("nobody"),
            .sudoUnavailable("guest"),
            .providerUnavailable("Provider not signed in."),
            .unsupportedModel("gpt-x"),
            .unsupportedReasoning("High"),
        ]
        for error in cases {
            XCTAssertEqual(error.localizedDescription, error.description, String(describing: error))
            XCTAssertFalse(
                error.localizedDescription.contains("error 0")
                    || error.localizedDescription.contains("ScheduledTaskPreflightError error"),
                "localizedDescription leaked NSError bridge: \(error.localizedDescription)"
            )
        }
        let asError: Error = ScheduledTaskPreflightError.invalidTask("Scheduler version mismatch. Retry.")
        XCTAssertEqual(asError.localizedDescription, "Scheduler version mismatch. Retry.")
    }

    func test_autoRoutingConfigurationCarriesScheduledFallbackAndEligibleProviders() {
        var task = makeHourly(nextRunAt: nil)
        task.routingMode = .auto

        let configuration = ScheduledTaskExecutor.routingConfiguration(
            for: task,
            policyDigest: String(repeating: "a", count: 64),
            eligibleProviders: [.codex, .grok]
        )

        XCTAssertEqual(configuration.mode, .auto)
        XCTAssertEqual(configuration.manualSelection.provider, task.provider)
        XCTAssertEqual(configuration.manualSelection.effectiveModel, task.model)
        XCTAssertEqual(configuration.manualProviderInstanceId, task.providerInstanceID)
        XCTAssertEqual(configuration.eligibleProviders, [.codex, .grok])
        XCTAssertEqual(configuration.revision, 1)
    }

    func test_rejectUIOnlySchedulePrompt_blocksLocalAgentCommands_becauseScheduleIsPasteAndPlay() {
        // WHY: Agent App intercepts /clear /status etc. without a provider turn —
        // including argument-bearing forms like `/clear foo`.
        XCTAssertThrowsError(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("/clear"))
        XCTAssertThrowsError(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("/clear history"))
        XCTAssertThrowsError(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("$status"))
        XCTAssertThrowsError(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("/model gpt-5"))
        XCTAssertThrowsError(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("/fork"))
        XCTAssertThrowsError(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("/plan"))
        XCTAssertThrowsError(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("/plan implement the feature"))
        XCTAssertThrowsError(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("/default"))
        XCTAssertNoThrow(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("/default Ship the deploy pipeline"))
        XCTAssertNoThrow(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("Ship the deploy pipeline"))
        XCTAssertNoThrow(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("$sam-work DEV-1"))
        XCTAssertNoThrow(try ScheduledTaskExecutor.rejectUIOnlySchedulePrompt("/goal reduce latency"))
    }

    func test_executeRunsHeadlessWithoutUIFocus_becauseSchedulesMustNotHijackTheUser() throws {
        // Source contract: scheduled fires create a durable thread + start via
        // sendAgentMessage. They must not activate the app, switch workspaces,
        // focus Agent App, write the composer, or depend on viewModel.send().
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/ScheduledTaskRuntime.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("router.createAgentThread("))
        XCTAssertTrue(source.contains("router.sendAgentMessage("))
        XCTAssertTrue(source.contains("surfaceID: nil"))
        XCTAssertTrue(source.contains("permissionMode: .fullAccess"))
        XCTAssertTrue(source.contains("interactionMode: .default"))
        XCTAssertTrue(source.contains("orchestrationRoutingSnapshot: prepared.routingSnapshot"))
        XCTAssertTrue(source.contains("skipMissedOccurrencesOnLaunch"))
        XCTAssertTrue(source.contains("reclaimOrphanedActiveRuns"))
        XCTAssertFalse(source.contains("openAgentAppForSchedule"))
        XCTAssertFalse(source.contains("await vm.send()"))
        XCTAssertFalse(source.contains("createThread(title: \"New thread\")"))
        XCTAssertFalse(source.contains("NSApplication.shared.activate"))
        XCTAssertFalse(source.contains("selectWorkspace("))
        XCTAssertFalse(
            source.contains("modelDiscoverySource == .live"),
            "Auto preflight must not be stricter than Agent App (requireLiveCatalog false)"
        )
    }

    func test_mainAppOwnsScheduler_becauseLaunchAgentMustNotDualClaim() throws {
        let main = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/Main.swift"),
            encoding: .utf8
        )
        let delegate = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/AppDelegate.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(main.contains("background agent unregistered"))
        XCTAssertFalse(main.contains("ScheduledTaskAgentAppDelegate("))
        XCTAssertTrue(delegate.contains("startInProcessScheduledTaskScheduler"))
        XCTAssertTrue(delegate.contains("ScheduledTaskAgentServiceManager().unregister()"))
        XCTAssertTrue(delegate.contains("router.scheduledTaskScheduler = scheduler"))
    }

    func test_runNowUsesInProcessScheduler_becauseXPCIsRetired() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/ScheduledTasksWindow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("router.scheduledTaskScheduler"))
        XCTAssertTrue(source.contains("scheduler.runNow(taskID:"))
        XCTAssertFalse(source.contains("service.wake(taskID:"))
        XCTAssertFalse(source.contains("try service.register()"))
    }

    func test_crossUserAutoUsesOneRunnerPerProvider_becauseRoutesMustLaunchTheAdmittedCLI() {
        let id = UUID()

        let codex = ScheduledTaskExecutor.runnerFilename(taskID: id, providerInstanceID: "codex-primary")
        let grok = ScheduledTaskExecutor.runnerFilename(taskID: id, providerInstanceID: "grok/primary")

        XCTAssertNotEqual(codex, grok)
        XCTAssertTrue(codex.hasSuffix("-codex-primary.sh"))
        XCTAssertTrue(grok.hasSuffix("-grok-primary.sh"))
    }

    func test_autoRoutingIsBoundToSavedProviderAccount_becauseScheduledRunsMustNotSubstituteSource() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/ScheduledTaskRuntime.swift"), encoding: .utf8)

        // Auto may only admit the exact saved provider + instance (SCHED-005).
        XCTAssertTrue(source.contains("$0.id == task.providerInstanceID"))
        XCTAssertTrue(source.contains("eligibleProviders: [task.provider]"))
        XCTAssertTrue(source.contains("is unavailable for Auto model routing"))
    }

    func test_preflightProbesAuthenticationInSelectedUserContext_becauseAccountsMustNotLeakAcrossHomes() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/ScheduledTaskRuntime.swift"))

        XCTAssertTrue(source.contains("ProviderCLIProbe.authenticated("))
        XCTAssertTrue(source.contains("probeEnvironment = user.name == NSUserName()"))
        XCTAssertTrue(source.contains("The selected provider is unavailable for system user"))
    }

    func test_helperPostsFailureNotifications_becauseUnattendedErrorsMustBeVisible() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/ScheduledTaskRuntime.swift"))

        XCTAssertTrue(source.contains("SystemNotifier.shared.bootstrap()"))
        XCTAssertTrue(source.contains("title: \"Scheduled task failed\""))
    }

    private func makeHourly(nextRunAt: Date?) -> ScheduledTask {
        ScheduledTask(
            title: "Hourly", prompt: "Run", workspaceID: WorkspaceID(), workspacePathSnapshot: "/tmp",
            runAsUser: NSUserName(), runAsUID: ScheduledSystemUserCatalog.user(named: NSUserName())?.uid ?? 501,
            provider: .codex, providerInstanceID: "codex", model: "gpt-5", reasoningEffort: .high,
            recurrence: .hourly(anchor: Date(timeIntervalSince1970: 0), intervalHours: 1),
            timeZoneIdentifier: "UTC", nextRunAt: nextRunAt
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
