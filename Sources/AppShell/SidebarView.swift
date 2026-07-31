import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CoreModel
import Persistence
import AgentRuntime
import Surfaces
import DesignSystemKit

public extension Notification.Name {
    static let rc2TokenSaverUsageChanged = Notification.Name("rc2TokenSaverUsageChanged")
    /// Posted by AppDelegate's "Toggle Token Saver" menu item (Cmd+Shift+S).
    /// SidebarViewModel observes this and calls setTokenSaverEnabled(!tokenSaverEnabled).
    static let rc2TokenSaverToggle = Notification.Name("rc2TokenSaverToggle")
}

@MainActor
public final class SidebarViewModel: ObservableObject {
    public struct TokenSaverLocalUsageUpdate: Equatable {
        public let providerTokenDeltas: [AgentProvider: Int]
        public let updatedAt: Date

        public init(
            providerTokenDeltas: [AgentProvider: Int],
            updatedAt: Date
        ) {
            self.providerTokenDeltas = providerTokenDeltas.filter { $0.value > 0 }
            self.updatedAt = updatedAt
        }

        public var totalTokenDelta: Int {
            providerTokenDeltas.values.reduce(0, +)
        }
    }

    public struct TokenSaverRolloverAdmission: Equatable {
        public let allowed: Bool
        public let reason: String

        public init(allowed: Bool, reason: String) {
            self.allowed = allowed
            self.reason = reason
        }
    }

    public struct TokenSaverProjectGovernance: Equatable, Identifiable {
        public let projectID: String
        public let projectName: String
        public let lanes: [TokenSaverLaneStateRecord]
        public let lifecycleDegradedReason: String?
        public let rolloverAdmission: TokenSaverRolloverAdmission

        public init(
            projectID: String,
            projectName: String,
            lanes: [TokenSaverLaneStateRecord],
            lifecycleDegradedReason: String? = nil,
            rolloverAdmission: TokenSaverRolloverAdmission = .init(
                allowed: false,
                reason: "authoritative_admission_required"
            )
        ) {
            self.projectID = projectID
            self.projectName = projectName
            self.lanes = lanes
            self.lifecycleDegradedReason = lifecycleDegradedReason
            self.rolloverAdmission = rolloverAdmission
        }

        public var id: String { projectID }
        public var optedOut: Bool { lanes.contains(where: \.optedOut) }
        public var retentionDays: Int { lanes.first?.retentionDays ?? 0 }
        public var promotedLaneCount: Int { lanes.filter { $0.state == "promoted" }.count }
        public var shadowLaneCount: Int { lanes.filter { $0.state == "shadow_only" }.count }
        /// Compatibility name retained for callers that mean live provider behavior.
        /// Shadow lanes never count as active because they cannot change provider input.
        public var activeLaneCount: Int { promotedLaneCount }
        public var laneSummaryLabel: String {
            "\(promotedLaneCount) promoted · \(shadowLaneCount) shadow"
        }
        public var stateLabel: String {
            if lifecycleDegradedReason != nil { return "Degraded (verbatim)" }
            if optedOut { return "Opted out" }
            if lanes.contains(where: { $0.reason.contains("degraded") }) { return "Degraded" }
            if promotedLaneCount > 0 { return "Active" }
            if shadowLaneCount > 0 { return "Shadow only" }
            return "Guarded off"
        }
        public var rolloverLane: TokenSaverLaneStateRecord? {
            lanes.first { $0.lane == "rollover_capsule" }
        }
        public var rolloverAvailable: Bool {
            rolloverAdmission.allowed && (rolloverLane?.retentionDays ?? 0) > 0
        }
        public var rolloverReason: String {
            guard rolloverAdmission.allowed else { return rolloverAdmission.reason }
            guard (rolloverLane?.retentionDays ?? 0) > 0 else { return "retention_not_positive" }
            return "Ready"
        }
    }

    /// Pure view-state for the Insomnia keep-awake status pill. Carries no UI
    /// dependency so the view can render + wire one-click disable from it.
    public struct InsomniaStatusPillState: Equatable {
        public let isVisible: Bool
        public let label: String
        public let disablesInsomniaOnTap: Bool
    }

    /// Derives the status-pill state from whether keep-awake assertions are held.
    /// Visible (with a disable-on-tap intent + human-readable label) only when on.
    nonisolated public static func insomniaStatusPill(enabled: Bool) -> InsomniaStatusPillState {
        InsomniaStatusPillState(
            isVisible: enabled,
            label: enabled ? "Keeping Mac awake" : "",
            disablesInsomniaOnTap: enabled
        )
    }

    public enum InsomniaBatteryDecision {
        case disable
        case keepEnabled
    }

    public typealias InsomniaBatteryPrompt = @MainActor () -> InsomniaBatteryDecision
    public typealias TokenSaverModelValidationProvider = @MainActor () -> TokenSaverModelValidation
    public typealias TokenSaverModelDownloadHandler = @MainActor (
        _ progress: @escaping @MainActor (TokenSaverModelDownloadState) -> Void
    ) async throws -> TokenSaverModelManifest

    // MARK: - Download confirm gate

    public enum DownloadConfirmDecision: Equatable {
        /// Disk has too little free space to safely store the model.
        case insufficientDisk
        /// Enough space: caller should show the confirm dialog and may proceed.
        case confirm
    }

    /// Estimated full Token Saver bundle size used for disk-space checks and
    /// the confirm dialog copy. Covers the selected approved MLX LLM plus the
    /// required BERT/encoder models downloaded during activation.
    nonisolated public static let approvedModelEstimatedBytes: Int64 = 3_800_000_000

    /// Safety margin added to the estimated model size before comparing with
    /// free disk space. Covers the partial download file and manifest write.
    nonisolated public static let downloadDiskMarginBytes: Int64 = 200_000_000

    /// Pure seam: decides whether a multi-GB download may proceed based solely
    /// on arithmetic over byte counts.  No I/O, no UI.
    ///
    /// Returns `.insufficientDisk` when `freeDiskBytes` is less than
    /// `modelBytes + downloadDiskMarginBytes`. Returns `.confirm` otherwise.
    ///
    /// WHY this exists as a separate function: an accidental click on the
    /// Token Saver card must not silently start a multi-GB download, and a
    /// nearly-full disk must warn the user before any bytes are fetched.
    nonisolated public static func downloadConfirmDecision(
        modelBytes: Int64,
        freeDiskBytes: Int64
    ) -> DownloadConfirmDecision {
        freeDiskBytes < modelBytes + downloadDiskMarginBytes ? .insufficientDisk : .confirm
    }

    /// Human-readable size string for `approvedModelEstimatedBytes`, e.g. "3.8 GB".
    nonisolated public static func humanModelSizeString() -> String {
        ByteCountFormatter.string(fromByteCount: approvedModelEstimatedBytes, countStyle: .file)
    }

    /// Seam injected in tests so the confirm prompt can be replaced without
    /// showing a real NSAlert. Production default shows a blocking NSAlert.
    public typealias TokenSaverDownloadConfirmProvider = @MainActor (
        _ sizeString: String,
        _ hasEnoughDisk: Bool
    ) -> Bool

    /// Seam injected in tests so the disable-confirm prompt can be replaced
    /// without showing a real NSAlert. Production default shows a blocking
    /// NSAlert. Returning true means "proceed with disable".
    public typealias TokenSaverDisableConfirmProvider = @MainActor () -> Bool
    public typealias OperationErrorPresenter = @MainActor (_ message: String, _ detail: String) -> Void

    // MARK: - WorkspacePrompting seam (:95)

    /// Decision returned by a text-input prompt (rename, description).
    /// `.committed(text)` means the user clicked Save; `.cancelled` means Cancel or dismiss.
    public enum PromptDecision: Equatable {
        case committed(String)
        case cancelled
    }

    /// Decision returned by a confirm-remove alert.
    public enum RemoveDecision: Equatable {
        case confirmed
        case cancelled
    }

    /// Injectable seam that drives the modal DECISION for rename/remove paths.
    /// The real implementation shows NSAlert/NSTextField; the test implementation
    /// returns a hard-coded result without spinning AppKit.
    ///
    /// Mirrors the `InsomniaBatteryPrompt` injection pattern (SidebarView.swift:43, :162).
    public protocol WorkspacePrompting: AnyObject {
        /// Called by `renameWorkspace`/`editDescription`. Must call `completion`
        /// exactly once. The string in `.committed` must already be trimmed.
        @MainActor func promptForText(
            title: String,
            message: String,
            initial: String,
            multiline: Bool,
            completion: @escaping @MainActor (PromptDecision) -> Void
        )

        /// Called by `removeWorkspace` for a single-workspace confirm.
        @MainActor func confirmRemoveOne(
            name: String,
            completion: @escaping @MainActor (RemoveDecision) -> Void
        )

        /// Called by `removeSelectedWorkspaces` for a multi-workspace confirm.
        @MainActor func confirmRemoveMany(
            count: Int,
            names: [String],
            completion: @escaping @MainActor (RemoveDecision) -> Void
        )
    }

    /// Default production prompter: shows the same NSAlert/beginSheetModal/runModal
    /// flow that the inline code used before the seam was introduced.
    /// No behaviour change -- wraps the existing modal calls verbatim.
    public final class AppKitWorkspacePrompter: WorkspacePrompting {
        private weak var viewModel: SidebarViewModel?

        public init(viewModel: SidebarViewModel) {
            self.viewModel = viewModel
        }

        @MainActor public func promptForText(
            title: String,
            message: String,
            initial: String,
            multiline: Bool,
            completion: @escaping @MainActor (PromptDecision) -> Void
        ) {
            viewModel?.presentPromptSheet(
                title: title,
                message: message,
                initial: initial,
                multiline: multiline
            ) { text in
                if let text {
                    completion(.committed(text))
                } else {
                    completion(.cancelled)
                }
            }
        }

        @MainActor public func confirmRemoveOne(
            name: String,
            completion: @escaping @MainActor (RemoveDecision) -> Void
        ) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Remove \"\(name)\"?"
            alert.informativeText = "This removes the workspace and its tabs from RemoteCode. Files on disk are not touched."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            let handler: (NSApplication.ModalResponse) -> Void = { response in
                completion(SidebarRootView.confirmRemoveDecision(response: response) ? .confirmed : .cancelled)
            }
            if let window = NSApp.keyWindow {
                alert.beginSheetModal(for: window, completionHandler: handler)
            } else {
                handler(alert.runModal())
            }
        }

