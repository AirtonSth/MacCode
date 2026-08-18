import CoreModel
import DesignSystemKit
import SwiftUI

public enum ActiveBotsTab: String, CaseIterable, Identifiable {
    case active
    case lastFinished

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .active: return "Active"
        case .lastFinished: return "Last Finished"
        }
    }
}

public struct ActiveBotScreenItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let botID: BotID
    public let title: String
    public let handle: String
    public let detail: String
    public let preview: String?
    public let symbol: String?
    public let startedAt: Date?

    public init(bot: BotDefinition, preview: String, providerName: String, startedAt: Date? = nil) {
        self.id = "active:\(bot.id.value.uuidString.lowercased())"
        self.botID = bot.id
        self.title = bot.name
        self.handle = bot.handle
        let job = bot.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let handleLine = "@\(bot.handle)"
        if job.isEmpty {
            self.detail = "\(handleLine) · \(providerName)"
        } else {
            self.detail = "\(handleLine) · \(job) · \(providerName)"
        }
        let clean = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preview = clean.isEmpty || clean == "No job yet" ? nil : clean
        self.symbol = bot.avatarSymbol
        self.startedAt = startedAt
    }

    public var lastTriggeredLabel: String {
        Self.timestampLabel(startedAt)
    }

    public var nextRunLabel: String { "Running now" }

    static func timestampLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

public struct FinishedBotScreenItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let runID: AgentRunID
    public let botID: BotID
    public let title: String
    public let detail: String
    public let status: AgentRunStatus
    public let finishedAt: Date?
    public let startedAt: Date

    public init(run: AgentRun, bot: BotDefinition, conversationTitle: String) {
        self.id = "finished:\(run.id.value.uuidString.lowercased())"
        self.runID = run.id
        self.botID = bot.id
        let safeTitle = bot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = safeTitle.isEmpty ? "Bot" : safeTitle
        let provider = PetActiveThreadProjector.providerLabel(run.provider)
        let model = run.model.isEmpty ? provider : "\(provider) · \(run.model)"
        let convo = conversationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.detail = convo.isEmpty ? "@\(bot.handle) · \(model)" : "@\(bot.handle) · \(convo) · \(model)"
        self.status = run.status
        self.finishedAt = run.finishedAt
        self.startedAt = run.startedAt
    }

    public var lastTriggeredLabel: String {
        ActiveBotScreenItem.timestampLabel(finishedAt ?? startedAt)
    }

    public var nextRunLabel: String { "—" }
}

public struct ActiveBotsRootView: View {
    @ObservedObject private var vm: BotsViewModel

    public init(vm: BotsViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(spacing: 0) {
            overviewScreen
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            footerBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Palette.bg)
        .accessibilityIdentifier("bots.activeScreen")
        .onAppear { vm.reloadActiveBotsScreen() }
        .onChange(of: vm.activeBotsTab) { _ in
            vm.reloadActiveBotsScreen()
        }
    }

