import AppKit
import CoreModel
import DesignSystemKit
import SwiftUI

public enum AgentChatThreadStatusMark: Equatable {
    case hidden
    case running
    case unread
    case symbol(name: String, color: Color, size: CGFloat)
}

/// One stop affordance for Agent App and dest thread rows.
public enum AgentChatThreadRowStopChrome {
    public static let symbolName = "stop.circle"
    public static let accessibilityLabel = "Stop thread"
    public static let help = "Stop this thread"

    public static func isVisible(
        status: AgentChatThreadStatusMark,
        hasStopHandler: Bool
    ) -> Bool {
        status == .running && hasStopHandler
    }
}

public struct AgentChatThreadRow<Leading: View, Trailing: View>: View {
    public let title: String
    public let subtitle: String
    public let unread: Bool
    public let selected: Bool
    public let status: AgentChatThreadStatusMark
    public let identifier: String
    public let onSelect: () -> Void
    public var unreadIdentifier: String?
    public var runningIdentifier: String?
    public var stopIdentifier: String?
    public var onStop: (() -> Void)?
    public var leading: Leading
    public var trailing: Trailing

    public init(
        title: String,
        subtitle: String,
        unread: Bool,
        selected: Bool,
        status: AgentChatThreadStatusMark,
        identifier: String,
        unreadIdentifier: String? = nil,
        runningIdentifier: String? = nil,
        stopIdentifier: String? = nil,
        onSelect: @escaping () -> Void,
        onStop: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.unread = unread
        self.selected = selected
        self.status = status
        self.identifier = identifier
        self.unreadIdentifier = unreadIdentifier
        self.runningIdentifier = runningIdentifier
        self.stopIdentifier = stopIdentifier
        self.onSelect = onSelect
        self.onStop = onStop
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        Button(action: onSelect) {
            HStack(spacing: DS.Space.md) {
                statusMark
                leading
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(DS.Font.bodyDense.weight(unread ? .semibold : .regular))
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if unread {
                    Circle()
                        .fill(DS.Palette.accent)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("Unread activity")
                        .accessibilityIdentifier(unreadIdentifier ?? "\(identifier).unread")
                }
                trailing
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
            .background(selected ? DS.Palette.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) { stopControl }
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var stopControl: some View {
        if AgentChatThreadRowStopChrome.isVisible(status: status, hasStopHandler: onStop != nil),
           let onStop {
            Button(action: onStop) {
                Image(systemName: AgentChatThreadRowStopChrome.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Palette.danger.opacity(0.75))
            }
            .buttonStyle(.plain)
            .padding(.trailing, DS.Space.md)
            .accessibilityLabel(AgentChatThreadRowStopChrome.accessibilityLabel)
            .accessibilityIdentifier(stopIdentifier ?? "\(identifier).stop")
            .help(AgentChatThreadRowStopChrome.help)
        }
    }

    @ViewBuilder
    private var statusMark: some View {
        switch status {
        case .hidden:
            Color.clear.frame(width: 8, height: 8)
        case .running:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(DS.Palette.textTertiary)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Running")
                .accessibilityIdentifier(runningIdentifier ?? "\(identifier).running")
        case .unread:
            Circle()
                .fill(DS.Palette.accent)
                .frame(width: 7, height: 7)
                .accessibilityLabel("Unread")
        case .symbol(let name, let color, let size):
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 8, height: 8)
        }
    }
}

/// Provider monogram chip at the leading edge of a thread row. Agent
/// App and Desk mount the same chip — the rails must not fork it.
public struct AgentThreadProviderMonogram: View {
    public let provider: AgentProvider

    public init(provider: AgentProvider) {
        self.provider = provider
    }

    public var body: some View {
        Text(AgentThreadRailRowCopy.monogram(for: provider))
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundColor(DS.Palette.textSecondary)
            .frame(width: 16, height: 16)
            .background(DS.Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityHidden(true)
    }
}

public extension AgentChatThreadRow where Leading == EmptyView, Trailing == EmptyView {
    init(
        title: String,
        subtitle: String,
        unread: Bool,
        selected: Bool,
        status: AgentChatThreadStatusMark,
        identifier: String,
        unreadIdentifier: String? = nil,
        runningIdentifier: String? = nil,
        stopIdentifier: String? = nil,
        onSelect: @escaping () -> Void,
        onStop: (() -> Void)? = nil
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            unread: unread,
            selected: selected,
            status: status,
            identifier: identifier,
            unreadIdentifier: unreadIdentifier,
            runningIdentifier: runningIdentifier,
            stopIdentifier: stopIdentifier,
            onSelect: onSelect,
            onStop: onStop,
            leading: { EmptyView() },
            trailing: { EmptyView() }
        )
    }
}

public struct AgentQueuedRow<Trailing: View>: View {
    public let text: String
    public let identifier: String
    public var leading: AnyView? = nil
    public var detail: AnyView? = nil
    public var trailing: Trailing

    public init(
        text: String,
        identifier: String,
        leading: AnyView? = nil,
        detail: AnyView? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.text = text
        self.identifier = identifier
        self.leading = leading
        self.detail = detail
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            if let leading {
                leading
            }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(text)
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.text)
                    .lineLimit(3)
                if let detail {
                    detail
                }
            }
            Spacer(minLength: DS.Space.sm)
            trailing
        }
        .accessibilityIdentifier(identifier)
    }
}

