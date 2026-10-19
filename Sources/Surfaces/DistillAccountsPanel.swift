import SwiftUI
import AgentRuntime
import CoreModel
import DesignSystemKit

public enum DistillAccountsInstallState: Equatable {
    case unknown, installed, installing, failed(String)
}

public enum DistillRoutingValidation {
    public static func models(for account: DistillAccountStatus?, catalog: [AgentModelDescriptor]) -> [AgentModelDescriptor] {
        guard let account else { return [] }
        return catalog.filter { $0.id != "auto" && $0.accountProvider == account.provider.rawValue }
    }

    public static func error(_ draft: DistillAutoRouting, saved: DistillAutoRouting,
                             accounts: [DistillAccountStatus], models: [AgentModelDescriptor]) -> String? {
        // Disabling an unchanged saved profile must work even when its catalog is no longer available.
        if !draft.enabled, draft.strategy == saved.strategy, draft.options == saved.options { return nil }
        if draft.enabled && draft.options.isEmpty { return "Add an option before enabling Auto." }
        var ids = Set<String>()
        for option in draft.options {
            guard !option.id.isEmpty, ids.insert(option.id).inserted else { return "Each Auto option needs a unique identity." }
            guard let account = accounts.first(where: { $0.id == option.accountID }) else { return "Choose an existing account for every option." }
            let eligible = Self.models(for: account, catalog: models)
            guard eligible.contains(where: { $0.id == option.mainModel }),
                  option.workerModel == nil || eligible.contains(where: { $0.id == option.workerModel }) else {
                return "Choose available Main and Worker models from the selected account’s provider."
            }
        }
        return nil
    }
}

public struct DistillAccountsPanelPresentation: Equatable {
    public let installState: DistillAccountsInstallState
    public let statuses: [DistillAccountStatus]
    public let busyProvider: DistillAccountProvider?
    public let signInURL: URL?
    public let lastError: String?
    public let busyAccountID: String?
    public let isBusy: Bool
    public let routing: DistillAutoRouting
    public let models: [AgentModelDescriptor]
    public let routingLoaded: Bool
    public let isRefreshing: Bool

    public init(statuses: [DistillAccountStatus], busyProvider: DistillAccountProvider?, signInURL: URL?, lastError: String?, installState: DistillAccountsInstallState = .unknown,
                busyAccountID: String? = nil, isBusy: Bool = false, routing: DistillAutoRouting = .init(), models: [AgentModelDescriptor] = [], routingLoaded: Bool = true, isRefreshing: Bool = false) {
        self.installState = installState
        self.statuses = statuses
        self.busyProvider = busyProvider
        self.signInURL = signInURL
        self.lastError = lastError
        self.busyAccountID = busyAccountID
        self.isBusy = isBusy || busyProvider != nil
        self.routing = routing
        self.models = models
        self.routingLoaded = routingLoaded
        self.isRefreshing = isRefreshing
    }

    public static func quotaText(_ quota: DistillAccountQuota?) -> String {
        quotaPresentation(quota, connected: true, connectionError: nil).text
    }

