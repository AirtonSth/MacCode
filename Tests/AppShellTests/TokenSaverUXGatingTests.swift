import XCTest
import AppKit
@testable import AppShell
import AgentRuntime
import CoreModel
@testable import Persistence

// WHY these tests exist (Rule 8):
// :185 -- A paused download shows only Cancel; Resume must exist and re-start
//         the download. Without this test a paused download is stuck -- the
//         user can only Cancel and lose progress context.
// :190 -- A blocked sidecar leaves the headline unchanged; the degraded copy
//         must appear so the user knows compression stopped, not just "Saved X
//         tokens" which implies everything is fine.
// :191 -- setTokenSaverEnabled(false) previously stopped + uninstalled with no
//         warning. The confirm gate must fire; bypassing it (gate returns false)
//         must leave Token Saver enabled.

@MainActor
final class TokenSaverUXGatingTests: XCTestCase {

    // MARK: - Shared helpers

    private final class FakeInsomniaPower: InsomniaPowerManaging {
        func activate(reason: String, options: InsomniaPowerOptions) -> Bool { true }
        func deactivate() {}
        func releaseProcessAssertions() {}
    }

    private final class FakeExternalPowerMonitor: ExternalPowerMonitoring {
        var currentPowerState: ExternalPowerState = .externalPower
        var onPowerStateChanged: (@MainActor (ExternalPowerState) -> Void)?
        func start() {}
        func stop() {}
    }

    private func makeVM(
        dir: String = NSTemporaryDirectory() + "RC2UXGate-" + UUID().uuidString,
        subscribed: Bool = true,
        downloadHandler: SidebarViewModel.TokenSaverModelDownloadHandler? = nil,
        validationProvider: SidebarViewModel.TokenSaverModelValidationProvider? = nil,
        downloadConfirmProvider: SidebarViewModel.TokenSaverDownloadConfirmProvider? = nil,
        disableConfirmProvider: SidebarViewModel.TokenSaverDisableConfirmProvider? = nil,
        operationErrorPresenter: @escaping SidebarViewModel.OperationErrorPresenter = { _, _ in }
    ) throws -> (AppContext, AppCommandRouter, SidebarViewModel) {
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        if subscribed {
            PrivateAccountSessionStore(repo: ctx.settingsRepo).save(PrivateAccountSession(
                accessToken: "tok",
                refreshToken: "ref",
                user: PrivateAccountUser(
                    daysRemaing: nil,
                    daysRemaining: 30,
                    email: "test@example.com",
                    id: "uid",
                    subscribed: true
                )
            ))
        }
        let vm = SidebarViewModel(
            context: ctx,
            router: router,
            insomniaPower: FakeInsomniaPower(),
            powerMonitor: FakeExternalPowerMonitor(),
            tokenSaverModelValidationProvider: validationProvider,
            tokenSaverModelDownloadHandler: downloadHandler,
            tokenSaverDownloadConfirmProvider: downloadConfirmProvider,
            tokenSaverDisableConfirmProvider: disableConfirmProvider,
            operationErrorPresenter: operationErrorPresenter
        )
        vm.reload()
        return (ctx, router, vm)
    }

    func test_projectGovernanceIsWorkspaceScopedAndDefaultsGuardedOff() throws {
        let (context, _, vm) = try makeVM()
        let selectedWorkspace = WorkspaceID()
        let otherWorkspace = WorkspaceID()
        let selectedProject = ProjectRepository.Project(
            id: ProjectID(), name: "Selected", path: "/tmp/selected", favorite: false,
            createdAt: Date(), updatedAt: Date()
        )
        let otherProject = ProjectRepository.Project(
            id: ProjectID(), name: "Other", path: "/tmp/other", favorite: false,
            createdAt: Date(), updatedAt: Date()
        )
        try context.projectRepo.upsert(selectedProject)
        try context.projectRepo.upsert(otherProject)
        try context.threadRepo.upsert(.init(
            projectId: selectedProject.id, workspaceId: selectedWorkspace,
            title: "selected", provider: .codex, model: "m"
        ))
        try context.threadRepo.upsert(.init(
            projectId: otherProject.id, workspaceId: otherWorkspace,
            title: "other", provider: .claude, model: "m"
        ))

        vm.selectedWorkspaceID = selectedWorkspace
        vm.reloadTokenSaverGovernance()

        XCTAssertEqual(vm.tokenSaverProjectGovernance.map(\.projectName), ["Selected"],
                       "project controls must not expose a different workspace scope")
        let governance = try XCTUnwrap(vm.tokenSaverProjectGovernance.first)
        XCTAssertEqual(governance.lanes.count, 10)
        XCTAssertEqual(governance.stateLabel, "Shadow only")
        XCTAssertEqual(governance.promotedLaneCount, 0)
        XCTAssertEqual(governance.shadowLaneCount, 2)
        XCTAssertEqual(governance.activeLaneCount, 0)
        XCTAssertFalse(governance.rolloverAvailable,
                       "rollover stays disabled until its owner and scorecard promote the lane")
    }

