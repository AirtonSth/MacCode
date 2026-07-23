import Foundation
import AppKit
import SwiftUI
import CoreImage
import CoreModel
import Persistence
import AgentRuntime
import SocketServer
import DesignSystemKit
import Surfaces
import UserNotifications
import os

extension Notification.Name {
    static let rc2RemoteAccessSettingChanged = Notification.Name("rc2RemoteAccessSettingChanged")
    static let rc2PrivateAccountChanged = Notification.Name("rc2PrivateAccountChanged")
}

/// Pure enumeration of every user-tunable AppSettings field key.
/// Used by the Settings window to surface all fields and by tests to guard
/// that no field is silently omitted from the UI.
public struct AppSettingsKeys {
    /// Stable string keys matching AppSettings property names. Extend this list
    /// whenever a new field is added to AppSettings so the coverage test catches
    /// any omission before the next release.
    public static let userTunableKeys: [String] = [
        "diffWordWrap",
        "diffIgnoreWhitespace",
        "sidebarSort",
        "insomniaEnabled",
        "insomniaAllowDisplaySleep",
        "insomniaAllowSystemSleepWhenDisplayClosed",
        "insomniaAllowScreenSaverAfter45MinutesOfInactivity",
        "tokenSaverEnabled",
        "terminalFontSize",
        "sessionLearnEnabled",
        "historyCompactionEnabled",
        "petEnabled",
        "petAnimationsEnabled",
        "petReadyCounterEnabled",
        "petPosition",
        "petSize",
        "petAttentionFilter",
        "petReduceMotion",
    ]
}

// MARK: - Devices panel pure formatters

/// Pure display fields derived from a DeviceTrust value. No MainActor needed;
/// all inputs are value types. Tested directly without constructing a ViewModel.
public struct DeviceRowFormatter {
    /// Short device name + abbreviated id so users distinguish devices without
    /// reading a full UUID. Example: "Sam's iPhone (abc12345)"
    public static func title(_ d: DeviceTrust) -> String {
        "\(d.displayName) (\(d.id.prefix(8)))"
    }

