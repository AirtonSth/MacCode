import AppKit
import CoreModel
import DesignSystemKit
import SwiftUI

/// Shared composer chrome for Agent App and Bots Desk.
///
/// WHY: Desk reimplemented account / permission / run-as / model pills as
/// `deskChipLabel`. Those controls are the same as Agent App and must paint
/// from one component.

// MARK: - Capsule shell

public enum AgentComposerCapsuleStyle: Equatable {
    case raised
    case tinted(Color)
}

public struct AgentComposerCapsule<Content: View>: View {
    public let style: AgentComposerCapsuleStyle
    public let foreground: Color
    public let content: Content

    public init(
        style: AgentComposerCapsuleStyle = .raised,
        foreground: Color = DS.Palette.textSecondary,
        @ViewBuilder content: () -> Content
    ) {
        self.style = style
        self.foreground = foreground
        self.content = content()
    }

    public var body: some View {
        content
            .fixedSize()
            .foregroundColor(foreground)
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, DS.Space.xs)
            .background(background)
            .clipShape(Capsule())
            .overlay(stroke)
    }

    private var background: Color {
        switch style {
        case .raised: return DS.Palette.surfaceRaised
        case .tinted(let color): return color.opacity(0.13)
        }
    }

    @ViewBuilder
    private var stroke: some View {
        switch style {
        case .raised:
            Capsule().strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        case .tinted:
            EmptyView()
        }
    }
}

public struct AgentComposerCapsuleLabel: View {
    public let icon: String?
    public let title: String
    public let chevron: Bool

    public init(icon: String?, title: String, chevron: Bool) {
        self.icon = icon
        self.title = title
        self.chevron = chevron
    }

    public var body: some View {
        HStack(spacing: DS.Space.xs) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10))
            }
            Text(title)
                .font(DS.Font.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
        }
    }
}

public extension AgentPermissionMode {
    var capsuleTint: Color {
        switch self {
        case .supervised: return DS.Palette.textSecondary
        case .autoAcceptEdits: return DS.Palette.warning
        case .fullAccess: return DS.Palette.danger
        }
    }

    var capsuleIcon: String {
        self == .fullAccess ? "exclamationmark.shield.fill" : "lock.shield"
    }
}

// MARK: - Compact menu

public struct AgentCompactMenuSection: View {
    public let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .font(DS.Font.caption2.weight(.semibold))
            .foregroundColor(DS.Palette.textTertiary)
            .padding(.top, DS.Space.xs)
            .fixedSize(horizontal: true, vertical: false)
    }
}

public struct AgentCompactMenuRow: View {
    public let title: String
    public let detail: String?
    public let selected: Bool
    public let width: CGFloat?
    public let action: () -> Void

    public init(
        _ title: String,
        detail: String? = nil,
        selected: Bool,
        width: CGFloat? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.selected = selected
        self.width = width
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 12)
                    .opacity(selected ? 1 : 0)
                Text(title)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(DS.Font.caption2.monospacedDigit())
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, DS.Space.xs)
            .frame(width: width, alignment: .leading)
            .background(selected ? DS.Palette.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

public struct AgentCompactMenuDivider: View {
    public let width: CGFloat?

    public init(width: CGFloat? = nil) {
        self.width = width
    }

    public var body: some View {
        Rectangle()
            .fill(DS.Palette.line)
            .frame(height: DS.Border.hairline)
            .padding(.vertical, DS.Space.xs)
            .frame(width: width)
    }
}

/// Pure width estimator for compact model menus. Distill labels are long
/// ("Muse Spark 1.3 Contributor") and numerous, so Distill callers pass the
/// full label set with a wider cap instead of the 3-row default.
public enum AgentModelMenuWidth {
    public static let defaultMin: CGFloat = 112
    public static let defaultMax: CGFloat = 260
    public static let distillMin: CGFloat = 224
    public static let distillMax: CGFloat = 360

    public static func estimatedWidth(
        titles: [String],
        min minWidth: CGFloat = defaultMin,
        max maxWidth: CGFloat = defaultMax
    ) -> CGFloat {
        let estimated = titles.map { CGFloat($0.count * 7 + 34) }.max() ?? minWidth
        return min(max(estimated, minWidth), maxWidth)
    }
}

/// Inline filter field for long Distill model lists.
public struct AgentModelSearchField: View {
    @Binding public var query: String
    public let width: CGFloat?
    public let accessibilityIdentifier: String

    public init(query: Binding<String>, width: CGFloat? = nil, accessibilityIdentifier: String) {
        self._query = query
        self.width = width
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityHidden(true)
            TextField("Filter models", text: $query)
                .textFieldStyle(.plain)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.text)
                .accessibilityIdentifier(accessibilityIdentifier)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, DS.Space.xs)
        .frame(width: width, alignment: .leading)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
        .padding(.bottom, DS.Space.xs)
    }
}

