import AppKit
import SwiftUI
import AgentRuntime
import CoreModel
import DesignSystemKit
import Surfaces

/// Accounts & Auto lives inline in Settings: a summary line over the full
/// accounts and Auto routing editor. The Agent App and Bot Studio point here
/// instead of carrying their own entry.
struct DistillAccountsSettingsSection: View {
    @ObservedObject var controller: DistillAccountsController
    let loadModels: () async -> [AgentModelDescriptor]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text(Self.summary(statuses: controller.statuses, routing: controller.routing, loaded: controller.hasLoadedState))
                .font(DS.Font.body)
                .foregroundColor(DS.Palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("settings.accounts.summary")
            DistillAccountsPanelHost(controller: controller, loadModels: loadModels, embedded: true)
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
    var embedded = false

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
            saveRouting: controller.saveRouting,
            embedded: embedded
        )
        .onAppear { if !embedded || !controller.hasLoadedState { controller.refresh() } }
        .task(id: controller.statuses.filter(\.connected).map(\.id) + [controller.routing.enabled ? "auto-enabled" : "auto-disabled"]) {
            _ = await loadModels()
        }
    }
}
