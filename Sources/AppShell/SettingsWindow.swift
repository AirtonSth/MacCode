import Foundation
import AppKit
import SwiftUI
import CoreModel
import Persistence
import AgentRuntime
import SocketServer
import DesignSystemKit
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
        "sessionLearnEnabled",
        "historyCompactionEnabled",
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

@MainActor
public final class SettingsViewModel: ObservableObject {
    public let settingsRepo: SettingsRepository
    public let trustRepo: DeviceTrustRepository
    public let settingsStore: SettingsStore
    public let customModelStore: AgentCustomModelStore
    public let context: AppContext
    private let privateAccountAPI: PrivateAccountAPI
    private let privateAccountStore: PrivateAccountSessionStore
    private let openURL: @MainActor (URL) -> Void
    private let updater: AppUpdateChecking?
    private var changeObservers: [NSObjectProtocol] = []

    @Published public var remoteAccessEnabled: Bool = false
    @Published public var appSettings: AppSettings = AppSettings()
    @Published public var codexPath: String = ""
    @Published public var claudePath: String = ""
    /// Last value that was actually persisted + wired into the coordinator.
    /// Used by CLIPathCommitPolicy to skip no-op commits.
    public var committedCodexPath: String = ""
    public var committedClaudePath: String = ""
    @Published public var codexAvailable: Bool = false
    @Published public var claudeAvailable: Bool = false
    @Published public var devices: [DeviceTrust] = []
    @Published public var auditLogEntries: [AuditLogEntry] = []
    @Published public var newPairingCode: String?
    @Published public var pairingCodeExpiresAt: Date?
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
        self.privateAccountStore = PrivateAccountSessionStore(repo: context.settingsRepo)
        self.updateAvailability = updater?.availability ?? .unknown
        reload()
        // Keep separate Settings/Account window instances in sync: when either
        // posts an account/remote-access change, refresh this instance too so it
        // never shows stale status (mirrors SidebarViewModel's observer).
        for name in [Notification.Name.rc2PrivateAccountChanged, .rc2RemoteAccessSettingChanged] {
            changeObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reload() }
            })
        }
    }

    deinit {
        changeObservers.forEach(NotificationCenter.default.removeObserver)
    }

    public func reload() {
        remoteAccessEnabled = (try? settingsRepo.get("remote_access_enabled")) == "1"
        appSettings = settingsStore.load()
        codexPath = cliPath(key: "cli.codex.path", fallback: "codex")
        claudePath = cliPath(key: "cli.claude.path", fallback: "claude")
        committedCodexPath = codexPath
        committedClaudePath = claudePath
        codexAvailable = resolveAvailable(codexPath)
        claudeAvailable = resolveAvailable(claudePath)
        providerUpdateMessages = [:]
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
        remoteAccessEnabled = on
        try? settingsRepo.set("remote_access_enabled", on ? "1" : "0")
        NotificationCenter.default.post(name: .rc2RemoteAccessSettingChanged, object: nil)
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

    public func setSessionLearnEnabled(_ on: Bool) {
        appSettings.sessionLearnEnabled = on
        settingsStore.update { $0.sessionLearnEnabled = on }
    }

    public func setHistoryCompactionEnabled(_ on: Bool) {
        appSettings.historyCompactionEnabled = on
        settingsStore.update { $0.historyCompactionEnabled = on }
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

    public func setCustomModel(provider: AgentProvider, index: Int, value: String) {
        customModelStore.update(provider: provider, index: index, value: value)
        // Mutate the affected element in place rather than re-listing the whole
        // provider on every keystroke; avoids a full DB read + dict replacement
        // (which re-rendered the entire Custom Models section per character).
        if var values = customModelsByProvider[provider], values.indices.contains(index) {
            values[index] = value
            customModelsByProvider[provider] = values
        } else {
            customModelsByProvider[provider] = customModelStore.list(provider: provider)
        }
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
        if let pc = try? trustRepo.createPairingCode(ttlSeconds: 600) {
            newPairingCode = pc.code
            pairingCodeExpiresAt = Date().addingTimeInterval(600)
        }
    }

    public func revoke(_ id: String) {
        try? trustRepo.revoke(id: id)
        reload()
    }

    /// Remove all revoked device rows from the device_trust table so the list
    /// stays clean. Only affects rows where revoked_at IS NOT NULL.
    public func deleteRevoked() {
        try? trustRepo.deleteRevoked()
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

    private func resolveAvailable(_ path: String) -> Bool {
        ProcessLocator.resolve(path).map { !$0.isEmpty } ?? false
    }

    private func cliPath(key: String, fallback: String) -> String {
        let stored = ((try? settingsRepo.get(key)) ?? "")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? (ProcessLocator.resolve(fallback) ?? fallback) : stored
    }

    private func saveCLIPath(key: String, provider: AgentProvider, path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        try? settingsRepo.set(key, trimmed)
        switch provider {
        case .codex:
            context.coordinator.replaceProviderAdapter(.codex, adapter: CodexAppServerAdapter(binaryNameOverride: trimmed.isEmpty ? nil : trimmed))
        case .claude:
            if ProcessInfo.processInfo.environment["RC_CLAUDE_AGENT_SDK_ENABLED"] == "0" {
                context.coordinator.replaceProviderAdapter(.claude, adapter: ClaudeStreamingCLIAdapter(binaryNameOverride: trimmed.isEmpty ? nil : trimmed))
            } else {
                context.coordinator.replaceProviderAdapter(.claude, adapter: ClaudeAgentSDKBridgeAdapter())
            }
        }
    }
}

public struct SettingsView: View {
    @ObservedObject var vm: SettingsViewModel
    private let onClose: (() -> Void)?

    // Hoisted so device rows don't each allocate a formatter on every render.
    private static let deviceDateFormatter = ISO8601DateFormatter()
    private static let deviceRelativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    @State private var deviceToRevoke: DeviceTrust?
    @State private var expandedUpdateDetails: Set<AgentProvider> = []
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    /// Local draft values for CLI path fields; committed on end-editing so
    /// mid-edit keystrokes don't fire saveCLIPath / replaceProviderAdapter.
    @State private var codexPathDraft: String = ""
    @State private var claudePathDraft: String = ""

    public init(vm: SettingsViewModel, onClose: (() -> Void)? = nil) {
        self.vm = vm
        self.onClose = onClose
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

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    remoteAccessSection
                    diffDefaultsSection
                    sidebarSection
                    insomniaSection
                    tokenSaverSection
                    advancedSection
                    customModelsSection
                    trustedDevicesSection
                    diagnosticsSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 620, height: 560)
        .background(DS.Palette.bg)
        .task { notificationStatus = await SystemNotifier.shared.authorizationStatus() }
        .onAppear {
            codexPathDraft = vm.codexPath
            claudePathDraft = vm.claudePath
        }
        .onChange(of: vm.codexPath) { codexPathDraft = $0 }
        .onChange(of: vm.claudePath) { claudePathDraft = $0 }
    }

    private func settingRow<Content: View>(_ label: String, @ViewBuilder _ control: () -> Content) -> some View {
        HStack {
            Text(label).font(DS.Font.body).foregroundColor(DS.Palette.text)
            Spacer()
            control()
        }
        .padding(.vertical, DS.Space.sm)
    }

    private var remoteAccessSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeader("Remote Access")
            settingRow("Allow iPhone or iPad on your network") {
                Toggle("", isOn: Binding(
                    get: { vm.remoteAccessEnabled },
                    set: { vm.setRemoteAccess($0) }
                ))
                .labelsHidden()
                .accessibilityIdentifier("settings.remoteAccess.toggle")
            }
            Text("Off binds the host API to 127.0.0.1. On binds to 0.0.0.0:18217 and publishes Bonjour; paired-device tokens are still required.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
        }
        .dsPanel(padding: DS.Space.lg)
    }

    private var diffDefaultsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeader("Diff Defaults")
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
            DSSectionHeader("Sidebar")
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

    private var insomniaSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeader("Insomnia")
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
            DSSectionHeader("Token Saver")
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
        }
        .dsPanel(padding: DS.Space.lg)
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeader("Advanced")
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

    private var customModelsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeader("Custom Models")
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
            DSSectionHeader("Trusted Devices")
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
            } else {
                Button("Generate pairing code") { vm.createPairingCode() }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("settings.pairing.generate")
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

    /// Device row caption: short id, paired date, and a relative "last seen"
    /// when the device has connected since pairing so users can recognize an
    /// active device instead of only an 8-char hash.
    private func deviceSubtitle(_ d: DeviceTrust) -> String {
        var parts = [d.id.prefix(8) + " \u{00B7} " + Self.deviceDateFormatter.string(from: d.createdAt)]
        if let lastSeen = d.lastSeenAt {
            parts.append("seen " + Self.deviceRelativeFormatter.localizedString(for: lastSeen, relativeTo: Date()))
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeader("Diagnostics")
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
                        Task { notificationStatus = await SystemNotifier.shared.authorizationStatus() }
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
                DSPill(vm.privateAccountStatus, tone: .warning)
            }

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Email")
                    .font(DS.Font.captionStrong)
                    .foregroundColor(DS.Palette.textSecondary)
                TextField("you@example.com", text: Binding(get: { vm.privateAccountEmail }, set: { vm.privateAccountEmail = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Font.body)
                    .focused($focusedField, equals: .email)
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

    public init(context: AppContext, updater: AppUpdateChecking? = nil) {
        self.viewModel = SettingsViewModel(context: context, updater: updater)
        let host = NSHostingController(rootView: SettingsView(vm: viewModel))
        let win = NSWindow(contentViewController: host)
        win.title = "RemoteCode Settings"
        win.styleMask = [.titled, .closable, .resizable]
        // Match the SwiftUI content frame so the window doesn't open smaller
        // than its content and jump-resize; guard against shrinking below it.
        win.setContentSize(NSSize(width: 620, height: 560))
        win.contentMinSize = NSSize(width: 620, height: 480)
        win.center()
        self.window = win
        host.rootView = SettingsView(vm: viewModel) { [weak win] in
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
