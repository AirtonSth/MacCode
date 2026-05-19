import Foundation
import AppKit
import CoreModel
import Persistence
import AgentRuntime
import SocketServer

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
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
    public let channel: ReleaseChannel
    private let appSupportOverride: String?
    private let dbOverride: String?

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
        router = AppCommandRouter(context: context)
        context.router = router

        // Wire EventBus to the persisted event log so events survive restart.
        let log = context.eventLog
        EventBus.shared.persister = { ev in
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
        windowController = MainWindowController(context: context, router: router)
        router.windowController = windowController
        // Rebuild Surface objects from restored layout descriptors, then
        // refresh so the restored workspaces + tabs actually render
        // (the controller's init refresh ran before surfaces existed).
        router.reinstantiateRestoredSurfaces()
        windowController.refreshFromState()

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
        let auth = LocalAuthAdapter(repo: trustRepo)
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
        settings = SettingsWindowController(context: context)
        SystemNotifier.shared.bootstrap()

        installMainMenu()
        windowController.show()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        context?.saveSnapshot()
        socketServer?.stop()
        httpServer?.stop()
        bonjour?.stop()
        NotificationCenter.default.removeObserver(self)
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

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About RemoteCode", action: #selector(showAbout), keyEquivalent: ""))
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
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
        fileMenu.addItem(.separator())
        let closeWin = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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
        surfaceItem.submenu = surfaceMenu

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

    @objc private func newWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            _ = try? router.createWorkspace(name: url.lastPathComponent, cwd: url.path)
        }
    }

    @objc private func newTerminal() { newSurface(type: .terminal) }
    @objc private func newBrowser() { newSurface(type: .browser) }
    @objc private func newAgentApp() { newSurface(type: .agentApp) }

    private func newSurface(type: SurfaceType) {
        guard let wid = context.state.window.selectedWorkspaceID else { NSSound.beep(); return }
        _ = try? router.createSurface(workspace: wid, type: type, paneID: nil, title: nil)
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
            "version": Data("0.1.0".utf8),
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

extension SurfaceType {
    /// Human-facing label, mirrors cmux terminology.
    public var displayLabel: String {
        switch self {
        case .terminal: return "Terminal"
        case .browser: return "Browser"
        case .agentApp: return "Agent App"
        case .files: return "Files"
        case .markdown: return "Markdown"
        case .filePreview: return "File Preview"
        case .rightSidebarTool: return "Right Sidebar Tool"
        }
    }
}
