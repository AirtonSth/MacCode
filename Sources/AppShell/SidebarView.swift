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
}

@MainActor
public final class SidebarViewModel: ObservableObject {
    public enum InsomniaBatteryDecision {
        case disable
        case keepEnabled
    }

    public typealias InsomniaBatteryPrompt = @MainActor () -> InsomniaBatteryDecision
    public typealias TokenSaverModelValidationProvider = @MainActor () -> TokenSaverModelValidation
    public typealias TokenSaverModelDownloadHandler = @MainActor (
        _ progress: @escaping @MainActor (TokenSaverModelDownloadState) -> Void
    ) async throws -> TokenSaverModelManifest

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
    @Published public var selectedWorkspaceID: WorkspaceID?
    @Published public var selectedWorkspaceIDs: Set<WorkspaceID> = []
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
    @Published public private(set) var tokenSaverUsageSnapshot: TokenSaverUsageSnapshot = .empty()
    @Published public var showsTokenSaverModelDownload = false
    @Published public private(set) var tokenSaverModelDownloadState: TokenSaverModelDownloadState = .idle
    public var draggingWorkspaceID: WorkspaceID?
    /// UX-MAC_SHELL_WINDOW-012: the row the drag is currently hovering,
    /// so the list can draw an insertion line instead of reordering live.
    @Published public var dropTargetWorkspaceID: WorkspaceID?
    private var selectionAnchorID: WorkspaceID?
    private var privateAccountObserver: NSObjectProtocol?
    private var tokenSaverUsageObserver: NSObjectProtocol?
    private let updateChecker: AppUpdateChecking?
    private let settingsStore: SettingsStore
    private let insomniaPower: InsomniaPowerManaging
    private let powerMonitor: ExternalPowerMonitoring
    private let insomniaBatteryPrompt: InsomniaBatteryPrompt
    private let tokenSaverModelValidationProvider: TokenSaverModelValidationProvider?
    private let tokenSaverModelDownloadHandler: TokenSaverModelDownloadHandler?
    private var lastPowerState: ExternalPowerState
    private var showingInsomniaBatteryPrompt = false
    private var tokenSaverModelDownloadTask: Task<TokenSaverModelManifest, Error>?

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
        tokenSaverModelDownloadHandler: TokenSaverModelDownloadHandler? = nil
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
            Task { @MainActor in viewModel.reloadTokenSaver() }
        }
        self.updateChecker?.onAvailabilityChanged = { [weak self] availability in
            self?.updateAvailability = availability
        }
        self.powerMonitor.onPowerStateChanged = { [weak self] state in
            self?.handleExternalPowerStateChanged(state)
        }
        self.powerMonitor.start()
        reload()
        reloadInsomnia()
        reloadTokenSaver()
    }

    deinit {
        if let privateAccountObserver {
            NotificationCenter.default.removeObserver(privateAccountObserver)
        }
        if let tokenSaverUsageObserver {
            NotificationCenter.default.removeObserver(tokenSaverUsageObserver)
        }
        tokenSaverModelDownloadTask?.cancel()
        powerMonitor.stop()
        insomniaPower.releaseProcessAssertions()
    }

    public func reload() {
        guard let ctx = context else { return }
        let loaded = (try? router?.listWorkspaces()) ?? ctx.state.window.workspaces.compactMap { ctx.state.workspaces[$0] }
        workspaces = loaded
        selectedWorkspaceID = ctx.state.window.selectedWorkspaceID
        selectedWorkspaceIDs = selectedWorkspaceIDs.intersection(Set(workspaces.map(\.id)))
        reloadPrivateAccount()
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

    private func reloadTokenSaver() {
        let settings = settingsStore.load()
        tokenSaverEnabled = settings.tokenSaverEnabled
        if let context {
            tokenSaverUsageSnapshot = TokenSaverUsageStore(
                appSupportDirectory: context.appSupportDirectory
            ).load()
        } else {
            tokenSaverUsageSnapshot = .empty()
        }
    }

    public func refreshTokenSaverAccountUsageForDetails() {
        context?.refreshTokenSaverAccountUsage(reason: "details")
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
        guard privateAccountUser?.subscribed == true else { return }
        if !enabled {
            tokenSaverEnabled = false
            settingsStore.update {
                $0.tokenSaverEnabled = false
            }
            context?.tokenSaverDistillServiceController.stop()
            return
        }
        let validation = validateTokenSaverModel()
        guard validation.state == .installed else {
            beginTokenSaverModelDownload(reason: validation.reason)
            return
        }
        tokenSaverEnabled = true
        settingsStore.update {
            $0.tokenSaverEnabled = true
        }
        refreshTokenSaverDistillService(modelValidation: validation)
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

    private func validateTokenSaverModel() -> TokenSaverModelValidation {
        if let tokenSaverModelValidationProvider {
            return tokenSaverModelValidationProvider()
        }
        guard let context else {
            return TokenSaverModelValidation(state: .missing, reason: "app support unavailable")
        }
        return TokenSaverModelInstaller(appSupportDirectory: context.appSupportDirectory).validateInstalledModel()
    }

    private func beginTokenSaverModelDownload(reason: String?) {
        tokenSaverModelDownloadTask?.cancel()
        tokenSaverModelDownloadState = .required(reason: reason)
        showsTokenSaverModelDownload = true

        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            do {
                let manifest = try await self.downloadTokenSaverModel { [weak self] state in
                    self?.tokenSaverModelDownloadState = state
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
                self.tokenSaverModelDownloadState = TokenSaverModelDownloadState(
                    phase: .failed,
                    downloadedBytes: self.tokenSaverModelDownloadState.downloadedBytes,
                    expectedBytes: self.tokenSaverModelDownloadState.expectedBytes,
                    statusText: "Download failed",
                    errorMessage: String(describing: error)
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
        return try await downloader.downloadApprovedModel { state in
            Task { @MainActor in
                progress(state)
            }
        }
    }

    private func refreshTokenSaverDistillService(modelValidation: TokenSaverModelValidation) {
        guard let context else { return }
        context.tokenSaverDistillServiceController.startIfEligible(
            session: PrivateAccountSessionStore(repo: context.settingsRepo).load(),
            settings: settingsStore.load(),
            modelValidation: modelValidation
        )
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
        try? router?.selectWorkspace(wid)
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
        guard let start = workspaces.firstIndex(where: { $0.id == anchor }),
              let end = workspaces.firstIndex(where: { $0.id == id }) else {
            selectedWorkspaceIDs.insert(id)
            selectionAnchorID = id
            return
        }
        let range = start <= end ? start...end : end...start
        selectedWorkspaceIDs = Set(range.map { workspaces[$0].id })
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
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            _ = createWorkspace(fromFolder: url)
        }
    }

    @discardableResult
    public func createWorkspace(fromFolder url: URL) -> Bool {
        guard let router else { return false }
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

    private func prompt(title: String, message: String, initial: String, multiline: Bool = false) -> String? {
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
        return alert.runModal() == .alertFirstButtonReturn
            ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
    }

    public func renameWorkspace(_ ws: Workspace) {
        guard let name = prompt(title: "Rename workspace",
                                message: "New name for “\(ws.name)”.",
                                initial: ws.name), !name.isEmpty else { return }
        try? router?.renameWorkspace(ws.id, name)
    }

    public func editDescription(_ ws: Workspace) {
        let current = ws.metadata["description"] ?? ""
        guard let text = prompt(title: "Workspace description",
                                message: "Optional note for “\(ws.name)”.",
                                initial: current,
                                multiline: true) else { return }
        try? router?.setWorkspaceDescription(ws.id, text)
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

    public func reorderWorkspace(_ dragged: WorkspaceID, before target: WorkspaceID) {
        guard dragged != target,
              let targetIndex = workspaces.firstIndex(where: { $0.id == target }) else { return }
        try? router?.reorderWorkspace(dragged, position: targetIndex)
        draggingWorkspaceID = nil
        dropTargetWorkspaceID = nil
        reload()
    }

    public func removeWorkspace(_ ws: Workspace) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove “\(ws.name)”?"
        alert.informativeText = "This removes the workspace and its tabs from RemoteCode. Files on disk are not touched."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            try? router?.closeWorkspace(ws.id)
        }
    }

    public func removeSelectedWorkspaces() {
        let ids = selectedWorkspaceIDs
        guard !ids.isEmpty else { return }
        let names = workspaces.filter { ids.contains($0.id) }.map(\.name)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(ids.count) workspaces?"
        alert.informativeText = "This removes the selected workspaces and their tabs from RemoteCode. Files on disk are not touched.\n\n" + names.joined(separator: "\n")
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? router?.closeWorkspaces(Array(ids))
        selectedWorkspaceIDs.removeAll()
        selectionAnchorID = nil
        reload()
    }
}

public struct SidebarRootView: View {
    private enum TokenSaverUsageScope: String, CaseIterable {
        case currentSession
        case week
    }

    @ObservedObject var vm: SidebarViewModel
    @State private var showsInsomniaOptions = false
    @State private var showsTokenSaverDetails = false
    @State private var tokenSaverDetailsScope: TokenSaverUsageScope = .week
    private let onOpenSettings: () -> Void
    private let onOpenAccount: () -> Void

    public init(
        vm: SidebarViewModel,
        onOpenSettings: @escaping () -> Void = {},
        onOpenAccount: @escaping () -> Void = {}
    ) {
        self.vm = vm
        self.onOpenSettings = onOpenSettings
        self.onOpenAccount = onOpenAccount
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
                        ForEach(rows, id: \.id) { ws in
                            workspaceRow(ws)
                        }
                    }
                }
                .padding(.horizontal, DS.Space.sm)
            }
            .frame(maxHeight: .infinity)

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
        .sheet(isPresented: $vm.showsTokenSaverModelDownload) {
            TokenSaverModelDownloadModal(
                state: vm.tokenSaverModelDownloadState,
                onCancel: { vm.cancelTokenSaverModelDownload() }
            )
        }
    }

    private var workspaceFilterField: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(DS.Palette.textTertiary)
            NonAutoFocusTextField(
                placeholder: "Filter workspaces",
                text: $vm.filterText,
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

    private func sidebarActionRow(symbol: String, title: String, isEmphasized: Bool = false) -> some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: isEmphasized ? .semibold : .regular))
                .frame(width: 20, height: 20)
                .foregroundColor(isEmphasized ? DS.Palette.warning : DS.Palette.text)
            Text(title)
                .font(DS.Font.body)
                .fontWeight(isEmphasized ? .semibold : .regular)
                .foregroundColor(isEmphasized ? DS.Palette.warning : DS.Palette.text)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.sm)
        .frame(height: 42)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(isEmphasized ? DS.Palette.warning.opacity(0.16) : Color.white.opacity(0.001))
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
    }

    private var tokenSaverCompactControl: some View {
        Button {
            toggleTokenSaverDetails(refreshWhenOpening: true)
        } label: {
            TokenSaverActivityRings(values: tokenSaverActivityRingValues)
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
        }
        showsTokenSaverDetails = willOpen
    }

    private var tokenSaverPillText: String {
        guard let user = vm.privateAccountUser else { return "Sign in" }
        guard user.subscribed else { return "Upgrade" }
        return vm.tokenSaverEnabled ? "Details" : "Enable"
    }

    private var tokenSaverHeadline: String {
        guard let user = vm.privateAccountUser else { return "Track Claude + Codex savings" }
        let used = vm.tokenSaverUsageSnapshot.usedTokens
        if user.subscribed {
            if vm.tokenSaverEnabled {
                let saved = vm.tokenSaverUsageSnapshot.measuredSavedTokens
                return saved > 0 ? "Saved \(Self.formatTokenCount(saved)) tokens" : "Tracking after next run"
            }
            return "Enable savings"
        }
        let potential = TokenSaverUsageStore.estimatePotentialSavings(usedTokens: used)
        return potential > 0 ? "Save ~\(Self.formatTokenCount(potential)) tokens" : "Savings estimate ready"
    }

    private var tokenSaverSubtitle: String {
        guard let user = vm.privateAccountUser else { return "Sign in to track account usage" }
        let used = vm.tokenSaverUsageSnapshot.usedTokens
        if user.subscribed {
            return used > 0 ? "Used \(Self.formatTokenCount(used)) in Claude + Codex" : "Local MLX model first enable"
        }
        return used > 0 ? "Used \(Self.formatTokenCount(used)) in Claude + Codex" : "Subscribe to activate local savings"
    }

    private var tokenSaverHelpText: String {
        "Token Saver shows Claude and Codex usage plus saved or potential tokens. Paid users can enable the local MLX model."
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
        tokenSaverActivityRingValues(for: vm.tokenSaverUsageSnapshot, scope: .week)
    }

    private func tokenSaverActivityRingValues(
        for snapshot: TokenSaverUsageSnapshot,
        scope: TokenSaverUsageScope
    ) -> TokenSaverActivityRings.Values {
        let claude = tokenSaverProviderUsage(.claude, in: snapshot)
        let codex = tokenSaverProviderUsage(.codex, in: snapshot)
        return TokenSaverActivityRings.Values(
            tokenSaverProgress: tokenSaverSavingsProgress(for: snapshot, scope: scope),
            claudeUsedProgress: tokenSaverUsedLimitProgress(for: claude, provider: .claude, scope: scope) ?? 0,
            codexUsedProgress: tokenSaverUsedLimitProgress(for: codex, provider: .codex, scope: scope) ?? 0
        )
    }

    private var tokenSaverActivityAccessibilityValue: String {
        let snapshot = vm.tokenSaverUsageSnapshot
        let claude = tokenSaverProviderUsage(.claude, in: snapshot)
        let codex = tokenSaverProviderUsage(.codex, in: snapshot)
        return [
            tokenSaverSavingsSummary(for: snapshot, scope: .week),
            "\(tokenSaverLimitScopeTitle(for: .week))",
            "Claude Code used \(tokenSaverUsedLimitText(for: claude, provider: .claude, scope: .week))",
            "Codex used \(tokenSaverUsedLimitText(for: codex, provider: .codex, scope: .week))"
        ].joined(separator: ", ")
    }

    private func tokenSaverLimitScopeTitle(for scope: TokenSaverUsageScope) -> String {
        switch scope {
        case .currentSession: return "current session"
        case .week: return "week"
        }
    }

    private func tokenSaverScopeTitle(_ scope: TokenSaverUsageScope) -> String {
        switch scope {
        case .currentSession: return "Current Session"
        case .week: return "Week"
        }
    }

    private func tokenSaverScopeUsedTokens(in snapshot: TokenSaverUsageSnapshot, scope: TokenSaverUsageScope) -> Int {
        switch scope {
        case .currentSession:
            return snapshot.providers.reduce(0) { $0 + $1.currentSessionTokens }
        case .week:
            return snapshot.usedTokens
        }
    }

    private func tokenSaverProviderUsage(
        _ provider: AgentProvider,
        in snapshot: TokenSaverUsageSnapshot
    ) -> TokenSaverProviderUsage {
        snapshot.providers.first { $0.provider == provider } ?? TokenSaverProviderUsage(provider: provider)
    }

    private func tokenSaverSavingsProgress(
        for snapshot: TokenSaverUsageSnapshot,
        scope: TokenSaverUsageScope
    ) -> Double {
        let saved = tokenSaverSavedOrPotential(in: snapshot, scope: scope)
        let used = tokenSaverScopeUsedTokens(in: snapshot, scope: scope)
        return tokenSaverRingProgress(numerator: saved, denominator: max(used + saved, 1))
    }

    private func tokenSaverSavedOrPotential(
        in snapshot: TokenSaverUsageSnapshot,
        scope: TokenSaverUsageScope
    ) -> Int {
        if vm.privateAccountUser?.subscribed == true && vm.tokenSaverEnabled {
            switch scope {
            case .currentSession:
                return 0
            case .week:
                return snapshot.measuredSavedTokens
            }
        }
        return TokenSaverUsageStore.estimatePotentialSavings(
            usedTokens: tokenSaverScopeUsedTokens(in: snapshot, scope: scope)
        )
    }

    private func tokenSaverSavingsSummary(
        for snapshot: TokenSaverUsageSnapshot,
        scope: TokenSaverUsageScope
    ) -> String {
        let prefix = vm.privateAccountUser?.subscribed == true && vm.tokenSaverEnabled ? "Saved" : "Could save"
        return "\(prefix) \(Self.formatTokenCount(tokenSaverSavedOrPotential(in: snapshot, scope: scope)))"
    }

    private func tokenSaverUsedLimitProgress(
        for usage: TokenSaverProviderUsage,
        provider: AgentProvider,
        scope: TokenSaverUsageScope
    ) -> Double? {
        switch scope {
        case .currentSession:
            if let currentSessionUsedPercent = usage.currentSessionUsedPercent {
                return min(max(currentSessionUsedPercent / 100.0, 0), 1)
            }
            guard usage.currentSessionLimitTokens > 0 else { return nil }
            return tokenSaverRingProgress(
                numerator: usage.currentSessionTokens,
                denominator: usage.currentSessionLimitTokens
            )
        case .week:
            if let weeklyUsedPercent = usage.weeklyUsedPercent {
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
            if let currentSessionUsedPercent = usage.currentSessionUsedPercent {
                return "Session used \(Self.formatPercent(currentSessionUsedPercent / 100.0))"
            }
            guard usage.currentSessionLimitTokens > 0 else { return "Session usage not loaded" }
            let usedProgress = tokenSaverRingProgress(
                numerator: usage.currentSessionTokens,
                denominator: usage.currentSessionLimitTokens
            )
            return "Session used \(Self.formatPercent(usedProgress))"
        case .week:
            if let weeklyUsedPercent = usage.weeklyUsedPercent {
                return "Weekly used \(Self.formatPercent(weeklyUsedPercent / 100.0))"
            }
            let weeklyLimit = max(usage.estimatedRawTokens, tokenSaverDefaultWeeklyLimitTokens(for: provider), 1)
            guard usage.actualProviderTokens > 0 else { return "Weekly usage not loaded" }
            return "Weekly used \(Self.formatTokenCount(usage.actualProviderTokens)) / \(Self.formatTokenCount(weeklyLimit))"
        }
    }

    private func tokenSaverDefaultWeeklyLimitTokens(for provider: AgentProvider) -> Int {
        switch provider {
        case .claude:
            return 1_000_000
        case .codex:
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

            Picker("Usage scope", selection: $tokenSaverDetailsScope) {
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
                tokenSaverProviderRow(provider: .claude)
                tokenSaverProviderRow(provider: .codex)
            }

            Text(tokenSaverPlanValueText)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.md)
        .frame(width: 350, alignment: .leading)
        .background(DS.Palette.surface)
        .accessibilityIdentifier("sidebar.tokenSaver.details")
    }

    private var tokenSaverDetailsActivityChart: some View {
        let snapshot = tokenSaverDetailsSnapshot
        return HStack(alignment: .center, spacing: DS.Space.lg) {
            TokenSaverActivityRings(values: tokenSaverActivityRingValues(for: snapshot, scope: tokenSaverDetailsScope))
                .frame(width: 104, height: 104)
                .accessibilityLabel("Token Saver usage rings")
                .accessibilityValue(tokenSaverDetailsChartAccessibilityValue(for: snapshot))

            VStack(alignment: .leading, spacing: DS.Space.sm) {
                tokenSaverRingLegendRow(
                    color: DS.Palette.success,
                    label: "Token Saver",
                    value: tokenSaverSavingsSummary(for: snapshot, scope: tokenSaverDetailsScope)
                )
                tokenSaverRingLegendRow(
                    color: DS.Palette.textSecondary,
                    label: "Used",
                    value: Self.formatTokenCount(tokenSaverScopeUsedTokens(in: snapshot, scope: tokenSaverDetailsScope))
                )
                tokenSaverRingLegendRow(
                    color: tokenSaverProviderColor(.claude),
                    label: tokenSaverProviderTitle(.claude),
                    value: tokenSaverLimitSummary(provider: .claude, in: snapshot, scope: tokenSaverDetailsScope)
                )
                tokenSaverRingLegendRow(
                    color: tokenSaverProviderColor(.codex),
                    label: tokenSaverProviderTitle(.codex),
                    value: tokenSaverLimitSummary(provider: .codex, in: snapshot, scope: tokenSaverDetailsScope)
                )
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
        if vm.tokenSaverUsageSnapshot.period == .sevenDays {
            return vm.tokenSaverUsageSnapshot
        }
        guard let context = vm.context else { return .empty() }
        return TokenSaverUsageStore(appSupportDirectory: context.appSupportDirectory).load()
    }

    private var tokenSaverDetailsSavedOrPotential: Int {
        tokenSaverSavedOrPotential(in: tokenSaverDetailsSnapshot, scope: tokenSaverDetailsScope)
    }

    private var tokenSaverPlanValueText: String {
        guard let user = vm.privateAccountUser else {
            return "Sign in to track Claude and Codex usage before enabling Token Saver."
        }
        guard user.subscribed else {
            return "Subscribe to start saving these tokens automatically."
        }
        if vm.tokenSaverEnabled {
            return "Your plan has already reduced provider usage by \(Self.formatTokenCount(tokenSaverDetailsSavedOrPotential)) tokens."
        }
        return "Enable Token Saver to run the approved local MLX model and start reducing provider usage."
    }

    private func tokenSaverProviderRow(provider: AgentProvider) -> some View {
        let snapshot = tokenSaverDetailsSnapshot
        let usage = tokenSaverProviderUsage(provider, in: snapshot)
        let value = vm.privateAccountUser?.subscribed == true && vm.tokenSaverEnabled
            ? usage.measuredSavedTokens
            : TokenSaverUsageStore.estimatePotentialSavings(usedTokens: usage.actualProviderTokens)
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
                Text((vm.privateAccountUser?.subscribed == true && vm.tokenSaverEnabled ? "Saved " : "Could save ") + Self.formatTokenCount(value))
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.success)
                    .monospacedDigit()
                    .lineLimit(1)
            }
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
            "Showing \(tokenSaverLimitScopeTitle(for: tokenSaverDetailsScope))"
        ].joined(separator: ", ")
    }

    private func tokenSaverProviderColor(_ provider: AgentProvider) -> Color {
        switch provider {
        case .claude:
            return Color(nsColor: .systemOrange)
        case .codex:
            return Color(nsColor: .systemBlue)
        }
    }

    private func tokenSaverProviderTitle(_ provider: AgentProvider) -> String {
        switch provider {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    private static func formatTokenCount(_ value: Int) -> String {
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

    private static func formatPercent(_ progress: Double) -> String {
        "\(Int((min(max(progress, 0), 1) * 100).rounded()))%"
    }

    struct TokenSaverActivityRings: View {
        struct Values: Equatable {
            let tokenSaverProgress: Double
            let claudeUsedProgress: Double
            let codexUsedProgress: Double
        }

        let values: Values

        var body: some View {
            GeometryReader { proxy in
                let side = max(min(proxy.size.width, proxy.size.height), 1)
                scaledContent(side: side)
                    .frame(width: side, height: side)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
        }

        private func scaledContent(side: CGFloat) -> some View {
            let scale = max(side / 34.0, 0.1)
            return ZStack {
                TokenSaverActivityRing(progress: values.tokenSaverProgress, color: DS.Palette.success, inset: 2 * scale, lineWidth: 4.0 * scale)
                TokenSaverActivityRing(progress: values.claudeUsedProgress, color: Color(nsColor: .systemOrange), inset: 8.2 * scale, lineWidth: 3.2 * scale)
                TokenSaverActivityRing(progress: values.codexUsedProgress, color: Color(nsColor: .systemBlue), inset: 13.8 * scale, lineWidth: 2.0 * scale)
            }
        }
    }

    private struct TokenSaverActivityRing: View {
        let progress: Double
        let color: Color
        let inset: CGFloat
        let lineWidth: CGFloat

        var body: some View {
            ZStack {
                TokenSaverActivityRingShape(progress: 1)
                    .stroke(
                        color.opacity(0.18),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )
                TokenSaverActivityRingShape(progress: progress)
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )
            }
            .padding(inset)
        }
    }

    private struct TokenSaverActivityRingShape: Shape {
        let progress: Double

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let bounded = min(max(progress, 0), 1)
            guard bounded > 0 else { return path }
            path.addArc(
                center: CGPoint(x: rect.midX, y: rect.midY),
                radius: min(rect.width, rect.height) / 2,
                startAngle: .degrees(-88),
                endAngle: .degrees((360 * bounded) - 88),
                clockwise: false
            )
            return path
        }
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
        .frame(width: 36, height: 24)
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
        let onCancel: () -> Void

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
                        Text(TokenSaverModelManifest.approvedModelID)
                            .font(DS.Font.monoSmall)
                            .foregroundColor(DS.Palette.textSecondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    infoRow("Source", "huggingface.co/samuelfaj/distill-1.7B-4bit-MLX")
                    infoRow("Status", state.statusText)
                    infoRow("Progress", progressText)
                    if let error = state.errorMessage, !error.isEmpty {
                        Text(error)
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                progressView
                    .accessibilityLabel("Token Saver model download progress")
                    .accessibilityValue(progressText)

                HStack {
                    Spacer()
                    Button("Cancel") {
                        onCancel()
                    }
                    .keyboardShortcut(.cancelAction)
                    .frame(minWidth: 88, minHeight: 44)
                }
            }
            .padding(DS.Space.xxl)
            .frame(width: 460)
            .background(DS.Palette.surface)
        }

        private var progressView: some View {
            Group {
                if let fraction = state.fractionCompleted {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
            }
            .tint(DS.Palette.success)
        }

        private var progressText: String {
            let downloaded = Self.formatBytes(state.downloadedBytes)
            guard let expected = state.expectedBytes else { return downloaded }
            let percent = Int(((state.fractionCompleted ?? 0) * 100).rounded())
            return "\(downloaded) / \(Self.formatBytes(expected)) (\(percent)%)"
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

    @ViewBuilder
    private func workspaceRow(_ ws: Workspace) -> some View {
        let selected = vm.selectedWorkspaceID == ws.id
        let checked = vm.selectedWorkspaceIDs.contains(ws.id)
        let desc = ws.metadata["description"]
        let pinned = ws.metadata["pinned"] == "true"
        let busy = vm.isWorkspaceBusy(ws)
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
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
                if ws.notificationsUnread > 0 {
                    DSPill("\(ws.notificationsUnread)", tone: .accent)
                }
            }
            .padding(.horizontal, DS.Space.sm)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(checked ? DS.Palette.accent.opacity(0.22)
                          : selected ? DS.Palette.selection.opacity(0.75)
                          : Color.white.opacity(0.001))
            )
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
        .accessibilityIdentifier("sidebar.workspaceRow.\(ws.id.value.uuidString)")
        .onDrag {
            vm.draggingWorkspaceID = ws.id
            return NSItemProvider(object: ws.id.value.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: WorkspaceDropDelegate(vm: vm, target: ws))
        .contextMenu {
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
            Button("Rename…") { vm.renameWorkspace(ws) }
            Button("Edit description…") { vm.editDescription(ws) }
            Menu("Color") {
                Button("None") { vm.setWorkspaceColor(ws, "") }
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

private struct TabColorMenuLabel: View {
    let color: TabColor

    init(_ color: TabColor) {
        self.color = color
    }

    var body: some View {
        Label {
            Text(color.label)
        } icon: {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color(hex: color.hex))
                .frame(width: 12, height: 12)
        }
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
    }

    func performDrop(info: DropInfo) -> Bool {
        if let dragged = vm.draggingWorkspaceID, dragged != target.id {
            vm.reorderWorkspace(dragged, before: target.id)
        }
        vm.draggingWorkspaceID = nil
        vm.dropTargetWorkspaceID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private struct NonAutoFocusTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
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
        field.placeholderString = placeholder
        field.setAccessibilityIdentifier(accessibilityIdentifier)
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
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

    public init(context: AppContext, router: AppCommandRouter, updater: AppUpdateChecking? = nil) {
        self.context = context
        self.router = router
        self.viewModel = SidebarViewModel(context: context, router: router, updateChecker: updater)
        let h = NSHostingView(rootView: SidebarRootView(vm: viewModel))
        h.translatesAutoresizingMaskIntoConstraints = false
        // NSHostingView is opaque by default; let the vibrancy show.
        h.wantsLayer = true
        h.layer?.backgroundColor = NSColor.clear.cgColor
        self.host = h
        // Subtle Liquid Glass: an under-window vibrancy material behind
        // the translucent SwiftUI sidebar. Chrome only — per design rules
        // glass never goes on main content.
        let container = NSVisualEffectView()
        container.material = .sidebar
        container.blendingMode = .behindWindow
        container.state = .active
        container.translatesAutoresizingMaskIntoConstraints = false
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
            onOpenAccount: { [weak self] in self?.showAccount() }
        )
    }

    public func refresh() {
        viewModel.reload()
    }

    public func disableInsomniaForAppClose() {
        viewModel.disableInsomniaForAppClose()
    }

    @objc private func showSettings() {
        guard let context else { return }
        let controller = settingsController ?? SettingsWindowController(context: context)
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
}