// MARK: - Source

public struct AgentSourceCapsule: View {
    public let label: String
    public let entries: [AgentSourceCapsulePresentation.MenuEntry]
    public let runLocked: Bool
    public let providerLocked: Bool
    public let unavailableReason: String?
    public let rowWidth: CGFloat
    public let accessibilityIdentifier: String
    public let popoverIdentifier: String
    @Binding public var isPresented: Bool
    public let onSelect: (AgentSourceCapsulePresentation.MenuEntry) -> Void

    public init(
        label: String,
        entries: [AgentSourceCapsulePresentation.MenuEntry],
        runLocked: Bool,
        providerLocked: Bool,
        unavailableReason: String? = nil,
        rowWidth: CGFloat = 220,
        accessibilityIdentifier: String,
        popoverIdentifier: String,
        isPresented: Binding<Bool>,
        onSelect: @escaping (AgentSourceCapsulePresentation.MenuEntry) -> Void
    ) {
        self.label = label
        self.entries = entries
        self.runLocked = runLocked
        self.providerLocked = providerLocked
        self.unavailableReason = unavailableReason
        self.rowWidth = rowWidth
        self.accessibilityIdentifier = accessibilityIdentifier
        self.popoverIdentifier = popoverIdentifier
        self._isPresented = isPresented
        self.onSelect = onSelect
    }

    private var canSwitch: Bool {
        AgentSourceCapsulePresentation.isInteractive(
            enabledSourceCount: entries.count,
            providerLocked: providerLocked,
            runLocked: runLocked
        )
    }

    private var helpText: String {
        AgentSourceCapsulePresentation.helpText(
            canSwitch: canSwitch,
            runLocked: runLocked,
            providerLocked: providerLocked,
            unavailableReason: unavailableReason
        )
    }

    public var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            AgentComposerCapsule {
                AgentComposerCapsuleLabel(
                    icon: (providerLocked || runLocked) ? "lock.fill" : "person.crop.circle",
                    title: label,
                    chevron: true
                )
            }
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel("Account \(label)")
        .accessibilityHint(AgentSourceCapsulePresentation.switchHint(canSwitch: canSwitch, helpText: helpText))
        .accessibilityIdentifier(accessibilityIdentifier)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popover
        }
    }

    private var popover: some View {
        let notice = AgentSourceCapsulePresentation.lockNotice(
            runLocked: runLocked,
            providerLocked: providerLocked,
            unavailableReason: unavailableReason,
            entryCount: entries.count
        )
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            if let notice {
                Text(notice.text)
                    .font(DS.Font.caption2)
                    .foregroundColor(notice.isWarning ? DS.Palette.warning : DS.Palette.textTertiary)
                    .fixedSize(horizontal: notice.wraps ? false : true, vertical: notice.wraps)
                    .frame(maxWidth: notice.wraps ? rowWidth : nil, alignment: .leading)
            }
            AgentCompactMenuSection("Account")
            if entries.isEmpty {
                Text("No accounts loaded")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
            } else {
                ForEach(entries, id: \.id) { entry in
                    AgentCompactMenuRow(entry.title, selected: entry.isSelected, width: rowWidth) {
                        guard canSwitch else { return }
                        onSelect(entry)
                        isPresented = false
                    }
                    .disabled(!canSwitch)
                }
            }
        }
        .padding(DS.Space.sm)
        .background(DS.Palette.surfaceOverlay)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier(popoverIdentifier)
    }
}

// MARK: - Permission

public struct AgentPermissionCapsule: View {
    public let selected: AgentPermissionMode
    public let modes: [AgentPermissionMode]
    public let unavailableReason: (AgentPermissionMode) -> String?
    public let disabled: Bool
    public let help: String
    public let accessibilityIdentifier: String
    public let onSelect: (AgentPermissionMode) -> Void

