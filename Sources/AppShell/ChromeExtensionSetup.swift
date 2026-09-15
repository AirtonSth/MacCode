import AppKit
import SwiftUI
import CoreModel
import AgentRuntime
import DesignSystemKit

@MainActor
final class ChromeExtensionSetup: ObservableObject {
    enum State: Equatable {
        case disconnected
        case preparing
        case awaitingChrome
        case connected
        case failed(String)

        var message: String {
            switch self {
            case .disconnected: return "Connect Chrome to use your existing logins in background tabs."
            case .preparing: return "Installing the Chrome extension…"
            case .awaitingChrome: return "Checking the Chrome connection…"
            case .connected: return "Chrome is connected. Your background tabs can use your existing logins."
            case .failed(let message): return message
            }
        }
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var checking = false
    @Published private(set) var extensionDirectory: URL?
    private var generation: UInt64 = 0
    private let prepare: @Sendable () async throws -> URL
    private let connected: @Sendable () async -> Bool
    private let openSetup: @MainActor (URL) async throws -> Void

    init(
        prepare: @escaping @Sendable () async throws -> URL = {
            try await Task.detached(priority: .userInitiated) {
                guard let helper = AgentSkillInstaller.resolveServiceBinary() else {
                    throw NSError(domain: "RemoteCode.ChromeSetup", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "The Chrome connection helper is missing. Reinstall RemoteCode and try again."])
                }
                return try ChromeProfileConnection.install(executable: helper.path)
            }.value
        },
        connected: @escaping @Sendable () async -> Bool = {
            await Task.detached(priority: .utility) {
                let reply = try? ChromeProfileConnection.request([
                    "operation": "browser_status", "session": UUID().uuidString,
                ])
                return reply?["ok"] as? Bool == true && reply?["connected"] as? Bool == true
            }.value
        },
        openSetup: @escaping @MainActor (URL) async throws -> Void = { folder in
            try await ComputerUseHostQueue.shared.withExclusive(kind: .mutation) {
                let result = await ChromeProfileComputerUseBackend(prepare: { folder })
                    .invoke(name: "browser_setup", arguments: [:])
                if result.isError {
                    throw NSError(domain: "RemoteCode.ChromeSetup", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: result.content.first?.text ?? "Chrome setup failed."])
                }
            }
        }
    ) {
        self.prepare = prepare
        self.connected = connected
        self.openSetup = openSetup
    }

    func install() async {
        guard state != .preparing else { return }
        generation &+= 1
        let current = generation
        checking = false
        state = .preparing
        defer {
            if current == generation, state == .preparing {
                state = extensionDirectory == nil ? .disconnected : .awaitingChrome
            }
        }
        do {
            let folder = try await prepare()
            guard current == generation, !Task.isCancelled else { return }
            extensionDirectory = folder
            try await openSetup(folder)
            guard current == generation, !Task.isCancelled else { return }
            state = .awaitingChrome
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }

    func refresh() async {
        guard !checking, state != .preparing else { return }
        generation &+= 1
        let current = generation
        checking = true
        let isConnected = await connected()
        guard current == generation else { return }
        checking = false
        guard !Task.isCancelled else { return }
        if isConnected {
            state = .connected
        } else if state == .connected {
            state = extensionDirectory == nil ? .disconnected : .awaitingChrome
        }
    }

    func waitForConnection() async {
        while state == .awaitingChrome && !Task.isCancelled {
            await refresh()
            guard state == .awaitingChrome else { return }
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
        }
    }
}

struct ChromeExtensionSettingsSection: View {
    @StateObject private var setup = ChromeExtensionSetup()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG("Computer Use")
            Text("Use Chrome in background tabs without taking over your mouse or keyboard. Selecting an automated tab gives control back to you.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Set Up Chrome Extension") {
                    Task { await setup.install() }
                }
                .buttonStyle(.bordered)
                .disabled(setup.state == .preparing)
                .accessibilityIdentifier("settings.computerUse.chrome.setup")
                Button(setup.checking ? "Checking…" : "Check Connection") {
                    Task { await setup.refresh() }
                }
                .buttonStyle(.bordered)
                .disabled(setup.checking || setup.state == .preparing)
                .accessibilityIdentifier("settings.computerUse.chrome.check")
            }
            Text(setup.state.message)
                .font(DS.Font.caption)
                .foregroundColor(setup.state == .connected ? DS.Palette.success : DS.Palette.textSecondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("settings.computerUse.chrome.status")
            if let folder = setup.extensionDirectory, case .failed = setup.state {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    ForEach(Array(ChromeProfileConnection.installationSteps(for: folder).enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step)")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Copy Folder Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(folder.path, forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.computerUse.chrome.copyPath")
                }
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("settings.computerUse.chrome.instructions")
            }
            Text("Setup briefly controls Chrome to install the extension. You can also ask an agent to do this for you.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
        }
        .dsPanel(padding: DS.Space.lg)
        .accessibilityIdentifier("settings.section.computerUse")
        .task { await setup.refresh() }
        .task(id: setup.state == .awaitingChrome) {
            await setup.waitForConnection()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await setup.refresh() }
        }
    }
}