        @MainActor public func confirmRemoveMany(
            count: Int,
            names: [String],
            completion: @escaping @MainActor (RemoveDecision) -> Void
        ) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Remove \(count) workspaces?"
            alert.informativeText = "This removes the selected workspaces and their tabs from RemoteCode. Files on disk are not touched.\n\n" + names.joined(separator: "\n")
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            let handler: (NSApplication.ModalResponse) -> Void = { response in
                completion(SidebarRootView.confirmRemoveDecision(response: response) ? .confirmed : .cancelled)
            }
            if let window = NSApp.keyWindow {
                alert.beginSheetModal(for: window, completionHandler: handler)
            } else {
                handler(alert.runModal())
            }
        }
    }

    /// Injectable workspace prompter. Defaults to `AppKitWorkspacePrompter` (set
    /// after `self` is available in `init`). Tests replace this with a fake that
    /// returns a pre-determined decision without spinning AppKit modals.
    public var workspacePrompter: (any WorkspacePrompting)?
    private let operationErrorPresenter: OperationErrorPresenter

    public weak var context: AppContext?
    public weak var router: AppCommandRouter?

    @Published public var workspaces: [Workspace] = [] {
        didSet { busyStateCache.removeAll(keepingCapacity: true) }
    }
    /// PERF-MAC_SHELL_WINDOW-003: memoize per-workspace busy state for the
    /// lifetime of one `workspaces` snapshot so repeated SwiftUI `body`
    /// evaluations don't re-walk panes/surfaces (and the registry) on
    /// every render. Invalidated whenever `workspaces` is reassigned via
    /// `reload`, which is driven by the same mutations that change busy.
    private var busyStateCache: [WorkspaceID: Bool] = [:]
    /// UX-SIDEBAR-COMPLETED-DOT: workspaces whose in-progress action just finished
    /// (busy → idle) and that the user has not opened since. Drives the small
    /// "action completed" dot shown in the spinner's slot. Cleared when the
    /// workspace is selected.
    @Published public private(set) var completedWorkspaces: Set<WorkspaceID> = []
    /// Busy set captured on the previous `reload`, used to detect the busy → idle
    /// transition that marks an action as completed.
    private var previousBusyWorkspaces: Set<WorkspaceID> = []
    @Published public var selectedWorkspaceID: WorkspaceID?
    @Published public var selectedWorkspaceIDs: Set<WorkspaceID> = []
    /// True while the main content pane shows Schedule Tasks (not a workspace).
    @Published public var isScheduledTasksSelected: Bool = false
    /// Fired when the user activates a workspace row so the shell can leave
    /// the Schedule Tasks main-content destination.
    var onWorkspaceContentActivated: (() -> Void)?
    /// IMP-MAC_SHELL_WINDOW-009: free-text filter applied to the rendered
    /// workspace list. Empty string shows everything; matching is over
    /// name, description, and cwd. The backing `workspaces` array stays
    /// canonical so drag-reorder indices remain correct.
    @Published public var filterText: String = ""
    @Published public var privateAccountUser: PrivateAccountUser?
    @Published public var updateAvailability: AppUpdateAvailability = .unknown
    @Published public private(set) var insomniaEnabled: Bool = false
    @Published public private(set) var insomniaAllowDisplaySleep: Bool = true
    @Published public private(set) var insomniaAllowSystemSleepWhenDisplayClosed: Bool = false
    @Published public private(set) var insomniaAllowScreenSaverAfter45MinutesOfInactivity: Bool = true
    @Published public private(set) var tokenSaverEnabled: Bool = false
    /// Graphify runtime gate (Token Saver ∧ preference) for bare-user counterfactual.
    @Published public private(set) var graphifyRuntimeActive: Bool = false
    @Published public private(set) var tokenSaverUsageSnapshot: TokenSaverUsageSnapshot = .empty()
    /// Saved-token totals from the local DB plus retained report/chart rows.
    @Published public private(set) var tokenSaverSavingsSummary: TokenSaverSavingsSummary = .empty
    /// Persisted daily credible totals (Week = Σ). Empty until first recompute.
    @Published public private(set) var tokenSaverDailyEconomyToday: TokenSaverDailyEconomyRecord?
    @Published public private(set) var tokenSaverDailyEconomyWeekTotal: Int = 0
    /// Multi-turn cache amortization by provider for the current calendar day
    /// (same stack as Agent App thread footers). Keyed by provider rawValue.
    @Published public private(set) var tokenSaverProviderCacheAmortToday: [String: Int] = [:]
    @Published public private(set) var tokenSaverProjectGovernance: [TokenSaverProjectGovernance] = []
    @Published public private(set) var tokenSaverGovernanceNotice: String?
    @Published public var showsTokenSaverModelDownload = false
    @Published public private(set) var tokenSaverModelDownloadState: TokenSaverModelDownloadState = .idle
    /// True while a background account-usage refresh (CLI probe) is in flight.
    /// Drives the spinner in the details popover (:188).
    @Published public private(set) var tokenSaverAccountUsageIsRefreshing: Bool = false
    /// Timestamp of the last completed account-usage refresh, or nil when never refreshed.
    /// Drives the "last updated" line in the details popover (:188).
    @Published public private(set) var tokenSaverAccountUsageLastUpdated: Date? = nil
    /// Latest positive change observed in the local provider-usage ledger.
    /// This is deliberately separate from account refresh time: a provider run can
    /// update local token usage without changing a rounded account percentage.
    @Published public private(set) var tokenSaverLocalUsageUpdate: TokenSaverLocalUsageUpdate?
    /// Current status of the Token Saver sidecar. Updated whenever the controller
    /// posts `.rc2TokenSaverDistillStatusChanged`. Drives the status row in the
    /// details popover so a blocked/failed sidecar is never invisible (Rule 6).
    @Published public private(set) var sidecarStatus: TokenSaverDistillServiceStatus = .notStarted
    public var draggingWorkspaceID: WorkspaceID?
    /// UX-MAC_SHELL_WINDOW-012: the row the drag is currently hovering,
    /// so the list can draw an insertion line instead of reordering live.
    @Published public var dropTargetWorkspaceID: WorkspaceID?
    /// :18 -- Edge auto-scroll direction during a drag. -1 = scroll up (near top),
    /// 0 = no scroll, +1 = scroll down (near bottom). Set by WorkspaceDropDelegate;
    /// observed by SidebarRootView to drive a timer-based NSScrollView scroll.
    @Published public var dragScrollEdge: Int = 0
    private var selectionAnchorID: WorkspaceID?
    /// Session-local undo stack for removed workspaces. Newest entry at end.
    /// Not persisted; cleared on app quit.
    private(set) var removedWorkspaceStack: [WorkspaceUndoEntry] = []
    /// PERF-MAC_SIDEBAR-001 (test seam): counts how many times
    /// `busyTooltip(for:)` issues a `threadRepo.list(workspaceId:)` DB call.
    /// Production code never reads this; tests assert it stays bounded so
    /// N health events * M workspaces does not produce N*M DB round-trips.
    var threadListCallCount: Int = 0
    private var privateAccountObserver: NSObjectProtocol?
    private var tokenSaverUsageObserver: NSObjectProtocol?
    private var tokenSaverDistributedUsageObserver: NSObjectProtocol?
    /// PERF-MAC-100: in-flight background reload of the heavy Token Saver
    /// usage snapshot + savings summary. A new notification cancels the prior
    /// task so a burst of per-provider `.rc2TokenSaverUsageChanged` events
    /// coalesces into a single off-main read instead of N main-thread reads.
    private var tokenSaverHeavyReloadTask: Task<Void, Never>?
    private var tokenSaverLocalUsageBaseline: [AgentProvider: Int]?
    private var sidecarStatusObserver: NSObjectProtocol?
    private var tokenSaverToggleObserver: NSObjectProtocol?
    private let updateChecker: AppUpdateChecking?
    private let settingsStore: SettingsStore
    private let insomniaPower: InsomniaPowerManaging
    private let powerMonitor: ExternalPowerMonitoring
    private let insomniaBatteryPrompt: InsomniaBatteryPrompt
    private let tokenSaverModelValidationProvider: TokenSaverModelValidationProvider?
    private let tokenSaverModelDownloadHandler: TokenSaverModelDownloadHandler?
    private let tokenSaverDownloadConfirmProvider: TokenSaverDownloadConfirmProvider?
    private let tokenSaverDisableConfirmProvider: TokenSaverDisableConfirmProvider?
    private var lastPowerState: ExternalPowerState
    private var showingInsomniaBatteryPrompt = false
    private var tokenSaverModelDownloadTask: Task<TokenSaverModelManifest, Error>?
    // Aggregate download progress across all files. Reset at the start of each download.
    @Published public private(set) var tokenSaverAggregatedDownloadedBytes: Int64 = 0
    @Published public private(set) var tokenSaverAggregatedTotalBytes: Int64 = 0
    @Published public private(set) var tokenSaverDownloadBytesPerSec: Double = 0
    // Internal tracking for aggregate accumulation. Not published -- only read on @MainActor.
    private var _aggregateCompletedBytes: Int64 = 0
    private var _aggregateCompletedExpected: Int64 = 0
    private var _aggregateLastFileBytes: Int64 = 0
    private var _aggregateSpeedSample: (bytes: Int64, time: Date) = (0, .distantPast)

    public init(
        context: AppContext,
        router: AppCommandRouter,
        updateChecker: AppUpdateChecking? = nil,
        insomniaPower: InsomniaPowerManaging = MacOSInsomniaPowerManager(),
        powerMonitor: ExternalPowerMonitoring = MacOSExternalPowerMonitor(),
        insomniaBatteryPrompt: @escaping InsomniaBatteryPrompt = {
            SidebarViewModel.defaultInsomniaBatteryPrompt()
        },
        tokenSaverModelValidationProvider: TokenSaverModelValidationProvider? = nil,
        tokenSaverModelDownloadHandler: TokenSaverModelDownloadHandler? = nil,
        tokenSaverDownloadConfirmProvider: TokenSaverDownloadConfirmProvider? = nil,
        tokenSaverDisableConfirmProvider: TokenSaverDisableConfirmProvider? = nil,
        operationErrorPresenter: @escaping OperationErrorPresenter = SidebarViewModel.defaultOperationErrorPresenter
    ) {
        self.context = context
        self.router = router
        self.updateChecker = updateChecker
        self.updateAvailability = updateChecker?.availability ?? .unknown
        self.settingsStore = SettingsStore(db: context.db)
        self.insomniaPower = insomniaPower
        self.powerMonitor = powerMonitor
        self.insomniaBatteryPrompt = insomniaBatteryPrompt
        self.tokenSaverModelValidationProvider = tokenSaverModelValidationProvider
        self.tokenSaverModelDownloadHandler = tokenSaverModelDownloadHandler
        self.tokenSaverDownloadConfirmProvider = tokenSaverDownloadConfirmProvider
        self.tokenSaverDisableConfirmProvider = tokenSaverDisableConfirmProvider
        self.operationErrorPresenter = operationErrorPresenter
        self.lastPowerState = powerMonitor.currentPowerState
        self.privateAccountObserver = NotificationCenter.default.addObserver(
            forName: .rc2PrivateAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let viewModel = self else { return }
            Task { @MainActor in viewModel.reloadPrivateAccount() }
        }
        self.tokenSaverUsageObserver = NotificationCenter.default.addObserver(
            forName: .rc2TokenSaverUsageChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let viewModel = self else { return }
            Task { @MainActor in viewModel.reloadTokenSaver(trackLocalUsageChange: true) }
        }
        self.tokenSaverDistributedUsageObserver =
            TokenSaverUsageCrossProcess.observeStoreChanged { [weak self] in
                guard let viewModel = self else { return }
                Task { @MainActor in
                    viewModel.reloadTokenSaver(trackLocalUsageChange: true)
                }
            }
        self.sidecarStatusObserver = NotificationCenter.default.addObserver(
            forName: .rc2TokenSaverDistillStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let viewModel = self,
                  let controller = note.object as? TokenSaverDistillServiceController else { return }
            Task { @MainActor in viewModel.sidecarStatus = controller.status }
        }
        self.tokenSaverToggleObserver = NotificationCenter.default.addObserver(
            forName: .rc2TokenSaverToggle,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let viewModel = self else { return }
            Task { @MainActor in viewModel.setTokenSaverEnabled(!viewModel.tokenSaverEnabled) }
        }
        self.updateChecker?.onAvailabilityChanged = { [weak self] availability in
            self?.updateAvailability = availability
        }
        self.powerMonitor.onPowerStateChanged = { [weak self] state in
            self?.handleExternalPowerStateChanged(state)
        }
        self.powerMonitor.start()
        // :95 -- Wire the default AppKit prompter after self is available.
        // Tests replace workspacePrompter with a fake before calling any prompt path.
        workspacePrompter = AppKitWorkspacePrompter(viewModel: self)
        reload()
        reloadInsomnia()
        reloadTokenSaver()
        sidecarStatus = context.tokenSaverDistillServiceController.status
    }

    deinit {
        if let privateAccountObserver {
            NotificationCenter.default.removeObserver(privateAccountObserver)
        }
        if let tokenSaverUsageObserver {
            NotificationCenter.default.removeObserver(tokenSaverUsageObserver)
        }
        if let tokenSaverDistributedUsageObserver {
            TokenSaverUsageCrossProcess.removeObserver(tokenSaverDistributedUsageObserver)
        }
        if let sidecarStatusObserver {
            NotificationCenter.default.removeObserver(sidecarStatusObserver)
        }
        if let tokenSaverToggleObserver {
            NotificationCenter.default.removeObserver(tokenSaverToggleObserver)
        }
        tokenSaverModelDownloadTask?.cancel()
        powerMonitor.stop()
        insomniaPower.releaseProcessAssertions()
    }

    public func reload() {
        guard let ctx = context else { return }
        let loaded = (try? router?.listWorkspaces()) ?? ctx.state.window.workspaces.compactMap { ctx.state.workspaces[$0] }
        // MRU: present the list ordered by most-recently-used so a workspace stays at
        // the top after activity instead of snapping back to its prior slot. Derived
        // from the durable per-workspace lastActivity timestamp, so it is immune to any
        // transient window-order churn.
        let ordered = LayoutReducer.mostRecentlyUsedOrder(loaded)
        // Refresh the selection first so a workspace that completed AND became
        // selected this tick is correctly treated as "being viewed" (no dot).
        // While Schedule Tasks owns the main content, keep every workspace row
        // deselected so the shell destination is unambiguous.
        if isScheduledTasksSelected {
            selectedWorkspaceID = nil
            selectedWorkspaceIDs.removeAll()
            selectionAnchorID = nil
        } else {
            selectedWorkspaceID = ctx.state.window.selectedWorkspaceID
        }
        updateCompletedWorkspaces(from: ordered)
        if ordered != workspaces {
            workspaces = ordered
        }
        if !isScheduledTasksSelected {
            selectedWorkspaceIDs = selectedWorkspaceIDs.intersection(Set(workspaces.map(\.id)))
        }
        reloadPrivateAccount()
    }

    /// UX-SIDEBAR-COMPLETED-DOT: detect workspaces whose action just finished and
    /// surface the completed dot. Uses the `busy` metadata that `listWorkspaces`
    /// already batch-computes (agent run / terminal job), so no extra DB work.
    private func updateCompletedWorkspaces(from list: [Workspace]) {
        let nowBusy = Set(list.filter { $0.metadata["busy"] == "true" }.map(\.id))
        completedWorkspaces = Self.completedWorkspacesAfterReload(
            previousBusy: previousBusyWorkspaces,
            nowBusy: nowBusy,
            current: completedWorkspaces,
            existing: Set(list.map(\.id)),
            selected: selectedWorkspaceID)
        previousBusyWorkspaces = nowBusy
    }

    /// Pure transition: a workspace that left the busy set since last reload just
    /// completed its action and earns a dot — unless it is the one the user is already
    /// viewing (selected). Currently-busy workspaces show a spinner instead, and
    /// entries for removed workspaces are dropped.
    nonisolated static func completedWorkspacesAfterReload(
        previousBusy: Set<WorkspaceID>,
        nowBusy: Set<WorkspaceID>,
        current: Set<WorkspaceID>,
        existing: Set<WorkspaceID>,
        selected: WorkspaceID?
    ) -> Set<WorkspaceID> {
        var result = current
        for id in previousBusy.subtracting(nowBusy) where id != selected {
            result.insert(id)
        }
        result.subtract(nowBusy)
        // The workspace the user is currently viewing never shows a dot, regardless of
        // how it was selected (click, keyboard, programmatic).
        if let selected { result.remove(selected) }
        result.formIntersection(existing)
        return result
    }

    /// Test seam: mark a workspace's action as completed so the completed-dot /
    /// clear-on-select behavior can be exercised without driving a full run.
    func markCompletedForTesting(_ id: WorkspaceID) {
        completedWorkspaces.insert(id)
    }

    private func reloadPrivateAccount() {
        guard let ctx = context else { return }
        privateAccountUser = PrivateAccountSessionStore(repo: ctx.settingsRepo).load()?.user
    }

    private func reloadInsomnia() {
        let settings = settingsStore.load()
        insomniaEnabled = settings.insomniaEnabled
        insomniaAllowDisplaySleep = settings.insomniaAllowDisplaySleep
        insomniaAllowSystemSleepWhenDisplayClosed = settings.insomniaAllowSystemSleepWhenDisplayClosed
        insomniaAllowScreenSaverAfter45MinutesOfInactivity = settings.insomniaAllowScreenSaverAfter45MinutesOfInactivity
        applyInsomniaPower()
    }

    /// PERF-MAC-100: fire-and-forget reload used by the notification path.
    ///
    /// The cheap `tokenSaverEnabled` flag is read synchronously on the main
    /// actor (UI + InsomniaSidebarTests assert it synchronously). The heavy
    /// work -- a JSON file read (`TokenSaverUsageStore.load()`) and a SQL
    /// aggregate (`tokenSaverSavingsRepo.summary()`) -- runs OFF the main
    /// thread and is coalesced: a fresh notification cancels the prior task,
    /// so a per-provider burst collapses to a single background read.
    private func reloadTokenSaver(trackLocalUsageChange: Bool = false) {
        let settings = settingsStore.load()
        tokenSaverEnabled = settings.tokenSaverEnabled
        graphifyRuntimeActive = settings.isGraphifyRuntimeActive
        guard let context else {
            tokenSaverHeavyReloadTask?.cancel()
            tokenSaverHeavyReloadTask = nil
            tokenSaverUsageSnapshot = .empty()
            tokenSaverSavingsSummary = .empty
            tokenSaverDailyEconomyToday = nil
            tokenSaverDailyEconomyWeekTotal = 0
            tokenSaverProviderCacheAmortToday = [:]
            tokenSaverLocalUsageBaseline = nil
            tokenSaverLocalUsageUpdate = nil
            return
        }
        context.recomputeTokenSaverDailyEconomyToday()
        let appSupport = context.appSupportDirectory
        let savingsRepo = context.tokenSaverSavingsRepo
        let economyRepo = context.tokenSaverDailyEconomyRepo
        tokenSaverHeavyReloadTask?.cancel()
        tokenSaverHeavyReloadTask = Task { [weak self] in
            let result = await Self.loadTokenSaverHeavy(
                appSupportDirectory: appSupport,
                savingsRepo: savingsRepo,
                economyRepo: economyRepo
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.tokenSaverUsageSnapshot = result.snapshot
                self.tokenSaverSavingsSummary = result.summary
                self.tokenSaverDailyEconomyToday = result.economyToday
                self.tokenSaverDailyEconomyWeekTotal = result.economyWeekTotal
                self.tokenSaverProviderCacheAmortToday = result.providerCacheAmortToday
                self.updateTokenSaverLocalUsage(
                    from: result.snapshot,
                    emitPositiveChange: trackLocalUsageChange
                )
            }
        }
    }

    private func updateTokenSaverLocalUsage(
        from snapshot: TokenSaverUsageSnapshot,
        emitPositiveChange: Bool
    ) {
        let current = Dictionary(uniqueKeysWithValues: snapshot.providers.map {
            ($0.provider, $0.actualProviderTokens)
        })
        defer { tokenSaverLocalUsageBaseline = current }
        guard emitPositiveChange, let previous = tokenSaverLocalUsageBaseline else { return }

        var providerDeltas: [AgentProvider: Int] = [:]
        for (provider, tokens) in current {
            let tokenDelta = tokens - (previous[provider] ?? 0)
            if tokenDelta > 0 {
                providerDeltas[provider] = tokenDelta
            }
        }
        guard !providerDeltas.isEmpty else { return }
        tokenSaverLocalUsageUpdate = TokenSaverLocalUsageUpdate(
            providerTokenDeltas: providerDeltas,
            updatedAt: Date()
        )
    }

    public func reloadTokenSaverGovernance() {
        guard let context else {
            tokenSaverProjectGovernance = []
            return
        }
        do {
            let projects = try context.projectRepo.list()
            let threads = try context.threadRepo.list(workspaceId: selectedWorkspaceID)
            let lifecycleDegradedReason = context.tokenSaverLifecycleDegradedReason
            let scopedProjectIDs: Set<String>
            if selectedWorkspaceID == nil {
                scopedProjectIDs = Set(projects.map { $0.id.value.uuidString })
            } else {
                scopedProjectIDs = Set(threads.compactMap { $0.projectId?.value.uuidString })
            }
            tokenSaverProjectGovernance = try projects.compactMap { project in
                let projectID = project.id.value.uuidString
                guard scopedProjectIDs.contains(projectID) else { return nil }
                try context.tokenSaverLaneStateRepo.ensureDefaults(projectID: projectID)
                let parentThread = threads
                    .filter { $0.projectId?.value.uuidString == projectID }
                    .max { $0.updatedAt < $1.updatedAt }
                let rolloverAdmission = parentThread.map {
                    let decision = context.tokenSaverRolloverAdmission(parentThreadID: $0.id)
                    return TokenSaverRolloverAdmission(allowed: decision.allowed, reason: decision.reason)
                } ?? .init(allowed: false, reason: "missing_project_scope")
                return TokenSaverProjectGovernance(
                    projectID: projectID,
                    projectName: project.name,
                    lanes: try context.tokenSaverLaneStateRepo.list(projectID: projectID),
                    lifecycleDegradedReason: lifecycleDegradedReason,
                    rolloverAdmission: rolloverAdmission
                )
            }
            if let lifecycleDegradedReason {
                tokenSaverGovernanceNotice = "Lifecycle retention is degraded; project lanes are forced to verbatim provider delivery. \(lifecycleDegradedReason)"
            }
        } catch {
            tokenSaverProjectGovernance = []
            operationErrorPresenter("Token Saver project controls unavailable", error.localizedDescription)
        }
    }

    public func setTokenSaverProjectOptOut(projectID: String, optedOut: Bool) {
        guard let context else { return }
        guard validateTokenSaverGovernanceProject(
            projectID,
            operation: "Could not update Token Saver opt-out"
        ) else { return }
        do {
            try context.tokenSaverLaneStateRepo.setOptOut(projectID: projectID, optedOut: optedOut)
            tokenSaverGovernanceNotice = optedOut ? "Project now uses verbatim provider delivery." : "Project opt-out removed; lanes remain gated by their scorecards."
            reloadTokenSaverGovernance()
        } catch {
            operationErrorPresenter("Could not update Token Saver opt-out", error.localizedDescription)
        }
    }

    public func setTokenSaverProjectRetention(projectID: String, days: Int) {
        guard let context else { return }
        guard validateTokenSaverGovernanceProject(
            projectID,
            operation: "Could not update Token Saver retention"
        ) else { return }
        do {
            try context.tokenSaverProjectDataRepo.setProjectRetentionDays(projectID: projectID, days: days)
            tokenSaverGovernanceNotice = days == 0 ? "Persistent project retention disabled." : "Project retention set to \(days) days."
            reloadTokenSaverGovernance()
        } catch {
            tokenSaverGovernanceNotice = "Retention unchanged: \(error.localizedDescription)"
            operationErrorPresenter("Could not update Token Saver retention", error.localizedDescription)
        }
    }

    public func forceTokenSaverVerbatim(projectID: String) {
        guard let context else { return }
        guard validateTokenSaverGovernanceProject(
            projectID,
            operation: "Could not force verbatim delivery"
        ) else { return }
        do {
            try context.tokenSaverLaneStateRepo.forceVerbatim(projectID: projectID)
            tokenSaverGovernanceNotice = "All project lanes stopped; provider delivery is verbatim."
            reloadTokenSaverGovernance()
        } catch {
            operationErrorPresenter("Could not force verbatim delivery", error.localizedDescription)
        }
    }

    public func deleteTokenSaverProjectData(projectID: String) {
        guard let context else { return }
        guard validateTokenSaverGovernanceProject(
            projectID,
            operation: "Could not delete Token Saver project data"
        ) else { return }
        do {
            let result = try context.tokenSaverProjectDataRepo.deleteProjectData(projectID: projectID)
            tokenSaverGovernanceNotice = "Deleted \(result.recoveryObjects) recovery objects, \(result.sessionLearnRecords) learned records, and \(result.rolloverCapsules) rollover capsules."
            reloadTokenSaverGovernance()
        } catch {
            operationErrorPresenter("Could not delete Token Saver project data", error.localizedDescription)
        }
    }

    public func createTokenSaverRollover(projectID: String) {
        guard let context else { return }
        guard validateTokenSaverGovernanceProject(
            projectID,
            operation: "Token Saver rollover unavailable"
        ) else { return }
        do {
            let parent = try context.threadRepo.list(workspaceId: selectedWorkspaceID)
                .filter { $0.projectId?.value.uuidString == projectID }
                .sorted { $0.updatedAt > $1.updatedAt }
                .first
            guard let parent else {
                operationErrorPresenter("Token Saver rollover unavailable", "No project thread exists in the selected workspace.")
                return
            }
            let child = try context.createTokenSaverRollover(parentThreadID: parent.id)
            tokenSaverGovernanceNotice = "Created rollover thread: \(child.title). The original thread was preserved."
            reloadTokenSaverGovernance()
        } catch {
            operationErrorPresenter("Token Saver rollover unavailable", error.localizedDescription)
        }
    }

    private func validateTokenSaverGovernanceProject(
        _ projectID: String,
        operation: String
    ) -> Bool {
        func reject(_ detail: String) -> Bool {
            operationErrorPresenter(
                operation,
                detail
            )
            return false
        }
        guard tokenSaverProjectGovernance.contains(where: { $0.projectID == projectID }) else {
            return reject("Project is not scoped to the currently selected workspace. Refresh project controls and try again.")
        }
        guard let context else {
            return reject("Project controls are unavailable. Reopen the workspace and try again.")
        }
        do {
            let projectExists = try context.projectRepo.list().contains {
                $0.id.value.uuidString == projectID
            }
            let remainsWorkspaceScoped: Bool
            if let selectedWorkspaceID {
                remainsWorkspaceScoped = try context.threadRepo.list(workspaceId: selectedWorkspaceID).contains {
                    $0.projectId?.value.uuidString == projectID
                }
            } else {
                remainsWorkspaceScoped = projectExists
            }
            guard projectExists, remainsWorkspaceScoped else {
                return reject("Project is not scoped to the currently selected workspace. Refresh project controls and try again.")
            }
            return true
        } catch {
            return reject("Could not verify the selected workspace project scope: \(error.localizedDescription)")
        }
    }

    /// PERF-MAC-100: deterministic reload for tests and any caller that must
    /// observe a populated snapshot immediately after `await`. Reads the cheap
    /// enabled flag synchronously, then awaits the same off-main heavy load
    /// INLINE (not registered in `tokenSaverHeavyReloadTask`, so a later
    /// notification cannot cancel it) before assigning the published values.
    func reloadTokenSaverAndWait() async {
        let settings = settingsStore.load()
        tokenSaverEnabled = settings.tokenSaverEnabled
        graphifyRuntimeActive = settings.isGraphifyRuntimeActive
        guard let context else {
            tokenSaverHeavyReloadTask?.cancel()
            tokenSaverHeavyReloadTask = nil
            tokenSaverUsageSnapshot = .empty()
            tokenSaverSavingsSummary = .empty
            tokenSaverDailyEconomyToday = nil
            tokenSaverDailyEconomyWeekTotal = 0
            tokenSaverProviderCacheAmortToday = [:]
            return
        }
        // Keep today's economy row fresh so Week = Σ dailies stays aligned.
        context.recomputeTokenSaverDailyEconomyToday()
        let result = await Self.loadTokenSaverHeavy(
            appSupportDirectory: context.appSupportDirectory,
            savingsRepo: context.tokenSaverSavingsRepo,
            economyRepo: context.tokenSaverDailyEconomyRepo
        )
        tokenSaverUsageSnapshot = result.snapshot
        tokenSaverSavingsSummary = result.summary
        tokenSaverDailyEconomyToday = result.economyToday
        tokenSaverDailyEconomyWeekTotal = result.economyWeekTotal
        tokenSaverProviderCacheAmortToday = result.providerCacheAmortToday
        updateTokenSaverLocalUsage(from: result.snapshot, emitPositiveChange: false)
    }

    /// Runs the heavy Token Saver reads off the main actor. `repo` is
    /// `@unchecked Sendable` and `TokenSaverUsageStore(...).load()` only reads
    /// a file, so both are safe to call on a background executor.
    private static func loadTokenSaverHeavy(
        appSupportDirectory: URL,
        savingsRepo: TokenSaverSavingsRepository,
        economyRepo: TokenSaverDailyEconomyRepository
    ) async -> (
        snapshot: TokenSaverUsageSnapshot,
        summary: TokenSaverSavingsSummary,
        economyToday: TokenSaverDailyEconomyRecord?,
        economyWeekTotal: Int,
        providerCacheAmortToday: [String: Int]
    ) {
        await Task.detached {
            let snapshot = TokenSaverUsageStore(appSupportDirectory: appSupportDirectory).load()
            let summary = (try? savingsRepo.summary()) ?? .empty
            let cal = Calendar.current
            let now = Date()
            let todayStart = cal.startOfDay(for: now)
            let todayMs = Int64(todayStart.timeIntervalSince1970 * 1000)
            let weekStart = cal.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
            let weekStartMs = Int64(weekStart.timeIntervalSince1970 * 1000)
            let weekEndExclusive = cal.date(byAdding: .day, value: 1, to: todayStart) ?? now
            let weekEndMs = Int64(weekEndExclusive.timeIntervalSince1970 * 1000)
            let economyToday = try? economyRepo.record(dayStartMs: todayMs)
            // Hybrid week: economy days (full formula) + measured-only for pre-feature days.
            let weekTotal = (try? economyRepo.windowTotalCredible(
                fromDayStartMs: weekStartMs,
                toDayStartMs: todayMs,
                toDayEndMsExclusive: weekEndMs
            ).total) ?? 0
            let dayEndMs = Int64(weekEndExclusive.timeIntervalSince1970 * 1000)
            let amortInputs = (try? savingsRepo.threadCacheAmortizationInputs(
                dayStartMs: todayMs,
                dayEndMsExclusive: dayEndMs
            )) ?? []
            var byProvider: [String: Int] = [:]
            for row in amortInputs {
                let credit = TokenSaverBareUserEstimator.sumThreadCacheAmortization(
                    savedTokens: row.savedTokens,
                    runs: row.runs
                )
                byProvider[row.provider, default: 0] = TokenSaverBareUserEstimator.saturatingAdd(
                    byProvider[row.provider] ?? 0,
                    credit
                )
            }
            return (snapshot, summary, economyToday, weekTotal, byProvider)
        }.value
    }

    public func refreshTokenSaverAccountUsageForDetails() {
        guard !tokenSaverAccountUsageIsRefreshing else { return }
        guard privateAccountUser != nil else { return }
        tokenSaverAccountUsageIsRefreshing = true
        // Fire-and-forget: kick the refresh, then observe the usage-changed
        // notification to detect completion.  A 90-second timeout ensures the
        // spinner stops even when the CLI probe hangs or the notification is
        // never posted (e.g. signed-out race).
        Task { @MainActor [weak self] in
            guard let self else { return }
            var observer: NSObjectProtocol?
            let done = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                // One-shot notification observer -- resumes with true on completion.
                observer = NotificationCenter.default.addObserver(
                    forName: .rc2TokenSaverUsageChanged,
                    object: nil,
                    queue: .main
                ) { _ in
                    if let o = observer { NotificationCenter.default.removeObserver(o) }
                    observer = nil
                    continuation.resume(returning: true)
                }
                self.context?.refreshTokenSaverAccountUsage(reason: "details")
                // Schedule a timeout: if no notification arrives within 90 s,
                // resume with false so the spinner stops.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 90_000_000_000)
                    guard let o = observer else { return }
                    NotificationCenter.default.removeObserver(o)
                    observer = nil
                    continuation.resume(returning: false)
                }
            }
            self.tokenSaverAccountUsageIsRefreshing = false
            if done { self.tokenSaverAccountUsageLastUpdated = Date() }
        }
    }

    public func setInsomniaEnabled(_ enabled: Bool) {
        insomniaEnabled = enabled
        settingsStore.update {
            $0.insomniaEnabled = enabled
        }
        applyInsomniaPower()
    }

    public func setInsomniaAllowDisplaySleep(_ enabled: Bool) {
        insomniaAllowDisplaySleep = enabled
        settingsStore.update { $0.insomniaAllowDisplaySleep = enabled }
        applyInsomniaPower()
    }

    public func setInsomniaAllowSystemSleepWhenDisplayClosed(_ enabled: Bool) {
        insomniaAllowSystemSleepWhenDisplayClosed = enabled
        settingsStore.update { $0.insomniaAllowSystemSleepWhenDisplayClosed = enabled }
        applyInsomniaPower()
    }

    public func setInsomniaAllowScreenSaverAfter45MinutesOfInactivity(_ enabled: Bool) {
        insomniaAllowScreenSaverAfter45MinutesOfInactivity = enabled
        settingsStore.update { $0.insomniaAllowScreenSaverAfter45MinutesOfInactivity = enabled }
        applyInsomniaPower()
    }

    public func disableInsomniaForAppClose() {
        finishInsomniaSession()
    }

    public func setTokenSaverEnabled(_ enabled: Bool) {
        if !enabled {
            let confirmed: Bool
            if let provider = tokenSaverDisableConfirmProvider {
                confirmed = provider()
            } else {
                confirmed = Self.defaultTokenSaverDisableConfirm()
            }
            guard confirmed else { return }
            tokenSaverEnabled = false
            graphifyRuntimeActive = false
            settingsStore.update {
                $0.tokenSaverEnabled = false
            }
            _ = context?.applyTokenSaverLifecycle(
                requestedEnabled: false,
                persistPreference: true
            )
            // Footer + other surfaces re-check eligibility immediately.
            NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)
            return
        }
        guard privateAccountUser?.subscribed == true else { return }
        let selectedValidation = validateTokenSaverModel(requireSelectedModel: true)
        if selectedValidation.state == .installed {
            tokenSaverEnabled = true
            settingsStore.update {
                $0.tokenSaverEnabled = true
            }
            graphifyRuntimeActive = settingsStore.load().isGraphifyRuntimeActive
            refreshTokenSaverDistillService(modelValidation: selectedValidation)
            NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)
            return
        }

        let installedFallbackValidation = validateTokenSaverModel(requireSelectedModel: false)
        if installedFallbackValidation.state == .installed {
            tokenSaverEnabled = true
            settingsStore.update {
                $0.tokenSaverEnabled = true
            }
            graphifyRuntimeActive = settingsStore.load().isGraphifyRuntimeActive
            refreshTokenSaverDistillService(modelValidation: installedFallbackValidation)
            beginTokenSaverModelDownload(reason: selectedValidation.reason)
            NotificationCenter.default.post(name: .rc2TokenSaverUsageChanged, object: nil)
            return
        }

        guard selectedValidation.state == .installed else {
            // Model is not present: require confirmation before starting the
            // multi-GB download. Skip the prompt only when the model is already
            // installed (no download needed).
            let freeDisk = Self.volumeFreeDiskBytes()
            let decision = Self.downloadConfirmDecision(
                modelBytes: Self.approvedModelEstimatedBytes,
                freeDiskBytes: freeDisk
            )
            let sizeString = Self.humanModelSizeString()
            let hasEnoughDisk = decision == .confirm
            let confirmed: Bool
            if let provider = tokenSaverDownloadConfirmProvider {
                confirmed = provider(sizeString, hasEnoughDisk)
            } else {
                confirmed = Self.defaultTokenSaverDownloadConfirm(sizeString: sizeString, hasEnoughDisk: hasEnoughDisk)
            }
            guard confirmed else { return }
            beginTokenSaverModelDownload(reason: selectedValidation.reason)
            return
        }
    }

    public func dismissTokenSaverModelDownload() {
        showsTokenSaverModelDownload = false
    }

    public func cancelTokenSaverModelDownload() {
        tokenSaverModelDownloadTask?.cancel()
        tokenSaverModelDownloadTask = nil
        tokenSaverModelDownloadState = TokenSaverModelDownloadState(
            phase: .paused,
            downloadedBytes: tokenSaverModelDownloadState.downloadedBytes,
            expectedBytes: tokenSaverModelDownloadState.expectedBytes,
            statusText: "Download paused"
        )
        showsTokenSaverModelDownload = false
    }

    public func retryTokenSaverModelDownload() {
        beginTokenSaverModelDownload(reason: nil)
    }

    /// Resumes a paused download. Shows the modal again and restarts the
    /// download from the beginning (the downloader does not support HTTP range
    /// resume, so "resume" means "start over from the paused state").
    public func resumeTokenSaverModelDownload() {
        showsTokenSaverModelDownload = true
        beginTokenSaverModelDownload(reason: nil)
    }

    // Maps a download error to a human-readable headline. Raw detail is available
    // separately so the UI can show it as secondary copy, not as the headline.
    nonisolated public static func downloadErrorMessage(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .timedOut, .internationalRoamingOff, .callIsActive,
                 .dataNotAllowed:
                return "No internet connection. Check your network and try again."
            case .cancelled:
                return "Download was cancelled."
            default:
                break
            }
        }
        if let downloadError = error as? TokenSaverModelDownloadError {
            switch downloadError {
            case .httpStatus(let code, _) where code == 401 || code == 403:
                return "Access denied. Make sure you are signed in and your subscription is active."
            case .httpStatus(let code, _) where code == 404:
                return "Model file not found on the server. Try again later."
            case .httpStatus(let code, _) where code >= 500:
                return "Server error (\(code)). Try again in a few minutes."
            case .httpStatus(let code, _):
                return "Download failed with server error \(code). Try again later."
            case .validationFailed:
                return "Downloaded model failed verification. The file may be corrupt. Retrying usually fixes this."
            case .noModelFiles, .invalidModelResponse:
                return "Could not read model information from the server. Try again later."
            case .invalidDownloadURL:
                return "Received an invalid download link. Try again later."
            }
        }
        if let nsError = error as? NSError, nsError.domain == NSCocoaErrorDomain {
            if nsError.code == NSFileWriteOutOfSpaceError || nsError.code == NSFileWriteVolumeReadOnlyError {
                return "Not enough disk space to save the model. Free up space and try again."
            }
        }
        return "Download failed. Try again."
    }

    // Pure helper: aggregate % and ETA from cumulative byte counters.
    // Guards: totalBytes==0 -> (0, nil); bytesPerSec<=0 -> (percent, nil).
    // The totalBytes value is an estimate until all per-file Content-Length
    // headers are resolved; it grows as each new file begins downloading.
    nonisolated public static func aggregateProgress(
        downloadedBytes: Int64,
        totalBytes: Int64,
        bytesPerSec: Double
    ) -> (percent: Int, etaSeconds: Int?) {
        guard totalBytes > 0, downloadedBytes >= 0 else { return (0, nil) }
        let fraction = min(Double(downloadedBytes) / Double(totalBytes), 1.0)
        let percent = Int((fraction * 100).rounded())
        guard bytesPerSec > 0 else { return (percent, nil) }
        let remaining = totalBytes - downloadedBytes
        let eta = remaining <= 0 ? 0 : Int((Double(remaining) / bytesPerSec).rounded())
        return (percent, eta)
    }

    // Formats seconds as "Xs", "Xm Ys", or "Xh Ym".
    nonisolated public static func formatDownloadETA(_ seconds: Int) -> String {
        guard seconds > 0 else { return "0s" }
        if seconds < 60 { return "\(seconds)s" }
        let mins = seconds / 60
        let secs = seconds % 60
        if mins < 60 {
            return secs > 0 ? "\(mins)m \(secs)s" : "\(mins)m"
        }
        let hrs = mins / 60
        let remMins = mins % 60
        return remMins > 0 ? "\(hrs)h \(remMins)m" : "\(hrs)h"
    }

    public func setTokenSaverModelDownloadStateForTesting(_ state: TokenSaverModelDownloadState) {
        tokenSaverModelDownloadState = state
    }

    public func markTokenSaverModelInstalledForTesting() {
        tokenSaverModelDownloadState = .ready
        showsTokenSaverModelDownload = false
        tokenSaverEnabled = true
        settingsStore.update {
            $0.tokenSaverEnabled = true
        }
        refreshTokenSaverDistillService(modelValidation: .installed)
    }

    private func validateTokenSaverModel(requireSelectedModel: Bool = false) -> TokenSaverModelValidation {
        if let tokenSaverModelValidationProvider {
            return tokenSaverModelValidationProvider()
        }
        guard let context else {
            return TokenSaverModelValidation(state: .missing, reason: "app support unavailable")
        }
        return TokenSaverModelInstaller(appSupportDirectory: context.appSupportDirectory)
            .validateInstalledTokenSaverModels(requireSelectedModel: requireSelectedModel)
    }

    private func beginTokenSaverModelDownload(reason: String?) {
        tokenSaverModelDownloadTask?.cancel()
        tokenSaverModelDownloadState = .required(reason: reason)
        showsTokenSaverModelDownload = true
        // Reset aggregate counters for this download session.
        _aggregateCompletedBytes = 0
        _aggregateCompletedExpected = 0
        _aggregateLastFileBytes = 0
        _aggregateSpeedSample = (0, Date())
        tokenSaverAggregatedDownloadedBytes = 0
        tokenSaverAggregatedTotalBytes = 0
        tokenSaverDownloadBytesPerSec = 0

        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            do {
                let manifest = try await self.downloadTokenSaverModel { [weak self] state in
                    guard let self else { return }
                    // Detect per-file resets: if bytes went backward, a file finished.
                    if state.downloadedBytes < self._aggregateLastFileBytes {
                        self._aggregateCompletedBytes += self._aggregateLastFileBytes
                        self._aggregateCompletedExpected += self._aggregateLastFileBytes
                    }
                    self._aggregateLastFileBytes = state.downloadedBytes
                    let aggregateDownloaded = self._aggregateCompletedBytes + state.downloadedBytes
                    // Total is completed-file bytes + current file expected (if known).
                    let aggregateTotal = self._aggregateCompletedExpected + (state.expectedBytes ?? state.downloadedBytes)
                    // Speed: bytes/sec over elapsed time since last sample (minimum 0.5 s window).
                    let now = Date()
                    let elapsed = now.timeIntervalSince(self._aggregateSpeedSample.time)
                    if elapsed >= 0.5 {
                        let deltaBytes = aggregateDownloaded - self._aggregateSpeedSample.bytes
                        self.tokenSaverDownloadBytesPerSec = elapsed > 0 ? Double(deltaBytes) / elapsed : 0
                        self._aggregateSpeedSample = (aggregateDownloaded, now)
                    }
                    self.tokenSaverAggregatedDownloadedBytes = aggregateDownloaded
                    self.tokenSaverAggregatedTotalBytes = aggregateTotal
                    self.tokenSaverModelDownloadState = state
                }
                let validation = self.validateTokenSaverModel()
                guard validation.state == .installed else {
                    throw TokenSaverModelDownloadError.validationFailed(validation.reason)
                }
                self.tokenSaverModelDownloadState = .ready
                self.showsTokenSaverModelDownload = false
                self.tokenSaverEnabled = true
                self.settingsStore.update {
                    $0.tokenSaverEnabled = true
                }
                self.refreshTokenSaverDistillService(modelValidation: validation)
                return manifest
            } catch is CancellationError {
                self.tokenSaverModelDownloadState = TokenSaverModelDownloadState(
                    phase: .paused,
                    downloadedBytes: self.tokenSaverModelDownloadState.downloadedBytes,
                    expectedBytes: self.tokenSaverModelDownloadState.expectedBytes,
                    statusText: "Download paused"
                )
                throw CancellationError()
            } catch {
                let headline = Self.downloadErrorMessage(error)
                let detail = String(describing: error)
                let message = detail == headline ? headline : "\(headline)\n\(detail)"
                self.tokenSaverModelDownloadState = TokenSaverModelDownloadState(
                    phase: .failed,
                    downloadedBytes: self.tokenSaverModelDownloadState.downloadedBytes,
                    expectedBytes: self.tokenSaverModelDownloadState.expectedBytes,
                    statusText: "Download failed",
                    errorMessage: message
                )
                self.showsTokenSaverModelDownload = true
                throw error
            }
        }
        tokenSaverModelDownloadTask = task
    }

    private func downloadTokenSaverModel(
        progress: @escaping @MainActor (TokenSaverModelDownloadState) -> Void
    ) async throws -> TokenSaverModelManifest {
        if let tokenSaverModelDownloadHandler {
            return try await tokenSaverModelDownloadHandler(progress)
        }
        guard let context else {
            throw TokenSaverModelDownloadError.validationFailed("app support unavailable")
        }
        let downloader = TokenSaverModelDownloader(
            installer: TokenSaverModelInstaller(appSupportDirectory: context.appSupportDirectory)
        )
        return try await downloader.downloadRequiredModels { state in
            Task { @MainActor in
                progress(state)
            }
        }
    }

    private func refreshTokenSaverDistillService(modelValidation: TokenSaverModelValidation) {
        guard let context else { return }
        let outcome = context.applyTokenSaverLifecycle(
            requestedEnabled: settingsStore.load().tokenSaverEnabled,
            modelValidation: modelValidation,
            persistPreference: true
        )
        tokenSaverEnabled = outcome.isEnabled
        graphifyRuntimeActive = settingsStore.load().isGraphifyRuntimeActive
    }

    /// Returns the number of free bytes on the volume that hosts the home
    /// directory, or 0 when the query fails. Used only for disk-space checks
    /// before the download confirm dialog; the real disk write can still fail
    /// if space changes between the check and the download.
    nonisolated public static func volumeFreeDiskBytes() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage {
            return available
        }
        // Fall back to the basic free-capacity key.
        let basic = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        if let available = basic?.volumeAvailableCapacity {
            return Int64(available)
        }
        return 0
    }

    /// Blocking NSAlert confirmation shown before a multi-GB Token Saver model
    /// download begins. Shows the download size and warns when disk is low.
    public static func defaultTokenSaverDownloadConfirm(
        sizeString: String,
        hasEnoughDisk: Bool
    ) -> Bool {
        let alert = NSAlert()
        if hasEnoughDisk {
            alert.alertStyle = .informational
            alert.messageText = "Download Token Saver model (\(sizeString))?"
            alert.informativeText = "Token Saver uses a local AI model to compress prompts. The model is downloaded once and stored on this Mac."
        } else {
            alert.alertStyle = .warning
            alert.messageText = "Not enough disk space"
            alert.informativeText = "The Token Saver model requires approximately \(sizeString) of free disk space, but this Mac does not appear to have enough available. Free up space before continuing."
        }
        alert.addButton(withTitle: hasEnoughDisk ? "Download" : "OK")
        if hasEnoughDisk {
            alert.addButton(withTitle: "Cancel")
        }
        let response = alert.runModal()
        return hasEnoughDisk && response == .alertFirstButtonReturn
    }

    /// Pure seam: returns true when a disable-confirm alert should be shown
    /// before stopping Token Saver. Always returns true so every disable goes
    /// through the confirm path; extracted for testing without spinning an NSAlert.
    ///
    /// WHY separate: the alert blocks the main thread. Tests inject
    /// `tokenSaverDisableConfirmProvider` to skip the alert; this seam documents
    /// the decision boundary (always confirm) independently of the alert copy.
    nonisolated public static func shouldConfirmTokenSaverDisable() -> Bool {
        return true
    }

    /// Blocking NSAlert shown before Token Saver is disabled. Disabling stops
    /// the sidecar process and uninstalls the managed distill skill.
    public static func defaultTokenSaverDisableConfirm() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Disable Token Saver?"
        alert.informativeText = "Disabling Token Saver stops the local model and uninstalls the compression skill. You can re-enable it at any time."
        alert.addButton(withTitle: "Disable")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    public static func defaultInsomniaBatteryPrompt() -> InsomniaBatteryDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Insomnia is on while your MacBook is on battery"
        alert.informativeText = "Insomnia can drain the battery because it keeps this Mac awake. Do you want to keep Insomnia on or disable it now?"
        alert.addButton(withTitle: "Disable Insomnia")
        alert.addButton(withTitle: "Keep Insomnia On")
        return alert.runModal() == .alertFirstButtonReturn ? .disable : .keepEnabled
    }

    private func handleExternalPowerStateChanged(_ state: ExternalPowerState) {
        let previousPowerState = lastPowerState
        lastPowerState = state
        guard previousPowerState != .battery, state == .battery else { return }
        confirmInsomniaOnBatteryIfNeeded()
    }

    private func confirmInsomniaOnBatteryIfNeeded() {
        guard insomniaEnabled, !showingInsomniaBatteryPrompt else { return }
        showingInsomniaBatteryPrompt = true
        let decision = insomniaBatteryPrompt()
        showingInsomniaBatteryPrompt = false
        if decision == .disable {
            setInsomniaEnabled(false)
        }
    }

    private func applyInsomniaPower() {
        guard insomniaEnabled else {
            insomniaPower.deactivate()
            return
        }

        guard insomniaPower.activate(reason: "RemoteCode Insomnia", options: insomniaPowerOptions) else {
            NSLog("RemoteCode Insomnia failed to activate macOS power assertions.")
            finishInsomniaSession()
            // UX-P2: surface the failure so the user knows why the toggle snapped off.
            showOperationError(
                "Insomnia could not keep the display or system awake",
                detail: "macOS denied the power assertion. RemoteCode may use `pmset` to disable clamshell sleep, which requires administrator privileges. Insomnia has been turned off."
            )
            return
        }
    }

    private func finishInsomniaSession() {
        insomniaEnabled = false
        insomniaPower.deactivate()
        settingsStore.update {
            $0.insomniaEnabled = false
        }
    }

    private var insomniaPowerOptions: InsomniaPowerOptions {
        InsomniaPowerOptions(
            allowDisplaySleep: insomniaAllowDisplaySleep,
            allowSystemSleepWhenDisplayClosed: insomniaAllowSystemSleepWhenDisplayClosed,
            allowScreenSaverAfter45MinutesOfInactivity: insomniaAllowScreenSaverAfter45MinutesOfInactivity
        )
    }

    public func select(_ wid: WorkspaceID) {
        selectedWorkspaceIDs.removeAll()
        selectionAnchorID = wid
        selectedWorkspaceID = wid
        isScheduledTasksSelected = false
        // UX-SIDEBAR-COMPLETED-DOT: opening a workspace clears its completed dot.
        completedWorkspaces.remove(wid)
        try? router?.selectWorkspace(wid)
        onWorkspaceContentActivated?()
    }

    /// Clears shift-range anchor when leaving workspaces for a shell destination.
    func clearSelectionAnchorForShellDestination() {
        selectionAnchorID = nil
    }

    public func selectWorkspaceRow(_ ws: Workspace, extendingSelection: Bool, togglingSelection: Bool = false) {
        if togglingSelection {
            toggleWorkspaceSelection(ws.id)
        } else if extendingSelection {
            extendWorkspaceSelection(to: ws.id)
        } else {
            select(ws.id)
        }
    }

    private func toggleWorkspaceSelection(_ id: WorkspaceID) {
        if selectedWorkspaceIDs.contains(id) {
            selectedWorkspaceIDs.remove(id)
        } else {
            selectedWorkspaceIDs.insert(id)
        }
        selectionAnchorID = id
    }

    private func extendWorkspaceSelection(to id: WorkspaceID) {
        let anchor = selectionAnchorID ?? selectedWorkspaceID ?? id
        // UX-SIDEBAR-P1-SHIFTRANGE: use filteredWorkspaces so a range selection
        // when a filter is active never includes workspaces the user cannot see.
        // Using the full `workspaces` array would produce a range spanning hidden
        // rows, causing "Remove" to silently delete workspaces outside the filter.
        let visible = filteredWorkspaces
        guard let start = visible.firstIndex(where: { $0.id == anchor }),
              let end = visible.firstIndex(where: { $0.id == id }) else {
            selectedWorkspaceIDs.insert(id)
            selectionAnchorID = id
            return
        }
        let range = start <= end ? start...end : end...start
        selectedWorkspaceIDs = Set(range.map { visible[$0].id })
    }

    /// IMP-MAC_SHELL_WINDOW-009: the workspace rows to render, narrowed by
    /// `filterText`. Order matches the canonical `workspaces` array so the
    /// shown rows still carry the real workspace identities used by
    /// drag-reorder (which resolves indices against `workspaces`).
    public var filteredWorkspaces: [Workspace] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return workspaces }
        return workspaces.filter { ws in
            if ws.name.lowercased().contains(query) { return true }
            if (ws.metadata["description"]?.lowercased().contains(query)) == true { return true }
            return ws.cwd.lowercased().contains(query)
        }
    }

    public func newWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            _ = createWorkspaces(fromFolders: Self.uniqueFolderURLs(panel.urls, excluding: workspaces))
        }
    }

    @discardableResult
    public func createWorkspace(fromFolder url: URL) -> Bool {
        guard let router else { return false }
        // DEDUP-P2: if a workspace with the same cwd already exists, flash
        // to it instead of creating a duplicate (drag-drop / Open Recent /
        // Cmd+N all call this path).
        if let existing = Self.findExistingWorkspace(byCwd: url, in: workspaces) {
            select(existing)
            return true
        }
        do {
            _ = try router.createWorkspace(fromFolder: url)
            // UX-MAC_SHELL_WINDOW-005: remember opened folders so they
            // appear under File ▸ Open Recent on the next open.
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            reload()
            return true
        } catch {
            return false
        }
    }

    /// Pure helper: returns the ID of the first workspace in `workspaces`
    /// whose cwd resolves to the same standardized path as `url`, or nil if
    /// no match exists.  Path-normalized comparison handles trailing slashes
    /// and symlink-free canonicalization consistently with
    /// `AppCommandRouter.createWorkspace(fromFolder:)`.
    nonisolated public static func findExistingWorkspace(
        byCwd url: URL,
        in workspaces: [Workspace]
    ) -> WorkspaceID? {
        let normalized = url.standardizedFileURL.path
        return workspaces.first { ws in
            URL(fileURLWithPath: ws.cwd).standardizedFileURL.path == normalized
        }?.id
    }

    /// Pure helper: deduplicates a raw panel URL list before workspace-add.
    ///
    /// Removes:
    /// - intra-selection duplicates (same standardized path appearing more than
    ///   once, e.g. a folder and its alias both selected).
    /// - URLs whose cwd already exists in `workspaces` (reuses the same
    ///   path-normalization as `findExistingWorkspace(byCwd:in:)`).
    ///
    /// Input order is preserved.  This is the canonical single place for
    /// multi-folder add dedup; `newWorkspace()` passes the NSOpenPanel result
    /// here before calling `createWorkspaces(fromFolders:)`.
    nonisolated public static func uniqueFolderURLs(
        _ urls: [URL],
        excluding workspaces: [Workspace]
    ) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return nil }
            guard findExistingWorkspace(byCwd: url, in: workspaces) == nil else { return nil }
            return url
        }
    }

    /// P2-SIDEBAR-SEPARATOR: Returns the index at which a pinned/unpinned
    /// divider should be inserted in `rows`, or `nil` when no divider is
    /// needed (empty list, all rows pinned, or no rows pinned).
    ///
    /// The index equals the count of leading pinned rows, i.e. the position
    /// of the first unpinned row.  Only rows whose metadata["pinned"] == "true"
    /// are considered pinned.
    nonisolated public static func pinnedSeparatorIndex(in rows: [Workspace]) -> Int? {
        guard !rows.isEmpty else { return nil }
        let count = rows.prefix(while: { $0.metadata["pinned"] == "true" }).count
        guard count > 0, count < rows.count else { return nil }
        return count
    }

    @discardableResult
    public func createWorkspaces(fromFolders urls: [URL]) -> Bool {
        urls.reduce(false) { created, url in
            createWorkspace(fromFolder: url) || created
        }
    }

    @discardableResult
    public func createWorkspaces(fromDroppedProviders providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }

        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                guard let url = Self.fileURL(fromDroppedItem: item) else { return }
                // UX-P2: reject non-folder drops; only directories can be workspaces.
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      isDir.boolValue else {
                    DispatchQueue.main.async {
                        self?.showOperationError(
                            "Cannot add \"\(url.lastPathComponent)\" as a workspace",
                            detail: "Only folders can be added as workspaces. Please drop a folder instead."
                        )
                    }
                    return
                }
                DispatchQueue.main.async {
                    _ = self?.createWorkspace(fromFolder: url)
                }
            }
        }
        return true
    }

    nonisolated static func fileURL(fromDroppedItem item: Any?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let data = item as? NSData {
            return URL(dataRepresentation: data as Data, relativeTo: nil)
        }
        if let string = item as? String {
            return URL(string: string) ?? URL(fileURLWithPath: string)
        }
        return nil
    }

    public func toggleSidebar() {
        NotificationCenter.default.post(name: .rc2ToggleSidebar, object: nil)
    }

    public var showsUpdateControl: Bool {
        updateChecker != nil
    }

    public var updateActionTitle: String {
        switch updateAvailability {
        case .available:
            return "Update Available"
        case .checking:
            return "Checking for Updates"
        case .upToDate:
            return "Up to Date"
        case .failed:
            return "Update Check Failed"
        case .unknown:
            return "Check for Updates"
        }
    }

    public var updateActionEnabled: Bool {
        updateChecker != nil && updateAvailability != .checking
    }

    public var updateActionHighlighted: Bool {
        updateAvailability == .available
    }

    public func checkForUpdates() {
        updateChecker?.checkForUpdates()
    }

    public func openWorkspaceInNewWindow(_ ws: Workspace) {
        router?.openWorkspaceInNewWindow(ws.id)
    }

    public static func finderURL(for ws: Workspace) -> URL? {
        guard !ws.cwd.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: ws.cwd, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: ws.cwd, isDirectory: true)
    }

    public func openWorkspaceInFinder(_ ws: Workspace) {
        guard let url = Self.finderURL(for: ws) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: cmux-style workspace editing (AppKit prompts — reliable,
    // no SwiftUI sheet plumbing).

    /// Builds and configures the NSAlert+accessoryView used by rename/description prompts.
    /// Pure setup -- no modal call. Separated so both the sheet and runModal paths
    /// share identical alert configuration.
    private func buildPromptAlert(title: String, message: String, initial: String, multiline: Bool) -> (NSAlert, NSTextField) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field: NSTextField
        if multiline {
            // UX-MAC_SHELL_WINDOW-006: descriptions get a taller, wrapping
            // field instead of a single-line entry.
            field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 84))
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            field.usesSingleLineMode = false
            field.maximumNumberOfLines = 0
            field.lineBreakMode = .byWordWrapping
        } else {
            field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        }
        field.stringValue = initial
        field.placeholderString = title
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return (alert, field)
    }

    /// :15 -- Presents a text-input prompt as a window sheet when a window is
    /// available. Falls back to runModal (blocking) when there is no key window
    /// (e.g. headless tests) so synchronous test callers are unaffected.
    ///
    /// WHY sheet: NSAlert.runModal() blocks all windows in the app, including
    /// detached workspace windows. beginSheetModal attaches the dialog to the
    /// specific window so other windows remain responsive.
    private func presentPromptSheet(title: String, message: String, initial: String, multiline: Bool = false, completion: @escaping (String?) -> Void) {
        let (alert, field) = buildPromptAlert(title: title, message: message, initial: initial, multiline: multiline)
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn
                    ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil)
            }
        } else {
            // Fallback: no window (headless / test). runModal is synchronous;
            // completion fires before this function returns.
            let response = alert.runModal()
            completion(response == .alertFirstButtonReturn
                ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil)
        }
    }

    public func renameWorkspace(_ ws: Workspace) {
        // :95 -- Route through workspacePrompter so tests can drive the decision.
        guard let prompter = workspacePrompter else { return }
        prompter.promptForText(
            title: "Rename workspace",
            message: "New name for \"\(ws.name)\".",
            initial: ws.name,
            multiline: false
        ) { [weak self] decision in
            guard let self else { return }
            guard case .committed(let name) = decision else { return }
            // UX-P3: whitespace-only rename must show an error rather than silently
            // doing nothing, so the user knows the save was rejected.
            guard !name.isEmpty else {
                self.showOperationError("Rename not saved",
                                       detail: "A workspace name cannot be blank. Please enter at least one non-whitespace character.")
                return
            }
            do {
                try self.router?.renameWorkspace(ws.id, name)
            } catch {
                self.showOperationError("Could not rename workspace", detail: error.localizedDescription)
            }
        }
    }

    public func editDescription(_ ws: Workspace) {
        // :95 -- Route through workspacePrompter so tests can drive the decision.
        guard let prompter = workspacePrompter else { return }
        let current = ws.metadata["description"] ?? ""
        prompter.promptForText(
            title: "Workspace description",
            message: "Optional note for \"\(ws.name)\".",
            initial: current,
            multiline: true
        ) { [weak self] decision in
            guard let self else { return }
            guard case .committed(let text) = decision else { return }
            do {
                try self.router?.setWorkspaceDescription(ws.id, text)
            } catch {
                self.showOperationError("Could not update description", detail: error.localizedDescription)
            }
        }
    }

    public func setWorkspaceColor(_ ws: Workspace, _ color: String) {
        try? router?.setWorkspaceColor(ws.id, color)
    }

    public func setWorkspacePinned(_ ws: Workspace, _ pinned: Bool) {
        try? router?.setWorkspacePinned(ws.id, pinned)
        reload()
    }

    public func isWorkspaceBusy(_ ws: Workspace) -> Bool {
        if let cached = busyStateCache[ws.id] { return cached }
        let busy = computeWorkspaceBusy(ws)
        busyStateCache[ws.id] = busy
        return busy
    }

    private func computeWorkspaceBusy(_ ws: Workspace) -> Bool {
        if ws.metadata["busy"] == "true" { return true }
        if let router { return router.isWorkspaceBusy(ws.id) }
        return ws.layout.paneIDs().contains { pid in
            (ws.layout.find(paneID: pid)?.surfaces ?? []).contains {
                guard SurfaceRegistry.shared.surface($0.id)?.isBusy == true else { return false }
                switch $0.type {
                case .terminal, .agentApp:
                    return true
                case .ssh, .browser, .files, .markdown, .filePreview, .rightSidebarTool:
                    return false
                }
            }
        }
    }

    // MARK: Row accessibility value

    /// Pure helper: builds the VoiceOver value string for a workspace row from
    /// pre-computed state flags.  Returns an empty string for an idle, normal row.
    ///
    /// - Parameters:
    ///   - busyDescription: output of `busyTooltip(...)`, or nil when idle.
    ///   - unreadCount: `ws.notificationsUnread`
    ///   - pinned: whether `ws.metadata["pinned"] == "true"`
    ///   - checked: whether the row is in `selectedWorkspaceIDs`
    nonisolated public static func workspaceRowAccessibilityValue(
        busyDescription: String?,
        unreadCount: Int,
        pinned: Bool,
        checked: Bool
    ) -> String {
        var parts: [String] = []
        if let desc = busyDescription { parts.append(desc) }
        if unreadCount > 0 { parts.append("\(unreadCount) unread") }
        if pinned { parts.append("pinned") }
        if checked { parts.append("selected") }
        return parts.joined(separator: ", ")
    }

    // MARK: Busy tooltip

    /// Pure helper: derives a human-readable busy tooltip string from raw title
    /// lists. Thread-busy takes priority over surface-busy. Returns nil when
    /// neither list has entries (idle).
    ///
    /// - Parameters:
    ///   - runningThreadTitles: titles of agent threads whose status == .running
    ///   - busySurfaceTitles: titles of terminal/agentApp surfaces that are busy
    nonisolated public static func busyTooltip(
        runningThreadTitles: [String],
        busySurfaceTitles: [String]
    ) -> String? {
        if let first = runningThreadTitles.first {
            let display = first.isEmpty ? "Untitled" : first
            return "Agent run in thread \"\(display)\""
        }
        if let first = busySurfaceTitles.first {
            let display = first.isEmpty ? "terminal" : first
            return "Terminal job running in \"\(display)\""
        }
        return nil
    }

    /// Returns a tooltip string describing the active busy source for `ws`,
    /// or nil when the workspace is idle.
    public func busyTooltip(for ws: Workspace) -> String? {
        let threadTitles: [String]
        if let router, let ctx = context {
            threadListCallCount += 1
            threadTitles = ((try? ctx.threadRepo.list(workspaceId: ws.id)) ?? [])
                .filter { $0.status == .running }
                .map(\.title)
        } else {
            threadTitles = []
        }
        let surfaceTitles: [String] = ws.layout.paneIDs().flatMap { pid -> [String] in
            guard let pane = ws.layout.find(paneID: pid) else { return [] }
            return pane.surfaces.compactMap { desc -> String? in
                guard SurfaceRegistry.shared.surface(desc.id)?.isBusy == true else { return nil }
                switch desc.type {
                case .terminal, .agentApp:
                    return desc.title
                case .ssh, .browser, .files, .markdown, .filePreview, .rightSidebarTool:
                    return nil
                }
            }
        }
        return Self.busyTooltip(runningThreadTitles: threadTitles, busySurfaceTitles: surfaceTitles)
    }

    public func reorderWorkspace(_ dragged: WorkspaceID, before target: WorkspaceID) {
        guard dragged != target,
              let targetIndex = workspaces.firstIndex(where: { $0.id == target }) else { return }
        try? router?.reorderWorkspace(dragged, position: targetIndex)
        draggingWorkspaceID = nil
        dropTargetWorkspaceID = nil
        dragScrollEdge = 0
        reload()
    }

    public func removeWorkspace(_ ws: Workspace) {
        // :95 -- Route through workspacePrompter so tests can drive the decision.
        // The AppKitWorkspacePrompter default preserves the :15 sheet/runModal fallback.
        guard let prompter = workspacePrompter else { return }
        prompter.confirmRemoveOne(name: ws.name) { [weak self] decision in
            guard let self, decision == .confirmed else { return }
            do {
                let entry = WorkspaceUndoEntry(name: ws.name, cwd: ws.cwd, metadata: ws.metadata)
                self.removedWorkspaceStack = WorkspaceUndoStack.push(entry, onto: self.removedWorkspaceStack)
                try self.router?.closeWorkspace(ws.id)
            } catch {
                // Roll back the undo push if close failed.
                self.removedWorkspaceStack = WorkspaceUndoStack.pop(from: self.removedWorkspaceStack)?.remaining ?? self.removedWorkspaceStack
                self.showOperationError("Could not remove workspace", detail: error.localizedDescription)
            }
        }
    }

    /// Pure helper: determines whether a context-menu gesture on `clickedID`
    /// should produce a multi-select menu or a single-row menu.
    ///
    /// Multi-select applies when the clicked row is already part of an explicit
    /// multi-item selection (>= 2 IDs in `selectedIDs`).  In that case the
    /// caller should show batch actions labelled with the returned count.
    /// Otherwise it falls through to the normal single-row actions so that
    /// right-clicking an unrelated row, or right-clicking when nothing is
    /// multi-selected, still shows the familiar per-workspace menu.
    ///
    /// - Returns: `(isMulti: true, count: N)` when batch menu is appropriate;
    ///            `(isMulti: false, count: 1)` otherwise.
    nonisolated public static func sidebarContextMenuMode(
        clickedID: WorkspaceID,
        selectedIDs: Set<WorkspaceID>
    ) -> (isMulti: Bool, count: Int) {
        guard selectedIDs.count >= 2, selectedIDs.contains(clickedID) else {
            return (isMulti: false, count: 1)
        }
        return (isMulti: true, count: selectedIDs.count)
    }

    public func pinSelectedWorkspaces(_ pinned: Bool) {
        let ids = selectedWorkspaceIDs
        guard !ids.isEmpty else { return }
        for id in ids {
            try? router?.setWorkspacePinned(id, pinned)
        }
        reload()
    }

    public func removeSelectedWorkspaces() {
        let ids = selectedWorkspaceIDs
        guard !ids.isEmpty else { return }
        let names = workspaces.filter { ids.contains($0.id) }.map(\.name)
        // :95 -- Route through workspacePrompter so tests can drive the decision.
        // The AppKitWorkspacePrompter default preserves the :15 sheet/runModal fallback.
        guard let prompter = workspacePrompter else { return }
        prompter.confirmRemoveMany(count: ids.count, names: names) { [weak self] decision in
            guard let self, decision == .confirmed else { return }
            do {
                try self.router?.closeWorkspaces(Array(ids))
            } catch {
                self.showOperationError("Could not remove workspaces", detail: error.localizedDescription)
                return
            }
            self.selectedWorkspaceIDs.removeAll()
            self.selectionAnchorID = nil
            self.reload()
        }
    }

    // MARK: Error surfacing

    public static func defaultOperationErrorPresenter(message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        // :15 -- Sheet so other windows are not blocked by error presentation.
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func showOperationError(_ message: String, detail: String) {
        operationErrorPresenter(message, detail)
    }

    // MARK: Keyboard navigation

    /// Moves the selected workspace up or down by `delta` within `filteredWorkspaces`.
    public func moveSelection(by delta: Int) {
        let rows = filteredWorkspaces
        guard !rows.isEmpty else { return }
        let currentIndex = rows.firstIndex(where: { $0.id == selectedWorkspaceID }) ?? -1
        let next = max(0, min(rows.count - 1, currentIndex + delta))
        select(rows[next].id)
    }

    /// Opens the currently-selected workspace (no-op if none selected).
    public func openSelectedWorkspace() {
        guard let wid = selectedWorkspaceID else { return }
        select(wid)
    }

    /// Removes the currently-selected workspace after confirmation.
    public func removeSelectedWorkspace() {
        guard let wid = selectedWorkspaceID,
              let ws = workspaces.first(where: { $0.id == wid }) else { return }
        removeWorkspace(ws)
    }

    /// True when there is at least one removed workspace that can be undone.
    public var canUndoRemoveWorkspace: Bool {
        !removedWorkspaceStack.isEmpty
    }

    /// Recreates the most-recently-removed workspace (session-local undo).
    /// No-op when the stack is empty.
    public func undoRemoveWorkspace() {
        guard let (entry, remaining) = WorkspaceUndoStack.pop(from: removedWorkspaceStack) else { return }
        removedWorkspaceStack = remaining
        do {
            let restored = try router?.createWorkspace(name: entry.name, cwd: entry.cwd)
            if let id = restored?.id {
                if entry.metadata["pinned"] == "true" {
                    try? router?.setWorkspacePinned(id, true)
                }
                if let color = entry.metadata["color"], !color.isEmpty {
                    try? router?.setWorkspaceColor(id, color)
                }
                if let desc = entry.metadata["description"], !desc.isEmpty {
                    try? router?.setWorkspaceDescription(id, desc)
                }
            }
            reload()
        } catch {
            showOperationError("Could not restore workspace", detail: error.localizedDescription)
        }
    }
}

