import Foundation
import AppKit
import SwiftUI
import CoreModel
import Persistence
import AgentRuntime
import SocketServer
import DesignSystemKit
import os

extension Notification.Name {
    static let rc2RemoteAccessSettingChanged = Notification.Name("rc2RemoteAccessSettingChanged")
    static let rc2PrivateAccountChanged = Notification.Name("rc2PrivateAccountChanged")
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
    @Published public var codexAvailable: Bool = false
    @Published public var claudeAvailable: Bool = false
    @Published public var devices: [DeviceTrust] = []
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
                Task { @MainActor in self?.reload() }
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
        codexAvailable = resolveAvailable(codexPath)
        claudeAvailable = resolveAvailable(claudePath)
        providerUpdateMessages = [:]
        customModelsByProvider = Dictionary(uniqueKeysWithValues: AgentProvider.allCases.map { provider in
            (provider, customModelStore.list(provider: provider))
        })
        devices = (try? trustRepo.list()) ?? []
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

    public func setCodexPath(_ path: String) {
        codexPath = path
        codexAvailable = resolveAvailable(path)
        providerUpdateMessages[.codex] = nil
        saveCLIPath(key: "cli.codex.path", provider: .codex, path: path)
    }

    public func setClaudePath(_ path: String) {
        claudePath = path
        claudeAvailable = resolveAvailable(path)
        providerUpdateMessages[.claude] = nil
        saveCLIPath(key: "cli.claude.path", provider: .claude, path: path)
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

    @State private var deviceToRevoke: DeviceTrust?
    @State private var expandedUpdateDetails: Set<AgentProvider> = []

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
                                Text(d.id.prefix(8) + " · " + Self.deviceDateFormatter.string(from: d.createdAt))
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

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeader("Diagnostics")
            cliPathRow(label: "Codex path",
                       value: Binding(get: { vm.codexPath }, set: { vm.setCodexPath($0) }),
                       available: vm.codexAvailable,
                       provider: .codex)
            cliPathRow(label: "Claude path",
                       value: Binding(get: { vm.claudePath }, set: { vm.setClaudePath($0) }),
                       available: vm.claudeAvailable,
                       provider: .claude)
            if vm.showsAppUpdates {
                appUpdatesRow
            }
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

    private func cliPathRow(label: String, value: Binding<String>, available: Bool, provider: AgentProvider) -> some View {
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
                TextField("", text: value)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Font.monoSmall)
                    .foregroundColor(DS.Palette.text)
                    .accessibilityIdentifier("settings.cli.\(provider.rawValue).field")
                Button("Browse...") { browseForBinary(into: value) }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("settings.cli.\(provider.rawValue).browse")
            }
            if let message = vm.providerUpdateMessages[provider] {
                let isError = message.hasPrefix("Update failed")
                let expanded = expandedUpdateDetails.contains(provider)
                let isLong = message.count > 200 || message.contains("\n")
                VStack(alignment: .leading, spacing: 2) {
                    Text(expanded || !isLong ? message : String(message.prefix(200)) + "…")
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

    private func browseForBinary(into value: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the CLI executable"
        if panel.runModal() == .OK, let url = panel.url {
            value.wrappedValue = url.path
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