    func test_projectGovernanceShadowLaneIsNotClaimedAsActive() {
        let governance = SidebarViewModel.TokenSaverProjectGovernance(
            projectID: "project",
            projectName: "Shadow",
            lanes: [TokenSaverLaneStateRecord(
                projectID: "project", lane: "semantic_prose", state: "shadow_only",
                reason: "shadow_evaluation", evidenceLevel: "diagnostic_heuristic",
                ownerRole: "Model Supply-Chain Owner", permissionBoundary: "project",
                retentionDays: 7, optedOut: false, killSwitchActive: false
            )]
        )

        XCTAssertEqual(governance.stateLabel, "Shadow only")
        XCTAssertEqual(governance.promotedLaneCount, 0)
        XCTAssertEqual(governance.shadowLaneCount, 1)
        XCTAssertEqual(governance.activeLaneCount, 0,
                       "shadow evaluation must not be presented as active provider behavior")
        XCTAssertEqual(governance.laneSummaryLabel, "0 promoted · 1 shadow")
        XCTAssertEqual(SidebarRootView.tokenSaverLaneStateLabel("promoted"), "Active")
        XCTAssertEqual(SidebarRootView.tokenSaverLaneStateLabel("shadow_only"), "Shadow")
        XCTAssertEqual(SidebarRootView.tokenSaverLaneStateLabel("off"), "Off")
    }

    func test_rolloverAvailabilityRequiresPositiveRetentionAndUsesRuntimeReason() {
        func governance(retentionDays: Int) -> SidebarViewModel.TokenSaverProjectGovernance {
            .init(
                projectID: "project",
                projectName: "Rollover",
                lanes: [TokenSaverLaneStateRecord(
                    projectID: "project", lane: "rollover_capsule", state: "promoted",
                    reason: "retention_required", evidenceLevel: "provider_usage",
                    ownerRole: "Provider Compatibility Owner", permissionBoundary: "project",
                    retentionDays: retentionDays, optedOut: false, killSwitchActive: false
                )],
                rolloverAdmission: .init(allowed: true, reason: "admitted")
            )
        }

        let blocked = governance(retentionDays: 0)
        XCTAssertFalse(blocked.rolloverAvailable)
        XCTAssertEqual(blocked.rolloverReason, "retention_not_positive",
                       "UI blocked reason must match the reason returned by the runtime lane gate")
        XCTAssertTrue(governance(retentionDays: 7).rolloverAvailable)
    }

    func test_lifecycleDegradedStateIsVisibleAndNeverClaimedActive() {
        let governance = SidebarViewModel.TokenSaverProjectGovernance(
            projectID: "project",
            projectName: "Degraded",
            lanes: [TokenSaverLaneStateRecord(
                projectID: "project", lane: "rollover_capsule", state: "promoted",
                reason: "scorecard_passed", evidenceLevel: "provider_usage",
                ownerRole: "Product Owner", permissionBoundary: "project",
                retentionDays: 7, optedOut: false, killSwitchActive: false
            )],
            lifecycleDegradedReason: "lifecycle_sweep_failed: disk I/O",
            rolloverAdmission: .init(allowed: false, reason: "lifecycle_degraded")
        )

        XCTAssertEqual(governance.promotedLaneCount, 1)
        XCTAssertEqual(governance.stateLabel, "Degraded (verbatim)",
                       "global lifecycle failure must override an otherwise promoted UI claim")
        XCTAssertFalse(governance.rolloverAvailable)
        XCTAssertEqual(governance.rolloverReason, "lifecycle_degraded")
    }