// MARK: - Workspace undo stack (pure; no AppKit/SwiftUI imports required for tests)

/// A snapshot of a workspace captured just before removal, enabling session-local undo.
public struct WorkspaceUndoEntry: Equatable, Sendable {
    public let name: String
    public let cwd: String
    public let metadata: [String: String]

    public init(name: String, cwd: String, metadata: [String: String]) {
        self.name = name
        self.cwd = cwd
        self.metadata = metadata
    }
}

/// Pure stack helpers for the removed-workspace undo feature.
/// Operates on a plain `[WorkspaceUndoEntry]` array; callers own the storage.
public enum WorkspaceUndoStack {
    /// Push a new entry onto the stack (newest at end).
    /// Returns the updated stack; entries beyond `maxDepth` are dropped from the front.
    public static func push(
        _ entry: WorkspaceUndoEntry,
        onto stack: [WorkspaceUndoEntry],
        maxDepth: Int = 10
    ) -> [WorkspaceUndoEntry] {
        var next = stack
        next.append(entry)
        if next.count > maxDepth {
            next.removeFirst(next.count - maxDepth)
        }
        return next
    }

    /// Pop the most-recently-removed entry.
    /// Returns `(entry, updatedStack)`, or `nil` when the stack is empty.
    public static func pop(
        from stack: [WorkspaceUndoEntry]
    ) -> (entry: WorkspaceUndoEntry, remaining: [WorkspaceUndoEntry])? {
        guard !stack.isEmpty else { return nil }
        var next = stack
        let entry = next.removeLast()
        return (entry, next)
    }
}

