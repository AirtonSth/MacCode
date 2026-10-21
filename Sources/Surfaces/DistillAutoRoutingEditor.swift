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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            enableRow
            if draft.enabled {
                Group {
                    strategyRow
                    optionsSection
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: draft.enabled)
            } else {
                offHint
            }
            if let error = validationError {
                AgentChoiceCallout(icon: "exclamationmark.triangle.fill", tint: DS.Palette.warning, text: error)
            }
        }
        .disabled(disabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Enable

    private var enableRow: some View {
        HStack(alignment: .center, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Use Auto").font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text)
                Text("When you pick Auto as Main, Distill chooses an account for you.")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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
    }

    private var offHint: some View {
        Text("Auto is off. Main uses the model you pick.")
            .font(DS.Font.caption)
            .foregroundColor(DS.Palette.textTertiary)
    }

    // MARK: Strategy

    private var strategyRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Pick accounts").font(DS.Font.captionStrong).foregroundColor(DS.Palette.textSecondary)
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
                 ? "Uses the first available option below."
                 : "Uses the option with the most quota left.")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Text("Options").font(DS.Font.captionStrong).foregroundColor(DS.Palette.textSecondary)
                Text("\(draft.options.count)")
                    .font(DS.Font.caption2.monospacedDigit())
                    .foregroundColor(DS.Palette.textTertiary)
                Spacer(minLength: 0)
            }
            if statuses.isEmpty {
                AgentChoiceCallout(icon: "person.crop.circle.badge.exclamationmark", tint: DS.Palette.warning,
                                   text: "Add an account on the left to use Auto.")
            } else if draft.options.isEmpty {
                AgentChoiceCallout(icon: "info.circle", tint: DS.Palette.accent,
                                   text: "Add an option to choose an account and its models.")
            }
            VStack(spacing: DS.Space.sm) {
                ForEach(Array(draft.options.enumerated()), id: \.element.id) { index, option in
                    optionCard(option, index: index)
                }
            }
            addOptionButton
        }
    }

    private var addOptionButton: some View {
        Button(action: addOption) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "plus")
                Text("Add option")
            }
            .font(DS.Font.caption.weight(.semibold))
            .foregroundColor(DS.Palette.accent)
            .frame(maxWidth: .infinity, minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card)
                .strokeBorder(DS.Palette.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .disabled(statuses.isEmpty)
        .help("Add an option")
    }

    private func optionCard(_ option: DistillAutoOption, index: Int) -> some View {
        let account = statuses.first { $0.id == option.accountID }
        let eligible = DistillRoutingValidation.models(for: account, catalog: models)
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Text("\(index + 1)")
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(DS.Palette.onAccent)
                    .frame(width: 20, height: 20)
                    .background(DS.Palette.accent, in: Circle())
                    .accessibilityLabel("Option \(index + 1)")
                accountField(option, account: account)
                Spacer(minLength: 0)
                Menu {
                    Button("Move up") { moveOption(option.id, offset: -1) }
                        .disabled(index == 0)
                    Button("Move down") { moveOption(option.id, offset: 1) }
                        .disabled(index == draft.options.count - 1)
                    Divider()
                    Button("Remove", role: .destructive) { removeOption(option.id) }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Actions for option \(index + 1)")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.md) {
                    mainPicker(option, eligible: eligible).frame(minWidth: 160)
                    workerPicker(option, eligible: eligible).frame(minWidth: 160)
                }
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    mainPicker(option, eligible: eligible)
                    workerPicker(option, eligible: eligible)
                }
            }
        }
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.bg.opacity(0.4))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.accounts.routing.\(option.id)")
    }

    private func mainPicker(_ option: DistillAutoOption, eligible: [AgentModelDescriptor]) -> some View {
        HStack(spacing: DS.Space.xs) {
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
    }

    private func workerPicker(_ option: DistillAutoOption, eligible: [AgentModelDescriptor]) -> some View {
        HStack(spacing: DS.Space.xs) {
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
    }

    private func accountField(_ option: DistillAutoOption, account: DistillAccountStatus?) -> some View {
        let remaining = account.flatMap {
            DistillAccountsPanelPresentation.quotaPresentation($0.quota, connected: $0.connected, connectionError: $0.connectionError).remainingPercent
        }
        return HStack(spacing: DS.Space.sm) {
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
            if let account, !account.connected {
                Text("Not connected")
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            } else if let remaining {
                Text("\(Int(remaining.rounded()))% remaining")
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(DS.Font.caption)
            .foregroundColor(DS.Palette.textSecondary)
            .fixedSize()
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