    func test_rolloverAvailabilityUsesAuthoritativeAdmissionReasons() {
        let deniedReasons = [
            "globally_disabled",
            "lifecycle_degraded",
            "evidence_not_authoritative",
            "owner_unassigned",
            "missing_project_scope"
        ]
        for reason in deniedReasons {
            let governance = SidebarViewModel.TokenSaverProjectGovernance(
                projectID: "project",
                projectName: "Rollover",
                lanes: [TokenSaverLaneStateRecord(
                    projectID: "project", lane: "rollover_capsule", state: "promoted",
                    reason: "scorecard_passed", evidenceLevel: "provider_usage",
                    ownerRole: "Product Owner", permissionBoundary: "project",
                    retentionDays: 30, optedOut: false, killSwitchActive: false
                )],
                rolloverAdmission: .init(allowed: false, reason: reason)
            )

            XCTAssertFalse(governance.rolloverAvailable, "\(reason) must block rollover")
            XCTAssertEqual(governance.rolloverReason, reason,
                           "UI must expose the centralized admission reason without recomputing it")
        }
    }

    func test_projectGovernanceUsesRuntimeGlobalOffAdmission() throws {
        let (context, _, vm) = try makeVM()
        SettingsStore(db: context.db).update { $0.tokenSaverEnabled = false }
        let workspaceID = WorkspaceID()
        let project = ProjectRepository.Project(
            id: ProjectID(), name: "Global off", path: "/tmp/global-off", favorite: false,
            createdAt: Date(), updatedAt: Date()
        )
        try context.projectRepo.upsert(project)
        try context.threadRepo.upsert(.init(
            projectId: project.id, workspaceId: workspaceID,
            title: "global off", provider: .grok, model: "m"
        ))
        try context.tokenSaverLaneStateRepo.upsert(.init(
            projectID: project.id.value.uuidString,
            lane: "rollover_capsule",
            state: "promoted",
            reason: "scorecard_passed",
            evidenceLevel: "provider_usage",
            ownerRole: "Product Owner",
            permissionBoundary: "project",
            retentionDays: 30,
            optedOut: false,
            killSwitchActive: false
        ))

        vm.selectedWorkspaceID = workspaceID
        vm.reloadTokenSaverGovernance()

        let governance = try XCTUnwrap(vm.tokenSaverProjectGovernance.first)
        XCTAssertFalse(governance.rolloverAvailable)
        XCTAssertEqual(governance.rolloverReason, "globally_disabled",
                       "Sidebar must use the centralized runtime admission even when the lane row looks live")
    }