// MARK: - Selection highlight color resolver (pure; no AppKit/SwiftUI imports required for tests)

/// Describes how the sidebar should color a row's selection highlight.
public enum SidebarHighlightTone: Equatable {
    /// Use the workspace's own color (hex swatch, e.g. 0x7CC7FF).
    case workspaceColor(UInt32)
    /// Fall back to the generic selection tint (no workspace color).
    case selection
    /// Multi-select checkmark tint.
    case accent
    /// Unselected — no highlight.
    case none
}

/// Pure, nonisolated resolver: maps row state -> `SidebarHighlightTone`.
///
/// Priority: checked (multi-select) > workspace color when selected > generic selection > none.
public struct SidebarSelectionHighlightResolver {
    public init() {}

    /// - Parameters:
    ///   - colorKey: the workspace's "color" metadata value (empty / nil = no color).
    ///   - isSelected: whether this row is the primary selected workspace.
    ///   - isChecked: whether this row is part of a multi-selection.
    public func resolve(colorKey: String?, isSelected: Bool, isChecked: Bool) -> SidebarHighlightTone {
        if isChecked { return .accent }
        guard isSelected else { return .none }
        if let hex = TabColor.from(colorKey)?.hex {
            return .workspaceColor(hex)
        }
        return .selection
    }

    /// Convenience: build from a `Workspace` and the current selection state.
    public func resolve(workspace: Workspace, isSelected: Bool, isChecked: Bool) -> SidebarHighlightTone {
        resolve(colorKey: workspace.metadata["color"], isSelected: isSelected, isChecked: isChecked)
    }
}

// MARK: - Keyboard intent model (pure; no AppKit/SwiftUI import required for tests)

/// The action the sidebar should perform in response to a key event.
public enum SidebarAction: Equatable {
    case moveUp
    case moveDown
    case openSelected
    case removeSelected
    case focusFilter
    case clearFilter
}

/// Input descriptor for `SidebarKeyIntentMapper`.
/// Uses plain Swift types so the mapper and its tests need no UI imports.
public struct SidebarKeyInput: Equatable {
    public let character: Character
    public let commandDown: Bool
    public let optionDown: Bool
    public let shiftDown: Bool

    public init(character: Character, commandDown: Bool = false, optionDown: Bool = false, shiftDown: Bool = false) {
        self.character = character
        self.commandDown = commandDown
        self.optionDown = optionDown
        self.shiftDown = shiftDown
    }
}

/// Pure, nonisolated mapper from a key input to a `SidebarAction`.
/// Bindings:
///   ↑ / ↓          → moveUp / moveDown
///   Return (↩)     → openSelected
///   Cmd+Delete (⌫) → removeSelected
///   Cmd+F          → focusFilter
///   Escape         → clearFilter
public struct SidebarKeyIntentMapper {
    private static let upCharacter: Character = Character(UnicodeScalar(NSUpArrowFunctionKey)!)
    private static let downCharacter: Character = Character(UnicodeScalar(NSDownArrowFunctionKey)!)
    private static let returnCharacter: Character = "\r"
    private static let deleteCharacter: Character = Character(UnicodeScalar(NSDeleteFunctionKey)!)
    private static let backspaceCharacter: Character = "\u{7F}"
    private static let escapeCharacter: Character = "\u{1B}"

    public init() {}

    public func action(for input: SidebarKeyInput) -> SidebarAction? {
        switch (input.character, input.commandDown, input.optionDown, input.shiftDown) {
        case (Self.upCharacter, false, false, false):
            return .moveUp
        case (Self.downCharacter, false, false, false):
            return .moveDown
        case (Self.returnCharacter, false, false, false):
            return .openSelected
        case (Self.deleteCharacter, true, false, false),
             (Self.backspaceCharacter, true, false, false):
            return .removeSelected
        case ("f", true, false, false):
            return .focusFilter
        case (Self.escapeCharacter, false, false, false):
            return .clearFilter
        default:
            return nil
        }
    }
}

// MARK: - Token Saver breakdown formatter (pure; no UI imports required)

/// One display row in the Token Saver savings breakdown.
public struct TokenSaverBreakdownRow: Equatable, Sendable {
    /// Human-readable mode label (e.g. "command-output", "prompt", "sr1").
    public let mode: String
    /// All-time tokens saved for this mode across all providers.
    public let savedTokens: Int
    /// Number of compressed runs for this mode.
    public let runs: Int

    public init(mode: String, savedTokens: Int, runs: Int) {
        self.mode = mode
        self.savedTokens = savedTokens
        self.runs = runs
    }
}

/// Pure formatter: `TokenSaverSavingsSummary` -> `[TokenSaverBreakdownRow]`.
///
/// Aggregates the per-(provider, mode) rows into per-mode totals (collapsing
/// across providers), then sorts descending by savedTokens so the most
/// impactful modes appear first. Prefer `windowed: true` for Today/Week so the
/// technique mix matches the ring's retained event window; all-time uses
/// permanent totals.
public struct TokenSaverBreakdownFormatter {
    public init() {}

    /// Returns one `TokenSaverBreakdownRow` per distinct mode, sorted descending
    /// by `savedTokens`. Modes with zero saved tokens are included so the UI can
    /// show them as inactive rather than absent.
    ///
    /// When `windowed` is nil (default), prefer retained-window technique mix when
    /// present so Today/Week match the ring; otherwise fall back to all-time modes.
    public func rows(from summary: TokenSaverSavingsSummary, windowed: Bool? = nil) -> [TokenSaverBreakdownRow] {
        let useWindow = windowed ?? !summary.windowByMode.isEmpty
        let source = useWindow ? summary.windowByMode : summary.modes
        var byMode: [String: (saved: Int, runs: Int)] = [:]
        for m in source {
            let existing = byMode[m.mode] ?? (0, 0)
            byMode[m.mode] = (existing.saved + m.savedTokens, existing.runs + m.runs)
        }
        return byMode
            .map { mode, totals in TokenSaverBreakdownRow(mode: mode, savedTokens: totals.saved, runs: totals.runs) }
            .sorted { $0.savedTokens > $1.savedTokens }
    }
}

public enum TokenSaverSavingsDisplay {
    public static let managedProviderIDs: Set<String> = ["claude", "codex", "grok"]

    public static func otherSavingsRow(
        from summary: TokenSaverSavingsSummary,
        subscribed: Bool,
        enabled: Bool
    ) -> (savedTokens: Int, runs: Int)? {
        guard subscribed && enabled else { return nil }
        let savedTokens = summary.savedTokens(forProvidersOtherThan: managedProviderIDs)
        guard savedTokens > 0 else { return nil }
        return (
            savedTokens: savedTokens,
            runs: summary.runs(forProvidersOtherThan: managedProviderIDs)
        )
    }
}

public struct SidebarRootView: View {
    private enum TokenSaverUsageScope: String, CaseIterable {
        case currentSession
        case week
    }

    @ObservedObject var vm: SidebarViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsInsomniaOptions = false
    @State private var showsTokenSaverDetails = false
    @State private var tokenSaverNow = Date()
    @AppStorage("sidebar.tokenSaver.detailsScope") private var tokenSaverDetailsScopeRaw: String = TokenSaverUsageScope.week.rawValue
    private var tokenSaverDetailsScope: TokenSaverUsageScope {
        TokenSaverUsageScope(rawValue: tokenSaverDetailsScopeRaw) ?? .week
    }
    private var tokenSaverDetailsScopeBinding: Binding<TokenSaverUsageScope> {
        Binding(
            get: { TokenSaverUsageScope(rawValue: tokenSaverDetailsScopeRaw) ?? .week },
            set: { tokenSaverDetailsScopeRaw = $0.rawValue }
        )
    }
    /// Toggled to true to programmatically focus the filter field (Cmd+F).
    @State private var filterFocusRequest: Bool = false
    /// :18 -- Timer fires at ~16 Hz while vm.dragScrollEdge != 0 to scroll toward
    /// the top or bottom of the workspace list. Stored so we can invalidate it
    /// when the drag leaves the edge zone or the drop completes.
    @State private var dragScrollTimer: Timer? = nil
    /// PERF-MAC_SIDEBAR-:101 -- Cache the disk-loaded details snapshot so the
    /// fallback `TokenSaverUsageStore.load()` call runs at most once per
    /// `vm.tokenSaverUsageSnapshot` change, not on every SwiftUI body pass.
    /// `_detailsSnapshotCacheKey` stores the published snapshot that was current
    /// when `_detailsSnapshotCache` was populated; a referential inequality check
    /// (Equatable) invalidates the cache when the store signals new data.
    @State private var _detailsSnapshotCache: TokenSaverUsageSnapshot? = nil
    @State private var _detailsSnapshotCacheKey: TokenSaverUsageSnapshot? = nil
    private let onOpenSettings: () -> Void
    private let onOpenAccount: () -> Void
    private let onOpenScheduledTasks: () -> Void
    private let keyMapper = SidebarKeyIntentMapper()

    public init(
        vm: SidebarViewModel,
        onOpenSettings: @escaping () -> Void = {},
        onOpenAccount: @escaping () -> Void = {},
        onOpenScheduledTasks: @escaping () -> Void = {}
    ) {
        self.vm = vm
        self.onOpenSettings = onOpenSettings
        self.onOpenAccount = onOpenAccount
        self.onOpenScheduledTasks = onOpenScheduledTasks
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Spacer(minLength: 0)
                if vm.privateAccountUser != nil {
                    Button(action: onOpenAccount) {
                        headerAccountAvatar
                            .frame(width: 28, height: 32)
                            .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(accountSubtitle)
                .accessibilityLabel("Account")
                .accessibilityValue(accountSubtitle)
            }

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(DS.Palette.textSecondary)
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")

                Button { vm.toggleSidebar() } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(DS.Palette.textSecondary)
                        .frame(width: 28, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Toggle sidebar")
                .accessibilityLabel("Toggle sidebar")
                .accessibilityIdentifier("shell.toggleSidebar")
            }
            .padding(.horizontal, DS.Space.md)
            .frame(height: 44)

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Button { vm.newWorkspace() } label: {
                    sidebarActionRow(symbol: "folder.badge.plus", title: "New Workspace")
                }
                .buttonStyle(.plain)
                .help("Create new workspace")
                .accessibilityIdentifier("sidebar.newWorkspace")

                Button(action: onOpenScheduledTasks) {
                    sidebarActionRow(
                        symbol: "calendar.badge.clock",
                        title: "Schedule Tasks",
                        isSelected: vm.isScheduledTasksSelected
                    )
                }
                .buttonStyle(.plain)
                .help("Create and manage scheduled Agent tasks")
                .accessibilityIdentifier("sidebar.scheduleTasks")
                .accessibilityAddTraits(vm.isScheduledTasksSelected ? .isSelected : [])

                Button(action: reportBug) {
                    sidebarActionRow(symbol: "ladybug", title: "Report Bug")
                }
                .buttonStyle(.plain)
                .help("Report a bug via email")
                .accessibilityIdentifier("sidebar.reportBug")

                if vm.showsUpdateControl {
                    Button { vm.checkForUpdates() } label: {
                        sidebarActionRow(
                            symbol: "arrow.down.circle",
                            title: vm.updateActionTitle,
                            isEmphasized: vm.updateActionHighlighted
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!vm.updateActionEnabled)
                    .help(updateHelpText)
                }
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.bottom, DS.Space.lg)

            HStack(spacing: DS.Space.sm) {
                Text("Workspaces")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                Spacer(minLength: 0)
                if !vm.selectedWorkspaceIDs.isEmpty {
                    Button("Remove") { vm.removeSelectedWorkspaces() }
                        .buttonStyle(.plain)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.danger)
                        .accessibilityIdentifier("sidebar.removeSelected")
                }
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.bottom, DS.Space.sm)

            // IMP-MAC_SHELL_WINDOW-009: keep the filter available whenever
            // there are workspaces, but do not auto-focus it on sidebar load.
            if !vm.workspaces.isEmpty {
                workspaceFilterField
                    .padding(.horizontal, DS.Space.md)
                    .padding(.bottom, DS.Space.sm)
            }

            // :18 -- ScrollViewReader exposes a proxy so the edge-scroll timer
            // can call scrollTo(first/last) while the user holds a drag near
            // the top or bottom edge of the list.
            ScrollViewReader { scrollProxy in
                ScrollView {
                    let rows = vm.filteredWorkspaces
                    LazyVStack(alignment: .leading, spacing: DS.Space.xxs) {
                        if vm.workspaces.isEmpty {
                            Text("No workspaces")
                                .font(DS.Font.body)
                                .foregroundColor(DS.Palette.textTertiary)
                                .padding(.horizontal, DS.Space.md)
                                .padding(.vertical, DS.Space.sm)
                        } else if rows.isEmpty {
                            Text("No matches")
                                .font(DS.Font.body)
                                .foregroundColor(DS.Palette.textTertiary)
                                .padding(.horizontal, DS.Space.md)
                                .padding(.vertical, DS.Space.sm)
                        } else {
                            let separatorIdx = SidebarViewModel.pinnedSeparatorIndex(in: rows)
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, ws in
                                if index == separatorIdx {
                                    pinnedGroupDivider
                                }
                                workspaceRow(ws)
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.sm)
                }
                .frame(maxHeight: .infinity)
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(phases: .down) { press in
                    handleKeyPress(press)
                }
                // :18 -- Start/stop the edge-scroll timer whenever the drag
                // edge direction changes. The timer fires at ~16 Hz and scrolls
                // one step toward the edge until the pointer leaves the zone.
                .onChange(of: vm.dragScrollEdge) { edge in
                    dragScrollTimer?.invalidate()
                    dragScrollTimer = nil
                    guard edge != 0 else { return }
                    dragScrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 16.0, repeats: true) { _ in
                        let rows = vm.filteredWorkspaces
                        guard !rows.isEmpty else { return }
                        if edge < 0, let first = rows.first {
                            scrollProxy.scrollTo(first.id, anchor: .top)
                        } else if edge > 0, let last = rows.last {
                            scrollProxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            accountFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Subtle liquid-glass: a near-transparent tint over the
        // NSVisualEffectView the host sits in (see SidebarView).
        .background(DS.Palette.surface.opacity(0.28))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.045))
                .frame(width: DS.Border.hairline)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            vm.createWorkspaces(fromDroppedProviders: providers)
        }
        // The sidebar material reaches the top edge; only its controls
        // start below the traffic-light band.
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $vm.showsTokenSaverModelDownload) {
            TokenSaverModelDownloadModal(
                state: vm.tokenSaverModelDownloadState,
                aggregatedDownloadedBytes: vm.tokenSaverAggregatedDownloadedBytes,
                aggregatedTotalBytes: vm.tokenSaverAggregatedTotalBytes,
                downloadBytesPerSec: vm.tokenSaverDownloadBytesPerSec,
                onCancel: { vm.cancelTokenSaverModelDownload() },
                onResume: { vm.resumeTokenSaverModelDownload() },
                onRetry: { vm.retryTokenSaverModelDownload() }
            )
        }
        .task {
            await tokenSaverDailyRolloverClock()
        }
    }