    static func quotaPresentation(_ quota: DistillAccountQuota?, connected: Bool, connectionError: String?,
                                  now: Date = Date()) -> (text: String, remainingPercent: Double?) {
        guard let quota else { return ("Quota unknown", nil) }
        func date(_ timestamp: String?) -> Date? {
            guard let timestamp else { return nil }
            // CLI/chrono RFC3339 includes fractional seconds; older snapshots may omit them.
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return parser.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
        }
        let remaining = quota.remainingPercent.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        let value = remaining.map { "\(Int($0.rounded()))% remaining" } ?? "Remaining quota unknown"
        let fetched = date(quota.fetchedAt)
        let age = fetched.map { now.timeIntervalSince($0) }
        let fresh = age.map { (0...300).contains($0) } ?? false
        let current = quota.status == "available" && fresh && connected && connectionError == nil
        let updated = fetched.map { "Updated \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Update time unknown"
        let future = (age ?? 0) < 0
        let freshness = fetched == nil || future ? "Quota freshness unknown" : (current ? "Saved quota" : "Stale")
        switch quota.status {
        case "available", "stale":
            return ("\(freshness) · \(value) · \(updated)\(future ? " (future timestamp)" : "")", current ? remaining : nil)
        case "loading": return ("Refreshing quota…", nil)
        case "unsupported": return ("Quota unavailable for this provider", nil)
        default:
            if quota.fetchedAt != nil {
                return ("\(freshness) · \(value) · \(updated)\(future ? " (future timestamp)" : "") · Refresh unavailable", nil)
            }
            let checked = date(quota.checkedAt)?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown"
            return ("Quota unavailable · Checked \(checked)", nil)
        }
    }
}

public struct DistillAccountsPanel: View {
    public let presentation: DistillAccountsPanelPresentation
    public let cancel: () -> Void
    public let openAgain: (URL) -> Void
    public let dismissError: () -> Void
    public let retryInstall: () -> Void
    public let refreshAccounts: () -> Void
    public let add: (DistillAccountProvider, String) -> Void
    public let rename: (String, String) -> Void
    public let connectAccount: (String) -> Void
    public let disconnectAccount: (String) -> Void
    public let remove: (String) -> Void
    public let refreshQuota: (String) -> Void
    public let saveRouting: (DistillAutoRouting) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var newProvider = DistillAccountProvider.chatgpt
    @State private var newLabel = ""
    @State private var showingAddAccount = false
    @State private var showingRouting = false
    @State private var renameAccount: DistillAccountStatus?
    @State private var renamedLabel = ""
    @State private var confirmation: DistillAccountStatus?
    @State private var removing = false
    @State private var draft: DistillAutoRouting?
    @State private var confirmingDiscard = false

    public init(presentation: DistillAccountsPanelPresentation,
                cancel: @escaping () -> Void, openAgain: @escaping (URL) -> Void, dismissError: @escaping () -> Void,
                retryInstall: @escaping () -> Void, refreshAccounts: @escaping () -> Void,
                add: @escaping (DistillAccountProvider, String) -> Void,
                rename: @escaping (String, String) -> Void, connectAccount: @escaping (String) -> Void,
                disconnectAccount: @escaping (String) -> Void, remove: @escaping (String) -> Void,
                refreshQuota: @escaping (String) -> Void, saveRouting: @escaping (DistillAutoRouting) -> Void) {
        self.presentation = presentation
        self.cancel = cancel
        self.openAgain = openAgain
        self.dismissError = dismissError
        self.retryInstall = retryInstall
        self.refreshAccounts = refreshAccounts
        self.add = add
        self.rename = rename
        self.connectAccount = connectAccount
        self.disconnectAccount = disconnectAccount
        self.remove = remove
        self.refreshQuota = refreshQuota
        self.saveRouting = saveRouting
    }

