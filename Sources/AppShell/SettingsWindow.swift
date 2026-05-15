import Foundation
import AppKit
import SwiftUI
import CoreModel
import Persistence

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
        }.padding(16).frame(width: 540, height: 380)
    }

    private var general: some View {
        Form {
            Picker("Theme", selection: $vm.theme) {
                Text("Dark").tag("dark")
                Text("Light").tag("light")
            }.disabled(true) // V1 ships dark only
            Toggle("First-run completed", isOn: $vm.firstRunCompleted).disabled(true)
            Text("State directory: \(vm.context.bootstrapReport.path)")
                .font(.caption.monospaced()).foregroundColor(.secondary)
        }
    }

    private var providers: some View {
        Form {
            Picker("Default provider", selection: $vm.defaultProvider) {
                Text("Codex").tag(AgentProvider.codex)
                Text("Claude").tag(AgentProvider.claude)
            }.onChange(of: vm.defaultProvider) { v in vm.setDefaultProvider(v) }
            Text("Codex CLI: \( codexInstalled ? "found" : "not in PATH" )")
                .foregroundColor(codexInstalled ? .green : .red).font(.caption)
            Text("Claude CLI: \( claudeInstalled ? "found" : "not in PATH" )")
                .foregroundColor(claudeInstalled ? .green : .red).font(.caption)
        }
    }

    private var remote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enable remote access (binds 0.0.0.0:18217)", isOn: $vm.remoteAccessEnabled)
                .onChange(of: vm.remoteAccessEnabled) { v in vm.setRemoteAccess(v) }
            Text("Pairing required when remote access is on. Tokens authorize every non-loopback /v1/* request.")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Button("Generate pairing code") { vm.createPairingCode() }
                if let c = vm.newPairingCode {
                    Text(c).font(.title.monospaced()).foregroundColor(.green).textSelection(.enabled)
                }
            }
            Divider()
            Text("Paired devices:").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(vm.devices, id: \.id) { d in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(d.displayName).bold()
                                Text(d.id.prefix(8) + " · " + ISO8601DateFormatter().string(from: d.createdAt))
                                    .font(.caption.monospaced()).foregroundColor(.secondary)
                            }
                            Spacer()
                            if d.revokedAt != nil {
                                Text("revoked").foregroundColor(.red).font(.caption)
                            } else {
                                Button("Revoke") { vm.revoke(d.id) }.controlSize(.small)
                            }
                        }
                    }
                }
            }.frame(maxHeight: 140)
        }.padding(.top, 4)
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
        win.title = "RemoteCode 2 Settings"
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