    @MainActor
    private func tokenSaverDailyRolloverClock() async {
        tokenSaverNow = Date()
        while !Task.isCancelled {
            let resetDate = Self.tokenSaverNextDailyResetDate(after: Date())
            let delay = max(resetDate.timeIntervalSinceNow, 0.1)
            let nanoseconds = UInt64(min(delay, 86_500) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { break }
            tokenSaverNow = Date()
        }
    }

    // MARK: Keyboard handling

    @discardableResult
    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        let modifiers = press.modifiers
        let input = SidebarKeyInput(
            character: press.key.character,
            commandDown: modifiers.contains(.command),
            optionDown: modifiers.contains(.option),
            shiftDown: modifiers.contains(.shift)
        )
        guard let action = keyMapper.action(for: input) else { return .ignored }
        switch action {
        case .moveUp:
            vm.moveSelection(by: -1)
        case .moveDown:
            vm.moveSelection(by: 1)
        case .openSelected:
            vm.openSelectedWorkspace()
        case .removeSelected:
            vm.removeSelectedWorkspace()
        case .focusFilter:
            filterFocusRequest = true
        case .clearFilter:
            vm.filterText = ""
        }
        return .handled
    }

    /// Opens the system mail client to report a bug to the maintainer.
    private func reportBug() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "samuelfajreldines@gmail.com"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "RemoteCode Bug Report")
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    private var workspaceFilterField: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(DS.Palette.textTertiary)
            NonAutoFocusTextField(
                placeholder: "Filter workspaces",
                text: $vm.filterText,
                focusRequest: $filterFocusRequest,
                accessibilityIdentifier: "sidebar.workspaceFilter"
            )
            .font(DS.Font.body)
            .foregroundColor(DS.Palette.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            if !vm.filterText.isEmpty {
                Button { vm.filterText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(DS.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, DS.Space.sm)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(DS.Palette.surfaceRaised.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Palette.lineStrong.opacity(0.5), lineWidth: DS.Border.hairline)
                )
        )
    }

    private func sidebarActionRow(
        symbol: String,
        title: String,
        isEmphasized: Bool = false,
        isSelected: Bool = false
    ) -> some View {
        let highlight = isEmphasized || isSelected
        return HStack(spacing: DS.Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: highlight ? .semibold : .regular))
                .frame(width: 20, height: 20)
                .foregroundColor(isEmphasized ? DS.Palette.warning : (isSelected ? DS.Palette.accent : DS.Palette.text))
            Text(title)
                .font(DS.Font.body)
                .fontWeight(highlight ? .semibold : .regular)
                .foregroundColor(isEmphasized ? DS.Palette.warning : (isSelected ? DS.Palette.text : DS.Palette.text))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.sm)
        .frame(height: 42)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(
                    isEmphasized
                        ? DS.Palette.warning.opacity(0.16)
                        : (isSelected ? DS.Palette.selection : Color.white.opacity(0.001))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(isEmphasized ? DS.Palette.warning.opacity(0.55) : Color.clear,
                              lineWidth: DS.Border.hairline)
        )
    }

    private var updateHelpText: String {
        switch vm.updateAvailability {
        case .available:
            return "Install the available RemoteCode update"
        case .checking:
            return "Checking for RemoteCode updates"
        case .upToDate:
            return "Check again for RemoteCode updates"
        case .failed(let message):
            return message
        case .unknown:
            return "Check for RemoteCode updates"
        }
    }

    private var accountFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(DS.Palette.line.opacity(0.55))
                .frame(height: DS.Border.hairline)

            if vm.privateAccountUser == nil {
                Button(action: onOpenAccount) {
                    HStack(spacing: DS.Space.md) {
                        accountAvatar
                        VStack(alignment: .leading, spacing: 1) {
                            Text(accountDisplayName)
                                .font(DS.Font.bodyStrong)
                                .foregroundColor(DS.Palette.text)
                                .lineLimit(1)
                            Text(accountSubtitle)
                                .font(DS.Font.caption2)
                                .foregroundColor(DS.Palette.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Palette.textTertiary)
                            .frame(width: 24, height: 24)
                    }
                    .padding(.horizontal, DS.Space.sm)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .fill(Color.white.opacity(0.001))
                    )
                }
                .buttonStyle(.plain)
                .help("Sign in")
                .padding(.horizontal, DS.Space.md)
                .padding(.top, DS.Space.md)

                Rectangle()
                    .fill(Color.white.opacity(0.09))
                    .frame(height: DS.Border.hairline)
                    .padding(.horizontal, DS.Space.md)
                    .padding(.vertical, DS.Space.sm)
            }

            footerUtilityControls
        }
        .background(Color.white.opacity(0.025))
    }

    private var footerUtilityControls: some View {
        Group {
            if tokenSaverShowsCompactFooterControl {
                HStack(alignment: .center, spacing: DS.Space.sm) {
                    insomniaControl
                        .frame(maxWidth: .infinity, alignment: .leading)

                    tokenSaverCompactControl
                }
                .padding(.horizontal, DS.Space.md)
                .padding(.top, DS.Space.md)
                .padding(.bottom, DS.Space.lg)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    tokenSaverControl
                        .padding(.horizontal, DS.Space.md)
                        .padding(.top, vm.privateAccountUser == nil ? 0 : DS.Space.md)

                    insomniaControl
                        .padding(.horizontal, DS.Space.md)
                        .padding(.top, DS.Space.sm)
                        .padding(.bottom, DS.Space.lg)
                }
            }
        }
    }

    private var tokenSaverControl: some View {
        // :186 -- compute model dir size once for this render pass.
        // Only evaluated when !tokenSaverEnabled so the hot (enabled) path
        // pays zero cost.
        let modelDirURL: URL? = {
            guard !vm.tokenSaverEnabled, let ctx = vm.context else { return nil }
            return TokenSaverModelInstaller(appSupportDirectory: ctx.appSupportDirectory).distillDirectory
        }()
        let modelDirBytes: Int64 = modelDirURL.map { Self.modelDirSize(at: $0) } ?? 0
        let showDeleteModel = !vm.tokenSaverEnabled && modelDirBytes > 0

        return VStack(alignment: .leading, spacing: DS.Space.xs) {
        Button {
            tokenSaverAction()
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Palette.success)
                        .frame(width: 18, height: 18)
                    Text("Token Saver")
                        .font(DS.Font.bodyStrong)
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(tokenSaverPillText)
                        .font(DS.Font.captionStrong)
                        .foregroundColor(tokenSaverPillForeground)
                        .padding(.horizontal, DS.Space.sm)
                        .frame(minHeight: 20)
                        .background(
                            Capsule()
                                .fill(tokenSaverPillBackground)
                        )
                }

                Text(tokenSaverHeadline)
                    .font(DS.Font.monoStrong)
                    .foregroundColor(DS.Palette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .monospacedDigit()

                Text(tokenSaverSubtitle)
                    .font(DS.Font.caption2)
                    .foregroundColor(tokenSaverSubtitleForeground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, DS.Space.md)
            .frame(minHeight: 70, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(tokenSaverPanelBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                            .stroke(DS.Palette.success.opacity(vm.tokenSaverEnabled ? 0.42 : 0.18),
                                    lineWidth: DS.Border.hairline)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(tokenSaverHelpText)
        .popover(isPresented: $showsTokenSaverDetails, arrowEdge: .trailing) {
            tokenSaverDetailsPopover
        }
        .accessibilityLabel("Token Saver")
        .accessibilityValue(tokenSaverAccessibilityValue)
        .accessibilityHint(tokenSaverHelpText)
        .accessibilityIdentifier("sidebar.tokenSaver")

        // :186 -- "Delete model (N GB)" affordance when disabled + model installed.
        // Guard: only shown when disabled so there is no risk of deleting a
        // live/downloading model.  The distillDirectory is removed atomically
        // so partial states (manifest + cache + model files) are all cleared.
        if showDeleteModel {
            Button {
                deleteTokenSaverModel()
            } label: {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(DS.Palette.danger)
                    Text("Delete model (\(Self.humanDirSizeString(modelDirBytes)))")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.danger)
                        .lineLimit(1)
                }
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, DS.Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete Token Saver model")
            .accessibilityValue("Model size \(Self.humanDirSizeString(modelDirBytes))")
            .accessibilityHint("Removes the downloaded model files to reclaim disk space")
            .accessibilityIdentifier("sidebar.tokenSaver.deleteModel")
        }
        } // end outer VStack
    }

    private var tokenSaverCompactControl: some View {
        let ringVals = tokenSaverActivityRingValues
        // :195 -- build the label outside the label closure so it is
        // available both for the rings and for the button's own a11y value.
        let ringsLabel = tokenSaverRingsAccessibilityLabel(
            for: vm.tokenSaverUsageSnapshot,
            scope: tokenSaverDetailsScope,
            ringVals: ringVals
        )
        return Button {
            toggleTokenSaverDetails(refreshWhenOpening: true)
        } label: {
            TokenSaverActivityRings(values: ringVals, a11yLabel: ringsLabel)
                .frame(width: 34, height: 34)
                .frame(width: 48, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tokenSaverHelpText)
        .popover(isPresented: $showsTokenSaverDetails, arrowEdge: .trailing) {
            tokenSaverDetailsPopover
        }
        .accessibilityLabel("Token Saver")
        .accessibilityValue(tokenSaverActivityAccessibilityValue)
        .accessibilityHint("Open Token Saver details")
        .accessibilityIdentifier("sidebar.tokenSaver.compact")
    }

    private func tokenSaverAction() {
        guard let user = vm.privateAccountUser else {
            onOpenAccount()
            return
        }
        guard user.subscribed else {
            onOpenAccount()
            return
        }
        if vm.tokenSaverEnabled {
            toggleTokenSaverDetails(refreshWhenOpening: true)
            return
        }
        withAnimation(DS.Motion.micro) {
            vm.setTokenSaverEnabled(true)
        }
    }

    private func toggleTokenSaverDetails(refreshWhenOpening: Bool) {
        let willOpen = !showsTokenSaverDetails
        if willOpen && refreshWhenOpening {
            vm.refreshTokenSaverAccountUsageForDetails()
            vm.reloadTokenSaverGovernance()
        }
        showsTokenSaverDetails = willOpen
    }

    // :186 -- Removes the entire Distill directory (model files + manifest +
    // validation cache) after an NSAlert confirmation.
    // Guard: only called from the delete button which is only shown when
    // !tokenSaverEnabled, so we never delete a live or downloading model.
    private func deleteTokenSaverModel() {
        guard !vm.tokenSaverEnabled else { return }
        guard let ctx = vm.context else { return }
        let installer = TokenSaverModelInstaller(appSupportDirectory: ctx.appSupportDirectory)
        let bytes = Self.modelDirSize(at: installer.distillDirectory)
        let sizeStr = Self.humanDirSizeString(bytes)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Token Saver model (\(sizeStr))?"
        alert.informativeText = "This removes the downloaded model files from disk. You can download the model again when you re-enable Token Saver."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.removeItem(at: installer.distillDirectory)
    }

    private var tokenSaverPillText: String {
        guard let user = vm.privateAccountUser else { return "Sign in" }
        guard user.subscribed else { return "Upgrade" }
        return vm.tokenSaverEnabled ? "Details" : "Enable"
    }

    private var tokenSaverHeadline: String {
        guard let user = vm.privateAccountUser else { return "Track Claude + Codex + Grok usage" }
        // Design: original "Estimated save N tokens" copy.
        // Number: scope credible total (Today/Week), not all-time pipes-only.
        let snap = tokenSaverDetailsSnapshot
        let scope = tokenSaverDetailsScope
        let saved = tokenSaverSavedOrPotential(in: snap, scope: scope)
        let used = tokenSaverScopeUsedTokens(in: snap, scope: scope)
        return Self.tokenSaverCardHeadline(
            subscribed: user.subscribed,
            enabled: vm.tokenSaverEnabled,
            sidecarStatus: vm.sidecarStatus,
            savedTokens: saved,
            usedTokens: used
        )
    }

    private var tokenSaverSubtitle: String {
        guard let user = vm.privateAccountUser else { return "Sign in to track account usage" }
        let used = vm.tokenSaverUsageSnapshot.usedTokens
        if user.subscribed {
            return used > 0 ? "Used \(Self.formatTokenCount(used)) in Claude + Codex + Grok" : "Enable local reduction experiments"
        }
        return used > 0 ? "Used \(Self.formatTokenCount(used)) in Claude + Codex + Grok" : "Subscribe to activate local reduction"
    }

    private var tokenSaverHelpText: String {
        "Token Saver shows provider usage and local reduction estimates. Billing claims require joined provider usage evidence."
    }

    private var tokenSaverAccessibilityValue: String {
        "\(tokenSaverPillText), \(tokenSaverHeadline), \(tokenSaverSubtitle)"
    }

    private var tokenSaverPillForeground: Color {
        vm.privateAccountUser?.subscribed == true ? DS.Palette.onAccent : DS.Palette.text
    }

    private var tokenSaverPillBackground: Color {
        vm.privateAccountUser?.subscribed == true ? DS.Palette.success : DS.Palette.surfaceRaised
    }

    private var tokenSaverPanelBackground: Color {
        vm.tokenSaverEnabled ? DS.Palette.success.opacity(0.08) : DS.Palette.surfaceRaised.opacity(0.82)
    }

    private var tokenSaverSubtitleForeground: Color {
        vm.tokenSaverEnabled ? DS.Palette.textSecondary : DS.Palette.textTertiary
    }

    private var tokenSaverShowsCompactFooterControl: Bool {
        vm.privateAccountUser?.subscribed == true && vm.tokenSaverEnabled
    }

    private var tokenSaverActivityRingValues: TokenSaverActivityRings.Values {
        // Follow the persisted Today/Week scope so the compact sidebar ring matches
        // the details popover ring exactly, instead of being pinned to .week.
        tokenSaverActivityRingValues(for: vm.tokenSaverUsageSnapshot, scope: tokenSaverDetailsScope)
    }

    private func tokenSaverActivityRingValues(
        for snapshot: TokenSaverUsageSnapshot,
        scope: TokenSaverUsageScope
    ) -> TokenSaverActivityRings.Values {
        let claude = tokenSaverProviderUsage(.claude, in: snapshot)
        let codex = tokenSaverProviderUsage(.codex, in: snapshot)
        let grok = tokenSaverProviderUsage(.grok, in: snapshot)
        let savingsFraction = tokenSaverSavingsRingFraction(for: snapshot, scope: scope)
        return TokenSaverActivityRings.Values(
            tokenSaverProgress: savingsFraction.progress,
            tokenSaverSavingsRingAvailable: savingsFraction.isComparable,
            claudeUsedProgress: tokenSaverUsedLimitProgress(for: claude, provider: .claude, scope: scope) ?? 0,
            codexUsedProgress: tokenSaverUsedLimitProgress(for: codex, provider: .codex, scope: scope) ?? 0,
            grokUsedProgress: tokenSaverUsedLimitProgress(for: grok, provider: .grok, scope: scope) ?? 0
        )
    }

    /// Managed providers ordered by used-limit progress (desc) for the selected
    /// scope — same order as concentric rings after Token Saver.
    private func tokenSaverProvidersByUsage(
        in snapshot: TokenSaverUsageSnapshot,
        scope: TokenSaverUsageScope
    ) -> [AgentProvider] {
        tokenSaverActivityRingValues(for: snapshot, scope: scope).providersOuterToInner
    }

    private var tokenSaverActivityAccessibilityValue: String {
        let snapshot = vm.tokenSaverUsageSnapshot
        let ringVals = tokenSaverActivityRingValues(for: snapshot, scope: tokenSaverDetailsScope)
        return tokenSaverRingsAccessibilityLabel(
            for: snapshot,
            scope: tokenSaverDetailsScope,
            ringVals: ringVals
        )
    }

    private func tokenSaverRingsAccessibilityLabel(
        for snapshot: TokenSaverUsageSnapshot,
        scope: TokenSaverUsageScope,
        ringVals: TokenSaverActivityRings.Values
    ) -> String {
        let fraction = tokenSaverSavingsRingFraction(for: snapshot, scope: scope)
        return Self.ringsAccessibilityLabel(
            scope: tokenSaverLimitScopeTitle(for: scope),
            savedTokens: tokenSaverSavedOrPotential(in: snapshot, scope: scope),
            savedProgress: ringVals.tokenSaverProgress,
            savedGoalTokens: fraction.mixTokens ?? tokenSaverSavingsGoalTokens(for: scope),
            savingsRingComparable: fraction.isComparable,
            savingsRingUnavailableReason: fraction.unavailableReason,
            claudeUsedProgress: ringVals.claudeUsedProgress,
            codexUsedProgress: ringVals.codexUsedProgress,
            grokUsedProgress: ringVals.grokUsedProgress
        )
    }

    private func tokenSaverLimitScopeTitle(for scope: TokenSaverUsageScope) -> String {
        switch scope {
        // :187 -- "currentSession" bucket sums today's calendar day, not a live
        // session window.  "today" is the honest label for what is shown.
        case .currentSession: return "today"
        case .week: return "week"
        }
    }

    private func tokenSaverScopeTitle(_ scope: TokenSaverUsageScope) -> String {
        switch scope {
        // :187 -- Picker label must match the windowing: today's calendar-day bucket,
        // not a "session" (which implies start-of-process to now).
        case .currentSession: return "Today"
        case .week: return "Week"
        }
    }

    /// Window-aligned provider usage for bare-user estimator inputs only.
    /// Prefer `snapshot.daily` buckets (same retention window as the savings ledger).
    /// Not a green-ring denominator — the green ring uses fixed 5M/35M goals.
    private func tokenSaverScopeUsedTokens(in snapshot: TokenSaverUsageSnapshot, scope: TokenSaverUsageScope) -> Int {
        switch scope {
        case .currentSession:
            return TokenSaverBareUserEstimator.todayProviderTokens(
                daily: snapshot.daily,
                now: tokenSaverNow
            )
        case .week:
            return TokenSaverBareUserEstimator.weekProviderTokens(daily: snapshot.daily)
        }
    }

    private func tokenSaverProviderUsage(
        _ provider: AgentProvider,
        in snapshot: TokenSaverUsageSnapshot
    ) -> TokenSaverProviderUsage {
        snapshot.providers.first { $0.provider == provider } ?? TokenSaverProviderUsage(provider: provider)
    }

    private func tokenSaverSavingsRingFraction(
        for snapshot: TokenSaverUsageSnapshot,
        scope: TokenSaverUsageScope
    ) -> TokenSaverSavingsRingFraction {
        let saved = tokenSaverSavedOrPotential(in: snapshot, scope: scope)
        let isDaily = scope == .currentSession
        return Self.tokenSaverSavingsRingFraction(
            savedTokens: saved,
            goalTokens: Self.tokenSaverSavingsGoalTokens(isDailyScope: isDaily),
            hasComparableUsageWindow: true
        )
    }

    private func tokenSaverSavingsProgress(
        for snapshot: TokenSaverUsageSnapshot,
        scope: TokenSaverUsageScope
    ) -> Double {
        tokenSaverSavingsRingFraction(for: snapshot, scope: scope).progress
    }

    private func tokenSaverSavedOrPotential(
        in snapshot: TokenSaverUsageSnapshot,
        scope: TokenSaverUsageScope
    ) -> Int {
        // WHY: one primary axis — same realized/credible estimator for paid and
        // teaser. Never the retired usage-fraction teaser: that inverted the card
        // so non-payers saw larger headlines than payers. History is not gated
        // on the enable toggle.
        tokenSaverPersistedOrLiveCredible(scope: scope, snapshot: snapshot)
    }

    /// Measured tool-output ledger only (no dialect/graphify/orchestration estimates).
    private func tokenSaverMeasuredSaved(scope: TokenSaverUsageScope) -> Int {
        let summary = vm.tokenSaverSavingsSummary
        switch scope {
        case .week:
            return Self.tokenSaverReportWindowSavedTokens(daily: summary.daily)
        case .currentSession:
            return Self.tokenSaverTodaySavedTokens(daily: summary.daily, now: tokenSaverNow)
        }
    }

    /// Today: today's economy row (or live recompute fallback).
    /// Week: sum of stored daily totals + measured-only for pre-feature days.
    private func tokenSaverPersistedOrLiveCredible(
        scope: TokenSaverUsageScope,
        snapshot: TokenSaverUsageSnapshot
    ) -> Int {
        switch scope {
        case .currentSession:
            if let today = vm.tokenSaverDailyEconomyToday {
                return today.totalCredible
            }
            return tokenSaverBareUserBreakdown(in: snapshot, scope: scope).totalCredible
        case .week:
            // Hybrid sum from load path; if zero (pre-write), fall back to live estimate
            // on the week window so UI is never empty after first day of the feature.
            if vm.tokenSaverDailyEconomyWeekTotal > 0 {
                return vm.tokenSaverDailyEconomyWeekTotal
            }
            return tokenSaverBareUserBreakdown(in: snapshot, scope: scope).totalCredible
        }
    }

    /// Bare-user counterfactual for the selected window (live compute; also used
    /// to **write** today's economy row). Week UI prefers Σ(DB days) when present.
    private func tokenSaverBareUserBreakdown(
        in snapshot: TokenSaverUsageSnapshot,
        scope: TokenSaverUsageScope
    ) -> TokenSaverBareUserBreakdown {
        // Prefer persisted today row for the live estimator path (writes / fallbacks).
        if scope == .currentSession, let today = vm.tokenSaverDailyEconomyToday {
            return TokenSaverBareUserBreakdown(
                measuredToolOutput: today.measuredTokens,
                estimatedDialect: today.dialectTokens,
                estimatedGraphify: today.graphifyTokens,
                estimatedOrchestration: today.orchestrationTokens,
                appliedOutputShare: today.appliedOutputShare,
                usedCalibratedDefaults: true
            )
        }
        return Self.tokenSaverBareUserBreakdown(
            measuredToolOutputSaved: tokenSaverMeasuredSaved(scope: scope),
            windowProviderTokens: tokenSaverScopeUsedTokens(in: snapshot, scope: scope),
            tokenSaverEnabled: vm.tokenSaverEnabled,
            graphifyActive: vm.graphifyRuntimeActive
        )
    }

    /// Pure seam: Day and Week must call the same estimator with window-aligned inputs.
    ///
    /// Graphify credit requires measured `graphifySignalCount` (CLI query|path|explain).
    /// Prefer under-count: never invent signals from preference-on alone.
    nonisolated public static func tokenSaverBareUserBreakdown(
        measuredToolOutputSaved: Int,
        windowProviderTokens: Int,
        tokenSaverEnabled: Bool,
        graphifyActive: Bool,
        graphifySignalCount: Int = 0,
        graphifyAnswerTokens: Int = 0,
        medianExplorationTokens: Int? = nil,
        assistantChars: Int = 0,
        observedOutputTokens: Int? = nil,
        observedInputTokens: Int? = nil,
        observationSampleCount: Int = 0
    ) -> TokenSaverBareUserBreakdown {
        let observation = TokenSaverBareUserObservation(
            windowProviderTokens: windowProviderTokens,
            observedOutputTokens: observedOutputTokens,
            observedInputTokens: observedInputTokens,
            observationSampleCount: observationSampleCount,
            assistantChars: assistantChars,
            graphifySignalCount: graphifyActive ? max(0, graphifySignalCount) : 0,
            graphifyAnswerTokens: graphifyActive ? max(0, graphifyAnswerTokens) : 0,
            medianExplorationTokens: graphifyActive ? medianExplorationTokens : nil
        )
        return TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: measuredToolOutputSaved,
            tokenSaverEnabled: tokenSaverEnabled,
            graphifyActive: graphifyActive,
            orchestrationActive: false,
            observation: observation
        )
    }

    /// Measured saved tokens for one provider in the selected scope, read from the
    /// per-(provider, day) buckets so the row matches the windowed green headline.
    private func tokenSaverScopedProviderSaved(_ provider: AgentProvider) -> Int {
        let summary = vm.tokenSaverSavingsSummary
        switch tokenSaverDetailsScope {
        case .week:
            return Self.tokenSaverWindowSaved(forProvider: provider.rawValue, dailyByProvider: summary.dailyByProvider)
        case .currentSession:
            return Self.tokenSaverTodaySaved(forProvider: provider.rawValue, dailyByProvider: summary.dailyByProvider, now: tokenSaverNow)
        }
    }

    /// Measured + multi-turn cache amort for provider rows (Today uses live amort map;
    /// Week falls back to measured-only until week amort is persisted per day).
    private func tokenSaverScopedProviderEstimatedSave(_ provider: AgentProvider) -> Int {
        let measured = tokenSaverScopedProviderSaved(provider)
        guard tokenSaverDetailsScope == .currentSession else { return measured }
        let amort = vm.tokenSaverProviderCacheAmortToday[provider.rawValue] ?? 0
        return TokenSaverBareUserEstimator.saturatingAdd(measured, amort)
    }

    /// Fixed green-ring goal for the selected scope (5M today / 35M week).
    private func tokenSaverSavingsGoalTokens(for scope: TokenSaverUsageScope) -> Int {
        Self.tokenSaverSavingsGoalTokens(isDailyScope: scope == .currentSession)
    }

    private func tokenSaverSavingsSummary(
        for snapshot: TokenSaverUsageSnapshot,
        scope: TokenSaverUsageScope
    ) -> String {
        // Design: original "Estimated save N" legend. Number is scope credible total.
        // Labels only: same primary figure for paid and teaser (no separate heuristic).
        let prefix = vm.privateAccountUser?.subscribed == true && vm.tokenSaverEnabled
            ? "Estimated save"
            : "Estimated potential"
        return "\(prefix) \(Self.formatTokenCount(tokenSaverSavedOrPotential(in: snapshot, scope: scope)))"
    }

    private func tokenSaverUsedLimitProgress(
        for usage: TokenSaverProviderUsage,
        provider: AgentProvider,
        scope: TokenSaverUsageScope
    ) -> Double? {
        switch scope {
        case .currentSession:
            // Prefer a live session %; bare 0 without an unexpired window is
            // treated as missing (probe miss / clear) so Today does not stick at 0%.
            if let currentSessionUsedPercent = usage.effectiveSessionUsedPercent() {
                return min(max(currentSessionUsedPercent / 100.0, 0), 1)
            }
            // Fall back to the weekly rate-limit % when session data is absent —
            // that is still honest provider usage, and matches what users check.
            if let weeklyUsedPercent = usage.effectiveWeeklyUsedPercent() {
                return min(max(weeklyUsedPercent / 100.0, 0), 1)
            }
            guard usage.currentSessionLimitTokens > 0 else { return nil }
            return tokenSaverRingProgress(
                numerator: usage.currentSessionTokens,
                denominator: usage.currentSessionLimitTokens
            )
        case .week:
            // Prefer effective % so an expired weekly window (or a zeroed
            // inactive-provider clear) does not keep painting a stale ring.
            if let weeklyUsedPercent = usage.effectiveWeeklyUsedPercent() {
                return min(max(weeklyUsedPercent / 100.0, 0), 1)
            }
        }
        guard usage.actualProviderTokens > 0 else { return nil }
        let denominator = max(usage.estimatedRawTokens, tokenSaverDefaultWeeklyLimitTokens(for: provider), 1)
        return tokenSaverRingProgress(numerator: usage.actualProviderTokens, denominator: denominator)
    }

    private func tokenSaverUsedLimitText(
        for usage: TokenSaverProviderUsage,
        provider: AgentProvider,
        scope: TokenSaverUsageScope
    ) -> String {
        tokenSaverUsedLimitProgress(
            for: usage,
            provider: provider,
            scope: scope
        ).map(Self.formatPercent) ?? "No data"
    }

    private func tokenSaverProviderUsageCaption(
        for usage: TokenSaverProviderUsage,
        provider: AgentProvider,
        scope: TokenSaverUsageScope
    ) -> String {
        switch scope {
        case .currentSession:
            // Pure seam owns the session/weekly-fallback wording so tests can
            // lock the explained fallback without rendering SwiftUI.
            return Self.tokenSaverCurrentSessionUsageCaption(
                effectiveSessionUsedPercent: usage.effectiveSessionUsedPercent(),
                effectiveWeeklyUsedPercent: usage.effectiveWeeklyUsedPercent(),
                currentSessionTokens: usage.currentSessionTokens,
                currentSessionLimitTokens: usage.currentSessionLimitTokens
            )
        case .week:
            if let weeklyUsedPercent = usage.effectiveWeeklyUsedPercent() {
                return "Weekly used \(Self.formatPercent(weeklyUsedPercent / 100.0))"
            }
            let weeklyLimit = max(usage.estimatedRawTokens, tokenSaverDefaultWeeklyLimitTokens(for: provider), 1)
            guard usage.actualProviderTokens > 0 else { return "Weekly usage not loaded" }
            return "Weekly used \(Self.formatTokenCount(usage.actualProviderTokens)) / \(Self.formatTokenCount(weeklyLimit))"
        }
    }

    /// Pure seam: Today-scope usage caption, including the explained weekly
    /// fallback when session probe data is missing/bare-zero.
    ///
    /// WHY: Claude often has a live session % while Codex/Grok fall back to
    /// weekly; without "(no session data)" that mix reads as a UI glitch.
    nonisolated public static func tokenSaverCurrentSessionUsageCaption(
        effectiveSessionUsedPercent: Double?,
        effectiveWeeklyUsedPercent: Double?,
        currentSessionTokens: Int = 0,
        currentSessionLimitTokens: Int = 0
    ) -> String {
        if let currentSessionUsedPercent = effectiveSessionUsedPercent {
            return "Session used \(formatPercent(currentSessionUsedPercent / 100.0))"
        }
        // When session probe is missing/bare-zero, surface weekly % under an
        // explained label instead of painting "Session used 0%" or a bare
        // "Week used X%" that looks inconsistent next to session captions.
        if let weeklyUsedPercent = effectiveWeeklyUsedPercent {
            return "Week used \(formatPercent(weeklyUsedPercent / 100.0)) (no session data)"
        }
        guard currentSessionLimitTokens > 0 else { return "Session usage not loaded" }
        let usedProgress: Double = {
            guard currentSessionTokens > 0, currentSessionLimitTokens > 0 else { return 0 }
            return min(max(Double(currentSessionTokens) / Double(currentSessionLimitTokens), 0), 1)
        }()
        return "Session used \(formatPercent(usedProgress))"
    }

    /// Static per-provider capability copy for automatic tool-output compression.
    ///
    /// Snapshot of today's real support only — not derived from savings math.
    /// TODO: replace this fixed mapping with a real capability flag (adapter /
    /// provider matrix) when one is wired through the runtime; do not invent
    /// integration with in-flight work.
    nonisolated public static func tokenSaverProviderCompressionCapabilityLine(
        for provider: AgentProvider
    ) -> String {
        switch provider {
        case .claude:
            // Claude: PostToolUse rewrite + PATH wrappers + | distill.
            return "Compresses tool output via hooks and shell wrappers"
        case .codex:
            // Codex: no upstream updatedToolOutput; PATH wrappers + | distill only.
            return "Compresses shell tool output via wrappers and | distill"
        case .grok:
            // Grok: PostToolUse is passive; PATH wrappers + | distill only.
            return "Compresses shell tool output via wrappers and | distill"
        }
    }

    private func tokenSaverDefaultWeeklyLimitTokens(for provider: AgentProvider) -> Int {
        switch provider {
        case .claude, .codex, .grok:
            return 1_000_000
        }
    }

    private func tokenSaverRingProgress(numerator: Int, denominator: Int) -> Double {
        guard numerator > 0, denominator > 0 else { return 0 }
        return min(max(Double(numerator) / Double(denominator), 0), 1)
    }

    private var tokenSaverDetailsPopover: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(alignment: .center, spacing: DS.Space.sm) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Palette.success)
                    .frame(width: 22, height: 22)
                Text("Token Saver")
                    .font(DS.Font.bodyStrong)
                    .foregroundColor(DS.Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(
                    get: { vm.tokenSaverEnabled },
                    set: { enabled in
                        guard vm.privateAccountUser?.subscribed == true else {
                            onOpenAccount()
                            return
                        }
                        vm.setTokenSaverEnabled(enabled)
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Token Saver")
                .accessibilityIdentifier("sidebar.tokenSaver.toggle")
            }

            // :188 -- Last-updated timestamp + in-flight spinner for the
            // account-usage refresh (CLI probe takes ~40s).
            HStack(spacing: DS.Space.xs) {
                if vm.tokenSaverAccountUsageIsRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.75)
                        .frame(width: 12, height: 12)
                        .accessibilityLabel("Refreshing usage data")
                        .accessibilityIdentifier("sidebar.tokenSaver.usageRefreshSpinner")
                }
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    Text(Self.accountUsageLastUpdatedLabel(
                        vm.tokenSaverAccountUsageLastUpdated,
                        now: timeline.date
                    ))
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                }
                .accessibilityIdentifier("sidebar.tokenSaver.lastUpdated")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            if let label = Self.sidecarStatusLabel(vm.sidecarStatus) {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Palette.warning)
                    Text(label)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.warning)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, DS.Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .fill(DS.Palette.warning.opacity(0.10))
                )
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("sidebar.tokenSaver.sidecarStatus")
            }

            Picker("Usage scope", selection: tokenSaverDetailsScopeBinding) {
                ForEach(TokenSaverUsageScope.allCases, id: \.self) { scope in
                    Text(tokenSaverScopeTitle(scope)).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("sidebar.tokenSaver.period")

            tokenSaverDetailsActivityChart

            Divider()

            VStack(alignment: .leading, spacing: DS.Space.sm) {
                // Same usage-desc order as the concentric rings (after Token Saver).
                ForEach(tokenSaverProvidersByUsage(in: tokenSaverDetailsSnapshot, scope: tokenSaverDetailsScope), id: \.self) { provider in
                    tokenSaverProviderRow(provider: provider)
                }
            }

            Text(Self.tokenSaverBillingEvidenceDisclaimer)
                .font(DS.Font.caption2)
                .foregroundColor(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Self.tokenSaverBillingEvidenceDisclaimer)
                .accessibilityIdentifier("sidebar.tokenSaver.billingEvidenceDisclaimer")
        }
        .padding(DS.Space.md)
        .frame(width: 350, alignment: .leading)
        .background(DS.Palette.surface)
        .accessibilityIdentifier("sidebar.tokenSaver.details")
    }

    var tokenSaverDetailsPopoverForTesting: some View {
        tokenSaverDetailsPopover
    }

    nonisolated public static func tokenSaverLaneStateLabel(_ state: String) -> String {
        switch state {
        case "promoted": return "Active"
        case "shadow_only": return "Shadow"
        case "off": return "Off"
        default: return state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private var tokenSaverDetailsActivityChart: some View {
        let snapshot = tokenSaverDetailsSnapshot
        let detailsRingVals = tokenSaverActivityRingValues(for: snapshot, scope: tokenSaverDetailsScope)
        // :195 -- build label via the seam; replaces the detached
        // .accessibilityLabel/.accessibilityValue pair that never reached the view.
        let detailsRingsLabel = tokenSaverRingsAccessibilityLabel(
            for: snapshot,
            scope: tokenSaverDetailsScope,
            ringVals: detailsRingVals
        )
        return HStack(alignment: .center, spacing: DS.Space.lg) {
            TokenSaverActivityRings(values: detailsRingVals, a11yLabel: detailsRingsLabel)
                .frame(width: 104, height: 104)

            VStack(alignment: .leading, spacing: DS.Space.sm) {
                tokenSaverRingLegendRow(
                    color: DS.Palette.success,
                    label: "Token Saver",
                    value: tokenSaverSavingsSummary(for: snapshot, scope: tokenSaverDetailsScope)
                )
                // Legend matches concentric rings: Token Saver first, then usage desc.
                ForEach(detailsRingVals.providersOuterToInner, id: \.self) { provider in
                    tokenSaverRingLegendRow(
                        color: tokenSaverProviderColor(provider),
                        label: tokenSaverProviderTitle(provider),
                        value: tokenSaverLimitSummary(provider: provider, in: snapshot, scope: tokenSaverDetailsScope)
                    )
                }
                Text("Showing \(tokenSaverLimitScopeTitle(for: tokenSaverDetailsScope))")
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var tokenSaverDetailsSnapshot: TokenSaverUsageSnapshot {
        // PERF-MAC_SIDEBAR-:101 -- fast path: published snapshot already has the
        // period we need; return it directly without a disk read.
        if Self.detailsSnapshotCacheValid(publishedSnapshot: vm.tokenSaverUsageSnapshot) {
            return vm.tokenSaverUsageSnapshot
        }
        // Slow path: fallback disk read, but only when the published snapshot
        // changed since the last call (cache miss). Invalidation is by value
        // equality: a new write to usage.json bumps vm.tokenSaverUsageSnapshot,
        // which is Equatable, so the cache stays coherent without a file watcher.
        let key = vm.tokenSaverUsageSnapshot
        if let cached = _detailsSnapshotCache, _detailsSnapshotCacheKey == key {
            return cached
        }
        guard let context = vm.context else { return .empty() }
        let loaded = TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
        _detailsSnapshotCache = loaded
        _detailsSnapshotCacheKey = key
        return loaded
    }

    /// Pure predicate: returns true when `publishedSnapshot` already carries the
    /// period required by the details popover, making a disk read unnecessary.
    /// Extracted as a static seam so tests can verify the hit/miss boundary
    /// without an AppContext or SwiftUI render cycle.
    /// WHY: the predicate is the only logic that determines whether a disk read
    /// fires per frame; testing it in isolation proves the cache-valid contract.
    static func detailsSnapshotCacheValid(publishedSnapshot: TokenSaverUsageSnapshot) -> Bool {
        publishedSnapshot.period == .sevenDays
    }

    private var tokenSaverDetailsSavedOrPotential: Int {
        tokenSaverSavedOrPotential(in: tokenSaverDetailsSnapshot, scope: tokenSaverDetailsScope)
    }

    private func tokenSaverProviderRow(provider: AgentProvider) -> some View {
        let snapshot = tokenSaverDetailsSnapshot
        let usage = tokenSaverProviderUsage(provider, in: snapshot)
        // WHY: rows use measured ledger + multi-turn cache amort (Today) so a
        // thread footer (e.g. 7.0M) is reflected on the provider line, not only
        // the headline.
        let value = tokenSaverScopedProviderEstimatedSave(provider)
        let prefix = vm.privateAccountUser?.subscribed == true && vm.tokenSaverEnabled
            ? "Estimated save "
            : "Estimated potential "
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Text(tokenSaverProviderTitle(provider))
                    .font(DS.Font.captionStrong)
                    .foregroundColor(DS.Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("Used \(tokenSaverUsedLimitText(for: usage, provider: provider, scope: tokenSaverDetailsScope))")
                    .font(DS.Font.caption)
                    .foregroundColor(tokenSaverProviderColor(provider))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Text(tokenSaverProviderUsageCaption(for: usage, provider: provider, scope: tokenSaverDetailsScope))
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(prefix + Self.formatTokenCount(value))
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.success)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            // Capability line: honest static support copy under caption/save row.
            // Presentation only — does not change savings arithmetic.
            Text(Self.tokenSaverProviderCompressionCapabilityLine(for: provider))
                .font(DS.Font.caption2)
                .foregroundColor(DS.Palette.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("sidebar.tokenSaver.providerCapability.\(provider.rawValue)")
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
    }

    private func tokenSaverRingLegendRow(color: Color, label: String, value: String) -> some View {
        HStack(alignment: .center, spacing: DS.Space.xs) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(value)
                .font(DS.Font.captionStrong)
                .foregroundColor(DS.Palette.text)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private func tokenSaverLimitSummary(
        provider: AgentProvider,
        in snapshot: TokenSaverUsageSnapshot,
        scope: TokenSaverUsageScope
    ) -> String {
        let usage = tokenSaverProviderUsage(provider, in: snapshot)
        let used = tokenSaverUsedLimitProgress(
            for: usage,
            provider: provider,
            scope: scope
        )
        return used.map { "\(Self.formatPercent($0)) used" } ?? "No data"
    }

    private func tokenSaverDetailsChartAccessibilityValue(for snapshot: TokenSaverUsageSnapshot) -> String {
        [
            tokenSaverSavingsSummary(for: snapshot, scope: tokenSaverDetailsScope),
            "Used \(Self.formatTokenCount(tokenSaverScopeUsedTokens(in: snapshot, scope: tokenSaverDetailsScope)))",
            "\(tokenSaverProviderTitle(.claude)) \(tokenSaverLimitSummary(provider: .claude, in: snapshot, scope: tokenSaverDetailsScope))",
            "\(tokenSaverProviderTitle(.codex)) \(tokenSaverLimitSummary(provider: .codex, in: snapshot, scope: tokenSaverDetailsScope))",
            "\(tokenSaverProviderTitle(.grok)) \(tokenSaverLimitSummary(provider: .grok, in: snapshot, scope: tokenSaverDetailsScope))",
            "Showing \(tokenSaverLimitScopeTitle(for: tokenSaverDetailsScope))"
        ].joined(separator: ", ")
    }

    private func tokenSaverProviderColor(_ provider: AgentProvider) -> Color {
        switch provider {
        case .claude:
            return Color(nsColor: .systemOrange)
        case .codex:
            return Color(nsColor: .systemBlue)
        case .grok:
            // Product request: purple Grok ring (distinct from Claude orange / Codex blue).
            return Color(nsColor: .systemPurple)
        }
    }

    private func tokenSaverProviderTitle(_ provider: AgentProvider) -> String {
        switch provider {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        }
    }

    /// Pure seam: maps a sidecar status to a short human-readable label for the
    /// details-popover status row. Returns nil for `.running` and `.notStarted`
    /// (healthy / not yet started) so no banner appears. Returns a non-nil,
    /// ASCII-only string for `.blocked`, `.failed`, and `.starting` (not healthy).
    ///
    /// WHY separate from `displayLabel`: this seam controls VISIBILITY. Returning
    /// nil hides the row entirely so the popover stays clean when the sidecar
    /// is healthy.
    nonisolated public static func sidecarStatusLabel(
        _ status: TokenSaverDistillServiceStatus
    ) -> String? {
        switch status {
        case .blocked(let reason):
            return reason.isEmpty ? "Sidecar blocked" : "Sidecar blocked: \(reason)"
        case .failed(let reason):
            return reason.isEmpty ? "Sidecar failed" : "Sidecar failed: \(reason)"
        case .starting:
            return "Sidecar warming up"
        case .running, .notStarted:
            return nil
        }
    }

    /// Pure seam: returns the headline string for the Token Saver card. Extracted
    /// so tests can verify the degraded-state copy without rendering any SwiftUI view.
    ///
    /// WHY: when the sidecar is blocked the user sees the same reduction estimate
    /// headline as when everything is healthy, giving no signal that compression
    /// has stopped. This seam makes the degraded variant testable and explicit.
    /// `savedTokens` is the single primary scope figure (same estimator/cap for paid
    /// and teaser). `usedTokens` is retained for call-site compatibility; headline
    /// must not re-derive a separate usage-fraction teaser from it.
    nonisolated public static func tokenSaverCardHeadline(
        subscribed: Bool,
        enabled: Bool,
        sidecarStatus: TokenSaverDistillServiceStatus,
        savedTokens: Int,
        usedTokens: Int
    ) -> String {
        _ = usedTokens
        if subscribed && enabled {
            if case .blocked = sidecarStatus {
                return "Token Saver degraded"
            }
            return savedTokens > 0
                ? "Estimated save \(Self.formatTokenCountPublic(savedTokens)) tokens"
                : "Measuring local reduction per agent run"
        }
        // WHY: gate the enable toggle, not history — lapsed/disabled still see the
        // realized primary figure. Unsubscribed uses the same figure under a
        // potential label (never a separate compression heuristic).
        if savedTokens > 0 {
            if subscribed {
                return "Estimated save \(Self.formatTokenCountPublic(savedTokens)) tokens"
            }
            return "Estimated potential ~\(Self.formatTokenCountPublic(savedTokens)) tokens"
        }
        if subscribed {
            return "Enable Token Saver"
        }
        return "Estimate ready"
    }

    /// WHY: plain-language inventory of every leg in the number, without selling
    /// Anthropic list price or inventing dollar savings. Keep scannable in the popover.
    nonisolated public static let tokenSaverBillingEvidenceDisclaimer =
        "What this number includes: compressed tool output from the local Distill ledger "
        + "(shell wrappers, | distill, and Claude hooks); shorter dialect answers; Graphify "
        + "when the agent actually queries the graph; multi-turn savings from re-reading "
        + "smaller tool results; and Auto when it picks a cheaper model at the same quality. "
        + "Nested agent work credits the parent thread. Exact-output tools (rg, sed, jq, full "
        + "patches) stay full on purpose and are not counted. Compressions that fail delivery "
        + "are not counted either. This is not your provider bill or Anthropic cache pricing."

    // Internal alias exposed for the pure seam above. Mirrors `formatTokenCount`
    // which is private; keeping it nonisolated and public lets tests call it.
    nonisolated public static func formatTokenCountPublic(_ value: Int) -> String {
        if value >= 1_000_000 {
            let whole = Double(value) / 1_000_000.0
            return String(format: whole >= 10 ? "%.0fM" : "%.1fM", whole)
        }
        if value >= 1_000 {
            let whole = Double(value) / 1_000.0
            return String(format: whole >= 10 ? "%.0fK" : "%.1fK", whole)
        }
        return "\(value)"
    }

    private static func formatTokenCount(_ value: Int) -> String {
        formatTokenCountPublic(value)
    }

    /// WHY: all-time primary may only headline attributed savings — never the
    /// permanent aggregate that folds in unattributed/unknown provider bytes.
    nonisolated public static func tokenSaverAllTimePrimaryTokens(
        attributedSavedTokens: Int
    ) -> Int {
        max(0, attributedSavedTokens)
    }

    /// Scope-independent caption: attributed lifetime, runs, average per run.
    nonisolated public static func tokenSaverSinceInstallLine(
        attributedSavedTokens: Int,
        attributedRuns: Int
    ) -> String {
        let saved = max(0, attributedSavedTokens)
        let runs = max(0, attributedRuns)
        let avg = runs > 0 ? Int((Double(saved) / Double(runs)).rounded()) : 0
        return "Since install · \(formatTokenCountPublic(saved)) attributed · \(runs) runs · avg \(formatTokenCountPublic(avg))/run"
    }

    /// Unattributed row value: always shows this-window and all-time (including zeros).
    nonisolated public static func tokenSaverUnattributedRowValue(
        windowSaved: Int,
        allTimeSaved: Int
    ) -> String {
        "\(formatTokenCountPublic(max(0, windowSaved))) this window · \(formatTokenCountPublic(max(0, allTimeSaved))) all time"
    }

    nonisolated public static func tokenSaverUnattributedRunsCaption(
        windowRuns: Int,
        allTimeRuns: Int
    ) -> String {
        let window = max(0, windowRuns)
        let all = max(0, allTimeRuns)
        let windowPart = window == 1 ? "1 run this window" : "\(window) runs this window"
        return "\(windowPart) · \(all) all time · not provider-attributed"
    }

    /// Pure primary figure for inversion tests: same bare-user estimator as the card.
    /// Enabled path may include capped dialect/graphify; disabled is measured-only.
    /// WHY: enabling must never lower the figure for the same measured/used window.
    nonisolated public static func tokenSaverCardPrimaryFigure(
        measuredSaved: Int,
        usedTokens: Int,
        tokenSaverEnabled: Bool,
        graphifyActive: Bool = false
    ) -> Int {
        tokenSaverBareUserBreakdown(
            measuredToolOutputSaved: measuredSaved,
            windowProviderTokens: usedTokens,
            tokenSaverEnabled: tokenSaverEnabled,
            graphifyActive: graphifyActive
        ).totalCredible
    }

    /// Absolute goals for the green Token Saver ring: 5M today / 35M week.
    nonisolated public static func tokenSaverSavingsGoalTokens(isDailyScope: Bool) -> Int {
        isDailyScope ? 5_000_000 : 35_000_000
    }

    /// Absolute goal progress for the green Token Saver ring (5M today / 35M week).
    nonisolated public static func savingsToGoalProgress(
        savedTokens: Int,
        goalTokens: Int
    ) -> Double {
        let saved = max(savedTokens, 0)
        let goal = max(goalTokens, 1)
        guard saved > 0 else { return 0 }
        return min(Double(saved) / Double(goal), 1)
    }

    /// Share of the measured (saved + used) mix that was locally reduced.
    /// Retained as a pure diagnostic seam; the green ring uses fixed goals instead.
    ///
    /// `usedTokens` must be **known billed** units (caller responsibility). Never
    /// pass raw provider tokens here for a displayed ring fraction.
    nonisolated public static func savingsAvoidanceRatio(
        savedTokens: Int,
        usedTokens: Int
    ) -> Double {
        let saved = max(0, savedTokens)
        let used = max(0, usedTokens)
        let denom = saved + used
        guard saved > 0, denom > 0 else { return 0 }
        return min(Double(saved) / Double(denom), 1)
    }

    /// Green savings ring fraction for a scope window.
    ///
    /// - Comparable window (Today/Week) → `saved / goal` clamped to 1 (5M today / 35M week).
    /// - No comparable usage window (all-time) → explicit unavailable (never 100% from used=0).
    public enum TokenSaverSavingsRingFraction: Equatable, Sendable {
        case comparable(progress: Double, goalTokens: Int)
        case noComparableUsageWindow

        public var isComparable: Bool {
            if case .comparable = self { return true }
            return false
        }

        public var progress: Double {
            if case .comparable(let progress, _) = self { return progress }
            return 0
        }

        /// Fixed goal denominator when comparable (5M today / 35M week).
        public var mixTokens: Int? {
            if case .comparable(_, let goal) = self { return goal }
            return nil
        }

        public var unavailableReason: String? {
            switch self {
            case .comparable:
                return nil
            case .noComparableUsageWindow:
                return "no comparable usage window"
            }
        }
    }

    /// Pure seam: map saved + fixed goal into a ring fraction state.
    nonisolated public static func tokenSaverSavingsRingFraction(
        savedTokens: Int,
        goalTokens: Int,
        hasComparableUsageWindow: Bool
    ) -> TokenSaverSavingsRingFraction {
        guard hasComparableUsageWindow else {
            return .noComparableUsageWindow
        }
        let goal = max(goalTokens, 1)
        let progress = savingsToGoalProgress(savedTokens: savedTokens, goalTokens: goal)
        return .comparable(progress: progress, goalTokens: goal)
    }

    /// All-time reconciliation: managed attributed rows + unattributed must equal
    /// attributed headline + unattributed (i.e. managed rows sum to the headline).
    ///
    /// WHY: production needs per-provider attributed figures from Persistence; this
    /// pure seam encodes the honesty contract tests can falsify without a DB.
    nonisolated public static func tokenSaverAllTimeRowsReconcileWithHeadline(
        managedProviderAttributedSaved: [Int],
        unattributedSaved: Int,
        attributedHeadline: Int
    ) -> Bool {
        let managed = managedProviderAttributedSaved.reduce(0) { $0 + max(0, $1) }
        let unattributed = max(0, unattributedSaved)
        let headline = max(0, attributedHeadline)
        return managed + unattributed == headline + unattributed
    }

    /// Pure all-time provider row figure — attributed only (never permanent aggregate).
    nonisolated public static func tokenSaverAllTimeProviderAttributedSaved(
        attributedSavedForProvider: Int
    ) -> Int {
        max(0, attributedSavedForProvider)
    }

    nonisolated public static func tokenSaverDayStartMs(
        now: Date,
        calendar: Calendar = .current
    ) -> Int64 {
        Int64(calendar.startOfDay(for: now).timeIntervalSince1970 * 1000)
    }

    nonisolated public static func tokenSaverNextDailyResetDate(
        after date: Date,
        calendar: Calendar = .current
    ) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        let currentReset = dayStart.addingTimeInterval(1)
        if date < currentReset { return currentReset }
        let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? date.addingTimeInterval(86_400)
        return nextDayStart.addingTimeInterval(1)
    }

    nonisolated public static func tokenSaverTodaySavedTokens(
        daily: [TokenSaverDailySavings],
        now: Date,
        calendar: Calendar = .current
    ) -> Int {
        let todayStartMs = tokenSaverDayStartMs(now: now, calendar: calendar)
        return daily
            .filter { $0.dayStartMs == todayStartMs }
            .reduce(0) { $0 + $1.savedTokens }
    }

    nonisolated public static func tokenSaverReportWindowSavedTokens(
        daily: [TokenSaverDailySavings]
    ) -> Int {
        daily.reduce(0) { $0 + $1.savedTokens }
    }

    /// Saved tokens for ONE provider on today's calendar day. Mirrors
    /// `tokenSaverTodaySavedTokens` but reads the per-(provider, day) buckets so a
    /// provider row matches the Today headline window.
    nonisolated public static func tokenSaverTodaySaved(
        forProvider provider: String,
        dailyByProvider: [TokenSaverProviderDailySavings],
        now: Date,
        calendar: Calendar = .current
    ) -> Int {
        let todayStartMs = tokenSaverDayStartMs(now: now, calendar: calendar)
        return dailyByProvider
            .filter { $0.provider == provider && $0.dayStartMs == todayStartMs }
            .reduce(0) { $0 + $1.savedTokens }
    }

    /// Saved tokens for ONE provider across the whole retained report window
    /// (the Week scope), from the per-(provider, day) buckets.
    nonisolated public static func tokenSaverWindowSaved(
        forProvider provider: String,
        dailyByProvider: [TokenSaverProviderDailySavings]
    ) -> Int {
        dailyByProvider
            .filter { $0.provider == provider }
            .reduce(0) { $0 + $1.savedTokens }
    }

    /// Today's saved tokens + run count for every provider NOT in `known` (the
    /// "CLI & other" reconciling row), windowed to today.
    nonisolated public static func tokenSaverTodaySaved(
        forProvidersOtherThan known: Set<String>,
        dailyByProvider: [TokenSaverProviderDailySavings],
        now: Date,
        calendar: Calendar = .current
    ) -> (savedTokens: Int, runs: Int) {
        let todayStartMs = tokenSaverDayStartMs(now: now, calendar: calendar)
        let rows = dailyByProvider.filter { !known.contains($0.provider) && $0.dayStartMs == todayStartMs }
        return (
            savedTokens: rows.reduce(0) { $0 + $1.savedTokens },
            runs: rows.reduce(0) { $0 + $1.runs }
        )
    }

    /// Report-window saved tokens + run count for every provider NOT in `known`
    /// (the "CLI & other" reconciling row), windowed to the Week scope.
    nonisolated public static func tokenSaverWindowSaved(
        forProvidersOtherThan known: Set<String>,
        dailyByProvider: [TokenSaverProviderDailySavings]
    ) -> (savedTokens: Int, runs: Int) {
        let rows = dailyByProvider.filter { !known.contains($0.provider) }
        return (
            savedTokens: rows.reduce(0) { $0 + $1.savedTokens },
            runs: rows.reduce(0) { $0 + $1.runs }
        )
    }

    private static func formatPercent(_ progress: Double) -> String {
        "\(Int((min(max(progress, 0), 1) * 100).rounded()))%"
    }

    // MARK: - Static seams (:15 :18 :186 :187 :188 :195)

    /// :15 -- Pure decision: maps an NSAlert response to a confirmed remove action.
    ///
    /// WHY separate: the confirmation logic (first button = proceed) must be
    /// testable without running a modal alert on the main thread. Extracted so
    /// both removeWorkspace and removeSelectedWorkspaces share identical semantics.
    ///
    /// - Returns: true when `response == .alertFirstButtonReturn` (Remove button),
    ///            false otherwise (Cancel or sheet dismissal).
    nonisolated public static func confirmRemoveDecision(response: NSApplication.ModalResponse) -> Bool {
        response == .alertFirstButtonReturn
    }

    /// :18 -- Pure decision: maps a pointer Y position relative to a scroll view
    /// to an auto-scroll direction during a drag.
    ///
    /// WHY separate: the arithmetic is trivially testable without a real scroll
    /// view or drag event. The caller (WorkspaceDropDelegate.dropUpdated) passes
    /// real coordinates; tests pass arbitrary values.
    ///
    /// - Parameters:
    ///   - pointerY: pointer Y in the scroll view's coordinate space.
    ///     Y increases downward (AppKit window coords are flipped relative to
    ///     screen; convert before calling if needed).
    ///   - viewHeight: total height of the scroll view.
    ///   - edgeZone: distance from the top or bottom edge that triggers scroll.
    /// - Returns: -1 when pointer is in the top edge zone (scroll up),
    ///            +1 when in the bottom edge zone (scroll down), 0 otherwise.
    nonisolated public static func autoScrollDirection(
        pointerY: CGFloat,
        viewHeight: CGFloat,
        edgeZone: CGFloat
    ) -> Int {
        guard viewHeight > 0, edgeZone > 0 else { return 0 }
        if pointerY < edgeZone { return -1 }
        if pointerY > viewHeight - edgeZone { return 1 }
        return 0
    }

    /// :186 -- Sums the byte sizes of all regular files under `url` (non-recursive
    /// into sub-directories is fine; the model dir is flat).  Uses a recursive
    /// enumerator so nested revision sub-directories are included.
    ///
    /// WHY pure/nonisolated: lets tests exercise the calculation with a temp-dir
    /// fixture without any AppContext or UI setup.  Returns 0 when the directory
    /// does not exist (model not installed).
    nonisolated public static func modelDirSize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// :186 -- Human-readable size string for a byte count, matching the style
    /// used in `TokenSaverModelDownloadModal.formatBytes`.
    nonisolated public static func humanDirSizeString(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return String(format: value >= 10 || index == 0 ? "%.0f %@" : "%.1f %@", value, units[index])
    }

    /// :188 -- Human-readable "last updated" label for the account-usage
    /// timestamp row in the details popover.
    ///
    /// Returns "Never" when `date` is nil.
    /// Returns "Updated just now" when elapsed < 60 s.
    /// Returns "Updated Xm ago" for minutes, "Updated Xh ago" for hours.
    /// Capped at "Updated 24h+ ago" beyond 24 h so the string stays compact.
    ///
    /// WHY separate: the test can verify the label logic without a running VM or
    /// wall-clock dependency -- tests pass an explicit `now`.
    nonisolated public static func lastUpdatedLabel(_ date: Date?, now: Date) -> String {
        guard let date else { return "Never" }
        let elapsed = now.timeIntervalSince(date)
        guard elapsed >= 0 else { return "Updated just now" }
        if elapsed < 60 { return "Updated just now" }
        let mins = Int(elapsed / 60)
        if mins < 60 { return "Updated \(mins)m ago" }
        let hours = mins / 60
        if hours < 24 { return "Updated \(hours)h ago" }
        return "Updated 24h+ ago"
    }

    /// Labels the slow provider-account probe explicitly so it cannot be mistaken
    /// for the local per-run usage signal shown elsewhere in the popover.
    nonisolated public static func accountUsageLastUpdatedLabel(
        _ date: Date?,
        now: Date
    ) -> String {
        let label = lastUpdatedLabel(date, now: now)
        guard label != "Never" else { return "Account usage not refreshed" }
        return label.replacingOccurrences(
            of: "Updated",
            with: "Account usage updated",
            options: [.anchored]
        )
    }

    /// Honest local-ledger activity copy. This reports provider tokens observed by
    /// RemoteCode, never projected savings or a rounded provider-account percentage.
    nonisolated public static func localUsageUpdateLabel(
        _ update: SidebarViewModel.TokenSaverLocalUsageUpdate,
        now: Date
    ) -> String {
        let order: [AgentProvider] = [.claude, .codex, .grok]
        let providerParts = order.compactMap { provider -> String? in
            guard let delta = update.providerTokenDeltas[provider], delta > 0 else { return nil }
            let title: String
            switch provider {
            case .claude: title = "Claude"
            case .codex: title = "Codex"
            case .grok: title = "Grok"
            }
            return "\(title) +\(formatTokenCountPublic(delta))"
        }
        guard !providerParts.isEmpty else { return "Local usage unchanged" }
        let relative = lastUpdatedLabel(update.updatedAt, now: now)
            .replacingOccurrences(of: "Updated ", with: "", options: [.anchored])
        return "Local usage · \(providerParts.joined(separator: ", ")) tokens · \(relative)"
    }

    /// :195 -- Accessible description of the activity rings for VoiceOver.
    ///
    /// WHY: `TokenSaverActivityRings` was `.accessibilityHidden(true)` so VoiceOver
    /// reported nothing.  This seam produces a non-empty string containing the ring
    /// values so screen readers can convey the same information as the visual rings.
    ///
    /// When `savingsRingComparable` is false, the green ring is in an explicit
    /// unavailable state (no comparable usage window / all-time) — never claim a
    /// goal percent from used=0.
    nonisolated public static func ringsAccessibilityLabel(
        scope: String,
        savedTokens: Int,
        savedProgress: Double,
        savedGoalTokens: Int = 35_000_000,
        savingsRingComparable: Bool = true,
        savingsRingUnavailableReason: String? = nil,
        claudeUsedProgress: Double,
        codexUsedProgress: Double,
        grokUsedProgress: Double
    ) -> String {
        let savedPct = Int((min(max(savedProgress, 0), 1) * 100).rounded())
        let claudePct = Int((min(max(claudeUsedProgress, 0), 1) * 100).rounded())
        let codexPct = Int((min(max(codexUsedProgress, 0), 1) * 100).rounded())
        let grokPct = Int((min(max(grokUsedProgress, 0), 1) * 100).rounded())
        let savedStr = savedTokens >= 1_000_000
            ? String(format: "%.1fM", Double(savedTokens) / 1_000_000)
            : savedTokens >= 1_000
                ? String(format: "%.0fK", Double(savedTokens) / 1_000)
                : "\(savedTokens)"
        let savingsPart: String
        if savingsRingComparable {
            // WHY: ring is fixed-goal (5M today / 35M week); a11y names that goal.
            let goalStr = savedGoalTokens >= 1_000_000
                ? String(format: "%.0fM", Double(savedGoalTokens) / 1_000_000)
                : savedGoalTokens >= 1_000
                    ? String(format: "%.0fK", Double(savedGoalTokens) / 1_000)
                    : "\(savedGoalTokens)"
            // WHY: the figure is scope credible (measured + dialect + graphify), same
            // as the visible "Estimated save" headline — never claim "measured" alone.
            savingsPart = "estimated save \(savedStr) local tokens, ~\(savedPct)% of \(goalStr) goal"
        } else {
            let reason = (savingsRingUnavailableReason?.isEmpty == false)
                ? savingsRingUnavailableReason!
                : "usage window unavailable"
            savingsPart = "estimated save \(savedStr) local tokens, savings share unavailable (\(reason))"
        }
        return "Token Saver rings, \(scope): \(savingsPart), Claude used \(claudePct)%, Codex used \(codexPct)%, Grok used \(grokPct)%"
    }

    /// WHY: concentric rings must read as "biggest usage outer". Token Saver is
    /// always the outermost ring; managed providers sort by used-progress desc
    /// so the chart matches the legend (e.g. Token Saver → Grok 46% → Claude 45% → Codex 7%).
    enum TokenSaverRingOrdering {
        /// Provider rings outer → inner (after Token Saver). Higher usage is outer.
        /// Ties keep a stable claude < codex < grok secondary order.
        nonisolated static func providersOuterToInner(
            claudeUsedProgress: Double,
            codexUsedProgress: Double,
            grokUsedProgress: Double
        ) -> [AgentProvider] {
            let items: [(AgentProvider, Double)] = [
                (.claude, claudeUsedProgress),
                (.codex, codexUsedProgress),
                (.grok, grokUsedProgress)
            ]
            let secondary: [AgentProvider: Int] = [.claude: 0, .codex: 1, .grok: 2]
            return items
                .sorted { lhs, rhs in
                    if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                    return (secondary[lhs.0] ?? 99) < (secondary[rhs.0] ?? 99)
                }
                .map(\.0)
        }
    }

    struct TokenSaverActivityRings: View {
        struct Values: Equatable {
            let tokenSaverProgress: Double
            /// False when billed units are unknown or the scope has no comparable
            /// usage window — green ring renders dimmed/empty, never a raw ratio.
            let tokenSaverSavingsRingAvailable: Bool
            let claudeUsedProgress: Double
            let codexUsedProgress: Double
            let grokUsedProgress: Double

            init(
                tokenSaverProgress: Double,
                tokenSaverSavingsRingAvailable: Bool = true,
                claudeUsedProgress: Double,
                codexUsedProgress: Double,
                grokUsedProgress: Double
            ) {
                self.tokenSaverProgress = tokenSaverProgress
                self.tokenSaverSavingsRingAvailable = tokenSaverSavingsRingAvailable
                self.claudeUsedProgress = claudeUsedProgress
                self.codexUsedProgress = codexUsedProgress
                self.grokUsedProgress = grokUsedProgress
            }

            /// Managed providers outer → inner after the always-outer Token Saver ring.
            var providersOuterToInner: [AgentProvider] {
                TokenSaverRingOrdering.providersOuterToInner(
                    claudeUsedProgress: claudeUsedProgress,
                    codexUsedProgress: codexUsedProgress,
                    grokUsedProgress: grokUsedProgress
                )
            }

            func usedProgress(for provider: AgentProvider) -> Double {
                switch provider {
                case .claude: return claudeUsedProgress
                case .codex: return codexUsedProgress
                case .grok: return grokUsedProgress
                }
            }
        }

        let values: Values
        /// :195 -- VoiceOver label describing ring values.  nil hides the element
        /// (legacy behaviour when caller cannot supply values; should not occur in
        /// production paths).
        var a11yLabel: String? = nil

        /// Geometry slots outer → inner (Token Saver + 3 provider rings).
        /// Line widths taper inward so the outer ring stays dominant.
        private static let ringSlots: [(inset: CGFloat, lineWidth: CGFloat)] = [
            (2.0, 4.0),
            (7.4, 3.0),
            (12.2, 2.2),
            (16.6, 1.8)
        ]

        var body: some View {
            GeometryReader { proxy in
                let side = max(min(proxy.size.width, proxy.size.height), 1)
                scaledContent(side: side)
                    .frame(width: side, height: side)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .aspectRatio(1, contentMode: .fit)
            // :195 -- expose ring values to VoiceOver instead of hiding the element.
            .accessibilityHidden(a11yLabel == nil)
            .accessibilityLabel(a11yLabel ?? "")
        }

        private func scaledContent(side: CGFloat) -> some View {
            let scale = max(side / 34.0, 0.1)
            let providers = values.providersOuterToInner
            let slots = Self.ringSlots
            return ZStack {
                // Slot 0: Token Saver always outermost (three provider rings inside).
                TokenSaverActivityRing(
                    progress: values.tokenSaverProgress,
                    color: DS.Palette.success,
                    inset: slots[0].inset * scale,
                    lineWidth: slots[0].lineWidth * scale,
                    dimmed: !values.tokenSaverSavingsRingAvailable
                )
                ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
                    let slot = slots[min(index + 1, slots.count - 1)]
                    TokenSaverActivityRing(
                        progress: values.usedProgress(for: provider),
                        color: tokenSaverProviderRingColor(provider),
                        inset: slot.inset * scale,
                        lineWidth: slot.lineWidth * scale
                    )
                }
            }
        }

        private func tokenSaverProviderRingColor(_ provider: AgentProvider) -> Color {
            switch provider {
            case .claude: return Color(nsColor: .systemOrange)
            case .codex: return Color(nsColor: .systemBlue)
            case .grok: return Color(nsColor: .systemPurple)
            }
        }
    }

    private struct TokenSaverActivityRing: View {
        let progress: Double
        let color: Color
        let inset: CGFloat
        let lineWidth: CGFloat
        var dimmed: Bool = false

        var body: some View {
            ZStack {
                TokenSaverActivityRingShape(progress: 1)
                    .stroke(
                        color.opacity(dimmed ? 0.08 : 0.18),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )
                // Unavailable/dimmed: track only — never paint a raw-derived fill.
                if !dimmed {
                    TokenSaverActivityRingShape(progress: progress)
                        .stroke(
                            color,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                        )
                }
            }
            .padding(inset)
        }
    }

    private struct TokenSaverActivityRingShape: Shape {
        let progress: Double

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let bounded = min(max(progress, 0), 1)
            let radius = min(rect.width, rect.height) / 2
            path.addArc(
                center: CGPoint(x: rect.midX, y: rect.midY),
                radius: radius,
                startAngle: .degrees(-88),
                endAngle: .degrees((360 * bounded) - 88),
                clockwise: false
            )
            return path
        }
    }

    /// P2-SIDEBAR-SEPARATOR: thin rule + "Pinned" caption rendered between
    /// the pinned and unpinned groups.
    private var pinnedGroupDivider: some View {
        HStack(spacing: DS.Space.sm) {
            Rectangle()
                .fill(DS.Palette.line.opacity(0.5))
                .frame(height: DS.Border.hairline)
            Text("Pinned")
                .font(DS.Font.caption2)
                .foregroundColor(DS.Palette.textTertiary)
                .fixedSize()
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.top, DS.Space.xxs)
        .padding(.bottom, DS.Space.xxs)
        .accessibilityHidden(true)
    }

    private var insomniaHelpText: String {
        "Insomnia keeps this Mac awake while the toggle is on. Settings can allow display sleep, closed-display sleep, or the screen saver without ending the session."
    }

    private var insomniaControl: some View {
        HStack(alignment: .center, spacing: DS.Space.sm) {
            insomniaToggle
            // UX-MAC_SHELL_WINDOW-013: a subtitle summarises which power
            // exceptions are active so the state is legible at a glance.
            VStack(alignment: .leading, spacing: 1) {
                Text("Insomnia")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.text)
                    .lineLimit(1)
                Text(insomniaStateSummary)
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
            .frame(height: 32, alignment: .center)
            Spacer(minLength: 0)
            insomniaOptionsMenu
        }
        .padding(.horizontal, DS.Space.sm)
        .frame(height: 40)
        .help(insomniaHelpText)
    }

    private var insomniaStateSummary: String {
        guard vm.insomniaEnabled else { return "Off" }
        var allowances: [String] = []
        if vm.insomniaAllowDisplaySleep { allowances.append("display can sleep") }
        if vm.insomniaAllowSystemSleepWhenDisplayClosed { allowances.append("sleep when closed") }
        if vm.insomniaAllowScreenSaverAfter45MinutesOfInactivity { allowances.append("screen saver after 45m") }
        return allowances.isEmpty ? "Mac stays awake" : allowances.joined(separator: " · ")
    }

    private var insomniaToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                vm.setInsomniaEnabled(!vm.insomniaEnabled)
            }
        } label: {
            ZStack(alignment: vm.insomniaEnabled ? .trailing : .leading) {
                Capsule()
                    .fill(vm.insomniaEnabled ? DS.Palette.danger : DS.Palette.surfaceRaised)
                    .overlay(
                        Capsule()
                            .stroke(vm.insomniaEnabled ? Color.clear : DS.Palette.lineStrong.opacity(0.7),
                                    lineWidth: DS.Border.hairline)
                    )
                Circle()
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.18), radius: 1, x: 0, y: 1)
                    .padding(2)
            }
            .frame(width: 32, height: 18)
        }
        .buttonStyle(.plain)
        // UX-SIDEBAR-P3-INSOMNIAHIT: 36x36 matches the adjacent options
        // chevron hit area; the previous 36x24 was inconsistent.
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
        .help(insomniaHelpText)
        .accessibilityLabel("Insomnia")
        .accessibilityValue(vm.insomniaEnabled ? "on" : "off")
        .accessibilityHint(insomniaHelpText)
        .accessibilityIdentifier("sidebar.insomnia.toggle")
    }

    private var insomniaOptionsMenu: some View {
        Button {
            showsInsomniaOptions.toggle()
        } label: {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Palette.textTertiary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsInsomniaOptions, arrowEdge: .trailing) {
            insomniaOptionsPopover
        }
        .help(insomniaHelpText)
        .accessibilityLabel("Insomnia settings")
        .accessibilityIdentifier("sidebar.insomnia.options")
    }

    private var insomniaOptionsPopover: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Toggle("Allow display sleep", isOn: Binding(
                get: { vm.insomniaAllowDisplaySleep },
                set: { vm.setInsomniaAllowDisplaySleep($0) }
            ))
            Toggle("Allow system sleep when display is closed", isOn: Binding(
                get: { vm.insomniaAllowSystemSleepWhenDisplayClosed },
                set: { vm.setInsomniaAllowSystemSleepWhenDisplayClosed($0) }
            ))
            Toggle("Allow screen saver after 45m of inactivity", isOn: Binding(
                get: { vm.insomniaAllowScreenSaverAfter45MinutesOfInactivity },
                set: { vm.setInsomniaAllowScreenSaverAfter45MinutesOfInactivity($0) }
            ))
        }
        .toggleStyle(.checkbox)
        .font(DS.Font.body)
        .foregroundColor(DS.Palette.text)
        .padding(DS.Space.md)
    }

    private struct TokenSaverModelDownloadModal: View {
        let state: TokenSaverModelDownloadState
        let aggregatedDownloadedBytes: Int64
        let aggregatedTotalBytes: Int64
        let downloadBytesPerSec: Double
        let onCancel: () -> Void
        let onResume: () -> Void
        let onRetry: () -> Void

        private var isFailed: Bool { state.phase == .failed }
        private var isPaused: Bool { state.phase == .paused }

        var body: some View {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                HStack(alignment: .top, spacing: DS.Space.md) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(DS.Palette.success)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("Download Token Saver model")
                            .font(DS.Font.title3)
                            .foregroundColor(DS.Palette.text)
                        Text(TokenSaverApprovedModels.selected().id)
                            .font(DS.Font.monoSmall)
                            .foregroundColor(DS.Palette.textSecondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    infoRow("Source", TokenSaverApprovedModels.selected().url.replacingOccurrences(of: "https://", with: ""))
                    infoRow("Status", state.statusText)
                    infoRow("Progress", progressText)
                    if let errorMessage = state.errorMessage, !errorMessage.isEmpty {
                        let parts = errorMessage.split(separator: "\n", maxSplits: 1).map(String.init)
                        let headline = parts.first ?? errorMessage
                        let detail = parts.count > 1 ? parts[1] : nil
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            Text(headline)
                                .font(DS.Font.caption)
                                .foregroundColor(DS.Palette.warning)
                                .fixedSize(horizontal: false, vertical: true)
                            if let detail {
                                Text(detail)
                                    .font(DS.Font.caption)
                                    .foregroundColor(DS.Palette.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                if !isFailed {
                    progressView
                        .accessibilityLabel("Token Saver model download progress")
                        .accessibilityValue(progressText)
                }

                HStack {
                    Spacer()
                    Button("Cancel") {
                        onCancel()
                    }
                    .keyboardShortcut(.cancelAction)
                    .frame(minWidth: 88, minHeight: 44)
                    if isPaused {
                        Button("Resume") {
                            onResume()
                        }
                        .keyboardShortcut(.defaultAction)
                        .frame(minWidth: 88, minHeight: 44)
                        .accessibilityIdentifier("tokenSaverDownload.resume")
                    }
                    if isFailed {
                        Button("Retry") {
                            onRetry()
                        }
                        .keyboardShortcut(.defaultAction)
                        .frame(minWidth: 88, minHeight: 44)
                    }
                }
            }
            .padding(DS.Space.xxl)
            .frame(width: 460)
            .background(DS.Palette.surface)
        }

        private var progressView: some View {
            Group {
                if aggregatedTotalBytes > 0 && state.phase == .downloading {
                    let fraction = min(Double(aggregatedDownloadedBytes) / Double(aggregatedTotalBytes), 1.0)
                    ProgressView(value: fraction, total: 1)
                } else if let fraction = state.fractionCompleted {
                    ProgressView(value: fraction, total: 1)
                } else {
                    ProgressView()
                }
            }
            .tint(DS.Palette.success)
        }

        private var progressText: String {
            // Use aggregate bytes when a real download is in progress.
            // Fall back to per-file display during prepare/verify/idle phases.
            guard state.phase == .downloading, aggregatedTotalBytes > 0 else {
                let downloaded = Self.formatBytes(state.downloadedBytes)
                guard let expected = state.expectedBytes else { return downloaded }
                let percent = Int(((state.fractionCompleted ?? 0) * 100).rounded())
                return "\(downloaded) / \(Self.formatBytes(expected)) (\(percent)%)"
            }
            let (percent, etaSeconds) = SidebarViewModel.aggregateProgress(
                downloadedBytes: aggregatedDownloadedBytes,
                totalBytes: aggregatedTotalBytes,
                bytesPerSec: downloadBytesPerSec
            )
            let downloaded = Self.formatBytes(aggregatedDownloadedBytes)
            let total = Self.formatBytes(aggregatedTotalBytes)
            let speed = downloadBytesPerSec > 0
                ? " - \(Self.formatBytes(Int64(downloadBytesPerSec)))/s"
                : ""
            let eta: String
            if let secs = etaSeconds, secs > 0 {
                eta = " - ~\(SidebarViewModel.formatDownloadETA(secs)) left"
            } else {
                eta = ""
            }
            return "\(downloaded) of \(total) - \(percent)%\(speed)\(eta)"
        }

        private func infoRow(_ label: String, _ value: String) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.md) {
                Text(label)
                    .font(DS.Font.captionStrong)
                    .foregroundColor(DS.Palette.textTertiary)
                    .frame(width: 72, alignment: .leading)
                Text(value)
                    .font(label == "Source" ? DS.Font.monoSmall : DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
        }

        private static func formatBytes(_ bytes: Int64) -> String {
            guard bytes > 0 else { return "0 B" }
            let units = ["B", "KB", "MB", "GB"]
            var value = Double(bytes)
            var index = 0
            while value >= 1024, index < units.count - 1 {
                value /= 1024
                index += 1
            }
            return String(format: value >= 10 || index == 0 ? "%.0f %@" : "%.1f %@", value, units[index])
        }

    }

    private var accountAvatar: some View {
        accountAvatar(size: 28, textSize: 11)
    }

    private var headerAccountAvatar: some View {
        accountAvatar(size: 18, textSize: 7.5)
    }

    private func accountAvatar(size: CGFloat, textSize: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(vm.privateAccountUser == nil ? DS.Palette.surfaceRaised : DS.Palette.accent.opacity(0.22))
                .overlay(
                    Circle()
                        .stroke(DS.Palette.lineStrong.opacity(0.7), lineWidth: DS.Border.hairline)
                )
            Text(accountInitials)
                .font(.system(size: textSize, weight: .semibold))
                .foregroundColor(vm.privateAccountUser == nil ? DS.Palette.textSecondary : DS.Palette.accent)
        }
        .frame(width: size, height: size)
    }

    private var accountDisplayName: String {
        guard let email = vm.privateAccountUser?.email, let local = email.split(separator: "@").first, !local.isEmpty else {
            return "Sign in"
        }
        return String(local)
    }

    private var accountSubtitle: String {
        vm.privateAccountUser?.email ?? "RemoteCode Account"
    }

    private var accountInitials: String {
        guard let email = vm.privateAccountUser?.email, let local = email.split(separator: "@").first else {
            return "RC"
        }
        let letters = local.filter(\.isLetter)
        let prefix = letters.prefix(2)
        return prefix.isEmpty ? "RC" : String(prefix).uppercased()
    }

    // MARK: Row accessibility helpers

    /// Builds the VoiceOver value string for a workspace row by forwarding to
    /// the pure `SidebarViewModel.workspaceRowAccessibilityValue(...)` helper.
    private func workspaceRowAccessibilityValue(
        ws: Workspace,
        busy: Bool,
        checked: Bool,
        pinned: Bool
    ) -> String {
        let busyDesc = busy ? vm.busyTooltip(for: ws) : nil
        return SidebarViewModel.workspaceRowAccessibilityValue(
            busyDescription: busyDesc,
            unreadCount: ws.notificationsUnread,
            pinned: pinned,
            checked: checked
        )
    }

    // MARK: Row highlight helpers

    private func rowHighlightColor(for tone: SidebarHighlightTone) -> Color {
        switch tone {
        case .workspaceColor(let hex):
            return Color(hex: hex).opacity(0.22)
        case .accent:
            return DS.Palette.accent.opacity(0.22)
        case .selection:
            return DS.Palette.selection.opacity(0.75)
        case .none:
            return Color.white.opacity(0.001)
        }
    }

    private func rowEdgeBarColor(for tone: SidebarHighlightTone) -> Color {
        switch tone {
        case .workspaceColor(let hex):
            return Color(hex: hex)
        case .accent:
            return DS.Palette.accent
        case .selection:
            return DS.Palette.accent
        case .none:
            return Color.clear
        }
    }

    @ViewBuilder
    private func workspaceRow(_ ws: Workspace) -> some View {
        let selected = vm.selectedWorkspaceID == ws.id
        let checked = vm.selectedWorkspaceIDs.contains(ws.id)
        let desc = ws.metadata["description"]
        let pinned = ws.metadata["pinned"] == "true"
        let busy = vm.isWorkspaceBusy(ws)
        let highlightTone = SidebarSelectionHighlightResolver().resolve(workspace: ws, isSelected: selected, isChecked: checked)
        Button {
            let flags = NSEvent.modifierFlags
            vm.selectWorkspaceRow(
                ws,
                extendingSelection: flags.contains(.shift),
                togglingSelection: flags.contains(.command))
        } label: {
            HStack(spacing: DS.Space.sm) {
                if checked {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .regular))
                        .frame(width: 20, height: 20)
                        .foregroundColor(DS.Palette.accent)
                }
                Image(systemName: pinned ? "pin.fill" : "folder.fill")
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 20, height: 20)
                    .foregroundColor(pinned ? DS.Palette.accent :
                        TabColor.from(ws.metadata["color"]).map { Color(hex: $0.hex) }
                        ?? DS.Palette.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ws.name).font(selected ? DS.Font.bodyStrong : DS.Font.body)
                        .foregroundColor(DS.Palette.text).lineLimit(1)
                    if let d = desc, !d.isEmpty {
                        Text(d).font(DS.Font.caption2)
                            .foregroundColor(DS.Palette.textTertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if busy {
                    let busyLabel = vm.busyTooltip(for: ws) ?? "Workspace busy"
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                        // UX-SIDEBAR-P3-BUSYTIP: use the per-workspace busy
                        // source description instead of the generic label so
                        // VoiceOver and tooltip convey agent-run vs terminal.
                        .help(busyLabel)
                        .accessibilityLabel(busyLabel)
                } else if vm.completedWorkspaces.contains(ws.id) {
                    // UX-SIDEBAR-COMPLETED-DOT: the action finished — a small success
                    // dot takes the spinner's slot until the user opens the workspace.
                    Circle()
                        .fill(DS.Palette.success)
                        .frame(width: 7, height: 7)
                        .frame(width: 16, height: 16)
                        .help("Action completed")
                        .accessibilityLabel("Action completed")
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
                if ws.notificationsUnread > 0 {
                    DSPill("\(ws.notificationsUnread)", tone: .accent)
                }
            }
            // UX-SIDEBAR-COMPLETED-DOT: fade/scale the spinner→dot swap in subtly
            // (reduced-motion shows it instantly).
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2),
                       value: vm.completedWorkspaces.contains(ws.id))
            .padding(.horizontal, DS.Space.sm)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(rowHighlightColor(for: highlightTone))
            )
            .overlay(alignment: .leading) {
                // Left-edge bar: visible only when row is selected (single or checked).
                // Uses workspace color when available, accent as fallback.
                if highlightTone != .none {
                    rowEdgeBarColor(for: highlightTone)
                        .frame(width: 3)
                        .clipShape(
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        )
                        .padding(.vertical, 5)
                }
            }
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                if vm.dropTargetWorkspaceID == ws.id {
                    Capsule()
                        .fill(DS.Palette.accent)
                        .frame(height: 2)
                        .padding(.horizontal, DS.Space.sm)
                }
            }
        }
        .buttonStyle(.plain)
        .help(ws.cwd.isEmpty ? ws.name : ws.cwd)
        // UX-SIDEBAR-P3-A11Y: expose a combined label so VoiceOver reads
        // name + status in one focused element rather than a string of
        // context-free sub-elements (number pill, icon-only pin state, etc).
        .accessibilityLabel(ws.name)
        .accessibilityValue(workspaceRowAccessibilityValue(ws: ws, busy: busy, checked: checked, pinned: pinned))
        .accessibilityIdentifier("sidebar.workspaceRow.\(ws.id.value.uuidString)")
        .onDrag {
            vm.draggingWorkspaceID = ws.id
            return NSItemProvider(object: ws.id.value.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: WorkspaceDropDelegate(vm: vm, target: ws))
        .contextMenu {
            let mode = SidebarViewModel.sidebarContextMenuMode(
                clickedID: ws.id,
                selectedIDs: vm.selectedWorkspaceIDs
            )
            if mode.isMulti {
                // Multi-select context menu: batch actions for all selected workspaces.
                Button { vm.pinSelectedWorkspaces(true) } label: {
                    Label("Pin \(mode.count) Workspaces", systemImage: "pin")
                }
                Button { vm.pinSelectedWorkspaces(false) } label: {
                    Label("Unpin \(mode.count) Workspaces", systemImage: "pin.slash")
                }
                Divider()
                Button("Remove \(mode.count) Workspaces\u{2026}", role: .destructive) {
                    vm.removeSelectedWorkspaces()
                }
            } else {
                // Single-row context menu: per-workspace actions.
                Button { vm.setWorkspacePinned(ws, !pinned) } label: {
                    Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin")
                }
                Divider()
                Button { vm.openWorkspaceInNewWindow(ws) } label: {
                    Label("Open in New Window", systemImage: "macwindow")
                }
                Button { vm.openWorkspaceInFinder(ws) } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
                Divider()
                Button("Rename\u{2026}") { vm.renameWorkspace(ws) }
                Button("Edit description\u{2026}") { vm.editDescription(ws) }
                Menu("Color") {
                    Button { vm.setWorkspaceColor(ws, "") } label: {
                        TabColorMenuLabel.none
                    }
                    ForEach(TabColor.allCases, id: \.self) { c in
                        Button { vm.setWorkspaceColor(ws, c.rawValue) } label: {
                            TabColorMenuLabel(c)
                        }
                    }
                }
                Divider()
                Button("Remove", role: .destructive) { vm.removeWorkspace(ws) }
            }
        }
    }
}