    /// Subtitle: ISO paired date, optional relative last-seen, revoked badge.
    /// Uses the shared formatters injected as parameters so tests can pass
    /// deterministic formatters without monkey-patching global state.
    public static func subtitle(
        _ d: DeviceTrust,
        isoFormatter: ISO8601DateFormatter,
        relativeFormatter: RelativeDateTimeFormatter,
        now: Date = Date()
    ) -> String {
        var parts: [String] = ["paired " + isoFormatter.string(from: d.createdAt)]
        if let ls = d.lastSeenAt {
            parts.append("seen " + relativeFormatter.localizedString(for: ls, relativeTo: now))
        }
        if d.alwaysAllowPairing { parts.append("always allow") }
        if d.revokedAt != nil { parts.append("revoked") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// True iff the device has been revoked and can be deleted from the list.
    public static func isRevoked(_ d: DeviceTrust) -> Bool { d.revokedAt != nil }
}

/// Pure formatter for a single AuditLogEntry row. No MainActor needed.
public struct AuditLogRowFormatter {
    /// One-line display string: timestamp + actor (if any) + action + detail (if any).
    /// Example: "2026-06-09T12:00:00Z  device \u{2192} pairing.redeem  MyPhone"
    public static func line(
        _ entry: AuditLogEntry,
        isoFormatter: ISO8601DateFormatter
    ) -> String {
        var parts: [String] = [isoFormatter.string(from: entry.ts)]
        if let actor = entry.actor { parts.append(actor) }
        parts.append(entry.action)
        if let detail = entry.detail { parts.append(detail) }
        return parts.joined(separator: "  ")
    }
}

/// Pure helpers for the keybindings config reveal button.
///
/// Extracted as a value type so tests can assert the path and template without
/// touching the file system or running on MainActor.
public struct KeybindingConfigReveal {
    /// Absolute path to the user-editable keybindings config file.
    /// Mirrors `KeybindingConfig.defaultPath` so the Reveal button and the
    /// parser always agree on the file location.
    public static var configPath: String {
        NSHomeDirectory() + "/.remotecode/keybindings.json"
    }

    /// A valid JSON array with a commented header block that serves as a
    /// starter template for new users. The file must be parseable by
    /// `KeybindingConfig.parse` (empty array = no custom bindings).
    public static var defaultTemplate: String {
        """
        // RemoteCode keybindings - edit and save; changes take effect immediately.
        // Format: [{"key":"mod+shift+p","command":"commandPalette.toggle","when":"terminalFocus"}]
        // "when" is optional. Modifiers: mod ctrl alt shift. Last matching rule wins.
        []
        """
    }

    /// Ensures the file exists (creating it with `defaultTemplate` if absent)
    /// then asks Finder to reveal it. No-op if the file cannot be created.
    @MainActor
    public static func revealCreatingIfAbsent() {
        let path = configPath
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            let dir = url.deletingLastPathComponent().path
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? defaultTemplate.write(toFile: path, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Pure, non-MainActor commit-policy helper for CLI path text fields.
///
/// Business rule: a mid-edit draft must not trigger provider-adapter replacement
/// or DB writes. Only a committed value (end-of-editing or Browse picker) that
/// differs from the previously persisted value should be applied.
///
/// - Parameters:
///   - old: The last value that was actually persisted/applied.
///   - new: The candidate value (may be a partial draft).
///   - committed: True when the edit session has ended (Return / focus-loss /
///     Browse picker). False on every intermediate keystroke.
/// - Returns: `true` iff the new value should be persisted and wired into the
///   live coordinator.
public struct CLIPathCommitPolicy {
    public static func shouldApply(old: String, new: String, committed: Bool) -> Bool {
        guard committed else { return false }
        return new != old
    }
}

/// Which execution engine backs the `.claude` provider.
/// `.cli` (default) drives the system `claude` binary directly — no Node, npm,
/// SDK, or 205MB native package. `.sdk` is an advanced opt-in that adds session
/// forking and live model/permission switching but requires Node 18+ and a
/// runtime SDK install (`ClaudeAgentSDKBridgeAdapter`).
public enum ClaudeEngine: String, CaseIterable {
    case cli
    case sdk
}

/// Pure resolver for the active Claude engine. Encodes the "minimize
/// dependencies" default: the CLI engine wins unless the user has explicitly
/// opted into the SDK, so a machine without a modern Node/npm toolchain still
/// runs Claude. A dev/admin env override takes precedence over the setting.
public struct ClaudeEnginePolicy {
    /// Settings key persisting the user's engine choice.
    public static let settingsKey = "cli.claude.engine"

    /// Resolves the engine. `RC_CLAUDE_AGENT_SDK_ENABLED` is honored as a
    /// dev/admin override ("0" → CLI, "1" → SDK); otherwise the persisted
    /// setting is used; otherwise the CLI default. Unrecognized values fall
    /// through to the next source rather than silently forcing an engine.
    public static func resolve(setting: String?, envOverride: String?) -> ClaudeEngine {
        if let env = envOverride?.trimmingCharacters(in: .whitespaces), !env.isEmpty {
            if env == "0" { return .cli }
            if env == "1" { return .sdk }
        }
        let stored = (setting ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return ClaudeEngine(rawValue: stored) ?? .cli
    }
}

/// Pure helper that encodes the cross-VM reload policy for
/// rc2RemoteAccessSettingChanged.
///
/// WHY: when this VM posts the notification itself (_postingRemoteAccess == true)
/// we must skip the reload to avoid the double-reload on every toggle.
/// Cross-VM notifications (isSelfOriginated == false) must always reload so
/// other open Settings windows stay in sync.
public struct RemoteAccessNotificationPolicy {
    /// Returns true iff a reload should be performed for an incoming
    /// rc2RemoteAccessSettingChanged notification.
    public static func shouldReload(isSelfOriginated: Bool) -> Bool {
        !isSelfOriginated
    }
}

/// Reflects whether the HTTP listener actually bound after a remote-access toggle.
///
/// WHY: the toggle writes the preference and fires the notification optimistically.
/// AppDelegate.configureDirectAccess() then calls http.start() which can throw
/// (port already in use, permission denied, etc.). Without checking the bind result
/// the toggle reads "on" while nothing is listening. This enum closes that gap.
///
/// - .on:        User requested on AND the listener successfully bound. Connections accepted.
/// - .bindFailed: User requested on BUT the listener failed to bind. Toggle must show
///               off/error; the stored preference has been rolled back to "0".
/// - .off:       User requested off (loopback-only mode; no remote connections).
public enum RemoteAccessStatus: Equatable {
    case on
    case bindFailed(reason: String)
    case off

    /// Pure decision: derive the correct status from the requested state and bind outcome.
    ///
    /// - Parameters:
    ///   - requestedOn: The value the user toggled to.
    ///   - listenerBound: True iff AppDelegate confirmed the HTTP server started
    ///                    without error after the toggle.
    ///   - failureReason: The error description when listenerBound is false.
    public static func remoteAccessStatus(
        requestedOn: Bool,
        listenerBound: Bool,
        failureReason: String = ""
    ) -> RemoteAccessStatus {
        guard requestedOn else { return .off }
        return listenerBound ? .on : .bindFailed(reason: failureReason)
    }
}

/// Surfaced status of the managed `distill` skill install (mirrors AppContext's
/// last reconcile) so a failure is visible in Settings instead of NSLog-only.
public enum DistillInstallStatus: Equatable {
    case inactive
    case installed
    case failed(String)

    /// A reconcile error wins (so a failure is never hidden as "off"); otherwise
    /// `installed` only while Token Saver is enabled and the Distill package is present.
    /// Token economy is paid — Distill integration tracks the Token Saver toggle.
    public static func from(error: String?, enabled: Bool, installedCount: Int) -> DistillInstallStatus {
        if let error { return .failed(error) }
        if enabled, installedCount > 0 { return .installed }
        return .inactive
    }
}

@MainActor
public final class SettingsViewModel: ObservableObject {
    public let settingsRepo: SettingsRepository
    public let trustRepo: DeviceTrustRepository
    public let settingsStore: SettingsStore
    public let customModelStore: AgentCustomModelStore
    public let context: AppContext
    private let storageBudgetManager: LocalStorageBudgetManager
    private let privateAccountAPI: PrivateAccountAPI
    private let privateAccountStore: PrivateAccountSessionStore
    private let openURL: @MainActor (URL) -> Void
    private let updater: AppUpdateChecking?
    private var changeObservers: [NSObjectProtocol] = []

    @Published public var remoteAccessEnabled: Bool = false
    /// Non-nil when the HTTP listener failed to bind after the last remote-access
    /// toggle-on. The toggle is reverted to off and the preference rolled back so
    /// the stored value matches the actual listener state.
    /// WHY: without this, remoteAccessEnabled stays true even when nothing is
    /// listening, and the user believes remote access is active when it is not.
    @Published public var remoteAccessBindFailedReason: String? = nil
    /// All server startup failures accumulated since launch (general surfacing,
    /// UX-MAC_SOCKET_SERVER-P1 :214). Read from AppDelegate.serverStartupFailures
    /// on Settings open and updated on serverStartupFailureNotification.
    /// WHY: a failed server start is otherwise invisible -- only NSLog; the user
    /// has no way to know the socket or HTTP listener never came up.
    /// Distinct from remoteAccessBindFailedReason (:162): that property is scoped
    /// to the current toggle attempt and gates toggle-revert. This list is
    /// always-visible, additive, and idempotent (read-only from AppDelegate).
    @Published public var serverStartupFailures: [(server: String, reason: String)] = []
    /// Managed-distill skill install status, surfaced so an install failure is
    /// visible instead of NSLog-only (mirrors serverStartupFailures). Refreshed from
    /// AppContext on every reload (Settings open / notifications) and after a retry.
    @Published public var distillInstallStatus: DistillInstallStatus = .inactive
    @Published public var appSettings: AppSettings = AppSettings()
    /// True while this VM is mid-post for rc2RemoteAccessSettingChanged so the
    /// observer can skip the redundant self-triggered reload (L91 perf fix).
    private var _postingRemoteAccess = false
    /// True between setRemoteAccess(true) and the serverStartupFailureNotification
    /// observation window so the observer can tell whether the failure belongs to
    /// the current toggle attempt (not a stale failure from a previous launch).
    /// Internal (not private) so tests can arm it directly to simulate the
    /// production timing without relying on async-clear ordering.
    var _pendingRemoteAccessToggle = false
    @Published public var codexPath: String = ""
    @Published public var claudePath: String = ""
    @Published public var grokPath: String = ""
    /// Last value that was actually persisted + wired into the coordinator.
    /// Used by CLIPathCommitPolicy to skip no-op commits.
    public var committedCodexPath: String = ""
    public var committedClaudePath: String = ""
    public var committedGrokPath: String = ""
    @Published public var codexAvailable: Bool = false
    @Published public var claudeAvailable: Bool = false
    @Published public var grokAvailable: Bool = false
    /// Active Claude execution engine (CLI default vs SDK bridge opt-in).
    @Published public var claudeEngine: ClaudeEngine = .cli
    /// True when `RC_CLAUDE_AGENT_SDK_ENABLED` pins the engine, so the picker is
    /// read-only (a dev/admin override outranks the persisted setting).
    @Published public var claudeEngineLockedByEnv: Bool = false
    @Published public var devices: [DeviceTrust] = []
    @Published public var auditLogEntries: [AuditLogEntry] = []
    @Published public var newPairingCode: String?
    @Published public var pairingCodeExpiresAt: Date?
    @Published public var pairingCodeError: String?
    /// QR payload string for the active pairing code, or nil when no code is live.
    /// Populated alongside `newPairingCode` so the QR view re-renders atomically.
    /// WHY separate: the view reads it directly; keeping it Published avoids
    /// recomputing the payload string on every TimelineView tick.
    @Published public var pairingQRPayload: String?
    @Published public var updatingProviders: Set<AgentProvider> = []
    @Published public var providerUpdateMessages: [AgentProvider: String] = [:]
    @Published public var customModelsByProvider: [AgentProvider: [String]] = [:]
    @Published public var privateAccountEmail: String = ""
    @Published public var privateAccountPassword: String = ""
    @Published public var privateAccountUser: PrivateAccountUser?
    @Published public var privateAccountStatus: String = "Optional"
    @Published public var privateAccountBusy: Bool = false
    @Published public var privateBillingPortalURL: URL?
    @Published public var updateAvailability: AppUpdateAvailability = .unknown
    /// Non-nil while a revoke failure message is pending display.
    @Published public var revokeErrorMessage: String?
    /// Non-nil when a settings toggle write fails so the UI can surface the
    /// error and tell the user the value will revert on next launch
    /// (P2-Settings-5: try? repo.set was silently swallowing errors).
    @Published public var settingsWriteError: String?
    /// Mirrors `UNAuthorizationStatus` so the Settings view can react to
    /// permission changes made in System Settings between open/close cycles.
    /// `.notDetermined` is the safe default before the first async probe.
    @Published public var notificationAuthStatus: UNAuthorizationStatus = .notDetermined
    @Published public var storageSnapshot: LocalStorageSnapshot?
    @Published public var storageOperationStatus: String?
    @Published public var storageOperationInProgress = false

    /// True only when an updater is configured (Sparkle feed present). The
    /// Settings "App Updates" row is hidden otherwise so unsigned/dev builds
    /// don't show a dead control.
    public var showsAppUpdates: Bool { updater != nil }

    public var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        if let build, !build.isEmpty, build != short { return "\(short) (\(build))" }
        return short
    }

    static let accountLog = Logger(subsystem: "io.remotecode.app", category: "private-account")

    /// Status strings that represent a sign-in/refresh failure (used by the
    /// signed-out form to decide whether to show the inline error hint).
    static let signInFailureStatuses: Set<String> = [
        "Sign in failed", "No internet connection", "Too many attempts, wait a minute",
        "Service unavailable", "Service error", "Session expired"
    ]

    /// Maps transport/API errors to distinct, actionable status copy so 401,
    /// 429, offline, and 5xx no longer collapse to one generic message.
    static func signInFailureMessage(for error: Error) -> String {
        if let apiError = error as? PrivateAccountAPIError {
            switch apiError {
            case .http(let code):
                switch code {
                case 401, 403: return "Sign in failed"
                case 429: return "Too many attempts, wait a minute"
                case 500...599: return "Service unavailable"
                default: return "Service error"
                }
            case .invalidResponse:
                return "Service error"
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "No internet connection"
            case .timedOut, .cannotConnectToHost, .cannotFindHost:
                return "Service unavailable"
            default:
                return "No internet connection"
            }
        }
        return "Sign in failed"
    }

    public init(
        context: AppContext,
        privateAccountAPI: PrivateAccountAPI = URLSessionPrivateAccountAPI(),
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        updater: AppUpdateChecking? = nil
    ) {
        self.context = context
        self.privateAccountAPI = privateAccountAPI
        self.openURL = openURL
        self.updater = updater
        self.settingsRepo = context.settingsRepo
        self.trustRepo = DeviceTrustRepository(db: context.db)
        self.settingsStore = SettingsStore(db: context.db)
        self.customModelStore = AgentCustomModelStore(repo: context.settingsRepo)
        self.storageBudgetManager = LocalStorageBudgetManager(
            db: context.db,
            attachmentRoot: context.appSupportDirectory.appendingPathComponent("agent-attachments", isDirectory: true)
        )
        self.privateAccountStore = PrivateAccountSessionStore(repo: context.settingsRepo)
        self.updateAvailability = updater?.availability ?? .unknown
        reload()
        // P2-Settings-5: surface toggle write failures instead of silently
        // swallowing them. Assigned after stored-property init so the closure may
        // capture self. Called on the calling thread (MainActor for all callers).
        self.settingsStore.onWriteError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.recordSettingsWriteError(error)
            }
        }
        self.customModelStore.onWriteError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.recordSettingsWriteError(error)
            }
        }
        // Keep separate Settings/Account window instances in sync: when either
        // posts an account/remote-access change, refresh this instance too so it
        // never shows stale status (mirrors SidebarViewModel's observer).
        // rc2RemoteAccessSettingChanged: skip if this VM is the one posting
        // (self-originated) to avoid the double reload on each toggle (L91 fix).
        changeObservers.append(NotificationCenter.default.addObserver(
            forName: .rc2PrivateAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reload() }
        })
        changeObservers.append(NotificationCenter.default.addObserver(
            forName: .rc2RemoteAccessSettingChanged, object: nil, queue: .main
        ) { [weak self] _ in
            // Capture the flag synchronously (before the Task hop) while
            // _postingRemoteAccess is still true for self-originated posts.
            let selfOriginated = self?._postingRemoteAccess ?? false
            Task { @MainActor [weak self] in
                guard let self, !selfOriginated else { return }
                self.reload()
            }
        })
        changeObservers.append(NotificationCenter.default.addObserver(
            forName: .petSettingsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reload() }
        })
        // Observe bind failures from AppDelegate.configureDirectAccess(). When
        // the HTTP server fails to start after we toggled remote access on, revert
        // the toggle to off (matching the stored preference AppDelegate already
        // rolled back) and surface the bind error to the UI.
        // WHY: without this observer, remoteAccessEnabled stays true even though
        // nothing is listening -- the toggle shows "on" while no connections are
        // accepted. The _pendingRemoteAccessToggle guard ensures only failures
        // that belong to the current toggle attempt are surfaced; stale failures
        // from a previous launch startup do not affect the toggle state.
        changeObservers.append(NotificationCenter.default.addObserver(
            forName: AppDelegate.serverStartupFailureNotification, object: nil, queue: .main
        ) { [weak self] notification in
            // Capture synchronously; Task hop cannot capture a mutating let.
            let pending = self?._pendingRemoteAccessToggle ?? false
            guard pending else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self._pendingRemoteAccessToggle = false
                // Read the HTTP server failure reason, if any.
                let delegate = notification.object as? AppDelegate
	                let reason = delegate?.serverStartupFailures
	                    .last(where: { $0.server == "HTTP server" })?.reason ?? "Listener failed to bind"
	                // Revert the stored preference so it matches the actual listener state.
	                do {
	                    try self.settingsRepo.set("remote_access_enabled", "0")
	                } catch {
	                    self.recordSettingsWriteError(error)
	                }
	                self.remoteAccessEnabled = false
	                self.remoteAccessBindFailedReason = reason
	                // Re-drive AppDelegate's configure with the reverted (off)
	                // setting: the failed configure armed a supervisor retry that
	                // captured remoteEnabled=true, and without this post a later
	                // retry success would bind 0.0.0.0 + publish Bonjour while the
	                // toggle and stored setting say remote access is OFF.
	                self._postingRemoteAccess = true
	                NotificationCenter.default.post(name: .rc2RemoteAccessSettingChanged, object: nil)
	                self._postingRemoteAccess = false
	            }
        })
        // General startup-failure surfacing (:214): always refresh the list when
        // any server startup failure is recorded, regardless of whether a toggle
        // is pending. This observer is additive and does not interfere with the
        // toggle-revert observer above (which exits early via the `guard pending`
        // gate when no toggle is in progress).
        // WHY: socket-server and HTTP-server failures that happen at launch (before
        // any toggle) are invisible to the user without this second observer.
        changeObservers.append(NotificationCenter.default.addObserver(
            forName: AppDelegate.serverStartupFailureNotification, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let delegate = notification.object as? AppDelegate
                if let failures = delegate?.serverStartupFailures {
                    self.serverStartupFailures = failures
                }
            }
        })
    }

    public func refreshStorageUsage() async {
        guard !storageOperationInProgress else { return }
        storageOperationInProgress = true
        defer { storageOperationInProgress = false }
        let manager = storageBudgetManager
        do {
            storageSnapshot = try await Task.detached(priority: .utility) {
                try manager.snapshot()
            }.value
        } catch {
            storageOperationStatus = "Storage usage could not be read: \(String(describing: error))"
        }
    }

    public func cleanUpExpiredStorage(compact: Bool = true) async {
        guard !storageOperationInProgress else { return }
        storageOperationInProgress = true
        defer { storageOperationInProgress = false }
        let manager = storageBudgetManager
        do {
            let result = try await Task.detached(priority: .utility) {
                try manager.cleanupExpired(compact: compact)
            }.value
            storageSnapshot = result.snapshot
            let removed = result.removedRows.values.reduce(0, +)
            if result.compacted {
                storageOperationStatus = "Removed \(removed) expired item\(removed == 1 ? "" : "s") and compacted the database."
            } else if let reason = result.compactionSkippedReason {
                storageOperationStatus = "Removed \(removed) expired item\(removed == 1 ? "" : "s"). \(reason.message)"
            } else {
                storageOperationStatus = "Removed \(removed) expired item\(removed == 1 ? "" : "s")."
            }
        } catch {
            storageOperationStatus = "Storage cleanup failed: \(String(describing: error))"
        }
    }

    deinit {
        changeObservers.forEach(NotificationCenter.default.removeObserver)
    }

    public func reload() {
        remoteAccessEnabled = (try? settingsRepo.get("remote_access_enabled")) == "1"
        // Refresh the general startup-failure list from AppDelegate on every reload
        // (Settings open, account/remote-access notification-driven reload).
        // Reading the shared array is idempotent and does not interfere with the
        // toggle-revert observer (:162) which is guarded by _pendingRemoteAccessToggle.
        // NSApp is an implicitly-unwrapped global that is nil in a unit-test
        // process with no shared NSApplication, so bind it before use.
        if let app = NSApp, let delegate = app.delegate as? AppDelegate {
            serverStartupFailures = delegate.serverStartupFailures
        }
        appSettings = settingsStore.reload()
        refreshDistillInstallStatus()
        codexPath = cliPath(key: "cli.codex.path", fallback: "codex")
        claudePath = cliPath(key: "cli.claude.path", fallback: "claude")
        grokPath = cliPath(key: "cli.grok.path", fallback: "grok")
        committedCodexPath = codexPath
        committedClaudePath = claudePath
        committedGrokPath = grokPath
        codexAvailable = resolveAvailable(codexPath)
        claudeAvailable = resolveAvailable(claudePath)
        grokAvailable = resolveAvailable(grokPath)
        let claudeEngineEnv = ProcessInfo.processInfo.environment["RC_CLAUDE_AGENT_SDK_ENABLED"]
        claudeEngine = ClaudeEnginePolicy.resolve(
            setting: (try? settingsRepo.get(ClaudeEnginePolicy.settingsKey)).flatMap { $0 },
            envOverride: claudeEngineEnv
        )
        claudeEngineLockedByEnv = (claudeEngineEnv == "0" || claudeEngineEnv == "1")
        // Do NOT clear providerUpdateMessages here — an account/remote-access
        // notification-driven reload was erasing update results the user may
        // be reading (P2-Settings-6).  Messages are cleared only by the setters
        // that trigger a new update attempt (setCodexPath / setClaudePath).
        customModelsByProvider = Dictionary(uniqueKeysWithValues: AgentProvider.allCases.map { provider in
            (provider, customModelStore.list(provider: provider))
        })
        devices = (try? trustRepo.list()) ?? []
        auditLogEntries = (try? trustRepo.listAuditLog()) ?? []
        if let updater { updateAvailability = updater.availability }
        if let session = privateAccountStore.load() {
            privateAccountUser = session.user
            privateAccountEmail = session.user.email
            privateAccountStatus = session.user.subscribed ? "Subscription active" : "Signed in; subscription required for backend push"
            privateBillingPortalURL = nil
        } else {
            privateAccountUser = nil
            privateAccountStatus = "Optional"
            privateBillingPortalURL = nil
        }
    }

    public func setRemoteAccess(_ on: Bool) {
        // Clear any previous bind-fail state; a new toggle attempt supersedes it.
        remoteAccessBindFailedReason = nil
        remoteAccessEnabled = on
        do {
            try settingsRepo.set("remote_access_enabled", on ? "1" : "0")
        } catch {
            remoteAccessEnabled = !on
            recordSettingsWriteError(error)
            return
        }
        // Arm the pending-toggle flag before posting so the serverStartupFailure
        // observer can attribute the upcoming bind result to this specific toggle.
        // Only arm when turning on; turning off cannot produce a bind error.
        _pendingRemoteAccessToggle = on
        _postingRemoteAccess = true
        NotificationCenter.default.post(name: .rc2RemoteAccessSettingChanged, object: nil)
        _postingRemoteAccess = false
        // AppDelegate's observer runs synchronously during the post above. If the
        // bind succeeded, no serverStartupFailureNotification is posted and the
        // pending flag stays armed. Disarm it on the next main-queue cycle so a
        // later, unrelated startup failure is not misattributed to this toggle.
        // The failure observer also clears the flag, so if a failure Task runs
        // before this async clear, no double-clear harm occurs.
        if on {
            DispatchQueue.main.async { [weak self] in
                self?._pendingRemoteAccessToggle = false
            }
        } else {
            _pendingRemoteAccessToggle = false
        }
    }

    public func setDiffWordWrap(_ on: Bool) {
        appSettings.diffWordWrap = on
        settingsStore.update { $0.diffWordWrap = on }
    }

    public func setDiffIgnoreWhitespace(_ on: Bool) {
        appSettings.diffIgnoreWhitespace = on
        settingsStore.update { $0.diffIgnoreWhitespace = on }
    }

    /// "updated" | "created" | "manual"
    public func setSidebarSort(_ value: String) {
        appSettings.sidebarSort = value
        settingsStore.update { $0.sidebarSort = value }
    }

    public func setInsomniaEnabled(_ on: Bool) {
        appSettings.insomniaEnabled = on
        settingsStore.update { $0.insomniaEnabled = on }
    }

    public func setInsomniaAllowDisplaySleep(_ on: Bool) {
        appSettings.insomniaAllowDisplaySleep = on
        settingsStore.update { $0.insomniaAllowDisplaySleep = on }
    }

    public func setInsomniaAllowSystemSleepWhenDisplayClosed(_ on: Bool) {
        appSettings.insomniaAllowSystemSleepWhenDisplayClosed = on
        settingsStore.update { $0.insomniaAllowSystemSleepWhenDisplayClosed = on }
    }

    public func setInsomniaAllowScreenSaverAfter45MinutesOfInactivity(_ on: Bool) {
        appSettings.insomniaAllowScreenSaverAfter45MinutesOfInactivity = on
        settingsStore.update { $0.insomniaAllowScreenSaverAfter45MinutesOfInactivity = on }
    }

    public func setTokenSaverEnabled(_ on: Bool) {
        appSettings.tokenSaverEnabled = on
        settingsStore.update { $0.tokenSaverEnabled = on }
    }

    /// Mirrors AppContext's last managed-distill reconcile into a published status
    /// so the Settings UI can show installed / failed / inactive distinctly.
    public func refreshDistillInstallStatus() {
        distillInstallStatus = DistillInstallStatus.from(
            error: context.managedDistillSkillInstallError,
            enabled: appSettings.tokenSaverEnabled,
            installedCount: context.managedDistillSkillInstallResults.count
        )
    }

    /// Re-run the managed-distill install (idempotent) and refresh the surfaced
    /// status — the recovery action shown next to an install failure.
    public func retryDistillInstall() {
        context.reconcileManagedDistillSkills(tokenSaverEnabled: appSettings.tokenSaverEnabled)
        refreshDistillInstallStatus()
    }

    public func setTerminalFontSize(_ size: Double) {
        let normalized = TerminalFontSizeSetting.normalized(size)
        appSettings.terminalFontSize = normalized
        settingsStore.update { $0.terminalFontSize = normalized }
    }

    public func setSessionLearnEnabled(_ on: Bool) {
        appSettings.sessionLearnEnabled = on
        settingsStore.update { $0.sessionLearnEnabled = on }
    }

    public func setHistoryCompactionEnabled(_ on: Bool) {
        appSettings.historyCompactionEnabled = on
        settingsStore.update { $0.historyCompactionEnabled = on }
    }

    public func setPetEnabled(_ on: Bool) {
        appSettings.petEnabled = on
        settingsStore.update { $0.petEnabled = on }
        postPetSettingsDidChange()
    }

    public func setPetAnimationsEnabled(_ on: Bool) {
        appSettings.petAnimationsEnabled = on
        settingsStore.update { $0.petAnimationsEnabled = on }
        postPetSettingsDidChange()
    }

    public func setPetReadyCounterEnabled(_ on: Bool) {
        appSettings.petReadyCounterEnabled = on
        settingsStore.update { $0.petReadyCounterEnabled = on }
        postPetSettingsDidChange()
    }

    public func setPetPosition(_ value: String) {
        let normalized = ["bottomRight", "bottomLeft", "free"].contains(value) ? value : "bottomRight"
        appSettings.petPosition = normalized
        settingsStore.update { $0.petPosition = normalized }
        postPetSettingsDidChange()
    }

    public func setPetSize(_ value: Double) {
        let normalized = [0.75, 1, 1.25, 1.5].contains(value) ? value : 1
        appSettings.petSize = normalized
        settingsStore.update { $0.petSize = normalized }
        postPetSettingsDidChange()
    }

    public func setPetAttentionFilter(_ value: String) {
        let normalized = ["all", "completed", "needsYou"].contains(value) ? value : "all"
        appSettings.petAttentionFilter = normalized
        settingsStore.update { $0.petAttentionFilter = normalized }
        postPetSettingsDidChange()
    }

    public func setPetReduceMotion(_ on: Bool) {
        appSettings.petReduceMotion = on
        settingsStore.update { $0.petReduceMotion = on }
        postPetSettingsDidChange()
    }

    /// Latest host file-access probe results (Settings privacy section).
    @Published public var hostFileAccessProbeResults: [HostFileAccessProbeResult] = []
    /// Code signature identity for the running process (TCC durability).
    @Published public var hostCodeSignatureIdentity: HostCodeSignatureIdentity =
        HostCodeSignatureReader.current()
    /// True after the user handled (not necessarily granted) folder-access onboarding.
    @Published public var hostFileAccessOnboardingCompleted: Bool = false
    /// Optional probe injection for unit tests (avoids real filesystem/TCC).
    var hostFileAccessProbeRunner: (() -> [HostFileAccessProbeResult])?

    /// Refresh signing identity + onboarding flag for the Files & Folders section.
    public func refreshHostFileAccessState() {
        hostCodeSignatureIdentity = HostCodeSignatureReader.current()
        hostFileAccessOnboardingCompleted = HostFileAccessOnboarding.isHandled(repo: settingsRepo)
    }

    /// Optional Settings-only probe: touches standard protected folders so any
    /// *pending* TCC dialog can appear. Never called from launch onboarding.
    /// Does not reopen a prior Don’t Allow — System Settings is required for that.
    /// Marks onboarding handled after the attempt.
    public func requestHostFileAccess() {
        let runner = hostFileAccessProbeRunner ?? { HostFileAccessProber.probeStandardTargets() }
        hostFileAccessProbeResults = runner()
        do {
            try HostFileAccessOnboarding.markHandled(repo: settingsRepo)
            hostFileAccessOnboardingCompleted = true
        } catch {
            recordSettingsWriteError(error)
        }
    }

    public func openHostFilesAndFoldersSettings() {
        // Classic deep link remains the most reliable across macOS 14+.
        openURL(HostFileAccessSystemSettings.filesAndFoldersURL)
    }

    public func openHostFullDiskAccessSettings() {
        openURL(HostFileAccessSystemSettings.fullDiskAccessURL)
    }

    private func postPetSettingsDidChange() {
        NotificationCenter.default.post(name: .petSettingsDidChange, object: nil)
    }

    /// Update the Codex CLI path draft. The UI passes `committed: false` on
    /// mid-edit keystrokes (display only) and `committed: true` on end-editing
    /// (Return key, focus loss, or Browse picker) so mid-edit keystrokes do NOT
    /// replace the live provider adapter or write the DB. The default is
    /// `committed: true` so programmatic callers (restore, tests, update action)
    /// apply immediately, matching the pre-debounce behaviour.
    public func setCodexPath(_ path: String, committed: Bool = true) {
        codexPath = path
        codexAvailable = resolveAvailable(path)
        if CLIPathCommitPolicy.shouldApply(old: committedCodexPath, new: path, committed: committed) {
            committedCodexPath = path
            providerUpdateMessages[.codex] = nil
            saveCLIPath(key: "cli.codex.path", provider: .codex, path: path)
        }
    }

    /// Update the Claude CLI path draft. The UI passes `committed: false` on
    /// mid-edit keystrokes (display only) and `committed: true` on end-editing
    /// (Return key, focus loss, or Browse picker) so mid-edit keystrokes do NOT
    /// replace the live provider adapter or write the DB. The default is
    /// `committed: true` so programmatic callers (restore, tests, update action)
    /// apply immediately, matching the pre-debounce behaviour.
    public func setClaudePath(_ path: String, committed: Bool = true) {
        claudePath = path
        claudeAvailable = resolveAvailable(path)
        if CLIPathCommitPolicy.shouldApply(old: committedClaudePath, new: path, committed: committed) {
            committedClaudePath = path
            providerUpdateMessages[.claude] = nil
            saveCLIPath(key: "cli.claude.path", provider: .claude, path: path)
        }
    }

    /// Switch the Claude execution engine. Persists the choice and live-swaps the
    /// provider adapter for FUTURE sessions (in-flight turns keep their engine).
    /// A no-op when unchanged or when an env override pins the engine.
    public func setClaudeEngine(_ engine: ClaudeEngine) {
        guard !claudeEngineLockedByEnv, engine != claudeEngine else { return }
        claudeEngine = engine
        do {
            try settingsRepo.set(ClaudeEnginePolicy.settingsKey, engine.rawValue)
        } catch {
            recordSettingsWriteError(error)
            return
        }
        providerUpdateMessages[.claude] = nil
        let binary = committedClaudePath.trimmingCharacters(in: .whitespacesAndNewlines)
        context.coordinator.replaceProviderAdapter(
            .claude,
            adapter: AppContext.makeClaudeAdapter(engine: engine, binary: binary.isEmpty ? nil : binary)
        )
    }

    /// Update the Grok CLI path draft. Same commit policy as Codex/Claude paths.
    public func setGrokPath(_ path: String, committed: Bool = true) {
        grokPath = path
        grokAvailable = resolveAvailable(path)
        if CLIPathCommitPolicy.shouldApply(old: committedGrokPath, new: path, committed: committed) {
            committedGrokPath = path
            providerUpdateMessages[.grok] = nil
            saveCLIPath(key: "cli.grok.path", provider: .grok, path: path)
        }
    }

    public func setCustomModel(provider: AgentProvider, index: Int, value: String) {
        customModelStore.update(provider: provider, index: index, value: value)
        // When the value is empty the store removes the row, shrinking the array.
        // Any subsequent in-place mutation at the same index would then hit an
        // out-of-bounds guard inside AgentCustomModelStore.update, silently
        // dropping keystrokes until the next full reload.  Always reload from the
        // store after an update so the local cache matches the persisted array length.
        customModelsByProvider[provider] = customModelStore.list(provider: provider)
    }

    public func removeCustomModel(provider: AgentProvider, index: Int) {
        customModelStore.remove(provider: provider, index: index)
        customModelsByProvider[provider] = customModelStore.list(provider: provider)
    }

    public func providerDisplayName(_ provider: AgentProvider) -> String {
        provider.rawValue.capitalized
    }

    public func updateProvider(_ provider: AgentProvider) async {
        guard !updatingProviders.contains(provider) else { return }
        guard let router = context.router else {
            providerUpdateMessages[provider] = "Update unavailable: app router is not ready."
            return
        }
        updatingProviders.insert(provider)
        defer { updatingProviders.remove(provider) }

        do {
            let value = try await router.updateAgentProvider(provider: provider, providerInstanceId: nil)
            let object = value.objectValue ?? [:]
            let ok = object["ok"]?.boolValue ?? false
            let status = object["status"]?.intValue ?? -1
            let stdout = object["stdout"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = object["stderr"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if ok {
                providerUpdateMessages[provider] = stdout.isEmpty ? "Update completed." : stdout
            } else {
                let detail = stderr.isEmpty ? stdout : stderr
                providerUpdateMessages[provider] = detail.isEmpty ? "Update failed with status \(status)." : "Update failed with status \(status): \(detail)"
            }
        } catch {
            providerUpdateMessages[provider] = "Update failed: \(error)"
        }
    }

    public func createPairingCode() {
        do {
            let pc = try trustRepo.createPairingCode(ttlSeconds: 600)
            newPairingCode = pc.code
            pairingCodeExpiresAt = Date().addingTimeInterval(600)
            pairingCodeError = nil
            // Build the QR payload immediately after minting the code.
            // host: prefer the persisted server_id's companion host if stored;
            // fall back to ProcessInfo hostname which is always available on macOS.
            // Keep pairing on the same listener port as AppDelegate/Bonjour.
            // server_id: read from settingsRepo — same key AppDelegate writes on first start.
            // WHY: encoding these alongside the code means iOS can open the TCP
            // connection without any manual IP entry.
            let host = ProcessInfo.processInfo.hostName
            let serverId: String = ((try? settingsRepo.get("server_id")) ?? nil) ?? ""
            pairingQRPayload = PairingQRPayload.buildPayload(
                code: pc.code,
                host: host,
                port: DirectAccessConfiguration.port(),
                serverId: serverId
            )
        } catch {
            pairingCodeError = "Could not generate a pairing code: \(error.localizedDescription)"
            pairingQRPayload = nil
        }
    }

    public func revoke(_ id: String) {
        do {
            try trustRepo.revoke(id: id)
            revokeErrorMessage = nil
        } catch {
            revokeErrorMessage = "Revoke failed: \(error.localizedDescription). The device may still be able to connect."
        }
        reload()
    }

    /// Remove all revoked device rows from the device_trust table so the list
    /// stays clean. Only affects rows where revoked_at IS NOT NULL.
    public func deleteRevoked() {
        try? trustRepo.deleteRevoked()
        reload()
    }

    public func setAlwaysAllowPairing(deviceID: String, enabled: Bool) {
        try? trustRepo.setAlwaysAllowPairing(id: deviceID, enabled: enabled)
        reload()
    }

    public func connectPrivateAccount() async {
        let email = privateAccountEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !privateAccountPassword.isEmpty, !privateAccountBusy else { return }
        privateAccountBusy = true
        defer { privateAccountBusy = false }
        do {
            let session = try await privateAccountAPI.login(email: email, password: privateAccountPassword)
            let user = try await privateAccountAPI.currentUser(accessToken: session.accessToken)
            let verified = PrivateAccountSession(accessToken: session.accessToken, refreshToken: session.refreshToken, user: user)
            privateAccountStore.save(verified)
            privateAccountPassword = ""
            privateAccountUser = verified.user
            privateAccountStatus = verified.user.subscribed ? "Subscription active" : "Signed in; subscription required for backend push"
            privateBillingPortalURL = nil
            NotificationCenter.default.post(name: .rc2PrivateAccountChanged, object: nil)
        } catch {
            Self.accountLog.error("Private account sign-in failed: \(String(describing: error), privacy: .public)")
            privateAccountStatus = Self.signInFailureMessage(for: error)
        }
    }

    public func refreshPrivateAccount() async {
        guard !privateAccountBusy else { return }
        guard let stored = privateAccountStore.load() else {
            privateAccountStatus = "Optional"
            return
        }
        privateAccountBusy = true
        defer { privateAccountBusy = false }
        do {
            let user = try await privateAccountAPI.currentUser(accessToken: stored.accessToken)
            let verified = PrivateAccountSession(accessToken: stored.accessToken, refreshToken: stored.refreshToken, user: user)
            privateAccountStore.save(verified)
            privateAccountUser = user
            privateAccountEmail = user.email
            privateAccountStatus = user.subscribed ? "Subscription active" : "Signed in; subscription required for backend push"
            NotificationCenter.default.post(name: .rc2PrivateAccountChanged, object: nil)
        } catch {
            do {
                let refreshed = try await privateAccountAPI.refresh(refreshToken: stored.refreshToken)
                privateAccountStore.save(refreshed)
                privateAccountUser = refreshed.user
                privateAccountEmail = refreshed.user.email
                privateAccountStatus = refreshed.user.subscribed ? "Subscription active" : "Signed in; subscription required for backend push"
                NotificationCenter.default.post(name: .rc2PrivateAccountChanged, object: nil)
            } catch {
                Self.accountLog.error("Private account refresh failed: \(String(describing: error), privacy: .public)")
                privateAccountStore.clear()
                privateAccountUser = nil
                privateBillingPortalURL = nil
                privateAccountStatus = "Session expired"
                NotificationCenter.default.post(name: .rc2PrivateAccountChanged, object: nil)
            }
        }
    }

    public func openPrivateBillingPortal() async {
        guard !privateAccountBusy else { return }
        guard let stored = privateAccountStore.load() else {
            privateAccountStatus = "Sign in required"
            return
        }
        privateAccountBusy = true
        defer { privateAccountBusy = false }
        do {
            _ = try await privateAccountAPI.billingOverview(accessToken: stored.accessToken)
            let url = try await privateAccountAPI.createPortal(accessToken: stored.accessToken)
            privateBillingPortalURL = url
            openURL(url)
        } catch {
            Self.accountLog.error("Private account billing portal failed: \(String(describing: error), privacy: .public)")
            privateAccountStatus = "Billing portal unavailable"
        }
    }

    public func disconnectPrivateAccount() async {
        let refreshToken = privateAccountStore.load()?.refreshToken
        if let refreshToken {
            try? await privateAccountAPI.logout(refreshToken: refreshToken)
        }
        privateAccountStore.clear()
        privateAccountPassword = ""
        privateAccountUser = nil
        privateAccountStatus = "Optional"
        privateBillingPortalURL = nil
        NotificationCenter.default.post(name: .rc2PrivateAccountChanged, object: nil)
    }

    public func checkForAppUpdates() {
        updater?.checkForUpdates()
        updateAvailability = updater?.availability ?? updateAvailability
    }

    /// Probe the current notification authorization status and publish it so
    /// the Settings view always reflects what System Settings shows, even when
    /// the user fixed or denied permission between two open/close cycles.
    public func refreshNotificationStatus() async {
        notificationAuthStatus = await SystemNotifier.shared.authorizationStatus()
    }

    private func resolveAvailable(_ path: String) -> Bool {
        ProcessLocator.resolve(path).map { !$0.isEmpty } ?? false
    }

    private func cliPath(key: String, fallback: String) -> String {
        let stored = ((try? settingsRepo.get(key)) ?? "")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? (ProcessLocator.resolve(fallback) ?? fallback) : stored
    }

    private func saveCLIPath(key: String, provider: AgentProvider, path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try settingsRepo.set(key, trimmed)
        } catch {
            recordSettingsWriteError(error)
            return
        }
        switch provider {
        case .codex:
            context.coordinator.replaceProviderAdapter(.codex, adapter: CodexAppServerAdapter(binaryNameOverride: trimmed.isEmpty ? nil : trimmed))
        case .claude:
            let engine = ClaudeEnginePolicy.resolve(
                setting: (try? settingsRepo.get(ClaudeEnginePolicy.settingsKey)).flatMap { $0 },
                envOverride: ProcessInfo.processInfo.environment["RC_CLAUDE_AGENT_SDK_ENABLED"]
            )
            context.coordinator.replaceProviderAdapter(
                .claude,
                adapter: AppContext.makeClaudeAdapter(engine: engine, binary: trimmed.isEmpty ? nil : trimmed)
            )
        case .grok:
            context.coordinator.replaceProviderAdapter(
                .grok,
                adapter: GrokACPAdapter(binaryNameOverride: trimmed.isEmpty ? nil : trimmed)
            )
        }
    }

    private func recordSettingsWriteError(_ error: Error) {
        settingsWriteError = Self.settingsWriteErrorMessage(error)
    }

    static func settingsWriteErrorMessage(_ error: Error) -> String {
        "Settings could not be saved: \(error.localizedDescription). The change will revert on next launch."
    }
}

