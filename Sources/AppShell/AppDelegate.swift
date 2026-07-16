import Foundation
import AppKit
import CoreModel
import Persistence
import AgentRuntime
import SocketServer
import Surfaces
import AppLifecycleSupport
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

    /// GAP-5 retention seam. `DirectHTTPServer.auth` is a *weak* ref, so the
    /// app delegate is the sole strong owner; this method makes that ownership
    /// the single, named, testable assignment. A regression that turns
    /// `authProvider` into a weak/unowned ref (or drops this call) lets the
    /// provider deallocate and silently disables pairing AND the LAN auth gate.
    /// `authProviderIsRetained` lets a test observe the strong ref survives a
    /// dropped local reference without spinning up the full HTTP stack.
    func retainAuthProvider(_ provider: DirectAuthProvider) {
        authProvider = provider
    }

    /// True iff a strong reference to an auth provider is currently held.
    /// Used by the GAP-5 regression test to fail loud if the strong owner
    /// is ever removed.
    var authProviderIsRetained: Bool { authProvider != nil }
    private var bonjour: NetService?
    private let bonjourDelegate = BonjourDelegate()
    private var directAccessSupervisor: DirectAccessLifecycleSupervisor?
    public var palette: CommandPalette?
    public var settings: SettingsWindowController?
    public private(set) var petController: PetController?
    public var updater: AppUpdateChecking?
    var keyWindowProviderForTests: (() -> NSWindow?)?
    public let channel: ReleaseChannel
    private let appSupportOverride: String?
    private let dbOverride: String?
    private var providerSessionReaperTimer: Timer?
    private var ccrRetentionTimer: Timer?
    private var diagnosticsHeartbeatTimer: Timer?
    private var tokenSaverAccountUsageRefreshTimer: Timer?
    private var lifecycleRecorder: AppLifecycleRecorder?
    /// Menu items whose keyEquivalent is controlled by keybindings.json.
    /// Populated by installMainMenu(); refreshed by reapplyKeybindingOverrides().
    private var keybindableMenuItems: [(item: NSMenuItem, command: String)] = []
    public static let tokenSaverAccountUsageRefreshInterval: TimeInterval = 5 * 60

    /// Accumulates server startup failures so Settings can show a status
    /// row rather than relying on NSLog alone (UX-MAC_SOCKET_SERVER-P1).
    /// Populated at most once per server per launch; cleared on re-configure.
    public private(set) var serverStartupFailures: [(server: String, reason: String)] = []

    /// True once the first denied-post notice has been fired this session.
    /// Guards `handleDeniedPost` so the user sees the notice at most once
    /// per launch regardless of how many runs finish while notifications are off.
    private var notificationsDeniedNoticeFired = false

    /// Notification name posted (on the main thread) when a server startup
    /// failure is recorded. Observers receive the `serverStartupFailures` array
    /// via `AppDelegate.shared?.serverStartupFailures` after the post.
    public static let serverStartupFailureNotification = Notification.Name("io.remotecode.serverStartupFailure")

    public init(channel: ReleaseChannel = .debug, appSupportOverride: String? = nil, dbOverride: String? = nil) {
        self.channel = channel
        self.appSupportOverride = appSupportOverride
        self.dbOverride = dbOverride
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let appSupportDirectory = AppPaths.appSupportDirectory(
            for: channel,
            override: appSupportOverride
        )
        ProviderProcessOwnership.shared.configure(
            fileURL: appSupportDirectory
                .appendingPathComponent("diagnostics", isDirectory: true)
                .appendingPathComponent("provider-process-ownership.json", isDirectory: false)
        )
        do {
            context = try AppContext(channel: channel, dbPathOverride: dbOverride, appSupportOverride: appSupportOverride)
        } catch {
            // UX-MAC_PERSISTENCE-P1: plain-language copy + recovery guidance.
            // The most common causes are a permissions error on first launch
            // or a half-written database after an abrupt kill. A fresh database
            // is stored alongside the corrupt one (Bootstrap quarantines it),
            // so the user can recover by deleting remotecode.sqlite and relaunching.
            let supportDir = AppPaths.appSupportDirectory(for: channel, override: appSupportOverride).path
            let alert = NSAlert()
            alert.messageText = "RemoteCode could not open its database"
            alert.informativeText = Self.dbOpenFailureInformativeText(
                supportDir: supportDir,
                errorDescription: error.localizedDescription
            )
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Show in Finder")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: supportDir, isDirectory: true)]
                )
            }
            NSApp.terminate(nil)
            return
        }

        // UX-MAC_PERSISTENCE-P1: inform the user when a corrupt database was
        // silently quarantined so they know prior data was preserved as a backup.
        if context.bootstrapReport.recoveredFromCorruption {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Previous database was corrupt"
                alert.informativeText = """
                    RemoteCode found and quarantined a corrupt database, then started \
                    fresh. Your previous data is preserved as a backup file (suffix \
                    ".corrupt-<date>") in:

                    \(self.context.bootstrapReport.path.components(separatedBy: "/").dropLast().joined(separator: "/"))

                    Workspaces, settings, and history from this session will be saved normally.
                    """
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Show in Finder")
                if alert.runModal() == .alertSecondButtonReturn {
                    let dir = URL(fileURLWithPath: self.context.bootstrapReport.path)
                        .deletingLastPathComponent()
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            }
        }

        installLifecycleRecorder()
        // PERF (cold launch): the orphan provider sweep is a process scan and
        // the event-log decode + PTY restore are heavy. StartupPlan defers them
        // past the first frame; see runDeferredStartup().
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
        do {
            EventBus.shared.reloadFromPersistence(lastSeq: try log.lastSeq(), recent: [])
        } catch {
            appLifecycleLog.error("event_log.sequence_init_failed error=\(error.localizedDescription, privacy: .public)")
        }
        updater = SparkleAppUpdater.defaultIfConfigured()
        updater?.onWillInstallUpdate = { [weak self] in
            self?.persistRestorableStateBeforeUpdate()
        }
        windowController = MainWindowController(context: context, router: router, updater: updater)
        router.windowController = windowController
        settings = SettingsWindowController(context: context, updater: updater)
        startPetController()

        // start unix socket server
        let socketPath = AppPaths.socketPath(for: channel)
        let dispatcher = JSONRPCDispatcher(router: router)
        let server = UnixSocketServer(socketPath: socketPath, dispatcher: dispatcher)
        do {
            try server.start()
            socketServer = server
            try? Self.resolvePetServerFailure(
                server: "rc2 socket",
                repository: NotificationRepository(db: context.db)
            )
        } catch {
            NSLog("Failed to start socket server: \(error)")
            recordServerStartupFailure("rc2 socket", reason: error.localizedDescription)
        }

        let trustRepo = DeviceTrustRepository(db: context.db)
        let auth = LocalAuthAdapter(
            repo: trustRepo,
            privateAccountStore: PrivateAccountSessionStore(repo: context.settingsRepo)
        )
        retainAuthProvider(auth)   // GAP-5: retain for process lifetime
        localAuth = auth
        // A device-initiated pair request pops an approve/deny modal on
        // the Mac. The HTTP handler invokes this off the listener thread;
        // hop to main for AppKit. The device polls /v1/pair/status mean-
        // while, so the server never blocks on the user's decision.
        auth.onPairingRequest = { [weak self] prompt in
            DispatchQueue.main.async { self?.presentPairingPrompt(prompt) }
        }
        // The device can cancel its own outstanding request (POST
        // /v1/pair/cancel). Fired off the listener thread; hop to main and
        // dismiss the approve/deny modal if it is showing that request.
        auth.onPairingCancelled = { [weak self] requestId in
            DispatchQueue.main.async { self?.dismissPairingSheetIfShowing(requestId: requestId) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(remoteAccessSettingChanged),
                                               name: .rc2RemoteAccessSettingChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keybindingsReloaded),
                                               name: .rc2KeybindingsReloaded, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        configureDirectAccess()

        palette = CommandPalette(router: router)
        SystemNotifier.shared.bootstrap()
        SystemNotifier.shared.onNotificationResponse = { [weak self] response in
            self?.handleNotificationResponse(response)
        }
        // UX-MAC_APPSHELL-P2: when OS permission is denied, surface an in-app
        // notice so a finished run is not invisible. Fired at most once per
        // session (notificationsDeniedNoticeFired gate) to avoid spam.
        SystemNotifier.shared.onDeniedPost = { [weak self] content in
            self?.handleDeniedPost(content)
        }
        reapIdleProviderSessions()
        providerSessionReaperTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in
            guard let delegate = self else { return }
            Task { @MainActor in
                delegate.reapIdleProviderSessions()
            }
        }

        runCCRRetention()
        ccrRetentionTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            guard let delegate = self else { return }
            Task { @MainActor in
                delegate.runCCRRetention()
            }
        }

        installMainMenu()
        windowController.show()
        refreshTokenSaverAccountUsageOnLaunch()
        startTokenSaverAccountUsageRefreshLoop()
        startDiagnosticsHeartbeat()
        logDiagnosticsHeartbeat(reason: "launch")
        checkForUpdatesAfterOpeningApp()

        // PERF (cold launch): the first frame has now painted (show() above), so
        // the "Restoring workspaces..." affordance can animate while the heavy,
        // frame-irrelevant restore work runs. StartupPlan.deferredSteps decide
        // what lands here. Hopping back through the main queue yields one runloop
        // turn for the frame before the PTY spawns / process scan begin.
        DispatchQueue.main.async { [weak self] in
            // Explain folder TCC before restored surfaces/PTYs touch protected paths.
            self?.presentHostFileAccessOnboardingIfNeeded()
            self?.runDeferredStartup()
        }
    }

    /// One-time explanation for Files and Folders TCC. macOS cannot grant all
    /// folder permissions in one API call. Every alert button marks onboarding
    /// *handled* (not “permissions granted”) so launch never nags in a loop.
    func presentHostFileAccessOnboardingIfNeeded() {
        guard let context else { return }
        let repo = SettingsRepository(db: context.db)
        guard HostFileAccessOnboarding.shouldPresent(
            handled: HostFileAccessOnboarding.isHandled(repo: repo)
        ) else { return }

        let alert = NSAlert()
        alert.messageText = HostFileAccessCopy.onboardingTitle
        alert.informativeText = HostFileAccessCopy.onboardingMessage
        if let warning = HostCodeSignatureReader.current().adHocWarning {
            alert.informativeText += "\n\n" + warning
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        let response = alert.runModal()
        do {
            try HostFileAccessOnboarding.handleAlertResponse(
                response,
                markHandled: { try HostFileAccessOnboarding.markHandled(repo: repo) },
                openSystemSettings: {
                    NSWorkspace.shared.open(HostFileAccessSystemSettings.filesAndFoldersURL)
                },
                checkFolderAccess: {
                    _ = HostFileAccessProber.probeStandardTargets()
                }
            )
        } catch {
            appLifecycleLog.error(
                "host_file_access.onboarding_persist_failed error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// PERF (cold launch): the StartupPlan-deferred steps -- orphan provider
    /// sweep (process scan), persisted event-log read + JSON decode of up to 256
    /// payloads, and reinstantiating restored surfaces (a PTY spawn per restored
    /// terminal). Runs after the first frame so launch is not blocked.
    private func runDeferredStartup() {
        terminateOrphanedProviderRuntimes(reason: "launch")

        if let log = context?.eventLog {
            do {
                let rows = try log.read(since: 0, limit: 256)
                let events = rows.compactMap { row -> EventBus.Event? in
                    guard let data = row.payloadJSON.data(using: .utf8),
                          let val = try? JSONDecoder().decode(JSONValue.self, from: data)
                    else { return nil }
                    return EventBus.Event(seq: row.seq, kind: row.kind, payload: val, ts: Date().timeIntervalSince1970)
                }
                EventBus.shared.reloadFromPersistence(lastSeq: try log.lastSeq(), recent: events)
            } catch {
                appLifecycleLog.error("event_log.deferred_reload_failed error=\(error.localizedDescription, privacy: .public)")
            }
        }

        // Rebuild Surface objects from restored layout descriptors, then drop
        // the restoring affordance and render the real layout.
        router?.reinstantiateRestoredSurfaces()
        Task { @MainActor [weak self] in
            await self?.router?.reconcileQueuedAgentMessagesOnLaunch()
        }
        windowController?.markRestorationComplete()
    }

    func startPetController() {
        guard petController == nil, let context, let router else { return }
        do {
            let controller = try PetController(
                context: context,
                router: router,
                openSettings: { [weak self] route in
                    guard let self, let settings = self.settings else { return false }
                    if let window = self.windowController?.window {
                        return settings.show(route: route, attachedTo: window)
                    }
                    return settings.show(route: route)
                }
            )
            petController = controller
            controller.start()
        } catch {
            appLifecycleLog.error("pet.start_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func stopPetController() {
        petController?.stop()
        petController = nil
    }

    public func checkForUpdatesAfterOpeningApp() {
        updater?.checkForUpdates()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        appLifecycleLog.info("app.will_terminate pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public)")
        lifecycleRecorder?.endRunCleanly(reason: "applicationWillTerminate")
        logDiagnosticsHeartbeat(reason: "will_terminate")
        disableInsomniaForAppClose()
        // Only tear down the managed distill integration when Token Saver is already
        // disabled. When it is enabled the integration (PATH symlink + skills) should
        // survive app-quit so the user's shell keeps working between runs. On the next
        // launch AppContext.init reconciles again and reinstalls whatever is needed.
        let tokenSaverEnabled = context.map { SettingsStore(db: $0.db).load().tokenSaverEnabled } ?? false
        if tokenSaverEnabled {
            appLifecycleLog.info("app.will_terminate distill_integration=retained token_saver=enabled")
        } else {
            appLifecycleLog.info("app.will_terminate distill_integration=removing token_saver=disabled")
            context?.reconcileManagedDistillSkills(tokenSaverEnabled: false)
        }
        persistRestorableStateBeforeUpdate()
        stopPetController()
        stopLiveRuntimesForAppTermination()
        socketServer?.stop()
        directAccessSupervisor?.shutdown()
        directAccessSupervisor = nil
        providerSessionReaperTimer?.invalidate()
        ccrRetentionTimer?.invalidate()
        diagnosticsHeartbeatTimer?.invalidate()
        tokenSaverAccountUsageRefreshTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
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
        context?.coordinator.stopAllProviderSessionsForAppTermination()
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
        terminateOrphanedProviderRuntimes(reason: "periodic")
        AppDiagnostics.heartbeat(
            reason: reason,
            activeAgentThreads: context?.coordinator.activeThreadIdsSnapshot().count ?? 0,
            lifecycleRecorder: lifecycleRecorder
        )
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
        do {
            let result = try ProviderProcessSweeper.terminatePersistedOrphanedProviderRuntimes(
                minAge: reason == "launch" ? 0 : ProcessSpawnTagger.defaultMinAge
            )
            guard !result.orphanRootPIDs.isEmpty || !result.failedPIDs.isEmpty else { return }
            appLifecycleLog.info("provider.orphan_sweep reason=\(reason, privacy: .public) roots=\(result.orphanRootPIDs.count, privacy: .public) terminated=\(result.terminatedPIDs.count, privacy: .public) failed=\(result.failedPIDs.count, privacy: .public)")
        } catch {
            // The ledger remains intact. Surface the failed audit instead of
            // reporting the indistinguishable all-clear result used previously.
            appLifecycleLog.fault("provider.orphan_sweep_failed reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
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

    /// Run CCR retention off the main thread. Dispatched to backgroundWriterQueue so
    /// the SQLite DELETE never blocks the main actor. Cadence: once on launch +
    /// every 24 hours via ccrRetentionTimer. No-op when context is nil (before init).
    private func runCCRRetention() {
        guard let ctx = context else { return }
        let store = ReversibleContentStore(db: ctx.db)
        let queue = ctx.backgroundWriterQueue
        queue.async {
            let now = Date()
            let cutoffMs = CCRRetentionJob.olderThanMs(now: now)
            do {
                let removed = try CCRRetentionJob.runRetention(store: store, now: now, cutoffMs: cutoffMs)
                if removed > 0 {
                    NSLog("CCR retention pruned \(removed) stale reversible-content row(s).")
                }
            } catch {
                NSLog("CCR retention failed: \(error)")
            }
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

    @objc private func workspaceWillSleep() {
        directAccessSupervisor?.suspend()
    }

    @objc private func workspaceDidWake() {
        guard let context else { return }
        let remoteEnabled = ((try? context.settingsRepo.get("remote_access_enabled")) ?? "0") == "1"
        do {
            try directAccessSupervisor?.resume(remoteEnabled: remoteEnabled)
        } catch {
            NSLog("Failed to restart HTTP server after wake: \(error)")
            recordServerStartupFailure("HTTP server", reason: error.localizedDescription)
        }
    }

    /// Invoked when KeybindingsSettingsPane posts `.rc2KeybindingsReloaded`
    /// (file-watcher change or manual Reload). The cache is already invalidated
    /// by the pane before the post; re-running applyKeybindingOverride here
    /// reads the updated file and sets the live keyEquivalent on every menu item
    /// that participates in keybindings.json without a relaunch.
    @objc private func keybindingsReloaded() {
        // Cache was already invalidated by the pane; calling invalidateCache()
        // again here is a no-op except it guarantees correctness if this observer
        // is ever triggered from a path other than the pane's reload().
        KeybindingConfig.invalidateCache()
        for entry in keybindableMenuItems {
            applyKeybindingOverride(to: entry.item, command: entry.command)
        }
    }

    /// Records a server startup failure, appends to `serverStartupFailures`,
    /// posts a notification, and logs via the lifecycle recorder.
    /// The method is `nonisolated` in name only — callers on the main actor
    /// call it synchronously; the notification is always posted on the main thread.
    private func recordServerStartupFailure(_ server: String, reason: String) {
        serverStartupFailures.append((server: server, reason: reason))
        lifecycleRecorder?.record("server_startup_failure server=\(server) reason=\(reason)")
        if let context {
            do {
                try Self.projectPetServerFailure(
                    server: server,
                    repository: NotificationRepository(db: context.db)
                )
            } catch {
                appLifecycleLog.error("pet.server_failure_projection_failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
        NotificationCenter.default.post(name: Self.serverStartupFailureNotification, object: self)
    }

    static func petServerFailureID(server: String) -> String {
        let stableServer = server.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
        return "pet.server-failure.\(stableServer)"
    }

    @discardableResult
    static func projectPetServerFailure(
        server: String,
        repository: NotificationRepository
    ) throws -> String {
        let id = petServerFailureID(server: server)
        let category = PetNotificationCategory.serverListenerFailed
        try repository.resurface(AppNotification(
            id: id,
            title: category.presentation.title,
            body: nil,
            category: category.rawValue
        ))
        EventBus.shared.publish(kind: "notification.created", payload: .object([
            "id": .string(id),
            "category": .string(category.rawValue)
        ]))
        return id
    }

    static func resolvePetServerFailure(
        server: String,
        repository: NotificationRepository
    ) throws {
        let id = petServerFailureID(server: server)
        try repository.markRead(id: id)
        EventBus.shared.publish(kind: "notification.read", payload: .object(["id": .string(id)]))
    }

    private func configureDirectAccess() {
        // Clear previous HTTP failure state so re-configure starts fresh.
        serverStartupFailures.removeAll { $0.server == "HTTP server" }

        guard let context, router != nil, localAuth != nil else {
            directAccessSupervisor?.shutdown()
            directAccessSupervisor = nil
            return
        }
        let remoteEnabled = (try? context.settingsRepo.get("remote_access_enabled")) ?? "0"
        let serverId = context.liveActivityHostIdentity.serverId
        let port = DirectAccessConfiguration.port()
        if directAccessSupervisor == nil {
            directAccessSupervisor = DirectAccessLifecycleSupervisor(
                startServer: { [weak self] enabled in
                    try self?.startDirectHTTPServer(remoteEnabled: enabled, serverId: serverId, port: port)
                },
                stopServer: { [weak self] in
                    self?.httpServer?.stop()
                    self?.httpServer = nil
                },
                publishBonjour: { [weak self] in
                    self?.publishBonjour(serverId: serverId, port: port)
                },
                stopBonjour: { [weak self] in
                    self?.bonjour?.stop()
                    self?.bonjour = nil
                },
                retryLogger: { attempt, delay, error in
                    let nsError = error as NSError
                    NSLog("Direct HTTP retry scheduled attempt=\(attempt) delay=\(delay)s reason=\(nsError.domain):\(nsError.code)")
                }
            )
        }
        do {
            try directAccessSupervisor?.configure(remoteEnabled: remoteEnabled == "1")
        } catch {
            NSLog("Failed to start HTTP server: \(error)")
            recordServerStartupFailure("HTTP server", reason: error.localizedDescription)
        }
    }

    private func startDirectHTTPServer(remoteEnabled: Bool, serverId: String, port: UInt16) throws {
        guard let context, let router, let auth = localAuth else { return }
        let loopbackOnly = !remoteEnabled
        let dispatcher = JSONRPCDispatcher(router: router)
        let http = DirectHTTPServer(port: port, loopbackOnly: loopbackOnly,
                                    dispatcher: dispatcher, auth: auth, serverId: serverId,
                                    bootEpoch: context.liveActivityHostIdentity.bootEpoch)
        try http.start()
        httpServer = http
        try? Self.resolvePetServerFailure(
            server: "HTTP server",
            repository: NotificationRepository(db: context.db)
        )
        NSLog("Direct HTTP server listening on \(loopbackOnly ? "127.0.0.1" : "0.0.0.0"):\(port) (loopback=\(loopbackOnly))")
        if loopbackOnly {
            NSLog("Bonjour not published: remote access is disabled")
        }
    }

    /// Pure builder for the Bonjour TXT record (GAP-4/T021). Extracted so the
    /// exact keys/values the iOS client reads before connecting are pinned by
    /// a test; a dropped or renamed key silently makes this Mac undiscoverable
    /// or mis-identified. Values are UTF-8 Data exactly as `setTXTRecord` needs.
    nonisolated static func bonjourTXTRecord(serverId: String, version: String) -> [String: Data] {
        [
            "server_id": Data(serverId.utf8),
            "app": Data("remotecode".utf8),
            "version": Data(version.utf8),
            "api": Data("2".utf8)
        ]
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
        let reopenTab = NSMenuItem(title: "Reopen Closed Tab", action: #selector(reopenClosedTab), keyEquivalent: "t")
        reopenTab.keyEquivalentModifierMask = [.command, .shift]
        reopenTab.target = self
        fileMenu.addItem(reopenTab)
        let closeWin = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeWin.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closeWin)
        fileMenuItem.submenu = fileMenu

        // Edit
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        // UX-MAC_SHELL_WINDOW-008: Undo/Redo route through the responder chain
        // to the first-responder's NSUndoManager (rename fields, description
        // editors, prompt composer). Without these items ⌘Z produces no result.
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
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
        keybindableMenuItems = [(item: paletteItem, command: "commandPalette.toggle")]
        viewMenu.addItem(paletteItem)
        let petItem = NSMenuItem(
            title: "Open Remote Code Pet",
            action: #selector(togglePetPopoverFromMenu),
            keyEquivalent: "p"
        )
        petItem.keyEquivalentModifierMask = [.command, .option]
        petItem.target = self
        viewMenu.addItem(petItem)
        // UX-MAC_APPSHELL-TOKENSAVER-KEYBOARD: keyboard-reachable Token Saver toggle
        // (Cmd+Shift+S). Posts rc2TokenSaverToggle; SidebarViewModel observes and
        // calls setTokenSaverEnabled(!current). Cmd+Shift+S is unused in this menu map.
        let tokenSaverToggleItem = NSMenuItem(title: "Toggle Token Saver", action: #selector(toggleTokenSaverFromMenu), keyEquivalent: "s")
        tokenSaverToggleItem.keyEquivalentModifierMask = [.command, .shift]
        tokenSaverToggleItem.target = self
        viewMenu.addItem(tokenSaverToggleItem)
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

    // MARK: - About panel

    /// Pure helper: builds the options dict for `orderFrontStandardAboutPanel`.
    ///
    /// Rules:
    ///   - `version` is always included as `.applicationVersion`.
    ///   - `build` is included as `.version` only when it is non-nil and
    ///     differs from `version` (avoids a redundant "1.2.3 (1.2.3)" line).
    ///   - For non-stable channels a credits line naming the channel is
    ///     included so the build provenance is visible in the About panel.
    nonisolated static func aboutPanelOptions(
        version: String,
        build: String?,
        channel: ReleaseChannel
    ) -> [NSApplication.AboutPanelOptionKey: Any] {
        var opts: [NSApplication.AboutPanelOptionKey: Any] = [:]
        opts[.applicationVersion] = version
        if let build, build != version {
            opts[.version] = build
        }
        if channel != .stable {
            opts[.credits] = NSAttributedString(string: channel.rawValue)
        }
        return opts
    }

    @objc private func showAbout() {
        let opts = Self.aboutPanelOptions(
            version: AppVersion.short,
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            channel: channel
        )
        NSApp.orderFrontStandardAboutPanel(options: opts)
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

    /// Non-blocking pairing sheet with live countdown tied to the request TTL.
    /// Replaces the blocking runModal so the main run loop is never stalled.
    /// Auto-dismisses when the TTL expires; the user can Approve or Deny at
    /// any point before expiry. Once dismissed (any path) the timer is cancelled.
    private var pairingSheet: NSPanel?
    private var pairingSheetTimer: Timer?
    private var pairingCountdownLabel: NSTextField?
    private var pairingAlwaysAllowCheckbox: NSButton?
    private var pairingPromptPending: PairingPrompt?

    private func presentPairingPrompt(_ prompt: PairingPrompt) {
        // Only one pairing sheet at a time. If a new request arrives while one
        // is open, deny the pending one first to avoid leaking approval state.
        if let pending = pairingPromptPending {
            localAuth?.denyPairingRequest(pending.requestId)
            dismissPairingSheet()
        }
        pairingPromptPending = prompt

        let ttl = prompt.expiresAt.timeIntervalSince(prompt.createdAt)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 290),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.title = "Pairing Request"
        panel.isMovableByWindowBackground = true
        panel.level = .modalPanel

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 290))

        // Device name label
        let heading = NSTextField(labelWithString: "Allow \"\(prompt.deviceName)\" to connect?")
        heading.font = NSFont.boldSystemFont(ofSize: 14)
        heading.alignment = .center
        heading.frame = NSRect(x: 20, y: 240, width: 360, height: 20)
        content.addSubview(heading)

        // UX-P2: always show the confirmation instruction; append source IP when
        // available so the user can cross-check the device identity without losing
        // the "check the code" prompt that was previously replaced by the IP.
        let infoText: String
        if let ip = prompt.sourceIP {
            infoText = "Confirm this code matches the device (from \(ip)):"
        } else {
            infoText = "Confirm this code matches the device:"
        }
        let info = NSTextField(labelWithString: infoText)
        info.alignment = .center
        info.textColor = .secondaryLabelColor
        info.frame = NSRect(x: 20, y: 215, width: 360, height: 18)
        content.addSubview(info)

        // Code display — expose digits individually for VoiceOver so the user
        // can verify each digit of the security code without mental grouping.
        let codeField = NSTextField(labelWithString: prompt.code)
        codeField.font = NSFont.monospacedDigitSystemFont(ofSize: 36, weight: .bold)
        codeField.alignment = .center
        codeField.frame = NSRect(x: 20, y: 155, width: 360, height: 50)
        codeField.setAccessibilityLabel(Self.pairingCodeAccessibilityLabel(prompt.code))
        content.addSubview(codeField)

        // Created-at detail
        let fmt = DateFormatter()
        fmt.dateStyle = .none
        fmt.timeStyle = .medium
        let createdLabel = NSTextField(labelWithString: "Requested at \(fmt.string(from: prompt.createdAt))")
        createdLabel.alignment = .center
        createdLabel.font = NSFont.systemFont(ofSize: 11)
        createdLabel.textColor = .secondaryLabelColor
        createdLabel.frame = NSRect(x: 20, y: 135, width: 360, height: 16)
        content.addSubview(createdLabel)

        // Countdown label
        let countdown = NSTextField(labelWithString: "")
        countdown.alignment = .center
        countdown.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        countdown.textColor = .secondaryLabelColor
        countdown.frame = NSRect(x: 20, y: 105, width: 360, height: 20)
        content.addSubview(countdown)
        pairingCountdownLabel = countdown

        if prompt.clientDeviceID != nil {
            let alwaysAllow = NSButton(checkboxWithTitle: "Always allow this device", target: nil, action: nil)
            alwaysAllow.frame = NSRect(x: 20, y: 70, width: 360, height: 22)
            alwaysAllow.toolTip = "Future pairing requests from this same device will be approved automatically until you turn this off in Settings."
            alwaysAllow.setAccessibilityIdentifier("pairing.alwaysAllow")
            content.addSubview(alwaysAllow)
            pairingAlwaysAllowCheckbox = alwaysAllow
        }

        // Approve button
        let approveBtn = NSButton(title: "Approve", target: self, action: #selector(pairingApprove))
        approveBtn.keyEquivalent = "\r"
        approveBtn.frame = NSRect(x: 220, y: 16, width: 160, height: 44)
        content.addSubview(approveBtn)

        // Deny button
        let denyBtn = NSButton(title: "Deny", target: self, action: #selector(pairingDeny))
        denyBtn.frame = NSRect(x: 20, y: 16, width: 160, height: 44)
        content.addSubview(denyBtn)

        panel.contentView = content
        pairingSheet = panel

        // Update countdown immediately, then each second.
        updatePairingCountdown(prompt: prompt, ttl: ttl)
        pairingSheetTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let p = self.pairingPromptPending else { return }
            if PairingCountdown.expired(createdAt: p.createdAt, ttl: ttl, now: Date()) {
                self.localAuth?.denyPairingRequest(p.requestId)
                self.dismissPairingSheet()
            } else {
                self.updatePairingCountdown(prompt: p, ttl: ttl)
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.orderFrontRegardless()
    }

    private func updatePairingCountdown(prompt: PairingPrompt, ttl: TimeInterval) {
        let secs = PairingCountdown.remainingSecs(createdAt: prompt.createdAt, ttl: ttl, now: Date())
        let intSecs = Int(secs.rounded(.up))
        pairingCountdownLabel?.stringValue = "Expires in \(intSecs)s"
    }

    @objc private func pairingApprove() {
        guard let prompt = pairingPromptPending else { return }
        localAuth?.approvePairingRequest(
            prompt.requestId,
            alwaysAllowPairing: pairingAlwaysAllowCheckbox?.state == .on
        )
        dismissPairingSheet()
    }

    @objc private func pairingDeny() {
        guard let prompt = pairingPromptPending else { return }
        localAuth?.denyPairingRequest(prompt.requestId)
        dismissPairingSheet()
    }

    /// Dismiss the approve/deny modal only if it is currently showing the
    /// request the device just cancelled. A no-op when no sheet is open or a
    /// different request is shown, so it never disturbs an unrelated prompt.
    private func dismissPairingSheetIfShowing(requestId: String) {
        guard pairingPromptPending?.requestId == requestId else { return }
        dismissPairingSheet()
    }

    private func dismissPairingSheet() {
        pairingSheetTimer?.invalidate()
        pairingSheetTimer = nil
        pairingSheet?.orderOut(nil)
        pairingSheet = nil
        pairingCountdownLabel = nil
        pairingAlwaysAllowCheckbox = nil
        pairingPromptPending = nil
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

    @objc private func toggleTokenSaverFromMenu() {
        NotificationCenter.default.post(name: .rc2TokenSaverToggle, object: nil)
    }

    @objc private func togglePetPopoverFromMenu() {
        if !togglePetPopover() {
            NSSound.beep()
        }
    }

    func togglePetPopover() -> Bool {
        petController?.togglePopoverFromKeyboard() == true
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

    /// Selectors that require at least one workspace to exist before they make
    /// any sense. Without a workspace the actions either beep (runtime guard) or
    /// crash; greying them out lets the responder chain give proper feedback and
    /// VoiceOver say "dimmed" instead of silently doing nothing.
    static let workspaceRequiredActions: Set<String> = [
        NSStringFromSelector(#selector(AppDelegate.newTerminal)),
        NSStringFromSelector(#selector(AppDelegate.newBrowser)),
        NSStringFromSelector(#selector(AppDelegate.newAgentApp)),
        NSStringFromSelector(#selector(AppDelegate.splitFocusedPaneRight)),
        NSStringFromSelector(#selector(AppDelegate.splitFocusedPaneDown)),
        NSStringFromSelector(#selector(AppDelegate.selectNextTab)),
        NSStringFromSelector(#selector(AppDelegate.selectPreviousTab)),
        NSStringFromSelector(#selector(AppDelegate.closeActiveTabOrWindow)),
        NSStringFromSelector(#selector(AppDelegate.reopenClosedTab)),
        NSStringFromSelector(#selector(AppDelegate.focusNextPane))
    ]

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

    /// Extended helper: also accounts for workspace presence for surface/tab
    /// actions. Kept separate so the existing `menuItemEnabled` signature is
    /// preserved and existing tests continue to compile unchanged.
    ///
    /// WHY: without `hasWorkspace` checks the Surface/Tab menu items are always
    /// active and produce a beep when no workspace is open — confusing for both
    /// sighted users and VoiceOver (UX-MAC_SHELL_WINDOW-013).
    public static func menuItemEnabled(
        action: Selector,
        updaterConfigured: Bool,
        hasWorkspace: Bool
    ) -> Bool {
        if workspaceRequiredActions.contains(NSStringFromSelector(action)) {
            return hasWorkspace
        }
        return menuItemEnabled(action: action, updaterConfigured: updaterConfigured)
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        let hasWorkspace = context?.state.window.selectedWorkspaceID != nil
        return Self.menuItemEnabled(action: action,
                                    updaterConfigured: updater != nil,
                                    hasWorkspace: hasWorkspace)
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
        let keyWindow = keyWindowProviderForTests?() ?? NSApp.keyWindow
        if keyWindow === settings?.window {
            settings?.close()
            return
        }
        // Route through the window controller so the focused pane's
        // unsaved-changes confirm runs; fall back to closing the key
        // window only when no surface is open.
        if windowController?.closeFocusedSurface() == true { return }
        (keyWindow ?? window)?.performClose(nil)
    }

    @objc private func reopenClosedTab() {
        guard let wid = context?.state.window.selectedWorkspaceID,
              let router else { NSSound.beep(); return }
        do {
            // Returns nil when the closed-tab buffer is empty; beep in that case.
            if try router.reopenClosedSurface(workspace: wid) == nil {
                NSSound.beep()
            }
        } catch {
            NSSound.beep()
        }
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

    // MARK: - Denied-notification in-app fallback (UX-MAC_APPSHELL-P2)

    /// Invoked by `SystemNotifier.shared.onDeniedPost`. Posts
    /// `SystemNotifier.rc2NotificationsDeniedPost` on the default
    /// `NotificationCenter` the first time it is called; subsequent calls
    /// are no-ops so the user is never spammed across multiple run completions.
    ///
    /// The once-only gate is a session-local `Bool` — intentionally not
    /// persisted, because the notice is only meaningful when the user is
    /// present and can act on it (open System Settings > Notifications).
    func handleDeniedPost(_ content: RemoteCodeNotificationContent) {
        guard Self.shouldFireDeniedNotice(alreadyFired: notificationsDeniedNoticeFired) else { return }
        notificationsDeniedNoticeFired = true
        NotificationCenter.default.post(
            name: SystemNotifier.rc2NotificationsDeniedPost,
            object: self,
            userInfo: ["threadId": content.userInfo["threadId"] ?? ""]
        )
    }

    /// Pure gate: returns true iff the once-only denied notice has not yet
    /// fired this session. Extracted so the decision is testable without
    /// any AppKit or @MainActor dependency.
    nonisolated static func shouldFireDeniedNotice(alreadyFired: Bool) -> Bool {
        !alreadyFired
    }

    // MARK: - Notification deep-link routing

    private func handleNotificationResponse(_ response: UNNotificationResponse) {
        let userInfo = response.notification.request.content.userInfo
        let stringInfo = Dictionary(userInfo.compactMap { (k, v) -> (String, String)? in
            guard let ks = k as? String, let vs = v as? String else { return nil }
            return (ks, vs)
        }, uniquingKeysWith: { a, _ in a })
        guard let intent = Self.routeFromNotification(userInfo: stringInfo) else { return }
        do {
            try openNotificationRoute(intent)
        } catch {
            NSLog("RemoteCode notification route failed thread=%@ error=%@",
                  intent.threadId.value.uuidString, error.localizedDescription)
        }
    }

    /// Testable notification seam. The thread repository is authoritative for
    /// workspace selection; `workspaceId` remains payload metadata for backwards
    /// compatibility. The canonical router verifies exact surface binding before
    /// marking the notification's thread read.
    @discardableResult
    func openNotificationRoute(_ intent: NotificationRouteIntent) throws -> SurfaceDescriptor {
        guard let router else { throw LayoutError.workspaceNotFound }
        return try router.openAgentThread(thread: intent.threadId, markRead: true)
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
    private func publishBonjour(serverId: String, port: UInt16) {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let svc = NetService(domain: "", type: "_remotecode._tcp.", name: name, port: Int32(port))
        let txt = Self.bonjourTXTRecord(serverId: serverId, version: AppVersion.short)
        svc.setTXTRecord(NetService.data(fromTXTRecord: txt))
        svc.delegate = bonjourDelegate
        svc.publish()
        bonjour = svc
        NSLog("Bonjour published: \(name) _remotecode._tcp:\(port)")
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

extension AppDelegate {
    /// Pure helper: builds the informative text for the database-open failure
    /// alert. Extracted for testability without any AppKit side-effects.
    ///
    /// WHY: The copy must tell the user *where* the database is and *how* to
    /// recover — a raw Swift error string does neither. This helper pins the
    /// contract so regression tests catch copy drift.
    nonisolated public static func dbOpenFailureInformativeText(
        supportDir: String,
        errorDescription: String
    ) -> String {
        """
        Your workspaces and settings are stored in:
        \(supportDir)

        To recover: quit RemoteCode, delete "remotecode.sqlite" from that folder, \
        and relaunch. A backup of the previous database may be present with a \
        ".corrupt-<date>" suffix.

        Technical detail: \(errorDescription)
        """
    }

    /// Pure helper: formats a pairing code for VoiceOver announcement.
    ///
    /// Each character is separated by a single space so VoiceOver reads them
    /// individually ("3 4 2 7 8 1") rather than as a single number
    /// ("three hundred forty-two thousand ..."). The prefix "Pairing code: "
    /// identifies the field role before the digits are announced.
    ///
    /// WHY extracted: testable without any @MainActor or AppKit dependency.
    nonisolated public static func pairingCodeAccessibilityLabel(_ code: String) -> String {
        let spaced = code.map { String($0) }.joined(separator: " ")
        return "Pairing code: \(spaced)"
    }
}

/// Pure, nonisolated helper for pairing sheet countdown math.
/// Extracted from AppDelegate so it can be tested without AppKit or @MainActor.
///
/// WHY: The non-blocking pairing sheet must accurately reflect the server-side
/// 300-second TTL. Errors here cause "time left" / actual expiry drift, which
/// means the user could see an expired prompt or be dismissed before the real
/// deadline. The helper is pure (injected `now`) so tests are deterministic.
public enum PairingCountdown {
    /// Seconds remaining until the request expires, clamped to [0, ttl].
    /// - Parameters:
    ///   - createdAt: When the request was created.
    ///   - ttl: Total TTL in seconds (default 300 for device-initiated pair).
    ///   - now: Current time (injected for testability).
    public static func remainingSecs(createdAt: Date, ttl: TimeInterval, now: Date) -> Double {
        let elapsed = now.timeIntervalSince(createdAt)
        return max(0, ttl - elapsed)
    }

    /// Returns true when `now` is at or past the expiry instant.
    public static func expired(createdAt: Date, ttl: TimeInterval, now: Date) -> Bool {
        now.timeIntervalSince(createdAt) >= ttl
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

#if DEBUG
extension AppDelegate {
    /// Test seam: synchronously drains the background writer queue after calling
    /// the production CCR retention path so tests can assert pruning without timers.
    ///
    /// WHY: `runCCRRetention` is private and dispatches asynchronously; a test
    /// that bypasses the delegate exercises only the API layer.  This seam drives
    /// the full production path — same store, same queue — then blocks until the
    /// async prune is complete, making the outcome synchronously verifiable.
    /// The 24-hour cadence timer is never installed in these tests, so disk growth
    /// due to an absent scheduling hook will fail this assertion.
    func runCCRRetentionForTesting() {
        runCCRRetention()
        context?.flushWriterQueue()
    }
}
#endif