    func test_governanceMutationsRejectProjectOutsideSelectedWorkspace() throws {
        var errors: [(String, String)] = []
        let (context, _, vm) = try makeVM(operationErrorPresenter: { message, detail in
            errors.append((message, detail))
        })
        let selectedWorkspace = WorkspaceID()
        let otherWorkspace = WorkspaceID()
        let selectedProject = ProjectRepository.Project(
            id: ProjectID(), name: "Selected", path: "/tmp/selected", favorite: false,
            createdAt: Date(), updatedAt: Date()
        )
        let otherProject = ProjectRepository.Project(
            id: ProjectID(), name: "Other", path: "/tmp/other", favorite: false,
            createdAt: Date(), updatedAt: Date()
        )
        try context.projectRepo.upsert(selectedProject)
        try context.projectRepo.upsert(otherProject)
        try context.threadRepo.upsert(.init(
            projectId: selectedProject.id, workspaceId: selectedWorkspace,
            title: "selected", provider: .codex, model: "m"
        ))
        try context.threadRepo.upsert(.init(
            projectId: otherProject.id, workspaceId: otherWorkspace,
            title: "other", provider: .claude, model: "m"
        ))
        let otherProjectID = otherProject.id.value.uuidString
        try context.tokenSaverSessionLearnRepo.save(
            text: "must survive rejected delete",
            scope: .init(
                workspaceID: otherWorkspace.value.uuidString,
                projectID: otherProjectID,
                threadID: "other-thread",
                provider: "claude"
            ),
            attemptID: "attempt"
        )

        vm.selectedWorkspaceID = selectedWorkspace
        vm.reloadTokenSaverGovernance()
        XCTAssertFalse(vm.tokenSaverProjectGovernance.contains { $0.projectID == otherProjectID })

        vm.setTokenSaverProjectRetention(projectID: otherProjectID, days: 30)
        vm.setTokenSaverProjectOptOut(projectID: otherProjectID, optedOut: true)
        vm.forceTokenSaverVerbatim(projectID: otherProjectID)
        vm.deleteTokenSaverProjectData(projectID: otherProjectID)
        vm.createTokenSaverRollover(projectID: otherProjectID)

        XCTAssertEqual(errors.count, 5)
        XCTAssertTrue(errors.allSatisfy { $0.1.contains("currently selected workspace") })
        XCTAssertTrue(try context.tokenSaverLaneStateRepo.list(projectID: otherProjectID).isEmpty,
                      "rejected cross-workspace mutations must not create governance rows")
        XCTAssertEqual(
            try context.tokenSaverSessionLearnRepo.topK(
                scope: .init(
                    workspaceID: otherWorkspace.value.uuidString,
                    projectID: otherProjectID,
                    threadID: "other-thread",
                    provider: "claude"
                ),
                byteBudget: 1_024,
                limit: 5
            ).map(\.text),
            ["must survive rejected delete"],
            "cross-workspace delete must not erase project data"
        )

        // A selection change must invalidate the previously loaded governance set
        // before a delayed UI reload can expose controls for the new workspace.
        errors.removeAll()
        let selectedProjectID = selectedProject.id.value.uuidString
        vm.selectedWorkspaceID = otherWorkspace
        vm.setTokenSaverProjectRetention(projectID: selectedProjectID, days: 7)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].1.contains("currently selected workspace"))
    }

    func test_projectGovernanceControlsPersistRetentionOptOutAndVerbatim() throws {
        let (context, _, vm) = try makeVM()
        let workspaceID = WorkspaceID()
        let project = ProjectRepository.Project(
            id: ProjectID(), name: "Controlled", path: "/tmp/controlled", favorite: false,
            createdAt: Date(), updatedAt: Date()
        )
        try context.projectRepo.upsert(project)
        try context.threadRepo.upsert(.init(
            projectId: project.id, workspaceId: workspaceID,
            title: "controlled", provider: .grok, model: "m"
        ))
        vm.selectedWorkspaceID = workspaceID
        vm.reloadTokenSaverGovernance()
        let projectID = project.id.value.uuidString

        vm.setTokenSaverProjectRetention(projectID: projectID, days: 30)
        XCTAssertTrue(vm.tokenSaverProjectGovernance[0].lanes.allSatisfy { $0.retentionDays == 30 })

        vm.setTokenSaverProjectOptOut(projectID: projectID, optedOut: true)
        XCTAssertTrue(vm.tokenSaverProjectGovernance[0].optedOut)
        XCTAssertTrue(vm.tokenSaverProjectGovernance[0].lanes.allSatisfy {
            $0.state == "off" && $0.killSwitchActive
        })

        vm.setTokenSaverProjectOptOut(projectID: projectID, optedOut: false)
        vm.forceTokenSaverVerbatim(projectID: projectID)
        XCTAssertTrue(vm.tokenSaverProjectGovernance[0].lanes.allSatisfy {
            $0.state == "off" && $0.reason == "verbatim_forced" && $0.killSwitchActive
        }, "verbatim retry must stop writers before provider delivery resumes")
    }

    func test_retentionCleanupFailureRollsBackPolicyAndLeavesUIUnchanged() throws {
        var presentedError: (String, String)?
        let (context, _, vm) = try makeVM(operationErrorPresenter: { message, detail in
            presentedError = (message, detail)
        })
        let workspaceID = WorkspaceID()
        let project = ProjectRepository.Project(
            id: ProjectID(), name: "Atomic retention", path: "/tmp/atomic-retention", favorite: false,
            createdAt: Date(), updatedAt: Date()
        )
        try context.projectRepo.upsert(project)
        try context.threadRepo.upsert(.init(
            projectId: project.id, workspaceId: workspaceID,
            title: "atomic", provider: .codex, model: "m"
        ))
        vm.selectedWorkspaceID = workspaceID
        vm.reloadTokenSaverGovernance()
        let projectID = project.id.value.uuidString
        let beforeRows = try context.tokenSaverLaneStateRepo.list(projectID: projectID)
        let beforeUI = try XCTUnwrap(vm.tokenSaverProjectGovernance.first)
        context.tokenSaverProjectDataRepo.beforeAtomicRetentionCleanupForTesting = {
            throw NSError(
                domain: "TokenSaverUXGatingTests",
                code: 91,
                userInfo: [NSLocalizedDescriptionKey: "injected cleanup failure"]
            )
        }
        defer { context.tokenSaverProjectDataRepo.beforeAtomicRetentionCleanupForTesting = nil }

        vm.setTokenSaverProjectRetention(projectID: projectID, days: 30)

        XCTAssertEqual(try context.tokenSaverLaneStateRepo.list(projectID: projectID), beforeRows,
                       "retention policy must roll back when lifecycle cleanup fails")
        XCTAssertEqual(vm.tokenSaverProjectGovernance.first, beforeUI,
                       "the UI must not claim a retention change that did not commit")
        XCTAssertEqual(presentedError?.0, "Could not update Token Saver retention")
        XCTAssertEqual(presentedError?.1, "injected cleanup failure")
        XCTAssertEqual(vm.tokenSaverGovernanceNotice, "Retention unchanged: injected cleanup failure")
    }

    // MARK: - :185 Resume button / resumeTokenSaverModelDownload

    func test_resumeTokenSaverModelDownload_setsShowsModalTrue() throws {
        // WHY: cancelTokenSaverModelDownload dismisses the sheet (showsTokenSaverModelDownload=false).
        // resumeTokenSaverModelDownload must re-open it so the modal reappears.
        var beginCalled = 0
        let handler: SidebarViewModel.TokenSaverModelDownloadHandler = { _ in
            beginCalled += 1
            // Suspend until cancelled so we can assert state while it runs.
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw CancellationError()
        }
        let (_, _, vm) = try makeVM(downloadHandler: handler)
        vm.cancelTokenSaverModelDownload()
        XCTAssertFalse(vm.showsTokenSaverModelDownload,
                       "cancel must dismiss the modal before resume is called")
        vm.resumeTokenSaverModelDownload()
        XCTAssertTrue(vm.showsTokenSaverModelDownload,
                      "resumeTokenSaverModelDownload must re-open the download modal")
    }

    func test_resumeTokenSaverModelDownload_invokesBeginDownload() throws {
        // WHY: resume must actually restart the download, not just show the modal.
        // Verifying the handler is invoked proves beginTokenSaverModelDownload was called.
        var beginCalled = 0
        let handler: SidebarViewModel.TokenSaverModelDownloadHandler = { _ in
            beginCalled += 1
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw CancellationError()
        }
        let (_, _, vm) = try makeVM(downloadHandler: handler)
        // Pause the download first.
        vm.cancelTokenSaverModelDownload()
        // Resume must trigger a new download task.
        vm.resumeTokenSaverModelDownload()
        // Give the task a tick to start.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertGreaterThan(beginCalled, 0,
                             "resumeTokenSaverModelDownload must invoke the download handler")
    }

    func test_downloadModal_isPaused_afterCancel() throws {
        // WHY: the paused state is what controls Resume button visibility.
        // Confirm cancel sets phase to .paused (not .idle or .failed).
        let stallHandler: SidebarViewModel.TokenSaverModelDownloadHandler = { _ in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw CancellationError()
        }
        let (_, _, vm) = try makeVM(
            downloadHandler: stallHandler,
            downloadConfirmProvider: { _, _ in true }   // skip NSAlert in tests
        )
        vm.setTokenSaverEnabled(true)   // triggers beginTokenSaverModelDownload
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        vm.cancelTokenSaverModelDownload()
        XCTAssertEqual(vm.tokenSaverModelDownloadState.phase, .paused,
                       "cancel must leave phase == .paused so the Resume button appears")
    }

    // MARK: - :190 Degraded headline when sidecar is blocked

    func test_tokenSaverCardHeadline_blocked_returnsDegradedCopy() {
        // WHY: when sidecar is blocked the user gets no signal from the savings
        // headline that compression has stopped. The degraded variant must appear.
        let headline = SidebarRootView.tokenSaverCardHeadline(
            subscribed: true,
            enabled: true,
            sidecarStatus: .blocked("GPU unavailable"),
            savedTokens: 50_000,
            usedTokens: 200_000
        )
        XCTAssertTrue(
            headline.lowercased().contains("degraded"),
            "Blocked sidecar must produce a degraded headline; got: '\(headline)'"
        )
        XCTAssertFalse(
            headline.lowercased().contains("saved"),
            "Blocked sidecar must not report saved tokens as if healthy; got: '\(headline)'"
        )
    }

    func test_tokenSaverCardHeadline_notStarted_returnsMeasuredReductionCopy() {
        // WHY: healthy (not-yet-started) state must still show Estimated save.
        // If this regresses, the degraded-branch logic has overreached into
        // non-blocked states.
        let headline = SidebarRootView.tokenSaverCardHeadline(
            subscribed: true,
            enabled: true,
            sidecarStatus: .notStarted,
            savedTokens: 50_000,
            usedTokens: 200_000
        )
        XCTAssertTrue(
            headline.lowercased().contains("estimated save"),
            "Non-blocked sidecar must keep original Estimated save design; got: '\(headline)'"
        )
        XCTAssertFalse(
            headline.lowercased().contains("vs bare"),
            "Design restore must not put bare-agent technique copy in the headline"
        )
    }

    func test_tokenSaverBillingEvidenceDisclaimerIsExplicit() {
        // WHY: popover must list every savings leg in plain language and still
        // refuse to claim provider list-price dollars.
        let disclosure = SidebarRootView.tokenSaverBillingEvidenceDisclaimer.lowercased()
        XCTAssertTrue(disclosure.contains("tool output") || disclosure.contains("distill"),
                      "Must mention measured tool-output path: \(disclosure)")
        XCTAssertTrue(disclosure.contains("dialect") || disclosure.contains("shorter"),
                      "Must mention dialect / shorter answers: \(disclosure)")
        XCTAssertTrue(disclosure.contains("graphify"),
                      "Must mention Graphify: \(disclosure)")
        XCTAssertTrue(disclosure.contains("multi-turn") || disclosure.contains("re-reading"),
                      "Must mention multi-turn cache impact: \(disclosure)")
        XCTAssertTrue(disclosure.contains("auto"),
                      "Must mention Auto routing: \(disclosure)")
        XCTAssertTrue(disclosure.contains("parent thread") || disclosure.contains("nested"),
                      "Must mention nested → parent attribution: \(disclosure)")
        XCTAssertTrue(disclosure.contains("rg") || disclosure.contains("exact-output") || disclosure.contains("exact"),
                      "Must say exact-output tools are skipped: \(disclosure)")
        XCTAssertTrue(disclosure.contains("not") && (disclosure.contains("bill") || disclosure.contains("pricing")),
                      "Must refuse provider bill claims: \(disclosure)")
    }

    func test_tokenSaverCardHeadline_blockedButDisabled_returnsEnableCopy() {
        // WHY: blocked only matters when enabled. With zero history, disabled
        // still shows the enable CTA; history (savedTokens > 0) is not gated.
        let headline = SidebarRootView.tokenSaverCardHeadline(
            subscribed: true,
            enabled: false,
            sidecarStatus: .blocked("GPU unavailable"),
            savedTokens: 0,
            usedTokens: 0
        )
        XCTAssertEqual(headline, "Enable Token Saver",
                       "Disabled Token Saver with no history must show the enable action even when sidecar is blocked")
    }

    func test_tokenSaverCardHeadline_disabledWithHistory_keepsEstimatedSave() {
        // WHY: lapsed/disabled subscribers keep historical measured numbers.
        let headline = SidebarRootView.tokenSaverCardHeadline(
            subscribed: true,
            enabled: false,
            sidecarStatus: .blocked("GPU unavailable"),
            savedTokens: 50_000,
            usedTokens: 200_000
        )
        XCTAssertTrue(
            headline.lowercased().contains("estimated save"),
            "Disabled with history must still show realized figure; got: '\(headline)'"
        )
        XCTAssertNotEqual(headline, "Enable Token Saver")
    }

    func test_tokenSaverCardHeadline_unsubscribed_doesNotUseUsedTimesPoint58() {
        // WHY: retire the 0.42/0.58 teaser; unsubscribed uses the same primary figure.
        let headline = SidebarRootView.tokenSaverCardHeadline(
            subscribed: false,
            enabled: false,
            sidecarStatus: .notStarted,
            savedTokens: 10,
            usedTokens: 78_600_000
        )
        XCTAssertTrue(headline.lowercased().contains("estimated potential"))
        XCTAssertTrue(headline.contains("10"),
                      "Must show primary figure 10, not ~45.6M: \(headline)")
    }

    func test_ringsAccessibilityLabel_qualifiesReductionAsMeasured() {
        // WHY: VoiceOver must not present a local diagnostic estimate as billed savings.
        let label = SidebarRootView.ringsAccessibilityLabel(
            scope: "week",
            savedTokens: 120_000,
            savedProgress: 0.6,
            savedGoalTokens: 200_000,
            claudeUsedProgress: 0.4,
            codexUsedProgress: 0.2,
            grokUsedProgress: 0.1
        )

        XCTAssertTrue(label.lowercased().contains("measured save") || label.lowercased().contains("est."))
        XCTAssertTrue(label.lowercased().contains("goal") || label.contains("%"))
        XCTAssertFalse(label.lowercased().contains(": saved"))
    }

    func test_shouldConfirmTokenSaverDisable_alwaysTrue() {
        // WHY: every disable must go through the confirm path. If this seam ever
        // returns false, the confirm gate in setTokenSaverEnabled is silently bypassed.
        XCTAssertTrue(SidebarViewModel.shouldConfirmTokenSaverDisable(),
                      "shouldConfirmTokenSaverDisable must always return true")
    }

    // MARK: - :191 Disable-confirm gate

    func test_setTokenSaverEnabled_false_doesNotDisableWhenConfirmDenied() throws {
        // WHY: if the user taps Cancel in the confirm alert, Token Saver must
        // remain enabled. Bypassing the guard means the user loses their setting
        // without consent.
        let (_, _, vm) = try makeVM(
            validationProvider: { .installed },
            disableConfirmProvider: { false }   // user taps Cancel
        )
        vm.setTokenSaverEnabled(true)           // enable first (model is installed)
        XCTAssertTrue(vm.tokenSaverEnabled, "pre-condition: Token Saver must be on")

        vm.setTokenSaverEnabled(false)
        XCTAssertTrue(vm.tokenSaverEnabled,
                      "setTokenSaverEnabled(false) must not disable when confirm returns false")
    }

    func test_setTokenSaverEnabled_false_disablesWhenConfirmAccepted() throws {
        // WHY: if the user confirms, Token Saver must actually stop.
        // This is the "happy path" of the confirm gate.
        let (_, _, vm) = try makeVM(
            validationProvider: { .installed },
            disableConfirmProvider: { true }    // user taps Disable
        )
        vm.setTokenSaverEnabled(true)
        XCTAssertTrue(vm.tokenSaverEnabled, "pre-condition: Token Saver must be on")

        vm.setTokenSaverEnabled(false)
        XCTAssertFalse(vm.tokenSaverEnabled,
                       "setTokenSaverEnabled(false) must disable when confirm returns true")
    }

    func test_setTokenSaverEnabled_true_doesNotRequireDisableConfirm() throws {
        // WHY: the confirm gate must only fire on disable, not enable.
        // If it fired on enable, enabling would be broken.
        var confirmCallCount = 0
        let (_, _, vm) = try makeVM(
            validationProvider: { .installed },
            disableConfirmProvider: {
                confirmCallCount += 1
                return true
            }
        )
        vm.setTokenSaverEnabled(true)
        XCTAssertEqual(confirmCallCount, 0,
                       "disableConfirmProvider must not be called when enabling Token Saver")
    }
}
