import AppKit
import SwiftUI
import CoreModel
import DesignSystemKit
import SocketServer
import Surfaces

@MainActor
protocol SSHTransferSurface: Surface {
    var sshTransferProfile: SSHHostProfile? { get }
    func appendSystemText(_ raw: String)
}

@MainActor
final class SSHSurface: NSObject, SSHTransferSurface {
    private let workspaceID: WorkspaceID
    private let cwd: String
    private weak var router: AppCommandRouter?
    private let terminalContainer = NSView()
    private let hostResizeHandle = DSResizeHandleView(axis: .vertical)
    private let transferDivider = DSResizeHandleView(axis: .vertical)
    private let viewModel: SSHSurfaceViewModel
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var transferWidthConstraint: NSLayoutConstraint?
    private var transferDividerWidthConstraint: NSLayoutConstraint?
    private var dragStartSidebarWidth: CGFloat?
    private var dragStartTransferWidth: CGFloat?
    private var terminal: TerminalSurface?
    private var activeTransferCount = 0
    static let hostSidebarWidthDefaultsKey = "ssh.hosts.sidebar.width.v1"
    static let transferSidebarWidthDefaultsKey = "ssh.files.sidebar.width.v1"
    static let transferSidebarExpandedDefaultsKey = "ssh.files.sidebar.expanded.v1"
    private static let transferSidebarExpandedWidth: CGFloat = 680

    private(set) var descriptor: SurfaceDescriptor
    let view: NSView

    var sshTransferProfile: SSHHostProfile? { viewModel.selectedHost }

