import XCTest
import CoreModel
import ServiceManagement
@testable import AppShell

final class ScheduledTaskRuntimeTests: XCTestCase {
    func test_catchUpKeepsOnlyMostRecentOccurrenceWithin24Hours_becauseWakeMustNotReplayBacklog() {
        let now = Date(timeIntervalSince1970: 10 * 24 * 60 * 60)
        let task = makeHourly(nextRunAt: Date(timeIntervalSince1970: 0))

        let reconciled = ScheduledTaskScheduler.reconciledDueDate(task: task, now: now)

        XCTAssertEqual(reconciled, now)
    }

    func test_catchUpSkipsExpiredOnceOccurrence_becauseOldOneShotWorkMustNotRunUnexpectedly() {
        let now = Date(timeIntervalSince1970: 3 * 24 * 60 * 60)
        var task = makeHourly(nextRunAt: nil)
        task.recurrence = .once(at: Date(timeIntervalSince1970: 0))
        task.nextRunAt = Date(timeIntervalSince1970: 0)

        XCTAssertNil(ScheduledTaskScheduler.reconciledDueDate(task: task, now: now))
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

    func test_crossUserAutoUsesOneRunnerPerProvider_becauseRoutesMustLaunchTheAdmittedCLI() {
        let id = UUID()

        let codex = ScheduledTaskExecutor.runnerFilename(taskID: id, providerInstanceID: "codex-primary")
        let grok = ScheduledTaskExecutor.runnerFilename(taskID: id, providerInstanceID: "grok/primary")

        XCTAssertNotEqual(codex, grok)
        XCTAssertTrue(codex.hasSuffix("-codex-primary.sh"))
        XCTAssertTrue(grok.hasSuffix("-grok-primary.sh"))
    }

    func test_executorPassesImmutableAutoSnapshotToCoordinator_becauseScheduledRunsMustActuallyRoute() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/ScheduledTaskRuntime.swift"))

        XCTAssertTrue(source.contains("routingSnapshot: prepared.routingSnapshot"))
        XCTAssertTrue(source.contains("launchConfigurations: launches"))
        XCTAssertTrue(source.contains("orchestrationRuntime.route("))
    }

    func test_preflightProbesAuthenticationInSelectedUserContext_becauseAccountsMustNotLeakAcrossHomes() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/ScheduledTaskRuntime.swift"))

        XCTAssertTrue(source.contains("ProviderCLIProbe.authenticated("))
        XCTAssertTrue(source.contains("probeEnvironment = user.name == NSUserName()"))
        XCTAssertTrue(source.contains("The selected provider account is unavailable for system user"))
    }

    func test_xpcChecksBundleAndProtocolVersion_becauseUpdatesMustReplaceStaleHelpers() throws {
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/ScheduledTaskRuntime.swift"))

        XCTAssertTrue(source.contains("public static let protocolVersion = 1"))
        XCTAssertTrue(source.contains("proxy.ping { version in"))
        XCTAssertTrue(source.contains("version == Self.serviceVersion"))
        XCTAssertTrue(source.contains("Scheduler version mismatch"))
        XCTAssertTrue(source.contains("try self.unregister()"))
        XCTAssertTrue(source.contains("try self.register()"))
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