    private var currentDraft: DistillAutoRouting { draft ?? presentation.routing }
    private var hasChanges: Bool { currentDraft != presentation.routing }
    private var validationError: String? {
        DistillRoutingValidation.error(currentDraft, saved: presentation.routing, accounts: presentation.statuses, models: presentation.models)
    }
    private var unavailable: Bool {
        if case .failed = presentation.installState { return true }
        return presentation.isBusy || presentation.installState == .installing || !presentation.routingLoaded
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack {
                Text("Accounts & Auto").font(DS.Font.title2)
                Spacer()
                Button("Done") {
                    if hasChanges { confirmingDiscard = true } else { dismiss() }
                }.keyboardShortcut(.cancelAction).frame(minHeight: 44).disabled(presentation.isBusy)
            }
            .confirmationDialog("Discard unsaved profile changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { draft = nil; dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            GeometryReader { proxy in
                if proxy.size.width >= 720 {
                    HStack(alignment: .top, spacing: DS.Space.xl) {
                        ScrollView { accountsCard }
                        ScrollView { routingCard }
                    }
                } else {
                    VStack(spacing: DS.Space.lg) {
                        Picker("Settings section", selection: $showingRouting) {
                            Text("Accounts").tag(false)
                            Text("Auto routing").tag(true)
                        }.pickerStyle(.segmented).labelsHidden()
                        ScrollView {
                            if showingRouting { routingCard } else { accountsCard }
                        }
                    }
                }
            }
            if let error = presentation.lastError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(DS.Palette.warning)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    VStack {
                        Button("Refresh accounts", action: refreshAccounts).frame(minHeight: 44)
                        Button("Dismiss", action: dismissError).frame(minWidth: 44, minHeight: 44)
                    }
                }.padding(DS.Space.sm)
            }
            routingFooter
        }
        .font(DS.Font.body)
        .foregroundStyle(DS.Palette.text)
        .interactiveDismissDisabled(hasChanges || presentation.isBusy)
        .sheet(isPresented: $showingAddAccount) {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                Text("Add account").font(DS.Font.title3)
                Picker("Provider", selection: $newProvider) {
                    ForEach(DistillAccountProvider.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.frame(minHeight: 44)
                TextField("Account label", text: $newLabel).frame(minHeight: 44)
                    .accessibilityLabel("Account label")
                Text("Give this account a name, then connect to sign in.")
                    .foregroundStyle(DS.Palette.textSecondary)
                HStack {
                    Button("Cancel") { showingAddAccount = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Add account") {
                        add(newProvider, newLabel.trimmingCharacters(in: .whitespacesAndNewlines))
                        showingAddAccount = false
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(unavailable || newLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.frame(minHeight: 44)
            }.padding(DS.Space.xxl).frame(minWidth: 300, idealWidth: 360, maxWidth: 360)
                .font(DS.Font.body).foregroundStyle(DS.Palette.text)
                .background(DS.Palette.bg)
        }
        .sheet(isPresented: Binding(get: { renameAccount != nil }, set: { if !$0 { renameAccount = nil } })) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Text("Rename \(renameAccount?.provider.displayName ?? "account")").font(DS.Font.body)
                TextField("Account label", text: $renamedLabel).frame(minHeight: 44)
                HStack {
                    Button("Cancel") { renameAccount = nil }.keyboardShortcut(.cancelAction).frame(minHeight: 44)
                    Button("Save") {
                        if let account = renameAccount { rename(account.id, renamedLabel.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        renameAccount = nil
                    }.keyboardShortcut(.defaultAction).frame(minHeight: 44).disabled(renamedLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(DS.Space.md).frame(minWidth: 300)
                .font(DS.Font.body).foregroundStyle(DS.Palette.text)
                .background(DS.Palette.bg)
        }
        .confirmationDialog("\(removing ? "Remove" : "Disconnect") \(confirmation?.label ?? "account")?",
                            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            Button(removing ? "Remove account" : "Disconnect account", role: .destructive) {
                if let account = confirmation { if removing { remove(account.id) } else { disconnectAccount(account.id) } }
                confirmation = nil
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text("\(confirmation?.provider.displayName ?? "") · \(confirmation?.label ?? "")\n\(confirmation?.email ?? confirmation?.id ?? "")\nOnly this account is affected. Other accounts stay connected.")
        }
        .onChange(of: presentation.routing) { saved in if draft == saved { draft = nil } }
    }

    private var accountsCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack {
                Text("Accounts").font(DS.Font.title3)
                Spacer()
                Button("Refresh", action: refreshAccounts).frame(minHeight: 44).disabled(presentation.isBusy || presentation.isRefreshing)
            }
            Text("Connect accounts to make their models available to Main, Worker and Auto.").foregroundStyle(DS.Palette.textSecondary)
            installNotice
            if presentation.isRefreshing { HStack { ProgressView().controlSize(.small); Text("Refreshing accounts…") } }
            Button { newLabel = ""; showingAddAccount = true } label: {
                Label("Add account", systemImage: "plus")
            }.frame(minHeight: 44).disabled(unavailable)
            if presentation.statuses.isEmpty { Text("Add an account, then choose Connect to sign in.").foregroundStyle(DS.Palette.textSecondary) }
            ForEach(presentation.statuses, id: \.id) { account in
                Divider()
                accountRow(account)
            }
        }.padding(DS.Space.xl).frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.surfaceRaised).clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
            .accessibilityIdentifier("agent.accounts.card")
    }

    @ViewBuilder private var installNotice: some View {
        switch presentation.installState {
        case .installing:
            HStack { ProgressView().controlSize(.small); Text("Installing Distill…") }.accessibilityIdentifier("agent.accounts.install.progress")
        case .failed(let message):
            Text(message).foregroundStyle(DS.Palette.warning).textSelection(.enabled).accessibilityIdentifier("agent.accounts.install.failed")
            Button("Retry", action: retryInstall).frame(minHeight: 44).accessibilityIdentifier("agent.accounts.install.retry")
        case .unknown, .installed: EmptyView()
        }
    }

    private func accountRow(_ account: DistillAccountStatus) -> some View {
        let quota = DistillAccountsPanelPresentation.quotaPresentation(
            account.quota, connected: account.connected, connectionError: account.connectionError
        )
        return VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("\(account.provider.displayName) · \(account.label)").fontWeight(.semibold).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Label(account.connected ? (account.email.map { "Connected · \($0)" } ?? "Connected") : "Not connected", systemImage: account.connected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(account.connected ? DS.Palette.success : DS.Palette.textSecondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let error = account.connectionError { Text(error).foregroundStyle(DS.Palette.warning).textSelection(.enabled) }
            Text(quota.text).font(DS.Font.bodyDense)
                .foregroundStyle(DS.Palette.textSecondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let remaining = quota.remainingPercent {
                ProgressView(value: remaining, total: 100).tint(DS.Palette.accent)
                    .accessibilityLabel("Saved remaining quota")
                    .accessibilityValue("\(Int(remaining.rounded())) percent")
            }
            if presentation.busyAccountID == account.id {
                HStack {
                    ProgressView().controlSize(.small).accessibilityLabel("Account operation in progress")
                    if let url = presentation.signInURL { Button("Open again") { openAgain(url) }.frame(minHeight: 44) }
                    Button("Cancel", action: cancel).frame(minHeight: 44)
                }
            } else {
                HStack {
                    if !account.connected {
                        Button("Connect") { connectAccount(account.id) }.frame(minHeight: 44)
                    }
                    Spacer(minLength: 0)
                    Menu("Account actions") {
                        Button("Refresh quota") { refreshQuota(account.id) }.disabled(!account.connected)
                        Button("Rename") { renamedLabel = account.label; renameAccount = account }
                        Divider()
                        if account.connected {
                            Button("Disconnect…", role: .destructive) { removing = false; confirmation = account }
                        }
                        Button("Remove…", role: .destructive) { removing = true; confirmation = account }
                    }.frame(minHeight: 44)
                        .accessibilityLabel("Account actions for \(account.provider.displayName) · \(account.label)")
                        .help("Actions for \(account.provider.displayName) · \(account.label)")
                }.disabled(unavailable)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("agent.accounts.\(account.id)")
    }

    private var routingCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text("Auto routing").font(DS.Font.title3)
            Text("Choose Auto in Main to use this profile. Worker uses this route’s setting.")
                .foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Enable profile", isOn: Binding(get: { currentDraft.enabled }, set: { var value = currentDraft; value.enabled = $0; draft = value })).frame(minHeight: 44)
            Picker("Strategy", selection: Binding(get: { currentDraft.strategy }, set: { var value = currentDraft; value.strategy = $0; draft = value })) {
                Text("First available in order").tag(DistillAutoStrategy.orderedFirst)
                Text("Highest remaining quota").tag(DistillAutoStrategy.highestRemaining)
            }.frame(minHeight: 44)
            Text(currentDraft.strategy == .orderedFirst
                 ? "Try connected accounts in the order below."
                 : "Prefer the connected account with the highest known remaining quota.")
                .font(DS.Font.bodyDense).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if currentDraft.options.isEmpty {
                Text("Add an option to choose an account and its models.").foregroundStyle(DS.Palette.textSecondary)
            }
            ForEach(currentDraft.options, id: \.id) { option in routeRow(option) }
            Button("Add option") {
                let account = presentation.statuses.first
                let model = DistillRoutingValidation.models(for: account, catalog: presentation.models).first
                var value = currentDraft
                value.options.append(.init(id: UUID().uuidString.lowercased(), accountID: account?.id ?? "", mainModel: model?.id ?? ""))
                draft = value
            }.frame(minHeight: 44)
        }.disabled(unavailable).padding(DS.Space.xl).frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.surfaceRaised).clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
            .accessibilityIdentifier("agent.accounts.routing")
    }

    private var routingFooter: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Divider()
            if let error = validationError {
                Text(error).foregroundStyle(DS.Palette.warning).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.lg) {
                Text(!presentation.routingLoaded ? "Loading saved profile…" :
                     (hasChanges ? "Unsaved changes" : "Saved profile · \(presentation.routing.enabled ? "Enabled" : "Disabled")"))
                    .foregroundStyle(hasChanges ? DS.Palette.warning : DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if presentation.isBusy, presentation.busyAccountID == nil {
                    ProgressView().controlSize(.small).accessibilityLabel("Saving accounts or routing")
                }
                if hasChanges {
                    Button("Cancel") { draft = nil }.frame(minHeight: 44).disabled(unavailable)
                    Button("Save profile") { saveRouting(currentDraft) }
                        .buttonStyle(.borderedProminent).frame(minHeight: 44)
                        .disabled(unavailable || validationError != nil)
                }
            }
        }.accessibilityIdentifier("agent.accounts.routing.footer")
    }

    private func editOption(_ id: String, _ edit: (inout DistillAutoOption) -> Void) {
        var value = currentDraft
        guard let index = value.options.firstIndex(where: { $0.id == id }) else { return }
        edit(&value.options[index]); draft = value
    }
    private func moveOption(_ id: String, offset: Int) {
        var value = currentDraft
        guard let index = value.options.firstIndex(where: { $0.id == id }), value.options.indices.contains(index + offset) else { return }
        value.options.swapAt(index, index + offset); draft = value
    }

    private func routeRow(_ option: DistillAutoOption) -> some View {
        let account = presentation.statuses.first { $0.id == option.accountID }
        let models = DistillRoutingValidation.models(for: account, catalog: presentation.models)
        let index = currentDraft.options.firstIndex { $0.id == option.id } ?? 0
        return VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack {
                Text("Option \(index + 1)").font(DS.Font.bodyStrong)
                Spacer()
                Menu("Option actions") {
                    Button("Move up") { moveOption(option.id, offset: -1) }.disabled(index == 0)
                    Button("Move down") { moveOption(option.id, offset: 1) }.disabled(index == currentDraft.options.count - 1)
                    Button("Remove option", role: .destructive) { var value = currentDraft; value.options.removeAll { $0.id == option.id }; draft = value }
                }.frame(minHeight: 44)
                    .accessibilityLabel("Actions for option \(index + 1)")
            }
            Text("Account").font(DS.Font.bodyStrong)
            Picker("Account", selection: Binding(get: { option.accountID }, set: { id in
                editOption(option.id) {
                    $0.accountID = id
                    $0.mainModel = DistillRoutingValidation.models(for: presentation.statuses.first { $0.id == id }, catalog: presentation.models).first?.id ?? ""
                    $0.workerModel = nil
                }
            })) {
                if account == nil { Text("Choose account").tag(option.accountID) }
                ForEach(presentation.statuses, id: \.id) { Text("\($0.provider.displayName) · \($0.label)").tag($0.id) }
            }.labelsHidden().frame(maxWidth: .infinity, minHeight: 44).help(account.map { "\($0.provider.displayName) · \($0.label)" } ?? "Choose account")
            Text("Main").font(DS.Font.bodyStrong)
            Picker("Main", selection: Binding(get: { option.mainModel }, set: { model in editOption(option.id) { $0.mainModel = model } })) {
                if !models.contains(where: { $0.id == option.mainModel }) { Text(option.mainModel.isEmpty ? "Choose model" : "Unavailable: \(option.mainModel)").tag(option.mainModel) }
                ForEach(models, id: \.id) { Text($0.label).tag($0.id) }
            }.labelsHidden().frame(maxWidth: .infinity, minHeight: 44).help(option.mainModel)
            Text("Worker").font(DS.Font.bodyStrong).foregroundStyle(DS.Palette.textSecondary)
            Picker("Worker", selection: Binding(get: { option.workerModel ?? "" }, set: { model in editOption(option.id) { $0.workerModel = model.isEmpty ? nil : model } })) {
                Text("Same as Main").tag("")
                if let worker = option.workerModel, !models.contains(where: { $0.id == worker }) { Text("Unavailable: \(worker)").tag(worker) }
                ForEach(models, id: \.id) { Text($0.label).tag($0.id) }
            }.labelsHidden().frame(maxWidth: .infinity, minHeight: 44).help(option.workerModel ?? "Same as Main")
        }.padding(DS.Space.lg).background(DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
            .accessibilityElement(children: .contain).accessibilityIdentifier("agent.accounts.routing.\(option.id)")
    }
}