private struct TabColorMenuLabel: View {
    let title: String
    let swatchImage: NSImage

    init(_ color: TabColor) {
        self.title = color.label
        self.swatchImage = Self.swatchImage(hex: color.hex)
    }

    private init(title: String, swatchImage: NSImage) {
        self.title = title
        self.swatchImage = swatchImage
    }

    static var none: TabColorMenuLabel {
        TabColorMenuLabel(title: "None", swatchImage: noneSwatchImage())
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(nsImage: swatchImage)
                .renderingMode(.original)
        }
    }

    private static func swatchImage(hex: UInt32) -> NSImage {
        menuImage { rect in
            let path = NSBezierPath(
                roundedRect: rect.insetBy(dx: 2, dy: 2),
                xRadius: 3,
                yRadius: 3
            )
            NSColor(hex: hex).setFill()
            path.fill()
            DS.NS.lineStrong.withAlphaComponent(0.75).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private static func noneSwatchImage() -> NSImage {
        menuImage { rect in
            let box = NSBezierPath(
                roundedRect: rect.insetBy(dx: 2, dy: 2),
                xRadius: 3,
                yRadius: 3
            )
            DS.NS.textTertiary.withAlphaComponent(0.9).setStroke()
            box.lineWidth = 1
            box.stroke()

            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + 4, y: rect.minY + 4))
            slash.line(to: NSPoint(x: rect.maxX - 4, y: rect.maxY - 4))
            slash.lineWidth = 1.25
            slash.stroke()
        }
    }

    private static func menuImage(draw: @escaping (NSRect) -> Void) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            draw(rect)
            return true
        }
        image.isTemplate = false
        return image
    }
}