public struct AgentChatAttachmentChips: View {
    public let attachments: [AgentAttachment]
    public let onRemove: (AgentAttachment) -> Void
    public var chipIdentifierPrefix: String = "bots.desk.attachment."
    public var stripIdentifier: String = "bots.desk.attachments"

    public init(
        attachments: [AgentAttachment],
        onRemove: @escaping (AgentAttachment) -> Void,
        chipIdentifierPrefix: String = "bots.desk.attachment.",
        stripIdentifier: String = "bots.desk.attachments"
    ) {
        self.attachments = attachments
        self.onRemove = onRemove
        self.chipIdentifierPrefix = chipIdentifierPrefix
        self.stripIdentifier = stripIdentifier
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.sm) {
                ForEach(attachments, id: \.self) { attachment in
                    HStack(spacing: DS.Space.xs) {
                        if AgentChatTranscriptChrome.isImagePath(attachment.path),
                           let img = NSImage(contentsOfFile: attachment.path) {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 18, height: 18)
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        } else {
                            Image(systemName: AgentChatTranscriptChrome.isImagePath(attachment.path) ? "photo" : "doc")
                                .font(.system(size: 9))
                        }
                        Text(attachment.displayName)
                            .font(DS.Font.caption2).lineLimit(1)
                        Button { onRemove(attachment) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.displayName)")
                    }
                    .foregroundColor(DS.Palette.textSecondary)
                    .padding(.horizontal, DS.Space.sm).padding(.vertical, 3)
                    .background(DS.Palette.surfaceRaised)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline))
                    .accessibilityIdentifier("\(chipIdentifierPrefix)\(attachment.displayName)")
                }
            }
        }
        .accessibilityIdentifier(stripIdentifier)
    }
}

public struct AgentChatWorkingPill: View {
    public let label: String
    public var identifier: String = "agent.workingPhase"
    public var tone: DSPill.Tone = .accent
    public var help: String? = nil
    public var accessibilityLabelText: String? = nil
    public var padded: Bool = true

    public init(
        label: String,
        identifier: String = "agent.workingPhase",
        tone: DSPill.Tone = .accent,
        help: String? = nil,
        accessibilityLabelText: String? = nil,
        padded: Bool = true
    ) {
        self.label = label
        self.identifier = identifier
        self.tone = tone
        self.help = help
        self.accessibilityLabelText = accessibilityLabelText
        self.padded = padded
    }

    public var body: some View {
        let pill = DSPill(label, tone: tone)
            .help(help ?? label)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(accessibilityLabelText ?? label)
        if padded {
            HStack {
                pill
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.sm)
        } else {
            pill
        }
    }
}

public struct AgentChatPeerActivityRow: View {
    public let snapshot: BotPeerActivitySnapshot
    public let startedAt: Date
    /// The waiting bot's avatar. Falls back to initials when the bot has no
    /// Blobatar/symbol so the row always shows who is being waited on.
    public var avatarSymbol: String?

    public init(
        snapshot: BotPeerActivitySnapshot,
        startedAt: Date,
        avatarSymbol: String? = nil
    ) {
        self.snapshot = snapshot
        self.startedAt = startedAt
        self.avatarSymbol = avatarSymbol
    }

    public var body: some View {
        TimelineView(AgentChatElapsedTickSchedule(start: startedAt)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
            HStack(alignment: .top, spacing: DS.Space.sm) {
                stateIcon
                BotsAvatarView(
                    name: snapshot.name,
                    handle: snapshot.handle,
                    symbol: avatarSymbol,
                    size: 22
                )
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(AgentPeerActivityPresentation.title(for: snapshot))
                        .font(DS.Font.body.weight(.medium))
                        .foregroundColor(titleColor)
                    Text(AgentPeerActivityPresentation.detail(
                        for: snapshot,
                        elapsedSeconds: seconds
                    ))
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AgentPeerActivityPresentation.accessibilityLabel(
                for: snapshot,
                elapsedSeconds: seconds
            ))
            .accessibilityIdentifier("agent.peerActivity")
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch snapshot.phase {
        case .waiting:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.regular)
                .tint(DS.Palette.accent)
                .frame(width: 22, height: 22)
                .background(Circle().fill(DS.Palette.accent.opacity(0.16)))
                .accessibilityHidden(true)
        case .needsAttention:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Palette.danger)
                .accessibilityHidden(true)
        }
    }

    private var titleColor: Color {
        snapshot.phase == .needsAttention ? DS.Palette.danger : DS.Palette.text
    }
}

