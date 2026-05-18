import Foundation
import AppKit
import SwiftUI
import CoreModel
import Persistence
import DesignSystemKit

extension Notification.Name {
    static let rc2RemoteAccessSettingChanged = Notification.Name("rc2RemoteAccessSettingChanged")
}

@MainActor
public final class SettingsViewModel: ObservableObject {
    public let settingsRepo: SettingsRepository
    public let trustRepo: DeviceTrustRepository
    public let context: AppContext

    @Published public var theme: String = "dark"
    @Published public var remoteAccessEnabled: Bool = false
    @Published public var defaultProvider: AgentProvider = .codex
    @Published public var firstRunCompleted: Bool = false
    @Published public var devices: [DeviceTrust] = []
    @Published public var newPairingCode: String?

    public init(context: AppContext) {
        self.context = context
        self.settingsRepo = context.settingsRepo
        self.trustRepo = DeviceTrustRepository(db: context.db)
        reload()
    }

    public func reload() {
        theme = (try? settingsRepo.get("theme")) ?? "dark"
        remoteAccessEnabled = (try? settingsRepo.get("remote_access_enabled")) == "1"
        let p = (try? settingsRepo.get("provider.default")) ?? "codex"
        defaultProvider = AgentProvider(rawValue: p) ?? .codex
        firstRunCompleted = (try? settingsRepo.get("first_run_completed")) == "1"
        devices = (try? trustRepo.list()) ?? []
    }

    public func setRemoteAccess(_ on: Bool) {
        remoteAccessEnabled = on
        try? settingsRepo.set("remote_access_enabled", on ? "1" : "0")
        NotificationCenter.default.post(name: .rc2RemoteAccessSettingChanged, object: nil)
    }

    public func setDefaultProvider(_ p: AgentProvider) {
        defaultProvider = p
        try? settingsRepo.set("provider.default", p.rawValue)
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
}

public struct SettingsView: View {
    @ObservedObject var vm: SettingsViewModel
    public init(vm: SettingsViewModel) { self.vm = vm }

    public var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            providers.tabItem { Label("Providers", systemImage: "sparkle") }
            remote.tabItem { Label("Remote Access", systemImage: "network") }
        }
        .padding(DS.Space.xl)
        .frame(width: 560, height: 400)
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

    private var general: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeader("Appearance")
            settingRow("Theme") {
                Picker("", selection: $vm.theme) {
                    Text("Dark").tag("dark"); Text("Light").tag("light")
                }.labelsHidden().frame(width: 140).disabled(true)
            }
            settingRow("First-run completed") {
                Image(systemName: vm.firstRunCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(vm.firstRunCompleted ? DS.Palette.success : DS.Palette.textTertiary)
            }
            Divider().overlay(DS.Palette.line)
            Text("State directory")
                .font(DS.Font.caption2.weight(.semibold)).foregroundColor(DS.Palette.textTertiary)
            Text(vm.context.bootstrapReport.path)
                .font(DS.Font.monoSmall).foregroundColor(DS.Palette.textSecondary)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private var providers: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeader("Default Provider")
            settingRow("Provider") {
                Picker("", selection: $vm.defaultProvider) {
                    Text("Codex").tag(AgentProvider.codex)
                    Text("Claude").tag(AgentProvider.claude)
                }.labelsHidden().frame(width: 140)
                .onChange(of: vm.defaultProvider) { v in vm.setDefaultProvider(v) }
            }
            Divider().overlay(DS.Palette.line)
            DSSectionHeader("CLI Availability")
            HStack(spacing: DS.Space.md) {
                DSPill("codex", tone: codexInstalled ? .success : .danger)
                Text(codexInstalled ? "Found in PATH" : "Not in PATH")
                    .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
            }
            HStack(spacing: DS.Space.md) {
                DSPill("claude", tone: claudeInstalled ? .success : .danger)
                Text(claudeInstalled ? "Found in PATH" : "Not in PATH")
                    .font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
            }
            Spacer()
        }
    }

    private var remote: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            DSSectionHeader("Direct Access")
            settingRow("Enable remote access (0.0.0.0:18217)") {
                Toggle("", isOn: $vm.remoteAccessEnabled)
                    .labelsHidden()
                    .onChange(of: vm.remoteAccessEnabled) { v in vm.setRemoteAccess(v) }
            }
            Text("Pairing required when remote access is on. Every non-loopback /v1/* request must carry a paired device token.")
                .font(DS.Font.caption).foregroundColor(DS.Palette.textTertiary)
            HStack(spacing: DS.Space.lg) {
                Button("Generate pairing code") { vm.createPairingCode() }
                    .buttonStyle(DSSecondaryButtonStyle())
                if let c = vm.newPairingCode {
                    Text(c).font(DS.Font.title2.monospaced())
                        .foregroundColor(DS.Palette.success).textSelection(.enabled)
                }
            }
            Divider().overlay(DS.Palette.line)
            DSSectionHeader("Paired Devices")
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
    }

    private var codexInstalled: Bool {
        FileManager.default.fileExists(atPath: "/opt/homebrew/bin/codex") ||
        FileManager.default.fileExists(atPath: "/usr/local/bin/codex")
    }
    private var claudeInstalled: Bool {
        FileManager.default.fileExists(atPath: "/opt/homebrew/bin/claude") ||
        FileManager.default.fileExists(atPath: "/usr/local/bin/claude")
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
    }

    public func show() {
        viewModel.reload()
        window.makeKeyAndOrderFront(nil)
    }
}