private struct WorkspaceDropDelegate: DropDelegate {
    @ObservedObject var vm: SidebarViewModel
    let target: Workspace

    func dropEntered(info: DropInfo) {
        guard vm.draggingWorkspaceID != nil, vm.draggingWorkspaceID != target.id else {
            vm.dropTargetWorkspaceID = nil
            return
        }
        // UX-MAC_SHELL_WINDOW-012: show an insertion line on hover and
        // commit the reorder on drop, rather than shuffling rows live.
        vm.dropTargetWorkspaceID = target.id
    }

    func dropExited(info: DropInfo) {
        if vm.dropTargetWorkspaceID == target.id {
            vm.dropTargetWorkspaceID = nil
        }
        vm.dragScrollEdge = 0
    }

    func performDrop(info: DropInfo) -> Bool {
        if let dragged = vm.draggingWorkspaceID, dragged != target.id {
            vm.reorderWorkspace(dragged, before: target.id)
        }
        vm.draggingWorkspaceID = nil
        vm.dropTargetWorkspaceID = nil
        vm.dragScrollEdge = 0
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // :18 -- Edge auto-scroll: while the user holds a drag near the top or
        // bottom of the sidebar's content window, SidebarRootView's scroll timer
        // fires and scrolls toward the edge.
        //
        // Strategy: convert the current mouse screen position into window Y,
        // use the key window's content height as a proxy for the scrollable
        // region height. The 40-pt edge zone matches typical row height so
        // one-row proximity triggers the scroll.
        if let window = NSApp.keyWindow {
            let screenPt = NSEvent.mouseLocation
            let windowPt = window.convertPoint(fromScreen: screenPt)
            let contentH = window.contentView?.bounds.height ?? window.frame.height
            // pointerY in top-left-origin space: flip AppKit's bottom-origin Y.
            let pointerY = contentH - windowPt.y
            vm.dragScrollEdge = SidebarRootView.autoScrollDirection(
                pointerY: pointerY,
                viewHeight: contentH,
                edgeZone: 40
            )
        } else {
            vm.dragScrollEdge = 0
        }
        return DropProposal(operation: .move)
    }
}

