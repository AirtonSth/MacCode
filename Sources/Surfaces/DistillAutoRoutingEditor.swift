import AgentRuntime
import CoreModel
import DesignSystemKit
import SwiftUI

/// Auto profile editor. Mounted by Settings > Accounts & Auto and the Auto model
/// guide, so both edit the same draft shape with the same validation.
public struct DistillAutoRoutingEditor: View {
    @Binding public var draft: DistillAutoRouting
    public let saved: DistillAutoRouting
    public let statuses: [DistillAccountStatus]
    public let models: [AgentModelDescriptor]
    public let disabled: Bool

    public init(draft: Binding<DistillAutoRouting>, saved: DistillAutoRouting, statuses: [DistillAccountStatus],
                models: [AgentModelDescriptor], disabled: Bool = false) {
        self._draft = draft
        self.saved = saved
        self.statuses = statuses
        self.models = models
        self.disabled = disabled
    }

    private var validationError: String? {
        DistillRoutingValidation.error(draft, saved: saved, accounts: statuses, models: models)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            explainer
            profileCard
            optionsSection
            if let error = validationError {
                AgentChoiceCallout(icon: "exclamationmark.triangle.fill", tint: DS.Palette.warning, text: error)
            }
        }
        .disabled(disabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Explainer

    private var explainer: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            AgentChoiceSectionHeader("How Auto works")
            HStack(alignment: .top, spacing: DS.Space.sm) {
                step(icon: "bubble.left", title: "You send a message", caption: "Choose Auto as Main.")
                flowChevron
                step(icon: "sparkles", title: "Auto picks an option",
                     caption: draft.strategy == .orderedFirst ? "First available in order" : "The one with the most quota left")
                flowChevron
                step(icon: "cpu", title: "Main + Worker run it", caption: "Models come from the chosen account.")
            }
        }
    }

    private func step(icon: String, title: String, caption: String) -> some View {
        VStack(spacing: DS.Space.sm) {
            AgentChoiceIconTile(systemName: icon, tint: DS.Palette.accent, size: 34)
            Text(title)
                .font(DS.Font.bodyStrong)
                .foregroundColor(DS.Palette.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(caption)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var flowChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(DS.Palette.textTertiary)
            .frame(height: 34)
            .accessibilityHidden(true)
    }

    // MARK: Profile

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack(alignment: .center, spacing: DS.Space.lg) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text("Use Auto profile").font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                    Text("Auto picks an option for Main when you choose Auto.")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                }
                Spacer(minLength: DS.Space.lg)
                Toggle("Use Auto profile", isOn: Binding(get: { draft.enabled }, set: { value in
                    var next = draft
                    next.enabled = value
                    draft = next
                }))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text("Strategy").font(DS.Font.captionStrong).foregroundColor(DS.Palette.textSecondary)
                AgentChoiceSegmented(
                    options: [
                        (value: DistillAutoStrategy.orderedFirst, title: "In order", help: "Try connected accounts in the order below."),
                        (value: DistillAutoStrategy.highestRemaining, title: "Most quota left", help: "Prefer the connected account with the highest known remaining quota.")
                    ],
                    selection: draft.strategy,
                    onSelect: { strategy in
                        var next = draft
                        next.strategy = strategy
                        draft = next
                    }
                )
                Text(draft.strategy == .orderedFirst
                     ? "Try connected accounts in the order below."
                     : "Prefer the connected account with the highest known remaining quota.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised)
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    // MARK: Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            AgentChoiceSectionHeader("Options") {
                HStack(spacing: DS.Space.md) {
                    Text("\(draft.options.count)")
                        .font(DS.Font.caption2.monospacedDigit())
                        .foregroundColor(DS.Palette.textTertiary)
                    Button(action: addOption) {
                        Label("Add option", systemImage: "plus")
                            .font(DS.Font.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Add an option")
                }
            }
            if statuses.isEmpty {
                AgentChoiceCallout(icon: "person.crop.circle.badge.exclamationmark", tint: DS.Palette.warning,
                                   text: "Connect an account in Settings › Accounts & Auto to use Auto.")
            } else if draft.options.isEmpty {
                AgentChoiceCallout(icon: "info.circle", tint: DS.Palette.accent,
                                   text: "Add an option to choose an account and its models.")
            }
            ForEach(Array(draft.options.enumerated()), id: \.element.id) { index, option in
                optionCard(option, index: index)
            }
        }
    }

    private func optionCard(_ option: DistillAutoOption, index: Int) -> some View {
        let account = statuses.first { $0.id == option.accountID }
        let eligible = DistillRoutingValidation.models(for: account, catalog: models)
        return VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(alignment: .top, spacing: DS.Space.md) {
                Text("\(index + 1)")
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(DS.Palette.onAccent)
                    .frame(width: 22, height: 22)
                    .background(DS.Palette.accent, in: Circle())
                    .accessibilityLabel("Option \(index + 1)")
                accountField(option, account: account)
                iconButton("chevron.up", help: "Move option up", disabled: index == 0) { moveOption(option.id, offset: -1) }
                iconButton("chevron.down", help: "Move option down", disabled: index == draft.options.count - 1) { moveOption(option.id, offset: 1) }
                iconButton("trash", help: "Remove option", tint: DS.Palette.danger) { removeOption(option.id) }
            }
            HStack(alignment: .top, spacing: DS.Space.lg) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    fieldLabel("Main")
                    Picker("Main", selection: Binding(get: { option.mainModel }, set: { model in editOption(option.id) { $0.mainModel = model } })) {
                        if !eligible.contains(where: { $0.id == option.mainModel }) {
                            Text(option.mainModel.isEmpty ? "Choose model" : "Unavailable: \(option.mainModel)").tag(option.mainModel)
                        }
                        ForEach(eligible, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(option.mainModel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    fieldLabel("Worker")
                    Picker("Worker", selection: Binding(get: { option.workerModel ?? "" }, set: { model in
                        editOption(option.id) { $0.workerModel = model.isEmpty ? nil : model }
                    })) {
                        Text("Same as Main").tag("")
                        if let worker = option.workerModel, !eligible.contains(where: { $0.id == worker }) {
                            Text("Unavailable: \(worker)").tag(worker)
                        }
                        ForEach(eligible, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(option.workerModel ?? "Same as Main")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised)
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.accounts.routing.\(option.id)")
    }

    private func accountField(_ option: DistillAutoOption, account: DistillAccountStatus?) -> some View {
        let remaining = account.flatMap {
            DistillAccountsPanelPresentation.quotaPresentation($0.quota, connected: $0.connected, connectionError: $0.connectionError).remainingPercent
        }
        return VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack(spacing: DS.Space.sm) {
                Circle()
                    .fill(account?.connected == true ? DS.Palette.success : DS.Palette.textTertiary)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Picker("Account", selection: Binding(get: { option.accountID }, set: { id in
                    editOption(option.id) {
                        $0.accountID = id
                        $0.mainModel = DistillRoutingValidation.models(for: statuses.first { $0.id == id }, catalog: models).first?.id ?? ""
                        $0.workerModel = nil
                    }
                })) {
                    if account == nil { Text("Choose account").tag(option.accountID) }
                    ForEach(statuses, id: \.id) { Text("\($0.provider.displayName) · \($0.label)").tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(account.map { "\($0.provider.displayName) · \($0.label)" } ?? "Choose account")
            }
            if let account, !account.connected {
                Text("Not connected").font(DS.Font.caption).foregroundColor(DS.Palette.textTertiary)
            } else if let remaining {
                Text("\(Int(remaining.rounded()))% remaining").font(DS.Font.caption).foregroundColor(DS.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(DS.Font.caption)
            .foregroundColor(DS.Palette.textSecondary)
    }

    private func iconButton(_ systemName: String, help: String, disabled: Bool = false,
                            tint: Color = DS.Palette.textSecondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Draft mutations

    private func addOption() {
        let account = statuses.first
        let model = DistillRoutingValidation.models(for: account, catalog: models).first
        var value = draft
        value.options.append(.init(id: UUID().uuidString.lowercased(), accountID: account?.id ?? "", mainModel: model?.id ?? ""))
        draft = value
    }

    private func editOption(_ id: String, _ edit: (inout DistillAutoOption) -> Void) {
        var value = draft
        guard let index = value.options.firstIndex(where: { $0.id == id }) else { return }
        edit(&value.options[index])
        draft = value
    }

    private func moveOption(_ id: String, offset: Int) {
        var value = draft
        guard let index = value.options.firstIndex(where: { $0.id == id }), value.options.indices.contains(index + offset) else { return }
        value.options.swapAt(index, index + offset)
        draft = value
    }

    private func removeOption(_ id: String) {
        var value = draft
        value.options.removeAll { $0.id == id }
        draft = value
    }
}