private final class SettingsRouteRegistry {
    private weak var generalAnchor: NSView?
    private weak var providersAnchor: NSView?

    func register(_ view: NSView, for route: PetSettingsRoute) {
        switch route {
        case .general:
            generalAnchor = view
        case .providers:
            providersAnchor = view
        }
    }

    func present(_ route: PetSettingsRoute, in window: NSWindow) -> Bool {
        guard let anchor = anchor(for: route), anchor.window === window else { return false }
        anchor.scrollToVisible(anchor.bounds)
        window.contentView?.layoutSubtreeIfNeeded()
        return isVisible(route, in: window)
    }

    func isVisible(_ route: PetSettingsRoute, in window: NSWindow) -> Bool {
        guard window.isVisible,
              let anchor = anchor(for: route),
              anchor.window === window else { return false }
        let visible = anchor.visibleRect.intersection(anchor.bounds)
        return visible.width > 0 && visible.height > 0
    }

    private func anchor(for route: PetSettingsRoute) -> NSView? {
        switch route {
        case .general:
            return generalAnchor
        case .providers:
            return providersAnchor
        }
    }
}

private struct SettingsRouteAnchor: NSViewRepresentable {
    let route: PetSettingsRoute
    let registry: SettingsRouteRegistry

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        registry.register(view, for: route)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        registry.register(nsView, for: route)
    }
}