    init(workspaceID: WorkspaceID, cwd: String, title: String, router: AppCommandRouter?) throws {
        self.workspaceID = workspaceID
        self.cwd = cwd
        self.router = router
        self.descriptor = SurfaceDescriptor(
            type: .ssh,
            title: title,
            iconName: "network",
            metadata: [
                "workspace": workspaceID.value.uuidString,
                "cwd": cwd,
                "ssh_status": "disconnected"
            ]
        )
        self.viewModel = SSHSurfaceViewModel()

        let root = AdaptiveSSHRootView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        root.layer?.backgroundColor = DS.NS.bg.cgColor

        let sidebar = NSHostingView(rootView: SSHSidebarView(vm: viewModel))
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.wantsLayer = true
        terminalContainer.layer?.backgroundColor = DS.NS.terminalBG.cgColor

        hostResizeHandle.translatesAutoresizingMaskIntoConstraints = false

        let transferSidebar = NSHostingView(rootView: SSHTransferSidebarView(vm: viewModel))
        transferSidebar.translatesAutoresizingMaskIntoConstraints = false

        transferDivider.translatesAutoresizingMaskIntoConstraints = false
        transferDivider.wantsLayer = true

        root.addSubview(sidebar)
        root.addSubview(hostResizeHandle)
        root.addSubview(terminalContainer)
        root.addSubview(transferDivider)
        root.addSubview(transferSidebar)
        let width = sidebar.widthAnchor.constraint(equalToConstant: Self.persistedHostSidebarWidth())
        let transferWidth = transferSidebar.widthAnchor.constraint(equalToConstant: 0)
        let transferDividerWidth = transferDivider.widthAnchor.constraint(equalToConstant: 0)
        self.sidebarWidthConstraint = width
        self.transferWidthConstraint = transferWidth
        self.transferDividerWidthConstraint = transferDividerWidth
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            width,

            hostResizeHandle.topAnchor.constraint(equalTo: root.topAnchor),
            hostResizeHandle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            hostResizeHandle.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            hostResizeHandle.widthAnchor.constraint(equalToConstant: DS.ResizeDivider.thickness),

            terminalContainer.topAnchor.constraint(equalTo: root.topAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: hostResizeHandle.trailingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: transferDivider.leadingAnchor),

            transferDivider.topAnchor.constraint(equalTo: root.topAnchor),
            transferDivider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            transferDivider.trailingAnchor.constraint(equalTo: transferSidebar.leadingAnchor),
            transferDividerWidth,

            transferSidebar.topAnchor.constraint(equalTo: root.topAnchor),
            transferSidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            transferSidebar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transferWidth
        ])
        self.view = root

        super.init()

        root.onSizeChanged = { [weak self] size in
            self?.applyAdaptiveHostSidebar(width: size.width, event: .resize)
        }
        hostResizeHandle.onDrag = { [weak self] delta, ended in
            self?.resizeHostSidebar(delta: delta, ended: ended)
        }
        transferDivider.onDrag = { [weak self] delta, ended in
            self?.resizeTransferSidebar(delta: delta, ended: ended)
        }
        viewModel.onRefresh = { [weak self] in self?.reloadHosts() }
        viewModel.onSave = { [weak self] draft in self?.save(draft) }
        viewModel.onConnect = { [weak self] host in self?.connect(host) }
        viewModel.onOpenNewConnection = { [weak self] host in self?.openNewConnection(host) }
        viewModel.onDelete = { [weak self] host in self?.delete(host) }
        viewModel.onSidebarCollapsedChange = { [weak self] collapsed in
            self?.setSidebarCollapsed(collapsed)
        }
        viewModel.onTransferSidebarCollapsedChange = { [weak self] collapsed in
            UserDefaults.standard.set(!collapsed, forKey: Self.transferSidebarExpandedDefaultsKey)
            self?.syncTransferSidebarWidth(animated: true)
        }
        viewModel.onTransfer = { [weak self] upload, localPath, remotePath in
            self?.runTransfer(upload: upload, localPath: localPath, remotePath: remotePath)
        }
        viewModel.onRefreshLocalFiles = { [weak self] in self?.refreshLocalFiles() }
        viewModel.onRefreshRemoteFiles = { [weak self] in self?.refreshRemoteFiles() }
        viewModel.onChooseLocalPath = { [weak self] in self?.chooseLocalTransferPath() }
        showPlaceholder()
        reloadHosts()
        syncTransferSidebarWidth(animated: false)
        applyAdaptiveHostSidebar(width: root.bounds.width, event: .structural)
    }

    private func setSidebarCollapsed(_ collapsed: Bool) {
        sidebarWidthConstraint?.constant = collapsed ? 44 : Self.persistedHostSidebarWidth()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.layoutSubtreeIfNeeded()
        }
    }

    private func applyAdaptiveHostSidebar(width: CGFloat, event: AdaptiveSidebarLayoutEvent) {
        guard width > 0 else { return }
        guard view.window != nil else { return }
        let now = Date().timeIntervalSinceReferenceDate
        let transferWidth = transferWidthConstraint?.constant ?? 0
        let decision = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: width - transferWidth,
            contentMinimumExtent: 520,
            sidebarExtent: Self.persistedHostSidebarWidth() + DS.ResizeDivider.thickness,
            currentVisible: !viewModel.sidebarCollapsed,
            intent: viewModel.hostSidebarIntent,
            event: event,
            now: now,
            lastAutomaticChange: viewModel.lastAutomaticHostSidebarChange
        )
        guard decision.isVisible == viewModel.sidebarCollapsed else { return }
        viewModel.sidebarCollapsed = !decision.isVisible
        if decision.didChangeAutomatically {
            viewModel.lastAutomaticHostSidebarChange = now
        }
    }

    private static func persistedHostSidebarWidth() -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: hostSidebarWidthDefaultsKey)
        guard stored > 0 else { return 292 }
        return min(520, max(220, stored))
    }

    private static func persistedTransferSidebarWidth() -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: transferSidebarWidthDefaultsKey)
        guard stored > 0 else { return transferSidebarExpandedWidth }
        return min(1120, max(480, stored))
    }

    private static func persistedTransferSidebarCollapsed() -> Bool {
        guard UserDefaults.standard.object(forKey: transferSidebarExpandedDefaultsKey) != nil else { return false }
        return !UserDefaults.standard.bool(forKey: transferSidebarExpandedDefaultsKey)
    }

    private func resizeHostSidebar(delta: CGFloat, ended: Bool) {
        guard !viewModel.sidebarCollapsed else { return }
        if dragStartSidebarWidth == nil {
            dragStartSidebarWidth = sidebarWidthConstraint?.constant ?? Self.persistedHostSidebarWidth()
        }
        let start = dragStartSidebarWidth ?? Self.persistedHostSidebarWidth()
        let next = min(520, max(220, start + delta))
        sidebarWidthConstraint?.constant = next
        UserDefaults.standard.set(Double(next), forKey: Self.hostSidebarWidthDefaultsKey)
        if ended {
            dragStartSidebarWidth = nil
        }
    }

    private func syncTransferSidebarWidth(animated: Bool) {
        let visible = viewModel.transferSidebarVisible
        transferDividerWidthConstraint?.constant = visible ? DS.ResizeDivider.thickness : 0
        transferWidthConstraint?.constant = visible ? (viewModel.transferSidebarCollapsed ? 44 : Self.persistedTransferSidebarWidth()) : 0
        let changes = { self.view.layoutSubtreeIfNeeded() }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                changes()
            }
        } else {
            changes()
        }
    }

    private func resizeTransferSidebar(delta: CGFloat, ended: Bool) {
        guard viewModel.transferSidebarVisible, !viewModel.transferSidebarCollapsed else { return }
        if dragStartTransferWidth == nil {
            dragStartTransferWidth = transferWidthConstraint?.constant ?? Self.persistedTransferSidebarWidth()
        }
        let start = dragStartTransferWidth ?? Self.persistedTransferSidebarWidth()
        let next = min(1120, max(480, start - delta))
        transferWidthConstraint?.constant = next
        UserDefaults.standard.set(Double(next), forKey: Self.transferSidebarWidthDefaultsKey)
        if ended {
            dragStartTransferWidth = nil
        }
    }

    private func reloadHosts() {
        do {
            viewModel.hosts = try router?.sshHostList(workspace: workspaceID) ?? []
            viewModel.error = nil
        } catch {
            viewModel.error = error.localizedDescription
        }
    }

    private func save(_ draft: SSHHostDraft) {
        let shouldConnectAfterSave = draft.id == nil
        let host = SSHHostProfile(
            id: draft.id ?? SSHHostID(),
            label: draft.resolvedLabel,
            destination: draft.destination,
            port: draft.parsedPort,
            identityFile: draft.parsedIdentityFile,
            password: draft.parsedPassword,
            options: draft.options
        )
        do {
            let saved = try router?.sshHostUpsert(host, workspace: workspaceID) ?? host
            reloadHosts()
            viewModel.showForm = false
            viewModel.editingHostID = nil
            if shouldConnectAfterSave {
                connect(saved)
            }
        } catch {
            viewModel.error = error.localizedDescription
        }
    }

    private func delete(_ host: SSHHostProfile) {
        do {
            try router?.sshHostDelete(host.id, workspace: workspaceID)
            if viewModel.selectedHost?.id == host.id {
                terminal?.close()
                terminal = nil
                descriptor.metadata["ssh_status"] = "disconnected"
                viewModel.selectedHost = nil
                viewModel.status = "Disconnected"
                viewModel.transferSidebarVisible = false
                showPlaceholder()
                syncTransferSidebarWidth(animated: true)
            }
            reloadHosts()
        } catch {
            viewModel.error = error.localizedDescription
        }
    }

    private func connect(_ host: SSHHostProfile) {
        // Surface an explicit "Connecting…" state before the blocking session
        // setup, and defer the work one run-loop turn so the spinner/status
        // actually paints instead of jumping straight to Connected/Failed
        // (UX-MAC_SSH-002).
        viewModel.status = "Connecting…"
        viewModel.error = nil
        DispatchQueue.main.async { [weak self] in
            self?.performConnect(host)
        }
    }

    private func performConnect(_ host: SSHHostProfile) {
        do {
            let saved = try router?.sshHostUpsert(host, workspace: workspaceID) ?? host
            terminal?.close()
            let next = try TerminalSurface(workspaceID: workspaceID, title: saved.label, launch: .ssh(profile: saved, cwd: cwd))
            terminal = next
            descriptor.metadata = next.descriptor.metadata
            descriptor.metadata["ssh_status"] = "connected"
            viewModel.selectedHost = saved
            viewModel.status = "Connected"
            viewModel.transferSidebarCollapsed = Self.persistedTransferSidebarCollapsed()
            viewModel.transferSidebarVisible = true
            viewModel.prepareTransferPanel(localPath: cwd, remotePath: "/")
            viewModel.error = nil
            installTerminal(next.view)
            syncTransferSidebarWidth(animated: true)
            refreshLocalFiles()
            refreshRemoteFiles()
            next.focus()
            EventBus.shared.publish(kind: "ssh.session.updated", payload: .object([
                "surface_id": .string(descriptor.id.value.uuidString),
                "profile_id": .string(saved.id.value.uuidString),
                "destination": .string(saved.destination),
                "status": .string("connected")
            ]))
            reloadHosts()
        } catch {
            viewModel.status = "Failed"
            viewModel.error = error.localizedDescription
        }
    }

    private func runTransfer(upload: Bool, localPath: String, remotePath: String) {
        let kind = upload ? "Upload" : "Download"
        let direction: SSHTransferDirection = upload ? .upload : .download
        viewModel.recordTransfer(direction: direction, localPath: localPath, remotePath: remotePath, status: .queued)
        viewModel.transferStatus = "\(kind) running"
        activeTransferCount += 1
        Task { [weak self] in
            guard let self else { return }
            // Process execution runs off the main run loop inside the router's
            // async transfer; UI updates resume here on the main actor.
            var ok = false
            do {
                let result = upload
                    ? try await self.router?.sshTransferUploadAsync(surface: self.descriptor.id, localPath: localPath, remotePath: remotePath)
                    : try await self.router?.sshTransferDownloadAsync(surface: self.descriptor.id, remotePath: remotePath, localPath: localPath)
                ok = result?.objectValue?["ok"]?.boolValue == true
                self.viewModel.transferStatus = ok ? "\(kind) completed" : "\(kind) failed"
                self.viewModel.recordTransfer(direction: direction, localPath: localPath, remotePath: remotePath, status: ok ? .successful : .failed)
            } catch {
                self.viewModel.transferStatus = "\(kind) failed"
                self.viewModel.recordTransfer(direction: direction, localPath: localPath, remotePath: remotePath, status: .failed)
                self.viewModel.error = error.localizedDescription
            }
            self.activeTransferCount -= 1
            // Coalesce listing refreshes: only refresh once the whole batch
            // (e.g. a multi-file uploadLocalSelection loop) has drained.
            if self.activeTransferCount == 0 {
                self.refreshLocalFiles()
                await self.refreshRemoteFilesAsync()
            }
        }
    }

    private func refreshLocalFiles() {
        do {
            let listing = try router?.sshFilesLocalList(path: viewModel.localSitePath)
            viewModel.applyLocalListing(listing?.objectValue ?? [:])
        } catch {
            viewModel.transferStatus = "Local list failed"
            viewModel.addTransferLog("Local: \(error.localizedDescription)")
        }
    }

    private func refreshRemoteFiles() {
        guard descriptor.metadata["ssh_status"] == "connected" else { return }
        do {
            let listing = try router?.sshFilesRemoteList(surface: descriptor.id, path: viewModel.remoteSitePath)
            viewModel.applyRemoteListing(listing?.objectValue ?? [:])
        } catch {
            viewModel.transferStatus = "Remote list failed"
            viewModel.addTransferLog("Remote: \(error.localizedDescription)")
        }
    }

    /// Async remote listing so post-transfer refreshes never block the main
    /// run loop (PERF-MAC_SSH-002). Spawns the remote shell off-thread via the
    /// router; UI updates resume on the main actor.
    private func refreshRemoteFilesAsync() async {
        guard descriptor.metadata["ssh_status"] == "connected" else { return }
        do {
            let listing = try await router?.sshFilesRemoteListAsync(surface: descriptor.id, path: viewModel.remoteSitePath)
            viewModel.applyRemoteListing(listing?.objectValue ?? [:])
        } catch {
            viewModel.transferStatus = "Remote list failed"
            viewModel.addTransferLog("Remote: \(error.localizedDescription)")
        }
    }

    private func chooseLocalTransferPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.selectLocalPath(url.path, isDirectory: url.hasDirectoryPath)
            if url.hasDirectoryPath { refreshLocalFiles() }
        }
    }

    private func openNewConnection(_ host: SSHHostProfile) {
        if terminal == nil {
            connect(host)
            return
        }
        do {
            let saved = try router?.sshHostUpsert(host, workspace: workspaceID) ?? host
            let desc = try router?.sshConnect(workspace: workspaceID, profileID: saved.id, profile: nil, title: saved.label, paneID: nil)
            if let desc {
                try router?.focusSurface(workspace: workspaceID, surface: desc.id)
            }
            viewModel.error = nil
        } catch {
            viewModel.status = "Failed"
            viewModel.error = error.localizedDescription
        }
    }

    func openNewConnectionForTesting(_ host: SSHHostProfile) {
        openNewConnection(host)
    }

    func connectForRouter(_ host: SSHHostProfile) {
        connect(host)
    }

    private func installTerminal(_ terminalView: NSView) {
        terminalContainer.subviews.forEach { $0.removeFromSuperview() }
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor)
        ])
    }

    private func showPlaceholder() {
        terminalContainer.subviews.forEach { $0.removeFromSuperview() }
        let label = NSTextField(labelWithString: "Select a saved SSH host or press + to add one.")
        label.textColor = DS.NS.textTertiary
        label.font = NSFont.systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: terminalContainer.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: terminalContainer.centerYAnchor)
        ])
    }

    func appendSystemText(_ raw: String) {
        terminal?.appendSystemText(raw)
    }

    func focus() {
        terminal?.focus()
    }

    func unfocus() {
        terminal?.unfocus()
    }

    func close() {
        terminal?.close()
    }

    func sendText(_ text: String) {
        terminal?.sendText(text)
    }

    func readText() -> String {
        terminal?.readText() ?? ""
    }

    func snapshot() -> [String: String] {
        [
            "cwd": cwd,
            "ssh_status": descriptor.metadata["ssh_status"] ?? "disconnected",
            "ssh_destination": descriptor.metadata["ssh_destination"] ?? ""
        ]
    }

    var hostSidebarWidthForTesting: CGFloat {
        sidebarWidthConstraint?.constant ?? 0
    }

    var transferSidebarWidthForTesting: CGFloat {
        transferWidthConstraint?.constant ?? 0
    }

    func setHostSidebarWidthForTesting(_ width: CGFloat) {
        sidebarWidthConstraint?.constant = min(520, max(220, width))
        UserDefaults.standard.set(Double(sidebarWidthConstraint?.constant ?? width), forKey: Self.hostSidebarWidthDefaultsKey)
    }
}