    private var overviewScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: DS.Space.lg) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Active Bots")
                        .font(DS.Font.title.weight(.semibold))
                        .foregroundColor(DS.Palette.text)
                    Text(vm.activeBotsSubtitle)
                        .font(DS.Font.body)
                        .foregroundColor(DS.Palette.textSecondary)
                }
                Spacer(minLength: DS.Space.lg)
            }
            .padding(.horizontal, DS.Space.xxl)
            .padding(.top, DS.Space.xxl)
            .padding(.bottom, DS.Space.xl)

            HStack(spacing: DS.Space.md) {
                filterChips
                Spacer(minLength: DS.Space.lg)
                searchField
                    .frame(maxWidth: 280)
            }
            .padding(.horizontal, DS.Space.xxl)
            .padding(.bottom, DS.Space.xl)

            content
        }
    }

    private var filterChips: some View {
        HStack(spacing: DS.Space.sm) {
            filterChip(.active, count: vm.filteredActiveBotItems().count)
            filterChip(.lastFinished, count: vm.filteredFinishedBotItems().count)
        }
        .accessibilityIdentifier("activeBots.statusFilter")
    }

    private func filterChip(_ tab: ActiveBotsTab, count: Int) -> some View {
        let selected = vm.activeBotsTab == tab
        return Button {
            vm.activeBotsTab = tab
        } label: {
            HStack(spacing: DS.Space.xs) {
                Text(tab.title)
                    .font(DS.Font.caption.weight(.semibold))
                Text("\(count)")
                    .font(DS.Font.caption2.weight(.bold))
                    .opacity(selected ? 0.9 : 0.7)
            }
            .foregroundColor(selected ? DS.Palette.onAccent : DS.Palette.textSecondary)
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.sm)
            .background(selected ? DS.Palette.accent : DS.Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(selected ? Color.clear : DS.Palette.line, lineWidth: DS.Border.hairline)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("activeBots.tab.\(tab.rawValue)")
    }

    private var searchField: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityHidden(true)
            TextField("Search bots", text: $vm.activeBotsSearchText)
                .textFieldStyle(.plain)
                .foregroundColor(DS.Palette.text)
                .accessibilityLabel("Search bots")
                .accessibilityIdentifier("activeBots.search")
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
    }

    @ViewBuilder
    private var content: some View {
        switch vm.activeBotsTab {
        case .active:
            activeList
        case .lastFinished:
            finishedList
        }
    }

    private var activeList: some View {
        let items = vm.filteredActiveBotItems()
        return Group {
            if items.isEmpty {
                DSEmptyState(
                    icon: "bolt.horizontal.circle",
                    title: vm.activeBotsSearchText.isEmpty ? "No active bots" : "No matching bots",
                    subtitle: vm.activeBotsSearchText.isEmpty
                        ? "Bot runs in progress will show up here with name and provider context."
                        : "Try another search or clear the status filter."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.md) {
                        ForEach(items) { item in
                            ActiveBotCard(item: item) {
                                vm.openActiveBotItem(item)
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.xxl)
                    .padding(.bottom, DS.Space.xxl)
                }
                .accessibilityIdentifier("activeBots.activeList")
            }
        }
    }

    private var finishedList: some View {
        let items = vm.filteredFinishedBotItems()
        return Group {
            if items.isEmpty {
                DSEmptyState(
                    icon: "checkmark.circle",
                    title: vm.activeBotsSearchText.isEmpty ? "No recent finished runs" : "No matching bots",
                    subtitle: vm.activeBotsSearchText.isEmpty
                        ? "Completed, failed, cancelled, and interrupted bot runs appear here."
                        : "Try another search or clear the status filter."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.md) {
                        ForEach(items) { item in
                            FinishedBotCard(item: item) {
                                vm.openFinishedBotItem(item)
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.xxl)
                    .padding(.bottom, DS.Space.xxl)
                }
                .accessibilityIdentifier("activeBots.finishedList")
            }
        }
    }

    private var footerBar: some View {
        HStack(spacing: DS.Space.md) {
            Text(vm.activeBotsFooterLine)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
            if vm.activeBotCount > 0 {
                DSPill("Live", tone: .warning)
                    .accessibilityHidden(true)
            } else {
                DSPill("Idle", tone: .neutral)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: DS.Space.md)
        }
        .padding(.horizontal, DS.Space.xxl)
        .frame(height: 40)
        .background(DS.Palette.surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(vm.activeBotsFooterLine)
    }
}

private struct ActiveBotCard: View {
    let item: ActiveBotScreenItem
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: DS.Space.xl) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(DS.Palette.accent)
                    .frame(width: 44, height: 44)
                    .background(DS.Palette.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack(spacing: DS.Space.sm) {
                        Text(item.title)
                            .font(DS.Font.body.weight(.semibold))
                            .foregroundColor(DS.Palette.text)
                            .lineLimit(1)
                        DSPill("Running", tone: .success)
                    }
                    Text(item.detail)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Last Triggered")
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                    Text(item.lastTriggeredLabel)
                        .font(DS.Font.caption.weight(.medium))
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(2)
                }
                .frame(width: 140, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Next Run")
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                    Text(item.nextRunLabel)
                        .font(DS.Font.caption.weight(.medium))
                        .foregroundColor(DS.Palette.warning)
                        .lineLimit(2)
                }
                .frame(width: 140, alignment: .leading)

                Menu {
                    Button("Open Desk", action: onOpen)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Bot actions")
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.lg)
            .background(DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("activeBots.active.\(item.botID.value.uuidString.lowercased())")
    }
}

private struct FinishedBotCard: View {
    let item: FinishedBotScreenItem
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: DS.Space.xl) {
                Image(systemName: statusIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(statusColor)
                    .frame(width: 44, height: 44)
                    .background(DS.Palette.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack(spacing: DS.Space.sm) {
                        Text(item.title)
                            .font(DS.Font.body.weight(.semibold))
                            .foregroundColor(DS.Palette.text)
                            .lineLimit(1)
                        statusPill
                    }
                    Text(item.detail)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Last Triggered")
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                    Text(item.lastTriggeredLabel)
                        .font(DS.Font.caption.weight(.medium))
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(2)
                }
                .frame(width: 140, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Next Run")
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                    Text(item.nextRunLabel)
                        .font(DS.Font.caption.weight(.medium))
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(2)
                }
                .frame(width: 140, alignment: .leading)

                Menu {
                    Button("Open Desk", action: onOpen)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Bot actions")
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.lg)
            .background(DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("activeBots.finished.\(item.runID.value.uuidString.lowercased())")
    }

    private var statusIcon: String {
        switch item.status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        case .interrupted: return "exclamationmark.triangle.fill"
        case .pending, .running: return "circle"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .completed: return DS.Palette.success
        case .failed: return DS.Palette.danger
        case .cancelled, .interrupted: return DS.Palette.warning
        case .pending, .running: return DS.Palette.textTertiary
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch item.status {
        case .completed: DSPill("Completed", tone: .success)
        case .failed: DSPill("Failed", tone: .danger)
        case .cancelled: DSPill("Cancelled", tone: .neutral)
        case .interrupted: DSPill("Interrupted", tone: .warning)
        case .pending: DSPill("Pending", tone: .warning)
        case .running: DSPill("Running", tone: .warning)
        }
    }
}