public struct SettingsView: View {
    @ObservedObject var vm: SettingsViewModel
    private let onClose: (() -> Void)?
    private let routeRegistry: SettingsRouteRegistry?

    // Hoisted so device rows don't each allocate a formatter on every render.
    private static let deviceDateFormatter = ISO8601DateFormatter()
    /// Medium-style date for the device subtitle ("Jun 9, 2026") — more
    /// readable than raw ISO8601 for the paired-date caption (P3-Settings-14).
    private static let deviceMediumDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
    private static let deviceRelativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    @State private var deviceToRevoke: DeviceTrust?
    @State private var expandedUpdateDetails: Set<AgentProvider> = []
    // notificationStatus is now owned by the ViewModel (notificationAuthStatus)
    // so show() can refresh it without re-creating the hosting view (P2-Settings-7).
    private var notificationStatus: UNAuthorizationStatus { vm.notificationAuthStatus }
    /// Local draft values for CLI path fields; committed on end-editing so
    /// mid-edit keystrokes don't fire saveCLIPath / replaceProviderAdapter.
    @State private var codexPathDraft: String = ""
    @State private var claudePathDraft: String = ""
    @State private var grokPathDraft: String = ""

    public init(vm: SettingsViewModel, onClose: (() -> Void)? = nil) {
        self.vm = vm
        self.onClose = onClose
        self.routeRegistry = nil
    }

