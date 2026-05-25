import Foundation
import AppKit
import SwiftUI
import CoreModel
import Persistence
import AgentRuntime
import SocketServer
import DesignSystemKit

extension Notification.Name {
    static let rc2RemoteAccessSettingChanged = Notification.Name("rc2RemoteAccessSettingChanged")
    static let rc2PrivateAccountChanged = Notification.Name("rc2PrivateAccountChanged")
}

@MainActor
public final class SettingsViewModel: ObservableObject {
    public let settingsRepo: SettingsRepository
    public let trustRepo: DeviceTrustRepository
    public let settingsStore: SettingsStore
    public let context: AppContext
    private let privateAccountAPI: PrivateAccountAPI
    private let privateAccountStore: PrivateAccountSessionStore
    private let openURL: @MainActor (URL) -> Void

    @Published public var remoteAccessEnabled: Bool = false
    @Published public var appSettings: AppSettings = AppSettings()
    @Published public var codexPath: String = ""
    @Published public var claudePath: String = ""
    @Published public var devices: [DeviceTrust] = []
    @Published public var newPairingCode: String?
    @Published public var updatingProviders: Set<AgentProvider> = []
    @Published public var providerUpdateMessages: [AgentProvider: String] = [:]
    @Published public var privateAccountEmail: String = ""
    @Published public var privateAccountPassword: String = ""
    @Published public var privateAccountUser: PrivateAccountUser?
    @Published public var privateAccountStatus: String = "Optional"
    @Published public var privateAccountBusy: Bool = false
    @Published public var privateBillingPortalURL: URL?

    public init(
        context: AppContext,
        privateAccountAPI: PrivateAccountAPI = URLSessionPrivateAccountAPI(),
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.context = context
        self.privateAccountAPI = privateAccountAPI
        self.openURL = openURL
        self.settingsRepo = context.settingsRepo
        self.trustRepo = DeviceTrustRepository(db: context.db)
        self.settingsStore = SettingsStore(db: context.db)
        self.privateAccountStore = PrivateAccountSessionStore(repo: context.settingsRepo)
        reload()
    }

    public func reload() {
        remoteAccessEnabled = (try? settingsRepo.get("remote_access_enabled")) == "1"
        appSettings = settingsStore.load()
        codexPath = cliPath(key: "cli.codex.path", fallback: "codex")
        claudePath = cliPath(key: "cli.claude.path", fallback: "claude")
        devices = (try? trustRepo.list()) ?? []
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
        saveCLIPath(key: "cli.codex.path", provider: .codex, path: path)
    }

    public func setClaudePath(_ path: String) {
        claudePath = path
        saveCLIPath(key: "cli.claude.path", provider: .claude, path: path)
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
            privateAccountStatus = "Sign in failed"
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

    public var codexAvailable: Bool { ProcessLocator.resolve(codexPath).map { !$0.isEmpty } ?? false }
    public var claudeAvailable: Bool { ProcessLocator.resolve(claudePath).map { !$0.isEmpty } ?? false }

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
            }

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    remoteAccessSection
                    diffDefaultsSection
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
            }
            settingRow("Ignore whitespace") {
                Toggle("", isOn: Binding(
                    get: { vm.appSettings.diffIgnoreWhitespace },
                    set: { vm.setDiffIgnoreWhitespace($0) }
                ))
                .labelsHidden()
            }
            Text("These defaults seed new Git diff surfaces and match the toolbar toggles in the diff panel.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
        }
        .dsPanel(padding: DS.Space.lg)
    }

    private var trustedDevicesSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeader("Trusted Devices")
            HStack(spacing: DS.Space.lg) {
                Button("Generate pairing code") { vm.createPairingCode() }
                    .buttonStyle(DSSecondaryButtonStyle())
                if let c = vm.newPairingCode {
                    Text(c).font(DS.Font.title2.monospaced())
                        .foregroundColor(DS.Palette.success).textSelection(.enabled)
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
                                Text(d.id.prefix(8) + " · " + ISO8601DateFormatter().string(from: d.createdAt))
                                    .font(DS.Font.monoSmall).foregroundColor(DS.Palette.textTertiary)
                            }
                            Spacer()
                            if d.revokedAt != nil {
                                DSPill("revoked", tone: .danger)
                            } else {
                                Button("Revoke") { vm.revoke(d.id) }
                                    .buttonStyle(DSSecondaryButtonStyle())
                            }
                        }
                        .dsPanel(padding: DS.Space.md)
                    }
                }
            }.frame(maxHeight: 150)
        }
        .dsPanel(padding: DS.Space.lg)
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
            Text("State directory")
                .font(DS.Font.caption2.weight(.semibold)).foregroundColor(DS.Palette.textTertiary)
            Text(vm.context.bootstrapReport.path)
                .font(DS.Font.monoSmall).foregroundColor(DS.Palette.textSecondary)
                .textSelection(.enabled)
        }
        .dsPanel(padding: DS.Space.lg)
    }

    private func cliPathRow(label: String, value: Binding<String>, available: Bool, provider: AgentProvider) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.md) {
                Text(label)
                    .font(DS.Font.caption2.weight(.semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                DSPill(available ? "found" : "missing", tone: available ? .success : .danger)
                Spacer()
                Button(vm.updatingProviders.contains(provider) ? "Updating..." : "Update") {
                    Task { await vm.updateProvider(provider) }
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .disabled(!available || vm.updatingProviders.contains(provider))
            }
            TextField("", text: value)
                .textFieldStyle(.roundedBorder)
                .font(DS.Font.monoSmall)
                .foregroundColor(DS.Palette.text)
            if let message = vm.providerUpdateMessages[provider] {
                Text(message)
                    .font(DS.Font.caption)
                    .foregroundColor(message.hasPrefix("Update failed") ? DS.Palette.danger : DS.Palette.textSecondary)
                    .textSelection(.enabled)
            }
        }
    }
}

public struct AccountView: View {
    @ObservedObject var vm: SettingsViewModel
    private let onClose: (() -> Void)?

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
            }

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Password")
                    .font(DS.Font.captionStrong)
                    .foregroundColor(DS.Palette.textSecondary)
                SecureField("Password", text: Binding(get: { vm.privateAccountPassword }, set: { vm.privateAccountPassword = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Font.body)
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
            .disabled(vm.privateAccountBusy)

            if vm.privateAccountStatus == "Sign in failed" {
                Text("Check the email and password, then try again.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.danger)
            }
        }
        .dsPanel(padding: DS.Space.xl, raised: true)
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

            HStack(spacing: DS.Space.md) {
                Button("Refresh") { Task { await vm.refreshPrivateAccount() } }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .disabled(vm.privateAccountBusy)
                Button("Billing") { Task { await vm.openPrivateBillingPortal() } }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .disabled(vm.privateAccountBusy)
                Spacer()
                Button("Disconnect") { Task { await vm.disconnectPrivateAccount() } }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .disabled(vm.privateAccountBusy)
            }
        }
        .dsPanel(padding: DS.Space.xl, raised: true)
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

    public init(context: AppContext) {
        self.viewModel = SettingsViewModel(context: context)
        let host = NSHostingController(rootView: SettingsView(vm: viewModel))
        let win = NSWindow(contentViewController: host)
        win.title = "RemoteCode Settings"
        win.styleMask = [.titled, .closable, .resizable]
        win.setContentSize(NSSize(width: 540, height: 380))
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