private struct SSHFileEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let kind: String
    let size: String
    let fileType: String
    let modified: String

    var isDirectory: Bool { kind == "directory" }
}

private enum SSHTransferDirection: String {
    case upload = "Upload"
    case download = "Download"
}

private enum SSHTransferState: String, CaseIterable {
    case queued = "Queued"
    case failed = "Failed"
    case successful = "Successful"
}

private struct SSHTransferQueueItem: Identifiable, Hashable {
    let id = UUID()
    let direction: SSHTransferDirection
    let localPath: String
    let remotePath: String
    let size: String
    let status: SSHTransferState
}

private struct SSHFileColumnWidths {
    var name: CGFloat = 220
    var size: CGFloat = 82
    var type: CGFloat = 104
    var modified: CGFloat = 132

    var total: CGFloat { name + size + type + modified }
}

private struct SSHQueueColumnWidths {
    var local: CGFloat = 210
    var direction: CGFloat = 86
    var remote: CGFloat = 180
    var size: CGFloat = 70
    var priority: CGFloat = 74
    var status: CGFloat = 86

    var total: CGFloat { local + direction + remote + size + priority + status }
}

@MainActor
fileprivate final class SSHSurfaceViewModel: ObservableObject {
    @Published var hosts: [SSHHostProfile] = []
    @Published var selectedHost: SSHHostProfile?
    @Published var showForm = false
    @Published var sidebarCollapsed = false {
        didSet { onSidebarCollapsedChange?(sidebarCollapsed) }
    }
    var hostSidebarIntent: AdaptiveSidebarIntent = .auto
    var lastAutomaticHostSidebarChange: TimeInterval?
    @Published var status = "Disconnected"
    @Published var error: String?
    @Published var draft = SSHHostDraft()
    @Published var editingHostID: SSHHostID?
    @Published var transferSidebarVisible = false
    @Published var transferSidebarCollapsed = false {
        didSet { onTransferSidebarCollapsedChange?(transferSidebarCollapsed) }
    }
    @Published var localSitePath = ""
    @Published var remoteSitePath = "/"
    @Published var localEntries: [SSHFileEntry] = []
    @Published var remoteEntries: [SSHFileEntry] = []
    @Published var selectedLocalEntry: SSHFileEntry?
    @Published var selectedRemoteEntry: SSHFileEntry?
    @Published var selectedLocalIDs: Set<String> = []
    @Published var selectedRemoteIDs: Set<String> = []
    @Published var transferLocalPath = ""
    @Published var transferRemotePath = ""
    @Published var transferStatus = "Ready"
    @Published var transferLogs: [String] = ["Ready"]
    @Published var queueItems: [SSHTransferQueueItem] = []
    @Published var selectedQueueState: SSHTransferState = .queued

    var onRefresh: (() -> Void)?
    var onSave: ((SSHHostDraft) -> Void)?
    var onConnect: ((SSHHostProfile) -> Void)?
    var onOpenNewConnection: ((SSHHostProfile) -> Void)?
    var onDelete: ((SSHHostProfile) -> Void)?
    var onSidebarCollapsedChange: ((Bool) -> Void)?
    var onTransferSidebarCollapsedChange: ((Bool) -> Void)?
    var onTransfer: ((Bool, String, String) -> Void)?
    var onRefreshLocalFiles: (() -> Void)?
    var onRefreshRemoteFiles: (() -> Void)?
    var onChooseLocalPath: (() -> Void)?

    func resetDraft() {
        draft = SSHHostDraft()
        editingHostID = nil
        showForm = true
        hostSidebarIntent = .forcedVisible
        sidebarCollapsed = false
    }

    func edit(_ host: SSHHostProfile) {
        draft = SSHHostDraft(host: host)
        editingHostID = host.id
        showForm = true
        hostSidebarIntent = .forcedVisible
        sidebarCollapsed = false
    }

    func cancelDraft() {
        showForm = false
        editingHostID = nil
        error = nil
    }

    func prepareTransferPanel(localPath: String, remotePath: String) {
        if localSitePath.isEmpty { localSitePath = localPath }
        if remoteSitePath.isEmpty { remoteSitePath = remotePath }
        addTransferLog("Connected")
    }

    func applyLocalListing(_ object: [String: JSONValue]) {
        localSitePath = object["path"]?.stringValue ?? localSitePath
        localEntries = decodeEntries(object["entries"]?.arrayValue)
        selectedLocalIDs = selectedLocalIDs.intersection(Set(localEntries.map(\.id)))
        if let selectedLocalEntry, !selectedLocalIDs.contains(selectedLocalEntry.id) {
            self.selectedLocalEntry = nil
        }
        transferStatus = "Local listed"
        addTransferLog("Local site: \(localSitePath)")
    }

    func applyRemoteListing(_ object: [String: JSONValue]) {
        remoteSitePath = object["path"]?.stringValue ?? remoteSitePath
        remoteEntries = decodeEntries(object["entries"]?.arrayValue)
        selectedRemoteIDs = selectedRemoteIDs.intersection(Set(remoteEntries.map(\.id)))
        if let selectedRemoteEntry, !selectedRemoteIDs.contains(selectedRemoteEntry.id) {
            self.selectedRemoteEntry = nil
        }
        transferStatus = "Remote listed"
        addTransferLog("Remote site: \(remoteSitePath)")
    }

    func selectLocal(_ entry: SSHFileEntry, additive: Bool = false) {
        selectedLocalEntry = entry
        if additive {
            if selectedLocalIDs.contains(entry.id) {
                selectedLocalIDs.remove(entry.id)
            } else {
                selectedLocalIDs.insert(entry.id)
            }
        } else {
            selectedLocalIDs = [entry.id]
        }
    }

    func selectRemote(_ entry: SSHFileEntry, additive: Bool = false) {
        selectedRemoteEntry = entry
        if additive {
            if selectedRemoteIDs.contains(entry.id) {
                selectedRemoteIDs.remove(entry.id)
            } else {
                selectedRemoteIDs.insert(entry.id)
            }
        } else {
            selectedRemoteIDs = [entry.id]
        }
    }

    func openLocal(_ entry: SSHFileEntry) {
        if entry.isDirectory {
            localSitePath = entry.path
            onRefreshLocalFiles?()
        }
    }

    func openRemote(_ entry: SSHFileEntry) {
        if entry.isDirectory {
            remoteSitePath = entry.path
            onRefreshRemoteFiles?()
        }
    }

    func localTransferEntries(anchor: SSHFileEntry) -> [SSHFileEntry] {
        let selected = localEntries.filter { selectedLocalIDs.contains($0.id) && !$0.isDirectory }
        if selectedLocalIDs.contains(anchor.id), !selected.isEmpty { return selected }
        return anchor.isDirectory ? [] : [anchor]
    }

    func remoteTransferEntries(anchor: SSHFileEntry) -> [SSHFileEntry] {
        let selected = remoteEntries.filter { selectedRemoteIDs.contains($0.id) && !$0.isDirectory }
        if selectedRemoteIDs.contains(anchor.id), !selected.isEmpty { return selected }
        return anchor.isDirectory ? [] : [anchor]
    }

    func uploadLocalSelection(anchor: SSHFileEntry) {
        for entry in localTransferEntries(anchor: anchor) {
            let remotePath = (remoteSitePath as NSString).appendingPathComponent(entry.name)
            onTransfer?(true, entry.path, remotePath)
        }
    }

    func downloadRemoteSelection(anchor: SSHFileEntry) {
        for entry in remoteTransferEntries(anchor: anchor) {
            let localPath = (localSitePath as NSString).appendingPathComponent(entry.name)
            onTransfer?(false, localPath, entry.path)
        }
    }

    func selectLocalPath(_ path: String, isDirectory: Bool) {
        if isDirectory {
            localSitePath = path
            transferLocalPath = path
        } else {
            transferLocalPath = path
            localSitePath = (path as NSString).deletingLastPathComponent
        }
        selectedLocalIDs.removeAll()
        selectedLocalEntry = nil
    }

    func recordTransfer(direction: SSHTransferDirection, localPath: String, remotePath: String, status: SSHTransferState) {
        let item = SSHTransferQueueItem(direction: direction, localPath: localPath, remotePath: remotePath, size: "", status: status)
        if status != .queued {
            queueItems.removeAll { $0.localPath == localPath && $0.remotePath == remotePath && $0.status == .queued }
        }
        queueItems.insert(item, at: 0)
        selectedQueueState = status
        addTransferLog("\(direction.rawValue): \(status.rawValue)")
    }

    func addTransferLog(_ line: String) {
        transferLogs.append(line)
        transferLogs = Array(transferLogs.suffix(5))
    }

    private func decodeEntries(_ values: [JSONValue]?) -> [SSHFileEntry] {
        values?.compactMap { value in
            guard let object = value.objectValue,
                  let name = object["name"]?.stringValue,
                  let path = object["path"]?.stringValue else { return nil }
            return SSHFileEntry(id: path,
                                name: name,
                                path: path,
                                kind: object["kind"]?.stringValue ?? object["type"]?.stringValue ?? "file",
                                size: object["size"]?.stringValue ?? "",
                                fileType: object["file_type"]?.stringValue ?? "",
                                modified: object["modified"]?.stringValue ?? "")
        } ?? []
    }
}

