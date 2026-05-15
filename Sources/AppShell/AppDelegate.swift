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
            alert.messageText = "Failed to bootstrap RemoteCode 2"
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
        // Rebuild Surface objects from restored layout descriptors.
        router.reinstantiateRestoredSurfaces()

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

        // Start direct HTTP server bound to loopback by default.
        let remoteEnabled = (try? context.settingsRepo.get("remote_access_enabled")) ?? "0"
        let loopbackOnly = remoteEnabled != "1"
        let trustRepo = DeviceTrustRepository(db: context.db)
        let auth = LocalAuthAdapter(repo: trustRepo)
        let http = DirectHTTPServer(port: 18217, loopbackOnly: loopbackOnly, dispatcher: dispatcher, auth: auth)
        do {
            try http.start()
            httpServer = http
            NSLog("Direct HTTP server listening on 127.0.0.1:18217 (loopback=\(loopbackOnly))")
        } catch {
            NSLog("Failed to start HTTP server: \(error)")
        }

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
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About RemoteCode 2", action: #selector(showAbout), keyEquivalent: ""))
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide RemoteCode 2", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit RemoteCode 2", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
        paletteItem.keyEquivalentModifierMask = [.command, .shift]
        paletteItem.target = self
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
        alert.messageText = "RemoteCode 2"
        alert.informativeText = "Native Swift macOS rewrite. cmux-style panes + Agent App surface."
        alert.runModal()
    }

    @objc private func togglePalette() {
        palette?.toggle()
    }

    @objc private func showSettings() {
        settings?.show()
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
}

extension SurfaceType {
    /// Human-facing label, mirrors cmux terminology.
    public var displayLabel: String {
        switch self {
        case .terminal: return "Terminal"
        case .browser: return "Browser"
        case .agentApp: return "Agent App"
        case .markdown: return "Markdown"
        case .filePreview: return "File Preview"
        case .rightSidebarTool: return "Right Sidebar Tool"
        }
    }
}