/// Shared thread rail chrome. Agent App and dest mount this so hide,
/// Clear All, +, and search stay one control.
public struct AgentChatThreadRail<Content: View>: View {
    public let title: String
    public let isEmpty: Bool
    public let emptySubtitle: String
    @Binding public var searchQuery: String
    public let hasSearchMatches: Bool
    public let onHide: () -> Void
    public let onClearAll: () -> Void
    public let onNew: () -> Void
    public var identifier: String
    public var hideIdentifier: String
    public var clearAllIdentifier: String
    public var newIdentifier: String
    public var searchIdentifier: String
    public var newHelp: String = AgentChatThreadRailCopy.newHelp
    public var showsTrailingHairline: Bool = false
    public var content: Content

    public init(
        title: String,
        isEmpty: Bool,
        emptySubtitle: String,
        searchQuery: Binding<String>,
        hasSearchMatches: Bool,
        identifier: String,
        hideIdentifier: String,
        clearAllIdentifier: String,
        newIdentifier: String,
        searchIdentifier: String,
        newHelp: String = AgentChatThreadRailCopy.newHelp,
        showsTrailingHairline: Bool = false,
        onHide: @escaping () -> Void,
        onClearAll: @escaping () -> Void,
        onNew: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.isEmpty = isEmpty
        self.emptySubtitle = emptySubtitle
        self._searchQuery = searchQuery
        self.hasSearchMatches = hasSearchMatches
        self.identifier = identifier
        self.hideIdentifier = hideIdentifier
        self.clearAllIdentifier = clearAllIdentifier
        self.newIdentifier = newIdentifier
        self.searchIdentifier = searchIdentifier
        self.newHelp = newHelp
        self.showsTrailingHairline = showsTrailingHairline
        self.onHide = onHide
        self.onClearAll = onClearAll
        self.onNew = onNew
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSSectionHeaderG(title) {
                HStack(spacing: Self.headerControlSpacing) {
                    hideButton
                        .padding(.horizontal, -DSIconButton.visualPackInset)
                    if AgentChatThreadRailCopy.showsClearAll(isEmpty: isEmpty) {
                        Button(AgentChatThreadRailCopy.clearAllTitle, action: onClearAll)
                            .buttonStyle(.plain)
                            .font(DS.Font.caption.weight(.medium))
                            .foregroundColor(DS.Palette.textSecondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityIdentifier(clearAllIdentifier)
                            .help(AgentChatThreadRailCopy.clearAllHelp)
                    }
                    DSIconButton("plus", help: newHelp, action: onNew)
                        .padding(.horizontal, -DSIconButton.visualPackInset)
                        .accessibilityIdentifier(newIdentifier)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            if isEmpty {
                DSEmptyState(
                    icon: AgentChatThreadRailCopy.emptyIcon,
                    title: AgentChatThreadRailCopy.emptyTitle,
                    subtitle: emptySubtitle
                )
            } else {
                searchBar
                if hasSearchMatches {
                    content
                } else {
                    Text(AgentChatThreadRailCopy.noMatchText(query: searchQuery))
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                        .padding(DS.Space.sm)
                }
            }
        }
        .background(DS.Palette.surface)
        .accessibilityIdentifier(identifier)
        .overlay(alignment: .trailing) {
            if showsTrailingHairline {
                Rectangle().fill(DS.Palette.line).frame(width: DS.Border.hairline)
            }
        }
    }

    /// Gap between hide, Clear All, and +. Icons keep a 44pt hit box via
    /// `visualPackInset`; this spacing is the visible air between glyphs.
    private static var headerControlSpacing: CGFloat { DS.Space.md }

    private var hideButton: some View {
        DSIconButton("sidebar.left", help: AgentChatThreadRailCopy.hideHelp, action: onHide)
            .accessibilityIdentifier(hideIdentifier)
    }

    private var searchBar: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityHidden(true)
            TextField(AgentChatThreadRailCopy.searchPlaceholder, text: $searchQuery)
                .textFieldStyle(.plain)
                .font(DS.Font.caption)
                .accessibilityIdentifier(searchIdentifier)
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(DS.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AgentChatThreadRailCopy.clearSearchLabel)
            }
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.xs)
    }
}
