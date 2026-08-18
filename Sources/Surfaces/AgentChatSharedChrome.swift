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
        onSelect: @escaping () -> Void,
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
        self.onSelect = onSelect
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
        .accessibilityIdentifier(identifier)
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
        onSelect: @escaping () -> Void
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
            onSelect: onSelect,
            leading: { EmptyView() },
            trailing: { EmptyView() }
        )
    }
}

public struct AgentQueuedRow<Trailing: View>: View {
    public let text: String
    public let identifier: String
    public var trailing: Trailing

    public init(text: String, identifier: String, @ViewBuilder trailing: () -> Trailing) {
        self.text = text
        self.identifier = identifier
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            Text(text)
                .font(DS.Font.body)
                .foregroundColor(DS.Palette.text)
                .lineLimit(3)
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

    public init(label: String, identifier: String = "agent.workingPhase") {
        self.label = label
        self.identifier = identifier
    }

    public var body: some View {
        HStack {
            DSPill(label, tone: .accent)
                .help(label)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(label)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.top, DS.Space.sm)
    }
}