    fileprivate init(
        vm: SettingsViewModel,
        onClose: (() -> Void)?,
        routeRegistry: SettingsRouteRegistry
    ) {
        self.vm = vm
        self.onClose = onClose
        self.routeRegistry = routeRegistry
    }

    public var body: some View {
        VStack(spacing: DS.Space.md) {
            HStack {
                Text("Settings")
                    .font(DS.Font.bodyStrong)
                    .foregroundColor(DS.Palette.text)
                Spacer()
                Button("Done") { onClose?() }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("settings.done")
            }

            // P2-Settings-5: surface toggle write errors as a dismissible banner.
            if let err = vm.settingsWriteError {
                HStack(spacing: DS.Space.sm) {
                    Text(err)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        vm.settingsWriteError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Palette.danger)
                    .accessibilityLabel("Dismiss")
                    .accessibilityIdentifier("settings.writeError.dismiss")
                }
                .padding(DS.Space.sm)
                .background(DS.Palette.danger.opacity(0.10))
                .cornerRadius(DS.Radius.card)
                .accessibilityIdentifier("settings.writeError")
            }

            // UX-MAC_SOCKET_SERVER-P1 :214: general server startup failure banner.
            // Shown whenever at least one server failed to start at launch or on
            // re-configure. Distinct from remoteAccessBindFailedReason (:162) which
            // is scoped to the current toggle attempt; this banner covers all servers
            // (socket + HTTP) and persists until the user dismisses it.
            if !vm.serverStartupFailures.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    ForEach(Array(vm.serverStartupFailures.enumerated()), id: \.offset) { _, failure in
                        HStack(spacing: DS.Space.sm) {
                            Text("\(failure.server) failed to start: \(failure.reason)")
                                .font(DS.Font.caption)
                                .foregroundColor(DS.Palette.danger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("settings.serverStartupFailure.\(failure.server)")
                        }
                    }
                    Button {
                        vm.serverStartupFailures = []
                    } label: {
                        Text("Dismiss")
                            .font(DS.Font.caption)
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("settings.serverStartupFailures.dismiss")
                }
                .padding(DS.Space.sm)
                .background(DS.Palette.danger.opacity(0.10))
                .cornerRadius(DS.Radius.card)
                .accessibilityIdentifier("settings.serverStartupFailures")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    remoteAccessSection
                        .background(routeAnchor(.general))
                        .accessibilityIdentifier("settings.section.general")
                    hostFileAccessSection
                    diffDefaultsSection
                    terminalSection
                    sidebarSection
                    petSection
                    insomniaSection
                    tokenSaverSection
                    keybindingsSection
                    advancedSection
                    storageSection
                    customModelsSection
                    trustedDevicesSection
                    diagnosticsSection
                        .background(routeAnchor(.providers))
                        .accessibilityIdentifier("settings.section.providers")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(DS.Space.xl)
        .frame(minWidth: 620, maxWidth: .infinity, minHeight: 480)
        .background(DS.Palette.bg)
        .task { await vm.refreshNotificationStatus() }
        .task { await vm.refreshStorageUsage() }
        .onAppear {
            codexPathDraft = vm.codexPath
            claudePathDraft = vm.claudePath
            grokPathDraft = vm.grokPath
            vm.refreshHostFileAccessState()
        }
        .onChange(of: vm.codexPath) { codexPathDraft = $0 }
        .onChange(of: vm.claudePath) { claudePathDraft = $0 }
        .onChange(of: vm.grokPath) { grokPathDraft = $0 }
    }

    @ViewBuilder
    private func routeAnchor(_ route: PetSettingsRoute) -> some View {
        if let routeRegistry {
            SettingsRouteAnchor(route: route, registry: routeRegistry)
                .allowsHitTesting(false)
        }
    }

    private func settingRow<Content: View>(_ label: String, @ViewBuilder _ control: () -> Content) -> some View {
        HStack {
            Text(label).font(DS.Font.body).foregroundColor(DS.Palette.text)
            Spacer()
            control()
                // P3-Settings-15: .labelsHidden() removes the toggle's own label
                // so VoiceOver fell back to an empty accessible name. Combining the
                // row children preserves the sibling label text as the accessible name.
                .accessibilityLabel(label)
        }
        .padding(.vertical, DS.Space.sm)
    }

    private var hostFileAccessSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG(HostFileAccessCopy.settingsSectionTitle)
            Text(HostFileAccessCopy.settingsExplanation)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.hostFileAccess.explanation")
            if let warning = vm.hostCodeSignatureIdentity.adHocWarning {
                Text(warning)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.hostFileAccess.adHocWarning")
            }
            // FDA-first: primary path for least prompt spam. Folder probe is
            // opt-in only (can surface multiple system dialogs).
            Button(HostFileAccessCopy.openFullDiskAccessButton) {
                vm.openHostFullDiskAccessSettings()
            }
            .buttonStyle(DSSecondaryButtonStyle())
            .accessibilityIdentifier("settings.hostFileAccess.openFullDiskAccess")
            HStack(spacing: DS.Space.sm) {
                Button(HostFileAccessCopy.openFilesAndFoldersButton) {
                    vm.openHostFilesAndFoldersSettings()
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .accessibilityIdentifier("settings.hostFileAccess.openFilesAndFolders")
                Button(HostFileAccessCopy.requestAccessButton) {
                    vm.requestHostFileAccess()
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .accessibilityIdentifier("settings.hostFileAccess.request")
            }
            if !vm.hostFileAccessProbeResults.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    ForEach(vm.hostFileAccessProbeResults, id: \.target) { result in
                        Text("\(result.target.title): \(result.outcome.rawValue)")
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textSecondary)
                            .accessibilityIdentifier("settings.hostFileAccess.result.\(result.target.rawValue)")
                    }
                }
                .accessibilityIdentifier("settings.hostFileAccess.results")
            }
        }
        .accessibilityIdentifier("settings.section.hostFileAccess")
    }

    private var remoteAccessSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG("Remote Access")
            settingRow("Allow iPhone or iPad on your network") {
                Toggle("", isOn: Binding(
                    get: { vm.remoteAccessEnabled },
                    set: { vm.setRemoteAccess($0) }
                ))
                .labelsHidden()
                .accessibilityIdentifier("settings.remoteAccess.toggle")
            }
            if let reason = vm.remoteAccessBindFailedReason {
                Text("Remote access could not start: \(reason). The toggle has been turned off.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.danger)
                    .accessibilityIdentifier("settings.remoteAccess.bindFailedNote")
            } else {
                Text("Off binds the host API to 127.0.0.1. On binds to 0.0.0.0:\(DirectAccessConfiguration.port()) and publishes Bonjour; paired-device tokens are still required.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
            }
        }
        .dsPanel(padding: DS.Space.lg)
    }

    private var diffDefaultsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG("Diff Defaults")
            settingRow("Word wrap") {
                Toggle("", isOn: Binding(
                    get: { vm.appSettings.diffWordWrap },
                    set: { vm.setDiffWordWrap($0) }
                ))
                .labelsHidden()
                .accessibilityIdentifier("settings.diff.wordWrap.toggle")
            }
            settingRow("Ignore whitespace") {
                Toggle("", isOn: Binding(
                    get: { vm.appSettings.diffIgnoreWhitespace },
                    set: { vm.setDiffIgnoreWhitespace($0) }
                ))
                .labelsHidden()
                .accessibilityIdentifier("settings.diff.ignoreWhitespace.toggle")
            }
            Text("These defaults seed new Git diff surfaces and match the toolbar toggles in the diff panel.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
        }
        .dsPanel(padding: DS.Space.lg)
    }

    private var sidebarSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG("Sidebar")
            settingRow("Workspace sort order") {
                Picker("", selection: Binding(
                    get: { vm.appSettings.sidebarSort },
                    set: { vm.setSidebarSort($0) }
                )) {
                    Text("Last updated").tag("updated")
                    Text("Date created").tag("created")
                    Text("Manual").tag("manual")
                }
                .labelsHidden()
                .frame(width: 140)
                .accessibilityIdentifier("settings.sidebar.sortOrder.picker")
            }
        }
        .dsPanel(padding: DS.Space.lg)
    }

    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG("Terminal")
            settingRow("Font size") {
                Picker("", selection: Binding(
                    get: { TerminalFontSizeSetting.normalized(vm.appSettings.terminalFontSize) },
                    set: { vm.setTerminalFontSize($0) }
                )) {
                    Text("Ghostty default").tag(TerminalFontSizeSetting.defaultSize)
                    ForEach(Array(Int(TerminalFontSizeSetting.minSize)...Int(TerminalFontSizeSetting.maxSize)), id: \.self) { size in
                        let value = Double(size)
                        Text(TerminalFontSizeSetting.displayLabel(value)).tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                .accessibilityIdentifier("settings.terminal.fontSize.picker")
            }
            Text("New terminals use this base size; workspace zoom remains separate.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
        }
        .dsPanel(padding: DS.Space.lg)
    }

    private var petSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG("Desktop Pet")
                .accessibilityIdentifier("settings.pet.section")

            settingRow("Show black cat pet") {
                Toggle("", isOn: Binding(
                    get: { vm.appSettings.petEnabled },
                    set: { vm.setPetEnabled($0) }
                ))
                .labelsHidden()
                .accessibilityIdentifier("settings.pet.enabled.toggle")
            }

            if vm.appSettings.petEnabled {
                settingRow("Play animations") {
                    Toggle("", isOn: Binding(
                        get: { vm.appSettings.petAnimationsEnabled },
                        set: { vm.setPetAnimationsEnabled($0) }
                    ))
                    .labelsHidden()
                    .accessibilityIdentifier("settings.pet.animations.toggle")
                }

                settingRow("Show ready counter") {
                    Toggle("", isOn: Binding(
                        get: { vm.appSettings.petReadyCounterEnabled },
                        set: { vm.setPetReadyCounterEnabled($0) }
                    ))
                    .labelsHidden()
                    .accessibilityIdentifier("settings.pet.counter.toggle")
                }

                settingRow("Reduce motion") {
                    Toggle("", isOn: Binding(
                        get: { vm.appSettings.petReduceMotion },
                        set: { vm.setPetReduceMotion($0) }
                    ))
                    .labelsHidden()
                    .accessibilityIdentifier("settings.pet.reduceMotion.toggle")
                }

                settingRow("Position") {
                    Picker("", selection: Binding(
                        get: { vm.appSettings.petPosition },
                        set: { vm.setPetPosition($0) }
                    )) {
                        Text("Bottom right").tag("bottomRight")
                        Text("Bottom left").tag("bottomLeft")
                        Text("Free").tag("free")
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .accessibilityIdentifier("settings.pet.position.picker")
                }

                settingRow("Size") {
                    Picker("", selection: Binding(
                        get: { vm.appSettings.petSize },
                        set: { vm.setPetSize($0) }
                    )) {
                        Text("75%").tag(0.75)
                        Text("100%").tag(1.0)
                        Text("125%").tag(1.25)
                        Text("150%").tag(1.5)
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    .accessibilityIdentifier("settings.pet.size.picker")
                }

                settingRow("Attention items") {
                    Picker("", selection: Binding(
                        get: { vm.appSettings.petAttentionFilter },
                        set: { vm.setPetAttentionFilter($0) }
                    )) {
                        Text("All").tag("all")
                        Text("Completed only").tag("completed")
                        Text("Needs you").tag("needsYou")
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    .accessibilityIdentifier("settings.pet.filter.picker")
                }

                HStack {
                    Spacer()
                    Button("Reset position") {
                        NotificationCenter.default.post(name: .petResetPositionRequested, object: nil)
                    }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("settings.pet.resetPosition")
                }
            }

            Text("The pet starts and stops with Remote Code. Rows use fixed summaries and never expose prompts, commands, file contents, tokens, or secret answers.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dsPanel(padding: DS.Space.lg)
    }

    private var insomniaSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG("Insomnia")
            settingRow("Keep Mac awake while agents run") {
                Toggle("", isOn: Binding(
                    get: { vm.appSettings.insomniaEnabled },
                    set: { vm.setInsomniaEnabled($0) }
                ))
                .labelsHidden()
                .accessibilityIdentifier("settings.insomnia.enabled.toggle")
            }
            if vm.appSettings.insomniaEnabled {
                settingRow("Allow display to sleep") {
                    Toggle("", isOn: Binding(
                        get: { vm.appSettings.insomniaAllowDisplaySleep },
                        set: { vm.setInsomniaAllowDisplaySleep($0) }
                    ))
                    .labelsHidden()
                    .accessibilityIdentifier("settings.insomnia.allowDisplaySleep.toggle")
                }
                settingRow("Allow system sleep when lid closed") {
                    Toggle("", isOn: Binding(
                        get: { vm.appSettings.insomniaAllowSystemSleepWhenDisplayClosed },
                        set: { vm.setInsomniaAllowSystemSleepWhenDisplayClosed($0) }
                    ))
                    .labelsHidden()
                    .accessibilityIdentifier("settings.insomnia.allowSystemSleepWhenDisplayClosed.toggle")
                }
                settingRow("Allow screen saver after 45 min idle") {
                    Toggle("", isOn: Binding(
                        get: { vm.appSettings.insomniaAllowScreenSaverAfter45MinutesOfInactivity },
                        set: { vm.setInsomniaAllowScreenSaverAfter45MinutesOfInactivity($0) }
                    ))
                    .labelsHidden()
                    .accessibilityIdentifier("settings.insomnia.allowScreenSaverAfter45MinutesOfInactivity.toggle")
                }
            }
            Text("Insomnia is also controllable from the sidebar. Changes here are reflected there immediately.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
        }
        .dsPanel(padding: DS.Space.lg)
    }

    private var tokenSaverSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG("Token Saver")
            settingRow("Enable Token Saver (requires subscription)") {
                Toggle("", isOn: Binding(
                    get: { vm.appSettings.tokenSaverEnabled },
                    set: { vm.setTokenSaverEnabled($0) }
                ))
                .labelsHidden()
                .accessibilityIdentifier("settings.tokenSaver.enabled.toggle")
            }
            Text("Compresses large tool output using the local MLX model so fewer tokens reach the remote provider. Activating from the sidebar is the primary path; this toggle reflects the persisted value.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
            distillInstallStatusRow
        }
        .dsPanel(padding: DS.Space.lg)
    }

    @ViewBuilder
    private var distillInstallStatusRow: some View {
        switch vm.distillInstallStatus {
        case .inactive:
            EmptyView()
        case .installed:
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(DS.Palette.success)
                Text("Distill skill installed for Claude + Codex")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
            }
            .accessibilityIdentifier("settings.tokenSaver.distillInstall.ok")
        case .failed(let reason):
            HStack(alignment: .top, spacing: DS.Space.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(DS.Palette.danger)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Distill skill install failed: \(reason)")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.danger)
                        .textSelection(.enabled)
                    Button("Retry install") { vm.retryDistillInstall() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .accessibilityIdentifier("settings.tokenSaver.distillInstall.failed")
        }
    }

    // todo/macos-app.md :142 - Keybindings editor pane (list parsed bindings +
    // warnings, conflict detection vs the static menu map, record-a-shortcut,
    // live-reload watcher). Heavy view code lives in KeybindingsSettingsPane.swift.
    private var keybindingsSection: some View {
        KeybindingsSettingsPane()
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG("Advanced")
            settingRow("Session Learn (writes to CLAUDE.md / AGENTS.md)") {
                Toggle("", isOn: Binding(
                    get: { vm.appSettings.sessionLearnEnabled },
                    set: { vm.setSessionLearnEnabled($0) }
                ))
                .labelsHidden()
                .accessibilityIdentifier("settings.advanced.sessionLearn.toggle")
            }
            settingRow("History compaction (lossy-recoverable storage)") {
                Toggle("", isOn: Binding(
                    get: { vm.appSettings.historyCompactionEnabled },
                    set: { vm.setHistoryCompactionEnabled($0) }
                ))
                .labelsHidden()
                .accessibilityIdentifier("settings.advanced.historyCompaction.toggle")
            }
            Text("Session Learn mines correction rules from failed runs into managed instructions. History Compaction stores large tool output in a structure-preserving compressed form. Both are off by default.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
        }
        .dsPanel(padding: DS.Space.lg)
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG("Storage")
            if let snapshot = vm.storageSnapshot {
                settingRow("Local database") {
                    Text(Self.storageByteLabel(snapshot.databaseBytes))
                        .font(DS.Font.body)
                        .foregroundColor(DS.Palette.textSecondary)
                        .accessibilityIdentifier("settings.storage.databaseBytes")
                }
                ForEach(snapshot.classes, id: \.storageClass) { usage in
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        HStack {
                            Text(usage.storageClass.displayName)
                                .font(DS.Font.body)
                                .foregroundColor(DS.Palette.text)
                            Spacer()
                            Text("\(Self.storageByteLabel(usage.payloadBytes)) of \(Self.storageByteLabel(usage.payloadQuotaBytes)) payload budget")
                                .font(DS.Font.caption)
                                .foregroundColor(usage.payloadBytes > usage.payloadQuotaBytes ? DS.Palette.danger : DS.Palette.textSecondary)
                        }
                        Text("\(usage.rowCount) items · \(usage.retentionDays)-day retention")
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textTertiary)
                    }
                    .accessibilityIdentifier("settings.storage.class.\(usage.storageClass.rawValue)")
                }
                if snapshot.reclaimableBytes > 0 {
                    Text("\(Self.storageByteLabel(snapshot.reclaimableBytes)) can be reclaimed by database compaction.")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                }
            } else {
                Text(vm.storageOperationInProgress ? "Reading local storage…" : "Storage usage is unavailable.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
            }

            HStack(spacing: DS.Space.sm) {
                Button("Refresh") {
                    Task { await vm.refreshStorageUsage() }
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .disabled(vm.storageOperationInProgress)
                .accessibilityIdentifier("settings.storage.refresh")

                Button("Clean Up Expired Data") {
                    Task { await vm.cleanUpExpiredStorage() }
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .disabled(vm.storageOperationInProgress)
                .accessibilityIdentifier("settings.storage.cleanup")

                if vm.storageOperationInProgress {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Storage operation in progress")
                }
            }
            Text("Cleanup removes only diagnostics and unreferenced local payloads older than 30 days. Referenced attachments and recoverable [[rc:handle]] originals are preserved.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let status = vm.storageOperationStatus {
                Text(status)
                    .font(DS.Font.caption)
                    .foregroundColor(status.hasPrefix("Storage cleanup failed") ? DS.Palette.danger : DS.Palette.textSecondary)
                    .accessibilityIdentifier("settings.storage.status")
            }
        }
        .dsPanel(padding: DS.Space.lg)
        .accessibilityIdentifier("settings.section.storage")
    }

    private static func storageByteLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var customModelsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG("Custom Models")
            let hasModels = AgentProvider.allCases.contains { !(vm.customModelsByProvider[$0] ?? []).isEmpty }
            if !hasModels {
                Text("No custom models saved. Add one from the Agent model menu.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
            }
            ForEach(AgentProvider.allCases, id: \.self) { provider in
                let models = vm.customModelsByProvider[provider] ?? []
                if !models.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        Text(vm.providerDisplayName(provider))
                            .font(DS.Font.caption2.weight(.semibold))
                            .foregroundColor(DS.Palette.textTertiary)
                        ForEach(Array(models.enumerated()), id: \.offset) { index, _ in
                            HStack(spacing: DS.Space.sm) {
                                TextField("Model ID", text: Binding(
                                    get: {
                                        let values = vm.customModelsByProvider[provider] ?? []
                                        return values.indices.contains(index) ? values[index] : ""
                                    },
                                    set: { vm.setCustomModel(provider: provider, index: index, value: $0) }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(DS.Font.monoSmall)
                                .accessibilityIdentifier("settings.customModel.\(provider.rawValue).\(index).field")
                                Button {
                                    vm.removeCustomModel(provider: provider, index: index)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12, weight: .semibold))
                                        .frame(width: 18, height: 18)
                                }
                                .help("Remove custom model")
                                .buttonStyle(DSSecondaryButtonStyle())
                                .accessibilityIdentifier("settings.customModel.\(provider.rawValue).\(index).remove")
                            }
                        }
                    }
                }
            }
        }
        .dsPanel(padding: DS.Space.lg)
    }

    private var trustedDevicesSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG("Trusted Devices")
            if !vm.remoteAccessEnabled {
                Text("Turn on Remote Access for paired devices to reach this Mac. A pairing code generated while it's off won't be reachable from another device.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.warning)
                    .accessibilityIdentifier("settings.pairing.remoteAccessOffNote")
            }
            if let c = vm.newPairingCode, let expiresAt = vm.pairingCodeExpiresAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(expiresAt.timeIntervalSince(context.date).rounded(.up)))
                    let expired = remaining <= 0
                    HStack(spacing: DS.Space.lg) {
                        Button(expired ? "Generate again" : "Generate pairing code") { vm.createPairingCode() }
                            .buttonStyle(DSSecondaryButtonStyle())
                            .accessibilityIdentifier("settings.pairing.generate")
                        Text(c).font(DS.Font.title2.monospaced())
                            .foregroundColor(expired ? DS.Palette.textTertiary : DS.Palette.success)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("settings.pairing.code")
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(c, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 18, height: 18)
                        }
                        .help("Copy pairing code")
                        .buttonStyle(DSSecondaryButtonStyle())
                        .disabled(expired)
                        .accessibilityIdentifier("settings.pairing.copy")
                        Text(expired ? "Expired" : String(format: "Expires in %d:%02d", remaining / 60, remaining % 60))
                            .font(DS.Font.caption)
                            .foregroundColor(expired ? DS.Palette.danger : DS.Palette.textTertiary)
                    }
                }
                // QR code: shown while the code is live; hidden once expired.
                // WHY: the QR encodes the same pairing URL the user can type manually,
                // so scanning it is strictly an ergonomic shortcut — the security
                // boundary is unchanged (code still expires in 600 s).
                if let payload = vm.pairingQRPayload {
                    PairingQRView(payload: payload)
                        .accessibilityIdentifier("settings.pairing.qr")
                }
            } else {
                Button("Generate pairing code") { vm.createPairingCode() }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("settings.pairing.generate")
            }
            // P2-Settings-4: surface pairing-code generation failures.
            if let err = vm.pairingCodeError {
                Text(err)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.danger)
                    .accessibilityIdentifier("settings.pairing.error")
            }
            // P1-Settings-3: surface revoke failures so the user knows the
            // device was not actually disconnected.
            if let err = vm.revokeErrorMessage {
                Text(err)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.danger)
                    .accessibilityIdentifier("settings.revoke.error")
            }
            let hasRevoked = vm.devices.contains { $0.revokedAt != nil }
            if hasRevoked {
                HStack {
                    Spacer()
                    Button("Delete Revoked") { vm.deleteRevoked() }
                        .buttonStyle(DSSecondaryButtonStyle())
                        .accessibilityIdentifier("settings.devices.deleteRevoked")
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.sm) {
                    if vm.devices.isEmpty {
                        Text("No paired devices.")
                            .font(DS.Font.caption).foregroundColor(DS.Palette.textTertiary)
                            .padding(DS.Space.md)
                    }
                    ForEach(vm.devices, id: \.id) { d in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.displayName).font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                                Text(deviceSubtitle(d))
                                    .font(DS.Font.monoSmall).foregroundColor(DS.Palette.textTertiary)
                            }
                            Spacer()
                            if d.revokedAt != nil {
                                DSPill("revoked", tone: .danger)
                            } else {
                                if d.alwaysAllowPairing {
                                    DSPill("always allow", tone: .success)
                                    Button("Disable Always Allow") {
                                        vm.setAlwaysAllowPairing(deviceID: d.id, enabled: false)
                                    }
                                    .buttonStyle(DSSecondaryButtonStyle())
                                    .accessibilityIdentifier("settings.device.\(d.id).alwaysAllow")
                                } else if d.clientDeviceID != nil {
                                    Button("Always Allow") {
                                        vm.setAlwaysAllowPairing(deviceID: d.id, enabled: true)
                                    }
                                    .buttonStyle(DSSecondaryButtonStyle())
                                    .accessibilityIdentifier("settings.device.\(d.id).alwaysAllow")
                                }
                                Button("Revoke") { deviceToRevoke = d }
                                    .buttonStyle(DSSecondaryButtonStyle())
                                    .accessibilityIdentifier("settings.device.\(d.id).revoke")
                            }
                        }
                        .dsPanel(padding: DS.Space.md)
                    }
                }
            }.frame(maxHeight: 150)

            if !vm.auditLogEntries.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Audit Log")
                        .font(DS.Font.caption2.weight(.semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(vm.auditLogEntries, id: \.id) { entry in
                                Text(AuditLogRowFormatter.line(entry, isoFormatter: Self.deviceDateFormatter))
                                    .font(DS.Font.monoSmall)
                                    .foregroundColor(DS.Palette.textTertiary)
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("settings.auditLog.\(entry.id)")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                }
            }
        }
        .dsPanel(padding: DS.Space.lg)
        .alert("Revoke device?",
               isPresented: Binding(get: { deviceToRevoke != nil }, set: { if !$0 { deviceToRevoke = nil } }),
               presenting: deviceToRevoke) { device in
            Button("Revoke", role: .destructive) { vm.revoke(device.id) }
            Button("Cancel", role: .cancel) {}
        } message: { device in
            Text("\(device.displayName) will need to pair again to access this Mac.")
        }
    }

    /// Device row caption: short id, localized medium paired date, and a
    /// relative "last seen" when the device has connected since pairing so
    /// users can recognize an active device instead of only an 8-char hash.
    /// Uses DateFormatter.medium instead of ISO8601 per P3-Settings-14.
    private func deviceSubtitle(_ d: DeviceTrust) -> String {
        var parts = [d.id.prefix(8) + " \u{00B7} " + Self.deviceMediumDateFormatter.string(from: d.createdAt)]
        if let lastSeen = d.lastSeenAt {
            parts.append("seen " + Self.deviceRelativeFormatter.localizedString(for: lastSeen, relativeTo: Date()))
        }
        if d.alwaysAllowPairing { parts.append("always allow") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Claude engine picker: CLI (recommended, no Node/npm) vs SDK bridge
    /// (advanced). Discloses what the SDK opt-in costs and adds. Read-only when
    /// an env override pins the engine.
    private var claudeEngineRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Claude engine")
                .font(DS.Font.caption2.weight(.semibold)).foregroundColor(DS.Palette.textTertiary)
            Picker("", selection: Binding(
                get: { vm.claudeEngine },
                set: { vm.setClaudeEngine($0) }
            )) {
                Text("Claude CLI — Recommended").tag(ClaudeEngine.cli)
                Text("Agent SDK Bridge — Advanced").tag(ClaudeEngine.sdk)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(vm.claudeEngineLockedByEnv)
            .accessibilityIdentifier("settings.claude.engine")
            Text(vm.claudeEngine == .sdk
                 ? "Advanced: needs Node.js 18+ and installs the Agent SDK on first use. Adds session forking and live model/permission switching. Uses your installed Claude CLI — no second native download."
                 : "Runs your installed Claude CLI directly. No Node.js, npm, or SDK download. Fork and live model/permission switching are unavailable.")
                .font(DS.Font.caption2).foregroundColor(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if vm.claudeEngineLockedByEnv {
                Text("Pinned by RC_CLAUDE_AGENT_SDK_ENABLED.")
                    .font(DS.Font.caption2).foregroundColor(DS.Palette.textTertiary)
            }
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG("Diagnostics")
            cliPathRow(
                label: "Codex path",
                draft: $codexPathDraft,
                onDraftChange: { vm.setCodexPath($0, committed: false) },
                onCommit: { vm.setCodexPath(codexPathDraft, committed: true) },
                available: vm.codexAvailable,
                provider: .codex
            )
            cliPathRow(
                label: "Claude path",
                draft: $claudePathDraft,
                onDraftChange: { vm.setClaudePath($0, committed: false) },
                onCommit: { vm.setClaudePath(claudePathDraft, committed: true) },
                available: vm.claudeAvailable,
                provider: .claude
            )
            claudeEngineRow
            cliPathRow(
                label: "Grok path",
                draft: $grokPathDraft,
                onDraftChange: { vm.setGrokPath($0, committed: false) },
                onCommit: { vm.setGrokPath(grokPathDraft, committed: true) },
                available: vm.grokAvailable,
                provider: .grok
            )
            if vm.showsAppUpdates {
                appUpdatesRow
            }
            notificationsRow
            Text("State directory")
                .font(DS.Font.caption2.weight(.semibold)).foregroundColor(DS.Palette.textTertiary)
            HStack(spacing: DS.Space.md) {
                Text(vm.context.bootstrapReport.path)
                    .font(DS.Font.monoSmall).foregroundColor(DS.Palette.textSecondary)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: vm.context.bootstrapReport.path)])
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .accessibilityIdentifier("settings.stateDirectory.reveal")
            }
            Text("Keybindings config")
                .font(DS.Font.caption2.weight(.semibold)).foregroundColor(DS.Palette.textTertiary)
            HStack(spacing: DS.Space.md) {
                Text(KeybindingConfigReveal.configPath)
                    .font(DS.Font.monoSmall).foregroundColor(DS.Palette.textSecondary)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button("Reveal config") {
                    KeybindingConfigReveal.revealCreatingIfAbsent()
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .accessibilityIdentifier("settings.keybindingsConfig.reveal")
            }
        }
        .dsPanel(padding: DS.Space.lg)
    }

    private var appUpdatesRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.md) {
                Text("App Updates")
                    .font(DS.Font.caption2.weight(.semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                Text("Version \(vm.appVersionString)")
                    .font(DS.Font.monoSmall)
                    .foregroundColor(DS.Palette.textSecondary)
                if vm.updateAvailability == .checking {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
                Spacer()
                Button("Check Now") { vm.checkForAppUpdates() }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .disabled(vm.updateAvailability == .checking)
                    .accessibilityIdentifier("settings.appUpdates.checkNow")
            }
            if let status = updateStatusText {
                Text(status)
                    .font(DS.Font.caption)
                    .foregroundColor(updateStatusIsError ? DS.Palette.danger : DS.Palette.textTertiary)
            }
        }
    }

    private var notificationsRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.md) {
                Text("Notifications")
                    .font(DS.Font.caption2.weight(.semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                Spacer()
                if notificationStatus == .denied {
                    Button("Open Notification Settings") {
                        SystemNotifier.shared.openSystemNotificationSettings()
                    }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("settings.notifications.openSettings")
                } else {
                    Button("Test notification") {
                        SystemNotifier.shared.postTestNotification()
                        Task { await vm.refreshNotificationStatus() }
                    }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("settings.notifications.test")
                }
            }
            if notificationStatus == .denied {
                Text("Notifications are turned off for RemoteCode. Thread banners won't appear until you re-enable them in System Settings.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.danger)
                    .accessibilityIdentifier("settings.notifications.deniedNote")
            }
        }
    }

    private var updateStatusText: String? {
        switch vm.updateAvailability {
        case .available: return "An update is available."
        case .upToDate: return "RemoteCode is up to date."
        case .failed(let message): return "Update check failed: \(message)"
        case .checking, .unknown: return nil
        }
    }

    private var updateStatusIsError: Bool {
        if case .failed = vm.updateAvailability { return true }
        return false
    }

    /// Render a CLI path row.
    ///
    /// `draft` is the local keystroke-level binding; `onDraftChange` is called
    /// on every keystroke (updates display/availability pill only); `onCommit`
    /// is called only when the user ends editing (Return key or focus loss) so
    /// that saveCLIPath / replaceProviderAdapter are not hit mid-edit.
    private func cliPathRow(
        label: String,
        draft: Binding<String>,
        onDraftChange: @escaping (String) -> Void,
        onCommit: @escaping () -> Void,
        available: Bool,
        provider: AgentProvider
    ) -> some View {
        let updating = vm.updatingProviders.contains(provider)
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.md) {
                Text(label)
                    .font(DS.Font.caption2.weight(.semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                DSPill(available ? "found" : "missing", tone: available ? .success : .danger)
                Spacer()
                if updating {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
                Button(updating ? "Updating..." : "Update") {
                    Task { await vm.updateProvider(provider) }
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .disabled(!available || updating)
                .accessibilityIdentifier("settings.cli.\(provider.rawValue).update")
            }
            HStack(spacing: DS.Space.sm) {
                TextField("", text: draft, onCommit: onCommit)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Font.monoSmall)
                    .foregroundColor(DS.Palette.text)
                    .onChange(of: draft.wrappedValue, perform: onDraftChange)
                    .accessibilityIdentifier("settings.cli.\(provider.rawValue).field")
                Button("Browse...") { browseForBinary(into: draft, onCommit: onCommit) }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("settings.cli.\(provider.rawValue).browse")
            }
            if let message = vm.providerUpdateMessages[provider] {
                let isError = message.hasPrefix("Update failed")
                let expanded = expandedUpdateDetails.contains(provider)
                let isLong = message.count > 200 || message.contains("\n")
                VStack(alignment: .leading, spacing: 2) {
                    Text(expanded || !isLong ? message : String(message.prefix(200)) + "...")
                        .font(DS.Font.caption)
                        .foregroundColor(isError ? DS.Palette.danger : DS.Palette.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(expanded ? nil : 3)
                        .accessibilityIdentifier("settings.cli.\(provider.rawValue).updateMessage")
                    if isLong {
                        Button(expanded ? "Hide details" : "Show details") {
                            if expanded { expandedUpdateDetails.remove(provider) }
                            else { expandedUpdateDetails.insert(provider) }
                        }
                        .buttonStyle(.link)
                        .font(DS.Font.caption)
                    }
                }
            }
        }
    }

    /// Opens an NSOpenPanel and, if the user picks a file, writes the path into
    /// `value` and immediately calls `onCommit` so the picker acts as an
    /// end-editing event (same as pressing Return in the text field).
    private func browseForBinary(into value: Binding<String>, onCommit: @escaping () -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the CLI executable"
        if panel.runModal() == .OK, let url = panel.url {
            value.wrappedValue = url.path
            onCommit()
        }
    }
}

public struct AccountView: View {
    @ObservedObject var vm: SettingsViewModel
    private let onClose: (() -> Void)?

    private enum SignInField: Hashable { case email, password }
    @FocusState private var focusedField: SignInField?
    @State private var revealPassword = false

    public init(vm: SettingsViewModel, onClose: (() -> Void)? = nil) {
        self.vm = vm
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            HStack(alignment: .top, spacing: DS.Space.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .fill(DS.Palette.accent.opacity(0.16))
                    Image(systemName: vm.privateAccountUser == nil ? "person.crop.circle.badge.plus" : "person.crop.circle.badge.checkmark")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(DS.Palette.accent)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(vm.privateAccountUser == nil ? "Sign in to RemoteCode" : "RemoteCode Account")
                        .font(DS.Font.title3)
                        .foregroundColor(DS.Palette.text)
                    Text(vm.privateAccountUser == nil ? "Connect your private account for backend push notifications to paired devices." : "Manage the private account connected to this Mac.")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Done") { onClose?() }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("account.done")
            }

            if vm.privateAccountUser == nil {
                signedOutForm
            } else {
                signedInPanel
            }
        }
        .padding(DS.Space.xxl)
        .frame(width: 460)
        .background(DS.Palette.bg)
    }

    private var signedOutForm: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack {
                Text("Status")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                Spacer()
                DSPill(vm.privateAccountStatus,
                       tone: SettingsViewModel.signInFailureStatuses.contains(vm.privateAccountStatus) ? .danger : .warning)
            }

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Email")
                    .font(DS.Font.captionStrong)
                    .foregroundColor(DS.Palette.textSecondary)
                TextField("you@example.com", text: Binding(get: { vm.privateAccountEmail }, set: { vm.privateAccountEmail = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Font.body)
                    .focused($focusedField, equals: .email)
                    .dsFocusRing(isFocused: focusedField == .email)
                    .onSubmit { focusedField = .password }
                    .accessibilityIdentifier("account.email")
            }

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Password")
                    .font(DS.Font.captionStrong)
                    .foregroundColor(DS.Palette.textSecondary)
                HStack(spacing: DS.Space.sm) {
                    Group {
                        if revealPassword {
                            TextField("Password", text: Binding(get: { vm.privateAccountPassword }, set: { vm.privateAccountPassword = $0 }))
                        } else {
                            SecureField("Password", text: Binding(get: { vm.privateAccountPassword }, set: { vm.privateAccountPassword = $0 }))
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Font.body)
                    .focused($focusedField, equals: .password)
                    .dsFocusRing(isFocused: focusedField == .password)
                    .onSubmit { Task { await vm.connectPrivateAccount() } }
                    .accessibilityIdentifier("account.password")
                    Button {
                        revealPassword.toggle()
                    } label: {
                        Image(systemName: revealPassword ? "eye.slash" : "eye")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 18, height: 18)
                    }
                    .help(revealPassword ? "Hide password" : "Show password")
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("account.password.reveal")
                }
            }

            Button {
                Task { await vm.connectPrivateAccount() }
            } label: {
                HStack(spacing: DS.Space.sm) {
                    if vm.privateAccountBusy {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.65)
                    }
                    Text(vm.privateAccountBusy ? "Signing in..." : "Sign in")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(vm.privateAccountBusy)
            .accessibilityIdentifier("account.signIn")

            if SettingsViewModel.signInFailureStatuses.contains(vm.privateAccountStatus) {
                Text(signInFailureHint)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.danger)
                    .accessibilityIdentifier("account.signIn.error")
            }
        }
        .dsPanel(padding: DS.Space.xl, raised: true)
        .onAppear { focusedField = .email }
    }

    private var signInFailureHint: String {
        switch vm.privateAccountStatus {
        case "No internet connection": return "No internet connection. Check your network and try again."
        case "Too many attempts, wait a minute": return "Too many attempts. Wait a minute, then try again."
        case "Service unavailable", "Service error": return "The service is unavailable right now. Try again shortly."
        case "Session expired": return "Your session expired. Sign in again."
        default: return "Check the email and password, then try again."
        }
    }

    private var signedInPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack(alignment: .center, spacing: DS.Space.md) {
                ZStack {
                    Circle()
                        .fill(DS.Palette.accent.opacity(0.20))
                        .overlay(Circle().stroke(DS.Palette.lineStrong, lineWidth: DS.Border.hairline))
                    Text(accountInitials)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Palette.accent)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(accountName)
                        .font(DS.Font.bodyStrong)
                        .foregroundColor(DS.Palette.text)
                    Text(vm.privateAccountUser?.email ?? "")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                        .textSelection(.enabled)
                }
                Spacer()
                DSPill(vm.privateAccountStatus, tone: vm.privateAccountUser?.subscribed == true ? .success : .warning)
            }

            if let detail = subscriptionDetailCaption {
                Text(detail)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                    .accessibilityIdentifier("account.subscriptionDetail")
            }

            if vm.privateAccountUser?.subscribed == false {
                Button {
                    Task { await vm.openPrivateBillingPortal() }
                } label: {
                    HStack(spacing: DS.Space.sm) {
                        if vm.privateAccountBusy {
                            ProgressView().controlSize(.small).scaleEffect(0.65)
                        }
                        Text("Start subscription")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .disabled(vm.privateAccountBusy)
                .accessibilityIdentifier("account.startSubscription")
            }

            HStack(spacing: DS.Space.md) {
                Button("Refresh") { Task { await vm.refreshPrivateAccount() } }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .disabled(vm.privateAccountBusy)
                    .accessibilityIdentifier("account.refresh")
                Button {
                    Task { await vm.openPrivateBillingPortal() }
                } label: {
                    HStack(spacing: DS.Space.xs) {
                        if vm.privateAccountBusy {
                            ProgressView().controlSize(.small).scaleEffect(0.55)
                        }
                        Text("Billing")
                    }
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .disabled(vm.privateAccountBusy)
                .accessibilityIdentifier("account.billing")
                Spacer()
                Button("Disconnect") { Task { await vm.disconnectPrivateAccount() } }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .disabled(vm.privateAccountBusy)
                    .accessibilityIdentifier("account.disconnect")
            }

            if let caption = signedInStatusCaption {
                Text(caption)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.danger)
                    .accessibilityIdentifier("account.statusCaption")
            }
        }
        .dsPanel(padding: DS.Space.xl, raised: true)
    }

    /// Surfaces Refresh/Billing error copy inside the signed-in panel (the pill
    /// tone alone didn't convey these). Nil for the normal subscribed/unsubscribed
    /// states, which the pill already describes.
    private var signedInStatusCaption: String? {
        switch vm.privateAccountStatus {
        case "Billing portal unavailable": return "Billing portal unavailable. Try again shortly."
        case "Session expired": return "Your session expired. Sign in again."
        default: return nil
        }
    }

    /// At-a-glance renewal/trial copy from the already-loaded account snapshot
    /// (`daysRemaining`), so subscribed users see "Renews in N days" rather than
    /// only a bare status pill. Nil when there is no meaningful countdown.
    private var subscriptionDetailCaption: String? {
        guard let user = vm.privateAccountUser, user.daysRemaining > 0 else { return nil }
        let days = user.daysRemaining
        let unit = days == 1 ? "day" : "days"
        return user.subscribed ? "Renews in \(days) \(unit)." : "Trial ends in \(days) \(unit)."
    }

    private var accountName: String {
        guard let email = vm.privateAccountUser?.email, let local = email.split(separator: "@").first, !local.isEmpty else {
            return "RemoteCode Account"
        }
        return String(local)
    }

    private var accountInitials: String {
        guard let email = vm.privateAccountUser?.email, let local = email.split(separator: "@").first else {
            return "RC"
        }
        let letters = local.filter(\.isLetter)
        let prefix = letters.prefix(2)
        return prefix.isEmpty ? "RC" : String(prefix).uppercased()
    }
}