private final class AdaptiveSSHRootView: NSView {
    var onSizeChanged: ((NSSize) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        guard oldSize != newSize else { return }
        onSizeChanged?(newSize)
    }
}

struct SSHHostDraft {
    var id: SSHHostID?
    var label = ""
    var destination = ""
    var portText = ""
    var identityFileText = ""
    var passwordText = ""
    var optionLines = ""

    var resolvedLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? destination : trimmed
    }

    var parsedPort: Int? {
        Int(portText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var options: [String] {
        optionLines
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var parsedIdentityFile: String? {
        let trimmed = identityFileText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var parsedPassword: String? {
        passwordText.isEmpty ? nil : passwordText
    }

    init(host: SSHHostProfile? = nil) {
        guard let host else { return }
        id = host.id
        label = host.label
        destination = host.destination
        portText = host.port.map(String.init) ?? ""
        identityFileText = host.identityFile ?? ""
        passwordText = host.password ?? ""
        optionLines = host.options.joined(separator: "\n")
    }
}

private struct SSHSidebarView: View {
    @ObservedObject var vm: SSHSurfaceViewModel

    var body: some View {
        Group {
            if vm.sidebarCollapsed {
                collapsedRail
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    DSSectionHeader("SSH", trailing: AnyView(
                        HStack(spacing: DS.Space.xs) {
                            DSIconButton("sidebar.left", help: "Hide hosts") {
                                vm.hostSidebarIntent = .forcedHidden
                                vm.sidebarCollapsed = true
                            }
                            DSIconButton("plus", help: "Add SSH host") {
                                vm.resetDraft()
                            }
                        }
                    ))
                    Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: DS.Space.xxs) {
                            savedHosts
                        }
                        .padding(DS.Space.sm)
                    }
                    .focusable()
                }
                .background(DS.Palette.sidebar)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(DS.Palette.line).frame(width: DS.Border.hairline)
                }
            }
        }
        .background(DS.Palette.sidebar)
        .sheet(isPresented: $vm.showForm) {
            SSHHostFormSheet(vm: vm)
        }
    }

    private var collapsedRail: some View {
        VStack(spacing: DS.Space.sm) {
            DSIconButton("sidebar.left", help: "Show hosts") {
                vm.hostSidebarIntent = .forcedVisible
                vm.sidebarCollapsed = false
            }
            DSIconButton("plus", help: "Add SSH host") {
                vm.resetDraft()
            }
            Divider().overlay(DS.Palette.line)
            Image(systemName: "network")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(vm.selectedHost == nil ? DS.Palette.textTertiary : DS.Palette.accent)
                .frame(width: 28, height: 28)
                .help(vm.selectedHost?.label ?? "SSH hosts")
            Spacer()
        }
        .padding(.top, DS.Space.sm)
        .frame(width: 44)
        .background(DS.Palette.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(DS.Palette.line).frame(width: DS.Border.hairline)
        }
    }

    private var savedHosts: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(vm.hosts.isEmpty ? "Saved" : "Saved · \(vm.hosts.count)")
                .font(DS.Font.caption2.weight(.semibold))
                .foregroundColor(DS.Palette.textTertiary)
                .textCase(.uppercase)
                .padding(.horizontal, DS.Space.xs)
                .padding(.top, DS.Space.xs)
            if vm.hosts.isEmpty {
                DSEmptyState(
                    icon: "network",
                    title: "No hosts",
                    subtitle: "Add a host to open an SSH terminal.",
                    background: DS.Palette.sidebar
                )
            } else {
                ForEach(vm.hosts, id: \.id) { host in
                    SSHHostRow(
                        host: host,
                        connected: vm.selectedHost?.id == host.id && vm.status == "Connected",
                        onConnect: { vm.onConnect?(host) },
                        onOpenNewConnection: { vm.onOpenNewConnection?(host) },
                        onEdit: { vm.edit(host) },
                        onDelete: { vm.onDelete?(host) }
                    )
                }
            }
        }
    }

}

