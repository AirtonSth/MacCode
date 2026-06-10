import Foundation
import AppKit
import CoreModel
import Persistence
import AgentRuntime
import SocketServer
import Surfaces
import UserNotifications
import os

private let appLifecycleLog = Logger(subsystem: "io.remotecode.app", category: "lifecycle")

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    public var context: AppContext!
    public var router: AppCommandRouter!
    public var windowController: MainWindowController!
    public var socketServer: UnixSocketServer?
    public var httpServer: DirectHTTPServer?
    /// GAP-5: `DirectHTTPServer.auth` is a weak ref. Without an owner the
    /// LocalAuthAdapter deallocates the instant launch returns, which
    /// silently disables pairing AND bypasses the LAN auth gate. The
    /// app delegate must own it for the process lifetime.
    private var authProvider: DirectAuthProvider?
    private var localAuth: LocalAuthAdapter?
    private var bonjour: NetService?
    private let bonjourDelegate = BonjourDelegate()
    public var palette: CommandPalette?
    public var settings: SettingsWindowController?
    public var updater: AppUpdateChecking?
    public let channel: ReleaseChannel
    private let appSupportOverride: String?
    private let dbOverride: String?
    private var providerSessionReaperTimer: Timer?
    private var diagnosticsHeartbeatTimer: Timer?
    private var tokenSaverAccountUsageRefreshTimer: Timer?
    private var lifecycleRecorder: AppLifecycleRecorder?
    public static let tokenSaverAccountUsageRefreshInterval: TimeInterval = 5 * 60

    public init(channel: ReleaseChannel = .debug, appSupportOverride: String? = nil, dbOverride: String? = nil) {
        self.channel = channel
        self.appSupportOverride = appSupportOverride
        self.dbOverride = dbOverride
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            context = try AppContext(channel: channel, dbPathOverride: dbOverride, appSupportOverride: appSupportOverride)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to bootstrap RemoteCode"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        installLifecycleRecorder()
        terminateOrphanedProviderRuntimes(reason: "launch")
        router = AppCommandRouter(context: context)
        context.router = router

        // Wire EventBus to the persisted event log so events survive restart.
        let log = context.eventLog
        EventBus.shared.shouldRetainRecentEvent = { ev in
            Self.shouldRetainRecentEvent(ev)
        }
        EventBus.shared.persister = { ev in
            guard Self.shouldPersistEvent(ev) else { return }
            let payloadData = (try? JSONEncoder().encode(ev.payload)) ?? Data("null".utf8)
            let json = String(data: payloadData, encoding: .utf8) ?? "null"
            _ = try? log.append(seq: ev.seq, kind: ev.kind, payloadJSON: json)
        }
        if let rows = try? log.read(since: 0, limit: 256) {
            let events = rows.compactMap { row -> EventBus.Event? in
                guard let data = row.payloadJSON.data(using: .utf8),
                      let val = try? JSONDecoder().decode(JSONValue.self, from: data)
                else { return nil }
                return EventBus.Event(seq: row.seq, kind: row.kind, payload: val, ts: Date().timeIntervalSince1970)
            }
            EventBus.shared.reloadFromPersistence(lastSeq: (try? log.lastSeq()) ?? 0, recent: events)
        }
        updater = SparkleAppUpdater.defaultIfConfigured()
        updater?.onWillInstallUpdate = { [weak self] in
            self?.persistRestorableStateBeforeUpdate()
        }
        windowController = MainWindowController(context: context, router: router, updater: updater)
        router.windowController = windowController
        // Rebuild Surface objects from restored layout descriptors, then
        // refresh so the restored workspaces + tabs actually render
        // (the controller's init refresh ran before surfaces existed).
        router.reinstantiateRestoredSurfaces()
        // UX-MAC_SHELL_WINDOW-014: surfaces now exist; drop the restoring
        // affordance and render the real layout.
        windowController.markRestorationComplete()

        // start unix socket server
        let socketPath = AppPaths.socketPath(for: channel)
        let dispatcher = JSONRPCDispatcher(router: router)
        let server = UnixSocketServer(socketPath: socketPath, dispatcher: dispatcher)
        do {
            try server.start()
            socketServer = server
        } catch {
            NSLog("Failed to start socket server: \(error)")
        }

        let trustRepo = DeviceTrustRepository(db: context.db)
        let auth = LocalAuthAdapter(
            repo: trustRepo,
            privateAccountStore: PrivateAccountSessionStore(repo: context.settingsRepo)
        )
        authProvider = auth   // GAP-5: retain for process lifetime
        localAuth = auth
        // A device-initiated pair request pops an approve/deny modal on
        // the Mac. The HTTP handler invokes this off the listener thread;
        // hop to main for AppKit. The device polls /v1/pair/status mean-
        // while, so the server never blocks on the user's decision.
        auth.onPairingRequest = { [weak self] prompt in
            DispatchQueue.main.async { self?.presentPairingPrompt(prompt) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(remoteAccessSettingChanged),
                                               name: .rc2RemoteAccessSettingChanged, object: nil)
        configureDirectAccess()

        palette = CommandPalette(router: router)
        settings = SettingsWindowController(context: context, updater: updater)
        SystemNotifier.shared.bootstrap()
        SystemNotifier.shared.onNotificationResponse = { [weak self] response in
            self?.handleNotificationResponse(response)
        }
        reapIdleProviderSessions()
        providerSessionReaperTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in
            guard let delegate = self else { return }
            Task { @MainActor in
                delegate.reapIdleProviderSessions()
            }
        }

        installMainMenu()
        windowController.show()
        refreshTokenSaverAccountUsageOnLaunch()
        startTokenSaverAccountUsageRefreshLoop()
        startDiagnosticsHeartbeat()
        logDiagnosticsHeartbeat(reason: "launch")
        checkForUpdatesAfterOpeningApp()
    }

    public func checkForUpdatesAfterOpeningApp() {
        updater?.checkForUpdates()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        appLifecycleLog.info("app.will_terminate pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public)")
        lifecycleRecorder?.endRunCleanly(reason: "applicationWillTerminate")
        logDiagnosticsHeartbeat(reason: "will_terminate")
        disableInsomniaForAppClose()
        context?.reconcileManagedDistillSkills(tokenSaverEnabled: false)
        persistRestorableStateBeforeUpdate()
        stopLiveRuntimesForAppTermination()
        socketServer?.stop()
        httpServer?.stop()
        bonjour?.stop()
        providerSessionReaperTimer?.invalidate()
        diagnosticsHeartbeatTimer?.invalidate()
        tokenSaverAccountUsageRefreshTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func disableInsomniaForAppClose() {
        windowController?.disableInsomniaForAppClose()
        if let context {
            SettingsStore(db: context.db).update { $0.insomniaEnabled = false }
        }
    }

    private func persistRestorableStateBeforeUpdate() {
        context?.saveSnapshot()
        for surface in SurfaceRegistry.shared.all() {
            (surface as? TerminalSurface)?.flushPersistedHistory()
        }
    }

    private func stopLiveRuntimesForAppTermination() {
        context?.coordinator.stopAllProviderSessions()
        for surface in SurfaceRegistry.shared.all() {
            surface.close()
        }
    }

    private func startDiagnosticsHeartbeat() {
        diagnosticsHeartbeatTimer?.invalidate()
        diagnosticsHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.logDiagnosticsHeartbeat(reason: "periodic")
            }
        }
    }

    private func refreshTokenSaverAccountUsageOnLaunch() {
        context?.refreshTokenSaverAccountUsage(reason: "launch")
    }

    private func startTokenSaverAccountUsageRefreshLoop() {
        tokenSaverAccountUsageRefreshTimer?.invalidate()
        tokenSaverAccountUsageRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: Self.tokenSaverAccountUsageRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.context?.refreshTokenSaverAccountUsage(reason: "periodic")
            }
        }
    }

    private func logDiagnosticsHeartbeat(reason: String) {
        AppDiagnostics.heartbeat(
            reason: reason,
            activeAgentThreads: context?.coordinator.activeThreadIdsSnapshot().count ?? 0
        )
        lifecycleRecorder?.recordHeartbeat(reason: reason)
    }

    private func installLifecycleRecorder() {
        let directory = AppPaths.appSupportDirectory(for: channel, override: appSupportOverride)
            .appendingPathComponent("diagnostics", isDirectory: true)
        let recorder = AppLifecycleRecorder(directory: directory)
        if let stale = recorder.consumeStaleRunMarker() {
            // The previous run never reached applicationWillTerminate: it was
            // killed (SIGTERM/SIGKILL) or died abruptly with no crash report.
            // This is the on-disk evidence for the "app silently vanished" report.
            appLifecycleLog.fault("app.previous_run_unclean \(stale, privacy: .public)")
            recorder.record("previous_run_ended_uncleanly \(stale)")
        }
        recorder.beginRun()
        recorder.installSignalHandlers()
        recorder.installExitHandler()
        lifecycleRecorder = recorder
    }

    private func terminateOrphanedProviderRuntimes(reason: String) {
        let result = ProviderProcessSweeper.terminateOrphanedProviderRuntimes()
        guard !result.orphanRootPIDs.isEmpty || !result.failedPIDs.isEmpty else { return }
        appLifecycleLog.info("provider.orphan_sweep reason=\(reason, privacy: .public) roots=\(result.orphanRootPIDs.count, privacy: .public) terminated=\(result.terminatedPIDs.count, privacy: .public) failed=\(result.failedPIDs.count, privacy: .public)")
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            windowController?.show()
        }
        router?.reconcileSurfaceVisibility()
        windowController?.repairSelectedTerminalFocus(reason: "app_reopen")
        return true
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        openDroppedWorkspaceFolders(urls)
    }

    public func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        openDroppedWorkspaceFolders([URL(fileURLWithPath: filename, isDirectory: true)])
    }

    public func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let opened = openDroppedWorkspaceFolders(filenames.map { URL(fileURLWithPath: $0, isDirectory: true) })
        sender.reply(toOpenOrPrint: opened ? .success : .failure)
    }

    @discardableResult
    public func openDroppedWorkspaceFolders(_ urls: [URL]) -> Bool {
        guard let router else { return false }
        var opened = false
        for url in urls {
            if (try? router.createWorkspace(fromFolder: url)) != nil {
                // UX-MAC_SHELL_WINDOW-005: feed File ▸ Open Recent.
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                opened = true
            }
        }
        if opened {
            windowController?.show()
        }
        return opened
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        // Timestamps the reveal (deminiaturize/refocus) AND samples memory at
        // that instant, so the lifecycle log shows the app was alive at the
        // moment focus returned — the gesture the silent-vanish report is tied
        // to — and whether memory spiked on reveal (out-of-memory kill).
        lifecycleRecorder?.recordHeartbeat(reason: "did_become_active")
        router?.reconcileSurfaceVisibility()
        windowController?.repairSelectedTerminalFocus(reason: "app_active")
    }

    private func reapIdleProviderSessions() {
        do {
            let result = try context.reapIdleProviderSessions()
            if !result.stoppedThreadIds.isEmpty {
                NSLog("Stopped \(result.stoppedThreadIds.count) idle provider session runtime(s).")
            }
        } catch {
            NSLog("Failed to reap idle provider sessions: \(error)")
        }
    }

    static func shouldPersistEvent(_ event: EventBus.Event) -> Bool {
        event.kind != "surface.output"
    }

    static func shouldRetainRecentEvent(_ event: EventBus.Event) -> Bool {
        event.kind != "surface.output"
    }

    @objc private func remoteAccessSettingChanged() {
        configureDirectAccess()
    }

    private func configureDirectAccess() {
        httpServer?.stop()
        httpServer = nil
        bonjour?.stop()
        bonjour = nil

        guard let context, let router, let auth = localAuth else { return }
        let remoteEnabled = (try? context.settingsRepo.get("remote_access_enabled")) ?? "0"
        let loopbackOnly = remoteEnabled != "1"
        let dispatcher = JSONRPCDispatcher(router: router)
        let serverId = stableServerId()
        let http = DirectHTTPServer(port: 18217, loopbackOnly: loopbackOnly,
                                    dispatcher: dispatcher, auth: auth, serverId: serverId)
        do {
            try http.start()
            httpServer = http
            NSLog("Direct HTTP server listening on \(loopbackOnly ? "127.0.0.1" : "0.0.0.0"):18217 (loopback=\(loopbackOnly))")
        } catch {
            NSLog("Failed to start HTTP server: \(error)")
        }

        if loopbackOnly {
            NSLog("Bonjour not published: remote access is disabled")
        } else {
            publishBonjour(serverId: serverId)
        }
    }

    /// GAP-2: a stable host identity persisted across launches so the
    /// mobile client's identity pin (RCA-022) does not break on every
    /// restart and force a re-pair.
    private func stableServerId() -> String {
        if let existing = (try? context.settingsRepo.get("server_id")) ?? nil, !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        try? context.settingsRepo.set("server_id", fresh)
        return fresh
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About RemoteCode", action: #selector(showAbout), keyEquivalent: ""))
        let settingsItem = NSMenuItem(title: "Settings\u{2026}", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let checkUpdatesItem = NSMenuItem(title: "Check for Updates\u{2026}", action: #selector(checkForUpdatesAction), keyEquivalent: "")
        checkUpdatesItem.target = self
        appMenu.addItem(checkUpdatesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide RemoteCode", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit RemoteCode", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        let newWS = NSMenuItem(title: "New Workspace…", action: #selector(newWorkspace), keyEquivalent: "n")
        newWS.target = self
        fileMenu.addItem(newWS)
        // UX-MAC_SHELL_WINDOW-005: standard Open Recent submenu, populated
        // by AppKit from noteNewRecentDocumentURL; selections route through
        // application(_:open:) which opens the folder as a workspace.
        let openRecent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let openRecentMenu = NSMenu(title: "Open Recent")
        let clearRecent = NSMenuItem(title: "Clear Menu", action: Selector(("clearRecentDocuments:")), keyEquivalent: "")
        openRecentMenu.addItem(clearRecent)
        openRecent.submenu = openRecentMenu
        fileMenu.addItem(openRecent)
        fileMenu.addItem(.separator())
        // UX-MAC_SHELL_WINDOW-003: ⌘W closes the focused tab when one
        // exists; it only closes the window when the workspace has none.
        let closeTab = NSMenuItem(title: "Close Tab", action: #selector(closeActiveTabOrWindow), keyEquivalent: "w")
        closeTab.target = self
        fileMenu.addItem(closeTab)
        let closeWin = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeWin.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closeWin)
        fileMenuItem.submenu = fileMenu

        // Edit
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu

        // View
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let paletteItem = NSMenuItem(title: "Show Command Palette", action: #selector(togglePalette), keyEquivalent: "k")
        paletteItem.keyEquivalentModifierMask = [.command]
        paletteItem.target = self
        // C5: ~/.remotecode/keybindings.json may rebind the palette.
        applyKeybindingOverride(to: paletteItem, command: "commandPalette.toggle")
        viewMenu.addItem(paletteItem)
        viewMenu.addItem(.separator())
        let revealDiagnostics = NSMenuItem(title: "Reveal Diagnostics in Finder", action: #selector(revealDiagnosticsInFinder), keyEquivalent: "")
        revealDiagnostics.target = self
        viewMenu.addItem(revealDiagnostics)
        viewItem.submenu = viewMenu

        // Surface
        let surfaceItem = NSMenuItem()
        mainMenu.addItem(surfaceItem)
        let surfaceMenu = NSMenu(title: "Surface")
        let term = NSMenuItem(title: "New Terminal Surface", action: #selector(newTerminal), keyEquivalent: "t")
        term.target = self
        let browser = NSMenuItem(title: "New Browser Surface", action: #selector(newBrowser), keyEquivalent: "b")
        browser.target = self
        let agent = NSMenuItem(title: "New Agent App Surface", action: #selector(newAgentApp), keyEquivalent: "g")
        agent.target = self
        surfaceMenu.addItem(term)
        surfaceMenu.addItem(browser)
        surfaceMenu.addItem(agent)
        surfaceMenu.addItem(.separator())
        // UX-MAC_SHELL_WINDOW-004: keyboard splits, defaulting to Terminal.
        let splitRight = NSMenuItem(title: "Split Right", action: #selector(splitFocusedPaneRight), keyEquivalent: "d")
        splitRight.keyEquivalentModifierMask = [.command]
        splitRight.target = self
        let splitDown = NSMenuItem(title: "Split Down", action: #selector(splitFocusedPaneDown), keyEquivalent: "d")
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        splitDown.target = self
        surfaceMenu.addItem(splitRight)
        surfaceMenu.addItem(splitDown)
        surfaceItem.submenu = surfaceMenu

        // Tab
        // UX-MAC_SHELL_WINDOW-002: keyboard navigation for the tab strip.
        let tabItem = NSMenuItem()
        mainMenu.addItem(tabItem)
        let tabMenu = NSMenu(title: "Tab")
        let nextTab = NSMenuItem(title: "Next Tab", action: #selector(selectNextTab), keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        nextTab.target = self
        let prevTab = NSMenuItem(title: "Previous Tab", action: #selector(selectPreviousTab), keyEquivalent: "[")
        prevTab.keyEquivalentModifierMask = [.command, .shift]
        prevTab.target = self
        tabMenu.addItem(nextTab)
        tabMenu.addItem(prevTab)
        tabMenu.addItem(.separator())
        for n in 1...9 {
            let item = NSMenuItem(title: "Select Tab \(n)", action: #selector(selectTabByNumber(_:)), keyEquivalent: "\(n)")
            item.keyEquivalentModifierMask = [.command]
            item.tag = n
            item.target = self
            tabMenu.addItem(item)
        }
        tabMenu.addItem(.separator())
        let nextPane = NSMenuItem(title: "Focus Next Pane", action: #selector(focusNextPane), keyEquivalent: "\t")
        nextPane.keyEquivalentModifierMask = [.control]
        nextPane.target = self
        tabMenu.addItem(nextPane)
        tabItem.submenu = tabMenu

        // Window
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "RemoteCode"
        alert.informativeText = "Native Swift macOS rewrite. cmux-style panes + Agent App surface."
        alert.runModal()
    }

    /// Opens the diagnostics folder in Finder so users can locate and attach
    /// lifecycle.log when filing a bug report about silent app disappearances.
    @objc private func revealDiagnosticsInFinder() {
        let dir = AppPaths.appSupportDirectory(for: channel, override: appSupportOverride)
            .appendingPathComponent("diagnostics", isDirectory: true)
        // Ensure directory exists even if no events have been recorded yet.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    /// Approve/deny modal for a device-initiated pairing request. The
    /// device shows the SAME code — the user confirms they match before
    /// approving (anti-MITM). Decision routes to the auth adapter; once
    /// approved the device's token is trusted and it never re-pairs.
    private func presentPairingPrompt(_ prompt: PairingPrompt) {
        let alert = NSAlert()
        alert.messageText = "Allow “\(prompt.deviceName)” to connect?"
        alert.informativeText = """
        A device wants to remote-control this Mac.

        Confirm this code matches the one shown on the device:

        \(prompt.code)
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Deny")
        NSApp.activate(ignoringOtherApps: true)
        let approved = alert.runModal() == .alertFirstButtonReturn
        if approved { localAuth?.approvePairingRequest(prompt.requestId) }
        else { localAuth?.denyPairingRequest(prompt.requestId) }
    }

    private func applyKeybindingOverride(to item: NSMenuItem, command: String) {
        let cfg = KeybindingConfig.loadDefaultPath()
        guard let binding = cfg.bindings.last(where: { $0.command == command }) else { return }
        var mask: NSEvent.ModifierFlags = []
        var ch = ""
        for t in binding.key.split(separator: "+").map(String.init) {
            switch t {
            case "mod": mask.insert(.command)
            case "ctrl": mask.insert(.control)
            case "alt", "opt": mask.insert(.option)
            case "shift": mask.insert(.shift)
            default: ch = t
            }
        }
        if !ch.isEmpty { item.keyEquivalent = ch; item.keyEquivalentModifierMask = mask }
    }

    @objc private func togglePalette() {
        palette?.toggle()
    }

    @objc private func showSettings() {
        if let window = windowController?.window {
            settings?.show(attachedTo: window)
        } else {
            settings?.show()
        }
    }

    @objc func checkForUpdatesAction() {
        updater?.checkForUpdates()
    }

    // MARK: - NSMenuItemValidation

    /// Pure helper: given a menu item action selector and whether an updater is
    /// configured, returns whether the item should be enabled.
    /// Extracted for unit-testing without any AppKit or @MainActor dependency.
    public static func menuItemEnabled(action: Selector, updaterConfigured: Bool) -> Bool {
        if action == #selector(AppDelegate.checkForUpdatesAction) {
            return updaterConfigured
        }
        // All other items this delegate owns are unconditionally enabled.
        return true
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        return Self.menuItemEnabled(action: action, updaterConfigured: updater != nil)
    }

    @objc private func newWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            _ = try? router.createWorkspace(name: url.lastPathComponent, cwd: url.path)
            // UX-MAC_SHELL_WINDOW-005: feed File ▸ Open Recent.
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
    }

    @objc private func newTerminal() { newSurface(type: .terminal) }
    @objc private func newBrowser() { newSurface(type: .browser) }
    @objc private func newAgentApp() { newSurface(type: .agentApp) }

    private func newSurface(type: SurfaceType) {
        guard let wid = context.state.window.selectedWorkspaceID else { NSSound.beep(); return }
        _ = try? router.createSurface(workspace: wid, type: type, paneID: nil, title: nil)
    }

    // UX-MAC_SHELL_WINDOW-004: keyboard split entry points.
    @objc private func splitFocusedPaneRight() {
        if windowController?.splitFocusedPane(.right) != true { NSSound.beep() }
    }

    @objc private func splitFocusedPaneDown() {
        if windowController?.splitFocusedPane(.down) != true { NSSound.beep() }
    }

    // MARK: - Tab keyboard navigation (UX-MAC_SHELL_WINDOW-002/003)

    /// The focused pane of the selected workspace, plus its ordered
    /// surfaces and the currently selected surface index.
    private func focusedPaneContext() -> (workspace: WorkspaceID, surfaces: [SurfaceDescriptor], selectedIndex: Int)? {
        guard let wid = context?.state.window.selectedWorkspaceID,
              let ws = context?.state.workspaces[wid] else { return nil }
        let paneID = ws.focusedPaneID ?? ws.layout.paneIDs().first
        guard let paneID, let pane = ws.layout.find(paneID: paneID),
              !pane.surfaces.isEmpty else { return nil }
        let selected = pane.selectedSurfaceID ?? pane.surfaces.first?.id
        let index = pane.surfaces.firstIndex { $0.id == selected } ?? 0
        return (wid, pane.surfaces, index)
    }

    @objc private func selectNextTab() { stepTab(by: 1) }
    @objc private func selectPreviousTab() { stepTab(by: -1) }

    private func stepTab(by delta: Int) {
        guard let ctx = focusedPaneContext(), ctx.surfaces.count > 1 else { NSSound.beep(); return }
        let count = ctx.surfaces.count
        let next = ((ctx.selectedIndex + delta) % count + count) % count
        try? router?.focusSurface(workspace: ctx.workspace, surface: ctx.surfaces[next].id)
    }

    @objc private func selectTabByNumber(_ sender: NSMenuItem) {
        guard let ctx = focusedPaneContext(),
              sender.tag >= 1, sender.tag <= ctx.surfaces.count else { NSSound.beep(); return }
        try? router?.focusSurface(workspace: ctx.workspace, surface: ctx.surfaces[sender.tag - 1].id)
    }

    @objc private func closeActiveTabOrWindow() {
        // Route through the window controller so the focused pane's
        // unsaved-changes confirm runs; fall back to closing the key
        // window only when no surface is open.
        if windowController?.closeFocusedSurface() == true { return }
        (NSApp.keyWindow ?? window)?.performClose(nil)
    }

    @objc private func focusNextPane() {
        guard let wid = context?.state.window.selectedWorkspaceID,
              let ws = context?.state.workspaces[wid] else { NSSound.beep(); return }
        let paneIDs = ws.layout.paneIDs()
        guard paneIDs.count > 1 else { NSSound.beep(); return }
        let current = ws.focusedPaneID ?? paneIDs.first
        let idx = current.flatMap { paneIDs.firstIndex(of: $0) } ?? 0
        let nextPane = paneIDs[(idx + 1) % paneIDs.count]
        guard let pane = ws.layout.find(paneID: nextPane),
              let surface = pane.selectedSurfaceID ?? pane.surfaces.first?.id else { NSSound.beep(); return }
        try? router?.focusSurface(workspace: wid, surface: surface)
    }

    private var window: NSWindow? { windowController?.window }

    // MARK: - Notification deep-link routing

    private func handleNotificationResponse(_ response: UNNotificationResponse) {
        let userInfo = response.notification.request.content.userInfo
        let stringInfo = Dictionary(userInfo.compactMap { (k, v) -> (String, String)? in
            guard let ks = k as? String, let vs = v as? String else { return nil }
            return (ks, vs)
        }, uniquingKeysWith: { a, _ in a })
        guard let intent = Self.routeFromNotification(userInfo: stringInfo) else { return }
        windowController?.show()
        if let wid = intent.workspaceId {
            try? router?.selectWorkspace(wid)
        }
        try? router?.selectAgentThread(thread: intent.threadId)
    }

    /// Pure mapper: notification userInfo -> RouteIntent.
    /// Returns nil when `threadId` key is absent or not a valid UUID.
    /// `workspaceId` is optional; absent or invalid value yields nil workspace.
    public static func routeFromNotification(userInfo: [String: String]) -> NotificationRouteIntent? {
        guard let raw = userInfo["threadId"],
              let uuid = UUID(uuidString: raw) else { return nil }
        let workspaceId = userInfo["workspaceId"]
            .flatMap { UUID(uuidString: $0) }
            .map { WorkspaceID($0) }
        return NotificationRouteIntent(threadId: AgentThreadID(uuid), workspaceId: workspaceId)
    }

    /// GAP-4: publish `_remotecode._tcp` so the iOS app can find this
    /// Mac on the LAN. TXT carries the stable identity + version so the
    /// client can show it before connecting.
    private func publishBonjour(serverId: String) {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let svc = NetService(domain: "", type: "_remotecode._tcp.", name: name, port: 18217)
        let txt: [String: Data] = [
            "server_id": Data(serverId.utf8),
            "app": Data("remotecode".utf8),
            "version": Data(AppVersion.short.utf8),
            "api": Data("2".utf8)
        ]
        svc.setTXTRecord(NetService.data(fromTXTRecord: txt))
        svc.delegate = bonjourDelegate
        svc.publish()
        bonjour = svc
        NSLog("Bonjour published: \(name) _remotecode._tcp:18217")
    }
}

/// Logs Bonjour publish outcome; a publish failure must be loud, not
/// silent, or the iOS app simply never sees this Mac (Rule 6).
final class BonjourDelegate: NSObject, NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        NSLog("Bonjour: did publish \(sender.name)")
    }
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        NSLog("Bonjour: FAILED to publish \(sender.name): \(errorDict)")
    }
}

/// Decoded intent from a tapped notification. Carries the thread (and
/// optionally the workspace) to navigate to. Workspace is absent when
/// the notification payload does not carry `workspaceId` — the router
/// can still find the thread by ID alone.
public struct NotificationRouteIntent: Equatable {
    public let threadId: AgentThreadID
    public let workspaceId: WorkspaceID?

    public init(threadId: AgentThreadID, workspaceId: WorkspaceID?) {
        self.threadId = threadId
        self.workspaceId = workspaceId
    }
}

extension SurfaceType {
    /// Human-facing label, mirrors cmux terminology.
    public var displayLabel: String {
        switch self {
        case .terminal: return "Terminal"
        case .ssh: return "SSH"
        case .browser: return "Browser"
        case .agentApp: return "Agent App"
        case .files: return "Files"
        case .markdown: return "Markdown"
        case .filePreview: return "File Preview"
        case .rightSidebarTool: return "Right Sidebar Tool"
        }
    }
}