@MainActor
public final class SettingsWindowController: NSObject {
    public let window: NSWindow
    public let viewModel: SettingsViewModel
    private let routeRegistry: SettingsRouteRegistry
    private var presentedRoute: PetSettingsRoute?

    public init(context: AppContext, updater: AppUpdateChecking? = nil) {
        self.viewModel = SettingsViewModel(context: context, updater: updater)
        let routeRegistry = SettingsRouteRegistry()
        self.routeRegistry = routeRegistry
        let host = NSHostingController(rootView: SettingsView(
            vm: viewModel,
            onClose: nil,
            routeRegistry: routeRegistry
        ))
        let win = NSWindow(contentViewController: host)
        win.title = "RemoteCode Settings"
        win.setAccessibilityRole(.window)
        win.setAccessibilitySubrole(.standardWindow)
        win.setAccessibilityTitle("RemoteCode Settings")
        win.setAccessibilityIdentifier("window.settings")
        win.styleMask = [.titled, .closable, .resizable]
        // Match the SwiftUI content frame so the window doesn't open smaller
        // than its content and jump-resize; guard against shrinking below it.
        win.setContentSize(NSSize(width: 620, height: 560))
        win.contentMinSize = NSSize(width: 620, height: 480)
        win.center()
        self.window = win
        host.rootView = SettingsView(
            vm: viewModel,
            onClose: { [weak win] in
                guard let win else { return }
                if let parent = win.sheetParent {
                    parent.endSheet(win)
                } else {
                    win.close()
                }
            },
            routeRegistry: routeRegistry
        )
    }

