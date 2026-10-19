import AppKit
import SwiftUI
import AgentRuntime
import CoreModel
import DesignSystemKit
import Surfaces

/// Accounts & Auto lives in Settings: a summary of the Distill accounts and
/// the Auto profile, with the full panel one click away. The Agent App and
/// Bot Studio point here instead of carrying their own entry.
struct DistillAccountsSettingsSection: View {
    @ObservedObject var controller: DistillAccountsController
    let loadModels: () async -> [AgentModelDescriptor]
    @State private var showingPanel = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG("Accounts & Auto")
            Text("Connect the accounts Distill can use and choose how Auto picks between them. Agent threads and Bots that choose the Auto model use this profile.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.sm) {
                Text(Self.summary(statuses: controller.statuses, routing: controller.routing, loaded: controller.hasLoadedState))
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("settings.accounts.summary")
                Button("Manage…") { showingPanel = true }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("settings.accounts.manage")
            }
        }
        .dsPanel(padding: DS.Space.lg)
        // Cached statuses paint first; the CLI re-read runs after the section
        // is on screen and only until the saved state has loaded once.
        .task { if !controller.hasLoadedState { controller.refresh() } }
        .sheet(isPresented: $showingPanel) {
            DistillAccountsPanelHost(controller: controller, loadModels: loadModels)
                .padding(DS.Space.xxl)
                .frame(minWidth: 360, idealWidth: 820, maxWidth: 820, minHeight: 480, idealHeight: 640)
                .background(DS.Palette.bg)
                .foregroundStyle(DS.Palette.text)
        }
    }

    static func summary(statuses: [DistillAccountStatus], routing: DistillAutoRouting, loaded: Bool) -> String {
        let connected = statuses.filter(\.connected).count
        let accounts: String
        if statuses.isEmpty {
            accounts = loaded ? "No accounts yet" : "Loading accounts…"
        } else {
            accounts = "\(connected) of \(statuses.count) account\(statuses.count == 1 ? "" : "s") connected"
        }
        guard loaded else { return accounts }
        return accounts + " · Auto " + (routing.enabled ? "on (\(routing.options.count) option\(routing.options.count == 1 ? "" : "s"))" : "off")
    }
}

struct DistillAccountsPanelHost: View {
    @ObservedObject var controller: DistillAccountsController
    let loadModels: () async -> [AgentModelDescriptor]

    var body: some View {
        DistillAccountsPanel(
            presentation: DistillAccountsPanelPresentation(
                statuses: controller.statuses,
                busyProvider: controller.busyProvider,
                signInURL: controller.signInURL,
                lastError: controller.lastError,
                installState: {
                    switch controller.installState {
                    case .unknown: return .unknown
                    case .installed: return .installed
                    case .installing: return .installing
                    case .failed(let message): return .failed(message)
                    }
                }(),
                busyAccountID: controller.busyAccountID,
                isBusy: controller.isBusy,
                routing: controller.routing,
                models: controller.models,
                routingLoaded: controller.hasLoadedState,
                isRefreshing: controller.isRefreshing
            ),
            cancel: controller.cancel,
            openAgain: { NSWorkspace.shared.open($0) },
            dismissError: controller.dismissError,
            retryInstall: controller.retryDistillInstall,
            refreshAccounts: controller.refresh,
            add: { controller.add(provider: $0, label: $1) },
            rename: { controller.rename(accountID: $0, label: $1) },
            connectAccount: { controller.login(accountID: $0) },
            disconnectAccount: { controller.logout(accountID: $0) },
            remove: { controller.remove(accountID: $0) },
            refreshQuota: { controller.refreshUsage(accountID: $0) },
            saveRouting: controller.saveRouting
        )
        .onAppear { controller.refresh() }
        .task(id: controller.statuses.filter(\.connected).map(\.id) + [controller.routing.enabled ? "auto-enabled" : "auto-disabled"]) {
            _ = await loadModels()
        }
    }
}