private struct NonAutoFocusTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    /// Set to `true` to programmatically focus the field (e.g. Cmd+F); resets to `false` once handled.
    @Binding var focusRequest: Bool
    let accessibilityIdentifier: String

    func makeNSView(context: Context) -> ManualFocusTextField {
        let field = ManualFocusTextField()
        field.placeholderString = placeholder
        field.stringValue = text
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = NSColor(DS.Palette.text)
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor(DS.Palette.textTertiary)]
        )
        field.setAccessibilityIdentifier(accessibilityIdentifier)
        return field
    }

    func updateNSView(_ field: ManualFocusTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.focusRequest = $focusRequest
        field.placeholderString = placeholder
        field.setAccessibilityIdentifier(accessibilityIdentifier)
        if field.stringValue != text {
            field.stringValue = text
        }
        if focusRequest {
            field.programmaticFocus()
            let resetRequest = $focusRequest
            DispatchQueue.main.async { resetRequest.wrappedValue = false }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, focusRequest: $focusRequest)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var focusRequest: Binding<Bool>

        init(text: Binding<String>, focusRequest: Binding<Bool>) {
            self.text = text
            self.focusRequest = focusRequest
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }

    final class ManualFocusTextField: NSTextField {
        private var allowManualFocus = false

        override var acceptsFirstResponder: Bool {
            allowManualFocus
        }

        /// Programmatically grant focus without a mouse event (e.g. Cmd+F keyboard shortcut).
        func programmaticFocus() {
            allowManualFocus = true
            window?.makeFirstResponder(self)
        }

        override func mouseDown(with event: NSEvent) {
            allowManualFocus = true
            super.mouseDown(with: event)
        }

        override func resignFirstResponder() -> Bool {
            allowManualFocus = false
            return super.resignFirstResponder()
        }
    }
}

@MainActor
public final class SidebarView: NSObject {
    public let view: NSView
    public weak var context: AppContext?
    public weak var router: AppCommandRouter?
    private let viewModel: SidebarViewModel
    private let host: NSHostingView<SidebarRootView>
    private var settingsController: SettingsWindowController?
    private var accountController: AccountWindowController?
    private let updater: AppUpdateChecking?
    /// Main window mounts Schedule Tasks in the workspace content column.
    public var onPresentScheduledTasks: (() -> Void)?
    /// Fired when a workspace is selected so main content leaves Schedule Tasks.
    public var onWorkspaceContentActivated: (() -> Void)? {
        get { viewModel.onWorkspaceContentActivated }
        set { viewModel.onWorkspaceContentActivated = newValue }
    }

    public init(context: AppContext, router: AppCommandRouter, updater: AppUpdateChecking? = nil) {
        self.context = context
        self.router = router
        self.updater = updater
        self.viewModel = SidebarViewModel(context: context, router: router, updateChecker: updater)
        let h = NSHostingView(rootView: SidebarRootView(vm: viewModel))
        h.translatesAutoresizingMaskIntoConstraints = false
        // NSHostingView is opaque by default; let the vibrancy show.
        h.wantsLayer = true
        h.layer?.backgroundColor = NSColor.clear.cgColor
        RemoteCodeAppearance.apply(to: h)
        self.host = h
        // Subtle Liquid Glass: an under-window vibrancy material behind
        // the translucent SwiftUI sidebar. Chrome only — per design rules
        // glass never goes on main content.
        let container = NSVisualEffectView()
        container.material = .sidebar
        container.blendingMode = .behindWindow
        container.state = .active
        container.translatesAutoresizingMaskIntoConstraints = false
        RemoteCodeAppearance.apply(to: container)
        container.addSubview(h)
        NSLayoutConstraint.activate([
            h.topAnchor.constraint(equalTo: container.topAnchor),
            h.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            h.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            h.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        self.view = container
        super.init()
        h.rootView = SidebarRootView(
            vm: viewModel,
            onOpenSettings: { [weak self] in self?.showSettings() },
            onOpenAccount: { [weak self] in self?.showAccount() },
            onOpenScheduledTasks: { [weak self] in self?.showScheduledTasks() }
        )
    }

    public func setScheduledTasksSelected(_ selected: Bool) {
        viewModel.isScheduledTasksSelected = selected
        if selected {
            // Visual deselect of all workspace rows while Schedule Tasks is active.
            viewModel.selectedWorkspaceID = nil
            viewModel.selectedWorkspaceIDs.removeAll()
            viewModel.clearSelectionAnchorForShellDestination()
        }
    }

    public func refresh() {
        viewModel.reload()
    }

    public func disableInsomniaForAppClose() {
        viewModel.disableInsomniaForAppClose()
    }

    @objc private func showSettings() {
        guard let context else { return }
        let controller = settingsController ?? SettingsWindowController(context: context, updater: updater)
        settingsController = controller
        if let window = view.window {
            controller.show(attachedTo: window)
        } else {
            controller.show()
        }
    }

    @objc private func showAccount() {
        guard let context else { return }
        let controller = accountController ?? AccountWindowController(context: context)
        accountController = controller
        if let window = view.window {
            controller.show(attachedTo: window)
        } else {
            controller.show()
        }
    }

    @objc private func showScheduledTasks() {
        // Prefer the main content column (same place workspaces open). Fall
        // back to a detached window only if the shell presenter is missing.
        if let onPresentScheduledTasks {
            onPresentScheduledTasks()
            return
        }
        guard let context, let router else { return }
        let controller = ScheduledTasksWindowController(context: context, router: router)
        controller.show()
    }
}