    public func show() {
        viewModel.reload()
        Task { await viewModel.refreshNotificationStatus() }
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow {
            show(attachedTo: parent)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    public func show(attachedTo parent: NSWindow) {
        viewModel.reload()
        Task { await viewModel.refreshNotificationStatus() }
        if parent.attachedSheet === window { return }
        if window.sheetParent != nil { window.sheetParent?.endSheet(window) }
        parent.beginSheet(window)
    }

    @discardableResult
    public func show(route: PetSettingsRoute) -> Bool {
        show()
        return present(route)
    }

    @discardableResult
    public func show(route: PetSettingsRoute, attachedTo parent: NSWindow) -> Bool {
        show(attachedTo: parent)
        return present(route)
    }

    public func close() {
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }

    var presentedRouteForTests: PetSettingsRoute? { presentedRoute }

    func isRouteVisibleForTests(_ route: PetSettingsRoute) -> Bool {
        routeRegistry.isVisible(route, in: window)
    }

    private func present(_ route: PetSettingsRoute) -> Bool {
        presentedRoute = nil
        window.contentView?.layoutSubtreeIfNeeded()
        guard routeRegistry.present(route, in: window) else { return false }
        presentedRoute = route
        return true
    }
}

// MARK: - PairingQRView

/// Renders the pairing QR code that encodes the `remotecode://pair?...` URL.
///
/// WHY: CoreImage QR output is a raw CIImage at 1:1 pixel resolution; it must
/// be scaled via NSCIImageRep before SwiftUI Image displays it at a readable
/// size. Interpolation is disabled so pixels remain crisp.
///
/// Stateless: recomputes NSImage only when `payload` changes (at most once per
/// code generation, not on every TimelineView tick).
private struct PairingQRView: View {
    let payload: String

    var body: some View {
        if let nsImage = makeQRImage(payload: payload) {
            Image(nsImage: nsImage)
                .interpolation(.none)
                .resizable()
                .frame(width: 128, height: 128)
                .accessibilityLabel("Scan to pair with this Mac")
        }
    }

    private func makeQRImage(payload: String) -> NSImage? {
        guard let ciImage = PairingQRPayload.qrCIImage(payload: payload) else { return nil }
        let rep = NSCIImageRep(ciImage: ciImage)
        let nsImage = NSImage(size: NSSize(width: 128, height: 128))
        nsImage.addRepresentation(rep)
        return nsImage
    }
}

@MainActor
public final class AccountWindowController: NSObject {
    public let window: NSWindow
    public let viewModel: SettingsViewModel

    public init(context: AppContext) {
        self.viewModel = SettingsViewModel(context: context)
        let host = NSHostingController(rootView: AccountView(vm: viewModel))
        let win = NSWindow(contentViewController: host)
        win.title = "RemoteCode Account"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 460, height: 360))
        win.center()
        self.window = win
        host.rootView = AccountView(vm: viewModel) { [weak win] in
            guard let win else { return }
            if let parent = win.sheetParent {
                parent.endSheet(win)
            } else {
                win.close()
            }
        }
    }

    public func show() {
        viewModel.reload()
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow {
            show(attachedTo: parent)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    public func show(attachedTo parent: NSWindow) {
        viewModel.reload()
        if parent.attachedSheet === window { return }
        if window.sheetParent != nil { window.sheetParent?.endSheet(window) }
        parent.beginSheet(window)
    }

    public func close() {
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }
}