    public init(
        selected: AgentPermissionMode,
        modes: [AgentPermissionMode],
        unavailableReason: @escaping (AgentPermissionMode) -> String? = { _ in nil },
        disabled: Bool,
        help: String = "Permission mode",
        accessibilityIdentifier: String,
        onSelect: @escaping (AgentPermissionMode) -> Void
    ) {
        self.selected = selected
        self.modes = modes
        self.unavailableReason = unavailableReason
        self.disabled = disabled
        self.help = help
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onSelect = onSelect
    }

    public var body: some View {
        Menu {
            ForEach(modes, id: \.self) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    if mode == selected { Image(systemName: "checkmark") }
                    Text(mode.displayName)
                }
                .disabled(unavailableReason(mode) != nil)
                .help(unavailableReason(mode) ?? mode.pickerHelpText)
            }
        } label: {
            AgentComposerCapsule(style: .tinted(selected.capsuleTint), foreground: selected.capsuleTint) {
                AgentComposerCapsuleLabel(
                    icon: selected.capsuleIcon,
                    title: selected.displayName,
                    chevron: true
                )
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(disabled)
        .help(help)
        .accessibilityLabel("Permission \(selected.displayName)")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

// MARK: - Run as

public enum AgentRunAsUserPresentation {
    public static let noBotLabel = "No Bot"
    public static let continueWithoutBotLabel = "Continuar sem bot"
    public static let handoffToBotSection = "Nova thread com outro bot…"
    public static let botActorIcon = "cpu"

    public static func isInteractive(userCount: Int, identityLocked: Bool, runLocked: Bool) -> Bool {
        userCount > 1 && !identityLocked && !runLocked
    }

    /// The chip opens a popover when there is anything to choose, or when a
    /// locked thread offers the hand-off.
    public static func isInteractive(
        userCount: Int,
        botsAvailable: Bool,
        actor: RunActor,
        identityLocked: Bool,
        runLocked: Bool
    ) -> Bool {
        if runLocked { return false }
        if identityLocked { return actor.botID != nil || botsAvailable }
        return userCount > 1 || botsAvailable
    }

    public static func identityLocked(providerLocked: Bool, actorLockedAt: Date?) -> Bool {
        providerLocked || actorLockedAt != nil
    }

    public static func targetBadge(_ target: ExecutionTarget) -> String {
        target == .vm ? "VM" : "Mac"
    }

    public static func actorTitle(botName: String, target: ExecutionTarget) -> String {
        "\(botName) · \(targetBadge(target))"
    }

    public static func actorIcon(identityLocked: Bool) -> String {
        identityLocked ? "lock.fill" : botActorIcon
    }

    public static func actorAccessibilityLabel(botName: String, target: ExecutionTarget, identityLocked: Bool) -> String {
        identityLocked
            ? "Locked to bot \(botName)"
            : "Run as bot \(botName) on \(targetBadge(target))"
    }

    public static func helpText(
        interactive: Bool,
        selected: AgentRunAsUser,
        identityLocked: Bool,
        runLocked: Bool
    ) -> String {
        if runLocked { return "macOS user is fixed while a run is active" }
        if identityLocked {
            return "macOS user is fixed after the first message. Start a new thread to run as a different user."
        }
        if !interactive {
            return "Provider processes run as macOS user \(selected.shortName)"
        }
        return "Choose which macOS user runs Distill (through the shared helper)"
    }
}

public struct AgentRunAsUserCapsule: View {
    public let usersProvider: () -> [AgentRunAsUser]
    public let selected: AgentRunAsUser
    public let runLocked: Bool
    public let identityLocked: Bool
    public let accessibilityIdentifier: String
    public let actor: RunActor
    /// Read only while the popover is open (and once to name a bot actor), never per body pass.
    public let botsProvider: (() -> [BotDefinition])?
    public let executionTarget: (BotID) -> ExecutionTarget
    public let onSelect: (AgentRunAsUser) -> Void
    public let onSelectActor: (RunActor) -> Void
    public let onContinueWithoutBot: () -> Void
    public let onHandoffToBot: ((BotID) -> Void)?
    public let onAppear: (() -> Void)?

    @State private var isPresented = false
    @State private var users: [AgentRunAsUser] = []
    @State private var bots: [BotDefinition] = []
    @State private var actorName: String?

    public init(
        usersProvider: @escaping () -> [AgentRunAsUser],
        selected: AgentRunAsUser,
        runLocked: Bool,
        identityLocked: Bool,
        accessibilityIdentifier: String,
        actor: RunActor = .none,
        botsProvider: (() -> [BotDefinition])? = nil,
        executionTarget: @escaping (BotID) -> ExecutionTarget = { _ in .mac },
        onSelect: @escaping (AgentRunAsUser) -> Void,
        onSelectActor: @escaping (RunActor) -> Void = { _ in },
        onContinueWithoutBot: @escaping () -> Void = {},
        onHandoffToBot: ((BotID) -> Void)? = nil,
        onAppear: (() -> Void)? = nil
    ) {
        self.usersProvider = usersProvider
        self.selected = selected
        self.runLocked = runLocked
        self.identityLocked = identityLocked
        self.accessibilityIdentifier = accessibilityIdentifier
        self.actor = actor
        self.botsProvider = botsProvider
        self.executionTarget = executionTarget
        self.onSelect = onSelect
        self.onSelectActor = onSelectActor
        self.onContinueWithoutBot = onContinueWithoutBot
        self.onHandoffToBot = onHandoffToBot
        self.onAppear = onAppear
    }

    public init(
        users: [AgentRunAsUser],
        selected: AgentRunAsUser,
        runLocked: Bool,
        identityLocked: Bool,
        accessibilityIdentifier: String,
        onSelect: @escaping (AgentRunAsUser) -> Void,
        onAppear: (() -> Void)? = nil
    ) {
        self.init(
            usersProvider: { users },
            selected: selected,
            runLocked: runLocked,
            identityLocked: identityLocked,
            accessibilityIdentifier: accessibilityIdentifier,
            onSelect: onSelect,
            onAppear: onAppear
        )
    }

    private var botID: BotID? { actor.botID }
    private var botName: String { actorName ?? "Bot" }

    private var interactive: Bool {
        AgentRunAsUserPresentation.isInteractive(
            userCount: users.count,
            botsAvailable: botsProvider != nil,
            actor: actor,
            identityLocked: identityLocked,
            runLocked: runLocked
        )
    }

    private var accessibilityText: String {
        guard let botID else { return "Run as macOS user \(selected.shortName)" }
        return AgentRunAsUserPresentation.actorAccessibilityLabel(
            botName: botName,
            target: executionTarget(botID),
            identityLocked: identityLocked
        )
    }

    public var body: some View {
        Group {
            if interactive {
                Button {
                    isPresented.toggle()
                } label: {
                    capsule(chevron: !identityLocked)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isPresented, arrowEdge: .bottom) { popover }
            } else {
                capsule(chevron: false)
            }
        }
        .disabled(runLocked)
        .help(AgentRunAsUserPresentation.helpText(
            interactive: interactive,
            selected: selected,
            identityLocked: identityLocked,
            runLocked: runLocked
        ))
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier(accessibilityIdentifier)
        .onAppear {
            users = usersProvider()
            resolveActorName()
            onAppear?()
        }
        .onChange(of: actor) { _ in resolveActorName() }
    }

    private func resolveActorName() {
        guard let botID, let botsProvider else {
            actorName = nil
            return
        }
        actorName = botsProvider().first(where: { $0.id == botID })?.name
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if identityLocked {
                if botID != nil {
                    AgentCompactMenuRow(
                        AgentRunAsUserPresentation.continueWithoutBotLabel,
                        selected: false
                    ) {
                        onContinueWithoutBot()
                        isPresented = false
                    }
                }
                if let onHandoffToBot {
                    AgentCompactMenuSection(AgentRunAsUserPresentation.handoffToBotSection)
                    ForEach(bots.filter { $0.id != botID }, id: \.id.value) { bot in
                        AgentCompactMenuRow(
                            bot.name,
                            detail: AgentRunAsUserPresentation.targetBadge(executionTarget(bot.id)),
                            selected: false
                        ) {
                            onHandoffToBot(bot.id)
                            isPresented = false
                        }
                    }
                }
            } else {
                if users.count > 1 {
                    AgentCompactMenuSection("macOS user")
                    ForEach(users, id: \.id) { user in
                        AgentCompactMenuRow(
                            user.shortName,
                            detail: user.fullName.flatMap { $0 != user.shortName ? $0 : nil },
                            selected: user.uid == selected.uid
                        ) {
                            onSelect(user)
                            isPresented = false
                        }
                    }
                }
                if botsProvider != nil {
                    AgentCompactMenuRow(AgentRunAsUserPresentation.noBotLabel, selected: actor == .none) {
                        onSelectActor(.none)
                        isPresented = false
                    }
                    AgentCompactMenuSection("Bots")
                    ForEach(bots, id: \.id.value) { bot in
                        AgentCompactMenuRow(
                            bot.name,
                            detail: AgentRunAsUserPresentation.targetBadge(executionTarget(bot.id)),
                            selected: actor == .bot(bot.id)
                        ) {
                            onSelectActor(.bot(bot.id))
                            isPresented = false
                        }
                    }
                }
            }
        }
        .padding(DS.Space.sm)
        .background(DS.Palette.surfaceOverlay)
        .fixedSize(horizontal: true, vertical: false)
        .onAppear {
            users = usersProvider()
            bots = botsProvider?() ?? []
        }
    }

    private func capsule(chevron: Bool) -> some View {
        AgentComposerCapsule {
            if let botID {
                AgentComposerCapsuleLabel(
                    icon: AgentRunAsUserPresentation.actorIcon(identityLocked: identityLocked),
                    title: AgentRunAsUserPresentation.actorTitle(botName: botName, target: executionTarget(botID)),
                    chevron: chevron
                )
            } else {
                AgentComposerCapsuleLabel(
                    icon: identityLocked ? "lock.fill" : "person.fill",
                    title: selected.shortName,
                    chevron: chevron
                )
            }
        }
    }
}

// MARK: - Model pill

public struct AgentModelPillPresentation: Equatable {
    public let title: String
    public let loading: Bool
    public let effort: String?
    public let serviceTier: String?
    public let contextWindow: String?
    /// Leading qualifier so adjacent pills stay unambiguous ("Main", "Reasoning").
    public let prefix: String?
    /// True when the selected model is missing from the current list.
    public let warning: Bool

    public init(
        title: String,
        loading: Bool = false,
        effort: String? = nil,
        serviceTier: String? = nil,
        contextWindow: String? = nil,
        prefix: String? = nil,
        warning: Bool = false
    ) {
        self.title = title
        self.loading = loading
        self.effort = effort
        self.serviceTier = serviceTier
        self.contextWindow = contextWindow
        self.prefix = prefix
        self.warning = warning
    }

    public var isAuto: Bool {
        title.caseInsensitiveCompare("Auto") == .orderedSame
    }

    public var accessibilityLabel: String {
        if isAuto {
            return loading ? "Auto model routing, loading" : "Auto model routing"
        }
        let subject = prefix.map { "\($0) model \(title)" } ?? "Model \(title)"
        var parts = [subject]
        if let effort { parts.append("effort \(effort)") }
        if let serviceTier { parts.append("tier \(serviceTier)") }
        if warning { parts.append("unavailable") }
        return parts.joined(separator: ", ")
    }
}

public struct AgentModelPillLabel: View {
    public let presentation: AgentModelPillPresentation
    public let width: CGFloat?

    public init(presentation: AgentModelPillPresentation, width: CGFloat? = nil) {
        self.presentation = presentation
        self.width = width
    }

    public var body: some View {
        HStack(spacing: DS.Space.xs) {
            if presentation.loading {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            }
            if presentation.warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Palette.warning)
                    .accessibilityHidden(true)
            }
            if let prefix = presentation.prefix {
                Text(prefix)
                    .font(DS.Font.caption2.weight(.semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
            Text(presentation.title)
                .font(DS.Font.caption.weight(.medium))
                .foregroundColor(DS.Palette.text)
                .lineLimit(1)
                .truncationMode(.tail)
            if let effort = presentation.effort {
                Text("·").foregroundColor(DS.Palette.textTertiary)
                Text(effort)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let tier = presentation.serviceTier {
                Text("·").foregroundColor(DS.Palette.textTertiary)
                Text(tier)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.warning)
                    .lineLimit(1)
            }
            if let ctx = presentation.contextWindow {
                Text("·").foregroundColor(DS.Palette.textTertiary)
                Text(ctx)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
                .foregroundColor(DS.Palette.textTertiary)
        }
        .modifier(AgentModelPillWidth(width: width))
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, DS.Space.xs)
        .background(DS.Palette.surfaceRaised)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
    }
}

private struct AgentModelPillWidth: ViewModifier {
    let width: CGFloat?

    func body(content: Content) -> some View {
        if let width {
            content.frame(width: width, alignment: .trailing)
        } else {
            content.fixedSize()
        }
    }
}

// MARK: - Queued header

public struct AgentQueuedHeader: View {
    public let count: Int
    public let identifier: String

    public init(count: Int, identifier: String) {
        self.count = count
        self.identifier = identifier
    }

    public var body: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Palette.accent)
                .accessibilityHidden(true)
            Text("Queued")
                .font(DS.Font.caption.weight(.semibold))
                .foregroundColor(DS.Palette.accent)
            Text("\(count)")
                .font(DS.Font.caption.monospacedDigit())
                .foregroundColor(DS.Palette.textTertiary)
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Suggestion panel

/// CH-11: cheap suggestion observation. `AgentComposerSuggestion` is already
/// Equatable, so SwiftUI can `onChange(of: suggestions)` without allocating
/// `map(\.id)` or `Array(enumerated())` on every composer body.
enum ComposerSuggestionObservation {
    static let extraArrayAllocationsPerBody = 0

    static func shouldResetHighlight(
        from previous: [AgentComposerSuggestion],
        to current: [AgentComposerSuggestion]
    ) -> Bool {
        previous != current
    }
}

public struct AgentComposerSuggestionPanel: View {
    public let suggestions: [AgentComposerSuggestion]
    public let highlightedIndex: Int?
    public let identifier: String
    public let onSelect: (AgentComposerSuggestion) -> Void

    public init(
        suggestions: [AgentComposerSuggestion],
        highlightedIndex: Int?,
        identifier: String,
        onSelect: @escaping (AgentComposerSuggestion) -> Void
    ) {
        self.suggestions = suggestions
        self.highlightedIndex = highlightedIndex
        self.identifier = identifier
        self.onSelect = onSelect
    }

    public var body: some View {
        let layout = ComposerSuggestionPlacement.layout(suggestionCount: suggestions.count)
        let highlightedID = Self.highlightedSuggestionID(in: suggestions, index: highlightedIndex)
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: suggestions.count > layout.maxVisibleRows) {
                VStack(spacing: 0) {
                    ForEach(suggestions) { suggestion in
                        row(suggestion, highlighted: suggestion.id == highlightedID)
                            .frame(height: layout.rowHeight)
                    }
                }
            }
            .frame(height: layout.height)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
        .padding(.horizontal, DS.Space.lg)
        .padding(.bottom, DS.Space.xs)
        .accessibilityIdentifier(identifier)
        .allowsHitTesting(true)
    }

    /// CH-11: highlight without `Array(enumerated())`. Identity stays on
    /// `AgentComposerSuggestion.id`; the index is only a lookup.
    public static func highlightedSuggestionID(
        in suggestions: [AgentComposerSuggestion],
        index: Int?
    ) -> String? {
        guard let index, suggestions.indices.contains(index) else { return nil }
        return suggestions[index].id
    }

    private func row(_ suggestion: AgentComposerSuggestion, highlighted: Bool) -> some View {
        Button { onSelect(suggestion) } label: {
            HStack(spacing: DS.Space.sm) {
                if suggestion.kind == .bot {
                    BotsAvatarView(
                        name: suggestion.botName ?? suggestion.title,
                        handle: suggestion.botHandle ?? "",
                        symbol: suggestion.botAvatarSymbol,
                        size: 18
                    )
                } else {
                    Image(systemName: suggestion.kind == .skill ? "puzzlepiece.extension" : "command")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(highlighted ? DS.Palette.accent : DS.Palette.textSecondary)
                        .frame(width: 16)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(suggestion.title)
                        .font(DS.Font.caption.weight(.medium))
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(1)
                    Text(suggestion.subtitle)
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? DS.Palette.accent.opacity(0.14) : Color.clear)
        }
        .buttonStyle(.plain)
        .help(suggestion.subtitle)
        .accessibilityIdentifier("agent.suggestion.\(suggestion.insertText.trimmingCharacters(in: .whitespaces))")
    }
}