private struct SSHTransferSidebarView: View {
    @ObservedObject var vm: SSHSurfaceViewModel
    @State private var fileColumns = SSHFileColumnWidths()
    @State private var queueColumns = SSHQueueColumnWidths()
    @State private var localPaneWidth: CGFloat = 340
    @State private var treeHeight: CGFloat = 126
    @State private var queueHeight: CGFloat = 166

    var body: some View {
        Group {
            if !vm.transferSidebarVisible {
                Color.clear
            } else if vm.transferSidebarCollapsed {
                collapsedRail
            } else {
                panel
            }
        }
        .background(DS.Palette.sidebar)
    }

    private var collapsedRail: some View {
        VStack(spacing: DS.Space.sm) {
            DSIconButton("sidebar.right", help: "Show file transfer") {
                vm.transferSidebarCollapsed = false
            }
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Palette.accent)
                .frame(width: 28, height: 28)
                .help("SSH file transfer")
            Spacer()
        }
        .padding(.top, DS.Space.sm)
        .frame(width: 44)
        .overlay(alignment: .leading) {
            Rectangle().fill(DS.Palette.line).frame(width: DS.Border.hairline)
        }
    }

    private var panel: some View {
        GeometryReader { proxy in
            let boundedQueueHeight = min(max(queueHeight, 112), max(112, proxy.size.height * 0.42))
            VStack(alignment: .leading, spacing: 0) {
                DSSectionHeader("Files", trailing: AnyView(
                    HStack(spacing: DS.Space.xs) {
                        DSIconButton("arrow.clockwise", help: "Refresh local and remote files") {
                            vm.onRefreshLocalFiles?()
                            vm.onRefreshRemoteFiles?()
                        }
                        DSIconButton("sidebar.right", help: "Hide file transfer") {
                            vm.transferSidebarCollapsed = true
                        }
                    }
                ))
                Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
                GeometryReader { contentProxy in
                    let panesHeight = max(220, contentProxy.size.height - boundedQueueHeight - 9)
                    VStack(spacing: 0) {
                        splitPanes
                            .frame(height: panesHeight)
                        DSResizeDivider(axis: .horizontal, help: "Resize transfer queue") { delta in
                            queueHeight = min(max(queueHeight - delta, 112), max(112, contentProxy.size.height * 0.56))
                        }
                        queuePanel
                            .frame(height: boundedQueueHeight)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(minWidth: 480)
        .overlay(alignment: .leading) {
            Rectangle().fill(DS.Palette.line).frame(width: DS.Border.hairline)
        }
    }

    private var splitPanes: some View {
        GeometryReader { proxy in
            let minPane: CGFloat = min(230, max(180, proxy.size.width * 0.38))
            let maxLeft = max(minPane, proxy.size.width - minPane - 8)
            let leftWidth = min(max(localPaneWidth, minPane), maxLeft)
            HStack(spacing: 0) {
                transferPane(title: "Local site",
                             path: $vm.localSitePath,
                             entries: vm.localEntries,
                             selectedIDs: vm.selectedLocalIDs,
                             refresh: { vm.onRefreshLocalFiles?() },
                             choose: { vm.onChooseLocalPath?() },
                             open: { vm.openLocal($0) },
                             select: { vm.selectLocal($0, additive: $1) },
                             transferTitle: "Upload",
                             transfer: { vm.uploadLocalSelection(anchor: $0) })
                    .frame(width: leftWidth)
                DSResizeDivider(axis: .vertical, help: "Resize local and remote panes") { delta in
                    localPaneWidth = min(max(localPaneWidth + delta, minPane), maxLeft)
                }
                transferPane(title: "Remote site",
                             path: $vm.remoteSitePath,
                             entries: vm.remoteEntries,
                             selectedIDs: vm.selectedRemoteIDs,
                             refresh: { vm.onRefreshRemoteFiles?() },
                             choose: nil,
                             open: { vm.openRemote($0) },
                             select: { vm.selectRemote($0, additive: $1) },
                             transferTitle: "Download",
                             transfer: { vm.downloadRemoteSelection(anchor: $0) })
            }
        }
    }

    private func transferPane(title: String,
                              path: Binding<String>,
                              entries: [SSHFileEntry],
                              selectedIDs: Set<String>,
                              refresh: @escaping () -> Void,
                              choose: (() -> Void)?,
                              open: @escaping (SSHFileEntry) -> Void,
                              select: @escaping (SSHFileEntry, Bool) -> Void,
                              transferTitle: String,
                              transfer: @escaping (SSHFileEntry) -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.xs) {
                Text(title + ":")
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                TextField("/", text: path, onCommit: refresh)
                    .textFieldStyle(.plain)
                    .font(DS.Font.monoSmall)
                    .padding(.horizontal, DS.Space.xs)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Palette.bg))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).stroke(DS.Palette.line))
                if let choose {
                    Button(action: choose) { Image(systemName: "folder") }
                        .buttonStyle(.plain)
                        .frame(width: 28, height: 28)
                        .help("Choose local file or folder")
                        .accessibilityLabel("Choose local file or folder")
                }
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .help("Refresh \(title.lowercased())")
                    .accessibilityLabel("Refresh \(title)")
            }
            .padding(DS.Space.xs)
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            directoryTree(entries: entries, path: path.wrappedValue, open: open)
                .frame(height: treeHeight)
            DSResizeDivider(axis: .horizontal, help: "Resize directory tree") { delta in
                treeHeight = min(max(treeHeight + delta, 76), 240)
            }
            fileTable(entries: entries,
                      selectedIDs: selectedIDs,
                      select: select,
                      open: open,
                      transferTitle: transferTitle,
                      transfer: transfer)
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            paneStatus(entries: entries, selectedIDs: selectedIDs)
                .frame(height: 28)
        }
    }

    private func directoryTree(entries: [SSHFileEntry], path: String, open: @escaping (SSHFileEntry) -> Void) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                Text(path.isEmpty ? "/" : path)
                    .font(DS.Font.monoSmall.weight(.semibold))
                    .lineLimit(1)
                    .foregroundColor(DS.Palette.text)
                    .padding(.horizontal, DS.Space.sm)
                    .padding(.top, DS.Space.xs)
                ForEach(entries.filter(\.isDirectory).prefix(24)) { entry in
                    Button { open(entry) } label: {
                        HStack(spacing: DS.Space.xs) {
                            Image(systemName: entry.name == ".." ? "arrow.turn.up.left" : "folder")
                                .foregroundColor(DS.Palette.textSecondary)
                                .frame(width: 16)
                            Text(entry.name)
                                .lineLimit(1)
                            Spacer()
                        }
                        .font(DS.Font.caption)
                        .padding(.horizontal, DS.Space.sm)
                        .frame(height: 22)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(DS.Palette.bg.opacity(0.42))
    }

    private func fileTable(entries: [SSHFileEntry],
                           selectedIDs: Set<String>,
                           select: @escaping (SSHFileEntry, Bool) -> Void,
                           open: @escaping (SSHFileEntry) -> Void,
                           transferTitle: String,
                           transfer: @escaping (SSHFileEntry) -> Void) -> some View {
        ScrollView(.horizontal) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    resizableHeader("Name", width: $fileColumns.name, minWidth: 150)
                    resizableHeader("Size", width: $fileColumns.size, minWidth: 68, alignment: .trailing)
                    resizableHeader("Kind", width: $fileColumns.type, minWidth: 82)
                    resizableHeader("Modified", width: $fileColumns.modified, minWidth: 112)
                }
                Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        if entries.isEmpty {
                            Text("No files listed")
                                .font(DS.Font.caption)
                                .foregroundColor(DS.Palette.textTertiary)
                                .frame(width: fileColumns.total)
                                .frame(minHeight: 72)
                        } else {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                Button {
                                    let flags = NSEvent.modifierFlags
                                    select(entry, flags.contains(.command) || flags.contains(.shift))
                                } label: {
                                    HStack(spacing: 0) {
                                        HStack(spacing: DS.Space.xs) {
                                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                                                .foregroundColor(entry.isDirectory ? DS.Palette.textSecondary : DS.Palette.accent)
                                                .frame(width: 16)
                                            Text(entry.name)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Spacer(minLength: 0)
                                        }
                                        .frame(width: fileColumns.name, alignment: .leading)
                                        Text(entry.size)
                                            .lineLimit(1)
                                            .monospacedDigit()
                                            .frame(width: fileColumns.size, alignment: .trailing)
                                        Text(entry.fileType)
                                            .lineLimit(1)
                                            .frame(width: fileColumns.type, alignment: .leading)
                                        Text(entry.modified)
                                            .lineLimit(1)
                                            .monospacedDigit()
                                            .frame(width: fileColumns.modified, alignment: .leading)
                                    }
                                    .font(DS.Font.caption)
                                    .foregroundColor(DS.Palette.text)
                                    .padding(.horizontal, DS.Space.xs)
                                    .frame(width: fileColumns.total, height: 26, alignment: .leading)
                                    .background(rowBackground(index: index, isSelected: selectedIDs.contains(entry.id)))
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if entry.isDirectory {
                                        Button("Open Folder") { open(entry) }
                                    } else {
                                        Button(transferMenuTitle(transferTitle: transferTitle,
                                                                 selectedIDs: selectedIDs,
                                                                 entries: entries,
                                                                 anchor: entry)) {
                                            transfer(entry)
                                        }
                                    }
                                    Button(selectedIDs.contains(entry.id) ? "Deselect" : "Select") {
                                        select(entry, true)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func transferMenuTitle(transferTitle: String,
                                   selectedIDs: Set<String>,
                                   entries: [SSHFileEntry],
                                   anchor: SSHFileEntry) -> String {
        let selectedFiles = entries.filter { selectedIDs.contains($0.id) && !$0.isDirectory }
        guard selectedIDs.contains(anchor.id), selectedFiles.count > 1 else { return transferTitle }
        return "\(transferTitle) \(selectedFiles.count) files"
    }

    private func resizableHeader(_ title: String,
                                 width: Binding<CGFloat>,
                                 minWidth: CGFloat,
                                 alignment: Alignment = .leading) -> some View {
        SSHResizableHeader(title: title, width: width, minWidth: minWidth, alignment: alignment)
    }

    private func rowBackground(index: Int, isSelected: Bool) -> Color {
        if isSelected { return DS.Palette.selection }
        return index.isMultiple(of: 2) ? DS.Palette.surface.opacity(0.35) : Color.clear
    }

    private func paneStatus(entries: [SSHFileEntry], selectedIDs: Set<String>) -> some View {
        let files = entries.filter { !$0.isDirectory }
        let total = files.compactMap { Int($0.size) }.reduce(0, +)
        let selectedCount = entries.filter { selectedIDs.contains($0.id) }.count
        return HStack {
            Text(selectedCount > 0 ? "Selected \(selectedCount) item\(selectedCount == 1 ? "" : "s")." : "\(files.count) files. Total size: \(total) bytes")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, DS.Space.sm)
    }

    private var queuePanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(SSHTransferState.allCases, id: \.self) { state in
                    Button {
                        vm.selectedQueueState = state
                    } label: {
                        Text("\(state.rawValue) transfers")
                            .font(DS.Font.caption.weight(vm.selectedQueueState == state ? .semibold : .regular))
                            .padding(.horizontal, DS.Space.sm)
                            .frame(height: 30)
                            .background(vm.selectedQueueState == state ? DS.Palette.bg : Color.clear)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("Queue: \(vm.queueItems.contains { $0.status == .queued } ? "active" : "empty")")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                    .padding(.trailing, DS.Space.sm)
            }
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        resizableHeader("Local", width: $queueColumns.local, minWidth: 150)
                        resizableHeader("Direction", width: $queueColumns.direction, minWidth: 74)
                        resizableHeader("Remote", width: $queueColumns.remote, minWidth: 140)
                        resizableHeader("Size", width: $queueColumns.size, minWidth: 56, alignment: .trailing)
                        resizableHeader("Priority", width: $queueColumns.priority, minWidth: 64)
                        resizableHeader("Status", width: $queueColumns.status, minWidth: 74)
                    }
                    ScrollView(.vertical) {
                        let items = vm.queueItems.filter { $0.status == vm.selectedQueueState }
                        LazyVStack(spacing: 0) {
                            if items.isEmpty {
                                Text("No \(vm.selectedQueueState.rawValue.lowercased()) transfers")
                                    .font(DS.Font.caption)
                                    .foregroundColor(DS.Palette.textTertiary)
                                    .frame(width: queueColumns.total)
                                    .frame(minHeight: 66)
                            } else {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    HStack(spacing: 0) {
                                        Text(item.localPath).frame(width: queueColumns.local, alignment: .leading)
                                        Text(item.direction.rawValue).frame(width: queueColumns.direction, alignment: .leading)
                                        Text(item.remotePath).frame(width: queueColumns.remote, alignment: .leading)
                                        Text(item.size).frame(width: queueColumns.size, alignment: .trailing)
                                        Text("Normal").frame(width: queueColumns.priority, alignment: .leading)
                                        Text(item.status.rawValue).frame(width: queueColumns.status, alignment: .leading)
                                    }
                                    .font(DS.Font.caption)
                                    .lineLimit(1)
                                    .padding(.horizontal, DS.Space.xs)
                                    .frame(width: queueColumns.total, height: 24, alignment: .leading)
                                    .background(rowBackground(index: index, isSelected: false))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct SSHResizableHeader: View {
    let title: String
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let alignment: Alignment
    @State private var startWidth: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: alignment)
            Rectangle()
                .fill(DS.Palette.lineStrong.opacity(0.92))
                .frame(width: DS.ResizeDivider.gripThickness, height: 18)
                .padding(.horizontal, DS.Space.xs)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let base = startWidth ?? width
                            if startWidth == nil { startWidth = width }
                            width = max(minWidth, base + value.translation.width)
                        }
                        .onEnded { _ in startWidth = nil }
                )
                .help("Drag to resize \(title)")
        }
        .font(DS.Font.caption2.weight(.semibold))
        .foregroundColor(DS.Palette.textSecondary)
        .frame(width: width, alignment: alignment)
        .padding(.horizontal, DS.Space.xs)
        .frame(height: 26)
        .background(DS.Palette.surfaceRaised.opacity(0.42))
    }
}

private struct SSHHostFormSheet: View {
    @ObservedObject var vm: SSHSurfaceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack {
                Text(vm.editingHostID == nil ? "New Host" : "Edit Host")
                    .font(DS.Font.caption2.weight(.semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                    .textCase(.uppercase)
                Spacer()
                Button { vm.cancelDraft() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityLabel("Close SSH host editor")
                .help("Cancel")
            }
            formField("Host", requirement: "Required") {
                TextField("user@host or ssh-config alias", text: $vm.draft.destination)
                    .textFieldStyle(.roundedBorder)
            }
            formField("Port", requirement: "Optional") {
                TextField("22", text: $vm.draft.portText)
                    .textFieldStyle(.roundedBorder)
            }
            formField("Identity file", requirement: "Optional") {
                HStack(spacing: DS.Space.xs) {
                    TextField("~/.ssh/id_ed25519", text: $vm.draft.identityFileText)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        chooseIdentityFile()
                    } label: {
                        Label("Choose", systemImage: "folder")
                    }
                    .help("Choose identity file")
                }
            }
            formField("Password", requirement: "Optional") {
                SecureField("Saved password", text: $vm.draft.passwordText)
                    .textFieldStyle(.roundedBorder)
            }
            fieldLabel("SSH options", requirement: "Optional")
            TextEditor(text: $vm.draft.optionLines)
                .font(DS.Font.monoSmall)
                .frame(minHeight: 84)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).stroke(DS.Palette.line))
            Divider()
            formField("Label", requirement: "Optional") {
                TextField("Production server", text: $vm.draft.label)
                    .textFieldStyle(.roundedBorder)
            }
            if let error = vm.error {
                Text(error)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.danger)
            }
            HStack(spacing: DS.Space.sm) {
                Spacer()
                Button("Cancel") { vm.cancelDraft() }
                    .keyboardShortcut(.cancelAction)
                Button(vm.editingHostID == nil ? "Save + Connect" : "Save") {
                    vm.onSave?(vm.draft)
                }
                    .disabled(vm.draft.destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(DSPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.lg)
        .frame(width: 460)
        .background(DS.Palette.surfaceRaised)
    }

    private func formField<Content: View>(_ label: String, requirement: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            fieldLabel(label, requirement: requirement)
            content()
        }
    }

    private func fieldLabel(_ label: String, requirement: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            Text(label)
                .font(DS.Font.caption2.weight(.semibold))
                .foregroundColor(DS.Palette.textSecondary)
            Text(requirement)
                .font(DS.Font.caption2.weight(.semibold))
                .foregroundColor(requirement == "Required" ? DS.Palette.accent : DS.Palette.textTertiary)
        }
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            vm.draft.identityFileText = url.path
        }
    }
}

private struct SSHHostRow: View {
    let host: SSHHostProfile
    let connected: Bool
    let onConnect: () -> Void
    let onOpenNewConnection: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onConnect) {
            HStack(spacing: DS.Space.md) {
                Image(systemName: "network")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(connected ? DS.Palette.accent : DS.Palette.textTertiary)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.label)
                        .font(DS.Font.bodyDense.weight(connected ? .semibold : .regular))
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if connected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Palette.accent)
                        .accessibilityLabel("Connected")
                }
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Palette.textTertiary)
                .help("Delete host")
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
            .background(connected ? DS.Palette.selection : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .stroke(connected ? DS.Palette.accent.opacity(0.42) : Color.clear, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open New Connection", action: onOpenNewConnection)
            Button("Edit Host", action: onEdit)
            Divider()
            Button("Delete Host", role: .destructive, action: onDelete)
        }
        .help(host.label)
    }

    private var subtitle: String {
        if let port = host.port {
            return "\(host.destination):\(port)"
        }
        return host.destination
    }
}
